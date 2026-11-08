package security

import (
	"bytes"
	"testing"
)

func TestNewSessionTokenIsUnique(t *testing.T) {
	a, hashA, err := NewSessionToken()
	if err != nil {
		t.Fatalf("NewSessionToken: %v", err)
	}
	b, hashB, err := NewSessionToken()
	if err != nil {
		t.Fatalf("NewSessionToken: %v", err)
	}

	if a == b {
		t.Fatal("deux tokens generes doivent differer")
	}
	if bytes.Equal(hashA, hashB) {
		t.Fatal("deux empreintes doivent differer")
	}
}

func TestHashIsReproducible(t *testing.T) {
	token, hash, _ := NewSessionToken()

	// C'est ce que fera le serveur a chaque requete : rehasher le token
	// presente et comparer a ce qui est en base.
	if !bytes.Equal(HashSessionToken(token), hash) {
		t.Fatal("rehasher le meme token doit redonner la meme empreinte")
	}
}

func TestHashDoesNotRevealToken(t *testing.T) {
	token, hash, _ := NewSessionToken()

	if bytes.Contains(hash, []byte(token)) {
		t.Fatal("l'empreinte ne doit pas contenir le token")
	}
	if len(hash) != 32 {
		t.Fatalf("sha256 fait 32 octets, got %d", len(hash))
	}
}
