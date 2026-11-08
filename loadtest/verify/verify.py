"""Correctness under load: after a k6 run, check in the database that the
concurrent writes left everything consistent -- the half of V.7 a latency table
cannot show. Run by `make loadtest`; the image is tests/Dockerfile.

    verify.py snapshot <file>              before the run: the counters to diff
    verify.py check <file> <summary.json>  after: invariants, and the diff
                                           against what k6 saw succeed

Only the load-test world is checked (public ids starting 10ad, see
backend/cmd/seed/loadtest.go), plus the demo event the demo bots vote in.

The invariants, and the mechanism each one proves:

  playlists  revision == number of ops, and the ops are numbered 1..revision
             with no gap or repeat           BumpPlaylistRevision's row lock
             song_count == rows              the counter moves in the same tx
             no two rows share a position    the position arithmetic
  votes      vote_count == vote rows         the counter moves in the same tx
             one vote per user per entry     the unique index
  grants     at most one live licence per    device_control_licenses_one_live_per_scope
             device, grantee and scope
  totals     revisions gained == mutations k6 got a 200 for
             votes gained == votes k6 saw accepted

More stored than k6 counted is printed as a warning, with the numbers: it is
either a request that committed after k6 gave up on it (a client timeout) or a
write the server stored while answering that it refused it -- the latter is how
the CastQueueVote bug (db/query/events.sql) showed up. Fewer is a failure.
"""

import json
import os
import sys

import psycopg2

DSN = os.environ["DATABASE_URL"]
FIXTURES = os.environ.get("FIXTURES", "loadtest/fixtures.json")

LOAD = "public_id::text LIKE '10ad%%'"


def demo_event():
    try:
        with open(FIXTURES) as f:
            return json.load(f).get("demoEvent") or ""
    except FileNotFoundError:
        return ""


def counters(cur):
    cur.execute(f"SELECT COALESCE(SUM(revision), 0) FROM playlists WHERE {LOAD}")
    revisions = int(cur.fetchone()[0])
    cur.execute(
        f"""SELECT COUNT(*) FROM event_queue_votes v
            JOIN event_queue_entries q ON q.id = v.queue_entry_id
            JOIN events e ON e.id = q.event_id
            WHERE e.{LOAD} OR e.public_id::text = %s""",
        (demo_event(),),
    )
    votes = int(cur.fetchone()[0])
    return {"revisions": revisions, "votes": votes}


def invariants(cur):
    """Each query returns the offending rows; none is the pass."""
    checks = [
        (
            "playlist revision == number of ops",
            f"""SELECT p.public_id, p.revision, COUNT(o.id) FROM playlists p
                LEFT JOIN playlist_ops o ON o.playlist_id = p.id
                WHERE p.{LOAD} GROUP BY p.id HAVING p.revision <> COUNT(o.id)""",
        ),
        (
            "playlist ops numbered 1..revision, no gap or repeat",
            f"""SELECT p.public_id, MIN(o.revision), MAX(o.revision), COUNT(DISTINCT o.revision), COUNT(*)
                FROM playlists p JOIN playlist_ops o ON o.playlist_id = p.id
                WHERE p.{LOAD} GROUP BY p.id
                HAVING MIN(o.revision) <> 1 OR MAX(o.revision) <> COUNT(*)
                    OR COUNT(DISTINCT o.revision) <> COUNT(*)""",
        ),
        (
            "playlist song_count == rows",
            f"""SELECT p.public_id, p.song_count, COUNT(s.id) FROM playlists p
                LEFT JOIN playlist_songs s ON s.playlist_id = p.id
                WHERE p.{LOAD} GROUP BY p.id HAVING p.song_count <> COUNT(s.id)""",
        ),
        (
            "no two rows of a playlist at the same position",
            f"""SELECT p.public_id, s.position, COUNT(*) FROM playlists p
                JOIN playlist_songs s ON s.playlist_id = p.id
                WHERE p.{LOAD} GROUP BY p.id, s.position HAVING COUNT(*) > 1""",
        ),
        (
            "queue entry vote_count == vote rows",
            f"""SELECT q.public_id, q.vote_count, COUNT(v.user_id) FROM event_queue_entries q
                JOIN events e ON e.id = q.event_id
                LEFT JOIN event_queue_votes v ON v.queue_entry_id = q.id
                WHERE e.{LOAD} OR e.public_id::text = %(demo)s
                GROUP BY q.id HAVING q.vote_count <> COUNT(v.user_id)""",
        ),
        (
            "one vote per user per queue entry",
            """SELECT queue_entry_id, user_id, COUNT(*) FROM event_queue_votes
                GROUP BY queue_entry_id, user_id HAVING COUNT(*) > 1""",
        ),
        (
            "at most one live control licence per device, grantee and scope",
            f"""SELECT d.public_id, l.grantee_user_id, l.event_id, COUNT(*) FROM device_control_licenses l
                JOIN devices d ON d.id = l.device_id
                WHERE d.{LOAD} AND l.revoked_at IS NULL AND (l.expires_at IS NULL OR l.expires_at > NOW())
                GROUP BY d.id, l.grantee_user_id, l.event_id HAVING COUNT(*) > 1""",
        ),
    ]
    failed = 0
    for name, sql in checks:
        cur.execute(sql, {"demo": demo_event()})
        rows = cur.fetchall()
        if rows:
            failed += 1
            print(f"  FAIL  {name}: {len(rows)} offending, e.g. {rows[:3]}")
        else:
            print(f"  ok    {name}")
    return failed


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("snapshot", "check"):
        sys.exit(__doc__)
    conn = psycopg2.connect(DSN)
    conn.set_session(readonly=True, autocommit=True)
    cur = conn.cursor()

    if sys.argv[1] == "snapshot":
        with open(sys.argv[2], "w") as f:
            json.dump(counters(cur), f)
        return

    with open(sys.argv[2]) as f:
        before = json.load(f)
    after = counters(cur)
    k6 = {}
    if len(sys.argv) > 3:
        with open(sys.argv[3]) as f:
            k6 = json.load(f).get("counters", {})

    print("Invariants after the run:")
    failed = invariants(cur)

    print("Totals, database against k6:")
    for label, key, k6key in (
        ("playlist revisions gained", "revisions", "playlist_mutations"),
        ("votes gained", "votes", "votes_accepted"),
    ):
        gained = after[key] - before[key]
        seen = k6.get(k6key)
        if seen is None:
            print(f"  -     {label}: {gained} (no k6 summary to compare)")
        elif gained == seen:
            print(f"  ok    {label}: {gained} == {k6key} {seen}")
        elif gained > seen:
            print(f"  WARN  {label}: {gained} > {k6key} {seen}: {gained - seen} stored without k6 "
                  f"counting them as accepted -- a client timeout, or the server storing a write "
                  f"it answered as refused (the CastQueueVote bug this check once found)")
        else:
            failed += 1
            print(f"  FAIL  {label}: {gained} < {k6key} {seen}: k6 saw successes the database lost")

    print("All consistent." if failed == 0 else f"{failed} check(s) FAILED.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
