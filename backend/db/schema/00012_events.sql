-- Music Track Vote: events / listening sessions (docs/data-model.md 10).
--
-- Anyone can suggest or vote for the next track; a track with more votes plays
-- earlier; visibility public/private (default public); vote license everyone /
-- invited_only / location_time; concurrent votes must be correct.

-- +goose Up
CREATE TABLE events (
    id                   BIGSERIAL           PRIMARY KEY,
    public_id            UUID                NOT NULL DEFAULT gen_random_uuid(),
    host_id              BIGINT              NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    source_playlist_id   BIGINT              REFERENCES playlists (id) ON DELETE SET NULL,
    name                 TEXT                NOT NULL,
    description          TEXT,
    visibility           resource_visibility NOT NULL DEFAULT 'public',
    vote_license         vote_license        NOT NULL DEFAULT 'everyone',
    status               event_status        NOT NULL DEFAULT 'scheduled',
    starts_at            TIMESTAMPTZ,
    ends_at              TIMESTAMPTZ,
    venue_latitude       NUMERIC(9, 6),
    venue_longitude      NUMERIC(9, 6),
    venue_radius_meters  INTEGER,
    vote_window_start    TIME,
    vote_window_end      TIME,
    vote_window_timezone TEXT,
    revision             BIGINT              NOT NULL DEFAULT 0,
    deleted_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT events_public_id_key UNIQUE (public_id),
    CONSTRAINT events_window_check CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at),
    CONSTRAINT events_radius_check CHECK (venue_radius_meters IS NULL OR venue_radius_meters > 0),

    -- The license and the data it needs cannot disagree. vote_window_timezone is
    -- required because a wall-clock window like "4-6 PM" is meaningless without
    -- the venue's zone.
    CONSTRAINT events_location_time_license_check CHECK (
        vote_license <> 'location_time'
        OR (venue_latitude       IS NOT NULL
            AND venue_longitude      IS NOT NULL
            AND venue_radius_meters  IS NOT NULL
            AND vote_window_start    IS NOT NULL
            AND vote_window_end      IS NOT NULL
            AND vote_window_timezone IS NOT NULL)
    )
);

CREATE INDEX events_host_id_idx ON events (host_id) WHERE deleted_at IS NULL;
CREATE INDEX events_source_playlist_id_idx ON events (source_playlist_id);
-- public event discovery
CREATE INDEX events_public_live_idx ON events (starts_at DESC)
    WHERE deleted_at IS NULL AND visibility = 'public';

CREATE TRIGGER events_set_updated_at
    BEFORE UPDATE ON events
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE event_members (
    event_id      BIGINT      NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    user_id       BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role          member_role NOT NULL DEFAULT 'editor',
    invited_by_id BIGINT      REFERENCES users (id) ON DELETE SET NULL,
    joined_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at  TIMESTAMPTZ,

    PRIMARY KEY (event_id, user_id)
);

CREATE INDEX event_members_user_id_idx ON event_members (user_id);

-- Non-friends welcome: inviting people you are not friends with is the point of
-- an event. Gated only by user_blocks, checked in the service before insert.
CREATE TABLE event_invitations (
    id              BIGSERIAL         PRIMARY KEY,
    event_id        BIGINT            NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    invitee_user_id BIGINT            NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    invited_by_id   BIGINT            NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status          invitation_status NOT NULL DEFAULT 'pending',
    expires_at      TIMESTAMPTZ,
    responded_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX event_invitations_one_pending_per_invitee
    ON event_invitations (event_id, invitee_user_id)
    WHERE status = 'pending';

CREATE INDEX event_invitations_invitee_pending_idx
    ON event_invitations (invitee_user_id, created_at DESC)
    WHERE status = 'pending';

-- The queue needs no position column: it IS the vote ranking.
--
--   SELECT * FROM event_queue_entries
--    WHERE event_id = $1 AND status = 'queued'
--    ORDER BY vote_count DESC, score_reached_at ASC;
--
-- score_reached_at holds the instant the entry reached its CURRENT vote total,
-- which is precisely "first song to reach that number of votes". It is exact
-- only because vote_count is monotonic (see event_queue_votes).
--
-- It defaults to NOW(), the transaction timestamp, so a zero-vote entry gets
-- exactly its own created_at and sorts by suggestion time. On increment it is
-- set from the inserted vote's clock_timestamp() and wrapped in GREATEST -- see
-- the comment on event_queue_votes for why NOW() is wrong there.
CREATE TABLE event_queue_entries (
    id               BIGSERIAL          PRIMARY KEY,
    event_id         BIGINT             NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    song_id          BIGINT             NOT NULL REFERENCES songs (id) ON DELETE RESTRICT,
    suggested_by_id  BIGINT             REFERENCES users (id) ON DELETE SET NULL,
    status           queue_entry_status NOT NULL DEFAULT 'queued',
    vote_count       INTEGER            NOT NULL DEFAULT 0,
    score_reached_at TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    played_at        TIMESTAMPTZ,
    created_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),

    CONSTRAINT event_queue_entries_vote_count_check CHECK (vote_count >= 0)
);

-- the hot read path, covered
CREATE INDEX event_queue_entries_ranking_idx
    ON event_queue_entries (event_id, status, vote_count DESC, score_reached_at);

-- A song may be re-suggested after it has played, but not queued twice at once.
CREATE UNIQUE INDEX event_queue_entries_one_active_per_song
    ON event_queue_entries (event_id, song_id)
    WHERE status IN ('queued', 'playing');

CREATE INDEX event_queue_entries_song_id_idx ON event_queue_entries (song_id);

-- Upvotes only, and final: no value column, no unvote. The subject only ever
-- says users "suggest or vote for" the next track. Finality is what keeps
-- vote_count monotonic, which is the precondition for the tiebreaker above.
-- A user tapping twice is a no-op, not a toggle.
--
-- Five mechanisms, one statement (db/query/events.sql, CastQueueVote):
--
--   WITH entry AS (
--       SELECT id FROM event_queue_entries WHERE id = $1 AND status = 'queued' FOR UPDATE
--   ), inserted AS (
--       INSERT INTO event_queue_votes (queue_entry_id, user_id, voter_latitude, voter_longitude)
--       SELECT entry.id, $2, $3, $4 FROM entry
--       ON CONFLICT (queue_entry_id, user_id) DO NOTHING
--       RETURNING created_at
--   )
--   UPDATE event_queue_entries e
--      SET vote_count       = e.vote_count + 1,
--          score_reached_at = GREATEST(e.score_reached_at, (SELECT created_at FROM inserted))
--    WHERE e.id = $1
--      AND e.status = 'queued'
--      AND EXISTS (SELECT 1 FROM inserted)
--   RETURNING e.vote_count, e.score_reached_at;
--
-- 1. UNIQUE (queue_entry_id, user_id) makes double-voting structurally
--    impossible -- no read-then-write race can defeat it.
-- 2. ON CONFLICT DO NOTHING makes the RPC idempotent under client retries.
-- 3. The UPDATE is a single-row read-modify-write under a Postgres row lock, so
--    N simultaneous votes serialise and all land. Correct under READ COMMITTED;
--    no SERIALIZABLE, no retry loop.
-- 4. created_at defaults to clock_timestamp(), NOT NOW(), and the UPDATE takes
--    GREATEST of the old value. This one matters and is not cosmetic:
--
--    NOW() is the TRANSACTION timestamp. Concurrent voters acquire the entry's
--    row lock in an order unrelated to when their transactions began, so a voter
--    that started earlier can win the lock later and stamp score_reached_at
--    BACKWARDS -- breaking both the ordering and the reconciliation invariant.
--    Verified empirically: 80 racing votes left score_reached_at < MAX(vote
--    created_at). clock_timestamp() is read per statement while the lock is
--    held, and GREATEST makes the column monotonic no matter what.
--
--    Invariant, now exact: score_reached_at = MAX(created_at) over the entry's
--    votes, or the entry's own created_at when it has none. One query to check.
-- 5. The vote row is written only through `entry`, which locks the entry while
--    it is still queued. A data-modifying CTE runs whatever the outer UPDATE
--    matches, so an unconditional INSERT stored votes for songs already playing
--    while vote_count stayed put -- vote rows and vote_count drifted apart.
--    Invariant: vote_count = COUNT(votes) per entry (loadtest/verify checks it).
--
-- Coordinates are persisted as the audit trail for a location_time decision that
-- can be contested.
CREATE TABLE event_queue_votes (
    id              BIGSERIAL     PRIMARY KEY,
    queue_entry_id  BIGINT        NOT NULL REFERENCES event_queue_entries (id) ON DELETE CASCADE,
    user_id         BIGINT        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    voter_latitude  NUMERIC(9, 6),
    voter_longitude NUMERIC(9, 6),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT event_queue_votes_one_per_user_key UNIQUE (queue_entry_id, user_id)
);

CREATE INDEX event_queue_votes_user_id_idx ON event_queue_votes (user_id);

-- A 1:1 side table rather than columns on events: it is written on every
-- play/pause/seek (several times per song) while events is nearly static, so
-- keeping it separate avoids churning the row every discovery query reads.
-- position_ms plus updated_at lets a joining client compute the playhead without
-- the server pushing ticks.
CREATE TABLE event_playback_states (
    event_id             BIGINT      PRIMARY KEY REFERENCES events (id) ON DELETE CASCADE,
    current_entry_id     BIGINT      REFERENCES event_queue_entries (id) ON DELETE SET NULL,
    controller_user_id   BIGINT      REFERENCES users (id) ON DELETE SET NULL,
    controller_device_id BIGINT      REFERENCES devices (id) ON DELETE SET NULL,
    is_paused            BOOLEAN     NOT NULL DEFAULT TRUE,
    position_ms          INTEGER     NOT NULL DEFAULT 0,
    started_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT event_playback_states_position_check CHECK (position_ms >= 0)
);

CREATE INDEX event_playback_states_current_entry_id_idx ON event_playback_states (current_entry_id);

CREATE TRIGGER event_playback_states_set_updated_at
    BEFORE UPDATE ON event_playback_states
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Same append-only journal as playlist_ops: (event_id, revision) UNIQUE, replay
-- from the client's last-seen revision.
CREATE TABLE event_ops (
    id         BIGSERIAL     PRIMARY KEY,
    event_id   BIGINT        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    revision   BIGINT        NOT NULL,
    actor_id   BIGINT        REFERENCES users (id) ON DELETE SET NULL,
    op_type    event_op_type NOT NULL,
    payload    JSONB         NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT event_ops_revision_key UNIQUE (event_id, revision)
);

-- +goose Down
DROP TABLE IF EXISTS event_ops;
DROP TABLE IF EXISTS event_playback_states;
DROP TABLE IF EXISTS event_queue_votes;
DROP TABLE IF EXISTS event_queue_entries;
DROP TABLE IF EXISTS event_invitations;
DROP TABLE IF EXISTS event_members;
DROP TABLE IF EXISTS events;
