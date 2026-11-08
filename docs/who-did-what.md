# Who did what

A map of the project's work and the people who did it.

**How this was made.** This page is built from `git log --all` on 2026-10-25 (HEAD `04a7608`):
382 commits plus 34 merge commits, from 2026-08-03 to 2026-10-25. Keep in mind:

- A commit count measures activity, not effort. One commit can be a whole feature or a one-line fix.
- Pair work, reviews and talks don't show up in git.
- GitHub merge commits are not credited to anyone here.
- When several people are listed, the first one did most of that work.

## People

| Person | Git names (GitHub) | Main focus |
| --- | --- | --- |
| Gregory Borne | Greg, Gregory, Gregory Borne (`Echo24h`)  | Backend services, API tests, most of the later app features |
| Cedric Muller | XVI (`aceyzz`) | Authentication, then security hardening |
| Tom Weimer | Tom, Tom Weimer (`TomWeimer`) | Frontend foundations and the UI component system |
| Maxime Turgeon | Maxkirit, Maxime Turgeon | Data model, permissions (OpenFGA), eval and load tooling, app auth and pages |


## Work by area

### Foundations

| Area | Who | What |
| --- | --- | --- |
| Project setup | Gregory, Tom | Gregory created the `Makefile`, base Go server and image service. Tom pushed the first prototype (08-04). |
| Proto contract | Tom, Gregory, Cedric, Maxime | Tom merged the protos into one versioned source of truth (08-12). Gregory wrote the Playlist, Event, User and Delegation services. Cedric wrote the Auth contracts. |
| Data model, SQL schema, sqlc queries | Maxime, Gregory | Maxime wrote `docs/annex/data-model.md`, the goose schema (with a concurrency test) and the queries for 25 use cases. Gregory extended them while building the services. |
| Code generation in Docker | Gregory, Tom | gRPC and sqlc code generated inside the backend image. |

### Backend

| Area | Who | What |
| --- | --- | --- |
| Authentication | Cedric | Register, login and logout; Argon2id hashing; opaque session tokens and the authenticator; mailer (log and SMTP); email verification codes; OAuth with Google and 42 (a Facebook provider too, written but not shown in the app: no Meta app could be registered); password reset; linking and unlinking OAuth accounts; rate limits on codes and logins. |
| Permissions (OpenFGA) | Maxime, Gregory | Maxime: the authz model, the OpenFGA compose services, the outbox pattern, permission enforcement in the interceptor, and the performance fixes (model id, cache, CPU shares). |
| Interceptor (Logging) | Gregory | activity logging, lists through ListObjects, permission model changes, and the per-IP and per-user rate limits. |
| Playlist Editor service | Gregory | First endpoints, then nearly every RPC: rename, move, delete, transfer, edit licence, list, ops log, covers, public search. |
| Track Vote (Event service) | Gregory | Votes and queue, playback, lifecycle, auto-advance timers, place-and-time voting, auto-end, pausing when the host leaves. |
| Control Delegation | Maxime, Gregory | Maxime built the MVP (10-19). Gregory added choosing the speaker device, one licence per event, and one licence for the whole player. |
| User and social | Gregory, Cedric, Maxime | Gregory: UserService, friends, blocking, avatars through the Rust image service, music preferences. Cedric and Maxime: auth-related and profile changes, social profiles linking. |
| Deezer and song cache | Gregory | Deezer client, `music_provider`, `songs`. |
| Realtime | Gregory | Live updates over gRPC Watch streams for playlists and events; removed the unused WebSocket path. |
| Device tracking | Maxime | Device metadata logging; device id tied to the session. |

### Frontend (Flutter)

| Area | Who | What |
| --- | --- | --- |
| App foundations | Tom | Command-based backend calls, theme and adaptive layout, cross-platform keychain storage (iOS, macOS, Android). |
| Auth client and first pages | Maxime | Session and auth interceptor; login, register and forgot-password pages; OAuth (42, Google) with the desktop webview; profile; social and user search; playlist and event tabs; voting; song suggestions; playlist management. |
| Later features | Gregory | Player and mini player, event and playlist screens, settings pages, venue map, live reloads, delegation screens, setting the backend address in the app. |
| UI component system | Tom | Refactor around `AppDimens`/`AppTheme` and shared widgets (`TrackTile`, `UserTile`, `ActionButton`, `AsyncListView`, ...), 10-17 to 10-19. |

### Testing, tooling and running the app

| Area | Who | What |
| --- | --- | --- |
| pytest API suite (`tests/`) | Gregory | one folder per service, interceptor and race tests. |
| Load testing (`loadtest/`, k6) | Maxime, Gregory, Cedric | Maxime built the setup and wrote up the results (`docs/annex/load-testing.md`). Gregory and Cedric made small changes. |
| Seed script | Maxime, Gregory | Maxime wrote the first version. Gregory moved it into the backend image and added load-test circles. |
| Docker eval and the browser "phone" | Maxime, Gregory | Maxime: one-command Docker launch, and an eval setup that needs no `/dev/kvm` (the phone runs in the browser). Gregory: phone fixes, make targets, the Android emulator and APK flow, and builds that fit a small disk. |
| Security hardening | Cedric | Database passwords read from `.env`, internal ports bound to localhost, no directory listing under `/media/`. |
| API docs and Swagger | Gregory, Maxime | Gregory serves Swagger from the backend and rewrote the API docs. Maxime updated them earlier. |

### Documentation

| Area | Who | What |
| --- | --- | --- |
| Design docs | Maxime | `data-model.md`, `permissions.md`, the authz guides, `auth-client.md`, `load-testing.md`, `project-state.md`, and this folder (walkthrough and diagrams). |
| Tracking and setup docs | Gregory | `todo.md`, README and installation guide. |

## Timeline

| Period | Main work |
| --- | --- |
| August | Setup and prototype (Gregory, Tom); schema, queries and the OpenFGA design (Maxime); auth backend and OAuth (Cedric); proto merge (Tom); first Playlist and Deezer code (Gregory) |
| September | Event, User, Delegation and Playlist services, plus the pytest suite (Gregory); permission enforcement (Maxime); password reset, linking and rate limits (Cedric); frontend auth client (Maxime) |
| October | App pages (Maxime, then Gregory); load tests and the browser phone (Maxime); realtime streams and the player (Gregory); UI component system; delegation (Maxime, Gregory); security hardening (Cedric) |
