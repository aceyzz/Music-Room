package interceptor

import (
	"context"
	"errors"
	"strings"

	"google.golang.org/grpc/metadata"
)

var errNoToken = errors.New("no session token in the request metadata")

// bearerToken reads "authorization: Bearer <token>" from the incoming
// metadata.
//
// The REST gateway reaches this too: grpc-gateway forwards an HTTP
// Authorization header into the gRPC metadata under the same unprefixed
// `authorization` key (every other permanent header arrives as
// `grpcgateway-<name>`), so one implementation covers both transports.
//
// internal/services has a near-identical parser. It stays there on purpose:
// Logout needs the raw token to hash and revoke, not an identity, and it is a
// public RPC precisely so that revoking an already-dead session is not an
// error. Sharing one function would make that handler depend on the
// authorization layer to do something that has nothing to do with authorization.
func bearerToken(ctx context.Context) (string, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return "", errNoToken
	}

	values := md.Get("authorization")
	if len(values) == 0 {
		return "", errNoToken
	}

	// RFC 7235: the scheme is case-insensitive.
	const prefix = "bearer "
	raw := values[0]
	if len(raw) <= len(prefix) || !strings.EqualFold(raw[:len(prefix)], prefix) {
		return "", errNoToken
	}

	token := strings.TrimSpace(raw[len(prefix):])
	if token == "" {
		return "", errNoToken
	}
	return token, nil
}
