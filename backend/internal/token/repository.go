// package token : seul acces a la table user_tokens.
// tokens a usage unique envoyes par email (verification, reset mot de passe).
package token

import (
	"context"
	"errors"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

var ErrNotFound = errors.New("token not found")

type Purpose string

const (
	PurposeEmailVerification Purpose = "email_verification"
	PurposePasswordReset     Purpose = "password_reset"
)

// Details : ce que la base sait d'un token.
// aucun jugement : le service decide s'il est valable.
type Details struct {
	ID              int64
	UserID          int64
	UserPublicID    string
	ExpiresAt       time.Time
	IsConsumed      bool
	IsEmailVerified bool
}

type Repository struct {
	q *sqlc.Queries
}

func NewRepository(db sqlc.DBTX) *Repository {
	return &Repository{q: sqlc.New(db)}
}

// Issue invalide les tokens en attente puis en cree un nouveau.
// tokenHash est l'empreinte SHA-256 : le code en clair n'arrive jamais ici.
func (r *Repository) Issue(ctx context.Context, userID int64, tokenHash []byte, expiresAt time.Time) error {
	if _, err := r.q.ConsumePendingTokens(ctx, sqlc.ConsumePendingTokensParams{
		UserID:  userID,
		Purpose: sqlc.TokenPurposeEmailVerification,
	}); err != nil {
		return err
	}

	_, err := r.q.CreateUserToken(ctx, sqlc.CreateUserTokenParams{
		UserID:    userID,
		Purpose:   sqlc.TokenPurposeEmailVerification,
		TokenHash: tokenHash,
		ExpiresAt: pgtype.Timestamptz{Time: expiresAt, Valid: true},
	})
	return err
}

// FindByHash lit le token. ne filtre ni expiration ni consommation.
func (r *Repository) FindByHash(ctx context.Context, tokenHash []byte) (Details, error) {
	row, err := r.q.GetUserTokenByHash(ctx, tokenHash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Details{}, ErrNotFound
		}
		return Details{}, err
	}

	return Details{
		ID:              row.ID,
		UserID:          row.UserID,
		UserPublicID:    row.UserPublicID.String(),
		ExpiresAt:       row.ExpiresAt.Time,
		IsConsumed:      row.ConsumedAt.Valid,
		IsEmailVerified: row.EmailVerifiedAt.Valid,
	}, nil
}

// Consume marque le token utilise. renvoie false s'il l'etait deja :
// la condition est dans le WHERE, donc deux appels simultanes ne peuvent
// pas reussir tous les deux.
func (r *Repository) Consume(ctx context.Context, tokenID int64) (bool, error) {
	rows, err := r.q.ConsumeUserToken(ctx, tokenID)
	if err != nil {
		return false, err
	}
	return rows > 0, nil
}

// MarkEmailVerified pose users.email_verified_at. idempotent.
func (r *Repository) MarkEmailVerified(ctx context.Context, userID int64) error {
	_, err := r.q.MarkEmailVerified(ctx, userID)
	return err
}

// FindEmail lit l'adresse du compte et si elle est deja verifiee.
func (r *Repository) FindEmail(ctx context.Context, userID int64) (email string, verified bool, err error) {
	row, err := r.q.GetUserEmailVerification(ctx, userID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", false, ErrNotFound
		}
		return "", false, err
	}
	return row.Email, row.EmailVerifiedAt.Valid, nil
}

func (r *Repository) IssueCode(ctx context.Context, userID int64, purpose Purpose, tokenHash []byte, expiresAt time.Time) error {
	p := sqlc.TokenPurpose(purpose)

	if _, err := r.q.ConsumePendingTokens(ctx, sqlc.ConsumePendingTokensParams{
		UserID:  userID,
		Purpose: p,
	}); err != nil {
		return err
	}

	_, err := r.q.CreateUserToken(ctx, sqlc.CreateUserTokenParams{
		UserID:    userID,
		Purpose:   p,
		TokenHash: tokenHash,
		ExpiresAt: pgtype.Timestamptz{Time: expiresAt, Valid: true},
	})
	return err
}

func (r *Repository) UseCodeAttempt(ctx context.Context, userID int64, purpose Purpose, maxAttempts int16) (int64, []byte, error) {
	row, err := r.q.UseTokenAttempt(ctx, sqlc.UseTokenAttemptParams{
		UserID:      userID,
		Purpose:     sqlc.TokenPurpose(purpose),
		MaxAttempts: maxAttempts,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, nil, ErrNotFound
		}
		return 0, nil, err
	}
	return row.ID, row.TokenHash, nil
}

func (r *Repository) CountRecentCodes(ctx context.Context, userID int64, purpose Purpose, shortSince, longSince time.Time) (int64, int64, error) {
	row, err := r.q.CountRecentTokens(ctx, sqlc.CountRecentTokensParams{
		ShortSince: pgtype.Timestamptz{Time: shortSince, Valid: true},
		UserID:     userID,
		Purpose:    sqlc.TokenPurpose(purpose),
		LongSince:  pgtype.Timestamptz{Time: longSince, Valid: true},
	})
	if err != nil {
		return 0, 0, err
	}
	return row.ShortWindow, row.LongWindow, nil
}
