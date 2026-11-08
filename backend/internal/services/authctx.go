package services

import (
	"context"
	"errors"
	"strings"

	"google.golang.org/grpc/metadata"
)

var errMissingToken = errors.New("missing session token")

const authHeader = "authorization"

// bearerToken extrait le token du header grpc "authorization: Bearer <token>".
// convention d'equipe (D15) : les metadonnees client passent en metadata,
// jamais dans le corps du message.
func bearerToken(ctx context.Context) (string, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return "", errMissingToken
	}

	values := md.Get(authHeader)
	if len(values) == 0 {
		return "", errMissingToken
	}

	// le prefixe est insensible a la casse selon la rfc.
	const prefix = "bearer "
	raw := values[0]
	if len(raw) <= len(prefix) || !strings.EqualFold(raw[:len(prefix)], prefix) {
		return "", errMissingToken
	}

	token := strings.TrimSpace(raw[len(prefix):])
	if token == "" {
		return "", errMissingToken
	}
	return token, nil
}
