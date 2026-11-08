-- Music Control Delegation (docs/data-model.md 11).

-- The permission check that runs before every playback command a non-owner sends.
--
-- A grant is for one event ("you can drive my speaker tonight"), never for every
-- event: GrantDeviceControl requires the event, and 00021 revoked the standing
-- rows (event_id NULL) older versions wrote and forbids live ones. So this matches
-- the event's own licence only.
--
-- Both liveness conditions are here rather than in Go: revoked_at IS NULL because
-- revocation is a timestamp, not a delete (who could control what, and when, is
-- what you need after an incident), and the expires_at test because an expired row
-- must stop granting anything the moment it lapses, with no sweep job in between.
-- name: ResolveDeviceControlLicense :one
SELECT * FROM device_control_licenses
WHERE device_id = sqlc.arg('device_id')
  AND grantee_user_id = sqlc.arg('grantee_user_id')
  AND event_id = sqlc.arg('event_id')
  AND revoked_at IS NULL
  AND (expires_at IS NULL OR expires_at > NOW())
LIMIT 1;

-- name: GrantDeviceControl :one
INSERT INTO device_control_licenses (device_id, grantee_user_id, granted_by_id, event_id)
VALUES (
    sqlc.arg('device_id'),
    sqlc.arg('grantee_user_id'),
    sqlc.arg('granted_by_id'),
    NULLIF(sqlc.arg('event_id')::bigint, 0)
)
RETURNING *;

-- Only the device owner (granted_by_id) can lift their own grant.
-- name: RevokeDeviceControl :one
UPDATE device_control_licenses
SET revoked_at = NOW()
WHERE id = sqlc.arg('id')
  AND device_id = sqlc.arg('device_id')
  AND granted_by_id = sqlc.arg('revoker_user_id')
  AND revoked_at IS NULL
RETURNING *;

-- "who currently has control of this device".
--
-- The public ids ride along because the app names users and events by them
-- and never sees the internal ones: without them it could not tell which of
-- its friends a licence belongs to, nor whether it is for the event on screen.
-- LEFT JOIN on events: a standing grant has none (event_public_id NULL).
-- name: ListDeviceControlLicensesByDevice :many
SELECT l.*, u.public_id AS grantee_public_id, e.public_id AS event_public_id
FROM device_control_licenses l
JOIN users u ON u.id = l.grantee_user_id
LEFT JOIN events e ON e.id = l.event_id
WHERE l.device_id = sqlc.arg('device_id') AND l.revoked_at IS NULL
ORDER BY l.created_at DESC;

-- Revokes every live grant between two users, in both directions.
--
-- For the friendship cascade. Delegation is friends-only at WRITE time and
-- nothing re-checks the friendship when a licence is used, so ending the
-- relationship has to take the permission back: otherwise a blocked ex-friend
-- keeps driving the speaker. Both directions, because either user may have
-- granted the other.
-- name: RevokeDeviceGrantsBetween :exec
UPDATE device_control_licenses
SET revoked_at = NOW()
WHERE revoked_at IS NULL
  AND ((granted_by_id = sqlc.arg('user_id')       AND grantee_user_id = sqlc.arg('other_user_id'))
    OR (granted_by_id = sqlc.arg('other_user_id') AND grantee_user_id = sqlc.arg('user_id')));

-- Resolution for the authorization interceptor. See GetUserIDByPublicID.
--
-- is_active is not filtered: deactivating a device must not make the licences on
-- it unmanageable, and the owner still needs to see and revoke them.
-- name: GetDeviceIDByPublicID :one
SELECT id
FROM devices
WHERE public_id = $1;

-- Makes device_id the event's speaker, in place of any it had (SetEventSpeaker:
-- the host picks the device that plays). Returns the one it replaces, 0 for
-- none. Read in the FROM, before the row changes (a CTE read from RETURNING
-- sees it after, and gives NULL); its row lock keeps two moves from both
-- reading the same one, so each licence moves once.
-- name: SetEventSpeaker :one
UPDATE event_playback_states s
SET speaker_device_id = sqlc.arg('device_id')
FROM (
    SELECT p.speaker_device_id FROM event_playback_states p
    WHERE p.event_id = sqlc.arg('event_id')
    FOR UPDATE
) previous
WHERE s.event_id = sqlc.arg('event_id')
RETURNING COALESCE(previous.speaker_device_id, 0)::bigint AS previous_device_id;

-- The live licences given on device_id for this one event: what moves with
-- the event's speaker. Live as in ResolveDeviceControlLicense.
-- name: ListEventLicensesOnDevice :many
SELECT * FROM device_control_licenses
WHERE device_id = sqlc.arg('device_id')
  AND event_id = sqlc.arg('event_id')
  AND revoked_at IS NULL
  AND (expires_at IS NULL OR expires_at > NOW())
ORDER BY id;
