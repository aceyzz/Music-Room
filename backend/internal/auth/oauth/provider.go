// package oauth : social login, agnostique du fournisseur.
// un fichier par provider, tous derriere la meme interface.
package oauth

import (
	"context"
	"errors"
)

var (
	// le provider n'a pas renvoye d'email. users.email est NOT NULL UNIQUE,
	// donc on ne peut pas creer le compte. cas connu de facebook.
	ErrNoEmail = errors.New("provider returned no email")

	ErrUnknownProvider = errors.New("unknown provider")
	ErrExchangeFailed  = errors.New("code exchange failed")
)

// Profile : ce qu'un provider dit d'un utilisateur, une fois le code echange.
// c'est le denominateur commun aux trois : au-dela, chacun renvoie autre chose
// et ca ne nous interesse pas.
type Profile struct {
	ProviderUserID string
	Email          string
	EmailVerified  bool
	DisplayName    string
}

// Provider : un fournisseur d'identite.
// Name sert de cle dans le registre et de valeur pour l'enum oauth_provider :
// les deux doivent coincider.
type Provider interface {
	Name() string
	Exchange(ctx context.Context, code, redirectURI string) (Profile, error)
}

// Registry : les providers configures, par nom.
// un provider sans identifiants n'est simplement pas enregistre.
type Registry map[string]Provider

func NewRegistry(providers ...Provider) Registry {
	r := make(Registry, len(providers))
	for _, p := range providers {
		r[p.Name()] = p
	}
	return r
}

func (r Registry) Get(name string) (Provider, error) {
	p, ok := r[name]
	if !ok {
		return nil, ErrUnknownProvider
	}
	return p, nil
}
