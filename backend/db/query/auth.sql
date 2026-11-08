-- Server-side session tokens (docs/data-model.md 5).
--
-- token_hash is a SHA-256 of the opaque string handed to the client. The plaintext
-- token never reaches the database, so a dump of this table cannot be replayed.
--
-- There is no refresh flow here on purpose. The session token is the credential,
-- GetSessionByHash runs on every authenticated request, and revocation takes
-- effect on the next one because the row is the source of truth.

-- Issued at login. expires_at is the absolute cap, computed by the caller from a
-- configured window; last_used_at defaults to NOW() and carries the idle timeout.
-- device_id is nullable so a client that has not registered a device yet can still
-- log in -- the device row is created on first heartbeat, not at signup.
-- name: CreateSession :one
INSERT INTO user_sessions (user_id, device_id, token_hash,
                           user_agent, ip_address, expires_at)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- The authentication path: one indexed lookup per request.
--
-- Deliberately does NOT filter on revoked_at or expires_at. The handler has to
-- distinguish "unknown token" (garbage, 401) from "revoked" (tell the client to
-- log in again, and log which reason) from "expired" (same, but not suspicious)
-- from "idle too long" (a last_used_at comparison it can only make with the row in
-- hand). Filtering here would collapse all four into ErrNoRows.
--
-- Joins users because the caller needs the account state anyway: a session on a
-- suspended or deleted account must not authenticate, and that check is free here
-- rather than a second round trip.
-- name: GetSessionByHash :one
SELECT sqlc.embed(s), u.public_id AS user_public_id, u.status AS user_status,
       u.email_verified_at
FROM user_sessions s
JOIN users u ON u.id = s.user_id
WHERE s.token_hash = $1;

-- Slides the idle window. Called after a request authenticates, and the caller is
-- expected to skip it unless last_used_at is already older than a threshold
-- (~1 min): otherwise this is one write per request on the hot path, which is the
-- single strongest argument for moving session tracking to Redis later.
--
-- No lock and no read-modify-write: concurrent requests on the same session race
-- to set the same column and last-write-wins is exactly the desired semantics.
-- name: TouchSession :exec
UPDATE user_sessions
SET last_used_at = NOW()
WHERE id = $1
  AND revoked_at IS NULL;

-- Binds the current session to the device it runs on; called by RegisterDevice.
--
-- A session belongs to one install of the app, so its device is set once here
-- and every later request reads it for free from GetSessionByHash -- no device
-- header to resolve per request. user_id is in the WHERE so a session can only
-- point at a device of its own user (the device row was just upserted for that
-- user, but the guard costs nothing). Re-running it with the same device is a
-- no-op write, which RegisterDevice on every app launch makes routine.
-- name: AttachSessionDevice :exec
UPDATE user_sessions
SET device_id = sqlc.arg('device_id')
WHERE id = sqlc.arg('session_id')
  AND user_id = sqlc.arg('user_id')
  AND revoked_at IS NULL;

-- Logout of the current session. Keyed by hash because that is what the caller
-- holds; the row is kept for audit rather than deleted.
-- name: RevokeSessionByHash :exec
UPDATE user_sessions
SET revoked_at = NOW(), revoked_reason = $2
WHERE token_hash = $1
  AND revoked_at IS NULL;

-- Mass revocation: password change, credential unlink, account suspension, or the
-- user pressing "sign out everywhere". except_session_id keeps the caller's own
-- session alive -- pass 0 to kill every session including it.
-- name: RevokeAllUserSessions :execrows
UPDATE user_sessions
SET revoked_at = NOW(), revoked_reason = sqlc.arg('revoked_reason')
WHERE user_id = sqlc.arg('user_id')
  AND id <> sqlc.arg('except_session_id')
  AND revoked_at IS NULL;
