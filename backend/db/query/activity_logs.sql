-- Audit and security logging (docs/data-model.md 12).

-- Subject V.6: every action on the mobile application generates a backend log
-- carrying the platform, the device and the application version.
--
-- The two scalar subqueries snapshot platform and app_version from the device in
-- the same statement, so no call site has to fetch the device first and no handler
-- can forget to pass them. They are PK lookups, and they return NULL when
-- device_id is NULL -- an unauthenticated request logs with empty snapshots rather
-- than failing.
--
-- Snapshotting duplicates data that device_id already points at, which is
-- deliberate: activity_logs.device_id is ON DELETE SET NULL, so a log written
-- today must still say "iOS, 2.3.1" after the user removes that phone. One of the
-- few places where denormalising is the right call.
--
-- user_id is nullable even though accounts are mandatory: a failed login or a call
-- with an expired token has no authenticated user, and those are precisely the
-- events worth logging. Same for platform::TEXT -- the column is TEXT rather than
-- the device_platform enum so a log can outlive an enum value.
--
-- The table is range-partitioned by month; created_at defaults to NOW() and
-- routing is automatic, so inserts look no different from an ordinary table.
-- name: CreateActivityLog :one
INSERT INTO activity_logs (
    user_id, device_id, action, resource_type, resource_id,
    platform_snapshot, app_version_snapshot,
    ip_address, user_agent, result_code, metadata
)
VALUES (
    sqlc.narg('user_id'),
    sqlc.narg('device_id'),
    sqlc.arg('action'),
    sqlc.narg('resource_type'),
    sqlc.narg('resource_id'),
    (SELECT d.platform::TEXT FROM devices d WHERE d.id = sqlc.narg('device_id')),
    (SELECT d.app_version    FROM devices d WHERE d.id = sqlc.narg('device_id')),
    sqlc.narg('ip_address'),
    sqlc.narg('user_agent'),
    sqlc.narg('result_code'),
    sqlc.arg('metadata')
)
RETURNING *;
