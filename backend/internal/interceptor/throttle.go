package interceptor

import (
	"context"
	"strconv"
	"time"

	"example.com/music-app/internal/clientip"
	"example.com/music-app/internal/ratelimit"
	"golang.org/x/time/rate"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// userLimits caps how often one user may call a social route, gRPC or REST:
// spamming friend requests, or walking the user directory with SearchUsers.
// Past it, RESOURCE_EXHAUSTED (429 through the gateway). A route not listed
// here is not limited per user.
//
// No minimum delay per pair after a decline, an unfriend or a block: blocking
// already stops every request from the blocked user, and this limit slows the
// rest. Unfriend and unblock delete their row, so the delay would need its own
// store, for little.
var userLimits = map[string]*ratelimit.Limiter{
	// 10 in a row, then one every 6 s: 10 a minute.
	"/music_room.v1.UserService/SendFriendRequest": ratelimit.New(rate.Every(6*time.Second), 10),
	"/music_room.v1.UserService/RemoveFriend":      ratelimit.New(rate.Every(6*time.Second), 10),
	"/music_room.v1.UserService/BlockUser":         ratelimit.New(rate.Every(6*time.Second), 10),
	"/music_room.v1.UserService/UnblockUser":       ratelimit.New(rate.Every(6*time.Second), 10),
	// One a second, 10 in a row: a search as the user types.
	"/music_room.v1.UserService/SearchUsers": ratelimit.New(1, 10),
}

// throttleUser takes one call from userID's budget on method, if it has one.
func throttleUser(method string, userID int64) error {
	limiter, ok := userLimits[method]
	if !ok || userID <= 0 {
		return nil
	}
	if !limiter.Allow(strconv.FormatInt(userID, 10)) {
		return errTooManyRequests
	}
	return nil
}

// LimitPerIP caps every call from one IP address, gRPC or REST: a coarse
// guard against one machine flooding the API. clientip finds the caller
// behind the gateway, so a REST call counts for the client, not the gateway.
// Unset, there is no such limit.
func (i *Interceptor) LimitPerIP(limiter *ratelimit.Limiter) {
	i.perIP = limiter
}

// throttleIP takes one call from the caller's address budget. Checked before
// anything else, and a refusal is not written to activity_logs: a flood would
// otherwise turn into as many database writes.
func (i *Interceptor) throttleIP(ctx context.Context) error {
	if i.perIP == nil {
		return nil
	}
	ip := clientip.FromContext(ctx)
	if ip == "" || i.perIP.Allow(ip) {
		return nil
	}
	return errTooManyRequests
}

var errTooManyRequests = status.Error(codes.ResourceExhausted, "too many requests, try again in a moment")
