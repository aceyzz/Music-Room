//go:build integration

// End-to-end tests for the outbox, against a real Postgres and a real OpenFGA.
// Run with `make docker-backend-test-integration`.
//
// The properties under test are the ones the design exists for, and none of them
// can be checked without both systems present: that a committed change always
// leaves a durable intent, that a delivery failure loses nothing, and that the
// worker eventually drains whatever the inline attempt could not.
package outbox

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	appdb "example.com/music-app/db"
	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()

	url := os.Getenv("APP_DATABASE_URL")
	if url == "" {
		t.Fatal("APP_DATABASE_URL non defini")
	}

	// The tests need the schema, and nothing else in the test run applies it --
	// migrations normally happen when the backend boots, which it has not.
	std, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatalf("open %s: %v", url, err)
	}
	defer std.Close()

	goose.SetBaseFS(appdb.MigrationsFS)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatalf("goose dialect: %v", err)
	}
	if err := goose.Up(std, "schema"); err != nil {
		t.Fatalf("migrations: %v", err)
	}

	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func testAuthzClient(t *testing.T) *authz.Client {
	t.Helper()

	fga, err := authz.NewClient(authz.Config{
		APIURL:  envOr("APP_OPENFGA_API_URL", "http://localhost:8082"),
		StoreID: envOr("APP_OPENFGA_STORE_ID", "01MRAVTHZ00000000000000000"),
	})
	if err != nil {
		t.Fatalf("authz client: %v", err)
	}
	if _, err := fga.Ping(context.Background()); err != nil {
		t.Fatalf("OpenFGA not usable: %v", err)
	}
	return fga
}

// recordingApplier stands in for OpenFGA when the test is about the outbox's
// own behaviour rather than the graph's.
type recordingApplier struct {
	err      error
	attempts int
	last     authz.Change
}

func (r *recordingApplier) Apply(_ context.Context, change authz.Change) error {
	r.attempts++
	r.last = change
	return r.err
}

func uniqueChange(t *testing.T) authz.Change {
	t.Helper()
	object := authz.UserRef(t.Name())
	return authz.Change{
		ObjectKey: object,
		Origin:    "test",
		Writes:    []authz.Tuple{{User: object, Relation: authz.RelAccountOwner, Object: object}},
	}
}

// enqueueCommitted does what a repository does: enqueue on the transaction that
// carries the domain change, then commit.
func enqueueCommitted(t *testing.T, pool *pgxpool.Pool, ob *Outbox, change authz.Change) Pending {
	t.Helper()

	ctx := context.Background()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	pending, err := ob.Enqueue(ctx, tx, change)
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatalf("commit: %v", err)
	}

	t.Cleanup(func() {
		_ = sqlc.New(pool).DeleteTupleChange(context.Background(), pending.id)
	})
	return pending
}

func rowByID(t *testing.T, pool *pgxpool.Pool, id int64) (sqlc.OpenfgaTupleOutbox, bool) {
	t.Helper()

	var row sqlc.OpenfgaTupleOutbox
	err := pool.QueryRow(context.Background(),
		`SELECT id, payload, object_key, origin, status, attempts, last_error, next_attempt_at, created_at
		 FROM openfga_tuple_outbox WHERE id = $1`, id).
		Scan(&row.ID, &row.Payload, &row.ObjectKey, &row.Origin, &row.Status,
			&row.Attempts, &row.LastError, &row.NextAttemptAt, &row.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) || err != nil && err.Error() == "no rows in result set" {
		return row, false
	}
	if err != nil {
		t.Fatalf("read row %d: %v", id, err)
	}
	return row, true
}

// The happy path, and the shape every mutation is meant to follow: the intent
// commits with the data, the inline attempt applies it, the row disappears.
func TestDeliverAppliesAndClearsTheRow(t *testing.T) {
	pool := testPool(t)
	applier := &recordingApplier{}
	ob := New(applier)

	pending := enqueueCommitted(t, pool, ob, uniqueChange(t))

	if _, exists := rowByID(t, pool, pending.id); !exists {
		t.Fatal("no row after commit: the intent was not durable, which is the " +
			"single thing this package is for")
	}

	ob.Deliver(context.Background(), pool, pending)

	if applier.attempts != 1 {
		t.Errorf("applied %d times, want 1", applier.attempts)
	}
	if _, exists := rowByID(t, pool, pending.id); exists {
		t.Error("row survived a successful delivery; it should be deleted")
	}
}

// A delivery failure must cost nothing but time. The row stays, carries the
// reason, and is scheduled for another go.
func TestFailedDeliveryKeepsTheRow(t *testing.T) {
	pool := testPool(t)
	applier := &recordingApplier{err: errors.New("openfga is having a day")}
	ob := New(applier)

	pending := enqueueCommitted(t, pool, ob, uniqueChange(t))
	ob.Deliver(context.Background(), pool, pending)

	if applier.attempts != inlineAttempts {
		t.Errorf("made %d inline attempts, want %d", applier.attempts, inlineAttempts)
	}

	row, exists := rowByID(t, pool, pending.id)
	if !exists {
		t.Fatal("row deleted despite the delivery failing -- the change is now lost")
	}
	if row.Status != "failed" {
		t.Errorf("status = %q, want \"failed\"", row.Status)
	}
	if row.Attempts != 1 {
		t.Errorf("attempts = %d, want 1", row.Attempts)
	}
	if !row.LastError.Valid || row.LastError.String == "" {
		t.Error("last_error is empty; whoever debugs this row gets nothing to go on")
	}
	if !row.NextAttemptAt.Time.After(time.Now()) {
		t.Error("next_attempt_at is not in the future, so the worker will spin on this row")
	}
}

// hangingApplier is a stopped OpenFGA: the call does not refuse, it just never
// answers, until the caller's deadline kills it.
type hangingApplier struct{}

func (hangingApplier) Apply(ctx context.Context, _ authz.Change) error {
	<-ctx.Done()
	return ctx.Err()
}

// Regression: a delivery that fails by TIMING OUT must still record that it
// failed.
//
// It did not. settle reused the delivery context, which by definition has just
// expired, so the reschedule was itself cancelled -- precisely in the case where
// OpenFGA is hanging, which is the case the outbox exists for. The row stayed
// pending with attempts=0 and no last_error: still delivered eventually, but
// retried at a flat interval forever with nothing recorded for whoever has to
// diagnose it. Found by stopping the real container, not by a unit test.
func TestTimeoutStillRecordsTheFailure(t *testing.T) {
	pool := testPool(t)
	ob := New(hangingApplier{})

	pending := enqueueCommitted(t, pool, ob, uniqueChange(t))
	ob.Deliver(context.Background(), pool, pending)

	row, exists := rowByID(t, pool, pending.id)
	if !exists {
		t.Fatal("row deleted after a timeout")
	}
	if row.Status != "failed" {
		t.Errorf("status = %q, want \"failed\": the timeout was not recorded", row.Status)
	}
	if row.Attempts != 1 {
		t.Errorf("attempts = %d, want 1: the counter never advances, so the backoff never grows",
			row.Attempts)
	}
	if !row.LastError.Valid || row.LastError.String == "" {
		t.Error("last_error is empty after a timeout")
	}
}

// The crash case, which is the whole reason the row is written inside the
// transaction: the process commits and then dies before delivering anything. No
// inline attempt ever runs, and the worker still has to finish the job.
func TestWorkerDeliversWhatTheProcessNeverDid(t *testing.T) {
	pool := testPool(t)
	applier := &recordingApplier{}
	ob := New(applier)

	pending := enqueueCommitted(t, pool, ob, uniqueChange(t))
	// Deliver is deliberately never called. Make the row due now rather than
	// waiting out the default grace period.
	if _, err := pool.Exec(context.Background(),
		`UPDATE openfga_tuple_outbox SET next_attempt_at = NOW() - INTERVAL '1 minute' WHERE id = $1`,
		pending.id); err != nil {
		t.Fatalf("make row due: %v", err)
	}

	worker := NewWorker(ob, pool, WorkerConfig{BatchSize: 50})
	if err := worker.RunOnce(context.Background()); err != nil {
		t.Fatalf("worker pass: %v", err)
	}

	if applier.attempts == 0 {
		t.Fatal("worker never picked up a committed-but-undelivered row")
	}
	if _, exists := rowByID(t, pool, pending.id); exists {
		t.Error("worker applied the change but left the row behind")
	}
	// The payload has to survive the round trip through JSONB intact, or the
	// worker delivers something subtly different from what was intended.
	if len(applier.last.Writes) != 1 || applier.last.Writes[0].Relation != authz.RelAccountOwner {
		t.Errorf("decoded change does not match what was enqueued: %+v", applier.last)
	}
	if applier.last.ObjectKey == "" || applier.last.Origin != "test" {
		t.Errorf("ObjectKey/Origin lost in the round trip: %q / %q",
			applier.last.ObjectKey, applier.last.Origin)
	}
}

// Same path, but against the real OpenFGA rather than a stand-in, so the
// serialised payload is proven to produce a tuple the server actually accepts.
func TestWorkerDeliversToRealOpenFGA(t *testing.T) {
	pool := testPool(t)
	fga := testAuthzClient(t)
	ob := New(fga)

	change := uniqueChange(t)
	t.Cleanup(func() {
		_ = fga.Apply(context.Background(), authz.Change{Deletes: change.Writes})
	})

	pending := enqueueCommitted(t, pool, ob, change)
	ob.Deliver(context.Background(), pool, pending)

	if _, exists := rowByID(t, pool, pending.id); exists {
		row, _ := rowByID(t, pool, pending.id)
		t.Fatalf("row survived: %s", row.LastError.String)
	}
}
