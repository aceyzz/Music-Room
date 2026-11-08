package oauth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// config commune aux trois providers.
type config struct {
	clientID     string
	clientSecret string
	tokenURL     string
	userInfoURL  string
}

func (c config) isComplete() bool {
	return c.clientID != "" && c.clientSecret != ""
}

// httpClient partage. timeout court : un provider lent ne doit pas bloquer
// une goroutine indefiniment.
var httpClient = &http.Client{Timeout: 10 * time.Second}

type tokenResponse struct {
	AccessToken string `json:"access_token"`
}

// exchangeCode echange le code d'autorisation contre un access token.
// le client_secret ne quitte jamais le serveur : c'est la raison d'etre de
// cet echange cote backend.
func exchangeCode(ctx context.Context, cfg config, code, redirectURI string) (string, error) {
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {redirectURI},
		"client_id":     {cfg.clientID},
		"client_secret": {cfg.clientSecret},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrExchangeFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// le corps peut contenir le code ou des identifiants : on ne le
		// remonte pas.
		return "", fmt.Errorf("%w: status %d", ErrExchangeFailed, resp.StatusCode)
	}

	var tr tokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil {
		return "", fmt.Errorf("%w: %v", ErrExchangeFailed, err)
	}
	if tr.AccessToken == "" {
		return "", ErrExchangeFailed
	}

	return tr.AccessToken, nil
}

// fetchProfile appelle l'endpoint userinfo et decode dans target.
func fetchProfile(ctx context.Context, userInfoURL, accessToken string, target any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, userInfoURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrExchangeFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: userinfo status %d", ErrExchangeFailed, resp.StatusCode)
	}

	return json.NewDecoder(resp.Body).Decode(target)
}
