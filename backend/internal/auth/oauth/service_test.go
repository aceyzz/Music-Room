package oauth

import (
	"context"
	"errors"
	"testing"
	"time"

	"example.com/music-app/internal/session"
	"example.com/music-app/internal/user"
)

// --- doublures ---------------------------------------------------------------

type fakeProvider struct {
	name    string
	profile Profile
	err     error
}

func (f *fakeProvider) Name() string { return f.name }

func (f *fakeProvider) Exchange(ctx context.Context, code, redirectURI string) (Profile, error) {
	if f.err != nil {
		return Profile{}, f.err
	}
	return f.profile, nil
}

type fakeUsers struct {
	byIdentity    user.Credentials
	byIdentityErr error
	byEmail       user.Credentials
	byEmailErr    error
	created       user.Credentials

	createdName  string
	createdEmail string
	createdVerif bool
	createCalled bool

	linkedUserID   int64
	linkedProvider string
	linkCalled     bool

	unlinkErr        error
	unlinkCalled     bool
	unlinkedProvider string

	listed      []user.LinkedIdentity
	hasPassword bool
	listedFor   int64
}

func (f *fakeUsers) FindByProviderIdentity(ctx context.Context, provider, providerUserID string) (user.Credentials, error) {
	if f.byIdentityErr != nil {
		return user.Credentials{}, f.byIdentityErr
	}
	return f.byIdentity, nil
}

func (f *fakeUsers) FindCredentialsByEmail(ctx context.Context, email string) (user.Credentials, error) {
	if f.byEmailErr != nil {
		return user.Credentials{}, f.byEmailErr
	}
	return f.byEmail, nil
}

func (f *fakeUsers) CreateFromOAuth(ctx context.Context, displayName, email string, emailVerified bool) (user.Credentials, error) {
	f.createCalled = true
	f.createdName = displayName
	f.createdEmail = email
	f.createdVerif = emailVerified
	return f.created, nil
}

func (f *fakeUsers) LinkOAuthIdentity(ctx context.Context, userID int64, provider, providerUserID, providerEmail string) error {
	f.linkCalled = true
	f.linkedUserID = userID
	f.linkedProvider = provider
	return nil
}

func (f *fakeUsers) UnlinkOAuthIdentity(ctx context.Context, userID int64, provider string) error {
	f.unlinkCalled = true
	f.unlinkedProvider = provider
	return f.unlinkErr
}

func (f *fakeUsers) ListOAuthIdentities(ctx context.Context, userID int64) ([]user.LinkedIdentity, bool, error) {
	f.listedFor = userID
	return f.listed, f.hasPassword, nil
}

type fakeSessions struct {
	gotUserID int64
	called    bool
}

func (f *fakeSessions) Create(ctx context.Context, userID int64, tokenHash []byte, expiresAt time.Time) (session.Session, error) {
	f.called = true
	f.gotUserID = userID
	return session.Session{ExpiresAt: expiresAt}, nil
}

type fakeTokens struct{}

func (fakeTokens) NewSessionToken() (string, []byte, error) {
	return "token-clair", []byte("empreinte"), nil
}

var fixedNow = time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)

func googleProfile() Profile {
	return Profile{
		ProviderUserID: "google-sub-1",
		Email:          "neo@matrix.io",
		EmailVerified:  true,
		DisplayName:    "Neo",
	}
}

func newTestService(users UserStore, sessions SessionCreator, p Provider) *Service {
	s := NewService(NewRegistry(p), users, sessions, fakeTokens{}, DefaultSessionTTL)
	s.now = func() time.Time { return fixedNow }
	return s
}

// --- tests -------------------------------------------------------------------

// cas 1 : identite deja liee
func TestLoginWithKnownIdentity(t *testing.T) {
	users := &fakeUsers{
		byIdentity: user.Credentials{ID: 42, PublicID: "uuid", DisplayName: "Neo", Email: "neo@matrix.io", Status: "active"},
	}
	sessions := &fakeSessions{}

	res, err := newTestService(users, sessions, &fakeProvider{name: "google", profile: googleProfile()}).
		Login(context.Background(), "google", "code", "http://cb")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}

	if res.SessionToken != "token-clair" {
		t.Errorf("token = %q", res.SessionToken)
	}
	if sessions.gotUserID != 42 {
		t.Errorf("session pour le mauvais user: %d", sessions.gotUserID)
	}
	if users.createCalled {
		t.Error("compte cree alors que l'identite existait")
	}
	if users.linkCalled {
		t.Error("liaison refaite alors que l'identite existait")
	}
}

// cas 2 : email connu, identite non liee
func TestLoginLinksExistingAccountByEmail(t *testing.T) {
	users := &fakeUsers{
		byIdentityErr: user.ErrNotFound,
		byEmail:       user.Credentials{ID: 7, PublicID: "uuid", Email: "neo@matrix.io", Status: "active"},
	}

	if _, err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google", profile: googleProfile()}).
		Login(context.Background(), "google", "code", "http://cb"); err != nil {
		t.Fatalf("Login: %v", err)
	}

	if !users.linkCalled || users.linkedUserID != 7 {
		t.Errorf("identite non liee au compte existant (called=%v id=%d)", users.linkCalled, users.linkedUserID)
	}
	if users.createCalled {
		t.Error("compte cree alors que l'email existait")
	}
}

// cas 3 : inconnu
func TestLoginCreatesAccount(t *testing.T) {
	users := &fakeUsers{
		byIdentityErr: user.ErrNotFound,
		byEmailErr:    user.ErrNotFound,
		created:       user.Credentials{ID: 99, PublicID: "uuid", Status: "active"},
	}

	if _, err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google", profile: googleProfile()}).
		Login(context.Background(), "google", "code", "http://cb"); err != nil {
		t.Fatalf("Login: %v", err)
	}

	if !users.createCalled {
		t.Fatal("compte non cree")
	}
	if users.createdEmail != "neo@matrix.io" || users.createdName != "Neo" {
		t.Errorf("cree avec %q / %q", users.createdName, users.createdEmail)
	}
	// google verifie l'email : pas de mail de confirmation a envoyer
	if !users.createdVerif {
		t.Error("email non marque verifie alors que google le confirme")
	}
	if !users.linkCalled || users.linkedUserID != 99 {
		t.Error("identite non liee au compte cree")
	}
}

func TestLoginRejectsUnknownProvider(t *testing.T) {
	s := newTestService(&fakeUsers{}, &fakeSessions{}, &fakeProvider{name: "google"})

	if _, err := s.Login(context.Background(), "twitter", "code", "http://cb"); !errors.Is(err, ErrUnknownProvider) {
		t.Fatalf("attendu ErrUnknownProvider, got %v", err)
	}
}

func TestLoginPropagatesNoEmail(t *testing.T) {
	users := &fakeUsers{}
	sessions := &fakeSessions{}
	p := &fakeProvider{name: "facebook", err: ErrNoEmail}

	_, err := newTestService(users, sessions, p).Login(context.Background(), "facebook", "code", "http://cb")
	if !errors.Is(err, ErrNoEmail) {
		t.Fatalf("attendu ErrNoEmail, got %v", err)
	}
	if users.createCalled || sessions.called {
		t.Error("compte ou session cree malgre l'absence d'email")
	}
}

func TestLoginRejectsSuspendedAccount(t *testing.T) {
	users := &fakeUsers{
		byIdentity: user.Credentials{ID: 42, Status: "suspended"},
	}
	sessions := &fakeSessions{}

	_, err := newTestService(users, sessions, &fakeProvider{name: "google", profile: googleProfile()}).
		Login(context.Background(), "google", "code", "http://cb")
	if err == nil {
		t.Fatal("un compte suspendu ne doit pas se connecter")
	}
	if sessions.called {
		t.Error("session creee pour un compte suspendu")
	}
}

func TestDisplayNameFallsBackToEmailLocalPart(t *testing.T) {
	p := googleProfile()
	p.DisplayName = "  "

	users := &fakeUsers{
		byIdentityErr: user.ErrNotFound,
		byEmailErr:    user.ErrNotFound,
		created:       user.Credentials{ID: 99, Status: "active"},
	}

	if _, err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google", profile: p}).
		Login(context.Background(), "google", "code", "http://cb"); err != nil {
		t.Fatalf("Login: %v", err)
	}

	if users.createdName != "neo" {
		t.Errorf("display name = %q, attendu la partie locale de l'email", users.createdName)
	}
}

func TestLoginReturnsEmailVerified(t *testing.T) {
	users := &fakeUsers{
		byIdentity: user.Credentials{ID: 42, PublicID: "uuid", Status: "active", EmailVerified: true},
	}

	res, err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google", profile: googleProfile()}).
		Login(context.Background(), "google", "code", "http://cb")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if !res.EmailVerified {
		t.Error("email_verified perdu entre le repository et la reponse")
	}
}

func TestLinkNewIdentity(t *testing.T) {
	users := &fakeUsers{byIdentityErr: user.ErrNotFound}

	if err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google", profile: googleProfile()}).
		Link(context.Background(), 42, "google", "code", "http://cb"); err != nil {
		t.Fatalf("Link: %v", err)
	}

	if !users.linkCalled || users.linkedUserID != 42 || users.linkedProvider != "google" {
		t.Errorf("liaison incorrecte (called=%v id=%d provider=%q)", users.linkCalled, users.linkedUserID, users.linkedProvider)
	}
}

func TestLinkIsIdempotentForSameUser(t *testing.T) {
	users := &fakeUsers{byIdentity: user.Credentials{ID: 42}}

	if err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google", profile: googleProfile()}).
		Link(context.Background(), 42, "google", "code", "http://cb"); err != nil {
		t.Fatalf("Link: %v", err)
	}
	if users.linkCalled {
		t.Error("liaison refaite alors qu'elle existait deja")
	}
}

func TestLinkRejectsIdentityOfAnotherUser(t *testing.T) {
	users := &fakeUsers{byIdentity: user.Credentials{ID: 7}}

	err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google", profile: googleProfile()}).
		Link(context.Background(), 42, "google", "code", "http://cb")
	if !errors.Is(err, user.ErrIdentityAlreadyLinked) {
		t.Fatalf("attendu ErrIdentityAlreadyLinked, got %v", err)
	}
	if users.linkCalled {
		t.Error("identite liee a un second compte")
	}
}

func TestLinkRejectsUnknownProvider(t *testing.T) {
	err := newTestService(&fakeUsers{}, &fakeSessions{}, &fakeProvider{name: "google"}).
		Link(context.Background(), 42, "twitter", "code", "http://cb")
	if !errors.Is(err, ErrUnknownProvider) {
		t.Fatalf("attendu ErrUnknownProvider, got %v", err)
	}
}

func TestUnlinkCallsStore(t *testing.T) {
	users := &fakeUsers{}

	if err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google"}).
		Unlink(context.Background(), 42, "google"); err != nil {
		t.Fatalf("Unlink: %v", err)
	}
	if !users.unlinkCalled || users.unlinkedProvider != "google" {
		t.Errorf("unlink incorrect (called=%v provider=%q)", users.unlinkCalled, users.unlinkedProvider)
	}
}

func TestUnlinkRejectsUnknownProvider(t *testing.T) {
	users := &fakeUsers{}

	err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google"}).
		Unlink(context.Background(), 42, "twitter")
	if !errors.Is(err, ErrUnknownProvider) {
		t.Fatalf("attendu ErrUnknownProvider, got %v", err)
	}
	if users.unlinkCalled {
		t.Error("provider inconnu transmis a la base")
	}
}

func TestUnlinkPropagatesLastLoginMethod(t *testing.T) {
	users := &fakeUsers{unlinkErr: user.ErrLastLoginMethod}

	err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google"}).
		Unlink(context.Background(), 42, "google")
	if !errors.Is(err, user.ErrLastLoginMethod) {
		t.Fatalf("attendu ErrLastLoginMethod, got %v", err)
	}
}

// List ne filtre pas sur les providers configures : facebook n'est pas dans
// le registre du service, mais l'identite reste rattachee au compte.
func TestListReturnsEveryLinkedIdentity(t *testing.T) {
	users := &fakeUsers{
		listed: []user.LinkedIdentity{
			{Provider: "google", Email: "neo@matrix.io", LinkedAt: fixedNow},
			{Provider: "facebook", LinkedAt: fixedNow},
		},
		hasPassword: false,
	}

	got, hasPassword, err := newTestService(users, &fakeSessions{}, &fakeProvider{name: "google"}).
		List(context.Background(), 42)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if users.listedFor != 42 {
		t.Errorf("liste demandee pour le compte %d, attendu 42", users.listedFor)
	}
	if len(got) != 2 || got[1].Provider != "facebook" {
		t.Errorf("identites inattendues: %+v", got)
	}
	if hasPassword {
		t.Error("has_password vrai pour un compte sans mot de passe")
	}
}
