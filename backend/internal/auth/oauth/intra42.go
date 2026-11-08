package oauth

import (
	"context"
	"strconv"
)

type Intra42Provider struct {
	cfg config
}

func NewIntra42Provider(clientID, clientSecret string) *Intra42Provider {
	cfg := config{
		clientID:     clientID,
		clientSecret: clientSecret,
		tokenURL:     "https://api.intra.42.fr/oauth/token",
		userInfoURL:  "https://api.intra.42.fr/v2/me",
	}
	if !cfg.isComplete() {
		return nil
	}
	return &Intra42Provider{cfg: cfg}
}

func (*Intra42Provider) Name() string { return "intra42" }

// /v2/me renvoie beaucoup plus que ca ; on ne decode que l'utile.
type intra42UserInfo struct {
	ID    int64  `json:"id"`
	Email string `json:"email"`
	Login string `json:"login"`
}

func (p *Intra42Provider) Exchange(ctx context.Context, code, redirectURI string) (Profile, error) {
	accessToken, err := exchangeCode(ctx, p.cfg, code, redirectURI)
	if err != nil {
		return Profile{}, err
	}

	var info intra42UserInfo
	if err := fetchProfile(ctx, p.cfg.userInfoURL, accessToken, &info); err != nil {
		return Profile{}, err
	}

	if info.Email == "" {
		return Profile{}, ErrNoEmail
	}

	return Profile{
		ProviderUserID: strconv.FormatInt(info.ID, 10),
		Email:          info.Email,
		EmailVerified:  true,
		DisplayName:    info.Login,
	}, nil
}
