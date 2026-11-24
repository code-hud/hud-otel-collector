-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- Only applied with HUD_TIMESERIES_TABLE=true (hud-migrate skips it otherwise): for a collector that feeds it with the
-- prometheus_remote_write exporter, read with PromQL. Its own database, ${DATABASE}_promql, next to the SQL tables'; the
-- inner tables land there too.
-- No samples TTL: it has to name the inner layout's columns, which change between engine versions.
CREATE DATABASE IF NOT EXISTS ${DATABASE}_promql;

CREATE TABLE IF NOT EXISTS ${DATABASE}_promql.metrics
ENGINE = TimeSeries
SETTINGS enable_time_series_table = 1
COMMENT 'Prometheus-style TimeSeries table for a collector that remote-writes the SDK metrics to it (prometheus_remote_write, test/timeseries.yaml), read with PromQL. Created only with HUD_TIMESERIES_TABLE=true. The engine keeps the data in its inner tables (samples, tags, metric families), no TTL.';
