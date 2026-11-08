package interceptor

import (
	"context"
	"errors"
	"log"
	"time"

	"example.com/music-app/internal/auth/authn"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/ratelimit"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// Authenticator resolves a session token. The part of
// internal/auth/authn.Authenticator used here.
type Authenticator interface {
	Authenticate(ctx context.Context, token string) (authn.Identity, error)
}

// Checker asks OpenFGA one question. The part of internal/authz.Client used
// here -- an interface so a test can answer without a server, and so this
// package cannot accidentally reach the write side.
type Checker interface {
	Check(ctx context.Context, req authz.CheckRequest) (bool, error)
}

// IDResolver turns a public UUID into an internal id. *Resolver is the one
// implementation; the interface is what lets the tests below exercise every
// decision in this file without a database, since none of those decisions
// depend on what the id turns out to be.
type IDResolver interface {
	Resolve(ctx context.Context, objectType authz.ObjectType, publicID string) (int64, error)
}

// defaultCheckTimeout bounds one Check.
//
// A check must answer now: it is on the request path, and an unbounded wait on
// a slow OpenFGA turns one degraded dependency into every request hanging.
// Short enough that the caller gets a denial instead of a timeout, long enough
// to survive a GC pause or a cold connection.
const defaultCheckTimeout = 2 * time.Second

// Interceptor authenticates and authorizes every RPC against the policy table.
type Interceptor struct {
	auth        Authenticator
	checker     Checker
	ids         IDResolver
	activityLog ActivityLogger
	perIP       *ratelimit.Limiter // LimitPerIP; nil = no limit

	now          func() time.Time
	checkTimeout time.Duration
}

func New(auth Authenticator, checker Checker, ids IDResolver, activityLog ActivityLogger) *Interceptor {
	return &Interceptor{
		auth:         auth,
		checker:      checker,
		ids:          ids,
		activityLog:  activityLog,
		now:          time.Now,
		checkTimeout: defaultCheckTimeout,
	}
}

// Unary is the interceptor to hand grpc.NewServer.
//
// Activity logging (V.6) lives here rather than as its own chained
// interceptor: it has to see every outcome, denials included, and a denial
// from authorize below never reaches a handler positioned after it in a
// chain -- only whatever wraps the whole authorize-then-handle sequence
// does.
func (i *Interceptor) Unary() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if err := i.throttleIP(ctx); err != nil {
			return nil, err
		}
		authorized, err := i.authorize(ctx, info.FullMethod, req)
		identity, ok := authn.FromContext(authorized)
		if err == nil && ok {
			err = throttleUser(info.FullMethod, identity.UserID)
		}
		if err != nil {
			i.logActivity(authorized, info.FullMethod, req, identity, ok, err)
			return nil, err
		}
		resp, err := handler(authorized, req)
		i.logActivity(authorized, info.FullMethod, req, identity, ok, err)
		return resp, err
	}
}

// Stream authorizes server-streaming RPCs exactly like unary ones, against the
// same policy table, at the moment the stream opens.
//
// The request of a server stream only exists once the handler reads it, so the
// check runs inside RecvMsg (authorizedStream): the generated handler reads the
// one request first thing, gets the denial as the error of that read, and
// returns it before any message is sent. Client and bidirectional streams are
// refused outright -- with several requests there is no single one to check.
//
// Opening is not the end of it: a viewer let in while a playlist was public
// must be dropped when it goes private (docs/permissions.md §7). That re-check
// belongs to each Watch handler, before every send, since only it knows when
// the state changed.
func (i *Interceptor) Stream() grpc.StreamServerInterceptor {
	return func(srv any, stream grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if i.perIP != nil {
			if err := i.throttleIP(stream.Context()); err != nil {
				return err
			}
		}
		if allowedWithoutPolicy[info.FullMethod] {
			return handler(srv, stream)
		}
		if info.IsClientStream {
			log.Printf("authz: client-streaming method %s has no authorization path -- denied", info.FullMethod)
			return status.Error(codes.PermissionDenied, "permission denied")
		}
		return handler(srv, &authorizedStream{ServerStream: stream, ctx: stream.Context(), method: info.FullMethod, i: i})
	}
}

// authorizedStream runs authorize on the stream's one request, and hands the
// handler the context carrying the caller's identity from then on.
type authorizedStream struct {
	grpc.ServerStream
	ctx        context.Context
	method     string
	i          *Interceptor
	authorized bool
}

func (s *authorizedStream) Context() context.Context { return s.ctx }

func (s *authorizedStream) RecvMsg(m any) error {
	if err := s.ServerStream.RecvMsg(m); err != nil {
		return err
	}
	if s.authorized {
		return nil
	}
	ctx, err := s.i.authorize(s.ctx, s.method, m)
	identity, ok := authn.FromContext(ctx)
	// Logged at opening, denials included, like a unary call: a stream can
	// stay open for an hour, and the opening is what someone asked for.
	s.i.logActivity(ctx, s.method, m, identity, ok, err)
	if err != nil {
		return err
	}
	s.ctx, s.authorized = ctx, true
	return nil
}

// authorize is the whole decision. It returns the context the handler should
// run with -- the identity is attached to it, as soon as it is known, on
// every path, including a later denial -- or the error the caller gets.
//
// Attaching identity before the outcome is decided (rather than only on the
// final, fully-successful return) is what lets activity logging (Unary,
// logActivity) record WHO was denied, not just THAT someone was: a request
// can fail authentication and never resolve an identity at all (logged as
// anonymous, correctly), or authenticate fine and still be denied by a
// Requirement further down -- those two must not look the same in the log.
func (i *Interceptor) authorize(ctx context.Context, method string, req any) (context.Context, error) {
	policy, known := policies[method]
	if !known {
		if allowedWithoutPolicy[method] {
			return ctx, nil
		}
		// Fail closed and say so. An RPC missing from the table is a mistake
		// in this repository, not in the request, and the log line is the only
		// way anyone finds out which one.
		log.Printf("authz: %s has no policy entry -- denied", method)
		return ctx, status.Error(codes.PermissionDenied, "permission denied")
	}
	if policy.Public {
		return ctx, nil
	}

	token, err := bearerToken(ctx)
	if err != nil {
		return ctx, status.Error(codes.Unauthenticated, "missing session token")
	}
	identity, err := i.auth.Authenticate(ctx, token)
	if err != nil {
		// Four distinct refusals (unknown, revoked, expired, inactive account)
		// collapse into one answer for the client and stay distinct in the log
		// -- see internal/auth/authn. "Which of the four" is operational
		// information, not the caller's business.
		log.Printf("authn: %s: %v", method, err)
		return ctx, status.Error(codes.Unauthenticated, "invalid session token")
	}
	ctx = authn.NewContext(ctx, identity)

	message, err := requestMessage(req)
	if err != nil {
		log.Printf("authz: %s: %v", method, err)
		return ctx, status.Error(codes.Internal, "could not inspect request")
	}

	if err := i.stampCaller(message, policy, identity); err != nil {
		return ctx, err
	}
	for _, requirement := range policy.Require {
		if err := i.enforce(ctx, message, requirement, identity); err != nil {
			return ctx, err
		}
	}

	return ctx, nil
}

// stampCaller replaces the request's idea of who is calling with the session's.
//
// A client may send its own public id -- it is in the REST path for several
// routes -- and sending someone else's is refused rather than quietly
// corrected. Both readings are defensible; this one turns a client bug into an
// error the client can see, where silently overwriting would let a request that
// meant to act as A succeed as B and look fine.
func (i *Interceptor) stampCaller(message protoreflect.Message, policy Policy, identity authn.Identity) error {
	if policy.CallerPublicIDField == "" {
		return nil
	}

	claimed, err := stringField(message, policy.CallerPublicIDField)
	if err != nil {
		log.Printf("authz: %v", err)
		return status.Error(codes.Internal, "could not inspect request")
	}
	if claimed != "" {
		normalized, err := authz.NormalizePublicID(claimed)
		if err != nil {
			return status.Errorf(codes.InvalidArgument, "%s is not a valid public id", policy.CallerPublicIDField)
		}
		if normalized != identity.UserPublicID {
			return status.Errorf(codes.PermissionDenied,
				"%s does not match the authenticated session", policy.CallerPublicIDField)
		}
	}

	// Canonical form on the way in, so a handler that echoes the field back
	// does not hand the client a different spelling than it sent.
	if err := setStringField(message, policy.CallerPublicIDField, identity.UserPublicID); err != nil {
		log.Printf("authz: %v", err)
		return status.Error(codes.Internal, "could not prepare request")
	}
	// The session lookup already returned the internal id (it joins users), so
	// the caller costs no resolution query -- only the other objects do.
	if err := setInt64Field(message, stampFieldFor(policy.CallerPublicIDField), identity.UserID); err != nil {
		log.Printf("authz: %v", err)
		return status.Error(codes.Internal, "could not prepare request")
	}
	return nil
}

// enforce runs one requirement: check the permission, then resolve the object.
//
// That order is deliberate. The check needs no database at all -- it is
// answerable from the request, which is the whole reason objects are named by
// public UUID (internal/authz.Object) -- so a denied request never reaches
// Postgres. And a made-up id is denied rather than reported as missing, which
// keeps "you may not" and "it is not there" indistinguishable on the read path.
func (i *Interceptor) enforce(ctx context.Context, message protoreflect.Message, requirement Requirement, identity authn.Identity) error {
	raw, err := stringField(message, requirement.IDField)
	if err != nil {
		log.Printf("authz: %v", err)
		return status.Error(codes.Internal, "could not inspect request")
	}
	if raw == "" {
		if requirement.Optional {
			return nil
		}
		return status.Errorf(codes.InvalidArgument, "%s is required", requirement.IDField)
	}
	publicID, err := authz.NormalizePublicID(raw)
	if err != nil {
		return status.Errorf(codes.InvalidArgument, "%s is not a valid public id", requirement.IDField)
	}

	if requirement.Permission != "" {
		object := authz.Object(requirement.Type, publicID)
		check := authz.CheckRequest{
			Subject:    authz.UserRef(identity.UserPublicID),
			Permission: requirement.Permission,
			Object:     object,
		}
		// Only where a condition reads it: a context is part of OpenFGA's
		// check-cache key (authz.NeedsRequestTime).
		if authz.NeedsRequestTime(requirement.Type, requirement.Permission) {
			check.Context = map[string]any{"current_time": authz.RequestTime(i.now())}
		}
		allowed, err := i.check(ctx, check)
		if err != nil {
			// Fail closed, and log it: this is the only branch where a denial
			// does not mean the caller lacks the permission, and the outage it
			// reports is invisible from the client's side.
			log.Printf("authz: check %s#%s@%s failed, denying: %v",
				object, requirement.Permission, identity.UserPublicID, err)
			return status.Error(codes.PermissionDenied, "permission denied")
		}
		if !allowed {
			return deny(requirement)
		}
	}

	if requirement.Resolve {
		id, err := i.ids.Resolve(ctx, requirement.Type, publicID)
		if err != nil {
			if errors.Is(err, ErrUnknownObject) {
				return deny(requirement)
			}
			log.Printf("authz: resolving %s %s: %v", requirement.Type, publicID, err)
			return status.Error(codes.Internal, "could not resolve request")
		}
		if err := setInt64Field(message, requirement.StampField(), id); err != nil {
			log.Printf("authz: %v", err)
			return status.Error(codes.Internal, "could not prepare request")
		}
	}
	return nil
}

// check bounds one question so a slow dependency cannot hold the request open.
func (i *Interceptor) check(ctx context.Context, req authz.CheckRequest) (bool, error) {
	checkCtx, cancel := context.WithTimeout(ctx, i.checkTimeout)
	defer cancel()
	return i.checker.Check(checkCtx, req)
}

// deny answers a failed requirement. NotFound where telling the caller the
// object exists would itself be the disclosure -- see Requirement.NotFound.
func deny(requirement Requirement) error {
	if requirement.NotFound {
		return status.Errorf(codes.NotFound, "%s not found", requirement.Type)
	}
	return status.Error(codes.PermissionDenied, "permission denied")
}
