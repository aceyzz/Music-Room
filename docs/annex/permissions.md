# Music Room — Permissions

Companion to `authz/model.fga`. That file is the machine-readable model; this one is the
rules in plain language, grouped by use case, with the part of each rule that OpenFGA
**cannot** answer stated next to it.

Who enforces these: `backend/internal/interceptor`, before the handler runs, one entry per
RPC. How that works and how to add an RPC to it: [`authz-enforcement.md`](./authz-enforcement.md).
Which rules below are still decided in Go rather than by the graph: the table at the end of
that file, and `grep -rn PLACEHOLDER backend/internal`.

Every rule below reads:

> A user **{user}** can **{action}** on **{object}** **IF** {conditions}.


---

## How to read the tables

Each category ends with a table:

| Column | Means |
| --- | --- |
| **Relation** | The `Check(user, relation, object)` the handler calls. |
| **Source of truth** | The Postgres table/column the tuple is derived from (`docs/annex/data-model.md`). |
| **Still checked in Go** | What must *also* be true. `Check()` returning `true` is necessary, never sufficient, wherever this column is non-empty. |

That last column is the whole reason this document exists. A model file read on its own
makes authorization look finished; it is not, and the gaps are deliberate rather than
forgotten.

---

## 0. Rules that apply everywhere

These are true of every rule below and are not repeated.

- **Authentication first.** Every `Check()` presumes a resolved `user:<id>` from a valid
  `user_sessions` row whose owner is `status = 'active'` (§5). An expired or revoked session
  is a 401 before authorization is consulted at all. **Enforced** since the interceptor
  landed, idle timeout included: `authn` rejects a session unused for longer than
  `APP_SESSION_IDLE_DAYS`. The Watch streams go through the same interceptor.
- **Soft-deleted resources are invisible.** `playlists.deleted_at` / `events.deleted_at`
  being non-NULL is a 404, checked in the same query that loads the row. It is not a tuple —
  see `authz/model.fga`, "What is deliberately NOT here".
- **Every action is logged.** V.6 requires an `activity_logs` row for any action, including
  the denied ones. A denial is `result_code = 7` (PERMISSION_DENIED). **Built**, inside the
  permission interceptor itself (`Interceptor.Unary`, `internal/interceptor/activitylog.go`)
  rather than as a second chained interceptor: a denial from `authorize` never reaches a
  handler positioned after it in a chain, so nothing outside `Unary` ever sees it to log it.
  Fire-and-forget (its own goroutine, its own timeout) so a slow or failed write never
  affects the request it describes. See [`authz-enforcement.md`](./authz-enforcement.md)
  §Activity logging.
- **Blocks cut both ways.** One `user_blocks` row produces two tuples. See §5.

---

## 1. Account and sessions

> A user can **change their email, change their password, view their active sessions, revoke
> a session, or delete their account** on **their own user** **IF** they are that user.
> There is no other condition and no other actor — there is no platform admin role in this
> model.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `user#can_manage_account` | `users`, `account_owner` tuple | Password change requires the current password; email change requires re-verification (`user_tokens`, purpose `email_verification`). |
| `user#can_manage_sessions` | `user_sessions.user_id` | The session being revoked must belong to the caller — a row check, since sessions are not FGA objects. |

**Why sessions are not an FGA object type.** "Is this session mine?" is
`WHERE user_id = $me` on a row the handler has already loaded. Making it a tuple would add a
write to the login path — the hottest write in the system — to answer a question Postgres
answers for free.

---

## 2. Profile information

Seven fields, each with its own `public` / `friends` / `private` setting (§6).

> A user can **view a given profile field** of **another user** **IF** they are that user,
> **or** the field is set to public, **or** the field is set to friends-only and the two are
> friends — **and** neither has blocked the other.

> A user can **edit any field of a profile, and change any field's visibility setting**, on
> **their own user** **IF** they are that user.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `user#can_view_profile` | account existence | Base card: `display_name` + avatar. Always visible unless blocked. |
| `user#can_edit_profile` | `account_owner` tuple | — |

**The seven fields are redacted in Go, not in the graph.** First name, last name, bio, birth
date, location (city + country code, one setting), phone and music preferences each have a
`user_profiles.*_visibility` column: public, friends or private. `GetUser` reads the row and
the `friendships` row, and empties each field the viewer may not see
(`internal/user/access.go`). It is a redaction, not an access check: `can_view_profile`
decides whether the profile is returned at all, blocks included; this decides what it
contains, from data the handler has already read.

---

## 3. Profile picture

> **Anyone** can **view** a **user's profile picture**. There is no condition.

> A user can **upload or replace their profile picture** on **their own user** **IF** they
> are that user.

> A user can **delete an image** **IF** they uploaded it.

Product decision, taken deliberately: there is no `avatar_visibility` column in §6 and none
is wanted. Avatars are public.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `image#can_view` (via `public`) | `user_profiles.avatar_image_id` | — |
| `user#can_edit_profile` | `account_owner` tuple | Upload goes through the Rust `image-service`; size/type/rate limits are enforced there and are not authorization. |
| `image#can_delete` | `images.owner_user_id` | Deleting an original must cascade its `source_image_id` variants — a repository concern, not a `Check()`. |

Derived variants (`thumb`, `medium`) inherit the original's visibility through the `original`
relation, so a permission decided once at upload covers every size.

---

## 4. Music preferences

> A user can **view another user's music preferences** **IF** they are that user, **or** the
> preferences are public, **or** they are friends and preferences are friends-only — **and**
> neither has blocked the other.

> A user can **add, remove or re-weight a genre preference** on **their own user** **IF**
> they are that user.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `user#can_view_preferences` | `user_profiles.preferences_visibility` | — |
| `user#can_manage_preferences` | `account_owner` tuple | `weight` must be 1..5 — validation, not authorization. |

Taste matching ("collaborate with people with the same musical tastes", V.2.3) reads other
users' preferences and must therefore filter by `can_view_preferences`, or it becomes a
side channel that leaks private preferences through a recommendation list. This is the
non-obvious one in this category.

---

## 5. Friends and blocks

> A user can **send a friend request** to **another user** **IF** neither has blocked the
> other.

> A user can **accept or decline a friend request** **IF** they are its addressee.
> A user can **cancel a friend request** **IF** they are its requester.

> A user can **block or unblock** **another user** unconditionally.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `user#can_send_friend_request` | `user_blocks` (both directions) | Not already friends; no open pending request either way — the partial unique index in §7 enforces it, the handler should report it. |
| — | `friend_requests.addressee_id` / `requester_id` | Row ownership. Not an FGA object: a request has exactly two parties, both named on the row. |
| — | `user_blocks` | Blocking is always allowed; the interesting work is the cascade below. |

**Blocking is directional in Postgres and bidirectional in FGA, on purpose.** `user_blocks`
records who blocked whom (§7, and it needs to, for appeals and for un-blocking). But a block
that hides A from B while leaving B visible to A is a mute, not a harassment control. One row
therefore writes two `blocked` tuples, and `but not blocked` subtracts from profile viewing,
friend requests and invitations in both directions.

**Blocking has a cascade the model cannot perform.** Creating a block must, in the same unit
of work: delete any `friendships` row for the pair, cancel open `friend_requests`, revoke
`device_control_licenses` between them (delegation is friends-only — §14), and delete the
corresponding tuples. FGA's exclusion stops *future* access; it does not clean up standing
grants. Done in `Block` (`user/repository.go`), in one outbox transaction. Licences have no
tuple (§14), so revoking them is a plain SQL update there.

---

## 6. Song catalog

> **Any authenticated user** can **search the catalog, read song details, and read a song's
> preview URL**. There is no condition.

No `song` type exists in the model. The Deezer cache (§8) carries no per-user access
distinction, so a type would mean one tuple per cached song to express "everyone".

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| — | `songs` | Authentication only. Rate limiting on the Deezer read-through path is a separate concern. |

---

## 7. Playlists — finding and reading

> A user can **view a playlist, its songs and its member list** **IF** the playlist is
> public, **or** they are its owner, admin, editor or viewer.

> A user can **subscribe to a playlist's live edit stream and replay its operation journal**
> **IF** they can view the playlist.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `playlist#can_view` | `playlists.visibility`, `playlist_members` | `deleted_at IS NULL`. |

**The stream is where this gets missed.** `ListPlaylistOpsSince` runs the same `can_view`
check as the snapshot read. `WatchPlaylist` runs it when the stream opens (interceptor), then
again before every send and on a timer (`accessRecheck`): a subscriber who was allowed in
while the playlist was public gets `NotFound` and the stream ends once it goes private.

---

## 8. Playlists — editing songs

> A user can **add a song to, remove a song from, or move a song within** a **playlist**
> **IF** they are its owner, admin or editor, **or** the playlist's edit license is
> "everyone" and they can view the playlist.

One permission covers all three operations. §9.1 defines a single write access, and
"may add but may not remove" is a distinction nobody has asked for.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `playlist#can_edit_songs` | `playlist_members.role`, `playlists.edit_license` | `deleted_at IS NULL`; the three-step revision transaction (§9.2) — `BumpPlaylistRevision` → change → `AppendPlaylistOp`, in that order. |

**`can_view and open_edit`, not bare `open_edit`.** The two columns are independent: a
*private* playlist with `edit_license = 'everyone'` is editable by its members and nobody
else. Collapsing them would silently make every private playlist world-writable, which is
the worst available failure mode and is why the intersection is spelled out in the model file
too.

---

## 9. Playlists — settings, membership, lifecycle

> A user can **rename a playlist, set its cover, change its visibility, or change its edit
> license** **IF** they are its owner or admin.

> A user can **invite another user to a playlist** **IF** they are its owner, admin or
> editor — **and** neither they nor the invitee has blocked the other.

> A user can **accept or decline a playlist invitation** **IF** they are its invitee.

> A user can **change another member's role, or remove a member** **IF** they are the
> playlist's owner or admin.

> A user can **delete a playlist, or transfer its ownership** **IF** they are its owner.

Editors can invite. That was an explicit decision: the Playlist Editor is a collaborative
tool and requiring an admin round-trip to add a collaborator defeats it.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `playlist#can_rename`, `#can_set_cover`, `#can_change_visibility`, `#can_change_license` | `playlist_members.role` | A rename, visibility or licence change writes a `playlist_ops` row (`rename`, `visibility_change`, `license_change`); a cover change writes none. A visibility change must also rewrite the `public` tuple. |
| `playlist#can_invite` + `user#can_receive_invitation` | `playlist_members.role`, `user_blocks` | **Two checks, on two objects** — one on the playlist, one on the invitee. No pending invitation already open (partial unique index, §9.1). Invitees need not be friends: that is the point (§9.1). |
| — | `playlist_invitations.invitee_user_id` | Row ownership; plus `status = 'pending'` and `expires_at` not passed. |
| `playlist#can_manage_members` | `playlist_members.role` | An admin may not demote or remove the owner. Rank comparison is Go's job — FGA answers "may you manage members", not "may you outrank this one". |
| `playlist#can_delete`, `#can_transfer_ownership` | `playlists.owner_id` | Transfer rewrites both `owner` tuples and both `playlist_members` rows atomically. |

---

## 10. Events — finding and reading

> A user can **find and view an event, its queue and its member list** **IF** the event is
> public, **or** they are its host, admin, editor or viewer.

Private means invited-only can *find* it as well as vote in it (§10) — discovery and read are
the same permission, so a private event must never appear in a search result or a listing.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `event#can_view` | `events.visibility`, `event_members` | `deleted_at IS NULL`. Listings must use `ListObjects(user, can_view, event)` — filtering a full `SELECT` in Go is how private events leak into search. |
| `queue_entry#can_view` | inherited from parent event | — |

---

## 11. Events — suggesting and voting

The three vote licenses (§10.3) are mutually exclusive and each gets its own rule.

> A user can **vote for, or suggest, a track in an event** whose license is **"everyone"**
> **IF** they can view the event.

> A user can **vote for, or suggest, a track in an event** whose license is
> **"invited only"** **IF** they are a member of the event.

> A user can **vote for, or suggest, a track in an event** whose license is
> **"location and time"** **IF** they can view the event, **and** the current time at the
> venue falls inside the daily vote window, **and** they are physically inside the venue
> radius.

The window is a CEL condition on the tuple (`within_vote_window`), evaluated against the
request time and the venue's IANA zone. **The radius is not** — CEL has no geospatial
functions, so the distance test stays in the Go handler and runs after `Check()` passes.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `event#can_vote` / `#can_suggest_song` | `events.vote_license`, `event_members` | `events.status <> 'ended'` (scheduled or live); entry `status = 'queued'`. |
| `event#can_vote_window` (condition) | `vote_window_start/_end/_timezone` | **Venue radius**: distance from `(venue_latitude, venue_longitude)` ≤ `venue_radius_meters`, using coordinates the client sends with the vote and which are persisted on `event_queue_votes` as the audit trail. |
| — | `event_queue_votes` unique `(queue_entry_id, user_id)` | One vote per user per entry, `ON CONFLICT DO NOTHING`. Votes are final; there is no unvote (§10.2). |

**Under `location_time`, the host cannot vote from home.** `can_vote_window` does not fall
back to membership. That is the strict reading of §10.3 and it is intentional — a location
license the organisers can ignore is not a location license. It is also the rule most likely
to surprise someone during the demo, which is why it is stated twice (here and in the model
file).

**Suggesting is gated by the same license as voting.** The subject phrases them as one
capability. If suggesting should ever be more open than voting, `can_suggest_song` is already
its own relation and only its definition changes.

---

## 12. Events — playback and queue management

> A user can **play, pause, skip or seek in an event** **IF** they are its host — **or** they
> hold a live control licence for this event on the event's speaker device.

> A user can **remove a track from the queue** **IF** they suggested it, **or** they are the
> event's host or admin.

The delegated path is a licence on the event's speaker device, read in SQL. Details in §14.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `event#can_control_playback` (host or admin) | `event_members.role` | **Not consulted by the playback RPCs**: `canControlPlayback` compares `events.host_id` itself, then looks for a licence. No API makes an event member `admin` (invites add `viewer`), so the two agree today. The event must not be `ended`; the host's first play takes it from `scheduled` to `live`. |
| `queue_entry#can_remove` | `event_queue_entries.suggested_by_id` | Entry `status = 'queued'` — you cannot un-suggest a song that is already playing. |

**Two routes, one action.** "Can this user drive the player?" is: they host the event, **or**
they hold a live licence for this event on its speaker device
(`event_playback_states.speaker_device_id`, set by the host's first play or by
`SetEventSpeaker`). One licence drives the whole player: play / pause, next, seek. Both
routes are checked in `event/access.go:canControlPlayback`, outside OpenFGA: a licence is per
(device, event), and a friend may hold one per event on the same device, while an OpenFGA
tuple is unique per (friend, device). So licences are not in the graph at all.

---

## 13. Events — settings, membership, lifecycle

> A user can **rename an event, change its visibility, change its vote license, or set its
> venue and vote window** **IF** they are its host or admin.

> A user can **start, pause, resume or end an event** **IF** they are its host or admin.

> A user can **invite another user to an event** **IF** they are its host, admin or editor —
> **and** neither they nor the invitee has blocked the other.

> A user can **accept or decline an event invitation** **IF** they are its invitee.

> A user can **change a member's role or remove a member** **IF** they are its host or admin.

> A user can **delete an event, or transfer hosting** **IF** they are its host.

| Relation | Source of truth | Still checked in Go |
| --- | --- | --- |
| `event#can_change_settings` | `event_members.role` | A change to `vote_license` rewrites the license flag tuples — **delete the other two**, since exactly one must exist. A change to `location_time` requires the venue/window columns to be present (the `CHECK` in §10.3). |
| `event#can_change_status` | `event_members.role` | Legal transitions only: `scheduled → live → ended`, and `ended` is terminal. The host's first play makes an event live; EndEvent ends it. Pausing is the music's (`SetEventPlayback`): the event stays live. State machines are not relationships. |
| `event#can_invite` + `user#can_receive_invitation` | `event_members.role`, `user_blocks` | Two checks, two objects. Invitees need not be friends. |
| `event#can_manage_members` | `event_members.role` | Cannot demote or remove the host. |
| `event#can_delete`, `#can_transfer_ownership` | `events.host_id` | — |

**Seeding an event from a playlist** (`events.source_playlist_id`) requires
`Check(user, can_view, playlist:X)` at creation time. It is a read of the playlist, and
skipping it would let anyone copy a private playlist's contents into a public event — a full
disclosure through a feature that does not look like a read.

---

## 14. Devices and control delegation

> A user can **register, rename, view or deactivate a device** **IF** it is attached to their
> account.

> A user can **grant control of a device to another user, for one event** **IF** they own the
> device **and** the grantee is their friend.

> A user can **revoke a control licence** **IF** they own the device.

> A user can **drive an event's player through a device** (play / pause, next, seek) **IF** they
> hold a live licence for **that event** on **that device**, **and** the device is the event's
> speaker.

A licence is one permission, not a set of capabilities: whoever holds it drives the whole
player (migration `00023` dropped the per-action columns, which nothing ever offered or read).
It is always for one event (migration `00021`): there is no standing "control my speaker
forever" grant, and a database constraint keeps one from being written.

The licence hangs off the **device**, not the user (data-model §11): granting a friend control of
the living-room tablet says nothing about the phone. When the host moves the event to another of
their devices (`SetEventSpeaker`), the event's live licences move with it, so a friend who drove
the old speaker drives the new one.

| Relation | Source of truth | Still checked in Go / SQL |
| --- | --- | --- |
| `device#can_view` / `can_rename` / `can_delete` (via `owner`) | `devices.user_id` | — |
| `device#can_grant_control` | `devices.user_id` | **Friendship**: a `friendships` row must exist between grantor and grantee. A write-time precondition, so it is not in the model. The event is required too. |
| `device#can_revoke_control` | `devices.user_id` | The licence must belong to this device (scoped by the query). Revocation sets `revoked_at`; the lookup ignores revoked rows, so it lands on the grantee's next request. |
| *(using a licence)* | `device_control_licenses` | **Not in OpenFGA at all.** `canControlPlayback` reads the row (`ResolveDeviceControlLicense`): same device, same grantee, same event, `revoked_at IS NULL`. |

**How a grant ends.** Every way is an explicit `revoked_at`, never a delete, so the history of
who could drive what stays readable:

- the owner revokes it (`RevokeDeviceControl`);
- **unfriending or blocking** revokes every live grant between the two users, in both
  directions (`RevokeDeviceGrantsBetween`, inside the `RemoveFriend` and `BlockUser` transactions, `user/repository.go`). This is
  needed because friendship is only checked when the grant is written: without it, an
  ex-friend would keep driving the speaker.

An ended event makes its licences useless without touching them: playback on an `ended` event
is refused before any licence is read. `device_control_licenses.expires_at` still exists and the
lookup honours it, but no RPC sets it.

Licence tuples that older versions wrote are still in the OpenFGA store, under relations the
model no longer has, so nothing can reach them; `make seed-reset` clears them.

---

## 15. Activity logs

> A user can **read their own activity log** **IF** they are its subject.

No FGA type. `activity_logs.user_id = $me` is the whole rule, and the table is partitioned
and write-heavy (§12) — adding a tuple per log row is not a trade anyone should make.

There is no admin-facing log reader, because there is no platform admin role in this model.

---

## 16. Not in the model, and why

Collected so nobody has to reconstruct the reasoning from an absence.

| Thing | Where it lives instead | Why |
| --- | --- | --- |
| Venue radius (`location_time`) | Go handler, after `Check()` | CEL has no geospatial functions. The time half of the same license *is* a condition. |
| `events.status`, `queue_entry.status`, `deleted_at` | The query that loads the row | Changes on every pause/skip. Tuples would mean a write per playback event. |
| Control licences | `device_control_licenses`, read in SQL | Per (device, event), which a tuple per (friend, device) cannot hold. |
| Delegation's friends-only rule | Write-time precondition | It gates the creation of the grant, not the use of it. Consequence: unfriending and blocking revoke the licences between the two. |
| Friend requests, friendships, sessions, logs | Row ownership (`WHERE user_id = $me`) | Two named parties on the row. FGA is for questions with a graph in them. |
| Songs | Nothing | No per-user distinction exists. |
| Platform admin / moderator | Nothing | Decided: per-resource roles only. `session_revoked_reason = 'admin'` is an ops action over SQL, not an in-app role. |
| Rate limits, upload size, password strength | Validation layer | Not authorization, and conflating them makes both harder to reason about. |

---

## 17. Open questions

0. ~~**Who reads the graph?**~~ **Answered.** `backend/internal/interceptor`, per RPC,
   before the handler, from a policy table that denies anything it does not list.
   `playlist/access.go` and `event/access.go` no longer decide visibility or vote
   licences -- those functions are gone rather than kept as a second opinion, because two
   permission systems answering the same question eventually disagree and the permissive
   one wins. What is left in Go is listed in [`authz-enforcement.md`](./authz-enforcement.md);
   the code for each missing piece is in [`todo.md`](./todo.md) §4 and §6.

   One thing the split turned up that is worth stating here: the Go checks were *narrower*
   than the model. They knew "owner or member", so a playlist admin could not set a cover
   and an event admin could not change a vote licence, though the model has said they can
   since the first draft. Deleting them widened those two permissions to what this document
   already specified.

1. ~~**Who writes the tuples, and when does the gap close?**~~ **Answered.** The `*_ops`
   journals were never a real retry source — they only cover playlists and events, leaving
   `user_blocks`, `friendships`, `user_profiles.*_visibility` and `device_control_licenses`
   with no way to detect a failed tuple write short of a full sweep. Replaced by a
   transactional outbox: `openfga_tuple_outbox` (migration 15), one row per logical change,
   inserted *inside* the domain transaction, drained by `backend/internal/authz/outbox` —
   inline after commit, then a worker every 15s. It covers every table uniformly because it
   is keyed on the change, not on the domain.

   Two properties worth knowing before relying on it. Delivery is **eventual**: a `Check`
   can lag a mutation by the retry backoff, and `CountPendingTupleChanges` is the honest
   measure of by how much. And the periodic full sweep in `notes20260816.md` is still not
   built — the outbox catches everything it knows it owes, so the remaining gap is a tuple
   written *correctly* that later drifts for a reason outside this path.
2. **Does a visibility change need to fan out to live subscribers?** §7 above. Making a
   playlist private should disconnect subscribers who lost `can_view`. Done by polling: each
   Watch handler re-checks `can_view` every 5 s and closes the stream on a denial. A push on
   revocation would be instant, but is not built.
3. **Stream authorization.** Settled for now: the `/ws` WebSocket endpoint was removed, and
   the gRPC Watch streams are authorized by the interceptor at open and re-check `can_view`
   every 5 s. A revocation can therefore take up to that long (plus the check cache) to close
   a live stream.
4. **Does an editor's invite need to be rate-limited?** Editors can invite (§9), and an
   editor who invites 500 people is a spam vector the partial unique index does not stop
   (it only prevents duplicate *pending* invites to the same person).
5. **Contextual tuples for the `location_time` geo check?** If we ever want FGA to be the
   single answer, Go could precompute `within_venue: bool` and pass it as a context
   parameter. It would move the boundary without moving the actual computation, which is why
   it was not done now — but it makes `ListObjects` for "events I can vote in right now"
   possible, which the current split does not.
