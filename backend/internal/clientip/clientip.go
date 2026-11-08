// Package clientip names the address a gRPC call came from.
package clientip

import (
	"context"
	"net"
	"strings"

	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
)

// FromContext returns the caller's IP, "" when unknown.
//
// A call through the REST gateway arrives over loopback: the gateway dials the
// gRPC server in the same process (cmd/main.go). For those, the caller is the
// last x-forwarded-for entry, the one grpc-gateway appends from the HTTP
// connection; the ones before it are whatever the client sent. Any other call
// is a native gRPC client: its connection's address, and x-forwarded-for is
// ignored, since such a client could write any.
func FromContext(ctx context.Context) string {
	p, ok := peer.FromContext(ctx)
	if !ok || p.Addr == nil {
		return ""
	}
	host, _, err := net.SplitHostPort(p.Addr.String())
	if err != nil {
		return ""
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return ""
	}
	if ip.IsLoopback() {
		if forwarded := lastForwarded(ctx); forwarded != nil {
			return forwarded.String()
		}
	}
	return ip.String()
}

func lastForwarded(ctx context.Context) net.IP {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return nil
	}
	values := md.Get("x-forwarded-for")
	if len(values) == 0 {
		return nil
	}
	entries := strings.Split(values[len(values)-1], ",")
	return net.ParseIP(strings.TrimSpace(entries[len(entries)-1]))
}
