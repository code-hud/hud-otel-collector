-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- SQL metrics: the collector's clickhouse exporter inserts the SDK's OTLP metrics into the otel_metrics_* tables, its
-- own layout, so HyperDX reads them as a metrics source. They keep the raw rows 3 days, every metric the SDK sends
-- (a time range of the tables below can be rebuilt from them by running their views' SELECT), and materialized views
-- aggregate each insert into the tables below.
-- Every series is a delta (AggregationTemporality = 1) except the process gauges and limits. Durations are the SDK's
-- base2 exponential histograms: buckets maps the scale-2 bucket index k, (2^(k/4), 2^((k+1)/4)] seconds, to its count,
-- without the empty ones; hud_duration_quantile(q, sumMap(buckets)) (the admin's setup.sql) reads a percentile. A point
-- at another scale goes onto scale 2 (exactly from a finer one, from a coarser one each bucket into its top scale-2
-- bucket). Zero and negative counts (none from the SDK) are dropped. Histogram counts are UInt64, as the exporter's
-- are; the sum metrics' (messages, issues, calls, ...) are Float64, as its sum values are.
--
-- The fine tables (below) are plain MergeTree with a row per export: a point goes as the SDK sent it to the row of its
-- TimeUnix, the end of the export interval it covers (aggregationInterval: 5 minutes by default, set per account),
-- nothing spread or merged (one row per key, pod, export and view). Queries sum them (sum, sumMap(buckets),
-- groupUniqArrayArrayMap(1000)(attributes)), so a chart is no finer than the export interval. They keep 30 days: the
-- dashboards read them up to 30 days back and the hourly tables beyond. Each fine table's insert rolls up into
-- <name>_buckets, an AggregatingMergeTree of aggregate states by the hour a point ends in, with the same columns, that
-- keeps 90 days. endpoint_metrics and function_metrics also roll up into <name>_lean, the same without the session
-- and caller columns, far fewer rows (what most charts read), that keeps 180 days. Read them with -Merge, or
-- finalizeAggregation() a column to union it with the fine table's. Every table's parts are daily, so TTL drops whole
-- days.
-- The views of one insert are not atomic: a failing view can leave others written, and the collector retries the whole
-- batch. Every table below keeps the hashes of its last 10000 inserts (non_replicated_deduplication_window, or
-- replicated_deduplication_window on replicated and Cloud tables), and the collector inserts synchronously with
-- deduplicate_blocks_in_dependent_materialized_views (test/clickhouse.yaml), so a retry only writes what is missing
-- instead of counting the rest twice.
--   endpoint_metrics  by flow, SDK session (service.instance.id) and deployment: code.flow.duration,
--                     hud.flow.e2e.duration and hud.flow.messages by status, method, route, end reason and queue,
--                     hud.flow.issues by fingerprint and user error, hud.flow.calling_flows by the flow that called it
--                     (parent) and started it (root). endpoint_metrics_lean has no instance.
--   machine_metrics   CPU, memory, event loop and uptime by SDK session and pod
--   function_metrics  code.function.* by function, file, caller function (name and file), flow, content hash, error type
--                     and deployment. function_metrics_lean has no caller, caller_file, content_hash or error_type.
-- endpoints and functions hold every service, flow and function seen in 180 days, for the dashboard selectors.
-- endpoint_metrics and function_metrics also keep every other attribute the SDK sends (a new one needs no migration),
-- as long as the rest of their row: attributes holds up to 1000 values per attribute, attribute_counts the
-- runs (calls) per 'attribute=value', keyed by sipHash64('attribute=value') % 100000 so a row holds at most 100000
-- counts (values sharing a bucket add up). Session and host attributes stay out, so a lean row never grows with the
-- number of pods, and so do the function's short name and its flow's type, route and methods: they vary per call (the
-- flow's are in its name).

-- The exporter's metric tables as its create_schema makes them (clickhouseexporter v0.165.0), keeping 3 days. Only
-- the metrics below go on to the tables after them; summaries and classic histograms (none from the SDK) stay here.
CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_sum
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ResourceSchemaUrl String CODEC(ZSTD(3)),
    ScopeName String CODEC(ZSTD(3)), ScopeVersion String CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ScopeDroppedAttrCount UInt32 CODEC(ZSTD(3)),
    ScopeSchemaUrl String CODEC(ZSTD(3)), ServiceName LowCardinality(String) CODEC(ZSTD(3)),
    MetricName LowCardinality(String) CODEC(ZSTD(3)), MetricDescription String CODEC(ZSTD(3)), MetricUnit String CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) CODEC(ZSTD(3)),
    StartTimeUnix DateTime CODEC(Delta, ZSTD(3)), TimeUnix DateTime CODEC(Delta, ZSTD(3)),
    Value Float64 CODEC(ZSTD(3)), Flags UInt32 CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) CODEC(ZSTD(3)),
    AggregationTemporality Int32 CODEC(ZSTD(3)), IsMonotonic Boolean CODEC(Delta, ZSTD(3)),
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
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_gauge
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ResourceSchemaUrl String CODEC(ZSTD(3)),
    ScopeName String CODEC(ZSTD(3)), ScopeVersion String CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ScopeDroppedAttrCount UInt32 CODEC(ZSTD(3)),
    ScopeSchemaUrl String CODEC(ZSTD(3)), ServiceName LowCardinality(String) CODEC(ZSTD(3)),
    MetricName LowCardinality(String) CODEC(ZSTD(3)), MetricDescription String CODEC(ZSTD(3)), MetricUnit String CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) CODEC(ZSTD(3)),
    StartTimeUnix DateTime CODEC(Delta, ZSTD(3)), TimeUnix DateTime CODEC(Delta, ZSTD(3)),
    Value Float64 CODEC(ZSTD(3)), Flags UInt32 CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) CODEC(ZSTD(3)),
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
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_histogram
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ResourceSchemaUrl String CODEC(ZSTD(3)),
    ScopeName String CODEC(ZSTD(3)), ScopeVersion String CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ScopeDroppedAttrCount UInt32 CODEC(ZSTD(3)),
    ScopeSchemaUrl String CODEC(ZSTD(3)), ServiceName LowCardinality(String) CODEC(ZSTD(3)),
    MetricName LowCardinality(String) CODEC(ZSTD(3)), MetricDescription String CODEC(ZSTD(3)), MetricUnit String CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) CODEC(ZSTD(3)),
    StartTimeUnix DateTime CODEC(Delta, ZSTD(3)), TimeUnix DateTime CODEC(Delta, ZSTD(3)),
    Count UInt64 CODEC(Delta, ZSTD(3)), Sum Float64 CODEC(ZSTD(3)),
    BucketCounts Array(UInt64) CODEC(ZSTD(3)), ExplicitBounds Array(Float64) CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) CODEC(ZSTD(3)),
    Flags UInt32 CODEC(ZSTD(3)), Min Float64 CODEC(ZSTD(3)), Max Float64 CODEC(ZSTD(3)),
    AggregationTemporality Int32 CODEC(ZSTD(3)),
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
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_exponential_histogram
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ResourceSchemaUrl String CODEC(ZSTD(3)),
    ScopeName String CODEC(ZSTD(3)), ScopeVersion String CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ScopeDroppedAttrCount UInt32 CODEC(ZSTD(3)),
    ScopeSchemaUrl String CODEC(ZSTD(3)), ServiceName LowCardinality(String) CODEC(ZSTD(3)),
    MetricName LowCardinality(String) CODEC(ZSTD(3)), MetricDescription String CODEC(ZSTD(3)), MetricUnit String CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) CODEC(ZSTD(3)),
    StartTimeUnix DateTime CODEC(Delta, ZSTD(3)), TimeUnix DateTime CODEC(Delta, ZSTD(3)),
    Count UInt64 CODEC(Delta, ZSTD(3)), Sum Float64 CODEC(ZSTD(3)),
    Scale Int32 CODEC(ZSTD(3)), ZeroCount UInt64 CODEC(ZSTD(3)), PositiveOffset Int32 CODEC(ZSTD(3)),
    PositiveBucketCounts Array(UInt64) CODEC(ZSTD(3)), NegativeOffset Int32 CODEC(ZSTD(3)),
    NegativeBucketCounts Array(UInt64) CODEC(ZSTD(3)),
    Exemplars Nested(FilteredAttributes Map(LowCardinality(String), String), TimeUnix DateTime, Value Float64, SpanId String,
        TraceId String) CODEC(ZSTD(3)),
    Flags UInt32 CODEC(ZSTD(3)), Min Float64 CODEC(ZSTD(3)), Max Float64 CODEC(ZSTD(3)),
    AggregationTemporality Int32 CODEC(ZSTD(3)),
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
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.otel_metrics_summary
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ResourceSchemaUrl String CODEC(ZSTD(3)),
    ScopeName String CODEC(ZSTD(3)), ScopeVersion String CODEC(ZSTD(3)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(3)), ScopeDroppedAttrCount UInt32 CODEC(ZSTD(3)),
    ScopeSchemaUrl String CODEC(ZSTD(3)), ServiceName LowCardinality(String) CODEC(ZSTD(3)),
    MetricName LowCardinality(String) CODEC(ZSTD(3)), MetricDescription String CODEC(ZSTD(3)), MetricUnit String CODEC(ZSTD(3)),
    Attributes Map(LowCardinality(String), String) CODEC(ZSTD(3)),
    StartTimeUnix DateTime CODEC(Delta, ZSTD(3)), TimeUnix DateTime CODEC(Delta, ZSTD(3)),
    Count UInt64 CODEC(Delta, ZSTD(3)), Sum Float64 CODEC(ZSTD(3)),
    ValueAtQuantiles Nested(Quantile Float64, Value Float64) CODEC(ZSTD(3)), Flags UInt32 CODEC(ZSTD(3)),
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
    replicated_deduplication_window = 10000;

-- An endpoint is a flow. Each metric's view fills its own columns and leaves the others '' or 0: duration_count is the
-- number of runs (errors are its 5xx ones), e2e_* the queue latency from publish to the end of the flow, issues
-- hud.flow.issues of every flow type, calling_runs the runs by the flow that called it (parent) and started it (root;
-- multiple: the run had more than one).
CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), flow LowCardinality(String),
    flow_type LowCardinality(String), method LowCardinality(String), route LowCardinality(String),
    status_code LowCardinality(String), end_reason LowCardinality(String), destination LowCardinality(String),
    deployment LowCardinality(String), fingerprint String, framework_result LowCardinality(String),
    caught LowCardinality(String), user_error String, parent_service LowCardinality(String),
    parent_flow LowCardinality(String), parent_multiple LowCardinality(String), root_service LowCardinality(String),
    root_flow LowCardinality(String), root_multiple LowCardinality(String), instance LowCardinality(String),
    duration_count UInt64, duration_sum Float64,
    buckets Map(Int16, UInt64),
    e2e_count UInt64, e2e_sum Float64,
    e2e_buckets Map(Int16, UInt64),
    messages Float64, issues Float64, calling_runs Float64, last_seen DateTime,
    attributes Map(String, Array(String)),
    attribute_counts Map(UInt32, UInt64)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, flow, t)
ORDER BY (env, service, flow, t, instance, flow_type, method, route, status_code, end_reason, destination, deployment,
    fingerprint, framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple,
    root_multiple)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_buckets
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), flow LowCardinality(String),
    flow_type LowCardinality(String), method LowCardinality(String), route LowCardinality(String),
    status_code LowCardinality(String), end_reason LowCardinality(String), destination LowCardinality(String),
    deployment LowCardinality(String), fingerprint String, framework_result LowCardinality(String),
    caught LowCardinality(String), user_error String, parent_service LowCardinality(String),
    parent_flow LowCardinality(String), parent_multiple LowCardinality(String), root_service LowCardinality(String),
    root_flow LowCardinality(String), root_multiple LowCardinality(String), instance LowCardinality(String),
    duration_count SimpleAggregateFunction(sum, UInt64), duration_sum SimpleAggregateFunction(sum, Float64),
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)),
    e2e_count SimpleAggregateFunction(sum, UInt64), e2e_sum SimpleAggregateFunction(sum, Float64),
    e2e_buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)),
    messages SimpleAggregateFunction(sum, Float64), issues SimpleAggregateFunction(sum, Float64),
    calling_runs SimpleAggregateFunction(sum, Float64), last_seen SimpleAggregateFunction(max, DateTime),
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String))),
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, flow, hour)
ORDER BY (env, service, flow, hour, instance, flow_type, method, route, status_code, end_reason, destination, deployment,
    fingerprint, framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple,
    root_multiple)
TTL hour + toIntervalDay(90)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), flow LowCardinality(String),
    flow_type LowCardinality(String), method LowCardinality(String), route LowCardinality(String),
    status_code LowCardinality(String), end_reason LowCardinality(String), destination LowCardinality(String),
    deployment LowCardinality(String), fingerprint String, framework_result LowCardinality(String),
    caught LowCardinality(String), user_error String, parent_service LowCardinality(String),
    parent_flow LowCardinality(String), parent_multiple LowCardinality(String), root_service LowCardinality(String),
    root_flow LowCardinality(String), root_multiple LowCardinality(String),
    duration_count SimpleAggregateFunction(sum, UInt64), duration_sum SimpleAggregateFunction(sum, Float64),
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)),
    e2e_count SimpleAggregateFunction(sum, UInt64), e2e_sum SimpleAggregateFunction(sum, Float64),
    e2e_buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)),
    messages SimpleAggregateFunction(sum, Float64), issues SimpleAggregateFunction(sum, Float64),
    calling_runs SimpleAggregateFunction(sum, Float64), last_seen SimpleAggregateFunction(max, DateTime),
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String))),
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, flow, hour)
ORDER BY (env, service, flow, hour, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple, root_multiple)
TTL hour + toIntervalDay(180)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

-- One row per session and export of its process metrics. uptime is the latest process.uptime (it only grows),
-- so the session started at last_seen - uptime. elu averages over the event loop's threads.
CREATE TABLE IF NOT EXISTS ${DATABASE}.machine_metrics
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), instance LowCardinality(String),
    deployment LowCardinality(String), pod LowCardinality(String),
    last_seen DateTime, uptime Float64,
    cpu_sum Float64, cpu_count UInt64,
    cpu_max Float64,
    memory_sum Float64, memory_count UInt64,
    memory_max Float64, memory_limit Float64,
    elu_sum Float64, elu_count UInt64,
    elu_max Float64
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, instance, t, deployment, pod)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.machine_metrics_buckets
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), instance LowCardinality(String),
    deployment LowCardinality(String), pod LowCardinality(String),
    last_seen SimpleAggregateFunction(max, DateTime), uptime SimpleAggregateFunction(max, Float64),
    cpu_sum SimpleAggregateFunction(sum, Float64), cpu_count SimpleAggregateFunction(sum, UInt64),
    cpu_max SimpleAggregateFunction(max, Float64),
    memory_sum SimpleAggregateFunction(sum, Float64), memory_count SimpleAggregateFunction(sum, UInt64),
    memory_max SimpleAggregateFunction(max, Float64), memory_limit SimpleAggregateFunction(max, Float64),
    elu_sum SimpleAggregateFunction(sum, Float64), elu_count SimpleAggregateFunction(sum, UInt64),
    elu_max SimpleAggregateFunction(max, Float64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
ORDER BY (env, service, instance, hour, deployment, pod)
TTL hour + toIntervalDay(90)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

-- A function as called by one caller function (name and file) in one flow. Error rows carry their error_type, call
-- rows ''.
CREATE TABLE IF NOT EXISTS ${DATABASE}.function_metrics
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), function String, file LowCardinality(String),
    caller String, caller_file LowCardinality(String), flow LowCardinality(String), content_hash String,
    error_type LowCardinality(String), deployment LowCardinality(String),
    calls Float64, errors Float64,
    duration_sum Float64, duration_count UInt64,
    buckets Map(Int16, UInt64),
    attributes Map(String, Array(String)),
    attribute_counts Map(UInt32, UInt64)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, function, file, t)
ORDER BY (env, service, function, file, t, caller, caller_file, flow, content_hash, error_type, deployment)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.function_metrics_buckets
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), function String, file LowCardinality(String),
    caller String, caller_file LowCardinality(String), flow LowCardinality(String), content_hash String,
    error_type LowCardinality(String), deployment LowCardinality(String),
    calls SimpleAggregateFunction(sum, Float64), errors SimpleAggregateFunction(sum, Float64),
    duration_sum SimpleAggregateFunction(sum, Float64), duration_count SimpleAggregateFunction(sum, UInt64),
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)),
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String))),
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, function, file, hour)
ORDER BY (env, service, function, file, hour, caller, caller_file, flow, content_hash, error_type, deployment)
TTL hour + toIntervalDay(90)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.function_metrics_lean
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), function String, file LowCardinality(String),
    flow LowCardinality(String), deployment LowCardinality(String),
    calls SimpleAggregateFunction(sum, Float64), errors SimpleAggregateFunction(sum, Float64),
    duration_sum SimpleAggregateFunction(sum, Float64), duration_count SimpleAggregateFunction(sum, UInt64),
    buckets SimpleAggregateFunction(sumMap, Map(Int16, UInt64)),
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String))),
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64))
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
ORDER BY (env, service, function, file, hour, flow, deployment)
TTL hour + toIntervalDay(180)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

-- A service with sessions (process metrics) has a row with flow = ''.
CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoints
(
    env LowCardinality(String), service LowCardinality(String), flow String,
    last_seen SimpleAggregateFunction(max, DateTime)
)
ENGINE = AggregatingMergeTree
ORDER BY (env, service, flow)
TTL last_seen + toIntervalDay(180)
SETTINGS non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.functions
(
    env LowCardinality(String), service LowCardinality(String), flow String, function String,
    last_seen SimpleAggregateFunction(max, DateTime)
)
ENGINE = AggregatingMergeTree
ORDER BY (env, service, flow, function)
TTL last_seen + toIntervalDay(180)
SETTINGS non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

-- Fine tables, from the otel_metrics_* tables. bucket_keys are a histogram point's bucket indexes on scale 2, other its
-- other attributes (the duration views keep them, one per run or call). A view's unlisted columns get their defaults
-- ('', 0, empty maps).

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_duration TO ${DATABASE}.endpoint_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH arrayMap(i -> toInt16(ceil((PositiveOffset + i) * exp2(2 - Scale)) - 1), arrayEnumerate(PositiveBucketCounts)) AS bucket_keys,
    mapFilter((k, v) -> v != '' AND NOT has(['service.name', 'deployment.environment.name', 'deployment.id', 'code.flow.name',
        'code.flow.type', 'http.request.method', 'http.route', 'http.response.status_code', 'hud.flow.end_reason',
        'messaging.destination.name', 'messaging.destination.template', 'service.instance.id', 'k8s.pod.name', 'k8s.pod.uid',
        'process.pid', 'host.name', 'host.id', 'container.id'], k), mapConcat(Attributes, ResourceAttributes)) AS other
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['http.request.method'] AS method, Attributes['http.route'] AS route,
    Attributes['http.response.status_code'] AS status_code, Attributes['hud.flow.end_reason'] AS end_reason,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['service.instance.id'] AS instance,
    sum(Count) AS duration_count, sum(Sum) AS duration_sum,
    sumMap(mapFilter((k, n) -> n != 0, mapFromArrays(bucket_keys, PositiveBucketCounts))) AS buckets,
    max(TimeUnix) AS last_seen, groupUniqArrayMap(1000)(other) AS attributes,
    sumMap(mapApply((k, v) -> (sipHash64(concat(k, '=', v)) % 100000, Count), other)) AS attribute_counts
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName = 'code.flow.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_e2e TO ${DATABASE}.endpoint_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH arrayMap(i -> toInt16(ceil((PositiveOffset + i) * exp2(2 - Scale)) - 1), arrayEnumerate(PositiveBucketCounts)) AS bucket_keys
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['service.instance.id'] AS instance,
    sum(Count) AS e2e_count, sum(Sum) AS e2e_sum,
    sumMap(mapFilter((k, n) -> n != 0, mapFromArrays(bucket_keys, PositiveBucketCounts))) AS e2e_buckets,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName = 'hud.flow.e2e.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, destination, deployment, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_messages TO ${DATABASE}.endpoint_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['service.instance.id'] AS instance, sum(Value) AS messages, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName = 'hud.flow.messages' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, destination, deployment, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_issues TO ${DATABASE}.endpoint_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, ResourceAttributes['deployment.id'] AS deployment,
    Attributes['issue.fingerprint'] AS fingerprint, Attributes['hud.issue.framework_result'] AS framework_result,
    Attributes['hud.issue.caught'] AS caught, Attributes['hud.issue.user_error'] AS user_error,
    ResourceAttributes['service.instance.id'] AS instance, sum(Value) AS issues, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName = 'hud.flow.issues' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, deployment, fingerprint, framework_result, caught, user_error, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_calling_flows TO ${DATABASE}.endpoint_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['http.response.status_code'] AS status_code,
    ResourceAttributes['deployment.id'] AS deployment,
    Attributes['hud.parent.service.name'] AS parent_service, Attributes['hud.parent.flow.name'] AS parent_flow,
    Attributes['hud.parent.multiple'] AS parent_multiple, Attributes['hud.root.service.name'] AS root_service,
    Attributes['hud.root.flow.name'] AS root_flow, Attributes['hud.root.multiple'] AS root_multiple,
    ResourceAttributes['service.instance.id'] AS instance, sum(Value) AS calling_runs, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName = 'hud.flow.calling_flows' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, status_code, deployment, parent_service, parent_flow, parent_multiple, root_service,
    root_flow, root_multiple, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.machine_metrics_gauge TO ${DATABASE}.machine_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t, ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    ResourceAttributes['service.instance.id'] AS instance, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['k8s.pod.name'] AS pod,
    max(TimeUnix) AS last_seen, maxIf(Value, MetricName = 'process.uptime') AS uptime,
    sumIf(Value, MetricName = 'process.cpu.utilization') AS cpu_sum, countIf(MetricName = 'process.cpu.utilization') AS cpu_count,
    maxIf(Value, MetricName = 'process.cpu.utilization') AS cpu_max,
    sumIf(Value, MetricName = 'nodejs.eventloop.utilization') AS elu_sum,
    countIf(MetricName = 'nodejs.eventloop.utilization') AS elu_count,
    maxIf(Value, MetricName = 'nodejs.eventloop.utilization') AS elu_max
FROM ${DATABASE}.otel_metrics_gauge
WHERE MetricName IN ('process.uptime', 'process.cpu.utilization', 'nodejs.eventloop.utilization')
GROUP BY t, env, service, instance, deployment, pod;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.machine_metrics_sum TO ${DATABASE}.machine_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t, ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    ResourceAttributes['service.instance.id'] AS instance, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['k8s.pod.name'] AS pod, max(TimeUnix) AS last_seen,
    sumIf(Value, MetricName = 'process.memory.usage') AS memory_sum, countIf(MetricName = 'process.memory.usage') AS memory_count,
    maxIf(Value, MetricName = 'process.memory.usage') AS memory_max,
    maxIf(Value, MetricName = 'hud.process.memory.limit') AS memory_limit
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName IN ('process.memory.usage', 'hud.process.memory.limit')
GROUP BY t, env, service, instance, deployment, pod;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_duration TO ${DATABASE}.function_metrics
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
GROUP BY t, env, service, function, file, caller, caller_file, flow, content_hash, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_calls TO ${DATABASE}.function_metrics
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
GROUP BY t, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoints_services TO ${DATABASE}.endpoints
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, '' AS flow,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_gauge
WHERE MetricName = 'process.uptime'
GROUP BY env, service;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoints_flows TO ${DATABASE}.endpoints
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName = 'code.flow.duration'
GROUP BY env, service, flow;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.functions_calls TO ${DATABASE}.functions
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.function.name'] AS function, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName = 'code.function.calls'
GROUP BY env, service, flow, function;

-- Hourly tables: each fine-table insert rolls up into its _buckets table, and endpoint and function metrics also into
-- their _lean table

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_buckets_rollup TO ${DATABASE}.endpoint_metrics_buckets
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    fingerprint, framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, instance,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets,
    sum(messages) AS messages, sum(issues) AS issues, sum(calling_runs) AS calling_runs, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_metrics
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple,
    instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_rollup TO ${DATABASE}.endpoint_metrics_lean
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    fingerprint, framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets,
    sum(messages) AS messages, sum(issues) AS issues, sum(calling_runs) AS calling_runs, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_metrics
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.machine_metrics_buckets_rollup TO ${DATABASE}.machine_metrics_buckets
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, instance, deployment, pod,
    max(last_seen) AS last_seen, max(uptime) AS uptime, sum(cpu_sum) AS cpu_sum, sum(cpu_count) AS cpu_count,
    max(cpu_max) AS cpu_max, sum(memory_sum) AS memory_sum, sum(memory_count) AS memory_count, max(memory_max) AS memory_max,
    max(memory_limit) AS memory_limit, sum(elu_sum) AS elu_sum, sum(elu_count) AS elu_count, max(elu_max) AS elu_max
FROM ${DATABASE}.machine_metrics
GROUP BY hour, env, service, instance, deployment, pod;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_buckets_rollup TO ${DATABASE}.function_metrics_buckets
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment,
    sum(calls) AS calls, sum(errors) AS errors, sum(duration_sum) AS duration_sum, sum(duration_count) AS duration_count,
    sumMap(buckets) AS buckets,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.function_metrics
GROUP BY hour, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_lean_rollup TO ${DATABASE}.function_metrics_lean
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, flow, deployment,
    sum(calls) AS calls, sum(errors) AS errors, sum(duration_sum) AS duration_sum, sum(duration_count) AS duration_count,
    sumMap(buckets) AS buckets,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.function_metrics
GROUP BY hour, env, service, function, file, flow, deployment;
