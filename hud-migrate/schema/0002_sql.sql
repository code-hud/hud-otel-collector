-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- SQL metrics: the collector's clickhouse exporter inserts the SDK's OTLP metrics into the otel_metrics_* tables, its
-- own layout, so HyperDX reads them as a metrics source. They keep the raw rows 3 days, every metric the SDK sends
-- (a time range of the tables below can be rebuilt from them by running their views' SELECT), and materialized views
-- aggregate each insert into the tables below.
-- Every series is a delta (AggregationTemporality = 1) except the process gauges and limits. Durations are the SDK's
-- base2 exponential histograms: buckets maps the scale-2 bucket index k, (2^(k/4), 2^((k+1)/4)] seconds, to its count,
-- without the empty ones; the dashboards' hud_duration_quantile(q, sumMap(buckets)) reads a percentile. A point
-- at another scale goes onto scale 2 (exactly from a finer one, from a coarser one each bucket into its top scale-2
-- bucket). Zero and negative counts (none from the SDK) are dropped. Histogram counts are UInt64, as the exporter's
-- are; the sum metrics' (messages, issues, calls, ...) are Float64, as its sum values are.
--
-- The fine tables (below) are plain MergeTree with a row per export: a point goes as the SDK sent it to the row of its
-- TimeUnix, the end of the export interval it covers (aggregationInterval: 5 minutes by default, set per account),
-- nothing spread or merged (one row per key, pod and export). Each is filled by one view over one otel_metrics_* table:
-- the exporter inserts sums, histograms and gauges separately, and a table fed from two of them would get a half-empty
-- row from each insert. So endpoints and functions have a _durations table (histograms) and a _counters table (sums).
-- Queries sum them (sum, sumMap(buckets), groupUniqArrayArrayMap(1000)(attributes)), so a chart is no finer than the
-- export interval. They keep 30 days: the dashboards read them up to 30 days back and the hourly tables beyond. Each
-- fine table's insert rolls up, by the hour a point ends in, into endpoint_metrics_1h, function_metrics_1h or
-- process_metrics_1h, with their fine tables' columns, that keep 90 days, and endpoint and function tables also into
-- endpoint_metrics_lean_1h or function_metrics_lean_1h, the same without the session, caller and error type columns,
-- far fewer rows (what most charts read), that keep 180 days. They are AggregatingMergeTree of aggregate states (a
-- key's durations and counts arrive as separate rows and merge in the background): read them with -Merge, or
-- finalizeAggregation() a column to union it with a fine table's. Every table's parts are daily, so TTL drops whole
-- days. Names: fine tables have no grain suffix (the export interval is configurable), hourly ones end in _1h, and a
-- view is <target>_mv, or <target>_from_<source>_mv when several views write the table.
-- The views of one insert are not atomic: a failing view can leave others written, and the collector retries the whole
-- batch. Every table below keeps the hashes of its last 10000 inserts (non_replicated_deduplication_window, or
-- replicated_deduplication_window on replicated and Cloud tables), and the collector inserts synchronously with
-- deduplicate_blocks_in_dependent_materialized_views (config/clickhouse/clickhouse.yaml), so a retry only writes what
-- is missing instead of counting the rest twice.
--   endpoint_durations  by flow, SDK session (service.instance.id), deployment, status, method, route, end reason and
--                       queue: code.flow.duration (duration_count: the runs, errors are its 5xx ones) and
--                       hud.flow.e2e.duration (e2e_*: queue latency from publish to the end of the flow)
--   endpoint_counters   by flow, SDK session, deployment, method, route, status, end reason and queue:
--                       hud.flow.messages, hud.flow.issues by fingerprint and user error, hud.flow.calling_flows by
--                       the flow that called it (parent) and started it (root)
--   process_metrics     CPU, memory, event loop and uptime by SDK session and pod. The collector turns the memory sums
--                       into gauges (config/clickhouse/clickhouse.yaml), so they share the other gauges'
--                       row.
--   function_durations  code.function.call.duration (sampled, so duration_count can be below calls) by function,
--                       file, caller function (name and file), flow, content hash and deployment
--   function_counters   code.function.calls and code.function.errors by the same and error type
-- endpoints and functions hold every service, flow and function seen in 180 days, for the dashboard selectors.
-- endpoint_durations and function_durations also keep every other attribute the SDK sends (a new one needs no
-- migration), as long as the rest of their row: attributes holds up to 1000 values per attribute, attribute_counts the
-- runs (calls) per 'attribute=value', keyed by sipHash64('attribute=value') % 100000 so a row holds at most 100000
-- counts (values sharing a bucket add up). Session and host attributes stay out, so a lean row never grows with the
-- number of pods, and so do the function's short name and its flow's type, route and methods: they vary per call (the
-- flow's are in its name).
-- The endpoint tables also split a flow's rows by the feature flag combination its runs set (feature_flags, before
-- attributes, and last in their sorting keys). The SDK sends one hud.feature_flag.<key> attribute per flag, or only
-- hud.feature_flags.overflow when a flow has more combinations than it tracks; feature_flags is the 'key=value' pairs
-- sorted by key and joined with ',' ('fast_path=false,new_checkout=true'), '__hud_other__' (the SDK's overflow key) on
-- overflow, and '' without flags. These keys stay out of attributes. The SDK sends at most 16 combinations per flow, so
-- a flow has at most 17 times the rows; it puts flags on flow series only, so process and function tables have none.
-- ponytail: a flag key holding ',' or '=' can make two combinations the same string; the SDK doesn't forbid them.

-- The exporter's metric tables as its create_schema makes them (clickhouseexporter v0.165.0), keeping 3 days. Only
-- the metrics below go on to the tables after them; summaries and classic histograms (none from the SDK) stay here.
CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_sum
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes (deployment.environment.name, deployment.id, service.instance.id, k8s.pod.name, ...), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'OTLP metric name (code.flow.duration, hud.flow.issues, process.uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s for durations, By for bytes, 1 for ratios, {call} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (flow, function, issue, feature flags, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the end of the export interval for SDK deltas, the sample time for gauges' CODEC(Delta, ZSTD(3)),
    Value Float64 COMMENT 'The sum: the change over the interval for a delta, the running total for a cumulative, in MetricUnit' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) COMMENT 'OTLP exemplars of the point: sample values with their time, trace and span ids' CODEC(ZSTD(3)),
    AggregationTemporality Int32 COMMENT 'OTLP temporality: 1 delta (every SDK sum the views read), 2 cumulative' CODEC(ZSTD(3)),
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
TTL TimeUnix + toIntervalDay(3)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Raw OTLP sum points as the clickhouse exporter inserts them, one row per data point: the SDK flow and function counters (deltas) and its other process sums. Source of endpoint_counters_mv, function_counters_mv and functions_mv. Kept 3 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_gauge
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes (deployment.environment.name, deployment.id, service.instance.id, k8s.pod.name, ...), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'OTLP metric name (code.flow.duration, hud.flow.issues, process.uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s for durations, By for bytes, 1 for ratios, {call} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (flow, function, issue, feature flags, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the end of the export interval for SDK deltas, the sample time for gauges' CODEC(Delta, ZSTD(3)),
    Value Float64 COMMENT 'The sampled value, in MetricUnit (seconds, bytes, or a 0-1 ratio for utilizations)' CODEC(ZSTD(3)),
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
TTL TimeUnix + toIntervalDay(3)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Raw OTLP gauge points, one row per data point: the SDK process gauges (process.uptime, process.cpu.utilization, nodejs.eventloop.utilization) and the memory sums the collector turns into gauges (process.memory.usage, hud.process.memory.limit). Source of process_metrics_mv and endpoints_from_process_mv. Kept 3 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_histogram
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes (deployment.environment.name, deployment.id, service.instance.id, k8s.pod.name, ...), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'OTLP metric name (code.flow.duration, hud.flow.issues, process.uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s for durations, By for bytes, 1 for ratios, {call} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (flow, function, issue, feature flags, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the end of the export interval for SDK deltas, the sample time for gauges' CODEC(Delta, ZSTD(3)),
    Count UInt64 COMMENT 'Observations in the point' CODEC(Delta, ZSTD(3)),
    Sum Float64 COMMENT 'Sum of the observations, in MetricUnit' CODEC(ZSTD(3)),
    BucketCounts Array(UInt64) COMMENT 'Observations per bucket, one more than ExplicitBounds' CODEC(ZSTD(3)),
    ExplicitBounds Array(Float64) COMMENT 'Upper bounds of the buckets, in MetricUnit' CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) COMMENT 'OTLP exemplars of the point: sample values with their time, trace and span ids' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    Min Float64 COMMENT 'Smallest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    Max Float64 COMMENT 'Largest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    AggregationTemporality Int32 COMMENT 'OTLP temporality: 1 delta, 2 cumulative' CODEC(ZSTD(3)),
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
TTL TimeUnix + toIntervalDay(3)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Raw OTLP explicit-bucket histogram points, one row per data point. The SDK sends none (its durations are exponential histograms), so no view reads it. Kept 3 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_exponential_histogram
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes (deployment.environment.name, deployment.id, service.instance.id, k8s.pod.name, ...), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'OTLP metric name (code.flow.duration, hud.flow.issues, process.uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s for durations, By for bytes, 1 for ratios, {call} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (flow, function, issue, feature flags, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the end of the export interval for SDK deltas, the sample time for gauges' CODEC(Delta, ZSTD(3)),
    Count UInt64 COMMENT 'Observations in the point (SDK durations: runs or sampled calls), zero ones included' CODEC(Delta, ZSTD(3)),
    Sum Float64 COMMENT 'Sum of the observations, in MetricUnit (seconds for SDK durations)' CODEC(ZSTD(3)),
    Scale Int32 COMMENT 'Exponential histogram scale: bucket boundaries are powers of 2^(2^-Scale) (SDK: 2)' CODEC(ZSTD(3)),
    ZeroCount UInt64 COMMENT 'Observations of exactly zero, in no bucket' CODEC(ZSTD(3)),
    PositiveOffset Int32 COMMENT 'Index of the first positive bucket: bucket i covers (base^(PositiveOffset+i), base^(PositiveOffset+i+1)], i from 0' CODEC(ZSTD(3)),
    PositiveBucketCounts Array(UInt64) COMMENT 'Observations per positive bucket, from PositiveOffset' CODEC(ZSTD(3)),
    NegativeOffset Int32 COMMENT 'Index of the first negative bucket (none from the SDK)' CODEC(ZSTD(3)),
    NegativeBucketCounts Array(UInt64) COMMENT 'Observations per negative bucket (none from the SDK)' CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) COMMENT 'OTLP exemplars of the point: sample values with their time, trace and span ids' CODEC(ZSTD(3)),
    Flags UInt32 COMMENT 'OTLP data point flags (bit 0: no recorded value)' CODEC(ZSTD(3)),
    Min Float64 COMMENT 'Smallest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    Max Float64 COMMENT 'Largest observation, in MetricUnit, 0 when unset' CODEC(ZSTD(3)),
    AggregationTemporality Int32 COMMENT 'OTLP temporality: 1 delta (every SDK histogram the views read), 2 cumulative' CODEC(ZSTD(3)),
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
TTL TimeUnix + toIntervalDay(3)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Raw OTLP base2 exponential histogram points, one row per data point: the SDK durations code.flow.duration, hud.flow.e2e.duration and code.function.call.duration, deltas in seconds. Source of endpoint_durations_mv, function_durations_mv and endpoints_from_durations_mv. Kept 3 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_summary
(
    ResourceAttributes Map(LowCardinality(String), String)
        COMMENT 'Resource attributes (deployment.environment.name, deployment.id, service.instance.id, k8s.pod.name, ...), values as strings' CODEC(ZSTD(3)),
    ResourceSchemaUrl String COMMENT 'OTLP resource schema URL' CODEC(ZSTD(3)),
    ScopeName String COMMENT 'Instrumentation scope name' CODEC(ZSTD(3)),
    ScopeVersion String COMMENT 'Instrumentation scope version' CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) COMMENT 'Instrumentation scope attributes' CODEC(ZSTD(3)),
    ScopeDroppedAttrCount UInt32 COMMENT 'Scope attributes the sender dropped' CODEC(ZSTD(3)),
    ScopeSchemaUrl String COMMENT 'OTLP instrumentation scope schema URL' CODEC(ZSTD(3)),
    ServiceName LowCardinality(String) COMMENT 'Resource attribute service.name' CODEC(ZSTD(3)),
    MetricName LowCardinality(String) COMMENT 'OTLP metric name (code.flow.duration, hud.flow.issues, process.uptime, ...)' CODEC(ZSTD(3)),
    MetricDescription String COMMENT 'OTLP metric description as sent' CODEC(ZSTD(3)),
    MetricUnit String COMMENT 'OTLP metric unit (s for durations, By for bytes, 1 for ratios, {call} style for counts)' CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) COMMENT 'Data point attributes (flow, function, issue, feature flags, ...), values as strings' CODEC(ZSTD(3)),
    StartTimeUnix DateTime
        COMMENT 'Start of the point, second precision: of its interval for a delta, of the series for a cumulative, optional for a gauge (1970 when unset)' CODEC(Delta, ZSTD(3)),
    TimeUnix DateTime
        COMMENT 'Time of the point, second precision: the end of the export interval for SDK deltas, the sample time for gauges' CODEC(Delta, ZSTD(3)),
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
TTL TimeUnix + toIntervalDay(3)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Raw OTLP summary points, one row per data point. The SDK sends none, so no view reads it. Kept 3 days.';

-- An endpoint is a flow. A flow without a queue has no e2e_* (0 and {}).
CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_durations
(
    t DateTime COMMENT 'End of the export interval the point covers (its TimeUnix), second precision',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    flow LowCardinality(String) COMMENT 'Flow key, code.flow.name: the flow type and identity, e.g. http|/users|get',
    flow_type LowCardinality(String) COMMENT 'code.flow.type: http, graphql, kafka, sqs, grpc or another flow kind',
    method LowCardinality(String) COMMENT 'http.request.method, HTTP flows only, else empty',
    route LowCardinality(String) COMMENT 'http.route, HTTP flows only, else empty',
    status_code LowCardinality(String) COMMENT 'http.response.status_code of the runs (HTTP, GraphQL), else empty',
    end_reason LowCardinality(String)
        COMMENT 'hud.flow.end_reason: http.server_timeout, http.client_timeout or http.response_aborted, empty when the run ended normally',
    destination LowCardinality(String)
        COMMENT 'Queue or topic: messaging.destination.name, else messaging.destination.template, empty for flows without a queue',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    instance LowCardinality(String) COMMENT 'SDK session: resource attribute service.instance.id',
    duration_count UInt64 COMMENT 'Runs: the code.flow.duration count, exact since flows are not sampled',
    duration_sum Float64 COMMENT 'Total run duration, seconds',
    buckets Map(Int16, UInt64)
        COMMENT 'Run durations on scale 2: bucket k maps to the runs in (2^(k/4), 2^((k+1)/4)] seconds, empty buckets and zero durations left out',
    e2e_count UInt64 COMMENT 'Messages with a queue latency (hud.flow.e2e.duration count), 0 for flows without a queue',
    e2e_sum Float64 COMMENT 'Total queue latency, from publish or enqueue to the end of the flow, seconds',
    e2e_buckets Map(Int16, UInt64) COMMENT 'Queue latency on the same scale-2 buckets as buckets, seconds',
    last_seen DateTime COMMENT 'Latest point time (TimeUnix) in the row, second precision',
    feature_flags LowCardinality(String)
        COMMENT 'Feature flag combination of the runs: key=value pairs sorted by key and joined with commas, __hud_other__ on overflow, empty without flags',
    attributes Map(String, Array(String))
        COMMENT 'Every other point and resource attribute (session, host and flag ones left out): name to up to 1000 distinct values',
    attribute_counts Map(UInt32, UInt64)
        COMMENT 'Runs per attribute value: sipHash64(name=value) % 100000 to the runs, values sharing a key add up'
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, flow, t)
ORDER BY (env, service, flow, t, instance, flow_type, method, route, status_code, end_reason, destination, deployment,
    feature_flags)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Flow (endpoint) run durations and queue latency, from the code.flow.duration and hud.flow.e2e.duration delta histograms. One row per insert for each env, service, flow, export interval end t, SDK session, deployment, flow type, method, route, status, end reason, destination and feature flag combination: sum rows to aggregate. Filled by endpoint_durations_mv, kept 30 days.';

-- A flow's counters, all by method, route, status code, end reason and destination as the run had them, and each by
-- its own columns, '' in the others' rows: issues by fingerprint, framework result, caught and user error,
-- runs_by_caller (runs by the flow that called it (parent) and started it (root; multiple: the run had more than one))
-- by parent and root.
CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_counters
(
    t DateTime COMMENT 'End of the export interval the point covers (its TimeUnix), second precision',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    flow LowCardinality(String) COMMENT 'Flow key, code.flow.name: the flow type and identity, e.g. http|/users|get',
    flow_type LowCardinality(String) COMMENT 'code.flow.type: http, graphql, kafka, sqs, grpc or another flow kind',
    method LowCardinality(String) COMMENT 'http.request.method, HTTP flows only, else empty',
    route LowCardinality(String) COMMENT 'http.route, HTTP flows only, else empty',
    status_code LowCardinality(String) COMMENT 'http.response.status_code of the runs (HTTP, GraphQL), else empty',
    end_reason LowCardinality(String)
        COMMENT 'hud.flow.end_reason: http.server_timeout, http.client_timeout or http.response_aborted, empty when the run ended normally',
    destination LowCardinality(String)
        COMMENT 'Queue or topic: messaging.destination.name, else messaging.destination.template, empty for flows without a queue',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    fingerprint String COMMENT 'issue.fingerprint of issues rows: 16 hex chars of the SHA-256 of the error signature',
    framework_result LowCardinality(String)
        COMMENT 'hud.issue.framework_result: the framework outcome of the failed run (HTTP status, gRPC code, ...), empty if none',
    caught LowCardinality(String) COMMENT 'hud.issue.caught: true when the error was caught, false when it escaped, empty outside issues rows',
    user_error String COMMENT 'hud.issue.user_error: the error the app reported for the run (capped), empty if none',
    parent_service LowCardinality(String) COMMENT 'hud.parent.service.name of runs_by_caller rows: service of the calling flow',
    parent_flow LowCardinality(String) COMMENT 'hud.parent.flow.name of runs_by_caller rows: flow key of the calling flow',
    parent_multiple LowCardinality(String) COMMENT 'hud.parent.multiple of runs_by_caller rows: true when the run or batch had more than one caller',
    root_service LowCardinality(String) COMMENT 'hud.root.service.name: service of the flow that started the call chain',
    root_flow LowCardinality(String) COMMENT 'hud.root.flow.name: flow key of the flow that started the call chain',
    root_multiple LowCardinality(String) COMMENT 'hud.root.multiple: true when the run or batch had more than one root',
    instance LowCardinality(String) COMMENT 'SDK session: resource attribute service.instance.id',
    messages Float64 COMMENT 'hud.flow.messages: messages handled by batch and queue flows',
    issues Float64 COMMENT 'hud.flow.issues: times the flow recorded this issue',
    runs_by_caller Float64 COMMENT 'hud.flow.calling_flows: runs (messages, for batch flows) by calling and root flow and status',
    last_seen DateTime COMMENT 'Latest point time (TimeUnix) in the row, second precision',
    feature_flags LowCardinality(String)
        COMMENT 'Feature flag combination of the runs: key=value pairs sorted by key and joined with commas, __hud_other__ on overflow, empty without flags'
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, flow, t)
ORDER BY (env, service, flow, t, instance, flow_type, method, route, status_code, end_reason, destination, deployment,
    fingerprint, framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple,
    root_multiple, feature_flags)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Flow counters, from the hud.flow.messages, hud.flow.issues and hud.flow.calling_flows delta sums. One row per insert for each env, service, flow, export interval end t, SDK session, deployment, method, route, status, end reason, destination, feature flag combination and the key columns of its metric, the others empty: issues by fingerprint, framework result, caught and user error, runs_by_caller by parent and root. Sum rows to aggregate. Filled by endpoint_counters_mv, kept 30 days.';

-- The endpoint union is installed in 0004: existing hud.3 endpoint tables don't have its columns.

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h
(
    hour DateTime COMMENT 'Start of the hour the points end in (toStartOfHour of the fine table t)',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    flow LowCardinality(String) COMMENT 'Flow key, code.flow.name: the flow type and identity, e.g. http|/users|get',
    flow_type LowCardinality(String) COMMENT 'code.flow.type: http, graphql, kafka, sqs, grpc or another flow kind',
    method LowCardinality(String) COMMENT 'http.request.method of the runs (HTTP flows), in duration and counter rows, else empty',
    route LowCardinality(String) COMMENT 'http.route of the runs (HTTP flows), in duration and counter rows, else empty',
    status_code LowCardinality(String)
        COMMENT 'http.response.status_code of the runs (HTTP, GraphQL), in duration and counter rows, else empty',
    end_reason LowCardinality(String)
        COMMENT 'hud.flow.end_reason of the runs, in duration and counter rows: http.server_timeout, http.client_timeout or http.response_aborted, else empty',
    destination LowCardinality(String)
        COMMENT 'Queue or topic (messaging.destination.name, else .template) of duration and counter rows, empty for flows without a queue',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    fingerprint String COMMENT 'issue.fingerprint of issues rows: 16 hex chars of the SHA-256 of the error signature',
    framework_result LowCardinality(String)
        COMMENT 'hud.issue.framework_result: the framework outcome of the failed run (HTTP status, gRPC code, ...), empty if none',
    caught LowCardinality(String) COMMENT 'hud.issue.caught: true when the error was caught, false when it escaped, empty outside issues rows',
    user_error String COMMENT 'hud.issue.user_error: the error the app reported for the run (capped), empty if none',
    parent_service LowCardinality(String) COMMENT 'hud.parent.service.name of runs_by_caller rows: service of the calling flow',
    parent_flow LowCardinality(String) COMMENT 'hud.parent.flow.name of runs_by_caller rows: flow key of the calling flow',
    parent_multiple LowCardinality(String) COMMENT 'hud.parent.multiple of runs_by_caller rows: true when the run or batch had more than one caller',
    root_service LowCardinality(String) COMMENT 'hud.root.service.name: service of the flow that started the call chain',
    root_flow LowCardinality(String) COMMENT 'hud.root.flow.name: flow key of the flow that started the call chain',
    root_multiple LowCardinality(String) COMMENT 'hud.root.multiple: true when the run or batch had more than one root',
    instance LowCardinality(String) COMMENT 'SDK session: resource attribute service.instance.id',
    duration_count SimpleAggregateFunction(sum, UInt64) COMMENT 'Runs (code.flow.duration count, exact), 0 in counter rows',
    duration_sum SimpleAggregateFunction(sum, Float64) COMMENT 'Total run duration, seconds',
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64))
        COMMENT 'Run durations on scale 2: bucket k maps to the runs in (2^(k/4), 2^((k+1)/4)] seconds, empty buckets and zero durations left out',
    e2e_count SimpleAggregateFunction(sum, UInt64) COMMENT 'Messages with a queue latency (hud.flow.e2e.duration count)',
    e2e_sum SimpleAggregateFunction(sum, Float64) COMMENT 'Total queue latency, from publish or enqueue to the end of the flow, seconds',
    e2e_buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)) COMMENT 'Queue latency on the same scale-2 buckets as buckets, seconds',
    messages SimpleAggregateFunction(sum, Float64) COMMENT 'hud.flow.messages: messages handled by batch and queue flows',
    issues SimpleAggregateFunction(sum, Float64) COMMENT 'hud.flow.issues: times the flow recorded this issue',
    runs_by_caller SimpleAggregateFunction(sum, Float64)
        COMMENT 'hud.flow.calling_flows: runs (messages, for batch flows) by calling and root flow and status',
    last_seen SimpleAggregateFunction(max, DateTime) COMMENT 'Latest point time (TimeUnix) in the row, second precision',
    feature_flags LowCardinality(String)
        COMMENT 'Feature flag combination of the runs: key=value pairs sorted by key and joined with commas, __hud_other__ on overflow, empty without flags',
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String)))
        COMMENT 'State of every other attribute of the duration rows: name to up to 1000 distinct values (read with groupUniqArrayArrayMapMerge(1000))',
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
        COMMENT 'Runs per attribute value: sipHash64(name=value) % 100000 to the runs, values sharing a key add up'
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, flow, hour)
ORDER BY (env, service, flow, hour, instance, flow_type, method, route, status_code, end_reason, destination, deployment,
    fingerprint, framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple,
    root_multiple, feature_flags)
TTL hour + toIntervalDay(90)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Hourly rollup of endpoint_durations and endpoint_counters with all their columns, SDK session included. AggregatingMergeTree: a key has separate duration and counter rows until merged, so read with sum, sumMap, max and groupUniqArrayArrayMapMerge(1000) grouped by the columns needed. Filled by endpoint_metrics_1h_from_durations_mv and endpoint_metrics_1h_from_counters_mv, kept 90 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h
(
    hour DateTime COMMENT 'Start of the hour the points end in (toStartOfHour of the fine table t)',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    flow LowCardinality(String) COMMENT 'Flow key, code.flow.name: the flow type and identity, e.g. http|/users|get',
    flow_type LowCardinality(String) COMMENT 'code.flow.type: http, graphql, kafka, sqs, grpc or another flow kind',
    method LowCardinality(String) COMMENT 'http.request.method of the runs (HTTP flows), in duration and counter rows, else empty',
    route LowCardinality(String) COMMENT 'http.route of the runs (HTTP flows), in duration and counter rows, else empty',
    status_code LowCardinality(String)
        COMMENT 'http.response.status_code of the runs (HTTP, GraphQL), in duration and counter rows, else empty',
    end_reason LowCardinality(String)
        COMMENT 'hud.flow.end_reason of the runs, in duration and counter rows: http.server_timeout, http.client_timeout or http.response_aborted, else empty',
    destination LowCardinality(String)
        COMMENT 'Queue or topic (messaging.destination.name, else .template) of duration and counter rows, empty for flows without a queue',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    fingerprint String COMMENT 'issue.fingerprint of issues rows: 16 hex chars of the SHA-256 of the error signature',
    framework_result LowCardinality(String)
        COMMENT 'hud.issue.framework_result: the framework outcome of the failed run (HTTP status, gRPC code, ...), empty if none',
    caught LowCardinality(String) COMMENT 'hud.issue.caught: true when the error was caught, false when it escaped, empty outside issues rows',
    user_error String COMMENT 'hud.issue.user_error: the error the app reported for the run (capped), empty if none',
    parent_service LowCardinality(String) COMMENT 'hud.parent.service.name of runs_by_caller rows: service of the calling flow',
    parent_flow LowCardinality(String) COMMENT 'hud.parent.flow.name of runs_by_caller rows: flow key of the calling flow',
    parent_multiple LowCardinality(String) COMMENT 'hud.parent.multiple of runs_by_caller rows: true when the run or batch had more than one caller',
    root_service LowCardinality(String) COMMENT 'hud.root.service.name: service of the flow that started the call chain',
    root_flow LowCardinality(String) COMMENT 'hud.root.flow.name: flow key of the flow that started the call chain',
    root_multiple LowCardinality(String) COMMENT 'hud.root.multiple: true when the run or batch had more than one root',
    duration_count SimpleAggregateFunction(sum, UInt64) COMMENT 'Runs (code.flow.duration count, exact), 0 in counter rows',
    duration_sum SimpleAggregateFunction(sum, Float64) COMMENT 'Total run duration, seconds',
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64))
        COMMENT 'Run durations on scale 2: bucket k maps to the runs in (2^(k/4), 2^((k+1)/4)] seconds, empty buckets and zero durations left out',
    e2e_count SimpleAggregateFunction(sum, UInt64) COMMENT 'Messages with a queue latency (hud.flow.e2e.duration count)',
    e2e_sum SimpleAggregateFunction(sum, Float64) COMMENT 'Total queue latency, from publish or enqueue to the end of the flow, seconds',
    e2e_buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)) COMMENT 'Queue latency on the same scale-2 buckets as buckets, seconds',
    messages SimpleAggregateFunction(sum, Float64) COMMENT 'hud.flow.messages: messages handled by batch and queue flows',
    issues SimpleAggregateFunction(sum, Float64) COMMENT 'hud.flow.issues: times the flow recorded this issue',
    runs_by_caller SimpleAggregateFunction(sum, Float64)
        COMMENT 'hud.flow.calling_flows: runs (messages, for batch flows) by calling and root flow and status',
    last_seen SimpleAggregateFunction(max, DateTime) COMMENT 'Latest point time (TimeUnix) in the row, second precision',
    feature_flags LowCardinality(String)
        COMMENT 'Feature flag combination of the runs: key=value pairs sorted by key and joined with commas, __hud_other__ on overflow, empty without flags',
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String)))
        COMMENT 'State of every other attribute of the duration rows: name to up to 1000 distinct values (read with groupUniqArrayArrayMapMerge(1000))',
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
        COMMENT 'Runs per attribute value: sipHash64(name=value) % 100000 to the runs, values sharing a key add up'
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, flow, hour)
ORDER BY (env, service, flow, hour, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple, root_multiple,
    feature_flags)
TTL hour + toIntervalDay(180)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Hourly rollup like endpoint_metrics_1h without the SDK session (instance), so far fewer rows: what most charts read. Read with sum, sumMap, max and groupUniqArrayArrayMapMerge(1000). Filled by endpoint_metrics_lean_1h_from_durations_mv and endpoint_metrics_lean_1h_from_counters_mv, kept 180 days.';

-- One row per session and export of its process metrics. uptime is the latest process.uptime (it only grows),
-- so the session started at last_seen - uptime. elu averages over the event loop's threads.
CREATE TABLE IF NOT EXISTS ${DATABASE}.process_metrics
(
    t DateTime COMMENT 'Sample time of the process gauges (their TimeUnix), second precision',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    instance LowCardinality(String) COMMENT 'SDK session: resource attribute service.instance.id',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    pod LowCardinality(String) COMMENT 'Resource attribute k8s.pod.name, empty outside Kubernetes',
    last_seen DateTime COMMENT 'Latest sample time (TimeUnix) in the row, second precision',
    uptime Float64 COMMENT 'process.uptime: seconds since the process started, the latest (max) sample',
    cpu_sum Float64
        COMMENT 'Sum of the process.cpu.utilization samples: CPU time since the previous sample over elapsed time and hud.process.cpu.limit, 0-1 each',
    cpu_count UInt64 COMMENT 'Number of process.cpu.utilization samples (average: cpu_sum / cpu_count)',
    cpu_max Float64 COMMENT 'Largest process.cpu.utilization sample, 0-1 of the CPU limit',
    memory_sum Float64 COMMENT 'Sum of the process.memory.usage samples (resident set size), bytes',
    memory_count UInt64 COMMENT 'Number of process.memory.usage samples (average: memory_sum / memory_count)',
    memory_max Float64 COMMENT 'Largest process.memory.usage sample, bytes',
    memory_limit Float64
        COMMENT 'hud.process.memory.limit: memory available to the process (pod limit, else machine total), bytes',
    elu_sum Float64 COMMENT 'Sum of the nodejs.eventloop.utilization samples of every thread, 0-1 each',
    elu_count UInt64
        COMMENT 'Number of nodejs.eventloop.utilization samples, one per thread and sample (average: elu_sum / elu_count)',
    elu_max Float64 COMMENT 'Largest nodejs.eventloop.utilization sample of any thread, 0-1'
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, instance, t, deployment, pod)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Process CPU, memory, event loop and uptime, from the SDK process gauges in otel_metrics_gauge. One row per insert for each env, service, SDK session, deployment, pod and sample time t: sums, counts and maxima of the samples, so an average is sum / count. Filled by process_metrics_mv, kept 30 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.process_metrics_1h
(
    hour DateTime COMMENT 'Start of the hour the points end in (toStartOfHour of the fine table t)',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    instance LowCardinality(String) COMMENT 'SDK session: resource attribute service.instance.id',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    pod LowCardinality(String) COMMENT 'Resource attribute k8s.pod.name, empty outside Kubernetes',
    last_seen SimpleAggregateFunction(max, DateTime) COMMENT 'Latest sample time (TimeUnix) in the row, second precision',
    uptime SimpleAggregateFunction(max, Float64)
        COMMENT 'process.uptime: seconds since the process started, the latest (max) sample',
    cpu_sum SimpleAggregateFunction(sum, Float64)
        COMMENT 'Sum of the process.cpu.utilization samples: CPU time since the previous sample over elapsed time and hud.process.cpu.limit, 0-1 each',
    cpu_count SimpleAggregateFunction(sum, UInt64)
        COMMENT 'Number of process.cpu.utilization samples (average: cpu_sum / cpu_count)',
    cpu_max SimpleAggregateFunction(max, Float64) COMMENT 'Largest process.cpu.utilization sample, 0-1 of the CPU limit',
    memory_sum SimpleAggregateFunction(sum, Float64)
        COMMENT 'Sum of the process.memory.usage samples (resident set size), bytes',
    memory_count SimpleAggregateFunction(sum, UInt64)
        COMMENT 'Number of process.memory.usage samples (average: memory_sum / memory_count)',
    memory_max SimpleAggregateFunction(max, Float64) COMMENT 'Largest process.memory.usage sample, bytes',
    memory_limit SimpleAggregateFunction(max, Float64)
        COMMENT 'hud.process.memory.limit: memory available to the process (pod limit, else machine total), bytes',
    elu_sum SimpleAggregateFunction(sum, Float64)
        COMMENT 'Sum of the nodejs.eventloop.utilization samples of every thread, 0-1 each',
    elu_count SimpleAggregateFunction(sum, UInt64)
        COMMENT 'Number of nodejs.eventloop.utilization samples, one per thread and sample (average: elu_sum / elu_count)',
    elu_max SimpleAggregateFunction(max, Float64)
        COMMENT 'Largest nodejs.eventloop.utilization sample of any thread, 0-1'
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
ORDER BY (env, service, instance, hour, deployment, pod)
TTL hour + toIntervalDay(90)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Hourly rollup of process_metrics by env, service, SDK session, deployment and pod. AggregatingMergeTree: read with sum and max. Filled by process_metrics_1h_mv, kept 90 days.';

-- A function as called by one caller function (name and file) in one flow.
CREATE TABLE IF NOT EXISTS ${DATABASE}.function_durations
(
    t DateTime COMMENT 'End of the export interval the point covers (its TimeUnix), second precision',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    function String COMMENT 'code.function.name: the function',
    file LowCardinality(String) COMMENT 'code.file.path: source file of the function',
    caller String COMMENT 'code.function.caller.name: the function that called it',
    caller_file LowCardinality(String) COMMENT 'code.function.caller.file.path: source file of the caller',
    flow LowCardinality(String) COMMENT 'code.flow.name: key of the flow the call ran in',
    content_hash String COMMENT 'hud.function.content_hash: hash of the function source, changes when its code changes',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    duration_sum Float64 COMMENT 'Total duration of the sampled calls, seconds',
    duration_count UInt64 COMMENT 'Sampled calls (code.function.call.duration count), can be below calls',
    buckets Map(Int16, UInt64)
        COMMENT 'Sampled call durations on scale 2: bucket k maps to the calls in (2^(k/4), 2^((k+1)/4)] seconds, empty buckets and zero durations left out',
    attributes Map(String, Array(String))
        COMMENT 'Every other point and resource attribute (session and host ones left out): name to up to 1000 distinct values',
    attribute_counts Map(UInt32, UInt64)
        COMMENT 'Sampled calls per attribute value: sipHash64(name=value) % 100000 to the calls, values sharing a key add up'
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, function, file, t)
ORDER BY (env, service, function, file, t, caller, caller_file, flow, content_hash, deployment)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Function call durations, from the code.function.call.duration delta histogram (sampled calls). One row per insert for each env, service, function, file, caller (name and file), flow, content hash, deployment and export interval end t: sum rows to aggregate. Filled by function_durations_mv, kept 30 days.';

-- The same keys and error_type: error rows carry their error_type, call rows ''.
CREATE TABLE IF NOT EXISTS ${DATABASE}.function_counters
(
    t DateTime COMMENT 'End of the export interval the point covers (its TimeUnix), second precision',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    function String COMMENT 'code.function.name: the function',
    file LowCardinality(String) COMMENT 'code.file.path: source file of the function',
    caller String COMMENT 'code.function.caller.name: the function that called it',
    caller_file LowCardinality(String) COMMENT 'code.function.caller.file.path: source file of the caller',
    flow LowCardinality(String) COMMENT 'code.flow.name: key of the flow the call ran in',
    content_hash String COMMENT 'hud.function.content_hash: hash of the function source, changes when its code changes',
    error_type LowCardinality(String)
        COMMENT 'error.type of errors rows: the exception class that escaped, empty in calls rows',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    calls Float64 COMMENT 'code.function.calls: invocations, exact (not sampled)',
    errors Float64 COMMENT 'code.function.errors: invocations that an exception escaped'
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, function, file, t)
ORDER BY (env, service, function, file, t, caller, caller_file, flow, content_hash, error_type, deployment)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Function calls and errors, from the code.function.calls and code.function.errors delta sums (exact, not sampled). One row per insert for each function_durations key and error type: sum rows to aggregate. Filled by function_counters_mv, kept 30 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.function_metrics_1h
(
    hour DateTime COMMENT 'Start of the hour the points end in (toStartOfHour of the fine table t)',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    function String COMMENT 'code.function.name: the function',
    file LowCardinality(String) COMMENT 'code.file.path: source file of the function',
    caller String COMMENT 'code.function.caller.name: the function that called it',
    caller_file LowCardinality(String) COMMENT 'code.function.caller.file.path: source file of the caller',
    flow LowCardinality(String) COMMENT 'code.flow.name: key of the flow the call ran in',
    content_hash String COMMENT 'hud.function.content_hash: hash of the function source, changes when its code changes',
    error_type LowCardinality(String)
        COMMENT 'error.type of errors rows: the exception class that escaped, empty in calls rows',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    calls SimpleAggregateFunction(sum, Float64) COMMENT 'code.function.calls: invocations, exact (not sampled)',
    errors SimpleAggregateFunction(sum, Float64) COMMENT 'code.function.errors: invocations that an exception escaped',
    duration_sum SimpleAggregateFunction(sum, Float64)
        COMMENT 'Total duration of the sampled calls, seconds, 0 in counter rows',
    duration_count SimpleAggregateFunction(sum, UInt64)
        COMMENT 'Sampled calls (code.function.call.duration count), can be below calls',
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64))
        COMMENT 'Sampled call durations on scale 2: bucket k maps to the calls in (2^(k/4), 2^((k+1)/4)] seconds, empty buckets and zero durations left out',
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String)))
        COMMENT 'State of every other attribute: name to up to 1000 distinct values (read with groupUniqArrayArrayMapMerge(1000))',
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
        COMMENT 'Sampled calls per attribute value: sipHash64(name=value) % 100000 to the calls, values sharing a key add up'
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, function, file, hour)
ORDER BY (env, service, function, file, hour, caller, caller_file, flow, content_hash, error_type, deployment)
TTL hour + toIntervalDay(90)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Hourly rollup of function_durations and function_counters with all their columns. AggregatingMergeTree: a key has separate duration and counter rows until merged, so read with sum, sumMap and groupUniqArrayArrayMapMerge(1000). Filled by function_metrics_1h_from_durations_mv and function_metrics_1h_from_counters_mv, kept 90 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.function_metrics_lean_1h
(
    hour DateTime COMMENT 'Start of the hour the points end in (toStartOfHour of the fine table t)',
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    function String COMMENT 'code.function.name: the function',
    file LowCardinality(String) COMMENT 'code.file.path: source file of the function',
    flow LowCardinality(String) COMMENT 'code.flow.name: key of the flow the call ran in',
    deployment LowCardinality(String) COMMENT 'Resource attribute deployment.id',
    calls SimpleAggregateFunction(sum, Float64) COMMENT 'code.function.calls: invocations, exact (not sampled)',
    errors SimpleAggregateFunction(sum, Float64) COMMENT 'code.function.errors: invocations that an exception escaped',
    duration_sum SimpleAggregateFunction(sum, Float64)
        COMMENT 'Total duration of the sampled calls, seconds, 0 in counter rows',
    duration_count SimpleAggregateFunction(sum, UInt64)
        COMMENT 'Sampled calls (code.function.call.duration count), can be below calls',
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64))
        COMMENT 'Sampled call durations on scale 2: bucket k maps to the calls in (2^(k/4), 2^((k+1)/4)] seconds, empty buckets and zero durations left out',
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String)))
        COMMENT 'State of every other attribute: name to up to 1000 distinct values (read with groupUniqArrayArrayMapMerge(1000))',
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
        COMMENT 'Sampled calls per attribute value: sipHash64(name=value) % 100000 to the calls, values sharing a key add up'
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
ORDER BY (env, service, function, file, hour, flow, deployment)
TTL hour + toIntervalDay(180)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Hourly rollup like function_metrics_1h without the caller, caller file, content hash and error type columns, far fewer rows. Read with sum, sumMap and groupUniqArrayArrayMapMerge(1000). Filled by function_metrics_lean_1h_from_durations_mv and function_metrics_lean_1h_from_counters_mv, kept 180 days.';

-- A service with sessions (process metrics) has a row with flow = ''.
CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoints
(
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    flow String
        COMMENT 'Flow key (code.flow.name), empty in the row of a service that sends process metrics (process.uptime)',
    last_seen SimpleAggregateFunction(max, DateTime)
        COMMENT 'Latest time the flow (or, with an empty flow, the service) sent a point, second precision'
)
ENGINE = AggregatingMergeTree
ORDER BY (env, service, flow)
TTL last_seen + toIntervalDay(180)
SETTINGS non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Every service and flow seen in the last 180 days, one row per env, service and flow once merged, for the dashboard selectors. A service that sends process metrics also has a row with an empty flow. Read with max(last_seen). Filled by endpoints_from_durations_mv and endpoints_from_process_mv.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.functions
(
    env LowCardinality(String) COMMENT 'Resource attribute deployment.environment.name',
    service LowCardinality(String) COMMENT 'Resource attribute service.name',
    flow String COMMENT 'code.flow.name: key of the flow the function was called in',
    function String COMMENT 'code.function.name',
    last_seen SimpleAggregateFunction(max, DateTime)
        COMMENT 'Latest time the function sent code.function.calls in the flow, second precision'
)
ENGINE = AggregatingMergeTree
ORDER BY (env, service, flow, function)
TTL last_seen + toIntervalDay(180)
SETTINGS non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000
COMMENT 'Every function seen in the last 180 days, one row per env, service, flow and function once merged, for the dashboard selectors. Read with max(last_seen). Filled by functions_mv.';

-- Fine tables, from the otel_metrics_* tables. bucket_keys are a histogram point's bucket indexes on scale 2, other its
-- other attributes (the duration views keep them, one per run or call).

-- ClickHouse validates a materialized view's SELECT against its target before honoring IF NOT EXISTS.
-- Keep these legacy definitions replayable on hud.3 without changing the existing views or sorting keys.
ALTER TABLE ${DATABASE}.endpoint_durations ADD COLUMN IF NOT EXISTS feature_flags LowCardinality(String) DEFAULT '';
ALTER TABLE ${DATABASE}.endpoint_counters ADD COLUMN IF NOT EXISTS feature_flags LowCardinality(String) DEFAULT '';
ALTER TABLE ${DATABASE}.endpoint_counters ADD COLUMN IF NOT EXISTS method LowCardinality(String) DEFAULT '';
ALTER TABLE ${DATABASE}.endpoint_counters ADD COLUMN IF NOT EXISTS route LowCardinality(String) DEFAULT '';
ALTER TABLE ${DATABASE}.endpoint_counters ADD COLUMN IF NOT EXISTS end_reason LowCardinality(String) DEFAULT '';
ALTER TABLE ${DATABASE}.endpoint_counters ADD COLUMN IF NOT EXISTS runs_by_caller Float64 DEFAULT 0;
ALTER TABLE ${DATABASE}.endpoint_metrics_1h ADD COLUMN IF NOT EXISTS feature_flags LowCardinality(String) DEFAULT '';
ALTER TABLE ${DATABASE}.endpoint_metrics_1h ADD COLUMN IF NOT EXISTS runs_by_caller SimpleAggregateFunction(sum, Float64) DEFAULT 0;
ALTER TABLE ${DATABASE}.endpoint_metrics_lean_1h ADD COLUMN IF NOT EXISTS feature_flags LowCardinality(String) DEFAULT '';
ALTER TABLE ${DATABASE}.endpoint_metrics_lean_1h ADD COLUMN IF NOT EXISTS runs_by_caller SimpleAggregateFunction(sum, Float64) DEFAULT 0;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_durations_mv TO ${DATABASE}.endpoint_durations
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH MetricName = 'code.flow.duration' AS run,
    arrayMap(i -> toInt16(ceil((PositiveOffset + i) * exp2(2 - Scale)) - 1), arrayEnumerate(PositiveBucketCounts)) AS bucket_keys,
    mapFilter((k, n) -> n != 0, mapFromArrays(bucket_keys, PositiveBucketCounts)) AS point_buckets,
    mapFilter((k, v) -> v != '' AND NOT startsWith(k, 'hud.feature_flag') AND NOT has(['service.name',
        'deployment.environment.name', 'deployment.id', 'code.flow.name', 'code.flow.type', 'http.request.method',
        'http.route', 'http.response.status_code', 'hud.flow.end_reason', 'messaging.destination.name',
        'messaging.destination.template', 'service.instance.id', 'k8s.pod.name', 'k8s.pod.uid', 'process.pid', 'host.name',
        'host.id', 'container.id'], k), mapConcat(Attributes, ResourceAttributes)) AS other,
    mapFilter((k, v) -> startsWith(k, 'hud.feature_flag.'), Attributes) AS flags
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['http.request.method'] AS method, Attributes['http.route'] AS route,
    Attributes['http.response.status_code'] AS status_code, Attributes['hud.flow.end_reason'] AS end_reason,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['service.instance.id'] AS instance,
    if(Attributes['hud.feature_flags.overflow'] = 'true', '__hud_other__',
        arrayStringConcat(arraySort(arrayMap((k, v) -> concat(substring(k, 18), '=', v), mapKeys(flags), mapValues(flags))),
        ',')) AS feature_flags,
    sumIf(Count, run) AS duration_count, sumIf(Sum, run) AS duration_sum, sumMapIf(point_buckets, run) AS buckets,
    sumIf(Count, NOT run) AS e2e_count, sumIf(Sum, NOT run) AS e2e_sum, sumMapIf(point_buckets, NOT run) AS e2e_buckets,
    max(TimeUnix) AS last_seen, groupUniqArrayMapIf(1000)(other, run) AS attributes,
    sumMapIf(mapApply((k, v) -> (sipHash64(concat(k, '=', v)) % 100000, Count), other), run) AS attribute_counts
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName IN ('code.flow.duration', 'hud.flow.e2e.duration') AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance,
    feature_flags
COMMENT 'Reads code.flow.duration and hud.flow.e2e.duration delta points from otel_metrics_exponential_histogram, maps their buckets onto scale 2 and writes them to endpoint_durations, grouped per insert.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_counters_mv TO ${DATABASE}.endpoint_counters
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH mapFilter((k, v) -> startsWith(k, 'hud.feature_flag.'), Attributes) AS flags
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['http.request.method'] AS method, Attributes['http.route'] AS route,
    Attributes['http.response.status_code'] AS status_code, Attributes['hud.flow.end_reason'] AS end_reason,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination,
    ResourceAttributes['deployment.id'] AS deployment,
    Attributes['issue.fingerprint'] AS fingerprint, Attributes['hud.issue.framework_result'] AS framework_result,
    Attributes['hud.issue.caught'] AS caught, Attributes['hud.issue.user_error'] AS user_error,
    if(MetricName = 'hud.flow.calling_flows', Attributes['hud.parent.service.name'], '') AS parent_service,
    if(MetricName = 'hud.flow.calling_flows', Attributes['hud.parent.flow.name'], '') AS parent_flow,
    if(MetricName = 'hud.flow.calling_flows', Attributes['hud.parent.multiple'], '') AS parent_multiple,
    Attributes['hud.root.service.name'] AS root_service, Attributes['hud.root.flow.name'] AS root_flow,
    Attributes['hud.root.multiple'] AS root_multiple,
    ResourceAttributes['service.instance.id'] AS instance,
    if(Attributes['hud.feature_flags.overflow'] = 'true', '__hud_other__',
        arrayStringConcat(arraySort(arrayMap((k, v) -> concat(substring(k, 18), '=', v), mapKeys(flags), mapValues(flags))),
        ',')) AS feature_flags,
    sumIf(Value, MetricName = 'hud.flow.messages') AS messages, sumIf(Value, MetricName = 'hud.flow.issues') AS issues,
    sumIf(Value, MetricName = 'hud.flow.calling_flows') AS runs_by_caller, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName IN ('hud.flow.messages', 'hud.flow.issues', 'hud.flow.calling_flows') AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, instance, feature_flags
COMMENT 'Reads hud.flow.messages, hud.flow.issues and hud.flow.calling_flows delta points from otel_metrics_sum and writes them to endpoint_counters, grouped per insert.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.process_metrics_mv TO ${DATABASE}.process_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t, ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    ResourceAttributes['service.instance.id'] AS instance, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['k8s.pod.name'] AS pod,
    max(TimeUnix) AS last_seen, maxIf(Value, MetricName = 'process.uptime') AS uptime,
    sumIf(Value, MetricName = 'process.cpu.utilization') AS cpu_sum, countIf(MetricName = 'process.cpu.utilization') AS cpu_count,
    maxIf(Value, MetricName = 'process.cpu.utilization') AS cpu_max,
    sumIf(Value, MetricName = 'process.memory.usage') AS memory_sum, countIf(MetricName = 'process.memory.usage') AS memory_count,
    maxIf(Value, MetricName = 'process.memory.usage') AS memory_max,
    maxIf(Value, MetricName = 'hud.process.memory.limit') AS memory_limit,
    sumIf(Value, MetricName = 'nodejs.eventloop.utilization') AS elu_sum,
    countIf(MetricName = 'nodejs.eventloop.utilization') AS elu_count,
    maxIf(Value, MetricName = 'nodejs.eventloop.utilization') AS elu_max
FROM ${DATABASE}.otel_metrics_gauge
WHERE MetricName IN ('process.uptime', 'process.cpu.utilization', 'nodejs.eventloop.utilization', 'process.memory.usage',
    'hud.process.memory.limit')
GROUP BY t, env, service, instance, deployment, pod
COMMENT 'Reads the process gauges from otel_metrics_gauge and writes their sums, counts and maxima to process_metrics, grouped per insert.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_durations_mv TO ${DATABASE}.function_durations
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH arrayMap(i -> toInt16(ceil((PositiveOffset + i) * exp2(2 - Scale)) - 1), arrayEnumerate(PositiveBucketCounts)) AS bucket_keys,
    mapFilter((k, v) -> v != '' AND NOT has(['service.name', 'deployment.environment.name', 'deployment.id', 'code.function.name',
        'code.file.path', 'code.flow.name', 'code.function.caller.name', 'code.function.caller.file.path',
        'hud.function.content_hash', 'code.flow.type', 'http.route', 'hud.endpoint.methods', 'hud.function.short_name',
        'service.instance.id', 'k8s.pod.name', 'k8s.pod.uid', 'process.pid', 'host.name', 'host.id', 'container.id'], k),
        mapConcat(Attributes, ResourceAttributes)) AS other
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    Attributes['code.function.name'] AS function, Attributes['code.file.path'] AS file,
    Attributes['code.function.caller.name'] AS caller, Attributes['code.function.caller.file.path'] AS caller_file,
    Attributes['code.flow.name'] AS flow,
    Attributes['hud.function.content_hash'] AS content_hash, ResourceAttributes['deployment.id'] AS deployment,
    sum(Sum) AS duration_sum, sum(Count) AS duration_count,
    sumMap(mapFilter((k, n) -> n != 0, mapFromArrays(bucket_keys, PositiveBucketCounts))) AS buckets,
    groupUniqArrayMap(1000)(other) AS attributes,
    sumMap(mapApply((k, v) -> (sipHash64(concat(k, '=', v)) % 100000, Count), other)) AS attribute_counts
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName = 'code.function.call.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, function, file, caller, caller_file, flow, content_hash, deployment
COMMENT 'Reads code.function.call.duration delta points from otel_metrics_exponential_histogram, maps their buckets onto scale 2 and writes them to function_durations, grouped per insert.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_counters_mv TO ${DATABASE}.function_counters
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    Attributes['code.function.name'] AS function, Attributes['code.file.path'] AS file,
    Attributes['code.function.caller.name'] AS caller, Attributes['code.function.caller.file.path'] AS caller_file,
    Attributes['code.flow.name'] AS flow,
    Attributes['hud.function.content_hash'] AS content_hash, Attributes['error.type'] AS error_type,
    ResourceAttributes['deployment.id'] AS deployment,
    sumIf(Value, MetricName = 'code.function.calls') AS calls,
    sumIf(Value, MetricName = 'code.function.errors') AS errors
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName IN ('code.function.calls', 'code.function.errors') AND AggregationTemporality = 1
GROUP BY t, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment
COMMENT 'Reads code.function.calls and code.function.errors delta points from otel_metrics_sum and writes them to function_counters, grouped per insert.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoints_from_process_mv TO ${DATABASE}.endpoints
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, '' AS flow,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_gauge
WHERE MetricName = 'process.uptime'
GROUP BY env, service
COMMENT 'Writes a row with an empty flow to endpoints for every service that sends process.uptime (otel_metrics_gauge).';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoints_from_durations_mv TO ${DATABASE}.endpoints
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName = 'code.flow.duration'
GROUP BY env, service, flow
COMMENT 'Writes every flow that sends code.flow.duration (otel_metrics_exponential_histogram) to endpoints.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.functions_mv TO ${DATABASE}.functions
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.function.name'] AS function, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName = 'code.function.calls'
GROUP BY env, service, flow, function
COMMENT 'Writes every function and flow that sends code.function.calls (otel_metrics_sum) to functions.';

-- Hourly tables: each fine-table insert rolls up into its family's _metrics_1h table, and endpoint and function tables
-- also into their _metrics_lean_1h table. A view's unlisted columns get their defaults ('', 0, empty maps and states).

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_from_durations_mv TO ${DATABASE}.endpoint_metrics_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    instance, feature_flags,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance,
    feature_flags
COMMENT 'Rolls each endpoint_durations insert up by hour into endpoint_metrics_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_from_durations_mv TO ${DATABASE}.endpoint_metrics_lean_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    feature_flags,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, feature_flags
COMMENT 'Rolls each endpoint_durations insert up by hour into endpoint_metrics_lean_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_from_counters_mv TO ${DATABASE}.endpoint_metrics_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination,
    deployment, fingerprint, framework_result, caught, user_error, parent_service, parent_flow, parent_multiple,
    root_service, root_flow, root_multiple, instance, feature_flags,
    sum(messages) AS messages, sum(issues) AS issues, sum(runs_by_caller) AS runs_by_caller, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, instance, feature_flags
COMMENT 'Rolls each endpoint_counters insert up by hour into endpoint_metrics_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_from_counters_mv TO ${DATABASE}.endpoint_metrics_lean_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination,
    deployment, fingerprint, framework_result, caught, user_error, parent_service, parent_flow, parent_multiple,
    root_service, root_flow, root_multiple, feature_flags,
    sum(messages) AS messages, sum(issues) AS issues, sum(runs_by_caller) AS runs_by_caller, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, feature_flags
COMMENT 'Rolls each endpoint_counters insert up by hour into endpoint_metrics_lean_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.process_metrics_1h_mv TO ${DATABASE}.process_metrics_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, instance, deployment, pod,
    max(last_seen) AS last_seen, max(uptime) AS uptime, sum(cpu_sum) AS cpu_sum, sum(cpu_count) AS cpu_count,
    max(cpu_max) AS cpu_max, sum(memory_sum) AS memory_sum, sum(memory_count) AS memory_count, max(memory_max) AS memory_max,
    max(memory_limit) AS memory_limit, sum(elu_sum) AS elu_sum, sum(elu_count) AS elu_count, max(elu_max) AS elu_max
FROM ${DATABASE}.process_metrics
GROUP BY hour, env, service, instance, deployment, pod
COMMENT 'Rolls each process_metrics insert up by hour into process_metrics_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_1h_from_durations_mv TO ${DATABASE}.function_metrics_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, caller, caller_file, flow, content_hash, deployment,
    sum(duration_sum) AS duration_sum, sum(duration_count) AS duration_count, sumMap(buckets) AS buckets,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.function_durations
GROUP BY hour, env, service, function, file, caller, caller_file, flow, content_hash, deployment
COMMENT 'Rolls each function_durations insert up by hour into function_metrics_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_lean_1h_from_durations_mv TO ${DATABASE}.function_metrics_lean_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, flow, deployment,
    sum(duration_sum) AS duration_sum, sum(duration_count) AS duration_count, sumMap(buckets) AS buckets,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.function_durations
GROUP BY hour, env, service, function, file, flow, deployment
COMMENT 'Rolls each function_durations insert up by hour into function_metrics_lean_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_1h_from_counters_mv TO ${DATABASE}.function_metrics_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment,
    sum(calls) AS calls, sum(errors) AS errors
FROM ${DATABASE}.function_counters
GROUP BY hour, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment
COMMENT 'Rolls each function_counters insert up by hour into function_metrics_1h.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_lean_1h_from_counters_mv TO ${DATABASE}.function_metrics_lean_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, flow, deployment, sum(calls) AS calls, sum(errors) AS errors
FROM ${DATABASE}.function_counters
GROUP BY hour, env, service, function, file, flow, deployment
COMMENT 'Rolls each function_counters insert up by hour into function_metrics_lean_1h.';
