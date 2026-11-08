-- Bring the bootstrap users table (00001) up to the identity model of
-- docs/data-model.md 5.
--
-- name -> display_name: the API vocabulary is display_name everywhere, and
-- "name" would collide with the profile's first_name/last_name.
--
-- public_id: the API exposes only this UUID, so sequential ids are never
-- enumerable by a client. The gen_random_uuid() default is volatile, so this
-- ALTER rewrites the table and gives every existing row a distinct value.
--
-- password_hash is nullable on purpose: a Google-first signup has no password.
-- The "at least one usable credential" invariant lives in the service layer,
-- because a user may legitimately set a password and then unlink their last
-- provider.

-- +goose Up
ALTER TABLE users RENAME COLUMN name TO display_name;

ALTER TABLE users
    ALTER COLUMN email TYPE CITEXT,
    ADD COLUMN public_id         UUID        NOT NULL DEFAULT gen_random_uuid(),
    ADD COLUMN password_hash     TEXT,
    ADD COLUMN status            user_status NOT NULL DEFAULT 'active',
    ADD COLUMN email_verified_at TIMESTAMPTZ,
    ADD COLUMN last_login_at     TIMESTAMPTZ,
    ADD COLUMN updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW();

ALTER TABLE users
    ADD CONSTRAINT users_public_id_key    UNIQUE (public_id),
    ADD CONSTRAINT users_display_name_key UNIQUE (display_name);

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- +goose Down
DROP TRIGGER IF EXISTS users_set_updated_at ON users;

ALTER TABLE users
    DROP CONSTRAINT IF EXISTS users_display_name_key,
    DROP CONSTRAINT IF EXISTS users_public_id_key;

ALTER TABLE users
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS last_login_at,
    DROP COLUMN IF EXISTS email_verified_at,
    DROP COLUMN IF EXISTS status,
    DROP COLUMN IF EXISTS password_hash,
    DROP COLUMN IF EXISTS public_id,
    ALTER COLUMN email TYPE TEXT;

ALTER TABLE users RENAME COLUMN display_name TO name;
