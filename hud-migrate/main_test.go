package main

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/ClickHouse/clickhouse-go/v2"
)

var (
	comment   = regexp.MustCompile(`--[^\n]*`)
	allowed   = regexp.MustCompile(`(?is)^(CREATE\s+(DATABASE|TABLE|(MATERIALIZED\s+)?VIEW|DICTIONARY)\s+IF\s+NOT\s+EXISTS|ALTER\s+TABLE\s+\S+\s+ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS)\s`)
	forbidden = regexp.MustCompile(`(?i)\b(DROP|RENAME|MODIFY|REPLACE|DELETE|UPDATE|TRUNCATE|DETACH|EXCHANGE|MATERIALIZE|CLEAR)\b`)
)

// Schema files only create what is missing: every statement is CREATE ... IF NOT EXISTS (database included) or
// ALTER TABLE ... ADD COLUMN IF NOT EXISTS. Changing an existing object means a new object under a new name.
// The check is textual, so a column or string literally named "drop" trips it; rename it.
func checkSQL(sql string) error {
	for _, stmt := range strings.Split(comment.ReplaceAllString(sql, ""), ";") {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}
		if !allowed.MatchString(stmt) {
			return fmt.Errorf("not CREATE ... IF NOT EXISTS or ADD COLUMN IF NOT EXISTS: %.60q", stmt)
		}
		if w := forbidden.FindString(stmt); w != "" {
			return fmt.Errorf("%s in %.60q", w, stmt)
		}
	}
	return nil
}

func TestSchemaIsCreateOnly(t *testing.T) {
	files, _ := fs.Glob(schemaFS, "schema/*.sql")
	if len(files) == 0 {
		t.Fatal("no schema files")
	}
	for _, f := range files {
		b, _ := schemaFS.ReadFile(f)
		if err := checkSQL(string(b)); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
	for sql, ok := range map[string]bool{
		"-- +goose Up\nCREATE TABLE IF NOT EXISTS hud_otel.a (x UInt8) ENGINE = MergeTree ORDER BY x SETTINGS ttl_only_drop_parts = 1;": true,
		"CREATE DATABASE IF NOT EXISTS ${DATABASE};":                                       true,
		"CREATE DATABASE hud_otel":                                                         false,
		"ALTER TABLE hud_otel.a ADD COLUMN IF NOT EXISTS y UInt8;":                         true,
		"CREATE MATERIALIZED VIEW IF NOT EXISTS hud_otel.v TO hud_otel.a AS SELECT 1 AS x": true,
		"CREATE TABLE hud_otel.a (x UInt8) ENGINE = Memory":                                false,
		"CREATE OR REPLACE TABLE hud_otel.a (x UInt8) ENGINE = Memory":                     false,
		"ALTER TABLE hud_otel.a MODIFY TTL now()":                                          false,
		"ALTER TABLE hud_otel.a ADD COLUMN IF NOT EXISTS y UInt8, DROP COLUMN x":           false,
		"RENAME TABLE hud_otel.a TO hud_otel.b":                                            false,
		"DROP TABLE IF EXISTS hud_otel.a":                                                  false,
	} {
		if err := checkSQL(sql); (err == nil) != ok {
			t.Errorf("checkSQL(%q) = %v, want ok=%v", sql, err, ok)
		}
	}
}

// Runs against ClickHouse as hud_migrator (test/smoke.sh sets the env up).
func TestUp(t *testing.T) {
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
	database, err := databaseName()
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := up(ctx, db, schema, database); err != nil {
			t.Fatal(err)
		}
	}
	for _, table := range []string{"metrics", "otel_logs"} {
		var exists uint8
		if err := db.QueryRowContext(ctx, "EXISTS TABLE "+database+"."+table).Scan(&exists); err != nil || exists != 1 {
			t.Errorf("%s.%s: exists=%d, err=%v", database, table, exists, err)
		}
	}
}

func TestDatabaseName(t *testing.T) {
	for env, want := range map[string]string{"": "hud_otel", "acme_otel": "acme_otel", "x; DROP DATABASE y": ""} {
		t.Setenv("HUD_CLICKHOUSE_DATABASE", env)
		if got, err := databaseName(); got != want || (err == nil) != (want != "") {
			t.Errorf("HUD_CLICKHOUSE_DATABASE=%q: got %q, %v", env, got, err)
		}
	}
}

func TestBuildDSN(t *testing.T) {
	for _, c := range []struct {
		endpoint   string
		skipVerify bool
		protocol   clickhouse.Protocol
		tls        bool
		err        bool
	}{
		{endpoint: "tcp://clickhouse:9000", protocol: clickhouse.Native},
		{endpoint: "http://clickhouse:8123", protocol: clickhouse.HTTP},
		{endpoint: "https://svc.eu-central-1.aws.clickhouse.cloud:8443", protocol: clickhouse.HTTP, tls: true},
		{endpoint: "https://svc.eu-central-1.aws.clickhouse.cloud:8443/", protocol: clickhouse.HTTP, tls: true},
		{endpoint: "https://svc:8443/prometheus/api/v1/write", protocol: clickhouse.HTTP, tls: true},
		{endpoint: "https://svc:8443?secure=true&dial_timeout=5s", protocol: clickhouse.HTTP, tls: true},
		{endpoint: "https://svc:8443?secure=false", err: true},
		{endpoint: "https://svc:8443", skipVerify: true, protocol: clickhouse.HTTP, tls: true},
		{endpoint: "tcp://svc:9440?secure=true", skipVerify: true, protocol: clickhouse.Native, tls: true},
	} {
		dsn, err := buildDSN(c.endpoint, c.skipVerify)
		if err != nil {
			t.Fatalf("%s: %v", c.endpoint, err)
		}
		opts, err := clickhouse.ParseDSN(dsn)
		if c.err {
			if err == nil {
				t.Errorf("%s: parsed %s, want an error", c.endpoint, dsn)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %s: %v", c.endpoint, dsn, err)
			continue
		}
		if opts.Protocol != c.protocol || (opts.TLS != nil) != c.tls || opts.Auth.Database != "" {
			t.Errorf("%s: %s: protocol %v, TLS %v, database %q", c.endpoint, dsn, opts.Protocol, opts.TLS != nil, opts.Auth.Database)
		}
		if c.tls && opts.TLS.InsecureSkipVerify != c.skipVerify {
			t.Errorf("%s: skip verify %v, want %v", c.endpoint, opts.TLS.InsecureSkipVerify, c.skipVerify)
		}
	}
}
