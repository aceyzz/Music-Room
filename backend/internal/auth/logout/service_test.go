package logout

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

type fakeHasher struct{}

func (fakeHasher) HashSessionToken(token string) []byte {
	return []byte("hash-de-" + token)
}

type fakeRevoker struct {
	gotHash []byte
	called  bool
	err     error
}

func (f *fakeRevoker) Revoke(ctx context.Context, tokenHash []byte) error {
	f.called = true
	f.gotHash = tokenHash
	return f.err
}

func TestLogoutRevokesHashedToken(t *testing.T) {
	revoker := &fakeRevoker{}
	svc := NewService(revoker, fakeHasher{})

	if err := svc.Logout(context.Background(), "token-clair"); err != nil {
		t.Fatalf("Logout: %v", err)
	}

	if !revoker.called {
		t.Fatal("la revocation n'a pas ete appelee")
	}
	// le repository ne doit jamais voir le token en clair
	if bytes.Equal(revoker.gotHash, []byte("token-clair")) {
		t.Fatal("le token clair a ete transmis au repository")
	}
	if !bytes.Equal(revoker.gotHash, []byte("hash-de-token-clair")) {
		t.Fatalf("empreinte inattendue: %q", revoker.gotHash)
	}
}

func TestLogoutRejectsEmptyToken(t *testing.T) {
	revoker := &fakeRevoker{}
	svc := NewService(revoker, fakeHasher{})

	if err := svc.Logout(context.Background(), ""); !errors.Is(err, ErrMissingToken) {
		t.Fatalf("attendu ErrMissingToken, got %v", err)
	}
	if revoker.called {
		t.Error("la base a ete touchee malgre un token vide")
	}
}

func TestLogoutPropagatesRepositoryError(t *testing.T) {
	boom := errors.New("db down")
	svc := NewService(&fakeRevoker{err: boom}, fakeHasher{})

	if err := svc.Logout(context.Background(), "token-clair"); !errors.Is(err, boom) {
		t.Fatalf("attendu l'erreur du repository, got %v", err)
	}
}
