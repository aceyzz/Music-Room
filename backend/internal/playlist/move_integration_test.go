//go:build integration

// MovePlaylistSong against a real Postgres: where a move lands, that repeated
// midpoints never collide, and that a song or anchor outside the playlist moves
// nothing. Run with `make docker-backend-test-integration`.
//
// Everything happens in one transaction that is rolled back, so the run leaves
// no account, song or playlist behind.
package playlist

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
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

// Same harness as event/create_integration_test.go.
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

// moveFixture is a playlist of n appended rows (the same song n times: the
// schema allows duplicates, and the rows are what is ordered).
type moveFixture struct {
	t        *testing.T
	queries  *db.Queries
	playlist int64
	rows     []int64 // playlist_songs ids, in insertion order
}

func newMoveFixture(t *testing.T, queries *db.Queries, n int) *moveFixture {
	t.Helper()
	ctx := context.Background()
	stamp := time.Now().UnixNano()
	owner, err := queries.CreateUser(ctx, db.CreateUserParams{
		DisplayName: fmt.Sprintf("move-it-%d", stamp),
		Email:       fmt.Sprintf("move-it-%d@example.test", stamp),
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	song, err := queries.UpsertSongFromDeezer(ctx, db.UpsertSongFromDeezerParams{
		DeezerSongID: stamp % 1_000_000_000, Title: "Move", DurationSeconds: 30, ArtistName: "Test",
		Readable: true,
	})
	if err != nil {
		t.Fatalf("create song: %v", err)
	}
	playlist, err := queries.CreatePlaylist(ctx, db.CreatePlaylistParams{
		OwnerID: owner.ID, Name: "Moves", Visibility: db.ResourceVisibilityPublic,
		EditLicense: db.EditLicenseEveryone,
	})
	if err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	f := &moveFixture{t: t, queries: queries, playlist: playlist.ID}
	for range n {
		row, err := queries.AppendSongToPlaylist(ctx, db.AppendSongToPlaylistParams{
			PlaylistID: playlist.ID, SongID: song.ID,
		})
		if err != nil {
			t.Fatalf("append: %v", err)
		}
		f.rows = append(f.rows, row.ID)
	}
	return f
}

// move puts row after anchor (0: the top) and returns how many rows changed.
func (f *moveFixture) move(row, anchor int64) int64 {
	f.t.Helper()
	moved, err := f.queries.MovePlaylistSong(context.Background(), db.MovePlaylistSongParams{
		ID: row, AfterID: anchor, PlaylistID: f.playlist,
	})
	if err != nil {
		f.t.Fatalf("move %d after %d: %v", row, anchor, err)
	}
	return moved
}

// order reads the playlist back and returns its row ids, checking that the
// returned positions are 1..n.
func (f *moveFixture) order() []int64 {
	f.t.Helper()
	songs, err := f.queries.GetPlaylistSongsByPlaylistID(context.Background(), f.playlist)
	if err != nil {
		f.t.Fatalf("read: %v", err)
	}
	ids := make([]int64, len(songs))
	for i, s := range songs {
		ids[i] = s.ID
		if s.Position != int64(i+1) {
			f.t.Errorf("row %d: position %d, want %d", s.ID, s.Position, i+1)
		}
	}
	return ids
}

func TestMovePlaylistSongPlacesTheSong(t *testing.T) {
	f := newMoveFixture(t, testQueries(t), 4)
	a, b, c, d := f.rows[0], f.rows[1], f.rows[2], f.rows[3]

	steps := []struct {
		name        string
		row, anchor int64
		want        []int64
	}{
		{"to the top", c, 0, []int64{c, a, b, d}},
		{"between two", d, c, []int64{c, d, a, b}},
		{"to the end", c, b, []int64{d, a, b, c}},
		{"where it already is", a, d, []int64{d, a, b, c}},
	}
	for _, step := range steps {
		if moved := f.move(step.row, step.anchor); moved != 1 {
			t.Fatalf("%s: %d rows moved, want 1", step.name, moved)
		}
		if got := f.order(); !slices.Equal(got, step.want) {
			t.Fatalf("%s: got %v, want %v", step.name, got, step.want)
		}
	}
}

// The case `/ 2` fails: NUMERIC division rounds to a fixed scale (20 digits
// here), so at move 69 the midpoint rounds onto its neighbour and two
// positions are equal.
func TestMovePlaylistSongMidpointsNeverCollide(t *testing.T) {
	f := newMoveFixture(t, testQueries(t), 3)
	first := f.rows[0]

	// The last song goes right after the first, every time: each move lands
	// between the first and the one moved before it, halving the same gap.
	for i := range 80 {
		order := f.order()
		last := order[2]
		f.move(last, first)
		if got, want := f.order(), []int64{first, last, order[1]}; !slices.Equal(got, want) {
			t.Fatalf("move %d: got %v, want %v", i+1, got, want)
		}
	}
}

func TestMovePlaylistSongOutsideThePlaylistMovesNothing(t *testing.T) {
	queries := testQueries(t)
	f := newMoveFixture(t, queries, 2)
	other := newMoveFixture(t, queries, 1)
	before := f.order()

	if moved := f.move(f.rows[0], other.rows[0]); moved != 0 {
		t.Errorf("anchor from another playlist: %d rows moved, want 0", moved)
	}
	if moved := f.move(other.rows[0], f.rows[1]); moved != 0 {
		t.Errorf("song from another playlist: %d rows moved, want 0", moved)
	}
	if moved := f.move(f.rows[0], 999_999_999_999); moved != 0 {
		t.Errorf("anchor that does not exist: %d rows moved, want 0", moved)
	}
	if got := f.order(); !slices.Equal(got, before) {
		t.Errorf("order changed: got %v, want %v", got, before)
	}
}
