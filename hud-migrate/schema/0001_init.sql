-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

CREATE DATABASE IF NOT EXISTS ${DATABASE};

-- ClickStack's otel_logs layout (hyperdx docker/otel-collector/schema/seed/00002_otel_logs_compat.sql), so HyperDX
-- reads it as a log source. The bloom-filter variant runs on every server version; ClickStack's text-index
-- variant (26.2+) would be a new table. HUD_LOGS_TTL_DAYS only applies when the table is created.
CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_logs
(
  `Timestamp` DateTime64(9) COMMENT 'Record time (OTLP time_unix_nano, else observed time), nanosecond precision' CODEC(Delta, ZSTD(3)),
  `TraceId` String COMMENT 'Trace id as hex, empty without a trace context' CODEC(ZSTD(3)),
  `SpanId` String COMMENT 'Span id as hex, empty without a trace context' CODEC(ZSTD(3)),
  `TraceFlags` UInt8 COMMENT 'W3C trace flags of the record (bit 0: sampled)',
  `SeverityText` LowCardinality(String) COMMENT 'Severity as sent (forensics: ERROR, or INFO for a baseline)' CODEC(ZSTD(3)),
  `SeverityNumber` UInt8 COMMENT 'OTLP severity number, 1-24 (9 INFO, 17 ERROR), 0 when unset',
  `ServiceName` LowCardinality(String) COMMENT 'Resource attribute service.name' CODEC(ZSTD(3)),
  `Body` String COMMENT 'Record body as a string (forensics: the censored investigation as JSON)' CODEC(ZSTD(3)),
  `ResourceSchemaUrl` LowCardinality(String) COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
  `ResourceAttributes` Map(LowCardinality(String), String) COMMENT 'Resource attributes (service, deployment, SDK session, host, pod), values as strings' CODEC(ZSTD(3)),
  `ScopeSchemaUrl` LowCardinality(String) COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
  `ScopeName` String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
  `ScopeVersion` LowCardinality(String) COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
  `ScopeAttributes` Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
  `LogAttributes` Map(LowCardinality(String), String) COMMENT 'Record attributes (forensics: hud.forensic.type, flow and issue attributes), values as strings' CODEC(ZSTD(3)),
  `EventName` String COMMENT 'OTLP event name (hud.forensic for SDK forensics), empty for plain logs' CODEC(ZSTD(3)),
  `__hdx_materialized_k8s.cluster.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.cluster.name'] COMMENT 'Copy of resource attribute k8s.cluster.name, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_k8s.container.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name'] COMMENT 'Copy of resource attribute k8s.container.name, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_k8s.deployment.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.deployment.name'] COMMENT 'Copy of resource attribute k8s.deployment.name, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_k8s.namespace.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'] COMMENT 'Copy of resource attribute k8s.namespace.name, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_k8s.node.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name'] COMMENT 'Copy of resource attribute k8s.node.name, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_k8s.pod.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'] COMMENT 'Copy of resource attribute k8s.pod.name, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_k8s.pod.uid` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.uid'] COMMENT 'Copy of resource attribute k8s.pod.uid, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_deployment.environment.name` LowCardinality(String) MATERIALIZED ResourceAttributes['deployment.environment.name'] COMMENT 'Copy of resource attribute deployment.environment.name, for HyperDX filters' CODEC(ZSTD(3)),
  `__hdx_materialized_session.id` String MATERIALIZED LogAttributes['session.id'] COMMENT 'Copy of log attribute session.id (HyperDX browser sessions, not the SDK session)' CODEC(ZSTD(3)),
  INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
  INDEX idx_session_id __hdx_materialized_session.id TYPE bloom_filter(0.001) GRANULARITY 1,
  INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
  INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
  INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
  INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
  INDEX idx_log_attr_key mapKeys(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
  INDEX idx_log_attr_value mapValues(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
  INDEX idx_lower_body lower(Body) TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 8
)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)
TTL toDateTime(Timestamp) + toIntervalDay(${HUD_LOGS_TTL_DAYS:-30})
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1, enable_block_number_column = 1, enable_block_offset_column = 1
COMMENT 'OTLP log records the collector exports, one row per record, in the ClickStack layout HyperDX reads. Holds the SDK forensics (EventName hud.forensic: error, duration and baseline investigations) and any other logs sent. Daily parts, kept HUD_LOGS_TTL_DAYS (default 30).';
