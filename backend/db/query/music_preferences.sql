-- Music taste, one row per genre (docs/data-model.md 6).
--
-- No update-in-place query: SetMusicPreferences replaces the whole set
-- (delete then insert, inside one transaction) rather than diffing, since the
-- client always sends its full picker state, never a single genre delta.

-- name: ListUserMusicPreferences :many
SELECT deezer_genre_id, genre_name, weight
FROM user_music_preferences
WHERE user_id = $1
ORDER BY weight DESC, genre_name;

-- name: DeleteUserMusicPreferences :exec
DELETE FROM user_music_preferences
WHERE user_id = $1;

-- name: CreateUserMusicPreference :one
INSERT INTO user_music_preferences (user_id, deezer_genre_id, genre_name, weight)
VALUES ($1, $2, $3, $4)
RETURNING *;
