// hud-migrate applies Hud's ClickHouse schema to the hud database, which the customer's setup script creates.
//
//	hud-migrate [up]    re-applies every schema/*.sql file. Each statement is idempotent, so concurrent runs
//	                    (one init container per collector replica) are safe.
//	hud-migrate once    runs the schema/once/*.sql steps not yet recorded in hud.schema_steps. The check isn't
//	                    atomic, so run it from one runner only.
//	hud-migrate status  prints the recorded schema version and the applied one-off steps.
//
// Environment: CLICKHOUSE_ENDPOINT (a clickhouse-go DSN: tcp://, clickhouse://, http:// or https://),
// CLICKHOUSE_USER, CLICKHOUSE_PASSWORD, HUD_LOGS_TTL_DAYS (default 30). HUD_SCHEMA_MANAGED=false makes up and
// once exit without connecting, for customers who run the migrations themselves.
package main

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path"
	"time"

	"github.com/ClickHouse/clickhouse-go/v2"
	"github.com/pressly/goose/v3"
)

//go:embed schema
var schemaFS embed.FS

// The oldest schema version a collector of this release can still write to. Raise it only with a change that breaks
// older collectors, which the add-only rule forbids; an older migrator then refuses to run against the newer schema.
const minCompatible = 1

var version = "dev"

func main() {
	cmd := "up"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	if err := run(context.Background(), cmd); err != nil {
		slog.Error("hud-migrate failed", "command", cmd, "error", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cmd string) error {
	if cmd != "up" && cmd != "once" && cmd != "status" {
		return fmt.Errorf("unknown command %q, want up, once or status", cmd)
	}
	if cmd != "status" && os.Getenv("HUD_SCHEMA_MANAGED") == "false" {
		slog.Info("HUD_SCHEMA_MANAGED=false, nothing to do", "command", cmd)
		return nil
	}
	db, err := open()
	if err != nil {
		return err
	}
	defer db.Close()
	schema, _ := fs.Sub(schemaFS, "schema")
	steps, _ := fs.Sub(schema, "once")
	switch cmd {
	case "up":
		return retry(func() error { return up(ctx, db, schema) })
	case "once":
		return runOnce(ctx, db, steps)
	default:
		return status(ctx, db, schema)
	}
}

func open() (*sql.DB, error) {
	endpoint := os.Getenv("CLICKHOUSE_ENDPOINT")
	if endpoint == "" {
		return nil, errors.New("CLICKHOUSE_ENDPOINT is required")
	}
	opts, err := clickhouse.ParseDSN(endpoint)
	if err != nil {
		return nil, err
	}
	if u := os.Getenv("CLICKHOUSE_USER"); u != "" {
		opts.Auth.Username = u
	}
	if p := os.Getenv("CLICKHOUSE_PASSWORD"); p != "" {
		opts.Auth.Password = p
	}
	if opts.Auth.Database == "" {
		opts.Auth.Database = "hud"
	}
	return clickhouse.OpenDB(opts), nil
}

// Same budget as ClickStack's migrate: 5 attempts, for a server that is still starting.
func retry(f func() error) error {
	var err error
	for i, wait := 0, time.Second; i < 5; i, wait = i+1, wait*2 {
		if err = f(); err == nil {
			return nil
		}
		slog.Warn("attempt failed", "attempt", i+1, "error", err)
		if i < 4 {
			time.Sleep(wait)
		}
	}
	return err
}

func provider(db *sql.DB, fsys fs.FS) (*goose.Provider, error) {
	return goose.NewProvider(goose.DialectClickHouse, db, fsys, goose.WithDisableVersioning(true))
}

func latest(p *goose.Provider) int64 {
	s := p.ListSources()
	return s[len(s)-1].Version
}

func up(ctx context.Context, db *sql.DB, schema fs.FS) error {
	p, err := provider(db, schema)
	if err != nil {
		return err
	}
	target := latest(p)
	recorded, compat, err := recordedVersion(ctx, db)
	if err != nil {
		return err
	}
	if int64(compat) > target {
		return fmt.Errorf("the hud schema is at version %d and needs a migrator of schema version %d or later, this one has %d",
			recorded, compat, target)
	}
	results, err := p.Up(ctx)
	if err != nil {
		return err
	}
	for _, r := range results {
		slog.Info("applied", "file", path.Base(r.Source.Path), "duration", r.Duration)
	}
	if _, err := db.ExecContext(ctx, "INSERT INTO hud.schema_info (version, min_compatible, migrator) VALUES (?, ?, ?)",
		target, minCompatible, version); err != nil {
		return err
	}
	slog.Info("schema up to date", "version", target, "recorded_before", recorded)
	return nil
}

// Version 0 when hud.schema_info doesn't exist yet.
func recordedVersion(ctx context.Context, db *sql.DB) (v, compat uint32, err error) {
	var exists uint8
	if err = db.QueryRowContext(ctx, "EXISTS TABLE hud.schema_info").Scan(&exists); err != nil || exists == 0 {
		return 0, 0, err
	}
	err = db.QueryRowContext(ctx, "SELECT max(version), max(min_compatible) FROM hud.schema_info").Scan(&v, &compat)
	return v, compat, err
}

func runOnce(ctx context.Context, db *sql.DB, steps fs.FS) error {
	p, err := provider(db, steps)
	if errors.Is(err, goose.ErrNoMigrations) {
		slog.Info("no one-off steps")
		return nil
	}
	if err != nil {
		return err
	}
	for _, s := range p.ListSources() {
		step := path.Base(s.Path)
		var done uint64
		if err := db.QueryRowContext(ctx, "SELECT count() FROM hud.schema_steps WHERE step = ?", step).Scan(&done); err != nil {
			return fmt.Errorf("%w (run hud-migrate up first)", err)
		}
		if done > 0 {
			slog.Info("already applied", "step", step)
			continue
		}
		if _, err := p.ApplyVersion(ctx, s.Version, true); err != nil {
			return fmt.Errorf("step %s: %w", step, err)
		}
		if _, err := db.ExecContext(ctx, "INSERT INTO hud.schema_steps (step, migrator) VALUES (?, ?)", step, version); err != nil {
			return err
		}
		slog.Info("applied", "step", step)
	}
	return nil
}

func status(ctx context.Context, db *sql.DB, schema fs.FS) error {
	p, err := provider(db, schema)
	if err != nil {
		return err
	}
	v, compat, err := recordedVersion(ctx, db)
	if err != nil {
		return err
	}
	fmt.Printf("hud schema version %d (min compatible %d), this migrator: schema version %d, release %s\n",
		v, compat, latest(p), version)
	rows, err := db.QueryContext(ctx, "SELECT step, migrator, applied_at FROM hud.schema_steps FINAL ORDER BY step")
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var step, migrator string
		var at time.Time
		if err := rows.Scan(&step, &migrator, &at); err != nil {
			return err
		}
		fmt.Printf("step %s applied %s by %s\n", step, at.Format(time.RFC3339), migrator)
	}
	return rows.Err()
}
