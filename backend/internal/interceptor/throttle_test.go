package interceptor

import (
	"context"
	"net"
	"testing"

	"example.com/music-app/internal/ratelimit"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestThrottleLimitsEachUserOnASocialRoute(t *testing.T) {
	const method = "/music_room.v1.UserService/BlockUser"
	const user, other = 900001, 900002

	for i := range 10 {
		if err := throttleUser(method, user); err != nil {
			t.Fatalf("call %d of the burst refused: %v", i+1, err)
		}
	}
	if status.Code(throttleUser(method, user)) != codes.ResourceExhausted {
		t.Fatal("the 11th call in a row was allowed")
	}
	if err := throttleUser(method, other); err != nil {
		t.Fatalf("another user shares the first one's budget: %v", err)
	}
	if err := throttleUser("/music_room.v1.EventService/CastVote", user); err != nil {
		t.Fatalf("a route without a limit was throttled: %v", err)
	}
}

func TestEveryLimitedRouteHasAPolicy(t *testing.T) {
	for method := range userLimits {
		if _, ok := policies[method]; !ok {
			t.Errorf("%s is limited but has no policy: the name is wrong, or the route is gone", method)
		}
	}
}

func callFrom(peerAddr, forwarded string) context.Context {
	addr, err := net.ResolveTCPAddr("tcp", peerAddr)
	if err != nil {
		panic(err)
	}
	ctx := peer.NewContext(context.Background(), &peer.Peer{Addr: addr})
	if forwarded != "" {
		ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("x-forwarded-for", forwarded))
	}
	return ctx
}

func TestThrottleIPCountsNativeAndGatewayCallsPerClient(t *testing.T) {
	i := &Interceptor{}
	if err := i.throttleIP(callFrom("203.0.113.7:51000", "")); err != nil {
		t.Fatalf("no limit set, yet refused: %v", err)
	}

	i.LimitPerIP(ratelimit.New(1, 2))
	native := callFrom("203.0.113.7:51000", "")
	viaGateway := callFrom("127.0.0.1:40000", "198.51.100.1")

	for range 2 {
		if err := i.throttleIP(native); err != nil {
			t.Fatalf("native gRPC burst refused: %v", err)
		}
	}
	if status.Code(i.throttleIP(native)) != codes.ResourceExhausted {
		t.Fatal("a native gRPC client past its burst was allowed")
	}
	// The gateway's own address is loopback: each REST client has its own budget.
	for range 2 {
		if err := i.throttleIP(viaGateway); err != nil {
			t.Fatalf("a REST client was counted with another: %v", err)
		}
	}
	if status.Code(i.throttleIP(viaGateway)) != codes.ResourceExhausted {
		t.Fatal("a REST client past its burst was allowed")
	}
}
