-- Music Control Delegation (docs/data-model.md 11).
--
-- Split from 00005_devices.sql because event_id references events: devices had
-- to land before the auth tables, this cannot land before 00012_events.sql.
--
-- The license hangs off devices, not users -- that is the subject's requirement
-- ("specific for each device attached to the user's account"). Granting a friend
-- control of the living-room tablet says nothing about the phone.
--
-- Unlike invitations, delegation IS friends-only: the subject says "give the
-- music control to different friends". The service layer requires a friendships
-- row between granted_by_id and grantee_user_id.

-- +goose Up
CREATE TABLE device_control_licenses (
    id              BIGSERIAL   PRIMARY KEY,
    device_id       BIGINT      NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    grantee_user_id BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    granted_by_id   BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- null = standing grant; set = "you can drive my speaker for tonight only"
    event_id        BIGINT      REFERENCES events (id) ON DELETE CASCADE,
    can_play_pause  BOOLEAN     NOT NULL DEFAULT TRUE,
    can_skip        BOOLEAN     NOT NULL DEFAULT TRUE,
    can_seek        BOOLEAN     NOT NULL DEFAULT FALSE,
    can_change_song BOOLEAN     NOT NULL DEFAULT FALSE,
    can_set_volume  BOOLEAN     NOT NULL DEFAULT FALSE,
    expires_at      TIMESTAMPTZ,
    -- revocation is a timestamp, not a delete: who could control what, and when,
    -- is exactly what you need after an incident
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT device_control_licenses_not_self_check CHECK (grantee_user_id <> granted_by_id)
);

-- At most one live grant per (device, friend, scope). COALESCE folds the nullable
-- event_id into the key, since NULLs would otherwise never collide.
CREATE UNIQUE INDEX device_control_licenses_one_live_per_scope
    ON device_control_licenses (device_id, grantee_user_id, COALESCE(event_id, 0))
    WHERE revoked_at IS NULL;

-- "what am I allowed to control?"
CREATE INDEX device_control_licenses_grantee_idx
    ON device_control_licenses (grantee_user_id)
    WHERE revoked_at IS NULL;

CREATE INDEX device_control_licenses_event_id_idx ON device_control_licenses (event_id);

-- +goose Down
DROP TABLE IF EXISTS device_control_licenses;
