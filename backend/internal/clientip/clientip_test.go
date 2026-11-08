package clientip

import (
	"context"
	"net"
	"testing"

	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
)

func call(peerAddr, forwarded string) context.Context {
	ctx := context.Background()
	if peerAddr != "" {
		addr, err := net.ResolveTCPAddr("tcp", peerAddr)
		if err != nil {
			panic(err)
		}
		ctx = peer.NewContext(ctx, &peer.Peer{Addr: addr})
	}
	if forwarded != "" {
		ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("x-forwarded-for", forwarded))
	}
	return ctx
}

func TestFromContext(t *testing.T) {
	for _, c := range []struct {
		name, peer, forwarded, want string
	}{
		{"native gRPC client", "203.0.113.7:51000", "", "203.0.113.7"},
		{"native client cannot forge its address", "203.0.113.7:51000", "198.51.100.1", "203.0.113.7"},
		{"through the gateway", "127.0.0.1:40000", "198.51.100.1", "198.51.100.1"},
		{"gateway: the entry it appended, not the client's", "127.0.0.1:40000", "10.0.0.1, 198.51.100.1", "198.51.100.1"},
		{"loopback without a forwarded address", "127.0.0.1:40000", "", "127.0.0.1"},
		{"IPv6 loopback", "[::1]:40000", "2001:db8::1", "2001:db8::1"},
		{"no peer", "", "", ""},
	} {
		if got := FromContext(call(c.peer, c.forwarded)); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
