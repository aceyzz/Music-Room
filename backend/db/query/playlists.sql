-- Music Playlist Editor (docs/data-model.md 9).
--
-- Every mutation below follows the same three steps, in one transaction:
--
--   1. BumpPlaylistRevision  -- takes the row lock, returns the new revision
--   2. the actual change     -- AppendSongToPlaylist, a move, a removal...
--   3. AppendPlaylistOp      -- journals it at that revision
--
-- Step 1 first is not a style choice. It serialises concurrent writers on the
-- playlists row, which is what makes revisions gapless and totally ordered, which
-- is what lets a reconnecting client call ListPlaylistOpsSince instead of
-- refetching everything.

-- Insert the playlist. The caller adds the owner's playlist_members row with role
-- 'owner' in the same transaction, so no authorization query ever has to
-- special-case playlists.owner_id.
-- name: CreatePlaylist :one
INSERT INTO playlists (owner_id, name, description, cover_image_id,
                       visibility, edit_license)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- Step 1 of every mutation. UPDATE ... RETURNING takes an exclusive row lock and
-- reads the new value in one statement, so two concurrent editors cannot be handed
-- the same revision number: the second blocks here until the first commits.
--
-- updated_at is not set explicitly -- the playlists_set_updated_at trigger does it.
-- name: BumpPlaylistRevision :one
UPDATE playlists
SET revision = revision + 1
WHERE id = $1
  AND deleted_at IS NULL
RETURNING revision;

-- Step 3. revision is the value BumpPlaylistRevision returned; the
-- playlist_ops_revision_key unique constraint is the backstop that catches any
-- code path which skipped step 1.
--
-- payload is JSONB and untyped on purpose -- an add_song op carries a song id and
-- a position, a rename carries two strings. The op_type enum tells the client how
-- to read it.
-- name: AppendPlaylistOp :one
INSERT INTO playlist_ops (playlist_id, revision, actor_id, op_type, payload)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- Reconnect replay: a client that was at revision N asks for everything after N
-- and applies it in order. Because revisions are gapless, receiving N+1..N+k
-- proves nothing was missed -- so a client that dropped for 30 seconds catches up
-- with a handful of rows instead of refetching the playlist.
-- name: ListPlaylistOpsSince :many
SELECT * FROM playlist_ops
WHERE playlist_id = sqlc.arg('playlist_id')
  AND revision > sqlc.arg('since_revision')
ORDER BY revision;

-- name: AddPlaylistOwner :exec
INSERT INTO playlist_members (playlist_id, user_id, role)
VALUES ($1, $2, 'owner');

-- Invited users, direct: like event_members, no pending/accept step.
-- name: AddPlaylistMember :exec
INSERT INTO playlist_members (playlist_id, user_id, role)
VALUES (sqlc.arg('playlist_id'), sqlc.arg('user_id'), 'editor')
ON CONFLICT (playlist_id, user_id) DO NOTHING;

-- Changes an existing member's role. Excludes the owner row on purpose:
-- reassigning ownership is a separate, owner-only operation
-- (can_transfer_ownership), not a role a manage_members admin can hand out
-- or take away -- so "target is the owner" and "target isn't a member at
-- all" both come back as zero rows here, same NotFound either way.
-- The people of a playlist, for its settings page: the owner first, then
-- admins, editors and viewers, each by when they joined.
-- name: ListPlaylistMembers :many
SELECT m.user_id, u.public_id, u.display_name, img.storage_key AS avatar_storage_key,
       m.role, m.joined_at
FROM playlist_members m
JOIN users u ON u.id = m.user_id
LEFT JOIN user_profiles p ON p.user_id = u.id
LEFT JOIN images img      ON img.id = p.avatar_image_id
WHERE m.playlist_id = sqlc.arg('playlist_id')
ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 WHEN 'editor' THEN 2 ELSE 3 END,
         m.joined_at;

-- Appends a song at the end (current max position + 1) in the "proper"
-- concurrency pattern (BumpPlaylistRevision -> this -> AppendPlaylistOp).
-- position stays NUMERIC in storage (gap-based, see MovePlaylistSong). The
-- bigint in RETURNING is not read for ordering: the handler answers with the
-- whole list, whose position is the row's index.
-- name: AppendSongToPlaylist :one
INSERT INTO playlist_songs (playlist_id, song_id, position, added_by_id)
SELECT sqlc.arg('playlist_id'),
       sqlc.arg('song_id'),
       COALESCE((
           SELECT MAX(position) FROM playlist_songs WHERE playlist_id = sqlc.arg('playlist_id')
       ), 0) + 1,
       sqlc.arg('added_by_id')
RETURNING id, playlist_id, song_id, position::bigint AS position, added_by_id, created_at;

-- revision = revision + 1 in the same UPDATE as the column it journals,
-- rather than a separate BumpPlaylistRevision call: this statement already
-- takes the row lock the bump exists to take, so a second UPDATE would only
-- lock the row twice for one mutation. Repository.SetVisibility appends the
-- matching playlist_ops row (visibility_change) right after, at the revision
-- this RETURNING hands back.
-- name: SetPlaylistVisibility :one
UPDATE playlists
SET visibility = $2,
    revision = revision + 1
WHERE id = $1
  AND deleted_at IS NULL
RETURNING *;

-- Same reasoning as SetPlaylistVisibility just above.
-- name: SetPlaylistEditLicense :one
UPDATE playlists
SET edit_license = $2,
    revision = revision + 1
WHERE id = $1
  AND deleted_at IS NULL
RETURNING *;

-- Same reasoning as SetPlaylistVisibility above -- revision folded into the
-- same UPDATE, journalled by the caller as 'rename' right after.
-- name: RenamePlaylist :one
UPDATE playlists
SET name = $2,
    revision = revision + 1
WHERE id = $1
  AND deleted_at IS NULL
RETURNING *;

-- Transfers ownership. Three statements, one transaction (see
-- Repository.TransferOwnership): promote the new owner's existing
-- membership row, demote the current owner's to admin (product decision:
-- the person who created the playlist keeps full day-to-day management,
-- just not can_delete/can_transfer_ownership), then move the authority
-- column itself. The first statement's affected-row count is the "is
-- new_owner actually a member?" check -- 0 rows means they are not, which
-- the caller reads as NotFound rather than silently doing nothing.
-- name: PromotePlaylistMemberToOwner :execrows
UPDATE playlist_members
SET role = 'owner'
WHERE playlist_id = sqlc.arg('playlist_id')
  AND user_id = sqlc.arg('user_id')
  AND role != 'owner';

-- name: DemotePlaylistOwnerToAdmin :exec
UPDATE playlist_members
SET role = 'admin'
WHERE playlist_id = sqlc.arg('playlist_id')
  AND user_id = sqlc.arg('user_id')
  AND role = 'owner';

-- current_owner_id in the WHERE is a belt-and-suspenders check: the
-- interceptor already confirmed the caller holds playlist#can_transfer_ownership
-- (owner) via the graph before this runs, but tying the column update to the
-- id that Check was actually about costs nothing and closes the (largely
-- theoretical) gap between "the graph said so" and "the row still agrees".
-- revision = revision + 1 here too, same reasoning as SetPlaylistVisibility
-- above: this UPDATE already locks the row, so the journalled revision
-- (Repository.TransferOwnership appends ownership_transfer right after)
-- rides along instead of costing a second lock.
-- name: TransferPlaylistOwnership :one
UPDATE playlists
SET owner_id = sqlc.arg('new_owner_id'),
    revision = revision + 1
WHERE id = sqlc.arg('playlist_id')
  AND owner_id = sqlc.arg('current_owner_id')
  AND deleted_at IS NULL
RETURNING *;

-- Soft delete. No cascade to playlist_ops/playlist_songs/playlist_members --
-- deleted_at IS NULL already gates every read and every id resolution
-- (GetPlaylistIDByPublicID, below), so the row becomes unreachable through
-- every existing RPC the instant this commits, tuples included: the
-- interceptor cannot resolve a deleted playlist's public_id at all, so it
-- never gets far enough to ask the graph anything. Nothing left over to
-- clean up there for that reason -- see internal/playlist/service.go:DeletePlaylist.
-- name: DeletePlaylist :one
UPDATE playlists
SET deleted_at = NOW()
WHERE id = $1
  AND deleted_at IS NULL
RETURNING *;


-- name: IncrementPlaylistStats :exec
UPDATE playlists AS p
SET song_count = song_count + 1,
    total_duration_seconds = total_duration_seconds + COALESCE((
        SELECT s.duration_seconds FROM songs AS s WHERE s.id = $2
    ), 0)
WHERE p.id = $1
  AND p.deleted_at IS NULL;

-- name: GetPlaylistSongDuration :one
SELECT s.duration_seconds
FROM playlist_songs ps
JOIN songs s ON s.id = ps.song_id
WHERE ps.id = $1
  AND ps.playlist_id = $2;

-- name: RemovePlaylistSong :exec
DELETE FROM playlist_songs AS ps
WHERE ps.id = $1
  AND ps.playlist_id = $2;

-- name: DecrementPlaylistStats :exec
UPDATE playlists
SET song_count = GREATEST(song_count - 1, 0),
    total_duration_seconds = GREATEST(total_duration_seconds - $2, 0)
WHERE id = $1;

-- name: GetPlaylistByID :one
SELECT * FROM playlists
WHERE id = $1
  AND deleted_at IS NULL;

-- ListPlaylists (docs/todo.md §2): the authorization question -- which ids
-- may the caller see -- is answered beforehand by OpenFGA ListObjects
-- (internal/authz.Client.ListObjects), never re-derived here. This query only
-- hydrates ids ListObjects already vetted; a WHERE clause that tried to
-- reconstruct "owner OR admin OR ... OR public" in SQL is exactly the drift
-- the todo item warns against -- one relation added to model.fga and not
-- mirrored here silently leaks or hides playlists.
--
-- ORDER BY created_at DESC does NOT use playlists_public_idx -- that index is
-- partial (WHERE visibility = 'public'), built for a "browse public
-- playlists" scan this query never does (it always starts from a known set
-- of ids, via playlists_public_id_key instead). The result set still needs
-- an explicit sort; id as a tiebreaker makes it fully deterministic (two rows
-- can share a created_at down to the microsecond under concurrent inserts),
-- which matters for a client diffing two responses and for tests asserting
-- on order.
-- name: GetPlaylistsByPublicIDs :many
SELECT * FROM playlists
WHERE public_id = ANY(sqlc.arg('public_ids')::UUID[])
  AND deleted_at IS NULL
ORDER BY created_at DESC, id DESC;

-- position comes back as the row's 1-based index, not the stored value: after
-- a move the stored value is a midpoint such as 2.75, which a bigint cast
-- would round onto its neighbour. id breaks ties, which MovePlaylistSong never
-- creates, so the order is the same on every read regardless.
-- name: GetPlaylistSongsByPlaylistID :many
SELECT ps.id,
       ps.playlist_id,
       ps.song_id,
       ROW_NUMBER() OVER (ORDER BY ps.position, ps.id)::bigint AS position,
       ps.added_by_id,
       ps.created_at,
       sqlc.embed(s)
FROM playlist_songs ps
JOIN songs s ON s.id = ps.song_id
WHERE ps.playlist_id = $1
ORDER BY ps.position, ps.id;

-- Step 2 of a move: puts song `id` right after song `after_id`, or at the top
-- when after_id is 0. Only the moved row is written.
--
--   between two songs  (anchor + next) * 0.5
--   after the last one anchor + 1
--   at the top         first - 1 (or unchanged when it is the only song)
--
-- `* 0.5`, never `/ 2`: NUMERIC division rounds its result to a fixed scale
-- (20 digits here), so after ~65 moves into the same gap the midpoint rounds
-- onto its neighbour and two positions are equal (measured:
-- TestMovePlaylistSongMidpointsNeverCollide fails at move 69 with `/ 2`). Multiplication is exact -- the scale grows by one digit per
-- halving -- so midpoints never collide and nothing has to rebalance.
--
-- Every lookup is scoped to playlist_id and excludes the moved row. No row is
-- updated (0 affected) when the song or the anchor is not in this playlist,
-- which the handler reports as NotFound: one of them was removed meanwhile.
-- name: MovePlaylistSong :execrows
WITH anchor AS (
    SELECT position
    FROM playlist_songs
    WHERE id = sqlc.arg('after_id')
      AND playlist_id = sqlc.arg('playlist_id')
),
next_after_anchor AS (
    SELECT MIN(ps.position) AS position
    FROM playlist_songs ps, anchor
    WHERE ps.playlist_id = sqlc.arg('playlist_id')
      AND ps.id <> sqlc.arg('id')
      AND ps.position > anchor.position
),
first_song AS (
    SELECT MIN(position) AS position
    FROM playlist_songs
    WHERE playlist_id = sqlc.arg('playlist_id')
      AND id <> sqlc.arg('id')
)
UPDATE playlist_songs AS moved
SET position = CASE
    WHEN sqlc.arg('after_id')::bigint = 0 THEN
        COALESCE((SELECT position FROM first_song) - 1, moved.position)
    ELSE
        COALESCE(((SELECT position FROM anchor) + (SELECT position FROM next_after_anchor)) * 0.5,
                 (SELECT position FROM anchor) + 1)
END
WHERE moved.id = sqlc.arg('id')
  AND moved.playlist_id = sqlc.arg('playlist_id')
  AND (sqlc.arg('after_id')::bigint = 0 OR EXISTS (SELECT 1 FROM anchor));

-- name: PlaylistSongExists :one
SELECT EXISTS(
  SELECT 1
  FROM playlist_songs
  WHERE playlist_id = $1
    AND song_id = $2
);

-- name: SetPlaylistCover :one
UPDATE playlists
SET cover_image_id = sqlc.arg('cover_image_id')
WHERE id = sqlc.arg('playlist_id')
  AND deleted_at IS NULL
RETURNING *;

-- SetPlaylistCover cannot SET the column back to NULL (a bound param means
-- "this value", never "clear it") -- DeletePlaylistCover needs exactly that,
-- same reasoning as UserService's ClearUserAvatar.
-- name: ClearPlaylistCover :exec
UPDATE playlists
SET cover_image_id = NULL
WHERE id = $1
  AND deleted_at IS NULL;
-- Resolution for the authorization interceptor. See GetUserIDByPublicID.
--
-- Filters deleted_at here rather than leaving it to the handler: a soft-deleted
-- playlist must read as gone, and a Check would happily answer `can_view: true`
-- for one -- `deleted_at` is not a tuple and never will be (authz/model.fga,
-- "What is deliberately NOT here"). No row means NotFound before any permission
-- question is asked, which is also the right answer for a made-up UUID.
-- name: GetPlaylistIDByPublicID :one
SELECT id
FROM playlists
WHERE public_id = $1
  AND deleted_at IS NULL;

-- ListLibraryPlaylists: the playlists among public_ids (what ListObjects
-- says the viewer may view) with everything the library list shows, and what
-- the handler needs to keep only the library -- is_owner, is_member,
-- owner_is_friend. Owners blocked in either direction are dropped here.
-- name: ListLibraryPlaylists :many
SELECT p.public_id, p.name, p.song_count, p.visibility,
       o.public_id AS owner_public_id, o.display_name AS owner_display_name,
       (p.owner_id = sqlc.arg('viewer_id')::bigint) AS is_owner,
       EXISTS (SELECT 1 FROM playlist_members m
               WHERE m.playlist_id = p.id AND m.user_id = sqlc.arg('viewer_id')::bigint) AS is_member,
       EXISTS (SELECT 1 FROM friendships f
               WHERE f.user_a_id = LEAST(p.owner_id, sqlc.arg('viewer_id')::bigint)
                 AND f.user_b_id = GREATEST(p.owner_id, sqlc.arg('viewer_id')::bigint)) AS owner_is_friend,
       (SELECT COUNT(*) FROM playlist_members m
        WHERE m.playlist_id = p.id AND m.role IN ('owner', 'admin', 'editor'))::int AS editor_count,
       COALESCE((SELECT s.cover_url FROM playlist_songs ps JOIN songs s ON s.id = ps.song_id
                 WHERE ps.playlist_id = p.id
                 ORDER BY ps.position, ps.id LIMIT 1), '')::text AS first_song_cover_url
FROM playlists p
JOIN users o ON o.id = p.owner_id
WHERE p.public_id = ANY(sqlc.arg('public_ids')::UUID[])
  AND p.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM user_blocks b
                  WHERE (b.blocker_id = sqlc.arg('viewer_id')::bigint AND b.blocked_id = p.owner_id)
                     OR (b.blocker_id = p.owner_id AND b.blocked_id = sqlc.arg('viewer_id')::bigint))
ORDER BY p.updated_at DESC, p.id DESC;

-- SearchPublicPlaylists: one page of public playlists whose name contains
-- `query` (strpos on lower(): no LIKE, so a % or _ typed by the user is just
-- a character; '' matches every name), newest first, with what the list
-- shows -- same columns as ListLibraryPlaylists, relation computed by the
-- handler. Owners blocked in either direction are dropped. Offset paging:
-- the handler asks for one row more than the page to know if there is a next.
-- name: SearchPublicPlaylists :many
SELECT p.public_id, p.name, p.song_count,
       o.public_id AS owner_public_id, o.display_name AS owner_display_name,
       (p.owner_id = sqlc.arg('viewer_id')::bigint) AS is_owner,
       EXISTS (SELECT 1 FROM playlist_members m
               WHERE m.playlist_id = p.id AND m.user_id = sqlc.arg('viewer_id')::bigint) AS is_member,
       EXISTS (SELECT 1 FROM friendships f
               WHERE f.user_a_id = LEAST(p.owner_id, sqlc.arg('viewer_id')::bigint)
                 AND f.user_b_id = GREATEST(p.owner_id, sqlc.arg('viewer_id')::bigint)) AS owner_is_friend,
       (SELECT COUNT(*) FROM playlist_members m
        WHERE m.playlist_id = p.id AND m.role IN ('owner', 'admin', 'editor'))::int AS editor_count,
       COALESCE((SELECT s.cover_url FROM playlist_songs ps JOIN songs s ON s.id = ps.song_id
                 WHERE ps.playlist_id = p.id
                 ORDER BY ps.position, ps.id LIMIT 1), '')::text AS first_song_cover_url
FROM playlists p
JOIN users o ON o.id = p.owner_id
WHERE p.visibility = 'public'
  AND p.deleted_at IS NULL
  AND strpos(lower(p.name), lower(sqlc.arg('query')::text)) > 0
  -- "My taste": the owner likes at least one genre the viewer likes. Only
  -- owners who show their music preferences to everyone count, or the
  -- filter would reveal tastes kept for friends or for themselves.
  AND (NOT sqlc.arg('my_taste')::bool OR EXISTS (
        SELECT 1
        FROM user_music_preferences theirs
        JOIN user_music_preferences mine
          ON mine.deezer_genre_id = theirs.deezer_genre_id
         AND mine.user_id = sqlc.arg('viewer_id')::bigint
        LEFT JOIN user_profiles op ON op.user_id = theirs.user_id
        WHERE theirs.user_id = p.owner_id
          -- No profile row yet: the column's default, public.
          AND COALESCE(op.preferences_visibility, 'public') = 'public'))
  AND NOT EXISTS (SELECT 1 FROM user_blocks b
                  WHERE (b.blocker_id = sqlc.arg('viewer_id')::bigint AND b.blocked_id = p.owner_id)
                     OR (b.blocker_id = p.owner_id AND b.blocked_id = sqlc.arg('viewer_id')::bigint))
ORDER BY p.created_at DESC, p.id DESC
LIMIT sqlc.arg('row_limit')::int OFFSET sqlc.arg('row_offset')::int;
