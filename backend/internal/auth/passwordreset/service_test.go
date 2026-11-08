package passwordreset

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"example.com/music-app/internal/mailer"
	"example.com/music-app/internal/token"
	"example.com/music-app/internal/user"
)

type fakeUsers struct {
	creds   user.Credentials
	findErr error

	resetUserID int64
	resetHash   string
	resetCalled bool
}

func (f *fakeUsers) FindCredentialsByEmail(ctx context.Context, email string) (user.Credentials, error) {
	if f.findErr != nil {
		return user.Credentials{}, f.findErr
	}
	return f.creds, nil
}

func (f *fakeUsers) ResetPassword(ctx context.Context, userID int64, passwordHash string) error {
	f.resetCalled = true
	f.resetUserID = userID
	f.resetHash = passwordHash
	return nil
}

type fakeCodes struct {
	issuedUserID  int64
	issuedPurpose token.Purpose
	issueCalled   bool

	checkErr     error
	checkPurpose token.Purpose
	checkCalled  bool
}

func (f *fakeCodes) Issue(ctx context.Context, userID int64, purpose token.Purpose) (string, error) {
	f.issueCalled = true
	f.issuedUserID = userID
	f.issuedPurpose = purpose
	return "123456", nil
}

func (f *fakeCodes) Check(ctx context.Context, userID int64, purpose token.Purpose, code string) error {
	f.checkCalled = true
	f.checkPurpose = purpose
	return f.checkErr
}

func (f *fakeCodes) TTL() time.Duration {
	return 15 * time.Minute
}

type fakeHasher struct{}

func (fakeHasher) Hash(password string) (string, error) {
	return "hash-de-" + password, nil
}

type fakeMailer struct {
	sent   mailer.Mail
	called bool
}

func (f *fakeMailer) Send(ctx context.Context, m mailer.Mail) error {
	f.called = true
	f.sent = m
	return nil
}

func activeCreds() user.Credentials {
	return user.Credentials{ID: 42, Email: "neo@matrix.io", Status: "active", HasPassword: true}
}

func newTestService(users Users, codes Codes, mail mailer.Mailer) *Service {
	return NewService(users, codes, fakeHasher{}, mail, 8)
}

func TestRequestResetSendsCode(t *testing.T) {
	codes := &fakeCodes{}
	mail := &fakeMailer{}

	if err := newTestService(&fakeUsers{creds: activeCreds()}, codes, mail).RequestReset(context.Background(), " neo@matrix.io "); err != nil {
		t.Fatalf("RequestReset: %v", err)
	}

	if codes.issuedUserID != 42 || codes.issuedPurpose != token.PurposePasswordReset {
		t.Errorf("code emis pour %d / %q", codes.issuedUserID, codes.issuedPurpose)
	}
	if mail.sent.To != "neo@matrix.io" || !strings.Contains(mail.sent.Body, "123456") {
		t.Errorf("mail = %+v", mail.sent)
	}
}

func TestRequestResetIsSilentForUnusableAccounts(t *testing.T) {
	suspended := activeCreds()
	suspended.Status = "suspended"

	cases := []struct {
		name  string
		users *fakeUsers
	}{
		{"email inconnu", &fakeUsers{findErr: user.ErrNotFound}},
		{"compte suspendu", &fakeUsers{creds: suspended}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			codes := &fakeCodes{}
			mail := &fakeMailer{}

			if err := newTestService(tc.users, codes, mail).RequestReset(context.Background(), "x@y.z"); err != nil {
				t.Fatalf("attendu nil, got %v", err)
			}
			if codes.issueCalled || mail.called {
				t.Error("code emis pour un compte inutilisable")
			}
		})
	}
}

func TestResetChangesPassword(t *testing.T) {
	users := &fakeUsers{creds: activeCreds()}
	codes := &fakeCodes{}

	if err := newTestService(users, codes, &fakeMailer{}).Reset(context.Background(), "neo@matrix.io", "123456", "nouveau-mdp"); err != nil {
		t.Fatalf("Reset: %v", err)
	}

	if codes.checkPurpose != token.PurposePasswordReset {
		t.Errorf("purpose = %q", codes.checkPurpose)
	}
	if !users.resetCalled || users.resetUserID != 42 {
		t.Fatalf("mot de passe non change (called=%v id=%d)", users.resetCalled, users.resetUserID)
	}
	if users.resetHash == "nouveau-mdp" {
		t.Error("mot de passe en clair transmis au repository")
	}
}

func TestResetAllowsAccountWithoutPassword(t *testing.T) {
	oauthOnly := activeCreds()
	oauthOnly.HasPassword = false
	users := &fakeUsers{creds: oauthOnly}

	if err := newTestService(users, &fakeCodes{}, &fakeMailer{}).Reset(context.Background(), "neo@matrix.io", "123456", "nouveau-mdp"); err != nil {
		t.Fatalf("Reset: %v", err)
	}
	if !users.resetCalled {
		t.Error("un compte oauth doit pouvoir definir un mot de passe")
	}
}

func TestResetRejectsShortPasswordBeforeCheckingCode(t *testing.T) {
	codes := &fakeCodes{}

	err := newTestService(&fakeUsers{creds: activeCreds()}, codes, &fakeMailer{}).Reset(context.Background(), "neo@matrix.io", "123456", "court")
	if !errors.Is(err, ErrPasswordTooShort) {
		t.Fatalf("attendu ErrPasswordTooShort, got %v", err)
	}
	if codes.checkCalled {
		t.Error("un essai a ete consomme pour un mot de passe invalide")
	}
}

func TestResetRejects(t *testing.T) {
	suspended := activeCreds()
	suspended.Status = "suspended"

	cases := []struct {
		name  string
		users *fakeUsers
		codes *fakeCodes
	}{
		{"email inconnu", &fakeUsers{findErr: user.ErrNotFound}, &fakeCodes{}},
		{"compte suspendu", &fakeUsers{creds: suspended}, &fakeCodes{}},
		{"mauvais code", &fakeUsers{creds: activeCreds()}, &fakeCodes{checkErr: ErrInvalidCode}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := newTestService(tc.users, tc.codes, &fakeMailer{}).Reset(context.Background(), "neo@matrix.io", "123456", "nouveau-mdp")
			if !errors.Is(err, ErrInvalidCode) {
				t.Fatalf("attendu ErrInvalidCode, got %v", err)
			}
			if tc.users.resetCalled {
				t.Error("mot de passe change malgre l'echec")
			}
		})
	}
}

func TestMinPasswordLenCannotBeLowered(t *testing.T) {
	s := NewService(&fakeUsers{creds: activeCreds()}, &fakeCodes{}, fakeHasher{}, &fakeMailer{}, 3)

	if err := s.Reset(context.Background(), "neo@matrix.io", "123456", "1234567"); !errors.Is(err, ErrPasswordTooShort) {
		t.Fatalf("attendu ErrPasswordTooShort, got %v", err)
	}
}
