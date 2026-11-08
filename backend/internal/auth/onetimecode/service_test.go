package onetimecode

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"example.com/music-app/internal/token"
)

type fakeCodes struct{}

func (fakeCodes) NewEmailCode() (string, []byte, error) {
	return "123456", []byte("hash-de-123456"), nil
}

func (fakeCodes) HashSessionToken(code string) []byte {
	return []byte("hash-de-" + code)
}

type fakeStore struct {
	issuedUserID  int64
	issuedPurpose token.Purpose
	issuedHash    []byte
	issuedExpiry  time.Time

	attemptUserID  int64
	attemptPurpose token.Purpose
	attemptMax     int16
	storedHash     []byte
	attemptErr     error

	consumeOK     bool
	consumeCalled bool

	shortCount   int64
	longCount    int64
	countedShort time.Time
	countedLong  time.Time
}

func (f *fakeStore) IssueCode(ctx context.Context, userID int64, purpose token.Purpose, tokenHash []byte, expiresAt time.Time) error {
	f.issuedUserID = userID
	f.issuedPurpose = purpose
	f.issuedHash = tokenHash
	f.issuedExpiry = expiresAt
	return nil
}

func (f *fakeStore) UseCodeAttempt(ctx context.Context, userID int64, purpose token.Purpose, maxAttempts int16) (int64, []byte, error) {
	f.attemptUserID = userID
	f.attemptPurpose = purpose
	f.attemptMax = maxAttempts
	if f.attemptErr != nil {
		return 0, nil, f.attemptErr
	}
	return 7, f.storedHash, nil
}

func (f *fakeStore) Consume(ctx context.Context, tokenID int64) (bool, error) {
	f.consumeCalled = true
	return f.consumeOK, nil
}

func (f *fakeStore) CountRecentCodes(ctx context.Context, userID int64, purpose token.Purpose, shortSince, longSince time.Time) (int64, int64, error) {
	f.countedShort = shortSince
	f.countedLong = longSince
	return f.shortCount, f.longCount, nil
}

var fixedNow = time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)

func newTestService(store Store) *Service {
	s := NewService(store, fakeCodes{}, DefaultTTL, DefaultMaxAttempts)
	s.now = func() time.Time { return fixedNow }
	return s
}

func TestIssueStoresHashOnly(t *testing.T) {
	store := &fakeStore{}

	code, err := newTestService(store).Issue(context.Background(), 42, token.PurposePasswordReset)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	if code != "123456" {
		t.Errorf("code = %q", code)
	}
	if bytes.Equal(store.issuedHash, []byte("123456")) {
		t.Error("le code en clair a ete stocke")
	}
	if store.issuedUserID != 42 || store.issuedPurpose != token.PurposePasswordReset {
		t.Errorf("emis pour %d / %q", store.issuedUserID, store.issuedPurpose)
	}
	if !store.issuedExpiry.Equal(fixedNow.Add(DefaultTTL)) {
		t.Errorf("expiration = %v", store.issuedExpiry)
	}
}

func TestCheckConsumesValidCode(t *testing.T) {
	store := &fakeStore{storedHash: []byte("hash-de-123456"), consumeOK: true}

	if err := newTestService(store).Check(context.Background(), 42, token.PurposeEmailVerification, "123456"); err != nil {
		t.Fatalf("Check: %v", err)
	}

	if !store.consumeCalled {
		t.Error("code valide non consomme")
	}
	if store.attemptUserID != 42 || store.attemptPurpose != token.PurposeEmailVerification {
		t.Errorf("essai pour %d / %q", store.attemptUserID, store.attemptPurpose)
	}
	if store.attemptMax != DefaultMaxAttempts {
		t.Errorf("max essais = %d", store.attemptMax)
	}
}

func TestCheckRejects(t *testing.T) {
	cases := []struct {
		name  string
		store *fakeStore
	}{
		{"mauvais code", &fakeStore{storedHash: []byte("hash-de-999999"), consumeOK: true}},
		{"aucun code utilisable", &fakeStore{attemptErr: token.ErrNotFound}},
		{"course perdue sur consume", &fakeStore{storedHash: []byte("hash-de-123456"), consumeOK: false}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := newTestService(tc.store).Check(context.Background(), 42, token.PurposePasswordReset, "123456")
			if !errors.Is(err, ErrInvalidCode) {
				t.Fatalf("attendu ErrInvalidCode, got %v", err)
			}
		})
	}
}

func TestWrongCodeIsNotConsumed(t *testing.T) {
	store := &fakeStore{storedHash: []byte("hash-de-999999"), consumeOK: true}

	_ = newTestService(store).Check(context.Background(), 42, token.PurposePasswordReset, "123456")

	if store.consumeCalled {
		t.Error("un mauvais code a consomme le token")
	}
}

func TestCheckPropagatesStoreError(t *testing.T) {
	boom := errors.New("db down")

	err := newTestService(&fakeStore{attemptErr: boom}).Check(context.Background(), 42, token.PurposePasswordReset, "123456")
	if !errors.Is(err, boom) {
		t.Fatalf("attendu l'erreur du store, got %v", err)
	}
}

func TestZeroConfigFallsBackToDefaults(t *testing.T) {
	store := &fakeStore{storedHash: []byte("hash-de-123456"), consumeOK: true}
	s := NewService(store, fakeCodes{}, 0, 0)
	s.now = func() time.Time { return fixedNow }

	if _, err := s.Issue(context.Background(), 42, token.PurposePasswordReset); err != nil {
		t.Fatalf("Issue: %v", err)
	}
	_ = s.Check(context.Background(), 42, token.PurposePasswordReset, "123456")

	if !store.issuedExpiry.Equal(fixedNow.Add(DefaultTTL)) {
		t.Errorf("ttl par defaut non applique: %v", store.issuedExpiry)
	}
	if store.attemptMax != DefaultMaxAttempts {
		t.Errorf("max essais par defaut non applique: %d", store.attemptMax)
	}
}

func TestIssueRejectsTooManyRequests(t *testing.T) {
	cases := []struct {
		name  string
		store *fakeStore
	}{
		{"deja un code dans la minute", &fakeStore{shortCount: ShortWindowMax}},
		{"quota horaire atteint", &fakeStore{longCount: LongWindowMax}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := newTestService(tc.store).Issue(context.Background(), 42, token.PurposePasswordReset)
			if !errors.Is(err, ErrTooManyRequests) {
				t.Fatalf("attendu ErrTooManyRequests, got %v", err)
			}
			if tc.store.issuedHash != nil {
				t.Error("code emis malgre la limite")
			}
		})
	}
}

func TestIssueCountsFromNow(t *testing.T) {
	store := &fakeStore{}

	if _, err := newTestService(store).Issue(context.Background(), 42, token.PurposePasswordReset); err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if !store.countedShort.Equal(fixedNow.Add(-ShortWindow)) || !store.countedLong.Equal(fixedNow.Add(-LongWindow)) {
		t.Errorf("fenetres = %v / %v", store.countedShort, store.countedLong)
	}
}
