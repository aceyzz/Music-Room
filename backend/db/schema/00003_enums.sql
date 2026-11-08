-- Native enum types. sqlc turns each of these into a real Go type with
-- Scan/Value, which is the point: an invalid role or status cannot compile.
--
-- Caveat for future migrations: ALTER TYPE ... ADD VALUE cannot run inside a
-- transaction, so any migration that adds a value needs goose's NO TRANSACTION
-- annotation. (Spelled out rather than quoted here on purpose: goose scans
-- comment lines too, and a literal annotation in prose fails the parser.)
-- Values are never removed.

-- +goose Up
CREATE TYPE user_status            AS ENUM ('active', 'suspended', 'deleted');
CREATE TYPE oauth_provider         AS ENUM ('google', 'facebook', 'deezer');
CREATE TYPE token_purpose          AS ENUM ('email_verification', 'password_reset');
CREATE TYPE visibility_scope       AS ENUM ('public', 'friends', 'private');
CREATE TYPE resource_visibility    AS ENUM ('public', 'private');
CREATE TYPE edit_license           AS ENUM ('everyone', 'invited_only');
CREATE TYPE vote_license           AS ENUM ('everyone', 'invited_only', 'location_time');
CREATE TYPE member_role            AS ENUM ('owner', 'admin', 'editor', 'viewer');
CREATE TYPE invitation_status      AS ENUM ('pending', 'accepted', 'declined', 'revoked', 'expired');
CREATE TYPE friend_request_status  AS ENUM ('pending', 'accepted', 'declined', 'cancelled');
-- 'paused' is gone since 00022: pausing is the music's (event_playback_states).
CREATE TYPE event_status           AS ENUM ('scheduled', 'live', 'paused', 'ended');
CREATE TYPE queue_entry_status     AS ENUM ('queued', 'playing', 'played', 'skipped');
CREATE TYPE device_platform        AS ENUM ('ios', 'android', 'web', 'desktop');

-- Why a session ends. Paired with user_sessions.revoked_at by a CHECK, so a
-- revoked session always says why: normal logout, killed from the user's own
-- device list, mass-revoked after a credential change, moderation, or an
-- anomaly that looked like theft (docs/data-model.md 5).
CREATE TYPE session_revoked_reason AS ENUM (
    'logout', 'user_revoked', 'password_change', 'admin', 'suspected_theft'
);

CREATE TYPE playlist_op_type AS ENUM (
    'create', 'rename', 'add_song', 'remove_song', 'move_song',
    'visibility_change', 'license_change', 'member_change'
);

CREATE TYPE event_op_type AS ENUM (
    'create', 'suggest_song', 'vote', 'play', 'pause', 'skip', 'seek',
    'status_change', 'member_change', 'control_change'
);

-- +goose Down
DROP TYPE IF EXISTS event_op_type;
DROP TYPE IF EXISTS playlist_op_type;
DROP TYPE IF EXISTS session_revoked_reason;
DROP TYPE IF EXISTS device_platform;
DROP TYPE IF EXISTS queue_entry_status;
DROP TYPE IF EXISTS event_status;
DROP TYPE IF EXISTS friend_request_status;
DROP TYPE IF EXISTS invitation_status;
DROP TYPE IF EXISTS member_role;
DROP TYPE IF EXISTS vote_license;
DROP TYPE IF EXISTS edit_license;
DROP TYPE IF EXISTS resource_visibility;
DROP TYPE IF EXISTS visibility_scope;
DROP TYPE IF EXISTS token_purpose;
DROP TYPE IF EXISTS oauth_provider;
DROP TYPE IF EXISTS user_status;
