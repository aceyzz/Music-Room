-- Devices attached to an account (docs/data-model.md 11).

-- Called on every login. The client sends a stable device_identifier it generated
-- once at install time, so the same phone reuses one row instead of accumulating
-- one per login -- which matters because user_sessions and activity_logs both
-- reference devices.id.
--
-- push_token is COALESCEd from the existing row: a plain login sends no push
-- token, and EXCLUDED.push_token would blank out a perfectly good one.
-- is_active is forced back to TRUE, so logging in again revives a device the user
-- had logged out of.
-- name: UpsertDevice :one
INSERT INTO devices (user_id, device_identifier, name, platform,
                     model, os_version, app_version, push_token, last_seen_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
ON CONFLICT (user_id, device_identifier) DO UPDATE
SET name         = EXCLUDED.name,
    platform     = EXCLUDED.platform,
    model        = EXCLUDED.model,
    os_version   = EXCLUDED.os_version,
    app_version  = EXCLUDED.app_version,
    push_token   = COALESCE(EXCLUDED.push_token, devices.push_token),
    last_seen_at = NOW(),
    is_active    = TRUE
RETURNING *;

-- name: ListDevicesByUser :many
SELECT * FROM devices
WHERE user_id = sqlc.arg('user_id') AND is_active
ORDER BY last_seen_at DESC NULLS LAST;

-- name: GetDeviceByID :one
SELECT * FROM devices WHERE id = sqlc.arg('id');
