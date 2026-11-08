-- Tokens a usage unique envoyes par email (docs/data-model.md 5).
--
-- token_hash est un SHA-256 du code envoye : un dump de la table ne permet
-- pas de valider un email a la place de quelqu'un.

-- Invalide les tokens non consommes de ce type avant d'en emettre un nouveau.
-- Sans ca, deux codes valides coexistent et le plus ancien reste utilisable.
-- Note: on marque consumed_at plutot que de supprimer, pour l'audit.
-- name: ConsumePendingTokens :execrows
UPDATE user_tokens
SET consumed_at = NOW()
WHERE user_id = $1
  AND purpose = $2
  AND consumed_at IS NULL;

-- Emet un nouveau token. expires_at est calcule par l'appelant.
-- name: CreateUserToken :one
INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at, requested_ip)
VALUES ($1, $2, $3, $4, $5)
RETURNING id, user_id, purpose, expires_at, created_at;

-- Lecture pour verification. Ne filtre ni l'expiration ni la consommation :
-- le service doit distinguer "code inconnu" de "deja utilise" de "expire"
-- pour les logs (V.6), comme GetSessionByHash le fait pour les sessions.
-- name: GetUserTokenByHash :one
SELECT t.id, t.user_id, t.purpose, t.expires_at, t.consumed_at, t.created_at,
       u.public_id AS user_public_id, u.email_verified_at
FROM user_tokens t
JOIN users u ON u.id = t.user_id
WHERE t.token_hash = $1;

-- Consommation. Le WHERE porte la condition, pas le Go : deux requetes
-- simultanees avec le meme code ne peuvent pas reussir toutes les deux.
-- Zero ligne = deja consomme.
-- name: ConsumeUserToken :execrows
UPDATE user_tokens
SET consumed_at = NOW()
WHERE id = $1
  AND consumed_at IS NULL;

-- Marque l'email verifie. Idempotent : rejouer ne change pas la date.
-- name: MarkEmailVerified :execrows
UPDATE users
SET email_verified_at = NOW()
WHERE id = $1
  AND email_verified_at IS NULL;

-- L'adresse a laquelle envoyer un code, et si elle est deja verifiee. Lue par
-- RequestEmailVerification, qui ne recoit que l'identite de la session : le
-- client ne choisit pas l'adresse, sinon n'importe qui pourrait faire envoyer
-- des mails a n'importe qui depuis notre domaine.
-- name: GetUserEmailVerification :one
SELECT email, email_verified_at
FROM users
WHERE id = $1
  AND status <> 'deleted';

-- name: UseTokenAttempt :one
UPDATE user_tokens AS u
SET attempts = u.attempts + 1
WHERE u.id = (
    SELECT t.id
    FROM user_tokens t
    WHERE t.user_id = sqlc.arg('user_id')
      AND t.purpose = sqlc.arg('purpose')
      AND t.consumed_at IS NULL
    ORDER BY t.created_at DESC
    LIMIT 1
)
  AND u.attempts < sqlc.arg('max_attempts')
  AND u.expires_at > NOW()
RETURNING u.id, u.token_hash;

-- name: CountRecentTokens :one
SELECT
    COUNT(*) FILTER (WHERE created_at > sqlc.arg('short_since')::timestamptz) AS short_window,
    COUNT(*) AS long_window
FROM user_tokens
WHERE user_id = sqlc.arg('user_id')
  AND purpose = sqlc.arg('purpose')
  AND created_at > sqlc.arg('long_since')::timestamptz;
