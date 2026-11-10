package main

import (
	"context"
	"io/fs"
	"os"
	"testing"
	"testing/fstest"
)

// Runs against a ClickHouse with the hud database, as hud_migrator (test/smoke.sh sets the env up).
func TestMigrate(t *testing.T) {
	if os.Getenv("CLICKHOUSE_ENDPOINT") == "" {
		t.Skip("CLICKHOUSE_ENDPOINT not set")
	}
	ctx := context.Background()
	db, err := open()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	schema, _ := fs.Sub(schemaFS, "schema")
	count := func(q string) (n uint64) {
		t.Helper()
		if err := db.QueryRowContext(ctx, q).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	for range 2 {
		if err := up(ctx, db, schema); err != nil {
			t.Fatal(err)
		}
	}
	if v, _, _ := recordedVersion(ctx, db); v != 1 {
		t.Fatalf("schema version %d, want 1", v)
	}

	if _, err := db.ExecContext(ctx, "CREATE TABLE IF NOT EXISTS hud.once_test (n UInt8) ENGINE = MergeTree ORDER BY n"); err != nil {
		t.Fatal(err)
	}
	steps := fstest.MapFS{"0001_backfill.sql": {Data: []byte("-- +goose Up\n-- +goose NO TRANSACTION\nINSERT INTO hud.once_test VALUES (1);\n")}}
	for range 2 {
		if err := runOnce(ctx, db, steps); err != nil {
			t.Fatal(err)
		}
	}
	if n := count("SELECT count() FROM hud.once_test"); n != 1 {
		t.Fatalf("one-off step ran %d times, want 1", n)
	}
	if n := count("SELECT count() FROM hud.schema_steps WHERE step = '0001_backfill.sql'"); n != 1 {
		t.Fatalf("%d schema_steps rows, want 1", n)
	}
	if err := runOnce(ctx, db, fstest.MapFS{}); err != nil {
		t.Fatal(err)
	}

	if _, err := db.ExecContext(ctx, "INSERT INTO hud.schema_info (version, min_compatible, migrator) VALUES (99, 99, 'test')"); err != nil {
		t.Fatal(err)
	}
	if err := up(ctx, db, schema); err == nil {
		t.Fatal("up ran against an incompatible newer schema")
	}
	for _, q := range []string{"DELETE FROM hud.schema_info WHERE version = 99", "DROP TABLE hud.once_test",
		"DELETE FROM hud.schema_steps WHERE step = '0001_backfill.sql'"} {
		if _, err := db.ExecContext(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
}
