// Command seed fills a Music Room database with a large, consistent demo
// world: 122 accounts, their friends, playlists, events, votes, devices and
// history, with every OpenFGA tuple the rows owe and every picture on disk.
//
//	make seed         # refuses if the seed is already there
//	make seed-reset   # wipes the database, OpenFGA and the images, then seeds
//	make seed-doc     # rewrites docs/annex/init_script_doc.md, no database needed
//	make loadtest-seed N=1000   # -reset, then the demo world plus N load-test
//	                            # users (loadtest.go) and loadtest/fixtures.json
//
// It reads the backend's own environment (APP_DATABASE_URL, APP_OPENFGA_*,
// APP_IMAGE_STORAGE_DIR), so it writes where the backend reads. The backend
// itself need not be running. docs/annex/init_script_doc.md lists what is created.
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"example.com/music-app/db"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"example.com/music-app/internal/config"
	"example.com/music-app/internal/media"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

func main() {
	reset := flag.Bool("reset", false, "empty every table, every OpenFGA tuple and the image folders first")
	offline := flag.Bool("offline", false, "do not ask Deezer for fresh preview URLs")
	docPath := flag.String("doc", "", "write the documentation of the world to this file and exit (no database)")
	load := defaultLoadConfig
	flag.IntVar(&load.Users, "loadtest", 0, "also write a load-test population of this many users (loadtest.go)")
	flag.IntVar(&load.EventSize, "loadtest-event-size", load.EventSize, "members per load-test event")
	flag.IntVar(&load.PlaylistSize, "loadtest-playlist-size", load.PlaylistSize, "members per load-test playlist")
	flag.IntVar(&load.DelegationSize, "loadtest-circle-size", load.DelegationSize, "people per delegation circle")
	loadOut := flag.String("loadtest-out", "../loadtest/fixtures.json", "where -loadtest writes what k6 reads")
	flag.Parse()

	if *docPath != "" {
		if err := os.WriteFile(*docPath, []byte(renderDoc(Build(docNow))), 0o644); err != nil {
			log.Fatalf("seed: %v", err)
		}
		log.Printf("seed: wrote %s", *docPath)
		return
	}
	if load.Users > 0 && load.Users < 2*load.DelegationSize {
		log.Fatalf("seed: -loadtest needs at least %d users", 2*load.DelegationSize)
	}
	if err := run(*reset, *offline, load, *loadOut); err != nil {
		log.Fatalf("seed: %v", err)
	}
}

func run(reset, offline bool, load LoadConfig, loadOut string) error {
	ctx := context.Background()
	start := time.Now()
	dbURL := config.Getenv("APP_DATABASE_URL", "")
	if dbURL == "" {
		return fmt.Errorf("APP_DATABASE_URL manquant")
	}
	fgaConfig := authz.Config{
		APIURL:  config.Getenv("APP_OPENFGA_API_URL", "http://localhost:8082"),
		StoreID: config.Getenv("APP_OPENFGA_STORE_ID", "01MRAVTHZ00000000000000000"),
		ModelID: config.Getenv("APP_OPENFGA_MODEL_ID", ""),
	}
	storageDir := config.Getenv("APP_IMAGE_STORAGE_DIR", "data/images")

	if err := migrate(dbURL); err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		return fmt.Errorf("database: %w", err)
	}
	defer pool.Close()
	fga, err := authz.NewClient(fgaConfig)
	if err != nil {
		return err
	}
	if _, err := fga.Ping(ctx); err != nil {
		return fmt.Errorf("openfga at %s: %w (is `make openfga` up?)", fgaConfig.APIURL, err)
	}

	var seeded bool
	if err := pool.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM users WHERE email = $1)",
		"alex@"+EmailDomain).Scan(&seeded); err != nil {
		return err
	}
	switch {
	case reset:
		if err := wipe(ctx, pool, fgaConfig, storageDir); err != nil {
			return fmt.Errorf("reset: %w", err)
		}
	case seeded:
		return errors.New("the demo world is already there (alex@" + EmailDomain + " exists). " +
			"`make seed-reset` wipes the database, OpenFGA and the images, then seeds again")
	}

	w := Build(time.Now())
	if offline {
		log.Printf("seed: offline, songs keep no preview URL")
	} else {
		log.Printf("seed: asking Deezer for fresh preview URLs (160 tracks, ~20 s; -offline skips it)")
		n := refreshSongs(ctx, w)
		log.Printf("seed: %d/%d previews refreshed", n, len(w.Songs))
	}

	store, err := media.NewStore(storageDir)
	if err != nil {
		return err
	}
	log.Printf("seed: drawing %d pictures into %s", 2*len(w.Images), storageDir)
	sizes, err := saveImages(w, store)
	if err != nil {
		return err
	}

	log.Printf("seed: writing the world and delivering its permission tuples (a few seconds)")
	ob := outbox.New(fga)
	counts, changes, err := writeWorld(ctx, pool, ob, w, sizes)
	if err != nil {
		return err
	}
	left, err := drain(ctx, pool, ob)
	if err != nil {
		return err
	}
	if left > 0 {
		log.Printf("seed: WARNING %d permission changes still in openfga_tuple_outbox; the backend's worker retries them", left)
	}

	log.Printf("seed: done in %s: %d rows in %d tables, %d permission changes, %d pictures",
		time.Since(start).Round(time.Second), sum(counts), len(counts), changes, 2*len(w.Images))

	if load.Users > 0 {
		lw, fx := BuildLoad(w.Now, load, w)
		log.Printf("seed: load test: %d users, %d events, %d playlists, %d delegation circles",
			len(fx.Users), len(fx.Events), len(fx.Playlists), len(fx.Circles))
		counts, changes, err := writeWorld(ctx, pool, ob, lw, nil)
		if err != nil {
			return fmt.Errorf("load test world: %w", err)
		}
		left, err := drain(ctx, pool, ob)
		if err != nil {
			return err
		}
		if left > 0 {
			log.Printf("seed: WARNING %d load-test permission changes still in openfga_tuple_outbox", left)
		}
		if err := writeFixtures(loadOut, fx); err != nil {
			return err
		}
		log.Printf("seed: load test: %d rows, %d permission changes; fixtures in %s", sum(counts), changes, loadOut)
	}
	log.Printf("seed: sign in as alex@%s / %s (docs/annex/init_script_doc.md lists everyone)", EmailDomain, Password)
	return nil
}

func migrate(dbURL string) error {
	std, err := sql.Open("pgx", dbURL)
	if err != nil {
		return err
	}
	defer std.Close()
	goose.SetBaseFS(db.MigrationsFS)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	if err := goose.Up(std, "schema"); err != nil {
		return fmt.Errorf("migrations: %w", err)
	}
	return nil
}

// drain delivers whatever the inline attempts left in the outbox. Enqueued rows
// wait 30 s before the worker may claim them (next_attempt_at); the seeder does
// not wait, it makes them due and runs the worker until the table is empty or
// stops shrinking.
func drain(ctx context.Context, pool *pgxpool.Pool, ob *outbox.Outbox) (int, error) {
	worker := outbox.NewWorker(ob, pool, outbox.WorkerConfig{BatchSize: 200})
	last := -1
	for pass := 0; pass < 20; pass++ {
		var left int
		if err := pool.QueryRow(ctx, "SELECT COUNT(*) FROM openfga_tuple_outbox").Scan(&left); err != nil {
			return 0, err
		}
		if left == 0 || left == last {
			return left, nil
		}
		last = left
		if _, err := pool.Exec(ctx, "UPDATE openfga_tuple_outbox SET next_attempt_at = NOW()"); err != nil {
			return 0, err
		}
		if err := worker.RunOnce(ctx); err != nil {
			return 0, err
		}
	}
	return last, nil
}
