package register

import (
	"context"
	"errors"
	"testing"

	"example.com/music-app/internal/user"
)

// --- doublures ---------------------------------------------------------------
// Elles implémentent les interfaces déclarées dans service.go. Le service ne
// voit aucune différence avec les vraies implémentations.

type fakeHasher struct {
	called bool
}

func (f *fakeHasher) Hash(password string) (string, error) {
	f.called = true
	return "hash-de-" + password, nil
}

type fakeCreator struct {
	gotDisplayName string
	gotEmail       string
	gotHash        string
	err            error
}

func (f *fakeCreator) Create(ctx context.Context, displayName, email, passwordHash string) (user.User, error) {
	f.gotDisplayName = displayName
	f.gotEmail = email
	f.gotHash = passwordHash
	if f.err != nil {
		return user.User{}, f.err
	}
	return user.User{PublicID: "uuid-test", DisplayName: displayName, Email: email}, nil
}

// --- tests -------------------------------------------------------------------

func TestRegisterCreatesUser(t *testing.T) {
	hasher := &fakeHasher{}
	creator := &fakeCreator{}
	svc := NewService(creator, hasher, DefaultMinPasswordLen)

	got, err := svc.Register(context.Background(), "  neo@matrix.io ", "hunter2hunter2", " Neo ")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	if got.PublicID != "uuid-test" {
		t.Errorf("PublicID = %q", got.PublicID)
	}
	// les espaces autour de l'email et du pseudo doivent avoir été retirés
	if creator.gotEmail != "neo@matrix.io" {
		t.Errorf("email non nettoye: %q", creator.gotEmail)
	}
	if creator.gotDisplayName != "Neo" {
		t.Errorf("display name non nettoye: %q", creator.gotDisplayName)
	}
	// le repository ne doit jamais voir le mot de passe en clair
	if creator.gotHash == "hunter2hunter2" {
		t.Error("le mot de passe en clair a ete transmis au repository")
	}
	if !hasher.called {
		t.Error("le hasher n'a pas ete appele")
	}
}

func TestRegisterRejectsBadInput(t *testing.T) {
	cases := []struct {
		name        string
		email       string
		password    string
		displayName string
		want        error
	}{
		{"email sans arobase", "pas-un-email", "hunter2hunter2", "Neo", ErrEmailInvalid},
		{"email vide", "", "hunter2hunter2", "Neo", ErrEmailInvalid},
		{"mot de passe trop court", "neo@matrix.io", "court", "Neo", ErrPasswordTooShort},
		{"display name vide", "neo@matrix.io", "hunter2hunter2", "   ", ErrDisplayNameInvalid},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			creator := &fakeCreator{}
			svc := NewService(creator, &fakeHasher{}, DefaultMinPasswordLen)

			_, err := svc.Register(context.Background(), tc.email, tc.password, tc.displayName)
			if !errors.Is(err, tc.want) {
				t.Fatalf("attendu %v, got %v", tc.want, err)
			}
			// rien ne doit atteindre la base quand l'entree est invalide
			if creator.gotEmail != "" {
				t.Error("le repository a ete appele malgre une entree invalide")
			}
		})
	}
}

func TestRegisterPropagatesRepositoryError(t *testing.T) {
	creator := &fakeCreator{err: user.ErrEmailTaken}
	svc := NewService(creator, &fakeHasher{}, DefaultMinPasswordLen)

	_, err := svc.Register(context.Background(), "neo@matrix.io", "hunter2hunter2", "Neo")
	if !errors.Is(err, user.ErrEmailTaken) {
		t.Fatalf("attendu ErrEmailTaken, got %v", err)
	}
}

func TestMinPasswordLenCannotBeLowered(t *testing.T) {
	// La config demande 3, mais le plancher est 8.
	svc := NewService(&fakeCreator{}, &fakeHasher{}, 3)

	// 7 caracteres : doit etre refuse malgre la config a 3.
	_, err := svc.Register(context.Background(), "neo@matrix.io", "1234567", "Neo")
	if !errors.Is(err, ErrPasswordTooShort) {
		t.Fatalf("la config ne doit pas pouvoir descendre sous le plancher, got %v", err)
	}
}
