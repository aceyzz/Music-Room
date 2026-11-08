# Load testing (V.7 Ramp-up)

The subject asks us to measure how much load the API and the backend can carry. The
measure is the number of simultaneous users on the three services. It must state the
characteristics of the server it ran on, and the number must be coherent with that
server. This document covers how we measure, what we measured, and where it broke.

**Contents.** [What a "user" is](#what-a-user-is) · [The server](#the-server-a-declared-budget) ·
[Method](#method-a-stepped-ramp-and-an-slo) · [Correctness under load](#correctness-under-load) ·
[Running it](#running-it) · [Results](#results) · [Where it breaks](#where-it-breaks) ·
[Limits of the method](#limits-of-the-method)

---

## What a "user" is

One k6 virtual user (VU) is one person with the app open, and it behaves like the app:

| Service | Each VU, every 5 s (the app's poll period) | And sometimes |
|---|---|---|
| Track Vote | `GetEventPlayback` + `ListEventQueue`, like the live event page | votes (40 % of polls), suggests (5 %); the host also advances the queue every ~30 s, one song |
| Playlist Editor | `GetPlaylist`, like the playlist page | adds (6 %), moves (12 %), removes (4 %), all on rows the other members edit too |
| Control Delegation | delegates: `GetEventPlayback`; owner: `ListDeviceControlLicenses` | delegates pause or resume with the owner's device (30 %); the owner grants and then revokes a spare friend, alternating |

The rates live in `loadtest/lib/behaviours.js`. They are guesses at an *engaged* user,
not at an average one: someone at a party voting every few seconds is the case the
server has to survive.

The groups are fixed, so contention is real. Fifty people share an event, ten share a
playlist, and six share a device. Every vote, move and grant competes with the others
in its group for the same rows.

**The headline number comes from `mixed`**, where each step's VUs are split 60 / 30 / 10
between the three services. Each service also has its own scenario, so a single
service's limit can be measured alone.

Three things are deliberately left out of the measured traffic:

- **Logging in.** Each `Login` verifies an Argon2id hash that takes 64 MiB of memory
  (`backend/internal/security/password.go`). A thousand VUs logging in at once would
  measure the hash and need ~64 GB of RAM. So the VUs start with sessions written by
  the seeder, and login throughput is measured on its own (`SCENARIO=login`).
- **Deezer.** Songs come only from the seeded catalogue, which is already in `songs`,
  so no request under load leaves the machine. A Deezer quota is not our server's
  capacity.
- **The per-IP rate limit.** k6 sends every request from one address, so the
  backend's limit per address (`APP_RATE_LIMIT_RPS`, 100 a second by default, gRPC and
  REST alike) would cap the run at 100 req/s. `loadtest/compose.yaml` turns it off (`APP_RATE_LIMIT_RPS=0`).

## The server: a declared budget

The load test runs on its own compose project, `music-room-lt` (`loadtest/compose.yaml`),
never on the dev stack. Every server-side container gets a CPU and memory cap, and the
**sum of the caps is the server** the number belongs to:

| Container | `small` | `medium` |
|---|---|---|
| backend (Go: gRPC + REST gateway) | 0.5 vCPU, 512 MB | 2 vCPU, 1 GB |
| postgres (app data) | 0.5 vCPU, 512 MB | 1 vCPU, 1 GB |
| openfga (permission checks) | 0.75 vCPU, 256 MB | 0.5 vCPU, 512 MB |
| openfga-postgres | 0.25 vCPU, 256 MB | 0.5 vCPU, 512 MB |
| redis + image-service (idle under this load) | 0.5 vCPU, 256 MB | 0.5 vCPU, 256 MB |
| **Total** | **≈ 2.5 vCPU, 1.75 GB**: a small VPS | **≈ 4.5 vCPU, 3.25 GB**: an entry-level server |

`small` was first declared with backend 1 vCPU and OpenFGA 0.25. The first runs showed
that split starved OpenFGA while the backend idled ([below](#what-the-measurements-say)),
so the same 2 vCPU are now split the other way. `medium` keeps its first split. To rerun
the original: `make loadtest LT_BACKEND_CPUS=1 LT_FGA_CPUS=0.25`.

The server containers are pinned to one half of the machine's cores and k6 to the other
half (`cpuset`), so on a single machine the load generator does not steal the server's
CPU. Each run writes the host CPU model, its core count and RAM, and the caps into
`env.txt`.

We run two budgets to show the number moves with the infrastructure, as the subject
asks: "tens for a Raspberry Pi, thousands for a low-end server".

## Method: a stepped ramp and an SLO

The VUs climb in steps, 25 → 50 → 100 → 200 → 400 → 800 by default. Each step has a
30 s ramp and then a 2 min hold, and every request is tagged with the step it ran in.
A step **holds** when, during its hold, all three of these are true:

- unexpected errors stay under 1 %;
- reads (the 5 s polls) have a p95 under 300 ms;
- writes (the taps) have a p95 under 500 ms.

**Max simultaneous users = the highest step such that it and every step below it held.**

Some answers are part of the protocol, not errors, and do not count against the error
rate. Examples: a vote on a song that just started playing, a move under a row someone
else just removed, a grant of a scope that is already granted. They are counted
separately as `conflicts`. Any 5xx, any 401/403 where none is expected, and any timeout
is an error.

Requests go over REST, through the gateway, rather than over gRPC as the app does. The
gateway path is gateway → gRPC → handler, which is strictly more work than the app's
direct call, so the number is a conservative bound.

## Correctness under load

Speed means little if concurrent writes corrupt data, and V.2 asks for exactly this
guarantee (concurrent edits, concurrent votes). After every run, `loadtest/verify/verify.py`
checks the database:

| Invariant | What it proves |
|---|---|
| playlist `revision` == number of ops, and ops are numbered 1..revision with no gap or repeat | the row lock in `BumpPlaylistRevision` serializes concurrent edits (`docs/annex/data-model.md` §13) |
| playlist `song_count` == rows; no two rows of a playlist at the same position | counters and positions move in the same transaction as the edit |
| queue entry `vote_count` == vote rows; one vote per user per entry | the vote counter and its unique index hold under concurrent votes |
| at most one live control licence per device, grantee and scope | `device_control_licenses_one_live_per_scope` under grant churn |
| revisions gained == playlist edits k6 got a 200 for; votes gained == votes k6 saw accepted | no acknowledged write is lost, and none is applied twice |

## Running it

Docker only. Nothing else is needed on the host.

```bash
make loadtest                                   # mixed, small budget, the full ramp (~15 min)
make loadtest LT_PROFILE=medium
make loadtest SCENARIO=playlist_editor          # one service alone
make loadtest SCENARIO=login STEPS=1,2,4,8,16   # logins per second
make loadtest STEPS=100,200 HOLD=1m             # a quicker look
make loadtest LT_DB_PARAMS='&pool_max_conns=20' # a tuning knob
make loadtest-down                              # stop it, drop its volumes
```

Each run re-seeds the load-test database: the demo world plus `N` (default 1000)
load-test users, with groups, grants and sessions (`backend/cmd/seed/loadtest.go`). It
then snapshots the counters, runs k6 with a live dashboard on http://localhost:5665
while `loadtest/stats.sh` samples `docker stats`, and finally runs the checks above.
Everything lands in `loadtest/results/<date>-<scenario>-<profile>/`:

| File | What |
|---|---|
| `steps.md` | the per-step table and the answer |
| `report.html` | k6's full report: latency over time, per request |
| `verify.txt` | the invariants after the run |
| `docker-stats.csv` | CPU and memory of every container, every 5 s |
| `env.txt` | host, budget, settings, git revision |
| `summary.json` | everything k6 measured |

At the evaluation, `make loadtest-demo` runs on the main stack instead: 100 bots vote in
"Friday Warm-up — Live" while Alex has that event open on the phone, so the queue
reorders on screen with the dashboard next to it. The rate limit is on there: 100 bots
make about 27 req/s from one address, under the 100 allowed. Past ~350 bots
(`DEMO_VUS`), raise `APP_RATE_LIMIT_RPS` in `.env` first.

## Results

> The numbers that count are the ones measured on the evaluation machine, or on an
> x86_64 Linux machine like it, with `env.txt` attached. A first run on a development
> Mac is below; Docker Desktop runs containers in a VM, so it is an indication only.

### First measurements (2026-10-11, development Mac)

Host: Apple M1 Pro, Docker Desktop (Linux VM, 8 CPUs, 9.7 GB). Server containers on cores
0–3, k6 on 4–7. Scenario `mixed` (60 % Track Vote, 30 % Playlist Editor, 10 % Control
Delegation). Every run passed the correctness checks.

> **These runs seeded 20 accounts, not 1,000.** A Makefile bug (an earlier `N ?= 20`
> for `activity-logs` won over the load test's `N ?= 1000`; `env.txt` says "users
> seeded: 20") gave them 1 event and 2 playlists, with up to 40 VUs per account. The
> CPU findings stand: every request still ran its Check. But contention was higher
> than declared, and the user count is VUs, not distinct people. Fixed 2026-10-12;
> runs from then on seed `N` accounts.

| Run | Budget | Steps | Max users with the SLO held | First step that broke |
|---|---|---|---|---|
| `mixed-small` | small, as declared (OpenFGA 0.25 vCPU) | 25 → 800 | **200** (78 req/s, read p95 60 ms) | 400: 33 % errors, p95 3.3 s |
| `mixed-small-fga075` | small, rebalanced: backend 0.5, OpenFGA 0.75 (same 2 vCPU) | 100 → 600 | **≥ 600**, top step tested (222 req/s, read p95 9 ms) | none reached |
| `mixed-medium` | medium (OpenFGA 0.5 vCPU) | 25 → 800 | **≥ 800**, top step tested (293 req/s, read p95 107 ms) | none reached |
| `mixed-medium`, cold jump | medium, started straight at 200 VUs | 200 → 1000 | **none** | 200: 8 % errors, p95 2 s |

The small budget as first declared (`mixed-small`):

| VUs | req/s | errors | read p95 (ms) | write p95 (ms) | SLO |
|----:|------:|-------:|--------------:|---------------:|:---:|
| 25 | 9.8 | 0.00% | 15 | 79 | held |
| 50 | 19.4 | 0.00% | 15 | 51 | held |
| 100 | 39.2 | 0.00% | 14 | 65 | held |
| 200 | 78.2 | 0.00% | 60 | 95 | held |
| 400 | 90.4 | 32.92% | 3340 | 3695 | BROKE |
| 800 | 165.8 | 79.00% | 2523 | 3373 | BROKE |

Peak CPU per container during each hold, as a share of one core. Under `small` OpenFGA
was capped at 25 % and the backend at 100 %:

| VUs | backend | postgres | openfga | openfga-postgres |
|----:|--------:|---------:|--------:|-----------------:|
| 100 | 11 % | 6 % | 16 % | 7 % |
| 200 | 16 % | 11 % | **25 %** | 9 % |
| 400 | 21 % | 12 % | **27 %** | 10 % |
| 800 | 29 % | 15 % | **27 %** | 14 % |

**Even when overloaded, the data stayed correct.** At 800 VUs with 79 % of requests
failing, every invariant held, and the database's totals matched exactly what k6 saw
succeed (1,215 playlist edits, 3,285 votes). Overload made requests slow or refused, but
none was half-applied.

**Before that, the check found a real bug.** On the first run the invariant
`vote_count == vote rows` failed for one entry: 6 counted, 7 rows. `CastQueueVote` wrote
the vote row unconditionally in a CTE but counted it only if the entry was still
`queued`. So a vote for a song that had just started playing was answered
`accepted=false` *and* stored. It happens without any concurrency (any vote on a
playing song), and the load test exposed it because hosts start songs while hundreds of
people vote. It is fixed in `db/query/events.sql`, with a regression test in
`tests/track_vote/test_vote_on_unqueued_entry.py` that fails on the old query.

### After the fixes (2026-10-12, same Mac)

Same host and scenario, with the five changes under "Why each Check cost more than it
should" applied, and 1,000 accounts seeded (20 events, 100 playlists) unless the row
says otherwise. One run per row; each passed the correctness checks.

| Run | Budget | Steps | Max users with the SLO held | First step that broke |
|---|---|---|---|---|
| `mixed-small-fixes` | small (backend 0.5, OpenFGA 0.75) | 100 → 1000 | **≥ 1000**, top step tested (393 req/s, read p95 8 ms) | none reached |
| `mixed-small-fixes-nocache` | the same, check cache off | 100 → 1000 | **800** (311 req/s, read p95 102 ms) | 1000: 21 % errors, p95 3.4 s |
| `mixed-small-fixes-knee` | small, 1,600 accounts | 400 → 1600 | **1000** (393 req/s, read p95 20 ms) | 1200: 0 % errors, read p95 343 ms |
| `mixed-medium-fixes-knee` | medium, 1,600 accounts | 400 → 1600 | **1000** (392 req/s, read p95 41 ms) | 1200: read p95 800 ms; 1400: 16 % errors |
| `mixed-medium-fixes-cold` | medium, started straight at 200 VUs | 200 → 1000 | **≥ 1000**, top step tested (393 req/s, read p95 15 ms) | none reached |
| `mixed-medium-fixes-cold-n20` | the same, on the 2026-10-11 world (`N=20`) | 200 → 1000 | **≥ 1000**, top step tested (368 req/s, read p95 6 ms) | none reached |

The rebalanced `small`, cache on (`mixed-small-fixes`):

| VUs | req/s | errors | read p95 (ms) | write p95 (ms) | SLO |
|----:|------:|-------:|--------------:|---------------:|:---:|
| 100 | 39.5 | 0.00% | 9 | 16 | held |
| 200 | 78.8 | 0.00% | 6 | 10 | held |
| 400 | 156.6 | 0.00% | 4 | 8 | held |
| 600 | 235.4 | 0.00% | 4 | 8 | held |
| 800 | 314.1 | 0.00% | 5 | 10 | held |
| 1000 | 393.0 | 0.00% | 8 | 13 | held |

Mean CPU during each hold, as a share of one core (backend and postgres from the
cache-on run). Under `small`, OpenFGA is capped at 75 % and the backend at 50 %:

| VUs | backend | postgres | openfga, cache on | openfga, cache off | openfga-postgres, on / off |
|----:|--------:|---------:|------------------:|-------------------:|---------------------------:|
| 400 | 18 % | 12 % | 19 % | 27 % | 5 % / 12 % |
| 600 | 26 % | 18 % | 26 % | 38 % | 7 % / 18 % |
| 800 | 35 % | 25 % | 35 % | 52 % | 9 % / 24 % |
| 1000 | **42 %** | 29 % | 43 % | **70 %** (peaks 76 %) | 11 % / 17 % |

The same numbers per unit of traffic, CPU per 100 req/s at 600 VUs, against the
2026-10-11 run with the same budget (`mixed-small-fga075`, 20 accounts):

| | backend | postgres | openfga | openfga-postgres |
|---|---:|---:|---:|---:|
| 2026-10-11, before the fixes | 15 % | 9 % | 18 % | 8 % |
| 2026-10-12, fixes, cache off | 11 % | 8 % | 16 % | 8 % |
| 2026-10-12, fixes, cache on | 11 % | 8 % | **11 %** | **3 %** |

The two 2026-10-12 rows differ only by the cache, so that comparison is exact. The first
row seeded 20 accounts, so its gap to the others mixes the fixes with a different data
set; read it as a direction, not a measurement.

## Where it breaks

What to look at when a step breaks, with the suspects we expected before measuring.
Each is confirmed or ruled out with `docker-stats.csv`; the measurements below settle
the first round:

1. **The backend's pgx pool.** `pgxpool.New` keeps its default size, max(4,
   `runtime.NumCPU()`), and `NumCPU` follows the cpuset, not the CPU cap. Every
   authenticated request takes a connection for the session lookup, another for the
   public-id resolution, and one more, asynchronously, for its activity-log row. If the
   backend's CPU is not saturated but latency climbs, the pool is the queue. To test
   it: `LT_DB_PARAMS='&pool_max_conns=20'`.
2. **OpenFGA** (confirmed, see below). Every request runs a `Check` over HTTP, with a
   2 s timeout. Under the first `small` split (0.25 vCPU), it was the first CPU to
   saturate.
3. **Postgres writes.** Playlist edits serialize on the playlist's row (by design), so
   ten editors on one playlist queue behind each other. That shows as write p95 rising
   while reads stay flat.
4. **The backend's CPU.** JSON ⇄ protobuf in the gateway, plus TLS-free HTTP.

### What the measurements say

**On 2026-10-11, OpenFGA was the bottleneck, by a wide margin.** Every authenticated
request runs at least one `Check`, so OpenFGA's CPU grows with the request rate. Under the
`small` budget it hit its 0.25 vCPU cap at 200 VUs and stayed pinned, while the backend
never passed 30 % of its core. Past the cap, Checks queue up beyond the backend's 2 s
timeout, and the interceptor denies what it cannot check. That is the 3 s p95 and the
error rate at 400 VUs.

**One rebalancing, inside the same budget, triples the number.** Moving 0.5 vCPU from
the backend (idle) to OpenFGA (saturated) took `small` from 200 to at least 600
simultaneous users, with p95 down from 60 ms to under 10 ms. The total is still 2 vCPU,
so the honest figure for "a 2 vCPU server" is the rebalanced one. The lesson for
deployment: give the permission service a CPU share proportional to traffic, not the
leftover.

**A cold burst is worse than a ramp.** `medium` has twice the first `small`'s OpenFGA CPU and
held 800 users when ramped up, yet failed every step when hit with 200 users at once
on a freshly started OpenFGA. Once Checks pass the 2 s timeout, the backend gives up on
them but OpenFGA still does the work, so the backlog never drains. People opening the
app together when an event starts is exactly this case.

**After the fixes (2026-10-12), the check cache is what moved the numbers.**
- **The cache.** With it on, `small` holds 1,000 users at a p95 of 13 ms. With only the
  cache off, the same run breaks at 1,000, OpenFGA pinned at its cap again. That is the
  same mechanism as before, one step further. OpenFGA's CPU per request drops by a third
  and openfga-postgres's by 60 %. The app polls the same (user, object) pairs every 5 s,
  so most Checks repeat an answer that is still in the cache.
- **The other fixes, measured.** The pinned model id, the connection pool and no retries
  lower OpenFGA's CPU by under 10 %, a figure that also mixes in the change of data
  set (20 → 1,000 accounts). They are worth keeping for correctness and
  predictability, not for speed.
- **The cold burst no longer collapses.** That holds on both worlds, the 1,000-account
  one and the 2026-10-11 one (`N=20`), from the first step to the last. Nothing about the
  burst itself changed: OpenFGA now has enough headroom that no backlog forms. Past its
  cap, the old collapse comes back. In the cache-off run at 1,000, throughput *fell*
  from 311 to 219 req/s instead of levelling off. That is why load shedding (6) is still
  the first next step.
- **Both budgets now break between 1,000 and 1,200 users, for different reasons.**
  - **`small`: the backend.** It is pinned at its 0.5 vCPU from 1,200 on, while OpenFGA
    stays near 55 % of its 0.75. The rebalance squeezed the backend, and it is now the
    first to run out.
  - **`medium`: OpenFGA again.** Its OpenFGA has 0.5 vCPU, less than `small`'s, and sits
    at that cap from 1,200 on, with the backend under a quarter of its 2 vCPU.
  - **So `medium` does no better than `small`,** with almost twice the CPU. Its split is
    now the badly shaped one. Moving CPU from its backend to OpenFGA would raise its knee
    the way it raised `small`'s. It is left as declared for now.
- **How a budget fails depends on which container saturates.**
  - **A saturated backend only queues.** `small` past its knee: latency climbs (p95 343 ms,
    then 1.3 s, then 2.2 s), errors stay at 0 % and throughput holds near 400–450 req/s.
  - **A saturated OpenFGA turns into errors.** `medium` past its knee: checks miss the 2 s
    timeout and become denials (16 %, then 78 %), and throughput falls.
  - **That is the case for load shedding (6),** and for sizing OpenFGA with headroom.
    When it runs short, users see failures, not slowness.

### Why each Check cost more than it should

More CPU moves the knee. These changes lower what one Check costs. They were made after
the 2026-10-11 runs and measured on 2026-10-12 (Results, "After the fixes"): the cache (5)
does nearly all of the work, and 2–4 are hygiene more than speed. Each is commented
where it lives.

1. **The budget is rebalanced.** `small` now gives OpenFGA 0.75 vCPU and the backend 0.5
   (Makefile). This is the split measured at ≥ 600.
2. **The images are pinned** (`openfga:v1.18.3`, `cli:v0.7.20`). A result now names a
   server version, and the backend matches one of that server's error messages.
3. **The model id is pinned at boot.** Without one, OpenFGA looks up the latest model on
   every Check (`authz.Client.Ping`). `make fga-model` now restarts the backend so it pins
   the new model.
4. **The Go SDK's defaults are overridden.** It retried every failed call 3 times, which
   contradicts our own fail-closed design and multiplies the load on an overloaded server.
   It also kept only 2 idle connections, so under load most Checks opened a new TCP
   connection (`authz.NewClient`).
5. **OpenFGA's check cache is on, with its cache controller** (`docker-compose.yaml`).
   - The app polls the same (user, object) every 5 s, so most checks repeat a recent
     answer.
   - The trade-off is eventual consistency. The controller clears cached entries once a
     tuple write lands, so a revocation takes effect after about 1–2 s, on top of the
     outbox lag that already exists (measured: a revoked public playlist still read as
     visible for 1.2 to 1.8 s). `FGA_CHECK_CACHE=false` turns it off. The API test suite
     runs with the cache off (`API_TEST_FGA_CACHE`), because two of its tests read
     straight after revoking.
   - For the cache to hit at all, the backend now sends `current_time` only to the checks
     whose condition reads it, truncated to the minute (`authz.NeedsRequestTime`). Before,
     a per-second timestamp on every check made every cache key unique.

The Go runtime was ruled out. OpenFGA v1.18.3 is built with Go 1.26, which sizes
`GOMAXPROCS` to the container's CPU cap by itself.

### Next steps

Each one costs more than the last:

- **(6) Load shedding in the interceptor.** Cap concurrent Checks and fail fast with
  `Unavailable` when the cap is reached. Use a Check timeout shorter than 2 s. The cache
  ended the cold burst below the knee, but past OpenFGA's cap the backlog still forms
  and throughput falls (cache-off run, 1,000 VUs). With shedding, a peak gives quick
  refusals that clients retry, not a backlog. It adds no capacity.
- **(7) Drop the redundant checks.**
  - `CastVote` checks `event#can_vote` and then `queue_entry#can_vote`, which recomputes
    the first. Checking the entry, and scoping the vote query by both ids, would do.
  - `GetPlaylist`'s two questions (view, then edit) could go in one `BatchCheck`.
  - This halves the checks on the hottest write, but moves one rule from the graph to SQL.
- **(8) A decision cache in the backend.** A short TTL, plus `singleflight` so that 50
  voters asking the same question share one Check. A hit never leaves the process. It is
  a second layer of staleness and needs a security review.
- **(9) gRPC instead of HTTP to OpenFGA.** No JSON, and no gateway hop inside OpenFGA. It
  means rewriting `authz.Client` without the SDK, for a smaller gain than 3–5.
- **(10) Several OpenFGA replicas behind a load balancer.** OpenFGA is stateless, so it
  scales out. But replicas only help with more cores, not inside a fixed budget, and
  `openfga-postgres` is next in line.

(6) and (7) are in reach. (9) and (10) go beyond what V.7 asks, which is a number
coherent with a declared server, not the highest one. The load mix also leaves out
`ListPlaylists`/`GetMusicEvents`, which call OpenFGA's `ListObjects` (its most expensive
call). Real-world capacity is lower than these numbers until a scenario includes them.

**An outbox claim that ran for 48 minutes (open).** Twice on 2026-10-12, the seed's
`-loadtest 1000` stalled. It had queued 11,463 permission changes in one transaction
and was delivering them inline, one by one. Thirty seconds in, they fell due, and the
backend's outbox worker started a `ClaimTupleChanges`. That single `UPDATE` ran on CPU
for 48 minutes (Postgres 16, 0.5 vCPU), holding its rows' locks. Every inline
`DeleteTupleChange` behind it timed out, so the seed cleared one row per 3 s.
`pg_cancel_backend` on the claim emptied the table in under a minute.
- **Not the cause: stale statistics.** `EXPLAIN` on the same shape, with statistics from
  a near-empty table, still picks the index anti-join.
- **Not reproduced:** a plain race. In a scratch Postgres 16 at 0.5 vCPU, the claim
  takes 0.7 ms on 11k rows, with another session deleting them one by one. Whatever made
  the real one run for 48 minutes is in what that simulation leaves out: the seed's
  other writes, the 1 s re-claims, the OpenFGA calls between them.
- **The workaround:** `make loadtest-seed` now stops the backend while it seeds, after
  which the seed takes 47 s.
- **In production,** the same race needs one request that enqueues more changes than it
  can deliver inline within the 30 s grace. The largest today is creating an event from a
  playlist, one change per song (`event.Repository`): hundreds, so seconds, not 30 s.
  Next: reproduce it against the real seed with the backend up (the old `loadtest-seed`),
  logging the claim's duration. Then consider claiming in two statements
  (select the ids, then update them), or a `statement_timeout` on the claim so that a
  runaway frees its locks.

Not yet measured: the same runs on the evaluation's x86_64 machine, the knee between
1,000 and 1,200 at a finer step, and `medium` with its CPU moved to OpenFGA.

## Limits of the method

- **Polling, not streaming.** The VUs poll every 5 s, as the app did when these runs were
  made. The app now holds gRPC Watch streams open instead (`WatchPlaylist`, `WatchEvent`),
  which k6 over REST does not exercise. Streaming needs its own scenario: open connections
  held, and the delay from a write to the other clients.
- **One machine.** On the evaluation machine, k6 and the server share the host, on
  separate cores. A second machine for k6 removes that doubt.
- **REST, not gRPC.** As a bound this is conservative (see Method). k6 can speak gRPC
  through the server's reflection if the exact app path is ever needed.
- **Login is measured apart.** Its limit is memory (64 MiB per concurrent login), so
  under the `small` budget it is a handful of concurrent logins. It is also the one
  scenario the rebalanced `small` hurts: Argon2 runs on the backend, which now has 0.5
  vCPU (`LT_BACKEND_CPUS=1` for the first split). That is a deliberate
  security trade-off, not a defect to tune away.
