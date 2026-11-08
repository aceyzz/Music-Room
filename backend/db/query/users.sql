-- Identity queries (docs/data-model.md 5).
--
-- Column lists are explicit rather than SELECT *, so password_hash only appears
-- where a query actually needs it. With SELECT * it would land in every DTO the
-- handlers build, and the first person to json.Marshal a User would leak it.

-- Signup with a password. password_hash is nullable in the schema (an OAuth-first
-- signup has none), so the same table serves both paths; only the RETURNING list
-- differs -- the caller never needs the hash it just wrote.
-- name: CreateUser :one
INSERT INTO users (display_name, email, password_hash)
VALUES ($1, $2, $3)
RETURNING id, public_id, display_name, email, status,
          email_verified_at, last_login_at, created_at, updated_at;

-- The login lookup. email is CITEXT, so no LOWER() here or at the call site.
-- Returns status as well as the hash: a suspended account must fail the login
-- even when the password is correct, and that decision belongs to the handler.
-- name: GetUserByEmail :one
SELECT id, public_id, display_name, email, password_hash, status,
       email_verified_at, last_login_at, created_at, updated_at
FROM users
WHERE email = $1
  AND status <> 'deleted';

-- name: UserExists :one
SELECT EXISTS(
  SELECT 1
  FROM users
  WHERE id = $1
    AND status <> 'deleted'
);

-- Fetch for UserService reads (profile, friends). No password_hash, no email:
-- this is a public-facing lookup, not the login path.
-- name: GetUserByID :one
SELECT id, public_id, display_name, status
FROM users
WHERE id = $1
  AND status <> 'deleted';

-- The public UUID of an account, by internal id.
--
-- Exists because a tuple's subject is always the public id (internal ids would
-- force a lookup before every Check -- see internal/authz.Object) while the API
-- still speaks internal ids in its request bodies. Every mutation that grants a
-- permission TO someone needs this one column and nothing else.
--
-- No rows means "no such usable account", which is the same answer UserExists
-- gives -- so a caller that needs both can use this alone.
-- name: GetUserPublicID :one
SELECT public_id
FROM users
WHERE id = $1
  AND status <> 'deleted';

-- The reverse of GetUserPublicID: the internal id behind a public UUID.
--
-- The authorization interceptor's resolution step. Requests name users by their
-- public UUID (that is the only id a client is ever given), the graph answers
-- questions about `user:<uuid>`, and the handlers and every other query here
-- speak internal ids -- so exactly one translation has to happen per request,
-- and this is it. The interceptor writes the result into the request's int64
-- field, which is what makes the user it CHECKED and the user the handler acts
-- on provably the same user.
--
-- The caller's own id does NOT come through here: the session lookup already
-- returns both (see GetSessionByHash). This is for the OTHER user in a request
-- -- an invitee, a grantee, the addressee of a friend request.
-- name: GetUserIDByPublicID :one
SELECT id
FROM users
WHERE public_id = $1
  AND status <> 'deleted';

-- name: UpdateUserPassword :execrows
UPDATE users
SET password_hash = $2
WHERE id = $1
  AND status <> 'deleted';
  