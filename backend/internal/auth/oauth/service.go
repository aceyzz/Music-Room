package oauth

import (
	"context"
	"errors"
	"strings"
	"time"

	"example.com/music-app/internal/session"
	"example.com/music-app/internal/user"
)

const DefaultSessionTTL = 30 * 24 * time.Hour

type UserStore interface {
	FindByProviderIdentity(ctx context.Context, provider, providerUserID string) (user.Credentials, error)
	FindCredentialsByEmail(ctx context.Context, email string) (user.Credentials, error)
	CreateFromOAuth(ctx context.Context, displayName, email string, emailVerified bool) (user.Credentials, error)
	LinkOAuthIdentity(ctx context.Context, userID int64, provider, providerUserID, providerEmail string) error
	UnlinkOAuthIdentity(ctx context.Context, userID int64, provider string) error
	ListOAuthIdentities(ctx context.Context, userID int64) ([]user.LinkedIdentity, bool, error)
}

type SessionCreator interface {
	Create(ctx context.Context, userID int64, tokenHash []byte, expiresAt time.Time) (session.Session, error)
}

type TokenGenerator interface {
	NewSessionToken() (token string, hash []byte, err error)
}

// Result : identique a celui du login classique. le client ne voit pas la
// difference entre une connexion par mot de passe et une connexion sociale.
type Result struct {
	SessionToken  string
	ExpiresAt     time.Time
	UserPublicID  string
	DisplayName   string
	Email         string
	EmailVerified bool
}

type Service struct {
	providers Registry
	users     UserStore
	sessions  SessionCreator
	tokens    TokenGenerator
	ttl       time.Duration
	now       func() time.Time
}

func NewService(providers Registry, users UserStore, sessions SessionCreator, tokens TokenGenerator, ttl time.Duration) *Service {
	if ttl <= 0 {
		ttl = DefaultSessionTTL
	}
	return &Service{
		providers: providers,
		users:     users,
		sessions:  sessions,
		tokens:    tokens,
		ttl:       ttl,
		now:       time.Now,
	}
}

// Login : echange le code, resout le compte, ouvre une session.
func (s *Service) Login(ctx context.Context, providerName, code, redirectURI string) (Result, error) {
	provider, err := s.providers.Get(providerName)
	if err != nil {
		return Result{}, err
	}

	profile, err := provider.Exchange(ctx, code, redirectURI)
	if err != nil {
		return Result{}, err
	}

	creds, err := s.resolveUser(ctx, provider.Name(), profile)
	if err != nil {
		return Result{}, err
	}

	if creds.Status != "active" {
		return Result{}, user.ErrNotFound
	}

	token, hash, err := s.tokens.NewSessionToken()
	if err != nil {
		return Result{}, err
	}

	sess, err := s.sessions.Create(ctx, creds.ID, hash, s.now().Add(s.ttl))
	if err != nil {
		return Result{}, err
	}

	return Result{
		SessionToken:  token,
		ExpiresAt:     sess.ExpiresAt,
		UserPublicID:  creds.PublicID,
		DisplayName:   creds.DisplayName,
		Email:         creds.Email,
		EmailVerified: creds.EmailVerified,
	}, nil
}

// resolveUser : trois cas, dans cet ordre.
//  1. identite deja liee -> on connecte
//  2. email deja connu   -> on lie l'identite au compte existant
//  3. inconnu            -> on cree le compte et on lie
func (s *Service) resolveUser(ctx context.Context, providerName string, p Profile) (user.Credentials, error) {
	creds, err := s.users.FindByProviderIdentity(ctx, providerName, p.ProviderUserID)
	if err == nil {
		return creds, nil
	}
	if !errors.Is(err, user.ErrNotFound) {
		return user.Credentials{}, err
	}

	// cas 2 : liaison automatique sur l'email.
	// LIMITE CONNUE : quelqu'un qui controle un compte provider portant
	// l'email d'un utilisateur existant prend son compte. acceptable tant
	// que la verification email n'est pas generalisee ; a durcir ensuite
	// (exiger un login classique puis une liaison explicite).
	creds, err = s.users.FindCredentialsByEmail(ctx, p.Email)
	if err == nil {
		if err := s.users.LinkOAuthIdentity(ctx, creds.ID, providerName, p.ProviderUserID, p.Email); err != nil {
			return user.Credentials{}, err
		}
		return creds, nil
	}
	if !errors.Is(err, user.ErrNotFound) {
		return user.Credentials{}, err
	}

	// cas 3 : creation.
	created, err := s.users.CreateFromOAuth(ctx, uniqueDisplayName(p), p.Email, p.EmailVerified)
	if err != nil {
		return user.Credentials{}, err
	}

	if err := s.users.LinkOAuthIdentity(ctx, created.ID, providerName, p.ProviderUserID, p.Email); err != nil {
		return user.Credentials{}, err
	}

	return created, nil
}

// display_name est UNIQUE. deux "Jean Dupont" chez google entrent en
// collision, donc on repli sur la partie locale de l'email, qui l'est
// beaucoup moins.
func uniqueDisplayName(p Profile) string {
	name := strings.TrimSpace(p.DisplayName)
	if name != "" {
		return name
	}
	local, _, _ := strings.Cut(p.Email, "@")
	return local
}

func (s *Service) Link(ctx context.Context, userID int64, providerName, code, redirectURI string) error {
	provider, err := s.providers.Get(providerName)
	if err != nil {
		return err
	}

	profile, err := provider.Exchange(ctx, code, redirectURI)
	if err != nil {
		return err
	}

	existing, err := s.users.FindByProviderIdentity(ctx, provider.Name(), profile.ProviderUserID)
	if err == nil {
		if existing.ID == userID {
			return nil
		}
		return user.ErrIdentityAlreadyLinked
	}
	if !errors.Is(err, user.ErrNotFound) {
		return err
	}

	return s.users.LinkOAuthIdentity(ctx, userID, provider.Name(), profile.ProviderUserID, profile.Email)
}

func (s *Service) Unlink(ctx context.Context, userID int64, providerName string) error {
	if _, err := s.providers.Get(providerName); err != nil {
		return err
	}
	return s.users.UnlinkOAuthIdentity(ctx, userID, providerName)
}

// List : les identites liees, et si le compte a un mot de passe. Pas de
// filtre sur les providers configures, contrairement a Link et Unlink : une
// identite liee du temps ou Facebook l'etait reste en base, et l'ecran doit
// dire la verite sur ce qui est rattache au compte.
func (s *Service) List(ctx context.Context, userID int64) ([]user.LinkedIdentity, bool, error) {
	return s.users.ListOAuthIdentities(ctx, userID)
}
