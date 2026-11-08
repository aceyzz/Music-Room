//go:build integration

// CreateFromOAuth against a real Postgres. Run with
// `make docker-backend-test-integration`.
//
// It used to insert only the users row: no user_profiles row and, worse, no
// OpenFGA tuples, so an account created by signing in with Google or 42 got
// NOT_FOUND on its own profile (can_view_profile) and PERMISSION_DENIED on
// every edit (can_edit_profile). This pins both halves of the fix.
//
// Unlike profile_integration_test.go this cannot run inside a rolled-back
// transaction: the repository opens and commits its own. The user row is
// deleted afterwards instead (user_profiles cascades), and the outbox row is
// gone already, since a successful delivery deletes it.
package user

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	appdb "example.com/music-app/db"
	sqlc "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

// recordingApplier stands in for OpenFGA: the test is about what the
// repository asks to write, not about OpenFGA accepting it.
type recordingApplier struct {
	mu      sync.Mutex
	changes []authz.Change
}

func (a *recordingApplier) Apply(_ context.Context, change authz.Change) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.changes = append(a.changes, change)
	return nil
}

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("APP_DATABASE_URL")
	if url == "" {
		t.Fatal("APP_DATABASE_URL non defini")
	}

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

func TestCreateFromOAuthWritesProfileAndTuples(t *testing.T) {
	ctx := context.Background()
	pool := testPool(t)
	applier := &recordingApplier{}
	repo := NewRepository(pool, outbox.New(applier))

	stamp := time.Now().UnixNano()
	creds, err := repo.CreateFromOAuth(ctx,
		fmt.Sprintf("oauth-it-%d", stamp), fmt.Sprintf("oauth-it-%d@example.test", stamp), true)
	if err != nil {
		t.Fatalf("CreateFromOAuth: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), "DELETE FROM users WHERE id = $1", creds.ID)
	})

	if !creds.EmailVerified {
		t.Error("EmailVerified: got false, want true (the provider verified it)")
	}

	if _, err := sqlc.New(pool).GetUserProfile(ctx, creds.ID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			t.Fatal("no user_profiles row for the OAuth account")
		}
		t.Fatalf("GetUserProfile: %v", err)
	}

	want := authz.NewUser(creds.PublicID)
	applier.mu.Lock()
	defer applier.mu.Unlock()
	if len(applier.changes) != 1 {
		t.Fatalf("applied changes: got %d, want 1 (%+v)", len(applier.changes), applier.changes)
	}
	got := applier.changes[0]
	if got.ObjectKey != want.ObjectKey || got.Origin != want.Origin ||
		len(got.Writes) != len(want.Writes) {
		t.Fatalf("change: got %+v, want %+v", got, want)
	}
	for i := range want.Writes {
		if got.Writes[i] != want.Writes[i] {
			t.Errorf("write %d: got %+v, want %+v", i, got.Writes[i], want.Writes[i])
		}
	}
}
