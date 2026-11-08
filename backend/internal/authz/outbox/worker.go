package outbox

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"time"

	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
)

// WorkerConfig tunes the reconciliation loop.
type WorkerConfig struct {
	// Interval between passes. The lag this adds to a permission change is at
	// most one interval plus the retry backoff, and only for changes whose
	// inline attempt already failed.
	Interval time.Duration
	// Rows per pass.
	BatchSize int32
}

func (c WorkerConfig) withDefaults() WorkerConfig {
	if c.Interval <= 0 {
		c.Interval = 15 * time.Second
	}
	if c.BatchSize <= 0 {
		c.BatchSize = 20
	}
	return c
}

// Worker drains the outbox.
//
// One worker, deliberately. The claim query keeps changes to the same object in
// order by refusing to hand out a row while an older row for that object is
// unfinished, and a single consumer means that ordering also holds across a
// batch. Scaling to several workers is possible -- the claim already uses FOR
// UPDATE SKIP LOCKED so they would not collide -- but it needs each object's
// rows routed to the same worker, and there is no volume here that asks for it.
type Worker struct {
	outbox *Outbox
	db     sqlc.DBTX
	config WorkerConfig
}

func NewWorker(outbox *Outbox, db sqlc.DBTX, config WorkerConfig) *Worker {
	return &Worker{outbox: outbox, db: db, config: config.withDefaults()}
}

// Run drains the outbox until ctx is cancelled. Blocking; run it in a goroutine.
func (w *Worker) Run(ctx context.Context) {
	log.Printf("authz outbox worker: every %s, %d rows per pass", w.config.Interval, w.config.BatchSize)

	ticker := time.NewTicker(w.config.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("authz outbox worker: stopped")
			return
		case <-ticker.C:
			if err := w.RunOnce(ctx); err != nil && !errors.Is(err, context.Canceled) {
				// A failed pass is not notable on its own -- OpenFGA being down is
				// exactly the situation this worker exists for. The rows stay put.
				log.Printf("authz outbox worker: pass failed: %v", err)
			}
		}
	}
}

// RunOnce claims a batch and delivers it. Exported so a test can drive the loop
// deterministically instead of waiting on a ticker.
func (w *Worker) RunOnce(ctx context.Context) error {
	rows, err := sqlc.New(w.db).ClaimTupleChanges(ctx, sqlc.ClaimTupleChangesParams{
		LeaseSeconds: int32(claimLease.Seconds()),
		BatchSize:    w.config.BatchSize,
	})
	if err != nil {
		return err
	}

	for _, row := range rows {
		if ctx.Err() != nil {
			// Leases expire on their own; whatever is left is picked up next pass.
			return ctx.Err()
		}
		w.deliverRow(ctx, row)
	}
	return nil
}

func (w *Worker) deliverRow(ctx context.Context, row sqlc.OpenfgaTupleOutbox) {
	change, err := decode(row)
	if err != nil {
		// Unparseable payload. Retrying cannot fix it, but deleting the row would
		// destroy the only record that a change is owed -- and this row is holding
		// back every later change to the same object, so it needs a human. Record
		// it and let the backoff push it out of the way.
		w.outbox.settle(ctx, w.db, row.ID, row.Attempts, err)
		return
	}

	err = w.outbox.attempt(ctx, change, 1)
	w.outbox.settle(ctx, w.db, row.ID, row.Attempts, err)
}

// decode rebuilds the change from the row. ObjectKey and Origin come from their
// columns rather than the payload -- they are indexed and queried, so they are
// not duplicated into the JSON.
func decode(row sqlc.OpenfgaTupleOutbox) (authz.Change, error) {
	var change authz.Change
	if err := json.Unmarshal(row.Payload, &change); err != nil {
		return authz.Change{}, err
	}
	change.ObjectKey = row.ObjectKey
	change.Origin = row.Origin
	return change, nil
}

// LogBacklog reports how far behind the permission graph is. In a healthy system
// every number is zero; a non-zero oldest age is the honest upper bound on how
// stale a Check can currently be.
func LogBacklog(ctx context.Context, db sqlc.DBTX) {
	stats, err := sqlc.New(db).CountPendingTupleChanges(ctx)
	if err != nil {
		log.Printf("authz outbox: backlog unknown: %v", err)
		return
	}
	if stats.Total == 0 {
		return
	}
	log.Printf("authz outbox: %d undelivered change(s), %d failed, oldest %.0fs",
		stats.Total, stats.Failed, stats.OldestAgeSeconds)
}
