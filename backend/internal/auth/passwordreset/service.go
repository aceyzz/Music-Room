package passwordreset

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"example.com/music-app/internal/auth/onetimecode"
	"example.com/music-app/internal/auth/register"
	"example.com/music-app/internal/mailer"
	"example.com/music-app/internal/token"
	"example.com/music-app/internal/user"
)

var (
	ErrInvalidCode      = onetimecode.ErrInvalidCode
	ErrPasswordTooShort = register.ErrPasswordTooShort
)

type Users interface {
	FindCredentialsByEmail(ctx context.Context, email string) (user.Credentials, error)
	ResetPassword(ctx context.Context, userID int64, passwordHash string) error
}

type Codes interface {
	Issue(ctx context.Context, userID int64, purpose token.Purpose) (string, error)
	Check(ctx context.Context, userID int64, purpose token.Purpose, code string) error
	TTL() time.Duration
}

type Hasher interface {
	Hash(password string) (string, error)
}

type Service struct {
	users          Users
	codes          Codes
	hasher         Hasher
	mail           mailer.Mailer
	minPasswordLen int
}

func NewService(users Users, codes Codes, hasher Hasher, mail mailer.Mailer, minPasswordLen int) *Service {
	if minPasswordLen < register.DefaultMinPasswordLen {
		minPasswordLen = register.DefaultMinPasswordLen
	}
	return &Service{
		users:          users,
		codes:          codes,
		hasher:         hasher,
		mail:           mail,
		minPasswordLen: minPasswordLen,
	}
}

func (s *Service) RequestReset(ctx context.Context, email string) error {
	creds, err := s.users.FindCredentialsByEmail(ctx, strings.TrimSpace(email))
	if errors.Is(err, user.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if creds.Status != "active" {
		return nil
	}

	code, err := s.codes.Issue(ctx, creds.ID, token.PurposePasswordReset)
	if err != nil {
		return err
	}

	return s.mail.Send(ctx, mailer.Mail{
		To:      creds.Email,
		Subject: "Music Room - reinitialisation du mot de passe",
		Body: fmt.Sprintf(
			"Ton code de reinitialisation : %s\n\nIl expire dans %d minutes.\n\nSi tu n'es pas a l'origine de cette demande, ignore ce message.",
			code, int(s.codes.TTL().Minutes()),
		),
	})
}

func (s *Service) Reset(ctx context.Context, email, code, newPassword string) error {
	if len(newPassword) < s.minPasswordLen {
		return ErrPasswordTooShort
	}

	creds, err := s.users.FindCredentialsByEmail(ctx, strings.TrimSpace(email))
	if errors.Is(err, user.ErrNotFound) {
		return ErrInvalidCode
	}
	if err != nil {
		return err
	}
	if creds.Status != "active" {
		return ErrInvalidCode
	}

	if err := s.codes.Check(ctx, creds.ID, token.PurposePasswordReset, code); err != nil {
		return err
	}

	hash, err := s.hasher.Hash(newPassword)
	if err != nil {
		return err
	}

	return s.users.ResetPassword(ctx, creds.ID, hash)
}
