-- Deezer song cache (docs/data-model.md 8).
--
-- One flat table, no artists / albums / genres / song_likes. This is a read-only
-- mirror refreshed wholesale by deezer_song_id, so update anomalies -- the
-- classic reason to normalise -- cannot occur. deezer_artist_id and
-- deezer_album_id stay as plain columns (no FK), so "more from this artist" is a
-- proxied Deezer call with no migration.
--
-- Field rule: only fields present in BOTH GET /track/{id} and GET /search?q=.
-- A row populated from a search result is therefore complete and never needs a
-- follow-up fetch to fill holes. That is why isrc, bpm and release_date are
-- absent -- by rule, not by accident.
--
-- duration_seconds stays an integer: the "MM:SS" formatting in deezer_client.go
-- is presentation and belongs to the client; the DB holds the sortable value.

-- +goose Up
CREATE TABLE songs (
    id               BIGSERIAL   PRIMARY KEY,
    deezer_song_id   BIGINT      NOT NULL,
    title            TEXT        NOT NULL,
    duration_seconds INTEGER     NOT NULL DEFAULT 0,
    artist_name      TEXT        NOT NULL DEFAULT '',
    deezer_artist_id BIGINT,
    album_title      TEXT        NOT NULL DEFAULT '',
    deezer_album_id  BIGINT,
    cover_url        TEXT,
    preview_url      TEXT,
    deezer_link      TEXT,
    explicit_lyrics  BOOLEAN     NOT NULL DEFAULT FALSE,
    readable         BOOLEAN     NOT NULL DEFAULT TRUE,
    rank             INTEGER     NOT NULL DEFAULT 0,
    synced_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- the upsert target of the read-through cache
    CONSTRAINT songs_deezer_song_id_key UNIQUE (deezer_song_id),
    CONSTRAINT songs_duration_check CHECK (duration_seconds >= 0)
);

-- revalidation sweep: rows whose synced_at is older than the TTL
CREATE INDEX songs_synced_at_idx ON songs (synced_at);

-- Local exact/prefix fallback when Deezer is unreachable. Btree on LOWER(),
-- not trigram: substring search would need pg_trgm, and search is Deezer's job.
CREATE INDEX songs_title_lower_idx ON songs (LOWER(title));
CREATE INDEX songs_artist_rank_idx ON songs (LOWER(artist_name), rank DESC);

-- +goose Down
DROP TABLE IF EXISTS songs;
