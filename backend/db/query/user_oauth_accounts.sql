-- Identites sociales liees a un compte (docs/data-model.md 5).
--
-- Deux contraintes uniques portent la logique :
--   (provider, provider_user_id) : une identite provider = un seul compte
--   (user_id, provider)          : un compte = un seul Google, un seul 42...

-- Le chemin nominal du social login : cette identite est-elle deja connue ?
-- Joint users parce que l'appelant a besoin de l'etat du compte de toute
-- facon : un compte suspendu ne doit pas se connecter, meme via Google.
-- name: GetUserByProviderIdentity :one
SELECT u.id, u.public_id, u.display_name, u.email, u.status,
       u.email_verified_at
FROM user_oauth_accounts a
JOIN users u ON u.id = a.user_id
WHERE a.provider = $1
  AND a.provider_user_id = $2;

-- Lie une identite provider a un compte existant.
-- Les deux contraintes uniques rejettent les doublons avec 23505 ; le
-- repository les traduit, comme pour l'inscription email.
-- name: LinkOAuthAccount :one
INSERT INTO user_oauth_accounts (user_id, provider, provider_user_id, provider_email)
VALUES ($1, $2, $3, $4)
RETURNING id, user_id, provider, provider_user_id, linked_at;

-- Cree un compte sans mot de passe : l'inscription vient d'un provider.
-- password_hash reste NULL, ce que le schema autorise. L'email est marque
-- verifie immediatement quand le provider l'a lui-meme verifie -- la decision
-- appartient au service, pas a cette requete.
-- name: CreateOAuthUser :one
INSERT INTO users (display_name, email, email_verified_at)
VALUES ($1, $2, $3)
RETURNING id, public_id, display_name, email, status,
          email_verified_at, created_at;

-- name: LockUserForCredentialChange :one
SELECT (password_hash IS NOT NULL)::boolean AS has_password
FROM users
WHERE id = $1
  AND status <> 'deleted'
FOR UPDATE;

-- name: CountOAuthAccounts :one
SELECT COUNT(*)
FROM user_oauth_accounts
WHERE user_id = $1;

-- name: DeleteOAuthAccount :execrows
DELETE FROM user_oauth_accounts
WHERE user_id = $1
  AND provider = $2;

-- L'ecran "Comptes lies" du profil. Pas les tokens : le client n'en fait rien.
-- name: ListOAuthAccounts :many
SELECT provider, provider_email, linked_at
FROM user_oauth_accounts
WHERE user_id = $1
ORDER BY linked_at;

-- Meme question que LockUserForCredentialChange, sans le FOR UPDATE : ici on
-- ne fait que l'afficher, et Unlink la repose sous verrou de toute facon.
-- name: UserHasPassword :one
SELECT (password_hash IS NOT NULL)::boolean AS has_password
FROM users
WHERE id = $1
  AND status <> 'deleted';
