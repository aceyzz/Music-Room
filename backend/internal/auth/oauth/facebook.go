package oauth

import (
	"context"
	"strings"
)

type FacebookProvider struct {
	cfg config
}

func NewFacebookProvider(clientID, clientSecret string) *FacebookProvider {
	cfg := config{
		clientID:     clientID,
		clientSecret: clientSecret,
		tokenURL:     "https://graph.facebook.com/v21.0/oauth/access_token",
		// facebook exige la liste des champs voulus.
		userInfoURL: "https://graph.facebook.com/v21.0/me?fields=id,name,email",
	}
	if !cfg.isComplete() {
		return nil
	}
	return &FacebookProvider{cfg: cfg}
}

func (*FacebookProvider) Name() string { return "facebook" }

type facebookUserInfo struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

func (p *FacebookProvider) Exchange(ctx context.Context, code, redirectURI string) (Profile, error) {
	accessToken, err := exchangeCode(ctx, p.cfg, code, redirectURI)
	if err != nil {
		return Profile{}, err
	}

	var info facebookUserInfo
	if err := fetchProfile(ctx, p.cfg.userInfoURL, accessToken, &info); err != nil {
		return Profile{}, err
	}

	// facebook peut ne rien renvoyer : compte cree par telephone, ou email
	// non partage. users.email est NOT NULL, donc on refuse ici.
	// data-model 5 prevoit de demander l'email au client dans ce cas ;
	// pas fait dans cette PR.
	if info.Email == "" {
		return Profile{}, ErrNoEmail
	}

	displayName := info.Name
	if displayName == "" {
		displayName, _, _ = strings.Cut(info.Email, "@")
	}

	return Profile{
		ProviderUserID: info.ID,
		Email:          info.Email,
		// facebook ne renvoie pas de champ de verification sur /me. une
		// adresse facebook est confirmee a l'inscription, mais on ne peut
		// pas le prouver ici : on ne pretend pas qu'elle l'est.
		EmailVerified: false,
		DisplayName:   displayName,
	}, nil
}
