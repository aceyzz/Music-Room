package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"example.com/music-app/internal/authz"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	openfga "github.com/openfga/go-sdk"
	"github.com/openfga/go-sdk/client"
)

// wipe empties everything the seed writes to, and everything else in the same
// places: every app table, every tuple in the store, the image folders. The
// user chose this over removing only seeded rows, knowing that it also wipes
// accounts made by hand -- that is the price of a world that is guaranteed
// consistent with its permission graph.
func wipe(ctx context.Context, pool *pgxpool.Pool, cfg authz.Config, storageDir string) error {
	rows, err := pool.Query(ctx, `
		SELECT quote_ident(c.relname)
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'public'
		  AND c.relkind IN ('r', 'p')
		  AND NOT c.relispartition
		  AND c.relname <> 'goose_db_version'`)
	if err != nil {
		return err
	}
	tables, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, "TRUNCATE TABLE "+strings.Join(tables, ", ")+" RESTART IDENTITY CASCADE"); err != nil {
		return fmt.Errorf("truncate: %w", err)
	}
	log.Printf("seed: emptied %d tables", len(tables))

	n, err := deleteAllTuples(ctx, cfg)
	if err != nil {
		return fmt.Errorf("openfga: %w", err)
	}
	log.Printf("seed: deleted %d OpenFGA tuples", n)

	for _, dir := range []string{"avatars", "playlists"} {
		if err := os.RemoveAll(filepath.Join(storageDir, dir)); err != nil {
			return err
		}
	}
	return nil
}

// deleteAllTuples reads the first page of the store and deletes it, until the
// store is empty. Always the first page: a continuation token describes a
// position in a list this loop is busy shrinking.
func deleteAllTuples(ctx context.Context, cfg authz.Config) (int, error) {
	conf := &client.ClientConfiguration{ApiUrl: cfg.APIURL, StoreId: cfg.StoreID}
	if cfg.ModelID != "" {
		conf.AuthorizationModelId = cfg.ModelID
	}
	fga, err := client.NewSdkClient(conf)
	if err != nil {
		return 0, err
	}
	deleted := 0
	for {
		page, err := fga.Read(ctx).Body(client.ClientReadRequest{}).
			Options(client.ClientReadOptions{PageSize: openfga.PtrInt32(100)}).Execute()
		if err != nil {
			return deleted, err
		}
		if len(page.Tuples) == 0 {
			return deleted, nil
		}
		keys := make([]client.ClientTupleKeyWithoutCondition, len(page.Tuples))
		for i, t := range page.Tuples {
			keys[i] = client.ClientTupleKeyWithoutCondition{User: t.Key.User, Relation: t.Key.Relation, Object: t.Key.Object}
		}
		if _, err := fga.DeleteTuples(ctx).Body(keys).Execute(); err != nil {
			return deleted, err
		}
		deleted += len(keys)
	}
}
