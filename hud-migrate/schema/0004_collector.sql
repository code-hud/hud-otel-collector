-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- Collector self-telemetry: the collector's own metrics (service.telemetry, level normal: what each receiver
-- accepted and refused, what each exporter sent and failed to send, queue sizes, batch sizes, memory and CPU), which
-- it sends every 30 s to itself on a localhost-only receiver and its metrics/self pipeline inserts here through a
-- second clickhouse exporter (config/clickhouse/collector-telemetry.yaml). Its own database, ${DATABASE}_collector,
-- next to the SQL tables', like ${DATABASE}_promql, so the Hud tables never hold a row about the collector. Skipped with
-- HUD_COLLECTOR_TELEMETRY=false, the switch that also turns the pipeline off.
-- The exporter's metric tables as its create_schema makes them (clickhouseexporter v0.165.0), with no views: the
-- points arrive cumulative (the collector's default), every series a running total since its process started (a
-- restart begins a new service.instance.id). Low volume (some hundred series per replica), so they keep 30 days.
CREATE DATABASE IF NOT EXISTS ${DATABASE}_collector;

CREATE TABLE IF NOT EXISTS ${DATABASE}_collector.otel_metrics_sum
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes of the collector process (service.name, service.instance.id, service.version, deployment.environment.name), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name (hud-otelcol)' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'Collector metric name (otelcol_receiver_accepted_metric_points, otelcol_exporter_send_failed_metric_points, otelcol_process_uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s, ms, By, {datapoints} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (receiver, processor, exporter, transport, data_type, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the collector''s 30 s export' CODEC(Delta, ZSTD(3)),
    Value Float64 COMMENT 'The sum: the running total since the collector started for a cumulative, the change over the interval for a delta, in MetricUnit' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) COMMENT 'OTLP exemplars of the point: sample values with their time, trace and span ids' CODEC(ZSTD(3)),
    AggregationTemporality Int32 COMMENT 'OTLP temporality: 2 cumulative (the collector''s default), 1 delta' CODEC(ZSTD(3)),
    IsMonotonic Boolean COMMENT 'Whether the sum only grows (a counter) rather than an up-down counter' CODEC(Delta, ZSTD(3)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_time_minmax TimeUnix TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, toStartOfHour(TimeUnix), cityHash64(Attributes), TimeUnix)
TTL TimeUnix + toIntervalDay(30)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1
COMMENT 'Raw OTLP sum points of the collector''s own metrics (service.telemetry, level normal), one row per data point: counters such as otelcol_receiver_accepted_metric_points, otelcol_exporter_sent_log_records and otelcol_exporter_send_failed_metric_points, and process sums. Cumulative. No view reads it. Kept 30 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}_collector.otel_metrics_gauge
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes of the collector process (service.name, service.instance.id, service.version, deployment.environment.name), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name (hud-otelcol)' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'Collector metric name (otelcol_receiver_accepted_metric_points, otelcol_exporter_send_failed_metric_points, otelcol_process_uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s, ms, By, {datapoints} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (receiver, processor, exporter, transport, data_type, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the collector''s 30 s export' CODEC(Delta, ZSTD(3)),
    Value Float64 COMMENT 'The sampled value, in MetricUnit' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) COMMENT 'OTLP exemplars of the point: sample values with their time, trace and span ids' CODEC(ZSTD(3)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_time_minmax TimeUnix TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, toStartOfHour(TimeUnix), cityHash64(Attributes), TimeUnix)
TTL TimeUnix + toIntervalDay(30)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1
COMMENT 'Raw OTLP gauge points of the collector''s own metrics, one row per data point: otelcol_process_memory_rss, otelcol_process_runtime_heap_alloc_bytes, otelcol_exporter_queue_size and the like. No view reads it. Kept 30 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}_collector.otel_metrics_histogram
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes of the collector process (service.name, service.instance.id, service.version, deployment.environment.name), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name (hud-otelcol)' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'Collector metric name (otelcol_receiver_accepted_metric_points, otelcol_exporter_send_failed_metric_points, otelcol_process_uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s, ms, By, {datapoints} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (receiver, processor, exporter, transport, data_type, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the collector''s 30 s export' CODEC(Delta, ZSTD(3)),
    Count UInt64 COMMENT 'Observations in the point' CODEC(Delta, ZSTD(3)),
    Sum Float64 COMMENT 'Sum of the observations, in MetricUnit' CODEC(ZSTD(3)),
    BucketCounts Array(UInt64) COMMENT 'Observations per bucket, one more than ExplicitBounds' CODEC(ZSTD(3)),
    ExplicitBounds Array(Float64) COMMENT 'Upper bounds of the buckets, in MetricUnit' CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) COMMENT 'OTLP exemplars of the point: sample values with their time, trace and span ids' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    Min Float64 COMMENT 'Smallest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    Max Float64 COMMENT 'Largest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    AggregationTemporality Int32 COMMENT 'OTLP temporality: 2 cumulative (the collector''s default), 1 delta' CODEC(ZSTD(3)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_time_minmax TimeUnix TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, toStartOfHour(TimeUnix), cityHash64(Attributes), TimeUnix)
TTL TimeUnix + toIntervalDay(30)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1
COMMENT 'Raw OTLP explicit-bucket histogram points of the collector''s own metrics, one row per data point: otelcol_processor_batch_batch_send_size and the like. Cumulative. No view reads it. Kept 30 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}_collector.otel_metrics_exponential_histogram
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes of the collector process (service.name, service.instance.id, service.version, deployment.environment.name), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name (hud-otelcol)' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'Collector metric name (otelcol_receiver_accepted_metric_points, otelcol_exporter_send_failed_metric_points, otelcol_process_uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s, ms, By, {datapoints} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (receiver, processor, exporter, transport, data_type, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the collector''s 30 s export' CODEC(Delta, ZSTD(3)),
    Count UInt64 COMMENT 'Observations in the point, zero ones included' CODEC(Delta, ZSTD(3)),
    Sum Float64 COMMENT 'Sum of the observations, in MetricUnit' CODEC(ZSTD(3)),
    Scale Int32 COMMENT 'Exponential histogram scale: bucket boundaries are powers of 2^(2^-Scale)' CODEC(ZSTD(3)),
    ZeroCount UInt64 COMMENT 'Observations of exactly zero, in no bucket' CODEC(ZSTD(3)),
    PositiveOffset Int32 COMMENT 'Index of the first positive bucket: bucket i covers (base^(PositiveOffset+i), base^(PositiveOffset+i+1)], i from 0' CODEC(ZSTD(3)),
    PositiveBucketCounts Array(UInt64) COMMENT 'Observations per positive bucket, from PositiveOffset' CODEC(ZSTD(3)),
    NegativeOffset Int32 COMMENT 'Index of the first negative bucket' CODEC(ZSTD(3)),
    NegativeBucketCounts Array(UInt64) COMMENT 'Observations per negative bucket' CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) COMMENT 'OTLP exemplars of the point: sample values with their time, trace and span ids' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    Min Float64 COMMENT 'Smallest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    Max Float64 COMMENT 'Largest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    AggregationTemporality Int32 COMMENT 'OTLP temporality: 2 cumulative (the collector''s default), 1 delta' CODEC(ZSTD(3)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_time_minmax TimeUnix TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, toStartOfHour(TimeUnix), cityHash64(Attributes), TimeUnix)
TTL TimeUnix + toIntervalDay(30)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1
COMMENT 'Raw OTLP base2 exponential histogram points of the collector''s own metrics, one row per data point. The collector sends none by default, created so every metric type has a table. Kept 30 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}_collector.otel_metrics_summary
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes of the collector process (service.name, service.instance.id, service.version, deployment.environment.name), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name (hud-otelcol)' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'Collector metric name (otelcol_receiver_accepted_metric_points, otelcol_exporter_send_failed_metric_points, otelcol_process_uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s, ms, By, {datapoints} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (receiver, processor, exporter, transport, data_type, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the collector''s 30 s export' CODEC(Delta, ZSTD(3)),
    Count UInt64 COMMENT 'Observations in the summary' CODEC(Delta, ZSTD(3)),
    Sum Float64 COMMENT 'Sum of the observations, in MetricUnit' CODEC(ZSTD(3)),
    ValueAtQuantiles Nested(Quantile Float64, Value Float64) COMMENT 'Precomputed quantiles (0-1) and their values, in MetricUnit' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_time_minmax TimeUnix TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, toStartOfHour(TimeUnix), cityHash64(Attributes), TimeUnix)
TTL TimeUnix + toIntervalDay(30)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1
COMMENT 'Raw OTLP summary points of the collector''s own metrics, one row per data point. The collector sends none by default, created so every metric type has a table. Kept 30 days.';
