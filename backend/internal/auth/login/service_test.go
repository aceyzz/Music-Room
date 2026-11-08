package login

import (
	"context"
	"errors"
	"testing"
	"time"

	"example.com/music-app/internal/session"
	"example.com/music-app/internal/user"
)

type fakeFinder struct {
	creds user.Credentials
	err   error
}

func (f *fakeFinder) FindCredentialsByEmail(ctx context.Context, email string) (user.Credentials, error) {
	if f.err != nil {
		return user.Credentials{}, f.err
	}
	return f.creds, nil
}

type fakeVerifier struct {
	err    error
	called bool
}

func (f *fakeVerifier) Verify(password, encodedHash string) error {
	f.called = true
	return f.err
}

type fakeTokens struct{}

func (fakeTokens) NewSessionToken() (string, []byte, error) {
	return "token-clair", []byte("empreinte"), nil
}

type fakeSessions struct {
	gotUserID    int64
	gotHash      []byte
	gotExpiresAt time.Time
	called       bool
}

func (f *fakeSessions) Create(ctx context.Context, userID int64, tokenHash []byte, expiresAt time.Time) (session.Session, error) {
	f.called = true
	f.gotUserID = userID
	f.gotHash = tokenHash
	f.gotExpiresAt = expiresAt
	return session.Session{PublicID: "uuid-session", ExpiresAt: expiresAt}, nil
}

type attempt struct {
	succeeded bool
	reason    string
}

type fakeAttempts struct {
	failures       int64
	failuresFromIP int64
	countedAt      time.Time
	recorded       []attempt
}

func (f *fakeAttempts) Record(ctx context.Context, email, ip string, succeeded bool, reason string) error {
	f.recorded = append(f.recorded, attempt{succeeded, reason})
	return nil
}

func (f *fakeAttempts) CountRecentFailuresFromIP(ctx context.Context, ip string, since time.Time) (int64, error) {
	return f.failuresFromIP, nil
}

func (f *fakeAttempts) CountRecentFailures(ctx context.Context, email string, since time.Time) (int64, error) {
	f.countedAt = since
	return f.failures, nil
}

var fixedNow = time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)

func activeCreds() user.Credentials {
	return user.Credentials{
		ID:           42,
		PublicID:     "uuid-user",
		DisplayName:  "Neo",
		Email:        "neo@matrix.io",
		PasswordHash: "$argon2id$...",
		HasPassword:  true,
		Status:       "active",
	}
}

func newTestService(finder CredentialsFinder, sessions SessionCreator, verifier Verifier, attempts AttemptStore, ttl time.Duration) *Service {
	s := NewService(finder, sessions, verifier, fakeTokens{}, attempts, ttl)
	s.now = func() time.Time { return fixedNow }
	return s
}

func TestLoginCreatesSession(t *testing.T) {
	sessions := &fakeSessions{}
	verifier := &fakeVerifier{}
	attempts := &fakeAttempts{}

	res, err := newTestService(&fakeFinder{creds: activeCreds()}, sessions, verifier, attempts, DefaultSessionTTL).
		Login(context.Background(), " neo@matrix.io ", "hunter2hunter2", "")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}

	if res.SessionToken != "token-clair" {
		t.Errorf("token = %q", res.SessionToken)
	}
	if !verifier.called {
		t.Error("le mot de passe n'a pas ete verifie")
	}
	if sessions.gotUserID != 42 {
		t.Errorf("session creee pour le mauvais user: %d", sessions.gotUserID)
	}
	if string(sessions.gotHash) == "token-clair" {
		t.Error("le token clair a ete transmis au repository")
	}
	if !sessions.gotExpiresAt.Equal(fixedNow.Add(DefaultSessionTTL)) {
		t.Errorf("expiration = %v", sessions.gotExpiresAt)
	}
	if len(attempts.recorded) != 1 || !attempts.recorded[0].succeeded {
		t.Errorf("tentatives enregistrees = %+v", attempts.recorded)
	}
}

func TestLoginFailuresAreIndistinguishable(t *testing.T) {
	noPassword := activeCreds()
	noPassword.HasPassword = false

	suspended := activeCreds()
	suspended.Status = "suspended"

	cases := []struct {
		name     string
		finder   *fakeFinder
		verifier *fakeVerifier
		reason   string
	}{
		{"email inconnu", &fakeFinder{err: user.ErrNotFound}, &fakeVerifier{}, "unknown_email"},
		{"compte sans mot de passe", &fakeFinder{creds: noPassword}, &fakeVerifier{}, "no_password"},
		{"compte suspendu", &fakeFinder{creds: suspended}, &fakeVerifier{}, "inactive"},
		{"mauvais mot de passe", &fakeFinder{creds: activeCreds()}, &fakeVerifier{err: errors.New("mismatch")}, "bad_password"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sessions := &fakeSessions{}
			attempts := &fakeAttempts{}

			_, err := newTestService(tc.finder, sessions, tc.verifier, attempts, DefaultSessionTTL).
				Login(context.Background(), "neo@matrix.io", "peu-importe", "")
			if !errors.Is(err, ErrInvalidCredentials) {
				t.Fatalf("attendu ErrInvalidCredentials, got %v", err)
			}
			if err.Error() != "invalid credentials" {
				t.Fatalf("message distinctif: %q", err.Error())
			}
			if sessions.called {
				t.Error("une session a ete creee malgre l'echec")
			}
			if len(attempts.recorded) != 1 || attempts.recorded[0].succeeded || attempts.recorded[0].reason != tc.reason {
				t.Errorf("tentatives enregistrees = %+v", attempts.recorded)
			}
		})
	}
}

func TestLoginBlockedAfterMaxFailures(t *testing.T) {
	verifier := &fakeVerifier{}
	sessions := &fakeSessions{}
	attempts := &fakeAttempts{failures: MaxFailures}

	_, err := newTestService(&fakeFinder{creds: activeCreds()}, sessions, verifier, attempts, DefaultSessionTTL).
		Login(context.Background(), "neo@matrix.io", "hunter2hunter2", "")
	if !errors.Is(err, ErrTooManyAttempts) {
		t.Fatalf("attendu ErrTooManyAttempts, got %v", err)
	}
	if verifier.called {
		t.Error("mot de passe verifie malgre le blocage")
	}
	if len(attempts.recorded) != 0 {
		t.Error("une tentative bloquee a ete enregistree")
	}
	if !attempts.countedAt.Equal(fixedNow.Add(-FailureWindow)) {
		t.Errorf("fenetre = %v", attempts.countedAt)
	}
}

func TestTooManyFailuresFromOneAddressBlocks(t *testing.T) {
	verifier := &fakeVerifier{}
	attempts := &fakeAttempts{failuresFromIP: MaxFailuresPerIP}

	_, err := newTestService(&fakeFinder{creds: activeCreds()}, &fakeSessions{}, verifier, attempts, DefaultSessionTTL).
		Login(context.Background(), "neo@matrix.io", "hunter2hunter2", "198.51.100.1")
	if !errors.Is(err, ErrTooManyAttempts) {
		t.Fatalf("attendu ErrTooManyAttempts, got %v", err)
	}
	if verifier.called {
		t.Error("mot de passe verifie malgre le blocage")
	}
}

func TestUnknownAddressSkipsTheAddressLimit(t *testing.T) {
	attempts := &fakeAttempts{failuresFromIP: MaxFailuresPerIP}

	if _, err := newTestService(&fakeFinder{creds: activeCreds()}, &fakeSessions{}, &fakeVerifier{}, attempts, DefaultSessionTTL).
		Login(context.Background(), "neo@matrix.io", "hunter2hunter2", ""); err != nil {
		t.Fatalf("Login: %v", err)
	}
}

func TestZeroTTLFallsBackToDefault(t *testing.T) {
	sessions := &fakeSessions{}

	if _, err := newTestService(&fakeFinder{creds: activeCreds()}, sessions, &fakeVerifier{}, &fakeAttempts{}, 0).
		Login(context.Background(), "neo@matrix.io", "hunter2hunter2", ""); err != nil {
		t.Fatalf("Login: %v", err)
	}
	if !sessions.gotExpiresAt.Equal(fixedNow.Add(DefaultSessionTTL)) {
		t.Errorf("un ttl a zero doit retomber sur 30 jours, got %v", sessions.gotExpiresAt)
	}
}
