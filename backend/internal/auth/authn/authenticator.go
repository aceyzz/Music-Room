// package authn : resout un token de session en utilisateur.
// pas de grpc, pas de sql. appele par l'intercepteur grpc.
package authn

import (
	"context"
	"errors"
	"log"
	"time"

	"example.com/music-app/internal/session"
)

// cinq refus distincts. le client les verra tous en Unauthenticated,
// mais les logs doivent savoir lequel (data-model 5).
var (
	ErrUnknownToken    = errors.New("unknown token")
	ErrRevoked         = errors.New("session revoked")
	ErrExpired         = errors.New("session expired")
	ErrIdle            = errors.New("session idle too long")
	ErrAccountInactive = errors.New("account not active")
)

// SessionStore : la part du repository utilisee ici.
type SessionStore interface {
	FindByHash(ctx context.Context, tokenHash []byte) (session.Details, error)
	Touch(ctx context.Context, sessionID int64) error
}

// DefaultIdleTimeout : duree sans requete au bout de laquelle une session est
// refusee, meme avant son expiration absolue. Une app mobile grand public
// (Spotify, Deezer) garde l'utilisateur connecte des semaines ; sept jours
// ferment une session abandonnee sur un telephone perdu sans faire se
// reconnecter quelqu'un qui ouvre l'app chaque week-end.
const DefaultIdleTimeout = 7 * 24 * time.Hour

// touchInterval : last_used_at n'est reecrit que s'il date de plus d'une
// minute. Sans ce seuil, chaque requete authentifiee devient une ecriture
// (auth.sql, TouchSession). Le prix : la fenetre d'inactivite est precise a
// une minute pres, ce qui est negligeable devant sept jours.
const touchInterval = time.Minute

// TokenHasher : recalcule l'empreinte du token presente.
type TokenHasher interface {
	HashSessionToken(token string) []byte
}

// Identity : qui appelle.
//
// Les deux ids, et c'est voulu. UserPublicID est le sujet des tuples
// (`user:<uuid>`), UserID est ce que le SQL et les handlers manipulent. Les
// porter ensemble est ce qui permet a l'intercepteur de remplir les champs
// int64 des requetes sans une resolution supplementaire, et donc de garantir
// que l'objet verifie et la ligne touchee sont le meme objet.
//
// SessionID et DeviceID viennent de la meme ligne, sans requete de plus :
// RegisterDevice rattache l'appareil a la session courante, et les journaux
// d'activite (V.6) lisent l'appareil d'ici. DeviceID vaut 0 tant que l'app ne
// s'est pas enregistree.
type Identity struct {
	UserID       int64
	UserPublicID string
	SessionID    int64
	DeviceID     int64
}

type Authenticator struct {
	sessions    SessionStore
	hasher      TokenHasher
	idleTimeout time.Duration
	now         func() time.Time
}

func NewAuthenticator(sessions SessionStore, hasher TokenHasher, idleTimeout time.Duration) *Authenticator {
	if idleTimeout <= 0 {
		idleTimeout = DefaultIdleTimeout
	}
	return &Authenticator{
		sessions:    sessions,
		hasher:      hasher,
		idleTimeout: idleTimeout,
		now:         time.Now,
	}
}

// Authenticate resout le token en identite.
// verifie dans cet ordre : existe, pas revoque, pas expire, pas inactif trop
// longtemps, compte actif. puis glisse la fenetre d'inactivite si besoin.
func (a *Authenticator) Authenticate(ctx context.Context, token string) (Identity, error) {
	if token == "" {
		return Identity{}, ErrUnknownToken
	}

	details, err := a.sessions.FindByHash(ctx, a.hasher.HashSessionToken(token))
	if err != nil {
		if errors.Is(err, session.ErrNotFound) {
			return Identity{}, ErrUnknownToken
		}
		return Identity{}, err
	}

	if details.IsRevoked {
		return Identity{}, ErrRevoked
	}

	now := a.now()
	if !details.ExpiresAt.After(now) {
		return Identity{}, ErrExpired
	}

	idle := now.Sub(details.LastUsedAt)
	if idle >= a.idleTimeout {
		return Identity{}, ErrIdle
	}

	if details.UserStatus != "active" {
		return Identity{}, ErrAccountInactive
	}

	if idle >= touchInterval {
		// un echec ici ne refuse pas la requete : la session est valable, seul
		// le glissement de la fenetre est perdu, et la requete suivante
		// reessaiera. Refuser ferait d'une panne d'ecriture une panne de lecture.
		if err := a.sessions.Touch(ctx, details.ID); err != nil {
			log.Printf("authn: touch session %d: %v", details.ID, err)
		}
	}

	return Identity{
		UserID:       details.UserID,
		UserPublicID: details.UserPublicID,
		SessionID:    details.ID,
		DeviceID:     details.DeviceID,
	}, nil
}

// identityKey : cle privee du contexte. Type dedie, pas une string, pour qu'un
// autre package ne puisse pas ecrire dessus par accident.
type identityKey struct{}

// NewContext attache l'identite resolue au contexte de la requete.
func NewContext(ctx context.Context, identity Identity) context.Context {
	return context.WithValue(ctx, identityKey{}, identity)
}

// FromContext lit l'identite attachee par l'intercepteur.
//
// Le booleen n'est pas decoratif : un handler joignable sans authentification
// (AuthService, le catalogue) n'en a pas, et confondre "anonyme" avec
// "utilisateur 0" est exactement le genre de confusion qui fait passer une
// requete anonyme pour une requete legitime.
func FromContext(ctx context.Context) (Identity, bool) {
	identity, ok := ctx.Value(identityKey{}).(Identity)
	return identity, ok
}
