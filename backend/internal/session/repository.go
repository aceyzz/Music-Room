package session

import (
	"context"
	"errors"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Session est ce que le reste de l'application connaît d'une session.
// Le token en clair n'est PAS ici : il n'existe qu'une fois, au login.
type Session struct {
	PublicID  string
	ExpiresAt time.Time
}

// Details : tout ce que la base sait d'une session.
// aucun jugement ici : le service decide si elle est valable.
type Details struct {
	// ID est l'id interne de la session : ce que TouchSession prend.
	ID int64
	// UserID est l'id interne, UserPublicID l'UUID public. Les deux, parce que
	// l'authentification est le seul endroit du systeme ou les deux sont
	// disponibles sans requete supplementaire (GetSessionByHash joint deja
	// users) : le graphe de permissions ne parle que d'UUID publics, les
	// handlers et le SQL ne parlent que d'ids internes. Les resoudre ici evite
	// un aller-retour par requete authentifiee.
	UserID       int64
	UserPublicID string
	ExpiresAt    time.Time
	LastUsedAt   time.Time
	RevokedAt    time.Time
	IsRevoked    bool
	UserStatus   string
	// DeviceID est l'appareil de cette session, 0 tant que l'app n'a pas
	// appele RegisterDevice. Une session = un telephone : c'est ce qui donne a
	// chaque requete authentifiee son appareil sans en-tete ni requete de plus.
	DeviceID int64
}

type Repository struct {
	q *sqlc.Queries
}

func NewRepository(db sqlc.DBTX) *Repository {
	return &Repository{q: sqlc.New(db)}
}

// Create enregistre une nouvelle session. tokenHash est l'empreinte SHA-256 ;
// le token en clair ne doit jamais arriver jusqu'ici.
func (r *Repository) Create(ctx context.Context, userID int64, tokenHash []byte, expiresAt time.Time) (Session, error) {
	row, err := r.q.CreateSession(ctx, sqlc.CreateSessionParams{
		UserID:    userID,
		TokenHash: tokenHash,
		ExpiresAt: pgtype.Timestamptz{Time: expiresAt, Valid: true},
	})
	if err != nil {
		return Session{}, err
	}

	return Session{
		PublicID:  row.PublicID.String(),
		ExpiresAt: row.ExpiresAt.Time,
	}, nil
}

// Revoke marque la session revoquee. la ligne est gardee pour l'audit,
// jamais supprimee : "pourquoi suis-je deconnecte" doit rester repondable.
func (r *Repository) Revoke(ctx context.Context, tokenHash []byte) error {
	return r.q.RevokeSessionByHash(ctx, sqlc.RevokeSessionByHashParams{
		TokenHash: tokenHash,
		RevokedReason: sqlc.NullSessionRevokedReason{
			SessionRevokedReason: sqlc.SessionRevokedReasonLogout,
			Valid:                true,
		},
	})
}

var ErrNotFound = errors.New("session not found")

// FindByHash lit la session portant cette empreinte.
// ne filtre ni les revoquees ni les expirees : le service doit pouvoir
// distinguer les cas pour les logs (data-model 5).
func (r *Repository) FindByHash(ctx context.Context, tokenHash []byte) (Details, error) {
	row, err := r.q.GetSessionByHash(ctx, tokenHash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Details{}, ErrNotFound
		}
		return Details{}, err
	}

	return Details{
		ID:           row.UserSession.ID,
		UserID:       row.UserSession.UserID,
		UserPublicID: row.UserPublicID.String(),
		ExpiresAt:    row.UserSession.ExpiresAt.Time,
		LastUsedAt:   row.UserSession.LastUsedAt.Time,
		RevokedAt:    row.UserSession.RevokedAt.Time,
		IsRevoked:    row.UserSession.RevokedAt.Valid,
		UserStatus:   string(row.UserStatus),
		DeviceID:     row.UserSession.DeviceID.Int64,
	}, nil
}

// Touch glisse la fenetre d'inactivite. l'appelant decide quand : l'appeler a
// chaque requete ferait une ecriture par requete authentifiee (auth.sql).
func (r *Repository) Touch(ctx context.Context, sessionID int64) error {
	return r.q.TouchSession(ctx, sessionID)
}
