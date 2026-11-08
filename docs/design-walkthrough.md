# Music Room: Design Walkthrough

A short tour of how Music Room is built. Read this first, then open the diagrams.

**Diagrams.** Each `walkthrough-*.html` file in `docs/diagrams/` is an interactive diagram. Open it in a browser. Click a box to see what it does, the file it lives in and a
short piece of real code.

| Diagram | What it shows |
| --- | --- |
| [Overview](diagrams/walkthrough-overview.html) | The whole system on one page |
| [Backend](diagrams/walkthrough-backend.html) | The Go process and its services |
| [Request pipeline](diagrams/walkthrough-request-pipeline.html) | What happens to one RPC before its handler runs |
| [OpenFGA](diagrams/walkthrough-openfga.html) | The permission service: model, checks, sync |
| [Auth and sessions](diagrams/walkthrough-auth.html) | Accounts, logins, session tokens |
| [Realtime](diagrams/walkthrough-realtime.html) | How a change reaches every open screen |
| [Frontend](diagrams/walkthrough-frontend.html) | The Flutter app: startup, data path, live screens |
| [Track Vote](diagrams/walkthrough-track-vote.html) | Live events with a voted queue |
| [Playlist Editor](diagrams/walkthrough-playlist-editor.html) | Collaborative playlists |
| [Control Delegation](diagrams/walkthrough-control-delegation.html) | Letting a friend drive the speaker |
| [Data model](diagrams/walkthrough-data-model.html) | The core Postgres tables (ER diagram) |

---

## 1. What Music Room is

Music Room is a collaborative music app (42 project, spec in `en.subject.pdf`). It has three main features:

- **Track Vote**: a live event where guests suggest songs and vote. The most-voted song plays next.
- **Playlist Editor**: several people edit the same playlist at the same time.
- **Control Delegation**: the host lets a friend control the event's speaker.

Around them: accounts and login (password, Google, 42), friends and blocks, profiles and
avatars, and a Deezer song search.

---

## 2. The system at a glance

[Diagram: Overview](diagrams/walkthrough-overview.html)

| Part | Tech | Port (compose) | Role |
| --- | --- | --- | --- |
| App | Flutter / Dart | — | The client: an Android APK, or the Linux build in a browser on eval machines |
| Backend | Go, gRPC + grpc-gateway | gRPC `50051`, REST `8081` | All business logic, one process |
| Postgres | PostgreSQL | `5432` | **The source of truth** |
| OpenFGA | openfga v1.18.3 + its own Postgres | HTTP `8082` (`5433` for its DB) | The permission graph |
| image-service | Rust, axum | `8080` | Resizes images, stores nothing |
| Deezer | public HTTP API | — | The song catalogue |

The basic flow:
1. The app calls the backend over **native gRPC**.
2. One interceptor checks the session and asks OpenFGA for permission.
3. A domain service reads and writes Postgres.
4. After the write, the service sends a signal so that every open "Watch" stream sends fresh state to its phone.

---

## 3. The contract: `proto/`

`proto/music_room/v1/` is the **single source of truth** for the API. Shared messages live in `dto/`, and
the services in `services/`:

| Service | RPCs | Notes |
| --- | --- | --- |
| AuthService | 11 | register, login, logout, email codes, password reset, OAuth |
| UserService | 16 | profile, music preferences, avatar, friends, blocks, search |
| MusicProviderService | 2 | Deezer get and search |
| PlaylistService | 19 | includes the `WatchPlaylist` stream |
| EventService | 17 | includes the `WatchEvent` stream |
| DelegationService | 6 | devices, licences, event speaker |

`buf generate` (config: root `buf.gen.yaml`) produces, from these files:
- Go structs, gRPC stubs and the REST gateway, in `backend/gen/go`;
- Dart stubs, in `frontend/app/lib/gen`;
- a merged Swagger file, which the backend serves at `/docs/`.

All proto files share one package (`music_room.v1`), so every message lands in one Go and one Dart namespace.

The generated folders are **gitignored**. After a proto or SQL change, run `make generate`, or
`make docker-generate` if the host tools aren't installed. Otherwise the build fails with "undefined" errors.

---

## 4. Backend

[Diagram: Backend](diagrams/walkthrough-backend.html)

### 4.1 Boot

`backend/cmd/main.go` does all the wiring, in this order:
1. Load `.env`.
2. Run the goose migrations.
3. Open the pgx pool.
4. Connect to OpenFGA and pin its model.
5. Build the outbox.
6. Build the auth chain.
7. Start the outbox worker.
8. Build the gRPC server with its interceptors.
9. Register the 6 services.
10. Start the event background loops.
11. Serve HTTP.

If Postgres or OpenFGA is missing, the backend stops at boot.

There are two listeners but only one set of handlers:
- **gRPC** on `:50051`, with reflection on (so `grpcurl` works).
- **HTTP** on `APP_HTTP_ADDR`. This is `:8081` in compose; the code default is `:8080`, which clashes with the image-service when you run both outside compose. The HTTP side serves:
  - the grpc-gateway REST API, which calls back into the gRPC port, so REST gets the same checks;
  - Swagger at `/docs/`;
  - image files at `/media/`;
  - the OAuth callback page.

### 4.2 Request pipeline

[Diagram: Request pipeline](diagrams/walkthrough-request-pipeline.html)

Each call goes through one interceptor (`internal/interceptor/`). These are the steps, in order:

1. **Rate limit.** In-memory token buckets: one per IP (`APP_RATE_LIMIT_RPS`, default 100), and tighter per-user limits on social actions.
2. **Policy lookup.** `policy.go` has one entry per RPC. **An RPC with no entry is denied**, and a test fails the build if any RPC lacks one.
3. **Session check.** The bearer token is hashed and looked up in `user_sessions`.
4. **Caller stamping.** The request's caller field must match the session; the internal user id is then filled in from the session.
5. **OpenFGA Check** for each requirement in the policy. A denied read returns `NotFound`; a denied write returns `PermissionDenied`.
6. **Id resolution.** Each `*_public_id` (UUID) is turned into the internal `int64` id and written into the request. The object that was checked is therefore the object the handler loads.
7. **Handler.** It runs the few checks the graph cannot do, called *residual checks*: venue radius, event ended, playback licence.
8. **Activity log.** One row per call, written in the background.

Clients only ever see **public UUIDs**. Internal `BIGSERIAL` ids never leave the server.

### 4.3 OpenFGA: permissions as a graph

CEL == Common Expression Language (Google's alternative to YML)

[Diagram: OpenFGA](diagrams/walkthrough-openfga.html)

- **The model.** `authz/model.fga` defines 6 types: `user`, `playlist`, `event`, `queue_entry`, `device`, `image`. Roles (owner, admin, editor, viewer) and public flags are stored tuples. Permissions such as `can_view`, `can_edit_songs` and `can_vote` are computed from them.
- **Postgres is the truth, OpenFGA is a copy.** A write that changes access calls `outbox.InTx`. In the *same transaction* it writes the row and the tuple changes it owes into `openfga_tuple_outbox`. After commit, the changes are applied right away. Anything that fails is retried by a worker that runs every 1 s in compose (15 s by default). A failed sync is a delay, never a lost write.
- **Reads.** The interceptor calls `Check`. List pages (all playlists, library, events) call `ListObjects(can_view)`, so the list *is* the permission answer.
- **Cache.** OpenFGA caches checks for 10 s, with a cache controller, so answers can be a few seconds stale. The backend sends `current_time` only to permissions that need it, rounded to the minute, which keeps cache keys stable.
- **Not in the graph:** the venue radius (CEL has no geometry), the event status, and control licences. These are Go or SQL checks.
- **Deployment.** `openfga-init` imports the model into a store with a fixed id. `make fga-model` re-imports it.

Rules in plain language: `docs/annex/permissions.md`. How to add a new mutation: `docs/annex/authz-sync-guide.md`.

### 4.4 Auth and sessions

[Diagram: Auth and sessions](diagrams/walkthrough-auth.html)

- **Opaque session tokens, not JWTs.** Login creates 32 random bytes. The client gets them once, and the server stores only the SHA-256 hash in `user_sessions`. Revoking a session is one `UPDATE`, so there is no refresh token.
- **Expiry.** A session expires 30 days after it is created, or after 7 days without use, and only if the account is active. These limits are enforced in Go. `last_used_at` moves at most once a minute.
- **Passwords** use Argon2id.
- **Login limits.** 5 failures per email or 20 per IP in 15 minutes, counted in `login_attempts`.
- **Email verification and password reset** share one-time 6-digit codes (hashed, valid 15 min, 5 tries). The mailer logs by default; set `APP_MAILER=smtp` to really send.
- **OAuth.** The provider redirects to the backend page `/oauth/callback`, which bounces the code to `musicroom://oauth`. The app then calls `OAuthLogin`, and the server exchanges the code itself.

### 4.5 Database: goose + sqlc

- **Migrations.** `backend/db/schema/` holds 23 migrations, embedded in the binary and applied at every boot. They must stay **flat**: both `//go:embed schema/*.sql` and `goose.Up` ignore subfolders.
- **Queries.** `backend/db/query/*.sql` are written by hand; `sqlc generate` turns them into typed Go in `backend/db/sqlc/`. The comments in the query files explain *why* each query is shaped the way it is.

---

## 5. Realtime

[Diagram: Realtime](diagrams/walkthrough-realtime.html)

Live screens use **gRPC server streams**: `WatchPlaylist` and `WatchEvent`.

1. A write commits, **then** publishes a signal on its topic (`playlist:<id>` or `event:<id>`) in an in-memory
   hub (`internal/realtime/hub.go`).
2. The signal carries **no data**. Each open stream wakes up and re-reads the full state **for its own viewer**,
   so per-viewer fields like `viewer_can_vote` stay correct. A burst of writes becomes one re-read.
3. Each stream also re-checks `can_view` every 5 s, and ends with `NotFound` if access is gone.
4. Background loops also publish:
   - auto-advance timers (next song when one ends);
   - the event ender (every 10 s);
   - the host-presence check (pause playback if the host's phone stops watching for 5 s).

**Limit:** the hub works within one process. Running several backends would need Redis pub/sub.

---

## 6. Frontend (Flutter)

[Diagram: Frontend](diagrams/walkthrough-frontend.html)

### 6.1 Startup and wiring

`frontend/app/lib/main.dart` does this in order:
1. Load the device info and the saved backend address.
2. Open **one gRPC channel** with two interceptors: client metadata, then auth.
3. Build one source per backend service.
4. Restore the session.
5. Start the global stores (session, current user, device).
6. Call `runApp`.

The session is restored before the router exists, so the router's first redirect is already correct.

Everything is passed down with `provider`. Each source is provided under **small interfaces**
(`EventApi`, `LiveEventApi`, ...), so a page and its test fake only see the calls that page uses.

### 6.2 The data path

```
Widget  →  page Store  →  Source (interface)  →  Command  →  generated gRPC client
```

- **Command** (`core/commands/`): one tiny class per RPC. Its `call()` turns `GrpcError` into a typed `AppError`, so no gRPC type leaks above the data layer.
- **Source** (`features/*/data/*_source.dart`): builds requests and maps DTOs to the domain models in `core/models/`, using `core/mapping/`.
- **Store** (`features/*/presentation/stores/`): holds `ValueNotifier<ItemState<T>>` or `ListState<T>`. Widgets rebuild with `ValueListenableBuilder`.
- **Store placement.** The global stores live in `main.dart`. Every other store is **created and disposed by its page**. The one exception is `SongPlayer`, which is app-wide so music keeps playing across tabs.
- **Errors.** The `BusyState` mixin runs one action at a time and shows a feature-specific message for each `AppError` type.

### 6.3 Live screens

`LiveStream` (`core/sources/live_stream.dart`) keeps one Watch stream open while a page is visible:
- it reconnects after 1, 2, 5, then 10 s;
- a `NotFound` stops it (the object was deleted or made private).

A button press shows the RPC's own reply immediately, and the next push agrees with it.

### 6.4 Client auth

- **The token.** `SessionCredentials` holds it in memory; `flutter_secure_storage` keeps it on disk.
- **The interceptor.** `AuthInterceptor` adds `authorization: Bearer` to every call except the anonymous auth calls. On `UNAUTHENTICATED` the session ends.
- **Navigation.** `SessionStore` drives the router through `authRedirect`: signed out goes to `/login`, an unverified email goes to `/verify-email`.

### 6.5 Present but not wired

These pieces exist in the code, but nothing uses them yet:
- The `DomainSource` and `Repository` base classes, and most of `features/music/song/`. The only real repository is `SessionRepository`.
- The web/REST path: `HttpService`, `HttpSource`, and the conditional export in `core/network/network.dart`. The app is native gRPC only.

---

## 7. The three services

### 7.1 Track Vote

[Diagram: Track Vote](diagrams/walkthrough-track-vote.html)

- **Who can vote.** The event's vote licence is `everyone`, `invited_only` or `location_time`. In OpenFGA it becomes exactly one of `open_vote`, `invited_vote` or `window_vote`. Suggesting a song uses the same permission as voting.
- **`location_time`.** OpenFGA checks the daily time window, using a CEL condition. Go then checks the venue radius and that the event has not ended.
- **A vote is one SQL statement** (`CastQueueVote`). It locks the entry while it is still queued, inserts the vote with `ON CONFLICT DO NOTHING` (one vote per person), and adds 1 to `vote_count`. There is no retry loop.
- **Queue order.** There is no position column: the queue is sorted by `vote_count DESC, score_reached_at`, so a tie goes to whichever song reached that count first.
- **Playback.**
  - `playNext` locks the playback row, starts the top entry, and sets the event to `live` on the first play.
  - A server timer plays the next song when one ends.
  - Only the host, or a delegated friend, may control playback.
- **Realtime.** Each change wakes `WatchEvent`. The app plays the sound only on the speaker phone.

### 7.2 Playlist Editor

[Diagram: Playlist Editor](diagrams/walkthrough-playlist-editor.html)

- **Who can edit.** The edit rule is `owner or admin or editor or (can_view and open_edit)`. A private playlist is never writable by strangers, even with licence `everyone`.
- **Every song edit is one transaction, in a fixed order:**
  1. `BumpPlaylistRevision` takes the playlist row lock and returns the new revision.
  2. The change itself.
  3. `AppendPlaylistOp` writes the op at that revision.

  The lock makes concurrent editors wait their turn. Revisions are therefore gapless, and two people adding the same song cannot both pass the duplicate check.
- **Moving a song.** Positions are `NUMERIC`, so a moved song lands halfway between its neighbours and nothing is ever renumbered.
- **Settings.** Visibility, licence and member changes also change OpenFGA tuples, so they go through the outbox.
- **On the app.** The editor drops any pushed state older than the revision it already shows.

### 7.3 Control Delegation

[Diagram: Control Delegation](diagrams/walkthrough-control-delegation.html)

- **Devices.** Each phone registers itself as a device on every session, and its session is attached to it. The host's phone becomes the event's **speaker** the first time the host plays.
- **Granting.** The owner of the speaker device can give a **friend** a licence for **one event**. A licence means control of the whole player: play, pause, seek, skip.
- **Licences are SQL rows** (`device_control_licenses`), not OpenFGA tuples. `canControlPlayback` allows the host always; anyone else needs a live licence for this event on the speaker device.
- **Revoking.**
  - Revoking sets `revoked_at` and keeps the row, as an audit trail.
  - Unfriending or blocking revokes every grant between the two users.
  - Moving the speaker to another device moves its licences with it.
- **Realtime.** Every licence change wakes `WatchEvent`, so the friend's controls appear or disappear at once.

---

## 8. Data model

[Diagram: Data model](diagrams/walkthrough-data-model.html)

There are 28 tables, grouped by domain. `docs/annex/data-model.md` is the full reference: read it before you
change any SQL.

| Domain | Main tables |
| --- | --- |
| Identity | `users`, `user_sessions`, `devices`, `user_oauth_accounts`, `user_tokens`, `login_attempts` |
| Profile / media | `user_profiles`, `user_music_preferences`, `images` |
| Social | `friend_requests`, `friendships`, `user_blocks` |
| Catalogue | `songs` (a cache of Deezer tracks) |
| Playlists | `playlists`, `playlist_members`, `playlist_invitations`, `playlist_songs`, `playlist_ops` |
| Events | `events`, `event_members`, `event_invitations`, `event_queue_entries`, `event_queue_votes`, `event_playback_states`, `event_ops` |
| Delegation | `device_control_licenses` |
| Audit / sync | `activity_logs` (partitioned by month), `openfga_tuple_outbox` |

Conventions:
- **Ids.** A `BIGSERIAL id` is used for joins; a `public_id UUID` is the only id that leaves the server.
- **Soft delete.** Playlists and events set `deleted_at`, and reads filter on it.
- **Friendships.** Stored once per pair, with the smaller id first (`CHECK (user_a_id < user_b_id)`).

---

## 9. Running and testing

Everything goes through the root `Makefile` (`make help`).

| Goal | Command |
| --- | --- |
| Full stack in Docker | `make all` |
| Eval: stack + demo data + phone | `make eval` |
| The "phone" in a browser | `make phone` (`:6080`), `make phone-2` (`:6081`) |
| Android APK for a real phone | `make apk` |
| Regenerate code | `make generate`, or `make docker-generate` without host tools |
| Go tests | `make backend-test` |
| API tests (pytest, black-box REST) | `make docker-api-test` |
| Load test (k6) | `make loadtest SCENARIO=mixed LT_PROFILE=small` |

- **The eval "phone".** Eval machines have no `/dev/kvm`, so no Android emulator can run. The "phone" is the Flutter **Linux** build running on Xvfb and shown in the browser through noVNC (`frontend/phone/`). It takes the same native gRPC path as Android. Sound and GPS are bridged in by small helpers.
- **API tests.** The suite in `tests/` is split by feature (`auth/`, `user/`, `playlist_editor/`, `track_vote/`, `control_delegation/`).
- **Load tests.** After a run, `loadtest/verify/verify.py` checks that the database stayed consistent: gapless revisions, vote counts equal to vote rows, and at most one live licence. Details in `docs/annex/load-testing.md`.

---

## 10. Known gaps and stale docs

These were checked against the code on 2026-10-25:

- **Redis** is commented in the backend and the compose. The realtime hub and the rate limits run in memory.
- **`event_ops`** exists as a table, but nothing writes to it.
- **`ListPlaylistOpsSince`** works on the server, but the app never calls it. On reconnect, the app re-reads the whole playlist.
- **Web/REST client** (§6.5) is not wired.

---

## 11. Further reading

| File | About |
| --- | --- |
| [`tech-choices.md`](tech-choices.md) | Why each tool was chosen, with pros, cons and alternatives |
| [`who-did-what.md`](who-did-what.md) | Who built which part, from the git history |
| `docs/annex/data-model.md` | Every table, the concurrency rules (§13), the OpenFGA mapping (§14) |
| `docs/annex/permissions.md` | The permission rules in plain language, plus the residual Go checks |
| `docs/annex/authz-enforcement.md` | The read side: interceptor and policies |
| `docs/annex/authz-sync-guide.md` / `docs/annex/authz-sync-summary.md` | The write side: keeping OpenFGA in sync |
| `docs/annex/auth-client.md` | How the app holds a session; OAuth setup |
| `docs/annex/load-testing.md` | Load test method and results |
| `docs/annex/todo.md` | What is left against the subject |
| `docs/annex/project-state.md` | Older snapshot of the project state |
