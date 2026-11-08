# Tuple sync — developer guide

How to keep the OpenFGA permission graph in step with Postgres when you add or change a
mutation. Background and rationale: [`authz-sync-summary.md`](./authz-sync-summary.md),
[`data-model.md` §14](./data-model.md), [`permissions.md`](./permissions.md).

This is the **write** half. Reading the graph -- the interceptor, the policy table, and what
is still checked in Go -- is [`authz-enforcement.md`](./authz-enforcement.md).

---

## The one rule

> **Enqueue the tuple change on the same `pgx.Tx` as the domain change, and deliver it
> after the commit.**

Everything else in this document follows from that. Passing the pool to `Enqueue` instead
of the transaction compiles, runs, passes your tests, and quietly removes the entire
guarantee — the outbox row would commit separately from the data it describes.

---

## The pattern

Any repository method that mutates a table listed in `data-model.md` §14 goes through
`outbox.InTx`. It exists so the rule above cannot be broken by a call site: `fn` only ever
receives the transaction, never the pool.

```go
func (r *Repository) DoSomething(ctx context.Context, ...) (Thing, error) {
	return outbox.InTx(ctx, r.outbox, r.db,
		func(ctx context.Context, tx pgx.Tx) (Thing, []authz.Change, error) {
			queries := sqlc.New(tx)

			// 1. the domain change
			row, err := queries.InsertTheThing(ctx, ...)
			if err != nil {
				return Thing{}, nil, err
			}

			// 2. describe what changed. InTx enqueues these on the same tx,
			//    commits, then delivers them.
			change := authz.Change{
				ObjectKey: authz.Object(authz.TypePlaylist, row.PublicID.String()),
				Origin:    authz.OriginPlaylistCreate, // add the constant to tuple.go
				Writes:    []authz.Tuple{ /* ... */ },
			}
			return Thing{...}, []authz.Change{change}, nil
		})
}
```

Returning **several** changes is normal, not an escape hatch. One `Change` is one *object's*
worth of work, because outbox ordering is per-object. Blocking a user touches the pair and
every device grant between them; one `Change` spanning all of those would order correctly
against none of them.

`InTx` swallows delivery failures on purpose. Once the commit lands, both the data and the
intent are durable; a delivery failure is a delay, not a lost write, and failing the user's
request because a secondary system is slow trades a self-healing problem for a user-visible
one.

Your repository needs `outbox.DB` (`sqlc.DBTX` plus `Begin`). `*pgxpool.Pool` satisfies it.
Take `*outbox.Outbox` in the constructor and wire it from `cmd/main.go`.

### What goes in the repository, and what does not

The repositories hold the mutations that **owe tuples** — not every mutation, and not every
piece of SQL. The services keep their reads, their DTO mapping, and the writes the graph does
not care about. `AddSongToPlaylist` is the clearest case: it is governed by
`playlist#can_edit_songs`, which resolves entirely from the *playlist's* tuples, so adding a
song owes no tuple at all. What it owes is a `Check`.

Two things belong outside the transaction and were deliberately moved out of it:

- **Network calls.** `SuggestSong` used to fetch from Deezer inside the transaction, holding a
  row lock across an HTTP request. The song catalogue is global and need not be atomic with
  the queue entry; a rollback leaves one extra `songs` row, which is a warm cache, not an
  inconsistency.
- **Image work.** Resizing and writing files happen before the transaction opens. The files
  must exist before a row points at them, and the *old* files are deleted only after the
  commit — a rollback must not leave a valid row pointing at a deleted file.

## Building a `Change`

```go
type Change struct {
	Writes    []Tuple
	Deletes   []Tuple
	ObjectKey string // required
	Origin    string // required in practice
}
```

- **`ObjectKey`** is the FGA object the change is *about* — `authz.Object(type, publicID)`.
  The worker uses it to keep changes to the same object in order. `Enqueue` errors without it.
- **`Origin`** is a short label for whoever debugs a stuck row. Add a constant to the
  `Origin*` block in `tuple.go` rather than inlining a string. One per *mutation*, not per
  object type: it is the only column that says which handler put the row there, so two
  handlers sharing a label costs exactly what it exists to provide.
- **Object ids are always public UUIDs**, never the `BIGSERIAL` primary key.

Tuples:

```go
authz.Tuple{
	User:     authz.UserRef(userPublicID), // or authz.Everyone for a [user:*] relation
	Relation: authz.RelPlaylistOwner,
	Object:   authz.Object(authz.TypePlaylist, playlistPublicID),
}
```

Only **directly assignable** relations have constants — the ones declared with a type
restriction, like `define owner: [user]`. Computed relations (`can_view`, `can_edit_songs`)
are derived by the server and cannot be written.

### Conditions

One relation carries a CEL condition, `event#window_vote`. Its parameters split across two
moments:

| Condition | Written on the tuple | Supplied at `Check` time |
| --- | --- | --- |
| `within_vote_window` | `window_start_minutes`, `window_end_minutes`, `venue_timezone` | `current_time` |

---

## Rules you must not break

**1. Mutually exclusive flags: delete the others in the same `Change`.**

The vote licence is exactly one of `open_vote` / `invited_vote` / `window_vote`. Splitting
the delete and the write across two `Change` values reintroduces a window where the graph is
wrong in the *permissive* direction. `authz.EventVoteLicense` already returns both halves —
use it:

```go
change := authz.EventVoteLicense(eventPublicID, authz.VoteLicenseInvitedOnly, nil)
```

**2. Derive from the row, not from the defaults.**

Read the value you just wrote and map it, rather than restating the column defaults in Go. A
default changed in a migration must not be able to silently disagree with the graph.

**3. Some deletions have no trigger in the model — the handler must do them.**

Friendships, profile visibility and control licences are not in the graph: they are read
from Postgres. **Blocking** is: it writes `blocked` in both directions, and the friendship and
licences it ends are removed from Postgres in the same transaction (`permissions.md` §5).

**4. A `Check` passing is necessary, never sufficient.**

The third column of every table in `permissions.md` lists what must *also* be true —
`events.status`, `deleted_at`, entry status, the venue radius. Read it before wiring a
handler.

**5. Never author a tuple that isn't a transcription of a row.**

The only sanctioned exception is `user#blocked`, where one directional `user_blocks` row
becomes two tuples.

---

## Adding a new object type or relation

1. Edit `authz/model.fga`.
2. `make fga-validate` — **necessary, not sufficient**: it does not catch the server's
   512-byte cap on condition expressions.
3. `make fga-model` to push it. This is the real check.
4. Add the constant to `tuple.go`. `TestRelationConstantsExistInModel` parses the model
   file and will fail if the name does not match.

If the type's table has no `public_id` column, add one first — see
`00017_public_ids.sql`, which did this for `devices`, `images` and `event_queue_entries`.

---

## Testing

```bash
make docker-backend-test              # unit; no services needed
make docker-backend-test-integration  # brings up Postgres + OpenFGA first
make docker-backend-lint              # gofmt + go vet
```

There is no Go toolchain assumed on the host — these run in a container. The repo **root**
is mounted, not `backend/`, because `internal/authz`'s tests read `authz/model.fga`.

Integration tests are behind `//go:build integration`. Use a fake `outbox.Applier` when the
test is about outbox behaviour, and the real client when it is about the graph.

Two things worth testing for any new mutation:

- The tuples land, and the *derived* permission resolves — check `can_view`, not `viewer`.
- The change survives OpenFGA being down. `docker compose stop openfga`, mutate, confirm
  the request succeeds and the outbox row is retained.

---

## Operating it

```bash
# backlog -- in a healthy system this is empty
docker exec music-room-postgres psql -U postgres -d music_room -c \
  "SELECT id, origin, object_key, status, attempts, last_error, next_attempt_at
     FROM openfga_tuple_outbox ORDER BY id"

# what the graph actually holds for one object
curl -s -X POST http://localhost:8082/stores/$STORE/read \
  -H 'Content-Type: application/json' -d '{"tuple_key":{"object":"user:<uuid>"}}'
```

The backend logs the backlog at boot and every failed delivery. A row stuck with a high
`attempts` is holding back **every later change to the same object** — that is intentional
(ordering), and it means a poisoned row needs a human, not just patience.

Delivery is eventual. A `Check` can lag a mutation by the retry backoff (30s doubling to
10min). If a flow needs the graph to be current *now*, it must be a mutation whose inline
`Deliver` succeeded — which is the normal case, but not a guarantee.

### Config

| Variable | Default | Notes |
| --- | --- | --- |
| `APP_OPENFGA_API_URL` | `http://localhost:8082` | `http://openfga:8080` inside compose |
| `APP_OPENFGA_STORE_ID` | `01MRAVTHZ00000000000000000` | the fixed ULID `openfga-init` imports into |
| `APP_OPENFGA_MODEL_ID` | *(empty)* | empty = always latest. Pin it in production; the id is logged at boot |
| `APP_OPENFGA_SYNC_INTERVAL_SECONDS` | `15` | worker tick |
| `APP_OPENFGA_SYNC_BATCH` | `20` | rows per pass |

The backend **fails to boot** if the store is unreachable or has no authorization model.
That is deliberate: a tuple write that goes nowhere is invisible, and the first symptom
would be a permission denied for no reason, much later.
