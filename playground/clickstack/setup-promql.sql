-- Optional, after setup.sql and only with HUD_TIMESERIES_TABLE=true: what PromQL on the metrics TimeSeries table needs.
-- hud-migrate creates ${HUD_CLICKHOUSE_DATABASE}_promql and its table, the collector remote-writes into it
-- (test/timeseries.yaml) and Hud's backend queries it with PromQL. setup.sh runs it when HUD_TIMESERIES_TABLE=true.

GRANT CREATE DATABASE, CREATE TABLE ON ${HUD_CLICKHOUSE_DATABASE}_promql.* TO hud_ddl;
GRANT INSERT ON ${HUD_CLICKHOUSE_DATABASE}_promql.* TO hud_write;
GRANT SELECT ON ${HUD_CLICKHOUSE_DATABASE}_promql.* TO hud_read;
-- PromQL (/prometheus/api/v1/query) evaluates through a temporary table.
GRANT CREATE TEMPORARY TABLE ON *.* TO hud_read;
-- A second profile rather than a change to hud_read_profile, so dropping it undoes this. Private preview setting.
CREATE SETTINGS PROFILE IF NOT EXISTS hud_read_promql_profile SETTINGS enable_time_series_aggregate_functions = 1 TO hud_read;
