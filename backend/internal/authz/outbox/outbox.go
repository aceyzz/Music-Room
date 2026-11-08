// Package outbox delivers authz.Change values to OpenFGA without losing any.
//
// It exists because Postgres and OpenFGA are two systems with no transaction
// between them. The naive dual write -- commit the row, then call the write API --
// has a window: if the process dies in it, the data changed and the permission
// graph did not, and nothing anywhere records that a tuple is owed. That
// divergence is silent, permanent, and can only be found by comparing the two
// systems in full.
//
// So the intent is written INSIDE the domain transaction. After that the delivery
// is allowed to fail as often as it likes: the row is the durable record that
// work remains, and both the inline attempt and the background worker read it.
//
// The split from package authz is deliberate. Tuple construction is pure and has
// no business importing the persistence layer; everything that touches sqlc lives
// here.
package outbox

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"github.com/jackc/pgx/v5/pgtype"
)

const (
	// Attempts made inline, before the row is handed to the worker. Small on
	// purpose: this runs inside a user's request. If OpenFGA is genuinely down,
	// retrying harder here only makes registration slower without making it
	// succeed.
	inlineAttempts = 3

	// Total wall clock the inline attempt may spend, across all retries. Bounds
	// the latency this adds to a request even when OpenFGA is hanging rather
	// than refusing.
	inlineBudget = 2 * time.Second

	// Pause between inline attempts. Short enough to fit the budget, long enough
	// that a blip has a chance to clear.
	inlinePause = 100 * time.Millisecond

	// Budget for writing down what happened. Separate from inlineBudget because
	// recording a timeout must not itself be subject to the timeout that just
	// expired -- see settle.
	settleBudget = 3 * time.Second

	// The worker's schedule, doubling per attempt.
	retryBaseDelay = 30 * time.Second
	retryMaxDelay  = 10 * time.Minute

	// How long a claimed row stays leased to a worker before another pass may
	// take it. Must exceed the time one delivery can take.
	claimLease = 60 * time.Second
)

// Applier is the part of authz.Client this package needs. Declared here, on the
// consumer side, so tests can substitute a fake without a network.
type Applier interface {
	Apply(ctx context.Context, change authz.Change) error
}

// Outbox enqueues changes transactionally and delivers them.
type Outbox struct {
	fga Applier
}

func New(fga Applier) *Outbox {
	return &Outbox{fga: fga}
}

// Pending is an enqueued change that has not been delivered yet. Returned by
// Enqueue and handed to Deliver once the caller's transaction has committed.
type Pending struct {
	id     int64
	change authz.Change
}

// Enqueue records the intent to apply change.
//
// db MUST be the same transaction as the domain change it accompanies. Passing a
// pool here compiles, runs, and quietly reduces this whole package to a
// best-effort dual write with extra machinery -- the row would commit separately
// from the data it describes, which is the exact failure the design removes.
//
// An empty change is not an error; it produces no row and delivers nothing.
func (o *Outbox) Enqueue(ctx context.Context, db sqlc.DBTX, change authz.Change) (Pending, error) {
	if change.IsEmpty() {
		return Pending{}, nil
	}
	if change.ObjectKey == "" {
		return Pending{}, fmt.Errorf("outbox: change has no ObjectKey, so the worker cannot order it")
	}

	payload, err := json.Marshal(change)
	if err != nil {
		return Pending{}, fmt.Errorf("outbox: marshal change: %w", err)
	}

	row, err := sqlc.New(db).EnqueueTupleChange(ctx, sqlc.EnqueueTupleChangeParams{
		Payload:   payload,
		ObjectKey: change.ObjectKey,
		Origin:    change.Origin,
	})
	if err != nil {
		return Pending{}, fmt.Errorf("outbox: enqueue: %w", err)
	}

	return Pending{id: row.ID, change: change}, nil
}

// Deliver makes the inline attempt, after the caller's transaction has committed.
//
// It returns nothing, and that is the point. By the time it runs, the domain
// change is durable and so is the intent to sync it; a failure here is a delay,
// not a lost write, and there is nothing useful for the caller to do about it.
// Failing the user's request because a secondary system is slow would trade a
// self-healing problem for a user-visible one.
//
// The context is detached from the caller's before the timeout is applied: a
// client that disconnects mid-registration should not abort the tuple write it
// already paid for. The budget still bounds it.
func (o *Outbox) Deliver(ctx context.Context, db sqlc.DBTX, pending Pending) {
	if pending.id == 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), inlineBudget)
	defer cancel()

	err := o.attempt(ctx, pending.change, inlineAttempts)
	o.settle(ctx, db, pending.id, 0, err)
}

// attempt applies the change, retrying up to n times.
func (o *Outbox) attempt(ctx context.Context, change authz.Change, n int) error {
	var err error
	for i := 0; i < n; i++ {
		if i > 0 {
			select {
			case <-ctx.Done():
				return fmt.Errorf("%w (after %d attempts)", ctx.Err(), i)
			case <-time.After(inlinePause):
			}
		}
		if err = o.fga.Apply(ctx, change); err == nil {
			return nil
		}
	}
	return err
}

// settle records the outcome: gone on success, rescheduled on failure.
//
// The bookkeeping gets a fresh context rather than the delivery's, and that is
// not a detail. A timeout is the most common reason to arrive here with a
// failure, and by then the delivery context is already dead -- so reusing it
// meant the reschedule failed exactly when it mattered. The row stayed pending
// with attempts=0 forever: still delivered eventually, since the worker picks it
// up regardless, but with no backoff growth and no last_error for whoever has to
// work out why it is stuck.
//
// A failure to record the failure is still only logged. The row keeps its
// previous next_attempt_at and gets retried anyway, so the sync converges; the
// cost is the attempt counter's accuracy.
func (o *Outbox) settle(ctx context.Context, db sqlc.DBTX, id int64, attempts int32, cause error) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), settleBudget)
	defer cancel()

	queries := sqlc.New(db)

	if cause == nil {
		if err := queries.DeleteTupleChange(ctx, id); err != nil {
			// The change IS applied; only the bookkeeping failed. The worker will
			// retry it, the writes are idempotent, and the row goes away then.
			log.Printf("authz outbox: row %d applied but not cleared: %v", id, err)
		}
		return
	}

	log.Printf("authz outbox: row %d failed (attempt %d), retrying later: %v", id, attempts+1, cause)

	err := queries.RescheduleTupleChange(ctx, sqlc.RescheduleTupleChangeParams{
		ID:             id,
		LastError:      pgtype.Text{String: truncate(cause.Error(), 500), Valid: true},
		BackoffSeconds: int32(backoff(attempts).Seconds()),
	})
	if err != nil {
		log.Printf("authz outbox: row %d could not be rescheduled: %v", id, err)
	}
}

// backoff doubles per attempt up to a ceiling. Written as a loop rather than a
// shift so a row that has failed sixty times cannot overflow its way into a
// negative delay.
func backoff(attempts int32) time.Duration {
	delay := retryBaseDelay
	for i := int32(0); i < attempts && delay < retryMaxDelay; i++ {
		delay *= 2
	}
	if delay > retryMaxDelay {
		delay = retryMaxDelay
	}
	return delay
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max]
}
