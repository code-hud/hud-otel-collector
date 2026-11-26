-- The customer's one-time admin setup (clickstack-integration-design.md, "Bootstrap"), with playground passwords: the
-- writer and migrator roles and users of the SQL tables, all a SQL-only install needs. PromQL on the TimeSeries table
-- adds setup-promql.sql. No read user: Hud reads through the ClickHouse Cloud remote MCP, the playground as admin.
-- ${HUD_CLICKHOUSE_DATABASE} is the database name the collector and hud-migrate are configured with (default
-- hud_otel): replace it before running this by hand, or run setup.sh, which the playground's ClickHouse does on
-- first start. hud-migrate creates the database; the grants name it before it exists.
-- ${HUD_CLICKHOUSE_DATABASE}_collector holds the collector's own metrics, unless HUD_COLLECTOR_TELEMETRY=false.

CREATE ROLE IF NOT EXISTS hud_write;   GRANT INSERT ON ${HUD_CLICKHOUSE_DATABASE}.* TO hud_write;
GRANT INSERT ON ${HUD_CLICKHOUSE_DATABASE}_collector.* TO hud_write;
-- Tables are create-only: the server refuses DROP, RENAME, MODIFY, CREATE OR REPLACE and ADD INDEX on them. Views are
-- the exception: ALTER VIEW (a materialized view's MODIFY QUERY) and DROP VIEW, so a view can be changed in place.
CREATE ROLE IF NOT EXISTS hud_ddl;
GRANT CREATE DATABASE, CREATE TABLE, CREATE VIEW, ALTER ADD COLUMN, ALTER VIEW, DROP VIEW, SELECT, INSERT
  ON ${HUD_CLICKHOUSE_DATABASE}.* TO hud_ddl;
GRANT CREATE DATABASE, CREATE TABLE ON ${HUD_CLICKHOUSE_DATABASE}_collector.* TO hud_ddl;

CREATE USER IF NOT EXISTS hud_collector IDENTIFIED WITH sha256_password BY 'Collector-pass-1234' DEFAULT ROLE hud_write;
CREATE USER IF NOT EXISTS hud_migrator  IDENTIFIED WITH sha256_password BY 'Migrator-pass-1234' DEFAULT ROLE hud_ddl;
GRANT hud_write TO hud_collector; GRANT hud_ddl TO hud_migrator;
