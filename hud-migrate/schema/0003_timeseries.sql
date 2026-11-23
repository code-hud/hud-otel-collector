-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- Only applied with HUD_TIMESERIES_TABLE=true (hud-migrate skips it otherwise): for a collector that feeds it with the
-- prometheus_remote_write exporter, read with PromQL. The inner tables land in the same database.
-- No samples TTL: it has to name the inner layout's columns, which change between engine versions.
CREATE TABLE IF NOT EXISTS ${DATABASE}.metrics
ENGINE = TimeSeries
SETTINGS enable_time_series_table = 1;
