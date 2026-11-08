-- ip_address is NULL when the caller's address is unknown (clientip).
-- name: RecordLoginAttempt :exec
INSERT INTO login_attempts (email, ip_address, succeeded, failure_reason)
VALUES (sqlc.arg('email'), NULLIF(sqlc.arg('ip_address')::text, '')::inet,
        sqlc.arg('succeeded'), sqlc.narg('failure_reason'));

-- name: CountRecentLoginFailures :one
SELECT COUNT(*)
FROM login_attempts f
WHERE f.email = sqlc.arg('email')
  AND f.succeeded = FALSE
  AND f.created_at > sqlc.arg('since')::timestamptz
  AND f.created_at > COALESCE(
      (SELECT MAX(s.created_at)
       FROM login_attempts s
       WHERE s.email = sqlc.arg('email')
         AND s.succeeded = TRUE),
      '-infinity'::timestamptz
  );

-- Failures from one address, whatever the email: what stops one machine
-- trying a password on many accounts. A success does not reset it, or the
-- attacker would sign in to their own account between guesses.
-- name: CountRecentLoginFailuresFromIP :one
SELECT COUNT(*)
FROM login_attempts
WHERE ip_address = sqlc.arg('ip_address')::text::inet
  AND succeeded = FALSE
  AND created_at > sqlc.arg('since')::timestamptz;
