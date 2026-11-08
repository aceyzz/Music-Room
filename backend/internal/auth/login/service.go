package login

import (
	"context"
	"errors"
	"strings"
	"time"

	"example.com/music-app/internal/session"
	"example.com/music-app/internal/user"
)

var (
	ErrInvalidCredentials = errors.New("invalid credentials")
	ErrTooManyAttempts    = errors.New("too many login attempts")
)

const (
	DefaultSessionTTL = 30 * 24 * time.Hour

	MaxFailures   = 5
	FailureWindow = 15 * time.Minute

	// MaxFailuresPerIP caps the failures from one address in FailureWindow,
	// whatever the email: MaxFailures alone lets one machine try a password on
	// every account. High enough for a shared network (a school, a café).
	MaxFailuresPerIP = 20
)

type Verifier interface {
	Verify(password, encodedHash string) error
}

type TokenGenerator interface {
	NewSessionToken() (token string, hash []byte, err error)
}

type CredentialsFinder interface {
	FindCredentialsByEmail(ctx context.Context, email string) (user.Credentials, error)
}

type SessionCreator interface {
	Create(ctx context.Context, userID int64, tokenHash []byte, expiresAt time.Time) (session.Session, error)
}

type AttemptStore interface {
	Record(ctx context.Context, email, ip string, succeeded bool, reason string) error
	CountRecentFailures(ctx context.Context, email string, since time.Time) (int64, error)
	CountRecentFailuresFromIP(ctx context.Context, ip string, since time.Time) (int64, error)
}

type Result struct {
	SessionToken  string
	ExpiresAt     time.Time
	UserPublicID  string
	DisplayName   string
	Email         string
	EmailVerified bool
}

type Service struct {
	users    CredentialsFinder
	sessions SessionCreator
	verifier Verifier
	tokens   TokenGenerator
	attempts AttemptStore
	ttl      time.Duration
	now      func() time.Time
}

func NewService(users CredentialsFinder, sessions SessionCreator, verifier Verifier, tokens TokenGenerator, attempts AttemptStore, ttl time.Duration) *Service {
	if ttl <= 0 {
		ttl = DefaultSessionTTL
	}
	return &Service{
		users:    users,
		sessions: sessions,
		verifier: verifier,
		tokens:   tokens,
		attempts: attempts,
		ttl:      ttl,
		now:      time.Now,
	}
}

// Login signs in with email and password. ip is the caller's address
// (clientip), "" when unknown: then only the per-email limit applies.
func (s *Service) Login(ctx context.Context, email, password, ip string) (Result, error) {
	email = strings.TrimSpace(email)
	now := s.now()
	if ip != "" {
		failures, err := s.attempts.CountRecentFailuresFromIP(ctx, ip, now.Add(-FailureWindow))
		if err != nil {
			return Result{}, err
		}
		if failures >= MaxFailuresPerIP {
			return Result{}, ErrTooManyAttempts
		}
	}

	failures, err := s.attempts.CountRecentFailures(ctx, email, now.Add(-FailureWindow))
	if err != nil {
		return Result{}, err
	}
	if failures >= MaxFailures {
		return Result{}, ErrTooManyAttempts
	}

	creds, err := s.users.FindCredentialsByEmail(ctx, email)
	if errors.Is(err, user.ErrNotFound) {
		return Result{}, s.fail(ctx, email, ip, "unknown_email")
	}
	if err != nil {
		return Result{}, err
	}

	if !creds.HasPassword {
		return Result{}, s.fail(ctx, email, ip, "no_password")
	}
	if creds.Status != "active" {
		return Result{}, s.fail(ctx, email, ip, "inactive")
	}
	if err := s.verifier.Verify(password, creds.PasswordHash); err != nil {
		return Result{}, s.fail(ctx, email, ip, "bad_password")
	}

	if err := s.attempts.Record(ctx, email, ip, true, ""); err != nil {
		return Result{}, err
	}

	token, hash, err := s.tokens.NewSessionToken()
	if err != nil {
		return Result{}, err
	}

	sess, err := s.sessions.Create(ctx, creds.ID, hash, now.Add(s.ttl))
	if err != nil {
		return Result{}, err
	}

	return Result{
		SessionToken:  token,
		ExpiresAt:     sess.ExpiresAt,
		UserPublicID:  creds.PublicID,
		DisplayName:   creds.DisplayName,
		Email:         creds.Email,
		EmailVerified: creds.EmailVerified,
	}, nil
}

func (s *Service) fail(ctx context.Context, email, ip, reason string) error {
	if err := s.attempts.Record(ctx, email, ip, false, reason); err != nil {
		return err
	}
	return ErrInvalidCredentials
}
