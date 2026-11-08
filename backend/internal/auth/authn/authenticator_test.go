package authn

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"example.com/music-app/internal/session"
)

// --- doublures ---------------------------------------------------------------

type fakeHasher struct{}

func (fakeHasher) HashSessionToken(token string) []byte {
	return []byte("hash-de-" + token)
}

type fakeFinder struct {
	details session.Details
	err     error
	gotHash []byte
	called  bool

	touchErr error
	touched  []int64
}

func (f *fakeFinder) Touch(ctx context.Context, sessionID int64) error {
	f.touched = append(f.touched, sessionID)
	return f.touchErr
}

func (f *fakeFinder) FindByHash(ctx context.Context, tokenHash []byte) (session.Details, error) {
	f.called = true
	f.gotHash = tokenHash
	if f.err != nil {
		return session.Details{}, f.err
	}
	return f.details, nil
}

// instant fixe : les tests ne dependent pas de l'heure reelle
var fixedNow = time.Date(2026, 8, 22, 12, 0, 0, 0, time.UTC)

// fenetre courte et explicite : les tests ne dependent pas du defaut
const testIdle = 24 * time.Hour

func newTestAuth(finder SessionStore) *Authenticator {
	a := NewAuthenticator(finder, fakeHasher{}, testIdle)
	a.now = func() time.Time { return fixedNow }
	return a
}

// session valide de reference
func validSession() session.Details {
	return session.Details{
		ID:           42,
		UserPublicID: "uuid-user",
		ExpiresAt:    fixedNow.Add(30 * 24 * time.Hour),
		LastUsedAt:   fixedNow.Add(-time.Second),
		UserStatus:   "active",
		DeviceID:     9,
	}
}

// --- tests -------------------------------------------------------------------

func TestAuthenticateResolvesIdentity(t *testing.T) {
	finder := &fakeFinder{details: validSession()}
	id, err := newTestAuth(finder).Authenticate(context.Background(), "token-clair")
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}

	if id.UserPublicID != "uuid-user" {
		t.Errorf("UserPublicID = %q", id.UserPublicID)
	}
	// l'appareil de la session suit l'identite : RegisterDevice et les
	// journaux d'activite le lisent d'ici
	if id.SessionID != 42 || id.DeviceID != 9 {
		t.Errorf("SessionID, DeviceID = %d, %d, want 42, 9", id.SessionID, id.DeviceID)
	}
	// la base ne recoit que l'empreinte, jamais le token clair
	if bytes.Equal(finder.gotHash, []byte("token-clair")) {
		t.Error("le token clair a ete transmis au repository")
	}
}

func TestAuthenticateRejects(t *testing.T) {
	revoked := validSession()
	revoked.IsRevoked = true
	revoked.RevokedAt = fixedNow.Add(-time.Hour)

	expired := validSession()
	expired.ExpiresAt = fixedNow.Add(-time.Second)

	suspended := validSession()
	suspended.UserStatus = "suspended"

	idle := validSession()
	idle.LastUsedAt = fixedNow.Add(-testIdle - time.Second)

	cases := []struct {
		name   string
		finder *fakeFinder
		want   error
	}{
		{"token inconnu", &fakeFinder{err: session.ErrNotFound}, ErrUnknownToken},
		{"session revoquee", &fakeFinder{details: revoked}, ErrRevoked},
		{"session expiree", &fakeFinder{details: expired}, ErrExpired},
		{"compte suspendu", &fakeFinder{details: suspended}, ErrAccountInactive},
		{"session inactive", &fakeFinder{details: idle}, ErrIdle},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := newTestAuth(tc.finder).Authenticate(context.Background(), "token-clair")
			if !errors.Is(err, tc.want) {
				t.Fatalf("attendu %v, got %v", tc.want, err)
			}
		})
	}
}

func TestAuthenticateRejectsEmptyToken(t *testing.T) {
	finder := &fakeFinder{details: validSession()}

	_, err := newTestAuth(finder).Authenticate(context.Background(), "")
	if !errors.Is(err, ErrUnknownToken) {
		t.Fatalf("attendu ErrUnknownToken, got %v", err)
	}
	if finder.called {
		t.Error("la base a ete touchee malgre un token vide")
	}
}

func TestExpiryIsExclusive(t *testing.T) {
	// expire exactement maintenant : doit etre refuse, pas accepte
	atLimit := validSession()
	atLimit.ExpiresAt = fixedNow

	_, err := newTestAuth(&fakeFinder{details: atLimit}).Authenticate(context.Background(), "token-clair")
	if !errors.Is(err, ErrExpired) {
		t.Fatalf("une session expirant pile maintenant doit etre refusee, got %v", err)
	}
}

func TestAuthenticatePropagatesRepositoryError(t *testing.T) {
	boom := errors.New("db down")

	_, err := newTestAuth(&fakeFinder{err: boom}).Authenticate(context.Background(), "token-clair")
	if !errors.Is(err, boom) {
		t.Fatalf("attendu l'erreur du repository, got %v", err)
	}
}

func TestIdleIsExclusive(t *testing.T) {
	// inactive depuis exactement la fenetre : refusee, comme l'expiration
	atLimit := validSession()
	atLimit.LastUsedAt = fixedNow.Add(-testIdle)

	_, err := newTestAuth(&fakeFinder{details: atLimit}).Authenticate(context.Background(), "token-clair")
	if !errors.Is(err, ErrIdle) {
		t.Fatalf("une session inactive pile depuis la fenetre doit etre refusee, got %v", err)
	}
}

func TestTouchOnlyPastInterval(t *testing.T) {
	cases := []struct {
		name      string
		lastUsed  time.Duration
		wantTouch bool
	}{
		{"utilisee il y a une seconde", time.Second, false},
		{"utilisee il y a pile une minute", time.Minute, true},
		{"utilisee il y a une heure", time.Hour, true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			details := validSession()
			details.LastUsedAt = fixedNow.Add(-tc.lastUsed)
			finder := &fakeFinder{details: details}

			if _, err := newTestAuth(finder).Authenticate(context.Background(), "token-clair"); err != nil {
				t.Fatalf("Authenticate: %v", err)
			}
			if got := len(finder.touched) == 1; got != tc.wantTouch {
				t.Fatalf("touched = %v, attendu touch = %v", finder.touched, tc.wantTouch)
			}
			if tc.wantTouch && finder.touched[0] != details.ID {
				t.Errorf("touch sur la session %d, attendu %d", finder.touched[0], details.ID)
			}
		})
	}
}

func TestRejectedSessionIsNotTouched(t *testing.T) {
	// une session refusee ne doit pas voir sa fenetre prolongee : sinon une
	// requete sur une session inactive la ressusciterait pour la suivante
	idle := validSession()
	idle.LastUsedAt = fixedNow.Add(-testIdle - time.Hour)
	finder := &fakeFinder{details: idle}

	_, _ = newTestAuth(finder).Authenticate(context.Background(), "token-clair")
	if len(finder.touched) != 0 {
		t.Fatalf("session refusee touchee : %v", finder.touched)
	}
}

func TestTouchFailureDoesNotReject(t *testing.T) {
	details := validSession()
	details.LastUsedAt = fixedNow.Add(-time.Hour)
	finder := &fakeFinder{details: details, touchErr: errors.New("db down")}

	if _, err := newTestAuth(finder).Authenticate(context.Background(), "token-clair"); err != nil {
		t.Fatalf("un echec de touch ne doit pas refuser la requete, got %v", err)
	}
}
