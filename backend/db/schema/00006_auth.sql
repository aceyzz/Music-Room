-- Credentials, one-shot tokens, server-side sessions and login throttling
-- (docs/data-model.md 5).
--
-- Nothing here stores a usable secret. Every *_hash column is a SHA-256 of the
-- value handed to the client, and the OAuth provider tokens are encrypted at
-- rest by the app before they reach the column.
--
-- Auth is opaque session tokens, not JWTs: user_sessions IS the session store,
-- and it is read on every authenticated request. There is no access/refresh
-- split, because the only reason for one is that a signed token cannot be
-- revoked -- and a row can.

-- +goose Up

-- Linked social identities. Signup by provider, or link a provider afterwards.
CREATE TABLE user_oauth_accounts (
    id                BIGSERIAL      PRIMARY KEY,
    user_id           BIGINT         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    provider          oauth_provider NOT NULL,
    provider_user_id  TEXT           NOT NULL,
    provider_email    CITEXT,
    access_token_enc  TEXT,
    refresh_token_enc TEXT,
    token_expires_at  TIMESTAMPTZ,
    scopes            JSONB          NOT NULL DEFAULT '[]'::JSONB,
    linked_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    -- one Music Room account per provider identity
    CONSTRAINT user_oauth_accounts_provider_identity_key UNIQUE (provider, provider_user_id),
    -- one account per provider per user
    CONSTRAINT user_oauth_accounts_user_provider_key UNIQUE (user_id, provider)
);

-- Single-use, expiring tokens emailed to the user.
CREATE TABLE user_tokens (
    id           BIGSERIAL     PRIMARY KEY,
    user_id      BIGINT        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    purpose      token_purpose NOT NULL,
    token_hash   BYTEA         NOT NULL,
    expires_at   TIMESTAMPTZ   NOT NULL,
    consumed_at  TIMESTAMPTZ,
    requested_ip INET,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT user_tokens_token_hash_key UNIQUE (token_hash)
);

-- Lookup path for "invalidate any previous unused token of this purpose", which
-- the service does before issuing a new one. Not a unique index: the correct
-- predicate would be "unconsumed AND not yet expired", and NOW() is not
-- immutable so it cannot appear in an index predicate. Enforced in the service.
CREATE INDEX user_tokens_user_purpose_idx
    ON user_tokens (user_id, purpose)
    WHERE consumed_at IS NULL;

-- Server-side sessions. The client holds one opaque token; this row is the
-- session. Authenticating a request is a lookup on token_hash, which is why
-- that index has to stay the single hottest read in the schema.
--
-- Two independent lifetimes, both enforced in the service layer rather than by
-- a constraint, because "has it expired?" is a question about NOW() and NOW()
-- is not immutable:
--
--   expires_at    absolute cap. A session dies at this instant no matter how
--                 active it was. Set from a fixed window at login.
--   last_used_at  idle timeout. The service compares it against a configured
--                 window and rejects a session that has been quiet too long.
--
-- public_id is what the "active sessions" screen shows and revokes by. The
-- client cannot address another session by its token -- it does not have it --
-- and BIGSERIAL ids must not leak (docs/data-model.md 2).
CREATE TABLE user_sessions (
    id             BIGSERIAL   PRIMARY KEY,
    public_id      UUID        NOT NULL DEFAULT gen_random_uuid(),
    user_id        BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id      BIGINT      REFERENCES devices (id) ON DELETE SET NULL,
    token_hash     BYTEA       NOT NULL,
    user_agent     TEXT,
    ip_address     INET,
    expires_at     TIMESTAMPTZ NOT NULL,
    last_used_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at     TIMESTAMPTZ,
    revoked_reason session_revoked_reason,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT user_sessions_public_id_key UNIQUE (public_id),
    CONSTRAINT user_sessions_token_hash_key UNIQUE (token_hash),
    -- A reason without a timestamp, or the reverse, means the revocation path
    -- was half-applied. Cheap to assert, and it keeps the audit trail honest.
    CONSTRAINT user_sessions_revoked_consistency CHECK (
        (revoked_at IS NULL) = (revoked_reason IS NULL)
    )
);

-- No index is declared for the authentication path: UNIQUE (token_hash) above
-- already provides it. Worth stating explicitly, because that constraint is
-- load-bearing for latency, not just for correctness -- every authenticated
-- request is a lookup through it.

-- "List my active sessions" and "revoke every session of this user" (password
-- change, account suspension). Partial: revoked rows are only ever read by the
-- audit path, which does not need this index.
CREATE INDEX user_sessions_user_id_idx ON user_sessions (user_id) WHERE revoked_at IS NULL;

-- Pruning cron only. It deletes on "expired before the cutoff OR revoked before
-- the cutoff"; this index serves the first term, and the second falls back to a
-- scan, which is acceptable for a batch job that runs off the request path.
CREATE INDEX user_sessions_expires_at_idx ON user_sessions (expires_at);

-- Durable audit trail for brute-force throttling. Not an FK on email: failed
-- attempts against unknown addresses are exactly what we need to record. The
-- live rate counter is a candidate for Redis later; until then it is counted
-- off this table, which is what the (email, created_at DESC) index is for.
CREATE TABLE login_attempts (
    id             BIGSERIAL   PRIMARY KEY,
    email          CITEXT      NOT NULL,
    ip_address     INET,
    succeeded      BOOLEAN     NOT NULL,
    failure_reason TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX login_attempts_email_created_at_idx ON login_attempts (email, created_at DESC);
CREATE INDEX login_attempts_ip_created_at_idx ON login_attempts (ip_address, created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS login_attempts;
DROP TABLE IF EXISTS user_sessions;
DROP TABLE IF EXISTS user_tokens;
DROP TABLE IF EXISTS user_oauth_accounts;
