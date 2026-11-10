// hud-migrate creates Hud's ClickHouse database and schema, like ClickStack's migrate tool.
//
//	hud-migrate [up]  re-applies every schema/*.sql file on each start. The files only create what is missing
//	                  (TestSchemaIsCreateOnly), so concurrent runs (one init container per collector replica) are safe.
//
// Environment: CLICKHOUSE_ENDPOINT (a clickhouse-go DSN: tcp://, clickhouse://, http:// or https://),
// CLICKHOUSE_USER, CLICKHOUSE_PASSWORD, HUD_CLICKHOUSE_DATABASE (default hud_otel, ${DATABASE} in the schema files),
// HUD_LOGS_TTL_DAYS (default 30, only used when otel_logs is created). HUD_SCHEMA_MANAGED=false makes it exit
// without connecting, for customers who run the migrations themselves.
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
	"regexp"
	"time"

	"github.com/ClickHouse/clickhouse-go/v2"
	"github.com/pressly/goose/v3"
)

//go:embed schema
var schemaFS embed.FS

var version = "dev"

var identifier = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		slog.Error("hud-migrate failed", "error", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) > 1 || len(args) == 1 && args[0] != "up" {
		return fmt.Errorf("unknown arguments %q, want up", args)
	}
	if os.Getenv("HUD_SCHEMA_MANAGED") == "false" {
		slog.Info("HUD_SCHEMA_MANAGED=false, nothing to do")
		return nil
	}
	database, err := databaseName()
	if err != nil {
		return err
	}
	db, err := open()
	if err != nil {
		return err
	}
	defer db.Close()
	schema, _ := fs.Sub(schemaFS, "schema")
	return retry(func() error { return up(ctx, db, schema, database) })
}

func databaseName() (string, error) {
	name := os.Getenv("HUD_CLICKHOUSE_DATABASE")
	if name == "" {
		name = "hud_otel"
	}
	if !identifier.MatchString(name) {
		return "", fmt.Errorf("HUD_CLICKHOUSE_DATABASE %q is not a plain identifier", name)
	}
	return name, nil
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

func up(ctx context.Context, db *sql.DB, schema fs.FS, database string) error {
	// goose's ENVSUB reads the process environment
	if err := os.Setenv("DATABASE", database); err != nil {
		return err
	}
	p, err := goose.NewProvider(goose.DialectClickHouse, db, schema, goose.WithDisableVersioning(true))
	if err != nil {
		return err
	}
	results, err := p.Up(ctx)
	if err != nil {
		return err
	}
	for _, r := range results {
		slog.Info("applied", "file", path.Base(r.Source.Path), "duration", r.Duration)
	}
	slog.Info("schema up to date", "database", database, "release", version)
	return nil
}
