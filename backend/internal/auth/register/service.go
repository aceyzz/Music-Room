package register

import (
	"context"
	"errors"
	"net/mail"
	"strings"

	"example.com/music-app/internal/user"
)

var (
	ErrEmailInvalid       = errors.New("email invalide")
	ErrPasswordTooShort   = errors.New("mot de passe trop court")
	ErrDisplayNameInvalid = errors.New("display name invalide")
)

// Plancher absolu, fallback si non configuré
const DefaultMinPasswordLen = 8

// Hasher est ce dont ce service a besoin du package security : rien de plus.
// L'interface est déclarée ici, côté consommateur, pour que register ne
// dépende pas d'un type concret.
type Hasher interface {
	Hash(password string) (string, error)
}

// UserCreator est la part du repository que ce service utilise.
type UserCreator interface {
	Create(ctx context.Context, displayName, email, passwordHash string) (user.User, error)
}

type Service struct {
	users          UserCreator
	hasher         Hasher
	minPasswordLen int
}

func NewService(users UserCreator, hasher Hasher, minPasswordLen int) *Service {
	if minPasswordLen < DefaultMinPasswordLen {
		minPasswordLen = DefaultMinPasswordLen
	}
	return &Service{
		users:          users,
		hasher:         hasher,
		minPasswordLen: minPasswordLen,
	}
}

// Register valide les entrées, hashe le mot de passe et crée le compte.
func (s *Service) Register(ctx context.Context, email, password, displayName string) (user.User, error) {
	email = strings.TrimSpace(email)
	displayName = strings.TrimSpace(displayName)

	if _, err := mail.ParseAddress(email); err != nil {
		return user.User{}, ErrEmailInvalid
	}
	if len(password) < s.minPasswordLen {
		return user.User{}, ErrPasswordTooShort
	}
	if displayName == "" {
		return user.User{}, ErrDisplayNameInvalid
	}

	hash, err := s.hasher.Hash(password)
	if err != nil {
		return user.User{}, err
	}

	return s.users.Create(ctx, displayName, email, hash)
}
