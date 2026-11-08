# Tuple sync — summary

*One-minute read. The how-to is in [`authz-sync-guide.md`](./authz-sync-guide.md).*

## What this is

Postgres is the source of truth; OpenFGA holds a derived copy of it as relationship
tuples. There is no transaction spanning the two, so keeping them in step is a
delivery problem. This is the machinery that solves it.

## How it works

One **logical change** = one row in `openfga_tuple_outbox`, inserted **inside the same
Postgres transaction as the domain change**. That is the whole trick: it makes
*"a committed change always has a durable tuple intent"* an invariant of the database
rather than a property of the code path. Everything after the commit is best-effort on
top of an intent that cannot be lost.

Delivery is: an inline attempt right after commit (so the graph is current when the
response goes out), then a background worker every 15s for whatever failed. Rows are
deleted on success, so an empty table means the graph is in sync.

## Decisions worth knowing

- **Public UUIDs as object ids**, never the `BIGSERIAL` keys — a check must be answerable
  from the request alone. `devices`, `images` and `event_queue_entries` got theirs in
  `00017_public_ids.sql`; without it, half the model was unwritable.
- **Writes and deletes travel together.** An event's vote licence is one of three mutually
  exclusive tuples. Applying the delete of the old one and the write of the new one
  separately passes through a wrong state, and one order is wrong in the permissive
  direction.
- **Per-object ordering.** The claim query will not hand out a row while an older row for
  the same object is unfinished. Otherwise a failed change can retry *after* a newer one
  and win, leaving the graph stale — and for a visibility tuple, stale can mean public.
- **Idempotent by necessity.** OpenFGA rejects a whole batch if one tuple already exists
  (`on_duplicate_writes` is ignored by server v1.18.3). So `Apply` falls back to
  tuple-by-tuple, deletes first, treating "already exists" and "does not exist" as success.

## Status

Live for every mutation that grants or removes a permission:

| Slice | Mutations synced |
| --- | --- |
| Accounts | `Register`, `UpdateUserProfile` |
| Social | `AcceptFriendRequest`, `BlockUser`, `UnblockUser` |
| Playlists | `CreatePlaylist`, `SetPlaylistVisibility`, `InviteToPlaylist`, `SetPlaylistCover`, `DeletePlaylistCover` |
| Events | `CreateEvent`, `SetEventVoteLicense`, `InviteToEvent`, `SuggestSong` |
| Delegation | `RegisterDevice`, `GrantDeviceControl`, `RevokeDeviceControl` |
| Avatars | `UploadAvatar`, `DeleteAvatar` |

Mutations that owe **nothing**, and should not be "fixed" to write a tuple:
`AddSongToPlaylist` / `RemoveSongFromPlaylist` (governed by `playlist#can_edit_songs`, which
resolves from the playlist's own tuples — the song catalogue is world-readable and
`playlist_songs` rows are not permission objects), `CastVote`, `SendFriendRequest`,
`DeclineFriendRequest`, `SetMusicPreferences`, and all playback state.

One behaviour changed rather than just being synced: **`BlockUser` now revokes the device
control grants between the two users**, in Postgres and in the graph. It did not before.
Delegation is friends-only as a write-time precondition and the model has no friendship
relation to re-evaluate, so a block left the ex-friend driving the speaker.

**The graph is now read.** `backend/internal/interceptor` authenticates and authorizes every
RPC before its handler, from a policy table that denies any method it does not list
([`authz-enforcement.md`](./authz-enforcement.md)). `canViewPlaylist`, `canEditPlaylist`,
`canViewEvent` and `canVoteInEvent` are deleted; what stays in Go is the residual list in
that document.

**Still not built:** the periodic full reconciliation sweep, and tuple sync for soft deletes
(no `DeletePlaylist` / `DeleteEvent` / unfriend RPC exists to hook). On the read side,
[`todo.md`](./todo.md) §6 has what is left.

Delivery is *eventual* — a `Check` can lag a mutation by the retry backoff.

## Where the code is

| Path | Role |
| --- | --- |
| `authz/model.fga` | the authorization model — the contract |
| `backend/db/schema/00015_openfga_outbox.sql` | the outbox table |
| `backend/internal/authz/` | tuple constructors + the OpenFGA write client |
| `backend/internal/authz/outbox/` | enqueue, inline delivery, worker |
| `backend/internal/authz/outbox/tx.go` | `InTx` — the pattern, so a call site cannot get it wrong |
| `backend/internal/{user,playlist,event,delegation}/repository.go` | the call sites |
| `backend/internal/media/tuples.go` | the image pair (avatar / cover) tuple bookkeeping |
| `backend/internal/authz/check.go` | the read client + the `Permission` constants |
| `backend/internal/interceptor/` | the read half: policy table, authn, authz, id resolution |
