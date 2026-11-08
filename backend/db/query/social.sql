-- Social graph (docs/data-model.md 7).

-- The service must check user_blocks in both directions before calling this.
-- The friend_requests_one_open_per_pair index then rejects a crossed request
-- (A->B while B->A is still pending) with a unique violation, so the handler maps
-- 23505 to "there is already a pending request" instead of racing on a SELECT.
-- name: CreateFriendRequest :one
INSERT INTO friend_requests (requester_id, addressee_id, message)
VALUES ($1, $2, $3)
RETURNING *;

-- Half one of the accept transaction.
--
-- addressee_id and status are in the WHERE clause, not checked in Go: only the
-- addressee may accept, and only a pending request can be accepted. Both
-- conditions therefore live in the statement that performs the write, so no
-- interleaved request can slip between the check and the update. Zero rows back
-- means "not yours, or already answered".
-- name: AcceptFriendRequest :one
UPDATE friend_requests
SET status = 'accepted', responded_at = NOW()
WHERE id = sqlc.arg('id')
  AND addressee_id = sqlc.arg('addressee_id')
  AND status = 'pending'
RETURNING id, requester_id, addressee_id;

-- Half two, same transaction, fed the ids returned above.
--
-- LEAST/GREATEST normalise the pair to satisfy friendships_canonical_order_check,
-- so callers pass the two ids in whatever order they have them. Doing it here
-- rather than in Go means the invariant cannot be violated by a caller that
-- forgets to sort -- there is exactly one row per pair, and the PK enforces it.
-- name: CreateFriendship :one
INSERT INTO friendships (user_a_id, user_b_id, created_from_request_id)
VALUES (
    LEAST(sqlc.arg('user_id')::BIGINT, sqlc.arg('friend_id')::BIGINT),
    GREATEST(sqlc.arg('user_id')::BIGINT, sqlc.arg('friend_id')::BIGINT),
    sqlc.narg('request_id')
)
RETURNING *;

-- name: AreFriends :one
SELECT EXISTS(
    SELECT 1 FROM friendships
    WHERE user_a_id = LEAST(sqlc.arg('user_id')::bigint, sqlc.arg('other_user_id')::bigint)
      AND user_b_id = GREATEST(sqlc.arg('user_id')::bigint, sqlc.arg('other_user_id')::bigint)
);

-- The other half of the accept transaction's guard clause: a pending request
-- must be declined by its addressee only, same shape as AcceptFriendRequest so
-- the same "zero rows = not yours, or already answered" reasoning applies.
-- name: DeclineFriendRequest :one
UPDATE friend_requests
SET status = 'declined', responded_at = NOW()
WHERE id = sqlc.arg('id')
  AND addressee_id = sqlc.arg('addressee_id')
  AND status = 'pending'
RETURNING id, requester_id, addressee_id;

-- The two request lists carry the OTHER person (the requester for incoming,
-- the addressee for outgoing) so a client can show who it is and open their
-- profile by public id; same avatar LEFT JOINs as ListFriends. A request to or
-- from an account that is no longer active is left out, like ListFriends does.
-- name: ListIncomingFriendRequests :many
SELECT fr.id, fr.requester_id, fr.addressee_id, fr.status, fr.message, fr.created_at,
       u.public_id     AS other_public_id,
       u.display_name  AS other_display_name,
       img.storage_key AS other_avatar_storage_key
FROM friend_requests fr
JOIN users u              ON u.id = fr.requester_id
LEFT JOIN user_profiles p ON p.user_id = u.id
LEFT JOIN images img      ON img.id = p.avatar_image_id
WHERE fr.addressee_id = sqlc.arg('user_id') AND fr.status = 'pending'
  AND u.status = 'active'
ORDER BY fr.created_at DESC;

-- name: ListOutgoingFriendRequests :many
SELECT fr.id, fr.requester_id, fr.addressee_id, fr.status, fr.message, fr.created_at,
       u.public_id     AS other_public_id,
       u.display_name  AS other_display_name,
       img.storage_key AS other_avatar_storage_key
FROM friend_requests fr
JOIN users u              ON u.id = fr.addressee_id
LEFT JOIN user_profiles p ON p.user_id = u.id
LEFT JOIN images img      ON img.id = p.avatar_image_id
WHERE fr.requester_id = sqlc.arg('user_id') AND fr.status = 'pending'
  AND u.status = 'active'
ORDER BY fr.created_at DESC;

-- Checked in both directions before CreateFriendRequest, per the comment
-- above: a block must silently prevent a request, not surface who blocked whom.
-- name: IsBlocked :one
SELECT EXISTS(
    SELECT 1 FROM user_blocks
    WHERE (blocker_id = sqlc.arg('user_id') AND blocked_id = sqlc.arg('other_user_id'))
       OR (blocker_id = sqlc.arg('other_user_id') AND blocked_id = sqlc.arg('user_id'))
);

-- Everything a profile page needs to pick its buttons, in one round trip.
--
-- blocked_by_viewer is DIRECTIONAL on purpose, unlike IsBlocked: the caller
-- may learn that they blocked someone (it is their own row, and they need it to
-- offer Unblock), never that someone blocked them -- that would disclose the
-- block (docs/permissions.md §5). A block by the target therefore leaves this
-- row reading "nothing", and GetUser's NotFound is the only sign.
--
-- At most one pending request exists per pair (friend_requests_one_open_per_pair),
-- so at most one of the two request ids is non-zero (0 = none: COALESCE,
-- because sqlc reads a scalar subquery as a non-null int64).
-- name: GetRelationship :one
SELECT
    EXISTS(
        SELECT 1 FROM user_blocks
        WHERE blocker_id = sqlc.arg('viewer_id') AND blocked_id = sqlc.arg('target_id')
    ) AS blocked_by_viewer,
    EXISTS(
        SELECT 1 FROM friendships
        WHERE user_a_id = LEAST(sqlc.arg('viewer_id')::bigint, sqlc.arg('target_id')::bigint)
          AND user_b_id = GREATEST(sqlc.arg('viewer_id')::bigint, sqlc.arg('target_id')::bigint)
    ) AS friends,
    COALESCE((SELECT id FROM friend_requests
              WHERE requester_id = sqlc.arg('viewer_id') AND addressee_id = sqlc.arg('target_id')
                AND status = 'pending'), 0)::bigint AS outgoing_request_id,
    COALESCE((SELECT id FROM friend_requests
              WHERE requester_id = sqlc.arg('target_id') AND addressee_id = sqlc.arg('viewer_id')
                AND status = 'pending'), 0)::bigint AS incoming_request_id;

-- One friend's detail, scoped to the viewer's own friendships: joining on
-- friendships rather than a plain users lookup means "not my friend" and
-- "doesn't exist" both come back as zero rows. AcceptFriendRequest reads the new
-- friend through it.
-- name: GetFriend :one
SELECT u.id, u.public_id, u.display_name,
       img.storage_key AS avatar_storage_key,
       f.created_at    AS friends_since
FROM friendships f
JOIN users u
  ON u.id = CASE WHEN f.user_a_id = sqlc.arg('viewer_id') THEN f.user_b_id
                                                          ELSE f.user_a_id END
LEFT JOIN user_profiles p ON p.user_id = u.id
LEFT JOIN images img      ON img.id = p.avatar_image_id
WHERE (f.user_a_id = sqlc.arg('viewer_id') OR f.user_b_id = sqlc.arg('viewer_id'))
  AND u.id = sqlc.arg('friend_id')
  AND u.status = 'active';

-- Blocking ends the friendship first (if any) -- see BlockUser's transaction
-- in internal/user/service.go, which runs this before CancelPendingFriendRequestsBetween
-- and the insert into user_blocks.
-- name: DeleteFriendship :exec
DELETE FROM friendships
WHERE user_a_id = LEAST(sqlc.arg('user_id')::bigint, sqlc.arg('other_user_id')::bigint)
  AND user_b_id = GREATEST(sqlc.arg('user_id')::bigint, sqlc.arg('other_user_id')::bigint);

-- Cancelled rather than deleted, same reasoning as friend_requests being
-- "directional and auditable" (docs/data-model.md 7): a block should leave a
-- trace of the request it invalidated, not erase it.
-- name: CancelPendingFriendRequestsBetween :exec
UPDATE friend_requests
SET status = 'cancelled', responded_at = NOW()
WHERE status = 'pending'
  AND ((requester_id = sqlc.arg('user_id') AND addressee_id = sqlc.arg('other_user_id'))
    OR (requester_id = sqlc.arg('other_user_id') AND addressee_id = sqlc.arg('user_id')));

-- Idempotent on purpose: blocking someone already blocked is not an error,
-- it is the state the caller wanted.
-- name: BlockUser :exec
INSERT INTO user_blocks (blocker_id, blocked_id)
VALUES (sqlc.arg('blocker_id'), sqlc.arg('blocked_id'))
ON CONFLICT (blocker_id, blocked_id) DO NOTHING;

-- name: UnblockUser :exec
DELETE FROM user_blocks
WHERE blocker_id = sqlc.arg('blocker_id') AND blocked_id = sqlc.arg('blocked_id');

-- name: ListBlockedUsers :many
SELECT u.id, u.public_id, u.display_name, b.created_at AS blocked_at
FROM user_blocks b
JOIN users u ON u.id = b.blocked_id
WHERE b.blocker_id = sqlc.arg('blocker_id')
ORDER BY b.created_at DESC;

-- friendships is undirected, so "my friends" has to match either column and then
-- pick the other one -- that is what the CASE in the JOIN condition does. The OR
-- in the WHERE clause is served by two indexes (the PK for user_a_id, and
-- friendships_user_b_id_idx for the other side), which Postgres combines.
--
-- The avatar is reached through user_profiles to images with LEFT JOINs, so a
-- friend with no profile row or no avatar still appears, with a NULL storage key.
-- name: ListFriends :many
SELECT u.id,
       u.public_id,
       u.display_name,
       img.storage_key AS avatar_storage_key,
       f.created_at    AS friends_since
FROM friendships f
JOIN users u
  ON u.id = CASE WHEN f.user_a_id = sqlc.arg('user_id') THEN f.user_b_id
                                                        ELSE f.user_a_id END
LEFT JOIN user_profiles p ON p.user_id = u.id
LEFT JOIN images img      ON img.id = p.avatar_image_id
WHERE (f.user_a_id = sqlc.arg('user_id') OR f.user_b_id = sqlc.arg('user_id'))
  AND u.status = 'active'
ORDER BY u.display_name;

-- Finding someone to befriend or invite.
--
-- display_name only: it is the unique public handle (docs/data-model.md 5).
-- Matching email too would let anyone test whether an address has an account.
--
-- `pattern` arrives with \, % and _ already escaped by the service
-- (likePattern), so typing "%" looks for a percent sign instead of listing
-- everyone. A substring ILIKE cannot use a btree index; it would take pg_trgm,
-- which 00010_songs.sql already declined for the same kind of search. A
-- sequential scan of users is fine at this project's scale.
--
-- Left out: the caller, accounts that are not active, and anyone with a block
-- in EITHER direction -- the same rule as user#can_view_profile, so a result
-- always opens. The caller's own blocks are listed by ListBlockedUsers.
--
-- Names that start with the query come first ("ann" -> "Anna" before
-- "Joanne"), then alphabetical.
-- name: SearchUsers :many
SELECT u.id,
       u.public_id,
       u.display_name,
       img.storage_key AS avatar_storage_key
FROM users u
LEFT JOIN user_profiles p ON p.user_id = u.id
LEFT JOIN images img      ON img.id = p.avatar_image_id
WHERE u.status = 'active'
  AND u.id <> sqlc.arg('viewer_id')
  AND u.display_name ILIKE '%' || sqlc.arg('pattern')::text || '%' ESCAPE '\'
  AND NOT EXISTS (
      SELECT 1 FROM user_blocks b
      WHERE (b.blocker_id = sqlc.arg('viewer_id') AND b.blocked_id = u.id)
         OR (b.blocker_id = u.id AND b.blocked_id = sqlc.arg('viewer_id'))
  )
ORDER BY (u.display_name ILIKE sqlc.arg('pattern')::text || '%' ESCAPE '\') DESC,
         u.display_name
LIMIT sqlc.arg('max_results');
