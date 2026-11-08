package emailverif

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"example.com/music-app/internal/mailer"
	"example.com/music-app/internal/token"
)

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

type fakeAccounts struct {
	email      string
	verified   bool
	markCalled bool
}

func (f *fakeAccounts) FindEmail(ctx context.Context, userID int64) (string, bool, error) {
	return f.email, f.verified, nil
}

func (f *fakeAccounts) MarkEmailVerified(ctx context.Context, userID int64) error {
	f.markCalled = true
	return nil
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

func TestRequestCodeSendsMail(t *testing.T) {
	codes := &fakeCodes{}
	mail := &fakeMailer{}

	if err := NewService(codes, &fakeAccounts{}, mail).RequestCode(context.Background(), 42, "neo@matrix.io"); err != nil {
		t.Fatalf("RequestCode: %v", err)
	}

	if codes.issuedUserID != 42 || codes.issuedPurpose != token.PurposeEmailVerification {
		t.Errorf("code emis pour %d / %q", codes.issuedUserID, codes.issuedPurpose)
	}
	if mail.sent.To != "neo@matrix.io" {
		t.Errorf("destinataire = %q", mail.sent.To)
	}
	if !strings.Contains(mail.sent.Body, "123456") || !strings.Contains(mail.sent.Body, "15 minutes") {
		t.Errorf("corps = %q", mail.sent.Body)
	}
}

func TestResendUsesAccountEmail(t *testing.T) {
	mail := &fakeMailer{}

	if err := NewService(&fakeCodes{}, &fakeAccounts{email: "neo@matrix.io"}, mail).Resend(context.Background(), 42); err != nil {
		t.Fatalf("Resend: %v", err)
	}

	if mail.sent.To != "neo@matrix.io" {
		t.Errorf("destinataire = %q", mail.sent.To)
	}
}

func TestResendRejectsVerifiedAccount(t *testing.T) {
	codes := &fakeCodes{}
	mail := &fakeMailer{}

	err := NewService(codes, &fakeAccounts{verified: true}, mail).Resend(context.Background(), 42)
	if !errors.Is(err, ErrAlreadyVerified) {
		t.Fatalf("attendu ErrAlreadyVerified, got %v", err)
	}
	if codes.issueCalled || mail.called {
		t.Error("code emis pour un compte deja verifie")
	}
}

func TestVerifyMarksEmailVerified(t *testing.T) {
	codes := &fakeCodes{}
	accounts := &fakeAccounts{}

	if err := NewService(codes, accounts, &fakeMailer{}).Verify(context.Background(), 42, "123456"); err != nil {
		t.Fatalf("Verify: %v", err)
	}

	if codes.checkPurpose != token.PurposeEmailVerification {
		t.Errorf("purpose = %q", codes.checkPurpose)
	}
	if !accounts.markCalled {
		t.Error("email non marque verifie")
	}
}

func TestVerifyRejectsInvalidCode(t *testing.T) {
	accounts := &fakeAccounts{}

	err := NewService(&fakeCodes{checkErr: ErrInvalidCode}, accounts, &fakeMailer{}).Verify(context.Background(), 42, "000000")
	if !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("attendu ErrInvalidCode, got %v", err)
	}
	if accounts.markCalled {
		t.Error("email marque verifie malgre un code invalide")
	}
}

func TestVerifyRejectsVerifiedAccount(t *testing.T) {
	codes := &fakeCodes{}

	err := NewService(codes, &fakeAccounts{verified: true}, &fakeMailer{}).Verify(context.Background(), 42, "123456")
	if !errors.Is(err, ErrAlreadyVerified) {
		t.Fatalf("attendu ErrAlreadyVerified, got %v", err)
	}
	if codes.checkCalled {
		t.Error("essai consomme pour un compte deja verifie")
	}
}
