# The auth client — how the Flutter app holds a session

The client half of authentication. Companion to
the Swagger at `http://localhost:8081/docs/` (the RPCs themselves) and
[`authz-enforcement.md`](authz-enforcement.md) (what the server does with the
token once it arrives).

Code: `frontend/app/lib/core/network/auth/`, `frontend/app/lib/features/auth/`,
`frontend/app/lib/globals/app_router.dart`.

---

## Three copies of one token

The session exists in three places, and keeping them in step is most of what
this slice does:

| Copy | Where | Lives until |
| --- | --- | --- |
| The authority | `user_sessions` in Postgres | revoked, absolute expiry, or a week idle |
| The persistent copy | secure storage, keys `session_token` and `session_user` | logout, or the server rejects it |
| The hot copy | `SessionCredentials`, in memory | the process ends |

`SessionRepository` is the only writer, and it writes them in that order —
server, then storage, then memory — so the token the interceptor attaches is
never ahead of what survived a restart.

The in-memory copy exists because the alternative is a keychain round trip on
every RPC. It lives in the network layer rather than in the auth feature
because `AppNetwork.connect()` runs before any store exists and the
interceptor needs something to read from the first call onward.

`session_user` holds the signed-in `AuthUser` as JSON — not a secret, but it
is worthless without the token and must disappear with it, so it is kept in
the same store and cleared by the same call.

## The pipeline

The feature follows the app's standard layering, with one deliberate
departure:

```
AuthGrpcSource ──▶ SessionRepository ──▶ SessionStore ──▶ LoginPage / VerifyEmailPage
   (AuthApi)         token + storage      SessionState        router redirect
```

- **Commands** (`features/auth/data/commands/auth_grpc_commands.dart`) — one
  `RpcCallCommand` per RPC, so a `GrpcError` becomes an `AppError` before it
  leaves the source.
- **`AuthGrpcSource`** implements `AuthApi`, a hand-written interface, instead
  of composing a `DomainSource`. `DomainSource` pairs a fetch, a watch and a
  synchronize source for one feature; auth is five unrelated one-shot calls
  and has nothing to watch. The interface is what lets the repository, the
  store and the widget tests run with no channel (`test/auth/fake_auth_api.dart`).
- **`SessionRepository`** owns the three copies above.
- **`SessionStore`** holds `ValueNotifier<SessionState>`, a sealed
  `SignedOut` / `SignedIn` pair. It is a *global* store, built in `main.dart`
  above the router, per the placement rule in `app_router.dart`: every page
  depends on it, so it must outlive any route.

`SessionStore.start()` is awaited before `runApp`, so the router's first
redirect already knows who is signed in — otherwise the app shows the login
page for a frame and then jumps away from it.

## The interceptor, and how a dead session is noticed

`AuthInterceptor` (a grpc-dart `ClientInterceptor`) attaches
`authorization: Bearer <token>` to every call, unary and stream, except
`Register`, `Login`, `OAuthLogin`, `RequestPasswordReset` and `ResetPassword`.
Those five get no header, and their `UNAUTHENTICATED` means "wrong password"
(or a stale token during a reset), not "dead session", so it is not reported.
They are five of the six RPCs the server's policy table marks `Public`; the
sixth, `Logout`, does carry the header — it is public only so that logging out
with an already-dead session still succeeds, and the handler reads the token
out of the metadata. Only unary calls report `UNAUTHENTICATED` to
`SessionCredentials`; see "What is not done" for streams.

In grpc-dart an interceptor belongs to the **client**, not to the channel.
A source that builds its generated client without passing them sends no token
at all, silently. That is why `GrpcService` exposes an `interceptors` list and
`GrpcSource.create` hands it to every source's factory: getting it right is
now the default rather than something each feature remembers.

Nothing polls for expiry. The client knows the absolute `expires_at` and
checks it when restoring, but the idle window slides server-side and is not
knowable here, so **an `UNAUTHENTICATED` answer is the signal**: the
interceptor reports it to `SessionCredentials`, which calls back into
`SessionStore`, which forgets the session and moves to
`SignedOut(expired: true)` — the flag the login page uses to explain why the
user is back there.

The report is guarded by comparing the rejected token to the current one. A
call sent with an old token can land after the user has already signed in
again; signing out the *new* session because of it would be a bug that only
shows up under bad network conditions.

## The router is the only thing that navigates

`authRedirect(SessionState, String location)` is a plain function, so it is
tested without a widget tree (`test/auth/auth_redirect_test.dart`):

| State | Allowed | Everything else redirects to |
| --- | --- | --- |
| `SignedOut` | `/login` | `/login` |
| `SignedIn`, email unverified | `/verify-email` | `/verify-email` |
| `SignedIn`, verified | anything but the two above | `/home-page` |

`createAppRouter` wires it with `refreshListenable: sessionStore.state`, so
logging in, logging out and losing the session all move the user without any
page calling `context.go`. Login, sign-up, logout and code entry therefore
contain no navigation at all — they change the session and let the redirect
follow. Build the router once, after `start()`: rebuilding a `GoRouter` resets
the navigation stack.

**Holding an unverified user on `/verify-email` is a client-side rule.** The
subject (V.1) demands mail validation; the server does not enforce it — an
unverified account can call every other RPC. If a second client ever exists,
it gets to make the same choice on its own.

## Errors

`ErrorMapper.fromGrpc` gained three cases the auth screens need to tell apart:
`INVALID_ARGUMENT` → `InvalidInputError`, `ALREADY_EXISTS` → `ConflictError`,
`FAILED_PRECONDITION` → `PreconditionFailedError`. The first used to map to
`NetworkError`, which is how a rejected password ended up reported as a
connectivity problem.

`ErrorMapper.from` now returns an `AppError` unchanged instead of wrapping it.
The error crosses two mapping points — `RpcCallCommand` maps it, then
`CommandExecutor` maps again on the way out — and the second pass used to turn
every typed error into `UnknownError`.

`authErrorMessage(error, action)` turns the pair into user-facing English. The
server's own messages are never shown: some are French developer strings, and
several are deliberately vague (`Login` will not say whether the email exists),
so only the screen knows enough to say something useful.

Two `FAILED_PRECONDITION` answers are swallowed rather than shown, because in
both the user's goal is already met: verifying an email that another device
verified first, and asking for a code when the account turns out to be
verified. Both end at the same place — mark the local session verified and let
the router move on.

## The dev token

`DEV_SESSION_TOKEN` in `.env` (read at compile time like the rest of
`AppConstants`) is used when nothing is stored, so screens behind the login
wall can be worked on without signing in every run: log in once with `grpcurl`
and paste the token. It is ignored in release builds (`kDebugMode`), carries a
fake account marked verified so the verification page does not block it, and
is never written back to secure storage.

## Tests

`flutter test` now runs 31 cases, 25 of them this slice's, and none need a
backend:

- `test/auth/auth_grpc_source_test.dart` — a real `AuthServiceBase` served on a
  loopback port, so the header, the anonymous exemptions, the status-code
  mapping and the rejection callback are exercised over the wire rather than
  against a mock of the thing under test.
- `test/auth/session_store_test.dart` — restore, login, register, logout,
  verification and expiry against `FakeAuthApi` and a fake secure-storage
  platform.
- `test/auth/auth_redirect_test.dart` — the redirect table above.
- `test/widget_test.dart` — the app boots to `/login` signed out, and an
  unverified login lands on `/verify-email`. (Where a *verified* login lands is
  left to the redirect test: the home page fetches network images, which a
  widget test cannot serve.)

The other six are the pre-existing mocked secure-storage tests. The on-device
keychain test (`integration_test/`) still needs a real device.

## Social sign-in (OAuth)

"Continue with Google / 42" is the OAuth authorization-code flow.
The app does the browser half, the server does the half that needs the client
secret:

```
app      1. open the provider's login page   OAuthBrowserFlow.authorize
                (client_id, redirect_uri, scope, state)  (flutter_web_auth_2)
provider 2. user logs in, clicks Allow
provider 3. redirect to redirect_uri?code=…&state=…
backend     GET /oauth/callback -> 302 musicroom://oauth?code=…&state=…
                                             internal/auth/oauth/callback.go
app         flutter_web_auth_2 catches musicroom://, the app checks `state`
app      4. OAuthLogin(provider, code, redirect_uri)  SessionStore.oauthLogin
backend  5. code -> access token, with the client secret   oauth/client.go
backend  6. read the email, find/create the account, return a session
```

Why the bounce page: Google and Facebook only accept http(s) redirect URIs for
a client with a secret, and the app can only receive its own `musicroom://`
scheme. The page copies `code`, `state`, `error` and `error_description` to a
destination fixed by config (`APP_OAUTH_APP_CALLBACK`), never by the request,
so it cannot be used as an open redirect.

Files: `features/auth/data/oauth_browser_flow.dart` (login URL, `state`,
cancel/error handling), `core/models/auth/oauth_provider.dart` (endpoints and
scopes), `SessionStore.signInWithProvider`, `OAuthButtons`. A closed window or
"Deny" is `OAuthCancelledError`, which the login page does not report.

### Linking a provider to an existing account

Profile → *Linked accounts* (subject: "link their network account"). Same
browser half as sign-in, a different RPC at step 4:
`LinkOAuthAccount(provider, code, redirect_uri)` instead of `OAuthLogin`. So
it needs nothing more from the providers: the redirect URI is the same one,
and a provider that can sign in can be linked.

- `ListOAuthAccounts` fills the screen: the linked providers and
  `has_password`. An AuthService RPC rather than a `UserDTO` field, because
  `UserDTO` is the profile *as another user sees it* (GetUser), and which
  identities open an account is no one else's business.
- **Unlink** is refused (`FailedPrecondition`) when it would leave no way in:
  no password and one provider. The app greys the button and points at
  Change password, which gives an OAuth-only account its first password
  (the reset flow proves the inbox, so no current password is asked).
- **Link** is refused (`AlreadyExists`) when that identity already opens
  another account. Merging the two is out of scope.
- Signing in with a provider whose email matches an account links it too
  (`OAuthLogin`), so a row can show up linked without ever tapping Link.

Files: `features/auth/presentation/stores/linked_accounts_store.dart`,
`features/auth/presentation/widgets/linked_accounts_section.dart`,
`LinkedAccountsApi` in `features/auth/data/auth_source.dart`.

### Turning a provider on

1. Register an app with the provider: Google Cloud Console (OAuth client of
   type *Web application*), Meta for Developers (Facebook Login), 42 intra
   (Settings → API → Register a new app). Facebook also needs
   `hidden: true` removed in `core/models/auth/oauth_provider.dart`.
2. Register this redirect URI there, exactly: the backend's public HTTP
   address + `/oauth/callback` (local: `http://localhost:8081/oauth/callback`).
3. Backend: `APP_OAUTH_<PROVIDER>_CLIENT_ID` and `_CLIENT_SECRET` in `.env`.
   The log line `OAuth providers: [...]` lists what got registered.
4. App: `OAUTH_<PROVIDER>_CLIENT_ID` in `frontend/app/.env`, and
   `OAUTH_REDIRECT_URI` equal to step 2. A provider without a client ID shows
   its button disabled, "(not configured)".

Caveats:

- **Platforms.** iOS, Android, macOS and Linux (below). Windows would work
  like Linux but has never been tried, and web needs an `auth.html` page plus
  the missing web half below; the buttons say "(not available here)" there.
- **Phones and emulators.** The redirect URI is opened by the phone's browser,
  where `localhost` is the phone. Use an address the phone can reach, and for
  Google (http allowed only for `localhost`) an https one, e.g. a tunnel to
  port 8081. iOS simulator and macOS can use `localhost`.
- **No PKCE yet.** On Android another app could register `musicroom://` and
  read a code on its way back. The `state` check stops forged logins, not
  that. PKCE (a `code_verifier` sent at step 4 and passed on at step 5) would:
  one proto field, one form field in `exchangeCode`, and the challenge in
  `authorizeUrl`.

Tests without real client IDs: `test/auth/oauth_browser_flow_test.dart`
(URLs, `state`, cancel, errors), the OAuth group in `test/widget_test.dart`
(buttons on the login page), `oauth/callback_test.go`, and two live tests
(`test/live`): the bounce page, and, against a backend started with
placeholder credentials and `LIVE_OAUTH_CONFIGURED_PROVIDER=intra42`, a code
exchange that reaches 42's real token endpoint and is refused.

## What is not done

- **No web half.** The app is not built for the web at all (the Dockerfile
  passes `--no-enable-web`), so there is no `auth_web_source.dart`. The server
  side is ready: `AuthService` is now registered on the gateway
  (`cmd/main.go`), so a web half would be client work only.
- **No Facebook app.** Google and 42 are registered (their IDs are in
  `.env.example`, their secrets only in the root `.env`). No Meta developer
  app could be registered, so Facebook is hidden (`OAuthProvider.hidden`):
  no sign-in button, no Linked accounts row. The server provider, the DB enum
  value and the client plumbing stay. The subject (V.1) asks for social
  sign-up "Facebook/Google", and Google covers it.
- **Stream errors are not reported.** The Watch streams (`WatchPlaylist`,
  `WatchEvent`) carry the same `authorization` header as unary calls, but an
  `UNAUTHENTICATED` on a stream does not call `credentials.reject`: the
  response stream can only be listened to once, by its caller, and the next
  unary call reports a dead session anyway (`auth_interceptor.dart`).

### 42 and Google on the Linux phone

The eval phone is the Linux build, where flutter_web_auth_2 opens the
provider's page in a WebKit window of the app's own (desktop_webview_window)
rather than a browser. That window reports every address it is sent to,
redirects included, so it stops at the redirect URI itself
(`http://localhost:8081/oauth/callback`) before loading it and hands the
code back: `OAuthConfig.catchesRedirect`. The bounce page is not needed there,
which matters because `localhost` inside the phone container is not the
backend. One redirect URI registered with each provider therefore serves the
Mac dev app (bounce page → `musicroom://`) and the phone (caught in the window).

The window comes from desktop_webview_window, which the app pins to a
patched copy (`frontend/app/third_party/desktop_webview_window`,
`dependency_overrides`; `PATCHED.md` there). Upstream 0.3.0 crashed the app
on every close of the window, the redirect caught or cancelled, so the
phone restarted on the login page and OAuthLogin was never called:

- its close handler read the window object after deleting it;
- its title bar was a second Flutter engine (running `main` with
  `web_view_title_bar <id>`), whose teardown raised a fatal GLX error on a
  screen without a GPU (Xvfb).

The copy fixes the first and draws the title bar with two GTK buttons, ✕
(cancel) and ← (back). The ✕ is needed because the phone's window manager
shows no title bars: it is the only way to abandon a login.

Google is known to refuse embedded webviews ("disallowed_useragent"), but it
serves its sign-in page to this one (WebKitGTK passes for a browser) and
takes the email step. Two things on its side: the OAuth client must be of
type *Web application* (Google allows http redirect URIs only for
`localhost`, which is ours), and while its consent screen is in *Testing*
only the Google accounts listed as test users can sign in, so add the
evaluators' or publish the app.

The phone image takes the client IDs from `APP_OAUTH_INTRA42_CLIENT_ID` and
`APP_OAUTH_GOOGLE_CLIENT_ID` in the root `.env` at build time
(`docker-compose.yaml` → `frontend/Dockerfile`), so `make phone-build` after
filling them in.
