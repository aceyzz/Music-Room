package outbox

import (
	"context"
	"fmt"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"github.com/jackc/pgx/v5"
)

// DB is what a repository needs to run the pattern: enough to query, and enough
// to open a transaction. *pgxpool.Pool satisfies it.
//
// Declared here rather than per-repository because every consumer needs exactly
// this and the four copies said nothing different.
type DB interface {
	sqlc.DBTX
	Begin(ctx context.Context) (pgx.Tx, error)
}

// InTx runs one domain mutation and the tuple intents it owes, atomically.
//
// This exists to make the pattern's one rule unbreakable rather than merely
// documented. The rule is: enqueue on the SAME transaction as the domain change,
// deliver after the commit. Passing the pool to Enqueue instead of the
// transaction compiles, runs, passes tests, and silently reduces the whole design
// to a best-effort dual write -- the outbox row would commit separately from the
// data it describes, which is the exact failure the outbox removes. Here, fn only
// ever receives queries bound to the transaction and never sees a handle it could
// get wrong.
//
// fn receives the transaction itself rather than a *sqlc.Queries bound to it,
// because some callers need to hand it to another package (the song cache, which
// writes through the same transaction). It is one line to wrap -- and the handle
// fn cannot get hold of is the pool, which is the only one that would be wrong.
//
// fn returns its result, the changes it owes, and an error. Returning the changes
// rather than enqueuing them keeps fn free of the outbox entirely: it describes
// what changed, and the ordering guarantees are applied around it.
//
// Several changes are allowed and normal. One Change is one OBJECT's worth of
// work -- blocking a user touches the pair and every device grant between them,
// and each of those is its own object with its own ordering. One change spanning
// them would serialise against none of them correctly.
//
// Delivery happens after the commit, on db rather than the (now finished)
// transaction, and its failures are swallowed: by then the data and the intent
// are both durable, so a failure is a delay and not a lost write. Failing the
// user's request because a secondary system is slow would trade a self-healing
// problem for a user-visible one.
func InTx[T any](
	ctx context.Context,
	outbox *Outbox,
	db DB,
	fn func(ctx context.Context, tx pgx.Tx) (T, []authz.Change, error),
) (T, error) {
	var zero T

	tx, err := db.Begin(ctx)
	if err != nil {
		return zero, fmt.Errorf("ouverture de transaction : %w", err)
	}
	// Sans effet après un Commit réussi ; couvre tous les retours en erreur
	// au-dessus sans un defer par branche.
	defer func() { _ = tx.Rollback(ctx) }()

	result, changes, err := fn(ctx, tx)
	if err != nil {
		return zero, err
	}

	pending := make([]Pending, 0, len(changes))
	for _, change := range changes {
		entry, err := outbox.Enqueue(ctx, tx, change)
		if err != nil {
			return zero, err
		}
		pending = append(pending, entry)
	}

	if err := tx.Commit(ctx); err != nil {
		return zero, fmt.Errorf("commit : %w", err)
	}

	// Synchrone : le graphe doit être à jour quand la réponse part, sinon la
	// première requête du client sur la ressource qu'il vient de créer peut être
	// refusée. En ordre d'enqueue, parce que deux changements sur le même objet
	// doivent s'appliquer dans l'ordre où ils ont été décidés.
	for _, entry := range pending {
		outbox.Deliver(ctx, db, entry)
	}

	return result, nil
}
