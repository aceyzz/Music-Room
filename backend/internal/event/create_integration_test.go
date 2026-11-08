//go:build integration

// CreateEventSimple against a real Postgres: the planned times reach the row
// and come back in the DTO. Run with `make docker-backend-test-integration`.
//
// Everything happens in one transaction that is rolled back, so the run leaves
// no account or event behind.
package event

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"slices"
	"testing"
	"time"

	appdb "example.com/music-app/db"
	db "example.com/music-app/db/sqlc"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

func testQueries(t *testing.T) *db.Queries {
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

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	t.Cleanup(pool.Close)
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	t.Cleanup(func() { _ = tx.Rollback(ctx) })
	return db.New(tx)
}

func TestCreateEventStoresItsTimes(t *testing.T) {
	ctx := context.Background()
	queries := testQueries(t)

	stamp := time.Now().UnixNano()
	host, err := queries.CreateUser(ctx, db.CreateUserParams{
		DisplayName: fmt.Sprintf("event-it-%d", stamp),
		Email:       fmt.Sprintf("event-it-%d@example.test", stamp),
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	start := time.Now().Add(24 * time.Hour).Truncate(time.Second)
	startsAt, endsAt, err := eventWindow(start.Unix(), start.Add(3*time.Hour).Unix(), time.Now())
	if err != nil {
		t.Fatalf("eventWindow: %v", err)
	}
	insert := func(params db.CreateEventSimpleParams) db.Event {
		t.Helper()
		params.HostID = host.ID
		params.Visibility = db.ResourceVisibilityPublic
		params.VoteLicense = db.VoteLicenseEveryone
		created, err := queries.CreateEventSimple(ctx, params)
		if err != nil {
			t.Fatalf("insert: %v", err)
		}
		return created
	}

	dto := eventDTO(insert(db.CreateEventSimpleParams{Name: "Planned", StartsAt: startsAt, EndsAt: endsAt}))
	if dto.GetStartsAt() != start.Unix() || dto.GetEndsAt() != start.Add(3*time.Hour).Unix() {
		t.Errorf("got starts_at=%d ends_at=%d, want %d %d",
			dto.GetStartsAt(), dto.GetEndsAt(), start.Unix(), start.Add(3*time.Hour).Unix())
	}

	// Without times, as every event created before this field existed.
	dto = eventDTO(insert(db.CreateEventSimpleParams{Name: "Undated"}))
	if dto.GetStartsAt() != 0 || dto.GetEndsAt() != 0 {
		t.Errorf("undated: got starts_at=%d ends_at=%d, want 0", dto.GetStartsAt(), dto.GetEndsAt())
	}
}

// EndOverdueEvents: an event past its planned end where nothing plays is
// ended, started or not, and whether its music stopped long ago or just now;
// one still within it, one with no planned end, and one past it whose music
// still plays are left alone.
func TestEndOverdueEvents(t *testing.T) {
	ctx := context.Background()
	queries := testQueries(t)

	stamp := time.Now().UnixNano()
	host, err := queries.CreateUser(ctx, db.CreateUserParams{
		DisplayName: fmt.Sprintf("event-end-%d", stamp),
		Email:       fmt.Sprintf("event-end-%d@example.test", stamp),
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	create := func(name string, starts, ends time.Time, start bool) int64 {
		t.Helper()
		params := db.CreateEventSimpleParams{
			HostID: host.ID, Name: name,
			Visibility: db.ResourceVisibilityPublic, VoteLicense: db.VoteLicenseEveryone,
		}
		if !ends.IsZero() {
			params.StartsAt = pgtype.Timestamptz{Time: starts, Valid: true}
			params.EndsAt = pgtype.Timestamptz{Time: ends, Valid: true}
		}
		created, err := queries.CreateEventSimple(ctx, params)
		if err != nil {
			t.Fatalf("insert: %v", err)
		}
		if start {
			// What the host's first play does (playNext).
			if _, err := queries.MarkEventLive(ctx, created.ID); err != nil {
				t.Fatalf("start: %v", err)
			}
		}
		return created.ID
	}
	live := func(name string, starts, ends time.Time) int64 {
		t.Helper()
		return create(name, starts, ends, true)
	}
	now := time.Now()
	over := live("Over", now.Add(-3*time.Hour), now.Add(-time.Hour))
	running := live("Running", now.Add(-time.Hour), now.Add(time.Hour))
	undated := live("Undated", time.Time{}, time.Time{})
	playing := live("Playing", now.Add(-3*time.Hour), now.Add(-time.Hour))
	song, err := queries.UpsertSongFromDeezer(ctx, db.UpsertSongFromDeezerParams{
		DeezerSongID: stamp, Title: "Still on", DurationSeconds: 30, ArtistName: "Artist",
	})
	if err != nil {
		t.Fatalf("song: %v", err)
	}
	entry, err := queries.SuggestSongToQueue(ctx, db.SuggestSongToQueueParams{
		EventID: playing, SongID: song.ID, SuggestedByID: host.ID,
	})
	if err != nil {
		t.Fatalf("suggest: %v", err)
	}
	if err := queries.CreateEventPlaybackState(ctx, playing); err != nil {
		t.Fatalf("playback state: %v", err)
	}
	if _, err := queries.StartEventPlayback(ctx, db.StartEventPlaybackParams{
		EventID: playing, CurrentEntryID: pgtype.Int8{Int64: entry.ID, Valid: true},
	}); err != nil {
		t.Fatalf("play: %v", err)
	}

	neverStarted := create("Never started", now.Add(-3*time.Hour), now.Add(-time.Hour), false)
	justOver := live("Just over", now.Add(-3*time.Hour), now.Add(-5*time.Minute))
	// Its planned end is long past, but its music stopped a moment ago.
	justStopped := live("Just stopped", now.Add(-3*time.Hour), now.Add(-time.Hour))
	if err := queries.CreateEventPlaybackState(ctx, justStopped); err != nil {
		t.Fatalf("playback state: %v", err)
	}
	if _, err := queries.SetEventPlaybackState(ctx, db.SetEventPlaybackStateParams{
		EventID: justStopped, IsPaused: true,
	}); err != nil {
		t.Fatalf("pause: %v", err)
	}

	ended, err := queries.EndOverdueEvents(ctx)
	if err != nil {
		t.Fatalf("EndOverdueEvents: %v", err)
	}
	for id, want := range map[int64]db.EventStatus{
		over: db.EventStatusEnded, neverStarted: db.EventStatusEnded,
		running: db.EventStatusLive, undated: db.EventStatusLive, playing: db.EventStatusLive,
		justOver: db.EventStatusEnded, justStopped: db.EventStatusEnded,
	} {
		if (want == db.EventStatusEnded) != slices.Contains(ended, id) {
			t.Errorf("event %d: returned %v, want ended=%v", id, slices.Contains(ended, id), want == db.EventStatusEnded)
		}
		got, err := queries.GetEventByID(ctx, id)
		if err != nil {
			t.Fatalf("get %d: %v", id, err)
		}
		if got.Status != want {
			t.Errorf("event %d: status %s, want %s", id, got.Status, want)
		}
	}
}
