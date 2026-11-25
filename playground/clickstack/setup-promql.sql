-- Optional, after setup.sql and only with HUD_TIMESERIES_TABLE=true: the grants of the metrics TimeSeries table (PromQL).
-- hud-migrate creates ${HUD_CLICKHOUSE_DATABASE}_promql and its table, the collector remote-writes into it
-- (test/timeseries.yaml). setup.sh runs it when HUD_TIMESERIES_TABLE=true.

GRANT CREATE DATABASE, CREATE TABLE ON ${HUD_CLICKHOUSE_DATABASE}_promql.* TO hud_ddl;
GRANT INSERT ON ${HUD_CLICKHOUSE_DATABASE}_promql.* TO hud_write;
