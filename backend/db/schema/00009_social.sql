-- Social graph (docs/data-model.md 7).
--
-- Two tables on purpose. friend_requests is directional and auditable (who
-- asked, when, declined or not). friendships is undirected and canonical:
-- exactly one row per pair, enforced by CHECK (user_a_id < user_b_id), so
-- "are A and B friends?" is a single PK lookup with the pair pre-sorted by the
-- caller -- no OR, no duplicate rows to reconcile.

-- +goose Up
CREATE TABLE friend_requests (
    id           BIGSERIAL             PRIMARY KEY,
    requester_id BIGINT                NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    addressee_id BIGINT                NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status       friend_request_status  NOT NULL DEFAULT 'pending',
    message      TEXT,
    responded_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ            NOT NULL DEFAULT NOW(),

    CONSTRAINT friend_requests_not_self_check CHECK (requester_id <> addressee_id)
);

-- Blocks crossed pending requests (A->B and B->A both open) by normalising the
-- pair before uniqueness is checked.
CREATE UNIQUE INDEX friend_requests_one_open_per_pair
    ON friend_requests (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id))
    WHERE status = 'pending';

CREATE INDEX friend_requests_addressee_pending_idx
    ON friend_requests (addressee_id, created_at DESC)
    WHERE status = 'pending';

CREATE TABLE friendships (
    user_a_id               BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    user_b_id               BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_from_request_id BIGINT      REFERENCES friend_requests (id) ON DELETE SET NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_a_id, user_b_id),
    CONSTRAINT friendships_canonical_order_check CHECK (user_a_id < user_b_id)
);

-- The PK only covers lookups leading with user_a_id, but "list my friends"
-- must match either side.
CREATE INDEX friendships_user_b_id_idx ON friendships (user_b_id);

-- Directional, and checked before inserting any invitation row. Since
-- invitations deliberately target non-friends, this is the only thing standing
-- between a private event's invite list and a harassment vector.
CREATE TABLE user_blocks (
    blocker_id BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    blocked_id BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (blocker_id, blocked_id),
    CONSTRAINT user_blocks_not_self_check CHECK (blocker_id <> blocked_id)
);

-- "has anyone blocked me?" is the direction the PK does not serve
CREATE INDEX user_blocks_blocked_id_idx ON user_blocks (blocked_id);

-- +goose Down
DROP TABLE IF EXISTS user_blocks;
DROP TABLE IF EXISTS friendships;
DROP TABLE IF EXISTS friend_requests;
