-- Transactional outbox for OpenFGA tuple writes (docs/data-model.md 14).
--
-- Postgres and OpenFGA are two systems and there is no distributed transaction
-- between them. The gap this table closes: a domain change commits, the process
-- dies before the tuple write lands, and nothing anywhere records that a tuple is
-- owed. The permission graph silently diverges from the data and no amount of
-- retry logic finds it, because there is nothing to retry from.
--
-- So the row is inserted in the SAME transaction as the domain change. That makes
-- "a committed change always has a durable tuple intent" an invariant of the
-- database rather than a property of the code path. Everything after the commit --
-- the inline attempt, the retries, the reconciliation worker -- is best-effort on
-- top of an intent that cannot be lost.
--
-- Self-pruning: rows are DELETED on success, not marked done. Only unfinished work
-- lives here, so in a healthy system the table is empty and its indexes cost
-- nothing. Audit belongs in activity_logs (section 12), not in a hot-path write
-- table -- and "how many rows are in here" becomes a one-number health metric.

-- +goose Up
CREATE TABLE openfga_tuple_outbox (
    id              BIGSERIAL   PRIMARY KEY,

    -- One row per LOGICAL change, not per tuple, and applied as a single OpenFGA
    -- Write call (that API is transactional over its batch).
    --
    -- This is forced by the model, not a preference. Per-field profile visibility
    -- is encoded as two wildcard flags where "neither present" means private, and
    -- BOTH present silently reads as public -- a fail-OPEN state. Changing a field
    -- from public to friends is therefore a delete and a write that must land
    -- together. Split across two rows, the worker can apply them in either order
    -- and land in exactly that fail-open state. See authz/model.fga.
    --
    -- Shape: {"writes": [{user, relation, object, condition?}], "deletes": [...]}
    payload         JSONB       NOT NULL,

    -- The FGA object this change is about ("user:<uuid>", "playlist:<uuid>", ...).
    -- It exists to keep changes to the same object in order.
    --
    -- Without it: change A (bio public -> friends) fails, change B (friends ->
    -- public) succeeds, then A retries and wins. The graph ends up stale, and
    -- because "public" is the fail-open direction for these flags, stale here is
    -- the dangerous direction. The claim query therefore skips any row that has an
    -- older unfinished row for the same object. Per-object head-of-line blocking,
    -- not global -- one poisoned row must not stop every other object's changes.
    object_key      TEXT        NOT NULL,

    -- What produced this row ("register", "playlist_member_add", ...). Purely for
    -- the human staring at a row that has been stuck for an hour.
    origin          TEXT        NOT NULL,

    -- 'failed' is NOT terminal -- it means the inline attempt exhausted its
    -- retries and the worker now owns the row. The worker claims both statuses;
    -- the distinction exists so a human can tell "nobody has tried yet" from
    -- "tried and it did not work", which are different problems.
    --
    -- A CHECK rather than an enum: two values of pure infrastructure state have
    -- not earned a type in the shared domain enum namespace, and adding one there
    -- later would drag in the ALTER TYPE / NO TRANSACTION dance for nothing.
    status          TEXT        NOT NULL DEFAULT 'pending',
    attempts        INTEGER     NOT NULL DEFAULT 0,
    last_error      TEXT,

    -- Defaulted into the future so the worker does not race the inline attempt
    -- that runs immediately after commit. A successful inline write deletes the
    -- row long before this passes; a failed one pushes it out with backoff. The
    -- worker only ever sees rows the inline path has finished with or died during.
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '30 seconds',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT openfga_tuple_outbox_status_check CHECK (status IN ('pending', 'failed')),
    CONSTRAINT openfga_tuple_outbox_attempts_check CHECK (attempts >= 0)
);

-- The worker's claim query: due rows, oldest first.
CREATE INDEX openfga_tuple_outbox_claim_idx ON openfga_tuple_outbox (next_attempt_at, id);

-- The "is there an older unfinished row for this object?" test in that same query.
CREATE INDEX openfga_tuple_outbox_object_key_idx ON openfga_tuple_outbox (object_key, id);

-- +goose Down
DROP TABLE IF EXISTS openfga_tuple_outbox;
