package onetimecode

import (
	"context"
	"crypto/subtle"
	"errors"
	"time"

	"example.com/music-app/internal/token"
)

var (
	ErrInvalidCode     = errors.New("invalid code")
	ErrTooManyRequests = errors.New("too many code requests")
)

const (
	DefaultTTL         = 15 * time.Minute
	DefaultMaxAttempts = 5

	ShortWindow    = time.Minute
	ShortWindowMax = 1
	LongWindow     = time.Hour
	LongWindowMax  = 5
)

type Store interface {
	IssueCode(ctx context.Context, userID int64, purpose token.Purpose, tokenHash []byte, expiresAt time.Time) error
	UseCodeAttempt(ctx context.Context, userID int64, purpose token.Purpose, maxAttempts int16) (int64, []byte, error)
	Consume(ctx context.Context, tokenID int64) (bool, error)
	CountRecentCodes(ctx context.Context, userID int64, purpose token.Purpose, shortSince, longSince time.Time) (int64, int64, error)
}

type Generator interface {
	NewEmailCode() (code string, hash []byte, err error)
	HashSessionToken(code string) []byte
}

type Service struct {
	store       Store
	codes       Generator
	ttl         time.Duration
	maxAttempts int16
	now         func() time.Time
}

func NewService(store Store, codes Generator, ttl time.Duration, maxAttempts int) *Service {
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	if maxAttempts <= 0 {
		maxAttempts = DefaultMaxAttempts
	}
	return &Service{
		store:       store,
		codes:       codes,
		ttl:         ttl,
		maxAttempts: int16(maxAttempts),
		now:         time.Now,
	}
}

func (s *Service) TTL() time.Duration {
	return s.ttl
}

func (s *Service) Issue(ctx context.Context, userID int64, purpose token.Purpose) (string, error) {
	now := s.now()

	short, long, err := s.store.CountRecentCodes(ctx, userID, purpose, now.Add(-ShortWindow), now.Add(-LongWindow))
	if err != nil {
		return "", err
	}
	if short >= ShortWindowMax || long >= LongWindowMax {
		return "", ErrTooManyRequests
	}

	code, hash, err := s.codes.NewEmailCode()
	if err != nil {
		return "", err
	}
	if err := s.store.IssueCode(ctx, userID, purpose, hash, now.Add(s.ttl)); err != nil {
		return "", err
	}
	return code, nil
}

func (s *Service) Check(ctx context.Context, userID int64, purpose token.Purpose, code string) error {
	tokenID, stored, err := s.store.UseCodeAttempt(ctx, userID, purpose, s.maxAttempts)
	if errors.Is(err, token.ErrNotFound) {
		return ErrInvalidCode
	}
	if err != nil {
		return err
	}

	if subtle.ConstantTimeCompare(s.codes.HashSessionToken(code), stored) != 1 {
		return ErrInvalidCode
	}

	consumed, err := s.store.Consume(ctx, tokenID)
	if err != nil {
		return err
	}
	if !consumed {
		return ErrInvalidCode
	}
	return nil
}
