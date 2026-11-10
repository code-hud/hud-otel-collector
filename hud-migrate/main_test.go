package main

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"strings"
	"testing"
)

var (
	comment   = regexp.MustCompile(`--[^\n]*`)
	allowed   = regexp.MustCompile(`(?is)^(CREATE\s+(TABLE|(MATERIALIZED\s+)?VIEW|DICTIONARY)\s+IF\s+NOT\s+EXISTS|ALTER\s+TABLE\s+\S+\s+ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS)\s`)
	forbidden = regexp.MustCompile(`(?i)\b(DROP|RENAME|MODIFY|REPLACE|DELETE|UPDATE|TRUNCATE|DETACH|EXCHANGE|MATERIALIZE|CLEAR)\b`)
)

// Schema files only create what is missing: every statement is CREATE ... IF NOT EXISTS or
// ALTER TABLE ... ADD COLUMN IF NOT EXISTS. Changing an existing object means a new object under a new name.
// ponytail: a textual check, so a column or string literally named "drop" trips it; rename it.
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
		"-- +goose Up\nCREATE TABLE IF NOT EXISTS hud.a (x UInt8) ENGINE = MergeTree ORDER BY x SETTINGS ttl_only_drop_parts = 1;": true,
		"ALTER TABLE hud.a ADD COLUMN IF NOT EXISTS y UInt8;":                    true,
		"CREATE MATERIALIZED VIEW IF NOT EXISTS hud.v TO hud.a AS SELECT 1 AS x": true,
		"CREATE TABLE hud.a (x UInt8) ENGINE = Memory":                           false,
		"CREATE OR REPLACE TABLE hud.a (x UInt8) ENGINE = Memory":                false,
		"ALTER TABLE hud.a MODIFY TTL now()":                                     false,
		"ALTER TABLE hud.a ADD COLUMN IF NOT EXISTS y UInt8, DROP COLUMN x":      false,
		"RENAME TABLE hud.a TO hud.b":                                            false,
		"DROP TABLE IF EXISTS hud.a":                                             false,
	} {
		if err := checkSQL(sql); (err == nil) != ok {
			t.Errorf("checkSQL(%q) = %v, want ok=%v", sql, err, ok)
		}
	}
}

// Runs against a ClickHouse with the hud database, as hud_migrator (test/smoke.sh sets the env up).
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
	for range 2 {
		if err := up(ctx, db, schema); err != nil {
			t.Fatal(err)
		}
	}
	for _, table := range []string{"metrics", "otel_logs"} {
		var exists uint8
		if err := db.QueryRowContext(ctx, "EXISTS TABLE hud."+table).Scan(&exists); err != nil || exists != 1 {
			t.Errorf("hud.%s: exists=%d, err=%v", table, exists, err)
		}
	}
}
