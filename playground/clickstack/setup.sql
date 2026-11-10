-- The customer's one-time admin setup (clickstack-integration-design.md, "Bootstrap"), with playground passwords.
-- ${HUD_CLICKHOUSE_DATABASE} is the database name the collector and hud-migrate are configured with (default
-- hud_otel): replace it before running this by hand, or run setup.sh, which the playground's ClickHouse does on
-- first start. hud-migrate creates the database; the grants name it before it exists.

CREATE ROLE IF NOT EXISTS hud_write;   GRANT INSERT ON ${HUD_CLICKHOUSE_DATABASE}.* TO hud_write;
CREATE ROLE IF NOT EXISTS hud_read;    GRANT SELECT ON ${HUD_CLICKHOUSE_DATABASE}.* TO hud_read;
-- Only what the create-only schema rule allows: the server refuses DROP, RENAME, MODIFY, CREATE OR REPLACE, ADD INDEX.
CREATE ROLE IF NOT EXISTS hud_ddl;
GRANT CREATE DATABASE, CREATE TABLE, CREATE VIEW, ALTER ADD COLUMN, SELECT, INSERT ON ${HUD_CLICKHOUSE_DATABASE}.* TO hud_ddl;

-- PromQL on TimeSeries needs the temporary-table grant (until ClickHouse#120724) and the time-series aggregate
-- functions; readonly = 1 would reject both.
CREATE SETTINGS PROFILE IF NOT EXISTS hud_read_profile SETTINGS
  readonly = 2, max_execution_time = 60, max_memory_usage = 8000000000, max_threads = 8,
  enable_time_series_aggregate_functions = 1 TO hud_read;
CREATE QUOTA IF NOT EXISTS hud_read_quota
  FOR INTERVAL 1 hour MAX queries = 20000, execution_time = 3600, read_bytes = 2000000000000 TO hud_read;
GRANT CREATE TEMPORARY TABLE ON *.* TO hud_read;

CREATE USER IF NOT EXISTS hud_collector IDENTIFIED WITH sha256_password BY 'Collector-pass-1234' DEFAULT ROLE hud_write;
CREATE USER IF NOT EXISTS hud_migrator  IDENTIFIED WITH sha256_password BY 'Migrator-pass-1234' DEFAULT ROLE hud_ddl;
-- sha256('Backend-pass-1234'); Hud keeps the password.
CREATE USER IF NOT EXISTS hud_backend IDENTIFIED WITH sha256_hash BY 'ed686e00633030dbf048d58bb84477ce6e9d443ed1da58a76e6386d644f19ee2' DEFAULT ROLE hud_read;
GRANT hud_write TO hud_collector; GRANT hud_ddl TO hud_migrator; GRANT hud_read TO hud_backend;
