package emailverif

import (
	"context"
	"errors"
	"fmt"
	"time"

	"example.com/music-app/internal/auth/onetimecode"
	"example.com/music-app/internal/mailer"
	"example.com/music-app/internal/token"
)

var (
	ErrInvalidCode     = onetimecode.ErrInvalidCode
	ErrAlreadyVerified = errors.New("email already verified")
)

type Codes interface {
	Issue(ctx context.Context, userID int64, purpose token.Purpose) (string, error)
	Check(ctx context.Context, userID int64, purpose token.Purpose, code string) error
	TTL() time.Duration
}

type Accounts interface {
	FindEmail(ctx context.Context, userID int64) (email string, verified bool, err error)
	MarkEmailVerified(ctx context.Context, userID int64) error
}

type Service struct {
	codes    Codes
	accounts Accounts
	mail     mailer.Mailer
}

func NewService(codes Codes, accounts Accounts, mail mailer.Mailer) *Service {
	return &Service{codes: codes, accounts: accounts, mail: mail}
}

func (s *Service) RequestCode(ctx context.Context, userID int64, email string) error {
	code, err := s.codes.Issue(ctx, userID, token.PurposeEmailVerification)
	if err != nil {
		return err
	}

	return s.mail.Send(ctx, mailer.Mail{
		To:      email,
		Subject: "Music Room - code de verification",
		Body: fmt.Sprintf(
			"Ton code de verification : %s\n\nIl expire dans %d minutes.",
			code, int(s.codes.TTL().Minutes()),
		),
	})
}

func (s *Service) Resend(ctx context.Context, userID int64) error {
	email, verified, err := s.accounts.FindEmail(ctx, userID)
	if err != nil {
		return err
	}
	if verified {
		return ErrAlreadyVerified
	}
	return s.RequestCode(ctx, userID, email)
}

func (s *Service) Verify(ctx context.Context, userID int64, code string) error {
	_, verified, err := s.accounts.FindEmail(ctx, userID)
	if err != nil {
		return err
	}
	if verified {
		return ErrAlreadyVerified
	}

	if err := s.codes.Check(ctx, userID, token.PurposeEmailVerification, code); err != nil {
		return err
	}

	return s.accounts.MarkEmailVerified(ctx, userID)
}
