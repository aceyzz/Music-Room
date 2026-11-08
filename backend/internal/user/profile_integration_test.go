//go:build integration

// UpsertUserProfile against a real Postgres: what "absent", "sent empty" and
// "sent with a value" do to a stored profile. Run with
// `make docker-backend-test-integration`.
//
// Everything happens in one transaction that is rolled back, so the run leaves
// no account behind.
package user

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	appdb "example.com/music-app/db"
	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"google.golang.org/protobuf/proto"
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

func TestUpsertUserProfileClearsOnlyWhatWasSentEmpty(t *testing.T) {
	ctx := context.Background()
	queries := testQueries(t)

	stamp := time.Now().UnixNano()
	user, err := queries.CreateUser(ctx, db.CreateUserParams{
		DisplayName: fmt.Sprintf("profile-it-%d", stamp),
		Email:       fmt.Sprintf("profile-it-%d@example.test", stamp),
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	upsert := func(req *pb.UpdateUserProfileRequest) db.UserProfile {
		t.Helper()
		req.UserId = user.ID
		params, err := profileParams(req)
		if err != nil {
			t.Fatalf("profileParams: %v", err)
		}
		profile, err := queries.UpsertUserProfile(ctx, params)
		if err != nil {
			t.Fatalf("upsert: %v", err)
		}
		return profile
	}

	upsert(&pb.UpdateUserProfileRequest{
		Bio: proto.String("hello"), City: proto.String("Paris"), CountryCode: proto.String("FR"),
		BirthDate: proto.String("1990-03-07"), BioVisibility: "private",
	})

	// Bio and birth date sent empty, city not sent at all.
	profile := upsert(&pb.UpdateUserProfileRequest{
		Bio: proto.String(""), BirthDate: proto.String(""), CountryCode: proto.String("BE"),
	})

	if profile.Bio.Valid {
		t.Errorf("bio: got %q, want NULL (sent empty)", profile.Bio.String)
	}
	if profile.BirthDate.Valid {
		t.Errorf("birth_date: got %v, want NULL (sent empty)", profile.BirthDate.Time)
	}
	if profile.City != (pgtype.Text{String: "Paris", Valid: true}) {
		t.Errorf("city: got %+v, want Paris (not sent)", profile.City)
	}
	if profile.CountryCode.String != "BE" {
		t.Errorf("country_code: got %+v, want BE", profile.CountryCode)
	}
	if profile.BioVisibility != "private" {
		t.Errorf("bio_visibility: got %q, want private (not sent)", profile.BioVisibility)
	}

	// SetAvatar's shape: only avatar_image_id, every Set flag false.
	profile, err = queries.UpsertUserProfile(ctx, db.UpsertUserProfileParams{UserID: user.ID})
	if err != nil {
		t.Fatalf("avatar-style upsert: %v", err)
	}
	if profile.City.String != "Paris" || profile.CountryCode.String != "BE" {
		t.Errorf("an upsert with no Set flags changed the profile: %+v", profile)
	}
}
