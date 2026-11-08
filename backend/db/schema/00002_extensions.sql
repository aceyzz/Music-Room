-- Extensions and shared helpers.
--
-- citext   : case-insensitive email / handle columns (users.email, login_attempts.email)
-- pgcrypto : gen_random_uuid() for the public_id columns exposed by the API
--
-- cube + earthdistance are deliberately NOT installed: the location_time vote
-- license is evaluated in the Go handler (see docs/data-model.md 14), so no SQL
-- query needs distance math yet. Adding them later is a one-line migration.

-- +goose Up
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Shared trigger maintaining updated_at on every mutable table.
-- +goose StatementBegin
CREATE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- +goose Down
DROP FUNCTION IF EXISTS set_updated_at();
DROP EXTENSION IF EXISTS pgcrypto;
DROP EXTENSION IF EXISTS citext;
