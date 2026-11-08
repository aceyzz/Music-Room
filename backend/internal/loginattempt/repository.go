package loginattempt

import (
	"context"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"github.com/jackc/pgx/v5/pgtype"
)

type Repository struct {
	q *sqlc.Queries
}

func NewRepository(db sqlc.DBTX) *Repository {
	return &Repository{q: sqlc.New(db)}
}

func (r *Repository) Record(ctx context.Context, email, ip string, succeeded bool, reason string) error {
	return r.q.RecordLoginAttempt(ctx, sqlc.RecordLoginAttemptParams{
		Email:         email,
		IpAddress:     ip,
		Succeeded:     succeeded,
		FailureReason: pgtype.Text{String: reason, Valid: reason != ""},
	})
}

func (r *Repository) CountRecentFailures(ctx context.Context, email string, since time.Time) (int64, error) {
	return r.q.CountRecentLoginFailures(ctx, sqlc.CountRecentLoginFailuresParams{
		Email: email,
		Since: pgtype.Timestamptz{Time: since, Valid: true},
	})
}

func (r *Repository) CountRecentFailuresFromIP(ctx context.Context, ip string, since time.Time) (int64, error) {
	return r.q.CountRecentLoginFailuresFromIP(ctx, sqlc.CountRecentLoginFailuresFromIPParams{
		IpAddress: ip,
		Since:     pgtype.Timestamptz{Time: since, Valid: true},
	})
}
