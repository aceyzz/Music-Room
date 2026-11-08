# Enforcement — how a request gets authorized

The read half of the permission system. Companion to
[`permissions.md`](./permissions.md) (the rules), [`authz-sync-guide.md`](./authz-sync-guide.md)
(the write half) and `authz/model.fga` (the model).

Code: `backend/internal/interceptor`.

---

## The one rule

> **An RPC with no entry in the policy table is denied.**

Not "allowed because nobody thought about it". Adding an RPC and forgetting to
protect it is the single most likely way to open a hole in this backend, and
this is the only arrangement where that mistake fails closed. `TestEveryRPCHasAPolicy`
walks the proto registry, so it fails the *build* rather than a request; the
runtime denial is the backstop.

---

## What happens, in order

```
metadata: authorization: Bearer <token>
        |
        v
  authn.Authenticate      token -> Identity{UserID, UserPublicID}   (one indexed SELECT)
        |                 Unauthenticated on failure, one message for all five reasons
        |                 (unknown, revoked, expired, idle, account not active),
        |                 then slides the idle window if last_used_at is over a minute old
        v
  stampCaller             the request's caller field <- the session
        |                 PermissionDenied if the request named someone else
        v
  for each Requirement:
     Check                Check(user:<uuid>, <permission>, <type>:<uuid>)   no database
        |                 NotFound on a read, PermissionDenied on a write
        v
     Resolve              public UUID -> internal id, stamped into the request
        |                 NotFound when no usable row carries it
        v
  handler                 receives the identity in its context and an id it did not choose
        |
        v
  logActivity              activity_logs row, async -- see "Activity logging" below
```

Both transports go through it: the REST gateway dials the same gRPC port over
loopback and grpc-gateway forwards an HTTP `Authorization` header into the
metadata unprefixed. The Watch streams (`WatchPlaylist`, `WatchEvent`) go through
the stream interceptor, which authorizes their one request the same way; each Watch
handler then re-checks `can_view` before sending, so a viewer who loses access is
dropped. (The old `/ws` WebSocket endpoint, which no interceptor saw, was removed.)

---

## Why the request gets rewritten

The API speaks internal `int64` ids in its request bodies and the graph speaks
public UUIDs. Something has to translate, and the direction was the whole
decision:

- Requests name objects by **public UUID** (`playlist_public_id`), which is the
  only id a client is ever handed.
- The interceptor checks THAT id, then resolves it and writes the internal id
  into the request.
- The handler has no other id to act on.

So the object that was authorized and the row the handler touches cannot be
different objects. The alternative — trusting a client to send a consistent
`(playlist_id, playlist_public_id)` pair — is a permission check on one object
and a write to another, which is worse than no check at all because it looks
like one.

The caller costs no lookup: `GetSessionByHash` joins `users`, so authentication
already returns both ids.

---

## Adding an RPC

1. Add the `*_public_id` fields to the request in `proto/`. The convention is
   exact — the int64 counterpart is the same name with `_id` where the public one
   has `_public_id` — because `Requirement.StampField()` derives one from the
   other. `TestPolicyFieldsExistOnEveryRequest` checks the derived name against
   the real descriptors.
2. Bind the REST path parameter to the public field, not the int64 one. A client
   only knows the UUID; a path it cannot build is a route it cannot call.
3. Add the policy entry. The shapes:

```go
// public: no session needed at all. Four RPCs, all of AuthService — the
// three that hand out a session, plus Logout, which reads its own token
// (and must still succeed when that token is already dead).
"/music_room.v1.AuthService/Login": {Public: true},

// authenticated, nothing else. The song catalogue — and the two email
// verification RPCs, which act on the session's own account: the address a
// code goes to, and the account a code may verify, come from the identity
// and never from the request.
"/music_room.v1.MusicProviderService/GetSong": {},
"/music_room.v1.AuthService/VerifyEmail":      {},

// row-owned: stamping the caller IS the check. You cannot list someone
// else's friends when the id being listed is always your own.
"/music_room.v1.UserService/GetFriends": {CallerPublicIDField: "user_public_id"},

// the normal case
"/music_room.v1.PlaylistService/SetPlaylistCover": {
    CallerPublicIDField: "user_public_id",
    Require: []Requirement{{
        Type: authz.TypePlaylist, IDField: "playlist_public_id",
        Permission: authz.PermPlaylistSetCover, Resolve: true,
    }},
},
```

4. If the permission is new, add the `Perm*` constant in `internal/authz/check.go`.
   `TestPermissionConstantsExistInModel` parses `model.fga`, so a name that is not
   a real relation fails the build — which matters, because OpenFGA answers a
   check on an unknown relation with a flat `false`, not an error.
5. Write down what the interceptor is *not* deciding, in `Residual`. It is a
   one-line statement that this method knowingly owes its handler something.

---

## The four rules that are not obvious

**1. A denied read is NotFound, a denied write is PermissionDenied.**

Set `NotFound: true` on read requirements. It is not politeness: `permissions.md`
§10 makes discovery and read the same permission, so an event you may not view
must be indistinguishable from one that does not exist. `PermissionDenied` on a
read confirms the object exists, which is the disclosure the private setting was
supposed to prevent. `TestReadPermissionsDenyAsNotFound` pins it.

**2. A check that cannot be answered is a denial.**

`Check` returns `(bool, error)` and never conflates them; the interceptor maps
any error to `PermissionDenied` and logs it. The write path retries forever
because a missing tuple is invisible. A check has the opposite shape: it must
answer now, and letting requests through while the authorization server is
unreachable turns one outage into an open door.

**3. Every check carries `current_time`.**

`within_vote_window` needs it from the request side. Unused context keys are
tolerated (verified against server v1.18.3), so it is supplied unconditionally
rather than per-relation. `request_event_id` is not supplied here — it belongs to
the delegated playback checks, which are still handler-side.

**4. A `Check` passing is necessary, never sufficient.**

The third column of every table in `permissions.md` is what must *also* be true.
What is left in Go today, and where:

| Residual | Where |
| --- | --- |
| Venue radius under a `location_time` licence | `event/access.go:requireVoteResiduals` |
| Per-field profile redaction | `user/service.go` (PLACEHOLDER), `user/access.go` |
| Playback: event OR device, relation depends on the action | `event/access.go:canControlPlayback` (still SQL) |
| `events.status`, entry status | `event/access.go:requireVoteResiduals`, `event/playback.go` |
| Friends-only delegation | `delegation/service.go` — a write-time precondition, not a check-time question |
| Row ownership (friend requests, friendships, licences) | the queries themselves, scoped by the caller |
| Member rank ("an admin may not demote the owner") | nowhere yet — no role-change RPC exists |
| The three-step revision transaction | `playlist/service.go` |

`grep -rn PLACEHOLDER backend/internal` finds the ones that are not written yet;
`todo.md` §4 and §6 has the code for each.

---

## Activity logging (V.6)

Every unary call writes one `activity_logs` row (`docs/annex/data-model.md` §12), success or
denial alike — `internal/interceptor/activitylog.go`, called from `Unary` itself rather than
as a second chained interceptor. That is not a style choice: a denial from `authorize`
returns before ever calling `handler`, so an interceptor positioned *after* the permission
one in a chain would simply never see a denied call. `Unary` is the only place that sees
every outcome, which is why logging lives there instead of being its own link in the chain.

```
  authorize            may fail -- Unauthenticated, PermissionDenied, ...
        |
        v
  logActivity           always runs: action = full method name, result_code = the
        |               gRPC status code returned (0 = OK), user_id = the caller's
        |               id IF authentication succeeded (NULL otherwise -- an
        |               unauthenticated call has no one to attribute it to)
        v
  handler / response
```

**Identity is attached to the context as soon as it is resolved**, not only on a fully
successful `authorize` — `authn.NewContext` runs right after `Authenticate` returns, before
`stampCaller` or any `Requirement` is evaluated. Attaching it only at the very end (the
original shape) meant a request that authenticated fine and was denied by a `Requirement`
further down logged with `user_id = NULL`, indistinguishable from a call that never
authenticated at all — exactly the two cases this table most needs to tell apart.

**The device comes from the session, not from the request.** `RegisterDevice` upserts the
device and binds the calling session to it (`AttachSessionDevice` sets
`user_sessions.device_id`). The app calls it after each sign-in and on each launch. From then
on `GetSessionByHash`, which runs on every authenticated call anyway, hands back the
`device_id` with the session, `authn.Identity.DeviceID` carries it, and `logActivity` writes it.
`CreateActivityLog` then snapshots `platform_snapshot`/`app_version_snapshot` from the device
row in the same statement. There's no per-request device lookup, and nothing trusts a
client-supplied device id: a session is one install of the app, so it can only name its own
device.

**`x-platform`/`x-device-model`/`x-app-version`** still go into the `metadata` JSONB column
on every call. They're the only device information an unauthenticated call has (a failed
login, an expired token), and the only information for a call made before the app registered
its device, which logs with `device_id` NULL.

grpc-gateway does **not** forward those three headers by default: `DefaultHeaderMatcher`
only passes through IANA-permanent HTTP headers and ones prefixed `Grpc-Metadata-`, silently
dropping anything else. `cmd/main.go` registers a custom `WithIncomingHeaderMatcher`
(`activityHeaderMatcher`) that forwards these three on top of the default set — without it,
the REST path (which is how the mobile app actually calls this API) would never deliver them
to the interceptor at all, even though a raw gRPC call already would.

**Fire-and-forget.** `logActivity` runs the insert in its own goroutine against its own
5-second timeout, detached from the request's context (which is cancelled the moment the RPC
returns to its caller). A write that fails only logs to stderr — an audit log must never make
the request it is describing slower or less reliable than it would otherwise be.

**`resource_type`/`resource_id`** name the object the call was about — `primaryResource`
(`activitylog.go`) walks the method's own `policy.Require` in order and reads back the first
`StampField` that actually resolved to an id (`int64Field`, `fields.go`), the same field
`enforce` already stamped into the request. Deliberately **not** the request body: this is a
security audit log kept for up to two years (`00014_activity_logs.sql`), and a raw body would
carry a password on `Register`/`Login`, a reset token, or worse — reading back only what the
interceptor itself resolved, never a field the client sent, is what keeps a secret from ever
reaching it. A denied `Requirement` reports no resource: `enforce` checks permission before
resolving, so nothing was resolved to read back — which is also the right amount of
disclosure for an object the caller was refused.

Not built: `ip_address`/`user_agent` are always left unset. Neither needs a design decision
like the two above, just plumbing — `todo.md` §6 if that is ever wanted.

---

## Testing

```bash
make docker-backend-test   # includes the policy-table tests
make docker-backend-lint
```

The interceptor's own tests replace OpenFGA and Postgres with two functions,
because no decision in that file depends on more than yes/no and an id. What
they cover, and why each one is worth a test rather than a reading of the code:

- an unlisted method is denied
- a request claiming another user's public id is denied, an empty one is filled in
- the undashed UUID form is accepted (the DTOs used to emit it)
- the resolved id reaches the request
- a denied read is NotFound, a denied write is PermissionDenied
- a failed check denies
- an invite checks both objects, in order
- a server stream is authorized on its request; one without a token is unauthenticated, and a denied read is NotFound
- client streams are denied except reflection

End to end, against a live stack, the shape that matters most is the pair: the
same RPC allowed for one caller and denied for another, differing only in the
graph. A test that only ever asserts "allowed" passes just as well with the
interceptor removed.
