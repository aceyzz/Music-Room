-- Profile with per-field visibility, plus music preferences
-- (docs/data-model.md 6).
--
-- Per-field *_visibility columns rather than a generic (user_id, field, scope)
-- table: adding a profile field needs a migration for the field anyway, so the
-- generic table buys no flexibility while costing type safety and a join on
-- every profile read. Resolving a profile view is one row fetch plus one
-- friendship lookup.
--
-- No genres table: Deezer's genre list is ~25 static entries from GET /genre,
-- read through a Redis-cached proxy. The chosen label is snapshotted here.

-- +goose Up
CREATE TABLE user_profiles (
    user_id                 BIGINT           PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    first_name              TEXT,
    last_name               TEXT,
    bio                     TEXT,
    birth_date              DATE,
    city                    TEXT,
    country_code            TEXT,
    phone_number            TEXT,
    avatar_image_id         BIGINT           REFERENCES images (id) ON DELETE SET NULL,
    first_name_visibility   visibility_scope NOT NULL DEFAULT 'friends',
    last_name_visibility    visibility_scope NOT NULL DEFAULT 'friends',
    bio_visibility          visibility_scope NOT NULL DEFAULT 'public',
    birth_date_visibility   visibility_scope NOT NULL DEFAULT 'private',
    location_visibility     visibility_scope NOT NULL DEFAULT 'friends',
    phone_visibility        visibility_scope NOT NULL DEFAULT 'private',
    preferences_visibility  visibility_scope NOT NULL DEFAULT 'public',
    created_at              TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

    CONSTRAINT user_profiles_country_code_check
        CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$')
);

CREATE INDEX user_profiles_avatar_image_id_idx ON user_profiles (avatar_image_id);

CREATE TRIGGER user_profiles_set_updated_at
    BEFORE UPDATE ON user_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- weight is what makes "collaborate with people with the same musical tastes"
-- a query rather than a guess.
CREATE TABLE user_music_preferences (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    deezer_genre_id BIGINT      NOT NULL,
    genre_name      TEXT        NOT NULL,
    weight          SMALLINT    NOT NULL DEFAULT 3,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, deezer_genre_id),
    CONSTRAINT user_music_preferences_weight_check CHECK (weight BETWEEN 1 AND 5)
);

-- taste matching reads by genre across users, the reverse of the PK order
CREATE INDEX user_music_preferences_genre_idx
    ON user_music_preferences (deezer_genre_id, weight DESC);

-- +goose Down
DROP TABLE IF EXISTS user_music_preferences;
DROP TABLE IF EXISTS user_profiles;
