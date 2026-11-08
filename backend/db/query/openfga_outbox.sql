-- Transactional outbox for OpenFGA tuple writes (docs/data-model.md 14).
--
-- The only query here that matters to correctness is the enqueue, and it matters
-- because of WHERE it is called from: inside the same transaction as the domain
-- change. Everything else is delivery machinery.

-- Called on the domain transaction's tx handle, never on the pool. If this runs
-- outside that transaction the whole design collapses back into a best-effort
-- dual write with extra steps.
-- name: EnqueueTupleChange :one
INSERT INTO openfga_tuple_outbox (payload, object_key, origin)
VALUES ($1, $2, $3)
RETURNING *;

-- Leases a batch to the worker.
--
-- The UPDATE ... RETURNING form is deliberate: it claims and releases in one
-- statement, so no transaction is held open across the OpenFGA network call that
-- follows. A row is leased by pushing next_attempt_at into the future; if the
-- worker dies mid-flight the lease simply expires and a later pass picks the row
-- up. FOR UPDATE SKIP LOCKED in the subquery is what stops two workers claiming
-- the same row in the instant between the SELECT and the UPDATE.
--
-- The NOT EXISTS clause enforces per-object ordering: a row is not claimable while
-- an older row for the same object is still unfinished. Rows are deleted on
-- success, so "still present with a lower id" means exactly "not yet applied".
-- Ordering is per-object rather than global on purpose -- a single row that can
-- never succeed must not block changes to every other object in the system.
-- name: ClaimTupleChanges :many
UPDATE openfga_tuple_outbox
SET next_attempt_at = NOW() + make_interval(secs => sqlc.arg('lease_seconds')::int)
WHERE id IN (
    SELECT c.id
    FROM openfga_tuple_outbox c
    WHERE c.next_attempt_at <= NOW()
      AND NOT EXISTS (
          SELECT 1
          FROM openfga_tuple_outbox p
          WHERE p.object_key = c.object_key
            AND p.id < c.id
      )
    ORDER BY c.id
    LIMIT sqlc.arg('batch_size')
    FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- Success. The row is deleted rather than marked done: this table is a work queue,
-- not a log, and an empty table is the signal that the graph is in sync.
-- name: DeleteTupleChange :exec
DELETE FROM openfga_tuple_outbox
WHERE id = $1;

-- Failure. Records why and when to try again; the caller computes the backoff so
-- the policy lives in one place in Go rather than being split across SQL.
--
-- Status flips to 'failed' but the row stays claimable -- 'failed' means "the
-- inline attempt gave up and the worker owns this now", not "abandoned".
-- name: RescheduleTupleChange :exec
UPDATE openfga_tuple_outbox
SET status          = 'failed',
    attempts        = attempts + 1,
    last_error      = sqlc.arg('last_error'),
    next_attempt_at = NOW() + make_interval(secs => sqlc.arg('backoff_seconds')::int)
WHERE id = sqlc.arg('id');

-- Health. Backs a "how far behind is the permission graph?" metric or log line:
-- in a healthy system both numbers are zero, and the oldest row's age is the
-- honest answer to how stale a Check can currently be.
-- name: CountPendingTupleChanges :one
SELECT COUNT(*)                                        AS total,
       COUNT(*) FILTER (WHERE status = 'failed')       AS failed,
       COALESCE(MAX(EXTRACT(EPOCH FROM NOW() - created_at)), 0)::float8 AS oldest_age_seconds
FROM openfga_tuple_outbox;
