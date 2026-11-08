package interceptor

import (
	"context"
	"errors"
	"testing"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/auth/authn"
	"example.com/music-app/internal/authz"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// These tests exercise the decisions, not the dependencies: OpenFGA and
// Postgres are replaced by two functions, because nothing the interceptor
// decides depends on what they answer beyond yes/no and an id.

const (
	callerPublicID = "3ab93193-24a1-44ef-91a4-5d21c6ec9acb"
	callerID       = int64(7)
	otherPublicID  = "11111111-2222-3333-4444-555555555555"
)

type fakeAuth struct {
	identity authn.Identity
	err      error
}

func (f fakeAuth) Authenticate(context.Context, string) (authn.Identity, error) {
	return f.identity, f.err
}

type fakeChecker struct {
	allow    bool
	err      error
	requests []authz.CheckRequest
}

func (f *fakeChecker) Check(_ context.Context, req authz.CheckRequest) (bool, error) {
	f.requests = append(f.requests, req)
	return f.allow, f.err
}

type fakeResolver struct {
	id  int64
	err error
}

func (f fakeResolver) Resolve(context.Context, authz.ObjectType, string) (int64, error) {
	return f.id, f.err
}

// fakeActivityLog stands in for Postgres: these tests exercise authorization
// decisions, not the audit log, and logActivity fires it in a goroutine
// anyway (see its own comment) -- nothing here reads calls back out.
type fakeActivityLog struct{}

func (fakeActivityLog) CreateActivityLog(context.Context, sqlc.CreateActivityLogParams) (sqlc.ActivityLog, error) {
	return sqlc.ActivityLog{}, nil
}

// harness builds an interceptor whose every dependency answers yes.
func harness(t *testing.T) (*Interceptor, *fakeChecker) {
	t.Helper()

	checker := &fakeChecker{allow: true}
	i := New(
		fakeAuth{identity: authn.Identity{UserID: callerID, UserPublicID: callerPublicID}},
		checker,
		fakeResolver{id: 42},
		fakeActivityLog{},
	)
	i.now = func() time.Time { return time.Date(2026, 9, 15, 18, 0, 0, 0, time.UTC) }
	return i, checker
}

func withToken(ctx context.Context) context.Context {
	return metadata.NewIncomingContext(ctx, metadata.Pairs("authorization", "Bearer opaque-token"))
}

// run puts req through the unary interceptor and reports whether the handler
// ran. The request is mutated in place, so the caller inspects it afterwards.
func run(t *testing.T, i *Interceptor, method string, req any) (ran bool, err error) {
	t.Helper()

	handler := func(context.Context, any) (any, error) {
		ran = true
		return nil, nil
	}
	_, err = i.Unary()(withToken(context.Background()), req, &grpc.UnaryServerInfo{FullMethod: method}, handler)
	return ran, err
}

func assertCode(t *testing.T, err error, want codes.Code) {
	t.Helper()

	if status.Code(err) != want {
		t.Fatalf("got %v (code %s), want code %s", err, status.Code(err), want)
	}
}

func TestPublicMethodNeedsNoToken(t *testing.T) {
	i, _ := harness(t)

	handler := func(context.Context, any) (any, error) { return nil, nil }
	_, err := i.Unary()(context.Background(), &pb.LoginRequest{},
		&grpc.UnaryServerInfo{FullMethod: "/music_room.v1.AuthService/Login"}, handler)
	if err != nil {
		t.Fatalf("Login must work without a session: %v", err)
	}
}

func TestMissingTokenIsUnauthenticated(t *testing.T) {
	i, _ := harness(t)

	handler := func(context.Context, any) (any, error) { return nil, nil }
	_, err := i.Unary()(context.Background(), &pb.GetFriendsRequest{},
		&grpc.UnaryServerInfo{FullMethod: "/music_room.v1.UserService/GetFriends"}, handler)
	assertCode(t, err, codes.Unauthenticated)
}

func TestUnknownMethodIsDenied(t *testing.T) {
	i, _ := harness(t)

	ran, err := run(t, i, "/music_room.v1.UserService/SomethingNobodyProtected", &pb.GetFriendsRequest{})
	if ran {
		t.Error("an unlisted method reached its handler")
	}
	assertCode(t, err, codes.PermissionDenied)
}

// The caller id is not negotiable. An empty field is filled in from the
// session; a field naming someone else is refused.
func TestCallerIDIsFilledInFromTheSession(t *testing.T) {
	i, _ := harness(t)
	req := &pb.GetFriendsRequest{}

	ran, err := run(t, i, "/music_room.v1.UserService/GetFriends", req)
	if err != nil || !ran {
		t.Fatalf("ran=%v err=%v", ran, err)
	}
	if req.GetUserId() != callerID {
		t.Errorf("user_id = %d, want %d", req.GetUserId(), callerID)
	}
	if req.GetUserPublicId() != callerPublicID {
		t.Errorf("user_public_id = %q, want %q", req.GetUserPublicId(), callerPublicID)
	}
}

func TestClaimingSomeoneElseIsDenied(t *testing.T) {
	i, _ := harness(t)
	req := &pb.GetFriendsRequest{UserPublicId: otherPublicID}

	ran, err := run(t, i, "/music_room.v1.UserService/GetFriends", req)
	if ran {
		t.Error("the handler ran for a request claiming to be another user")
	}
	assertCode(t, err, codes.PermissionDenied)
}

// The hex form is what PlaylistDTO, MusicEventDTO and UserDTO used to emit, so
// a client echoing an older id back must still work.
func TestUndashedPublicIDIsAccepted(t *testing.T) {
	i, _ := harness(t)
	undashed := "3ab9319324a144ef91a45d21c6ec9acb"
	req := &pb.GetFriendsRequest{UserPublicId: undashed}

	if _, err := run(t, i, "/music_room.v1.UserService/GetFriends", req); err != nil {
		t.Fatalf("the undashed form of the caller's own id was rejected: %v", err)
	}
	if req.GetUserPublicId() != callerPublicID {
		t.Errorf("user_public_id = %q, want it normalized to %q", req.GetUserPublicId(), callerPublicID)
	}
}

func TestMalformedPublicIDIsInvalidArgument(t *testing.T) {
	i, _ := harness(t)
	req := &pb.GetPlaylistRequest{PlaylistPublicId: "not-a-uuid"}

	_, err := run(t, i, "/music_room.v1.PlaylistService/GetPlaylist", req)
	assertCode(t, err, codes.InvalidArgument)
}

func TestMissingRequiredObjectIsInvalidArgument(t *testing.T) {
	i, _ := harness(t)

	_, err := run(t, i, "/music_room.v1.PlaylistService/GetPlaylist", &pb.GetPlaylistRequest{})
	assertCode(t, err, codes.InvalidArgument)
}

// The resolved id lands in the request. This is the invariant the whole design
// rests on: the handler acts on the object that was checked because it has no
// other id to act on.
func TestResolvedObjectIDIsStamped(t *testing.T) {
	i, _ := harness(t)
	req := &pb.GetPlaylistRequest{PlaylistPublicId: otherPublicID}

	ran, err := run(t, i, "/music_room.v1.PlaylistService/GetPlaylist", req)
	if err != nil || !ran {
		t.Fatalf("ran=%v err=%v", ran, err)
	}
	if req.GetPlaylistId() != 42 {
		t.Errorf("playlist_id = %d, want the resolved 42", req.GetPlaylistId())
	}

	checked := authz.Object(authz.TypePlaylist, otherPublicID)
	if got := i.checker.(*fakeChecker).requests[0]; got.Object != checked {
		t.Errorf("checked %q, want %q", got.Object, checked)
	}
}

func TestDeniedReadIsNotFound(t *testing.T) {
	i, checker := harness(t)
	checker.allow = false

	ran, err := run(t, i, "/music_room.v1.PlaylistService/GetPlaylist",
		&pb.GetPlaylistRequest{PlaylistPublicId: otherPublicID})
	if ran {
		t.Error("the handler ran after a denied check")
	}
	assertCode(t, err, codes.NotFound)
}

func TestDeniedWriteIsPermissionDenied(t *testing.T) {
	i, checker := harness(t)
	checker.allow = false

	_, err := run(t, i, "/music_room.v1.PlaylistService/AddSongToPlaylist",
		&pb.AddSongToPlaylistRequest{PlaylistPublicId: otherPublicID})
	assertCode(t, err, codes.PermissionDenied)
}

// A check that cannot be answered is a denial, not a pass. The opposite choice
// -- allowing a request through when the authorization server is unreachable --
// turns one outage into an open door.
func TestCheckFailureFailsClosed(t *testing.T) {
	i, checker := harness(t)
	checker.err = errors.New("openfga unreachable")

	ran, err := run(t, i, "/music_room.v1.PlaylistService/AddSongToPlaylist",
		&pb.AddSongToPlaylistRequest{PlaylistPublicId: otherPublicID})
	if ran {
		t.Error("the handler ran despite an unanswerable check")
	}
	assertCode(t, err, codes.PermissionDenied)
}

func TestUnknownObjectIsDenied(t *testing.T) {
	i, _ := harness(t)
	i.ids = fakeResolver{err: ErrUnknownObject}

	_, err := run(t, i, "/music_room.v1.PlaylistService/GetPlaylist",
		&pb.GetPlaylistRequest{PlaylistPublicId: otherPublicID})
	assertCode(t, err, codes.NotFound)
}

// CreateEvent's source playlist is the one genuinely optional object: absent
// means "start with an empty queue", not "you forgot something".
func TestOptionalObjectIsSkippedWhenAbsent(t *testing.T) {
	i, checker := harness(t)

	ran, err := run(t, i, "/music_room.v1.EventService/CreateEvent", &pb.CreateEventRequest{Name: "x"})
	if err != nil || !ran {
		t.Fatalf("ran=%v err=%v", ran, err)
	}
	if len(checker.requests) != 0 {
		t.Errorf("checked %d objects, want none", len(checker.requests))
	}
}

func TestOptionalObjectIsCheckedWhenPresent(t *testing.T) {
	i, checker := harness(t)
	req := &pb.CreateEventRequest{Name: "x", SourcePlaylistPublicId: otherPublicID}

	if _, err := run(t, i, "/music_room.v1.EventService/CreateEvent", req); err != nil {
		t.Fatalf("err=%v", err)
	}
	if len(checker.requests) != 1 || checker.requests[0].Permission != authz.PermPlaylistView {
		t.Fatalf("seeding from a playlist must check can_view on it, got %+v", checker.requests)
	}
	if req.GetSourcePlaylistId() != 42 {
		t.Errorf("source_playlist_id = %d, want the resolved 42", req.GetSourcePlaylistId())
	}
}

// Two objects, two checks: the playlist and the invitee (docs/permissions.md §9).
func TestInviteChecksBothObjects(t *testing.T) {
	i, checker := harness(t)
	req := &pb.InviteToPlaylistRequest{
		PlaylistPublicId:    otherPublicID,
		InviteeUserPublicId: callerPublicID,
	}

	if _, err := run(t, i, "/music_room.v1.PlaylistService/InviteToPlaylist", req); err != nil {
		t.Fatalf("err=%v", err)
	}
	if len(checker.requests) != 2 {
		t.Fatalf("got %d checks, want 2 (the playlist and the invitee)", len(checker.requests))
	}
	if checker.requests[0].Permission != authz.PermPlaylistInvite {
		t.Errorf("first check is %s, want %s", checker.requests[0].Permission, authz.PermPlaylistInvite)
	}
	if checker.requests[1].Permission != authz.PermUserReceiveInvitation {
		t.Errorf("second check is %s, want %s", checker.requests[1].Permission, authz.PermUserReceiveInvitation)
	}
}

// within_vote_window needs current_time from the request side, so the checks
// that can reach it carry it -- both of CastVote's -- truncated to the minute
// so repeated checks share OpenFGA's cache key.
func TestConditionalChecksCarryCurrentTime(t *testing.T) {
	i, checker := harness(t)
	i.now = func() time.Time { return time.Date(2026, 9, 15, 18, 0, 42, 0, time.UTC) }

	if _, err := run(t, i, "/music_room.v1.EventService/CastVote", &pb.CastVoteRequest{
		EventPublicId:      otherPublicID,
		QueueEntryPublicId: otherPublicID,
	}); err != nil {
		t.Fatalf("err=%v", err)
	}
	if len(checker.requests) != 2 {
		t.Fatalf("%d checks ran, want 2", len(checker.requests))
	}
	for _, req := range checker.requests {
		if got := req.Context["current_time"]; got != "2026-09-15T18:00:00Z" {
			t.Errorf("%s: current_time = %v, want the request's clock to the minute", req.Object, got)
		}
	}
}

// The opposite case: a check no condition can reach sends no context at all,
// because OpenFGA's check cache keys on it.
func TestUnconditionalChecksCarryNoContext(t *testing.T) {
	i, checker := harness(t)

	if _, err := run(t, i, "/music_room.v1.PlaylistService/GetPlaylist",
		&pb.GetPlaylistRequest{PlaylistPublicId: otherPublicID}); err != nil {
		t.Fatalf("err=%v", err)
	}
	if len(checker.requests) == 0 {
		t.Fatal("no check ran")
	}
	if ctx := checker.requests[0].Context; ctx != nil {
		t.Errorf("context = %v, want none", ctx)
	}
}

func TestSubjectIsTheAuthenticatedUser(t *testing.T) {
	i, checker := harness(t)

	if _, err := run(t, i, "/music_room.v1.PlaylistService/GetPlaylist",
		&pb.GetPlaylistRequest{PlaylistPublicId: otherPublicID}); err != nil {
		t.Fatalf("err=%v", err)
	}
	if got, want := checker.requests[0].Subject, authz.UserRef(callerPublicID); got != want {
		t.Errorf("subject = %q, want %q", got, want)
	}
}

func TestIdentityReachesTheHandler(t *testing.T) {
	i, _ := harness(t)

	var seen authn.Identity
	var ok bool
	handler := func(ctx context.Context, _ any) (any, error) {
		seen, ok = authn.FromContext(ctx)
		return nil, nil
	}
	if _, err := i.Unary()(withToken(context.Background()), &pb.GetFriendsRequest{},
		&grpc.UnaryServerInfo{FullMethod: "/music_room.v1.UserService/GetFriends"}, handler); err != nil {
		t.Fatalf("err=%v", err)
	}
	if !ok || seen.UserPublicID != callerPublicID || seen.UserID != callerID {
		t.Errorf("handler saw identity %+v (present=%v), want the authenticated caller", seen, ok)
	}
}

// fakeStream delivers one request, the way a server stream's client sends it.
type fakeStream struct {
	grpc.ServerStream
	ctx context.Context
	req proto.Message
}

func (f *fakeStream) Context() context.Context { return f.ctx }

func (f *fakeStream) RecvMsg(m any) error {
	proto.Merge(m.(proto.Message), f.req)
	return nil
}

// runStream opens a server stream on method the way the generated handler
// does: read the request, then serve. It returns the request as the handler
// read it and the context the handler ran with.
func runStream(t *testing.T, i *Interceptor, ctx context.Context, method string, req proto.Message) (proto.Message, context.Context, error) {
	t.Helper()

	got := req.ProtoReflect().New().Interface()
	var handlerCtx context.Context
	handler := func(_ any, stream grpc.ServerStream) error {
		if err := stream.RecvMsg(got); err != nil {
			return err
		}
		handlerCtx = stream.Context()
		return nil
	}
	info := &grpc.StreamServerInfo{FullMethod: method, IsServerStream: true}
	err := i.Stream()(nil, &fakeStream{ctx: ctx, req: req}, info, handler)
	return got, handlerCtx, err
}

// The policy table does not care whether a method streams, so a unary
// method's entry stands in for a Watch RPC here.
func TestStreamIsAuthorizedOnItsRequest(t *testing.T) {
	i, _ := harness(t)

	got, ctx, err := runStream(t, i, withToken(context.Background()),
		"/music_room.v1.UserService/GetFriends", &pb.GetFriendsRequest{})
	if err != nil {
		t.Fatalf("err=%v", err)
	}
	if id := got.(*pb.GetFriendsRequest).GetUserId(); id != callerID {
		t.Errorf("user_id = %d, want the caller stamped in (%d)", id, callerID)
	}
	if identity, ok := authn.FromContext(ctx); !ok || identity.UserID != callerID {
		t.Errorf("handler context has identity %+v (present=%v), want the caller", identity, ok)
	}
}

func TestStreamWithoutTokenIsUnauthenticated(t *testing.T) {
	i, _ := harness(t)

	_, ctx, err := runStream(t, i, context.Background(),
		"/music_room.v1.UserService/GetFriends", &pb.GetFriendsRequest{})
	assertCode(t, err, codes.Unauthenticated)
	if ctx != nil {
		t.Error("the handler went on serving after a denied read")
	}
}

func TestStreamDeniedReadIsNotFound(t *testing.T) {
	i, checker := harness(t)
	checker.allow = false

	_, _, err := runStream(t, i, withToken(context.Background()),
		"/music_room.v1.PlaylistService/GetPlaylist", &pb.GetPlaylistRequest{PlaylistPublicId: otherPublicID})
	assertCode(t, err, codes.NotFound)
}

func TestClientStreamsAreDeniedExceptReflection(t *testing.T) {
	i, _ := harness(t)

	handler := func(any, grpc.ServerStream) error { return nil }
	err := i.Stream()(nil, nil, &grpc.StreamServerInfo{
		FullMethod: "/music_room.v1.EventService/SomeFutureStream", IsClientStream: true,
	}, handler)
	assertCode(t, err, codes.PermissionDenied)

	err = i.Stream()(nil, nil,
		&grpc.StreamServerInfo{FullMethod: "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"}, handler)
	if err != nil {
		t.Errorf("reflection must stay usable: %v", err)
	}
}

// recordingActivityLog hands each logged row back over a channel, since
// logActivity writes from its own goroutine.
type recordingActivityLog struct {
	rows chan sqlc.CreateActivityLogParams
}

func (r recordingActivityLog) CreateActivityLog(_ context.Context, params sqlc.CreateActivityLogParams) (sqlc.ActivityLog, error) {
	r.rows <- params
	return sqlc.ActivityLog{}, nil
}

func (r recordingActivityLog) next(t *testing.T) sqlc.CreateActivityLogParams {
	t.Helper()
	select {
	case params := <-r.rows:
		return params
	case <-time.After(2 * time.Second):
		t.Fatal("no activity log row written")
		return sqlc.CreateActivityLogParams{}
	}
}

// V.6: an authenticated call is logged against its session's device, which is
// what fills platform_snapshot/app_version_snapshot. A call with no session, or
// a session not yet bound to a device, logs device_id NULL -- never device 0.
func TestActivityLogCarriesTheSessionDevice(t *testing.T) {
	cases := []struct {
		name       string
		identity   authn.Identity
		withToken  bool
		wantDevice int64 // 0 = NULL
	}{
		{"bound session", authn.Identity{UserID: callerID, UserPublicID: callerPublicID, SessionID: 3, DeviceID: 9}, true, 9},
		{"session before RegisterDevice", authn.Identity{UserID: callerID, UserPublicID: callerPublicID, SessionID: 3}, true, 0},
		{"no session", authn.Identity{}, false, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := recordingActivityLog{rows: make(chan sqlc.CreateActivityLogParams, 1)}
			i := New(fakeAuth{identity: tc.identity}, &fakeChecker{allow: true}, fakeResolver{id: 42}, logger)

			ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-platform", "android"))
			if tc.withToken {
				ctx = metadata.NewIncomingContext(context.Background(),
					metadata.Pairs("authorization", "Bearer opaque-token", "x-platform", "android"))
			}
			handler := func(context.Context, any) (any, error) { return nil, nil }
			_, _ = i.Unary()(ctx, &pb.GetFriendsRequest{},
				&grpc.UnaryServerInfo{FullMethod: "/music_room.v1.UserService/GetFriends"}, handler)

			row := logger.next(t)
			if got := row.DeviceID; got.Valid != (tc.wantDevice != 0) || got.Int64 != tc.wantDevice {
				t.Errorf("device_id = %+v, want %d (0 = NULL)", got, tc.wantDevice)
			}
			// The headers are recorded either way: they are all a call with
			// no device has to say what it ran on.
			if string(row.Metadata) != `{"x-platform":"android"}` {
				t.Errorf("metadata = %s", row.Metadata)
			}
		})
	}
}
