-- Music Playlist Editor (docs/data-model.md 9).
--
-- Real-time multi-user editing, visibility public/private (default public),
-- edit license everyone/invited_only (default everyone), and explicit handling
-- of concurrent edits.
--
-- Concurrency, in one transaction per mutation:
--
--   UPDATE playlists SET revision = revision + 1, updated_at = NOW()
--    WHERE id = $1 AND deleted_at IS NULL
--    RETURNING revision;              -- row lock serialises concurrent writers
--   -- ... apply the change to playlist_songs ...
--   INSERT INTO playlist_ops (playlist_id, revision, actor_id, op_type, payload)
--   VALUES ($1, $revision, $actor, $op, $payload);
--
-- The row lock makes revisions gapless and totally ordered, so a reconnecting
-- client replays the tail of playlist_ops from its last-seen revision instead of
-- refetching the playlist.

-- +goose Up
CREATE TABLE playlists (
    id                     BIGSERIAL           PRIMARY KEY,
    public_id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    owner_id               BIGINT              NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name                   TEXT                NOT NULL,
    description            TEXT,
    cover_image_id         BIGINT              REFERENCES images (id) ON DELETE SET NULL,
    visibility             resource_visibility NOT NULL DEFAULT 'public',
    edit_license           edit_license        NOT NULL DEFAULT 'everyone',
    revision               BIGINT              NOT NULL DEFAULT 0,
    song_count             INTEGER             NOT NULL DEFAULT 0,
    total_duration_seconds INTEGER             NOT NULL DEFAULT 0,
    deleted_at             TIMESTAMPTZ,
    created_at             TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT playlists_public_id_key UNIQUE (public_id)
);

CREATE INDEX playlists_owner_id_idx ON playlists (owner_id) WHERE deleted_at IS NULL;
-- public playlist discovery
CREATE INDEX playlists_public_idx ON playlists (created_at DESC)
    WHERE deleted_at IS NULL AND visibility = 'public';

CREATE TRIGGER playlists_set_updated_at
    BEFORE UPDATE ON playlists
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The owner gets an 'owner' row at creation, so no access query has to
-- special-case playlists.owner_id.
CREATE TABLE playlist_members (
    playlist_id   BIGINT      NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    user_id       BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role          member_role NOT NULL DEFAULT 'editor',
    invited_by_id BIGINT      REFERENCES users (id) ON DELETE SET NULL,
    joined_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (playlist_id, user_id)
);

-- "which playlists can I see?" is the direction the PK does not serve
CREATE INDEX playlist_members_user_id_idx ON playlist_members (user_id);

-- Always targets an existing account: nobody uses the app without one. Hence no
-- invitee_email, no CHECK reconciling two nullable invitee columns, and no
-- token_hash for shareable links -- the row itself is the mechanism, delivered
-- in-app. An invitee is explicitly NOT required to be a friend; the only
-- precondition is the absence of a user_blocks row in either direction.
CREATE TABLE playlist_invitations (
    id              BIGSERIAL         PRIMARY KEY,
    playlist_id     BIGINT            NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    invitee_user_id BIGINT            NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    invited_by_id   BIGINT            NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    offered_role    member_role       NOT NULL DEFAULT 'editor',
    status          invitation_status NOT NULL DEFAULT 'pending',
    expires_at      TIMESTAMPTZ,
    responded_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

-- stops invite spam
CREATE UNIQUE INDEX playlist_invitations_one_pending_per_invitee
    ON playlist_invitations (playlist_id, invitee_user_id)
    WHERE status = 'pending';

CREATE INDEX playlist_invitations_invitee_pending_idx
    ON playlist_invitations (invitee_user_id, created_at DESC)
    WHERE status = 'pending';

-- position is NUMERIC and set to the midpoint of its neighbours, so inserting or
-- moving a song writes exactly one row and never renumbers the rest. Two users
-- moving different songs do not conflict at all. Midpoints are computed as
-- (a + b) * 0.5, which NUMERIC keeps exact (division rounds to a fixed
-- scale), so no gap ever runs out and nothing rebalances. See
-- MovePlaylistSong in db/query/playlists.sql.
--
-- No unique on (playlist_id, song_id): duplicates are legitimate in a DJ set.
CREATE TABLE playlist_songs (
    id          BIGSERIAL   PRIMARY KEY,
    playlist_id BIGINT      NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    song_id     BIGINT      NOT NULL REFERENCES songs (id) ON DELETE RESTRICT,
    position    NUMERIC     NOT NULL,
    added_by_id BIGINT      REFERENCES users (id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX playlist_songs_playlist_position_idx ON playlist_songs (playlist_id, position);
CREATE INDEX playlist_songs_song_id_idx ON playlist_songs (song_id);

-- Append-only journal. (playlist_id, revision) is UNIQUE, which is what makes
-- gap-free replay possible.
CREATE TABLE playlist_ops (
    id          BIGSERIAL        PRIMARY KEY,
    playlist_id BIGINT           NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    revision    BIGINT           NOT NULL,
    actor_id    BIGINT           REFERENCES users (id) ON DELETE SET NULL,
    op_type     playlist_op_type NOT NULL,
    payload     JSONB            NOT NULL DEFAULT '{}'::JSONB,
    created_at  TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

    CONSTRAINT playlist_ops_revision_key UNIQUE (playlist_id, revision)
);

-- +goose Down
DROP TABLE IF EXISTS playlist_ops;
DROP TABLE IF EXISTS playlist_songs;
DROP TABLE IF EXISTS playlist_invitations;
DROP TABLE IF EXISTS playlist_members;
DROP TABLE IF EXISTS playlists;
