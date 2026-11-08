# Load testing: how-to

Only Docker is needed. Full method: [`docs/load-testing.md`](../docs/load-testing.md).

## Run

```bash
make loadtest                                   # mixed scenario, small budget, ~15 min
make loadtest LT_PROFILE=medium                 # bigger budget (4 vCPU)
make loadtest SCENARIO=playlist_editor          # also: track_vote, delegation, login
make loadtest STEPS=100,200 HOLD=1m             # shorter ramp
make loadtest LT_FGA_CPUS=0.25 LT_BACKEND_CPUS=1 LT_LABEL=first     # move CPU within a budget
make loadtest FGA_CHECK_CACHE=false LT_LABEL=nocache                 # OpenFGA check cache off
make loadtest-down                              # stop the stack, drop its volumes
```

A run re-seeds its own stack (`music-room-lt`, separate from the dev stack). It ramps up
virtual users while the live dashboard is on http://localhost:5665, then checks the
database stayed consistent.

Output goes to `results/<date>-<scenario>-<profile>/`. Read `steps.md` first: it says
which load steps held and gives the max number of users. `verify.txt` holds the
consistency checks, and `docker-stats.csv` shows which container saturated.

**Eval demo:** `make loadtest-demo` runs on the main stack. 100 bots vote in
"Friday Warm-up — Live" while the phone (:6080) shows that event.

## Tests

```bash
make docker-api-test                                      # full Python API suite, in a container
make docker-api-test PYTEST_ARGS="tests/track_vote -x"    # one folder
```

## Findings (dev Mac, indicative only)

The 2026-10-11 runs seeded 20 accounts, not 1,000. A Makefile `N` collision, fixed on
2026-10-12, caused it. Details are in the doc.

| Budget | 2026-10-11 | 2026-10-12, after the fixes |
|---|---|---|
| small, 2 vCPU, first split (backend 1, OpenFGA 0.25) | 200 | — |
| small, 2 vCPU, rebalanced (backend 0.5, OpenFGA 0.75), the default | ≥ 600 | 1000 (breaks at 1200: backend CPU, latency only) |
| small, rebalanced, OpenFGA check cache off | — | 800 |
| medium, 4 vCPU, ramped | ≥ 800 | 1000 (breaks at 1200: OpenFGA CPU, then errors) |
| medium, hit with 200 users at once on a fresh stack | none (8 % errors at 200) | ≥ 1000, on either data set |

- **OpenFGA was the bottleneck.** It runs a permission check on every request. Giving it
  CPU from the idle backend tripled the number within the same budget.
- **The check cache did most of the rest.** The app re-asks the same questions every 5 s,
  so OpenFGA's CPU per request fell by a third, and its database's by 60 %. With the
  cache off, OpenFGA hits its cap again at 1,000 users. The pinned model id, the
  connection pool and no SDK retries gain under 10 %. The cost: a revoked permission can
  still read as allowed for about 1–2 s.
- **The cold-burst collapse is gone** below the knee. Past it, the collapse comes back:
  throughput falls instead of levelling off. Load shedding is the next fix.
- **Both budgets now break between 1,000 and 1,200 users.** `small` runs out of backend
  CPU, and only latency suffers (0 % errors). `medium` runs out of OpenFGA CPU (it gives
  OpenFGA 0.5 vCPU, less than `small`), and it fails with errors, as before. With almost
  twice the CPU, `medium` does no better: its split is the one to fix now.
- **Data stays consistent under overload**, even at 79 % errors: every invariant held,
  in every run.
- **Bugs found:**
  - **Fixed:** a vote on a song that was already playing was stored but not counted
    (`CastQueueVote`, `db/query/events.sql`). The regression test is
    `tests/track_vote/test_vote_on_unqueued_entry.py`.
  - **Worked around:** the seed stalled for 50 minutes when the backend's outbox worker
    raced it. The cause is still open; `make loadtest-seed` now stops the backend while
    it seeds.
- **Next steps:** load shedding, then fewer checks per request, then the outbox claim. The
  list is in [`docs/load-testing.md`](../docs/load-testing.md#next-steps).
- **Still to do:** rerun on an x86_64 Linux machine like the eval's.
