-- Deezer song cache (docs/data-model.md 8).

-- The write half of the read-through cache: called with whatever GET /track/{id}
-- or GET /search returned, whether or not the song is already known.
--
-- ON CONFLICT on the deezer_song_id unique constraint refreshes every field
-- rather than DO NOTHING, because Deezer is the source of truth -- readable flips
-- when licensing changes and rank moves constantly. synced_at = NOW() is what
-- makes the row fresh again for the TTL sweep; nothing else updates it.
-- name: UpsertSongFromDeezer :one
INSERT INTO songs (deezer_song_id, title, duration_seconds,
                   artist_name, deezer_artist_id, album_title, deezer_album_id,
                   cover_url, preview_url, deezer_link,
                   explicit_lyrics, readable, rank)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
ON CONFLICT (deezer_song_id) DO UPDATE
SET title            = EXCLUDED.title,
    duration_seconds = EXCLUDED.duration_seconds,
    artist_name      = EXCLUDED.artist_name,
    deezer_artist_id = EXCLUDED.deezer_artist_id,
    album_title      = EXCLUDED.album_title,
    deezer_album_id  = EXCLUDED.deezer_album_id,
    cover_url        = EXCLUDED.cover_url,
    preview_url      = EXCLUDED.preview_url,
    deezer_link      = EXCLUDED.deezer_link,
    explicit_lyrics  = EXCLUDED.explicit_lyrics,
    readable         = EXCLUDED.readable,
    rank             = EXCLUDED.rank,
    synced_at        = NOW()
RETURNING *;

-- name: GetSongByDeezerID :one
SELECT * FROM songs
WHERE deezer_song_id = $1;

-- A fresh Deezer preview link for a song about to play: the stored one is
-- signed for 15 minutes (hdnea=exp=...), and the seed stores none at all.
-- name: SetSongPreviewURL :exec
UPDATE songs
SET preview_url = $2
WHERE id = $1;
