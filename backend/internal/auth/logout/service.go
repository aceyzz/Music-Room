package logout

import (
	"context"
	"errors"
)

var ErrMissingToken = errors.New("missing session token")

type TokenHasher interface {
	HashSessionToken(token string) []byte
}

type SessionRevoker interface {
	Revoke(ctx context.Context, tokenHash []byte) error
}

type Service struct {
	sessions SessionRevoker
	hasher   TokenHasher
}

func NewService(sessions SessionRevoker, hasher TokenHasher) *Service {
	return &Service{sessions: sessions, hasher: hasher}
}

// Logout revoque la session portant ce token.
// token inconnu ou deja revoque : succes silencieux.
// repondre autrement dirait au client quels tokens existent.
func (s *Service) Logout(ctx context.Context, token string) error {
	if token == "" {
		return ErrMissingToken
	}
	return s.sessions.Revoke(ctx, s.hasher.HashSessionToken(token))
}
