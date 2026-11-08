-- Music Track Vote (docs/data-model.md 10).

-- Simple mutations used by the first live-playlist API. Mirrors the pattern
-- used by playlists.sql: authorization is intentionally kept outside this
-- service for now.
-- name: CreateEventSimple :one
INSERT INTO events (
    host_id, source_playlist_id, name, description, visibility, vote_license,
    venue_latitude, venue_longitude, venue_radius_meters,
    vote_window_start, vote_window_end, vote_window_timezone,
    starts_at, ends_at
)
VALUES (
    sqlc.arg('host_id'),
    NULLIF(sqlc.arg('source_playlist_id')::bigint, 0),
    sqlc.arg('name'),
    NULLIF(sqlc.arg('description')::text, ''),
    sqlc.arg('visibility'),
    sqlc.arg('vote_license'),
    sqlc.narg('venue_latitude'),
    sqlc.narg('venue_longitude'),
    NULLIF(sqlc.arg('venue_radius_meters')::int, 0),
    sqlc.narg('vote_window_start'),
    sqlc.narg('vote_window_end'),
    NULLIF(sqlc.arg('vote_window_timezone')::text, ''),
    sqlc.narg('starts_at'),
    sqlc.narg('ends_at')
)
RETURNING *;

-- name: AddEventOwner :exec
INSERT INTO event_members (event_id, user_id, role)
VALUES (sqlc.arg('event_id'), sqlc.arg('user_id'), 'owner');

-- Which of these events the user is a member of (host or invited), for
-- MusicEventDTO.viewer_is_member.
-- name: ListUserEventMemberships :many
SELECT event_id FROM event_members
WHERE user_id = sqlc.arg('user_id') AND event_id = ANY(sqlc.arg('event_ids')::bigint[]);

-- Invited users, direct: the subject only ever describes "invited users",
-- never a pending/accept step, so this adds the membership row outright.
-- name: AddEventMember :exec
INSERT INTO event_members (event_id, user_id, role)
VALUES (sqlc.arg('event_id'), sqlc.arg('user_id'), 'viewer')
ON CONFLICT (event_id, user_id) DO NOTHING;

-- "who is invited to this event" (the host included, as the 'owner' row).
-- name: ListEventMembers :many
SELECT m.user_id, u.public_id, u.display_name, img.storage_key AS avatar_storage_key,
       m.role, m.joined_at
FROM event_members m
JOIN users u ON u.id = m.user_id
LEFT JOIN user_profiles p ON p.user_id = u.id
LEFT JOIN images img      ON img.id = p.avatar_image_id
WHERE m.event_id = sqlc.arg('event_id')
ORDER BY m.joined_at;

-- Changes the vote license (and its venue/window) after creation. The three
-- venue/window columns are always overwritten together with the license --
-- switching away from location_time clears them, since the CHECK constraint
-- forbids a non-location_time license from keeping stale venue data.
-- Makes an event public or private after creation.
-- name: SetEventVisibility :one
UPDATE events
SET visibility = sqlc.arg('visibility')
WHERE id = sqlc.arg('id')
RETURNING *;

-- name: SetEventVoteLicense :one
UPDATE events
SET vote_license        = sqlc.arg('vote_license'),
    venue_latitude       = sqlc.narg('venue_latitude'),
    venue_longitude      = sqlc.narg('venue_longitude'),
    venue_radius_meters  = NULLIF(sqlc.arg('venue_radius_meters')::int, 0),
    vote_window_start    = sqlc.narg('vote_window_start'),
    vote_window_end      = sqlc.narg('vote_window_end'),
    vote_window_timezone = NULLIF(sqlc.arg('vote_window_timezone')::text, '')
WHERE id = sqlc.arg('id')
RETURNING *;

-- Every event gets a playback row at creation so the radio station always has
-- something to read, even before anything has played (paused, no current song).
-- name: CreateEventPlaybackState :exec
INSERT INTO event_playback_states (event_id)
VALUES (sqlc.arg('event_id'));

-- name: GetEventByID :one
SELECT * FROM events
WHERE id = sqlc.arg('id')
  AND deleted_at IS NULL;

-- Lifecycle (docs/permissions.md §13): scheduled -> live -> ended, ended
-- terminal. The host's first play makes an event live (MarkEventLive, below);
-- EndEvent is the one transition a request asks for. event#can_change_status
-- (host or admin) says WHO; the status in the WHERE clause doubles as a
-- compare-and-swap, so two transitions racing each other can't both land: the
-- second UPDATE affects zero rows once the first has committed, surfaced by
-- the caller as FailedPrecondition, never silently overwritten. Pausing is the
-- music's (SetEventPlayback): the event stays live.
--
-- End is legal from any status but ended: one whose event never started ends
-- it too (the app has End event, not Delete).
-- name: EndEvent :one
UPDATE events
SET status = 'ended',
    revision = revision + 1
WHERE id = $1
  AND deleted_at IS NULL
  AND status IN ('scheduled', 'live')
RETURNING *;

-- Soft delete. Legal from ANY status (docs/permissions.md §13 states no
-- restriction, unlike the four transitions above) -- a host can delete a
-- scheduled event that never happened, or a live one mid-session. No
-- cascade: same reasoning as PlaylistService's DeletePlaylist
-- (db/query/playlists.sql) -- deleted_at IS NULL already gates every read
-- and every id resolution (GetEventIDByPublicID, below), so the event
-- becomes unreachable through every other RPC the instant this commits,
-- tuples included. The one thing that does NOT reach through a Postgres
-- query -- the in-memory auto-advance timer (scheduler.go) -- is cancelled
-- by the handler after this commits (internal/event/lifecycle.go).
-- name: DeleteEvent :one
UPDATE events
SET deleted_at = NOW()
WHERE id = $1
  AND deleted_at IS NULL
RETURNING *;

-- Internal promotion used by playNext (internal/event/playback.go), not
-- exposed as its own RPC: starting an actual song -- manually via
-- PlayNextInEventQueue, or automatically via the auto-advance
-- scheduler -- is itself what makes an event "live" the first
-- time, same as a radio station going live the moment it starts
-- broadcasting rather than requiring the host to flip a separate switch
-- first: `scheduled` (first song ever) -- `live` itself never reaches here,
-- playNext checks that before calling.
-- name: MarkEventLive :one
UPDATE events
SET status = 'live',
    revision = revision + 1
WHERE id = $1
  AND deleted_at IS NULL
  AND status = 'scheduled'
RETURNING *;

-- GetMusicEvents (docs/todo.md §3): the authorization question -- which ids
-- may the caller see -- is answered beforehand by OpenFGA ListObjects
-- (internal/authz.Client.ListObjects, event#can_view), never re-derived
-- here. This query only hydrates ids ListObjects already vetted -- same
-- reasoning and same shape as PlaylistService's GetPlaylistsByPublicIDs
-- (db/query/playlists.sql).
-- name: GetEventsByPublicIDs :many
SELECT * FROM events
WHERE public_id = ANY(sqlc.arg('public_ids')::UUID[])
  AND deleted_at IS NULL
ORDER BY created_at DESC, id DESC;

-- Adds a song to an event's live vote queue. The partial unique index
-- event_queue_entries_one_active_per_song ((event_id, song_id) WHERE status IN
-- ('queued', 'playing')) turns a re-suggestion of an already-queued song into a
-- unique_violation, which the service surfaces as AlreadyExists.
-- name: SuggestSongToQueue :one
INSERT INTO event_queue_entries (event_id, song_id, suggested_by_id)
VALUES (
    sqlc.arg('event_id'),
    sqlc.arg('song_id'),
    NULLIF(sqlc.arg('suggested_by_id')::bigint, 0)
)
RETURNING *;

-- The vote. This is the one query in the codebase whose exact shape is
-- load-bearing; the reasoning is in the comment above event_queue_votes in
-- 00012_events.sql and is summarised here.
--
-- One statement does four things:
--
--   * UNIQUE (queue_entry_id, user_id) makes a double vote structurally
--     impossible -- no read-then-write race can defeat it.
--   * ON CONFLICT DO NOTHING makes the RPC idempotent, so a client retry is a
--     no-op rather than a second vote.
--   * The UPDATE is a single-row read-modify-write under a Postgres row lock, so
--     N simultaneous votes serialise and all land. Correct under READ COMMITTED --
--     no SERIALIZABLE, no retry loop.
--   * score_reached_at is taken from the vote's clock_timestamp() (read while the
--     lock is held) and wrapped in GREATEST, so it is monotonic. NOW() would be
--     the transaction timestamp and could stamp it BACKWARDS under contention,
--     breaking the queue ordering.
--
--   * The vote row is only written through `entry`, which locks the entry while
--     it is still 'queued'. A data-modifying CTE always runs to completion,
--     whatever the outer UPDATE matches: written unconditionally (as it once
--     was), a vote on a song that had just started playing kept its row while
--     the UPDATE, finding the entry no longer queued, left vote_count alone --
--     vote rows and vote_count drifted apart, and the RPC answered
--     accepted=false for a vote it had stored. The load test's consistency
--     check found it (docs/load-testing.md). FOR UPDATE, not a plain EXISTS:
--     under READ COMMITTED a PlayNext committing between the check and the
--     UPDATE would reopen the same gap; with the lock it waits, or it went
--     first and FOR UPDATE re-reads the row and finds it no longer queued.
--
-- ZERO ROWS IS A NORMAL RESULT, not an error: it means either the user had already
-- voted (the conflict fired) or the entry is no longer 'queued'. Both are no-ops --
-- nothing is written -- so the handler treats pgx.ErrNoRows as "nothing to do" and
-- re-reads the queue.
-- name: CastQueueVote :one
WITH entry AS (
    SELECT id FROM event_queue_entries
    WHERE id = sqlc.arg('queue_entry_id') AND status = 'queued'
    FOR UPDATE
),
inserted AS (
    INSERT INTO event_queue_votes (queue_entry_id, user_id, voter_latitude, voter_longitude)
    SELECT entry.id, sqlc.arg('user_id'), sqlc.narg('voter_latitude'), sqlc.narg('voter_longitude')
    FROM entry
    ON CONFLICT (queue_entry_id, user_id) DO NOTHING
    RETURNING created_at
)
UPDATE event_queue_entries e
SET vote_count       = e.vote_count + 1,
    score_reached_at = GREATEST(e.score_reached_at, (SELECT created_at FROM inserted))
WHERE e.id = sqlc.arg('queue_entry_id')
  AND e.status = 'queued'
  AND EXISTS (SELECT 1 FROM inserted)
RETURNING e.vote_count, e.score_reached_at;

-- The hot read path. There is no position column: the ORDER BY *is* the queue.
-- vote_count DESC then score_reached_at ASC means "most votes first, and on a tie
-- the song that got there first" -- which is exact only because vote_count is
-- monotonic (no unvote) and score_reached_at is monotonic (see above).
-- event_queue_entries_ranking_idx covers this exactly, sort included.
--
-- viewer_has_voted drives the UI's filled/empty vote button. EXISTS is a semi-join
-- on the (queue_entry_id, user_id) unique index -- it stops at the first match and
-- returns a plain bool, unlike a LEFT JOIN which would need a NULL check and could
-- duplicate rows.
-- name: ListEventQueue :many
SELECT e.id,
       e.public_id,
       e.vote_count,
       e.score_reached_at,
       e.suggested_by_id,
       sqlc.embed(s),
       EXISTS (
           SELECT 1 FROM event_queue_votes v
           WHERE v.queue_entry_id = e.id
             AND v.user_id = sqlc.arg('viewer_id')
       ) AS viewer_has_voted
FROM event_queue_entries e
JOIN songs s ON s.id = e.song_id
WHERE e.event_id = sqlc.arg('event_id')
  AND e.status = 'queued'
ORDER BY e.vote_count DESC, e.score_reached_at;

-- The radio station read path: current playback state, no join. A fresh
-- event has current_entry_id NULL, which the LEFT JOIN version of this query
-- used to scan into a non-nullable embedded Song and crash -- fetch the song
-- separately (GetQueueEntrySong) only when there is one.
-- name: GetEventPlaybackState :one
SELECT * FROM event_playback_states
WHERE event_id = sqlc.arg('event_id');

-- Same read, but locking the row: used inside playNext's transaction so two
-- concurrent advances for the same event (the auto-advance timer racing a
-- manual skip, or two suggestions racing to start an idle radio) serialise
-- instead of both starting a song at once.
-- name: GetEventPlaybackStateForUpdate :one
SELECT * FROM event_playback_states
WHERE event_id = sqlc.arg('event_id')
FOR UPDATE;

-- Only ever called with a queue entry id known to exist (current_entry_id),
-- so no LEFT JOIN / NULL-scan risk here.
-- name: GetQueueEntrySong :one
SELECT s.* FROM event_queue_entries e
JOIN songs s ON s.id = e.song_id
WHERE e.id = sqlc.arg('id');

-- name: GetNextQueuedEntry :one
SELECT e.*, sqlc.embed(s)
FROM event_queue_entries e
JOIN songs s ON s.id = e.song_id
WHERE e.event_id = sqlc.arg('event_id')
  AND e.status = 'queued'
ORDER BY e.vote_count DESC, e.score_reached_at
LIMIT 1;

-- name: MarkQueueEntryPlaying :exec
UPDATE event_queue_entries SET status = 'playing' WHERE id = sqlc.arg('id');

-- name: MarkQueueEntryPlayed :exec
UPDATE event_queue_entries SET status = 'played', played_at = NOW() WHERE id = sqlc.arg('id');

-- RemoveQueueEntry (docs/todo.md §3, docs/permissions.md §12):
-- queue_entry#can_remove (suggester OR can_manage_queue from parent) is
-- already checked by the interceptor against the entry itself -- no
-- event_id needed here, same reasoning as CastVote's CastQueueVote just
-- above it not taking one either. A genuine DELETE, not a status flag: no
-- audit trail is needed for a live vote queue (event_ops -- unused for any
-- mutation today, see docs/todo.md -- would be the place for one), and
-- deleting is what makes event_queue_entries_one_active_per_song allow the
-- same song to be re-suggested right away.
--
-- status = 'queued' in the WHERE is the compare-and-swap: "already playing
-- or played" -- docs/permissions.md's "you cannot un-suggest a song that is
-- already playing" -- surfaces as zero rows affected, not a race the
-- caller can win against a concurrent PlayNextInEventQueue.
-- name: RemoveQueueEntry :execrows
DELETE FROM event_queue_entries
WHERE id = $1
  AND status = 'queued';

-- Advances the radio station to a new song: reset the playhead, unpause, and
-- record who (if anyone) triggered it.
-- name: StartEventPlayback :one
UPDATE event_playback_states
SET current_entry_id   = sqlc.arg('current_entry_id'),
    controller_user_id = NULLIF(sqlc.arg('controller_user_id')::bigint, 0),
    is_paused           = FALSE,
    position_ms         = 0,
    started_at          = NOW()
WHERE event_id = sqlc.arg('event_id')
RETURNING *;

-- Makes device_id the event's speaker if it has none yet (docs/todo.md §4, D1):
-- the device of the host's first play keeps it until the host picks another
-- (SetEventSpeaker, which moves the licences along), so a delegate's licence on it
-- keeps meaning something when the host presses play from another device.
-- The IS NULL test makes it one statement with no read-then-write race.
-- name: ClaimEventSpeaker :exec
UPDATE event_playback_states
SET speaker_device_id = sqlc.arg('device_id')
WHERE event_id = sqlc.arg('event_id')
  AND speaker_device_id IS NULL;

-- Pause, resume or seek the song currently playing.
--
-- Play, pause and seek all reduce to this: a pause flag plus a playhead.
-- The client does not need ticks pushed to it. position_ms is the playhead as of
-- updated_at (maintained by the event_playback_states_set_updated_at trigger), so
-- a joining client computes where the song is now as
-- position_ms + (now - updated_at) when not paused. That is why this table is
-- separate from events: it is rewritten several times per song, while events is
-- nearly static.
-- name: SetEventPlaybackState :one
UPDATE event_playback_states
SET is_paused           = sqlc.arg('is_paused'),
    position_ms         = sqlc.arg('position_ms'),
    controller_user_id  = NULLIF(sqlc.arg('controller_user_id')::bigint, 0)
WHERE event_id = sqlc.arg('event_id')
RETURNING *;

-- Clears "now playing" when the queue runs dry, so the radio reports
-- silence instead of leaving a finished (or skipped) song looking current
-- with a playhead that drifts past its own duration until someone
-- intervenes manually.
-- name: StopEventPlayback :one
UPDATE event_playback_states
SET current_entry_id = NULL,
    is_paused         = TRUE,
    position_ms       = 0
WHERE event_id = sqlc.arg('event_id')
RETURNING *;

-- Resolution for the authorization interceptor. See GetPlaylistIDByPublicID for
-- why deleted_at is filtered here.
-- name: GetEventIDByPublicID :one
SELECT id
FROM events
WHERE public_id = $1
  AND deleted_at IS NULL;

-- Resolution for the authorization interceptor.
--
-- No status filter: `queued` / `playing` / `played` is a residual Go check (the
-- entry must still be queued to be voted on or removed), and folding it in here
-- would turn "you cannot vote for a song that already played" into a bare
-- NotFound.
-- name: GetQueueEntryIDByPublicID :one
SELECT id
FROM event_queue_entries
WHERE public_id = $1;

-- The events whose auto-advance timer must be armed again at boot: the timers
-- live in memory (internal/event/scheduler.go), so a restart loses them all and
-- every playing event would stay on its song past the end. remaining_ms is how
-- much of the current song is left now, from the playhead as of updated_at
-- (what clients extrapolate from too); negative when it is already over.
-- name: ListPlayingEvents :many
SELECT p.event_id,
       (s.duration_seconds::bigint * 1000 - p.position_ms
        - (EXTRACT(EPOCH FROM (NOW() - p.updated_at)) * 1000)::bigint)::bigint AS remaining_ms
FROM event_playback_states p
JOIN events e ON e.id = p.event_id
JOIN event_queue_entries q ON q.id = p.current_entry_id
JOIN songs s ON s.id = q.song_id
WHERE NOT p.is_paused
  AND e.status = 'live'
  AND e.deleted_at IS NULL;

-- The events whose song is playing, with their host (the speaker: today
-- only the host plays the sound) and where the song is now, for
-- PauseAbsentSpeakers.
-- name: ListPlayingEventHosts :many
SELECT p.event_id, e.host_id,
       LEAST(s.duration_seconds::bigint * 1000,
             p.position_ms + (EXTRACT(EPOCH FROM (NOW() - p.updated_at)) * 1000)::bigint)::int
           AS position_ms
FROM event_playback_states p
JOIN events e ON e.id = p.event_id
JOIN event_queue_entries q ON q.id = p.current_entry_id
JOIN songs s ON s.id = q.song_id
WHERE NOT p.is_paused
  AND e.status = 'live'
  AND e.deleted_at IS NULL;

-- What each listed event's player is doing, for MusicEventDTO.playback: an
-- event with no row here (never started) is idle, like one whose queue ran dry.
-- A picture for each event's card: the cover of the song playing, else of
-- the one that plays next (most votes first, as GetNextQueuedEntry); empty
-- when neither has one.
-- name: GetEventCovers :many
SELECT e.id AS event_id,
       COALESCE(
           (SELECT s.cover_url
            FROM event_playback_states p
            JOIN event_queue_entries q ON q.id = p.current_entry_id
            JOIN songs s ON s.id = q.song_id
            WHERE p.event_id = e.id),
           (SELECT s.cover_url
            FROM event_queue_entries q
            JOIN songs s ON s.id = q.song_id
            WHERE q.event_id = e.id AND q.status = 'queued' AND s.cover_url IS NOT NULL
            ORDER BY q.vote_count DESC, q.score_reached_at
            LIMIT 1),
           '')::text AS cover_url
FROM events e
WHERE e.id = ANY(sqlc.arg('event_ids')::BIGINT[]);

-- name: GetEventPlaybackSummaries :many
SELECT event_id, (current_entry_id IS NOT NULL)::boolean AS has_song, is_paused
FROM event_playback_states
WHERE event_id = ANY(sqlc.arg('event_ids')::BIGINT[]);

-- Ends, at once, every event past its planned end where nothing plays: what
-- EndEvent does for one, run by the server on its own (RunEventEnder, every
-- 10 s) so an event nobody ended does not stay "current" forever. Events
-- with no ends_at are left alone.
--
-- A party that still plays goes on until the host presses End event; once
-- past its end, the music stopping (a pause, the host away, the queue dry)
-- ends it. A scheduled event that never started ends the same way. Returns
-- their ids, to stop their timers.
-- name: EndOverdueEvents :many
UPDATE events e
SET status = 'ended',
    revision = revision + 1
WHERE e.status IN ('scheduled', 'live')
  AND e.ends_at IS NOT NULL
  AND e.deleted_at IS NULL
  AND e.ends_at <= NOW()
  AND NOT EXISTS (
      SELECT 1 FROM event_playback_states p
      WHERE p.event_id = e.id
        AND p.current_entry_id IS NOT NULL
        AND NOT p.is_paused
  )
RETURNING e.id;
