-- Devices attached to an account (docs/data-model.md 11).
--
-- Created before the auth tables because user_sessions.device_id references it,
-- and before activity_logs, which reads platform/model/app_version from here
-- instead of duplicating them on every log row.
--
-- The control license that hangs off a device lives in 00013_delegation.sql: it
-- also references events, so it cannot be created this early.

-- +goose Up
CREATE TABLE devices (
    id                BIGSERIAL       PRIMARY KEY,
    user_id           BIGINT          NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_identifier TEXT            NOT NULL,
    name              TEXT            NOT NULL,
    platform          device_platform NOT NULL,
    model             TEXT,
    os_version        TEXT,
    app_version       TEXT,
    push_token        TEXT,
    last_seen_at      TIMESTAMPTZ,
    is_active         BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT devices_user_identifier_key UNIQUE (user_id, device_identifier)
);

CREATE INDEX devices_user_id_idx ON devices (user_id) WHERE is_active;

-- +goose Down
DROP TABLE IF EXISTS devices;
