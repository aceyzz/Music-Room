-- Profile with per-field visibility (docs/data-model.md 6).

-- Called in the same transaction as CreateUser. Registration used to insert only
-- the users row, which meant the carefully chosen *_visibility defaults on this
-- table never applied to anybody -- the row they default on was never created,
-- and GetUserProfile returned no rows for every account in the system.
--
-- Every column is left to its default, and the whole row comes back, because the
-- caller derives the new user's FGA visibility tuples from it. Reading the values
-- rather than restating them in Go is the point: the defaults live in exactly one
-- place, and changing one here cannot silently disagree with the graph.
-- name: CreateUserProfile :one
INSERT INTO user_profiles (user_id)
VALUES ($1)
RETURNING *;

-- Returns the whole row INCLUDING the *_visibility columns, because resolving
-- what a given viewer may see is a Go decision, not a SQL one: it needs the
-- viewer's friendship status (a PK lookup on friendships with the pair sorted)
-- and it has to blank fields rather than drop them. One row fetch plus one
-- friendship lookup, per the schema comment.
-- name: GetUserProfile :one
SELECT * FROM user_profiles
WHERE user_id = $1;

-- One partial upsert for the whole profile form.
--
-- The seven profile fields are each driven by a pair: set_<field> says whether
-- the client sent the field at all, <field> is the new value, NULL to clear it.
-- So "leave alone" and "clear" are different requests, which a single nullable
-- parameter cannot express: COALESCE(param, column) used to be used here, and
-- with it NULL meant "unchanged" and nothing could ever be emptied again.
-- UpdateUserProfile fills both from the request's proto3 `optional` presence
-- (internal/user/service.go, profileParams). A caller that only sets
-- avatar_image_id (SetAvatar) leaves every set_<field> false and touches
-- nothing else.
--
-- The visibility scopes and avatar_image_id keep COALESCE: a scope always has a
-- value, and the avatar is cleared by its own query (ClearUserAvatar).
-- INSERT ... ON CONFLICT covers a missing row: the handler passes NULL for any
-- field not sent, which is what the column would hold anyway.
-- name: UpsertUserProfile :one
INSERT INTO user_profiles (
    user_id, first_name, last_name, bio, birth_date, city, country_code, phone_number,
    avatar_image_id,
    first_name_visibility, last_name_visibility, bio_visibility, birth_date_visibility,
    location_visibility, phone_visibility, preferences_visibility
) VALUES (
    sqlc.arg('user_id'), sqlc.narg('first_name'), sqlc.narg('last_name'), sqlc.narg('bio'),
    sqlc.narg('birth_date'), sqlc.narg('city'), sqlc.narg('country_code'), sqlc.narg('phone_number'),
    sqlc.narg('avatar_image_id'),
    COALESCE(sqlc.narg('first_name_visibility')::visibility_scope, 'friends'),
    COALESCE(sqlc.narg('last_name_visibility')::visibility_scope, 'friends'),
    COALESCE(sqlc.narg('bio_visibility')::visibility_scope, 'public'),
    COALESCE(sqlc.narg('birth_date_visibility')::visibility_scope, 'private'),
    COALESCE(sqlc.narg('location_visibility')::visibility_scope, 'friends'),
    COALESCE(sqlc.narg('phone_visibility')::visibility_scope, 'private'),
    COALESCE(sqlc.narg('preferences_visibility')::visibility_scope, 'public')
)
ON CONFLICT (user_id) DO UPDATE
SET first_name             = CASE WHEN sqlc.arg('set_first_name')::bool THEN sqlc.narg('first_name') ELSE user_profiles.first_name END,
    last_name              = CASE WHEN sqlc.arg('set_last_name')::bool THEN sqlc.narg('last_name') ELSE user_profiles.last_name END,
    bio                    = CASE WHEN sqlc.arg('set_bio')::bool THEN sqlc.narg('bio') ELSE user_profiles.bio END,
    birth_date             = CASE WHEN sqlc.arg('set_birth_date')::bool THEN sqlc.narg('birth_date') ELSE user_profiles.birth_date END,
    city                   = CASE WHEN sqlc.arg('set_city')::bool THEN sqlc.narg('city') ELSE user_profiles.city END,
    country_code           = CASE WHEN sqlc.arg('set_country_code')::bool THEN sqlc.narg('country_code') ELSE user_profiles.country_code END,
    phone_number           = CASE WHEN sqlc.arg('set_phone_number')::bool THEN sqlc.narg('phone_number') ELSE user_profiles.phone_number END,
    avatar_image_id        = COALESCE(sqlc.narg('avatar_image_id'),        user_profiles.avatar_image_id),
    first_name_visibility  = COALESCE(sqlc.narg('first_name_visibility')::visibility_scope,  user_profiles.first_name_visibility),
    last_name_visibility   = COALESCE(sqlc.narg('last_name_visibility')::visibility_scope,   user_profiles.last_name_visibility),
    bio_visibility         = COALESCE(sqlc.narg('bio_visibility')::visibility_scope,         user_profiles.bio_visibility),
    birth_date_visibility  = COALESCE(sqlc.narg('birth_date_visibility')::visibility_scope,  user_profiles.birth_date_visibility),
    location_visibility    = COALESCE(sqlc.narg('location_visibility')::visibility_scope,    user_profiles.location_visibility),
    phone_visibility       = COALESCE(sqlc.narg('phone_visibility')::visibility_scope,       user_profiles.phone_visibility),
    preferences_visibility = COALESCE(sqlc.narg('preferences_visibility')::visibility_scope, user_profiles.preferences_visibility)
WHERE user_profiles.user_id = sqlc.arg('user_id')
RETURNING *;

-- UpsertUserProfile keeps COALESCE on avatar_image_id (see its comment above),
-- so it cannot set it back to NULL -- DeleteAvatar needs exactly that, so it
-- gets its own query.
-- name: ClearUserAvatar :exec
UPDATE user_profiles
SET avatar_image_id = NULL
WHERE user_id = $1;
