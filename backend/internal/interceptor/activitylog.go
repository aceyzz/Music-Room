package interceptor

import (
	"context"
	"encoding/json"
	"log"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/auth/authn"
	"example.com/music-app/internal/authz"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// ActivityLogger writes one row to activity_logs. The part of *sqlc.Queries
// used here, as an interface for the same reason Authenticator/Checker are:
// so a test can exercise Unary() without a database.
type ActivityLogger interface {
	CreateActivityLog(ctx context.Context, arg sqlc.CreateActivityLogParams) (sqlc.ActivityLog, error)
}

// activityHeaders are the request headers V.6 asks to be captured, copied
// into the JSONB `metadata` column on every call.
//
// They are the fallback, not the main record. An authenticated call is logged
// against its session's device (identity.DeviceID, bound by RegisterDevice),
// and CreateActivityLog snapshots platform and app_version from that row. The
// headers are all a failed login, an expired token, or a call made before the
// app registered its device has to say what it ran on.
var activityHeaders = []string{"x-platform", "x-device-model", "x-app-version"}

// requestMetadata collects activityHeaders present on the incoming call.
// Absent headers are simply omitted, not recorded as empty strings.
func requestMetadata(ctx context.Context) []byte {
	md, _ := metadata.FromIncomingContext(ctx)
	found := map[string]string{}
	for _, key := range activityHeaders {
		if values := md.Get(key); len(values) > 0 {
			found[key] = values[0]
		}
	}
	encoded, err := json.Marshal(found)
	if err != nil {
		return []byte("{}")
	}
	return encoded
}

// primaryResource says which object, if any, this call was about -- the
// first Requirement in the method's policy that names a type and actually
// resolved to an id, in table order. Deliberately NOT the request body: a
// security audit log kept for up to two years (00014_activity_logs.sql)
// must not become a second place secrets end up, so this reads back only
// what the interceptor itself already resolved and stamped (StampField) --
// never a raw field the client sent, which is exactly the boundary that
// keeps a password or a reset token out of it.
//
// req is re-reflected rather than passed the message enforce() already
// built: it is the same underlying proto message (Go passes it by pointer),
// so whatever Resolve stamped into it during authorize is still there to
// read back here, without threading a return value through every enforce
// call for the sole benefit of logging.
func primaryResource(method string, req any) (authz.ObjectType, int64) {
	policy, known := policies[method]
	if !known {
		return "", 0
	}
	message, err := requestMessage(req)
	if err != nil {
		return "", 0
	}
	for _, requirement := range policy.Require {
		if !requirement.Resolve {
			continue
		}
		id, err := int64Field(message, requirement.StampField())
		if err != nil || id <= 0 {
			continue // unresolved (denied before Resolve ran) or Optional and absent.
		}
		return requirement.Type, id
	}
	return "", 0
}

// logActivity records one call's outcome. Fire-and-forget: an audit log must
// never make the request it is describing slower or less reliable, so this
// runs in its own goroutine against its own timeout, detached from ctx
// (which is likely cancelled the moment the RPC returns to its caller).
//
// identity's zero value (ok=false) logs user_id as NULL -- itself the point
// for a rejected call, per activity_logs' own schema comment: "a failed
// login or an expired-token call has no authenticated user yet, and those
// are precisely the events worth logging."
func (i *Interceptor) logActivity(ctx context.Context, method string, req any, identity authn.Identity, ok bool, rpcErr error) {
	if i.activityLog == nil {
		return
	}
	params := sqlc.CreateActivityLogParams{
		Action:     method,
		ResultCode: pgtype.Int2{Int16: int16(status.Code(rpcErr)), Valid: true},
		Metadata:   requestMetadata(ctx),
	}
	if ok {
		params.UserID = pgtype.Int8{Int64: identity.UserID, Valid: true}
		if identity.DeviceID > 0 {
			params.DeviceID = pgtype.Int8{Int64: identity.DeviceID, Valid: true}
		}
	}
	if resourceType, resourceID := primaryResource(method, req); resourceID > 0 {
		params.ResourceType = pgtype.Text{String: string(resourceType), Valid: true}
		params.ResourceID = pgtype.Int8{Int64: resourceID, Valid: true}
	}

	go func() {
		bgCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := i.activityLog.CreateActivityLog(bgCtx, params); err != nil {
			log.Printf("activity log: %s: %v", method, err)
		}
	}()
}
