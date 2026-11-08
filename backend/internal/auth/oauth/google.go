package oauth

import (
	"context"
	"strings"
)

type GoogleProvider struct {
	cfg config
}

// NewGoogleProvider renvoie nil si les identifiants manquent : un provider
// non configure n'est pas enregistre, plutot que d'echouer a l'usage.
func NewGoogleProvider(clientID, clientSecret string) *GoogleProvider {
	cfg := config{
		clientID:     clientID,
		clientSecret: clientSecret,
		tokenURL:     "https://oauth2.googleapis.com/token",
		userInfoURL:  "https://openidconnect.googleapis.com/v1/userinfo",
	}
	if !cfg.isComplete() {
		return nil
	}
	return &GoogleProvider{cfg: cfg}
}

func (*GoogleProvider) Name() string { return "google" }

// forme de la reponse userinfo (openid connect).
type googleUserInfo struct {
	Sub           string `json:"sub"`
	Email         string `json:"email"`
	EmailVerified bool   `json:"email_verified"`
	Name          string `json:"name"`
}

func (p *GoogleProvider) Exchange(ctx context.Context, code, redirectURI string) (Profile, error) {
	accessToken, err := exchangeCode(ctx, p.cfg, code, redirectURI)
	if err != nil {
		return Profile{}, err
	}

	var info googleUserInfo
	if err := fetchProfile(ctx, p.cfg.userInfoURL, accessToken, &info); err != nil {
		return Profile{}, err
	}

	if info.Email == "" {
		return Profile{}, ErrNoEmail
	}

	// google ne renvoie pas toujours "name" : on retombe sur la partie
	// locale de l'email plutot que de creer un compte sans pseudo.
	displayName := info.Name
	if displayName == "" {
		displayName, _, _ = strings.Cut(info.Email, "@")
	}

	return Profile{
		ProviderUserID: info.Sub,
		Email:          info.Email,
		EmailVerified:  info.EmailVerified,
		DisplayName:    displayName,
	}, nil
}
