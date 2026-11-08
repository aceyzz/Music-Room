package security

import (
	"errors"
	"strings"
	"testing"
)

func TestHashThenVerify(t *testing.T) {
	h := NewArgon2Hasher()

	encoded, err := h.Hash("hunter2hunter2")
	if err != nil {
		t.Fatalf("Hash: %v", err)
	}

	if err := h.Verify("hunter2hunter2", encoded); err != nil {
		t.Fatalf("le bon mot de passe doit passer, got %v", err)
	}

	if err := h.Verify("mauvais", encoded); !errors.Is(err, ErrPasswordMismatch) {
		t.Fatalf("attendu ErrPasswordMismatch, got %v", err)
	}
}

func TestHashIsSaltedPerCall(t *testing.T) {
	h := NewArgon2Hasher()

	a, _ := h.Hash("meme-mot-de-passe")
	b, _ := h.Hash("meme-mot-de-passe")

	if a == b {
		t.Fatal("deux hash du meme mot de passe doivent differer (sel aleatoire)")
	}
}

func TestHashNeverContainsPlaintext(t *testing.T) {
	h := NewArgon2Hasher()

	encoded, _ := h.Hash("hunter2hunter2")
	if strings.Contains(encoded, "hunter2hunter2") {
		t.Fatal("le hash ne doit jamais contenir le mot de passe")
	}
}

func TestVerifyRejectsGarbage(t *testing.T) {
	h := NewArgon2Hasher()

	if err := h.Verify("x", "pas-un-hash"); !errors.Is(err, ErrInvalidHash) {
		t.Fatalf("attendu ErrInvalidHash, got %v", err)
	}
}
