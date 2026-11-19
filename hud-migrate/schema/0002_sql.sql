-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- SQL metrics: the collector's clickhouse exporter inserts the SDK's OTLP metrics into the ingest_* tables. They are
-- Null tables: materialized views aggregate each insert into the tables below and the raw rows are not kept.
-- Every series is a delta (AggregationTemporality = 1) except the process gauges and limits. The SDK's exponential
-- histograms arrive as classic buckets on the transform/classic grid (duration_bounds). A delta covers its export
-- interval [StartTimeUnix, TimeUnix) (aggregationInterval: 5 minutes by default, set per account), so it is spread
-- over the fine buckets that interval overlaps, each getting its share of the interval: a chart then shows the SDK's
-- own resolution whatever the interval (every bucket of an interval has its rate and its duration distribution),
-- instead of one bucket holding it all and the others none. Counts are therefore Float64; they add up to whole
-- numbers again over whole intervals. An interval that is empty or longer than an hour goes to the bucket of TimeUnix.
--
-- The fine tables (below, at 1 or 5 minutes) are plain MergeTree holding plain values: every insert's rows stay as
-- written (one per key, pod and view, nothing merged), so queries sum them (sum, sumForEach(buckets),
-- groupUniqArrayArrayMap(1000)(attributes)). They keep HUD_METRICS_FINE_TTL_DAYS days (default 30, only applies when a
-- table is created). Each fine table's insert rolls up into <name>_hourly, an AggregatingMergeTree of aggregate states
-- that keeps everything: read it with -Merge, or finalizeAggregation() a column to union it with the fine table's.
--   flow              code.flow.duration, hud.flow.e2e.duration and hud.flow.messages by flow and status, 1 minute
--   session_health    CPU, memory, event loop and uptime by SDK session (service.instance.id), 1 minute
--   session_flow      runs, 5xx runs and issues by session and flow, 1 minute
--   issue             hud.flow.issues by flow, fingerprint and user error, 1 minute
--   calling_flow      hud.flow.calling_flows: runs by flow and the flow that called it (parent) and started it (root),
--                     1 minute
--   function          code.function.* by function, file and deployment, 5 minutes
--   function_metrics  code.function.* by function, caller function (name and file), flow, content hash and error type,
--                     5 minutes
-- labels holds every environment, service, flow and function seen, for the dashboard selectors.
-- flow and function also keep every other attribute the SDK sends (a new one needs no migration), as long as the rest
-- of their row: attributes holds up to 1000 values per attribute, attribute_counts the
-- runs (calls) per 'attribute=value', keyed by sipHash64('attribute=value') % 100000 so a row holds at most 100000
-- counts (values sharing a bucket add up). Session and host attributes stay out, so a row never grows with the number
-- of pods, and so do the function's caller, content hash, short name and its flow's type, route and methods: they vary
-- per call, and function_metrics has them (the flow's in its name).

-- The exporter's metric tables, by column name (clickhouseexporter v0.165.0). Summaries and exponential histograms
-- (none after transform/classic) are accepted and dropped.
CREATE TABLE IF NOT EXISTS ${DATABASE}.ingest_sum
(
    ResourceAttributes Map(LowCardinality(String), String), ResourceSchemaUrl String, ScopeName String, ScopeVersion String,
    ScopeAttributes Map(LowCardinality(String), String), ScopeDroppedAttrCount UInt32, ScopeSchemaUrl String,
    ServiceName LowCardinality(String), MetricName LowCardinality(String), MetricDescription String, MetricUnit String,
    Attributes Map(LowCardinality(String), String), StartTimeUnix DateTime, TimeUnix DateTime, Value Float64, Flags UInt32,
    `Exemplars.FilteredAttributes` Array(Map(LowCardinality(String), String)), `Exemplars.TimeUnix` Array(DateTime),
    `Exemplars.Value` Array(Float64), `Exemplars.SpanId` Array(String), `Exemplars.TraceId` Array(String),
    AggregationTemporality Int32, IsMonotonic Bool
)
ENGINE = Null;

CREATE TABLE IF NOT EXISTS ${DATABASE}.ingest_gauge
(
    ResourceAttributes Map(LowCardinality(String), String), ResourceSchemaUrl String, ScopeName String, ScopeVersion String,
    ScopeAttributes Map(LowCardinality(String), String), ScopeDroppedAttrCount UInt32, ScopeSchemaUrl String,
    ServiceName LowCardinality(String), MetricName LowCardinality(String), MetricDescription String, MetricUnit String,
    Attributes Map(LowCardinality(String), String), StartTimeUnix DateTime, TimeUnix DateTime, Value Float64, Flags UInt32,
    `Exemplars.FilteredAttributes` Array(Map(LowCardinality(String), String)), `Exemplars.TimeUnix` Array(DateTime),
    `Exemplars.Value` Array(Float64), `Exemplars.SpanId` Array(String), `Exemplars.TraceId` Array(String)
)
ENGINE = Null;

CREATE TABLE IF NOT EXISTS ${DATABASE}.ingest_histogram
(
    ResourceAttributes Map(LowCardinality(String), String), ResourceSchemaUrl String, ScopeName String, ScopeVersion String,
    ScopeAttributes Map(LowCardinality(String), String), ScopeDroppedAttrCount UInt32, ScopeSchemaUrl String,
    ServiceName LowCardinality(String), MetricName LowCardinality(String), MetricDescription String, MetricUnit String,
    Attributes Map(LowCardinality(String), String), StartTimeUnix DateTime, TimeUnix DateTime, Count UInt64, Sum Float64,
    BucketCounts Array(UInt64), ExplicitBounds Array(Float64),
    `Exemplars.FilteredAttributes` Array(Map(LowCardinality(String), String)), `Exemplars.TimeUnix` Array(DateTime),
    `Exemplars.Value` Array(Float64), `Exemplars.SpanId` Array(String), `Exemplars.TraceId` Array(String),
    Flags UInt32, Min Float64, Max Float64, AggregationTemporality Int32
)
ENGINE = Null;

CREATE TABLE IF NOT EXISTS ${DATABASE}.ingest_exponential_histogram
(
    ResourceAttributes Map(LowCardinality(String), String), ResourceSchemaUrl String, ScopeName String, ScopeVersion String,
    ScopeAttributes Map(LowCardinality(String), String), ScopeDroppedAttrCount UInt32, ScopeSchemaUrl String,
    ServiceName LowCardinality(String), MetricName LowCardinality(String), MetricDescription String, MetricUnit String,
    Attributes Map(LowCardinality(String), String), StartTimeUnix DateTime, TimeUnix DateTime, Count UInt64, Sum Float64,
    Scale Int32, ZeroCount UInt64, PositiveOffset Int32, PositiveBucketCounts Array(UInt64), NegativeOffset Int32,
    NegativeBucketCounts Array(UInt64),
    `Exemplars.FilteredAttributes` Array(Map(LowCardinality(String), String)), `Exemplars.TimeUnix` Array(DateTime),
    `Exemplars.Value` Array(Float64), `Exemplars.SpanId` Array(String), `Exemplars.TraceId` Array(String),
    Flags UInt32, Min Float64, Max Float64, AggregationTemporality Int32
)
ENGINE = Null;

CREATE TABLE IF NOT EXISTS ${DATABASE}.ingest_summary
(
    ResourceAttributes Map(LowCardinality(String), String), ResourceSchemaUrl String, ScopeName String, ScopeVersion String,
    ScopeAttributes Map(LowCardinality(String), String), ScopeDroppedAttrCount UInt32, ScopeSchemaUrl String,
    ServiceName LowCardinality(String), MetricName LowCardinality(String), MetricDescription String, MetricUnit String,
    Attributes Map(LowCardinality(String), String), StartTimeUnix DateTime, TimeUnix DateTime, Count UInt64, Sum Float64,
    `ValueAtQuantiles.Quantile` Array(Float64), `ValueAtQuantiles.Value` Array(Float64), Flags UInt32
)
ENGINE = Null;

-- The upper bounds of buckets[1..33] (seconds), buckets[34] is +Inf. Same list as transform/classic.
CREATE VIEW IF NOT EXISTS ${DATABASE}.duration_bounds AS
SELECT [0.0009765634765625, 0.0013810693130729076, 0.001953126953125, 0.0027621386261458152, 0.00390625390625,
    0.0055242772522916305, 0.0078125078125, 0.011048554504583261, 0.015625015625, 0.022097109009166522, 0.03125003125,
    0.044194218018333044, 0.0625000625, 0.08838843603666609, 0.125000125, 0.17677687207333218, 0.25000025,
    0.35355374414666435, 0.5000005, 0.7071074882933287, 1.000001, 1.4142149765866574, 2.000002, 2.828429953173315,
    4.000004, 5.65685990634663, 8.000008, 11.31371981269326, 16.000016, 22.62743962538652, 32.000032, 45.25487925077304,
    64.000064] AS bounds;

-- duration_count is the number of runs, e2e_* is the queue latency from publish to the end of the flow.
CREATE TABLE IF NOT EXISTS ${DATABASE}.flow
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), flow String, flow_type LowCardinality(String),
    method LowCardinality(String), route String, status_code LowCardinality(String), end_reason LowCardinality(String),
    destination String, deployment String,
    duration_count Float64, duration_sum Float64,
    buckets Array(Float64),
    e2e_count Float64, e2e_sum Float64,
    e2e_buckets Array(Float64),
    messages Float64, last_seen DateTime,
    attributes Map(String, Array(String)),
    attribute_counts Map(UInt32, Float64)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, flow, t, flow_type, method, route, status_code, end_reason, destination, deployment)
TTL t + toIntervalDay(${HUD_METRICS_FINE_TTL_DAYS:-30})
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS ${DATABASE}.flow_hourly
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), flow String, flow_type LowCardinality(String),
    method LowCardinality(String), route String, status_code LowCardinality(String), end_reason LowCardinality(String),
    destination String, deployment String,
    duration_count SimpleAggregateFunction(sum, Float64), duration_sum SimpleAggregateFunction(sum, Float64),
    buckets AggregateFunction(sumForEach, Array(Float64)),
    e2e_count SimpleAggregateFunction(sum, Float64), e2e_sum SimpleAggregateFunction(sum, Float64),
    e2e_buckets AggregateFunction(sumForEach, Array(Float64)),
    messages SimpleAggregateFunction(sum, Float64), last_seen SimpleAggregateFunction(max, DateTime),
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String))),
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, Float64))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (env, service, flow, hour, flow_type, method, route, status_code, end_reason, destination, deployment);

-- One row per session and minute it reported process metrics. uptime is the latest process.uptime (it only grows),
-- so the session started at last_seen - uptime. elu averages over the event loop's threads.
CREATE TABLE IF NOT EXISTS ${DATABASE}.session_health
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), instance String, deployment String, pod String,
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
TTL t + toIntervalDay(${HUD_METRICS_FINE_TTL_DAYS:-30})
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS ${DATABASE}.session_health_hourly
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), instance String, deployment String, pod String,
    last_seen SimpleAggregateFunction(max, DateTime), uptime SimpleAggregateFunction(max, Float64),
    cpu_sum SimpleAggregateFunction(sum, Float64), cpu_count SimpleAggregateFunction(sum, UInt64),
    cpu_max SimpleAggregateFunction(max, Float64),
    memory_sum SimpleAggregateFunction(sum, Float64), memory_count SimpleAggregateFunction(sum, UInt64),
    memory_max SimpleAggregateFunction(max, Float64), memory_limit SimpleAggregateFunction(max, Float64),
    elu_sum SimpleAggregateFunction(sum, Float64), elu_count SimpleAggregateFunction(sum, UInt64),
    elu_max SimpleAggregateFunction(max, Float64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (env, service, instance, hour, deployment, pod);

-- errors: runs with a 5xx status. issues: hud.flow.issues of every flow type.
CREATE TABLE IF NOT EXISTS ${DATABASE}.session_flow
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), instance String, flow String,
    flow_type LowCardinality(String),
    runs Float64, errors Float64,
    issues Float64, last_seen DateTime
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, instance, t, flow, flow_type)
TTL t + toIntervalDay(${HUD_METRICS_FINE_TTL_DAYS:-30})
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS ${DATABASE}.session_flow_hourly
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), instance String, flow String,
    flow_type LowCardinality(String),
    runs SimpleAggregateFunction(sum, Float64), errors SimpleAggregateFunction(sum, Float64),
    issues SimpleAggregateFunction(sum, Float64), last_seen SimpleAggregateFunction(max, DateTime)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (env, service, instance, hour, flow, flow_type);

CREATE TABLE IF NOT EXISTS ${DATABASE}.issue
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), flow String, flow_type LowCardinality(String),
    fingerprint String, framework_result LowCardinality(String), caught LowCardinality(String), user_error String,
    issues Float64
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, flow, t, fingerprint, framework_result, caught, flow_type, user_error)
TTL t + toIntervalDay(${HUD_METRICS_FINE_TTL_DAYS:-30})
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS ${DATABASE}.issue_hourly
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), flow String, flow_type LowCardinality(String),
    fingerprint String, framework_result LowCardinality(String), caught LowCardinality(String), user_error String,
    issues SimpleAggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (env, service, flow, hour, fingerprint, framework_result, caught, flow_type, user_error);

-- parent and root are the calling flows (multiple: the run had more than one). The rest of the attributes are the
-- flow's own, as on code.flow.duration.
CREATE TABLE IF NOT EXISTS ${DATABASE}.calling_flow
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), flow String, flow_type LowCardinality(String),
    status_code LowCardinality(String), parent_service LowCardinality(String), parent_flow String,
    parent_multiple LowCardinality(String), root_service LowCardinality(String), root_flow String,
    root_multiple LowCardinality(String), deployment String,
    runs Float64
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, flow, t, parent_service, parent_flow, root_service, root_flow, flow_type, status_code, parent_multiple,
    root_multiple, deployment)
TTL t + toIntervalDay(${HUD_METRICS_FINE_TTL_DAYS:-30})
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS ${DATABASE}.calling_flow_hourly
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), flow String, flow_type LowCardinality(String),
    status_code LowCardinality(String), parent_service LowCardinality(String), parent_flow String,
    parent_multiple LowCardinality(String), root_service LowCardinality(String), root_flow String,
    root_multiple LowCardinality(String), deployment String,
    runs SimpleAggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (env, service, flow, hour, parent_service, parent_flow, root_service, root_flow, flow_type, status_code, parent_multiple,
    root_multiple, deployment);

CREATE TABLE IF NOT EXISTS ${DATABASE}.function
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), function String, file String, deployment String,
    calls Float64, errors Float64,
    duration_sum Float64, duration_count Float64,
    buckets Array(Float64),
    attributes Map(String, Array(String)),
    attribute_counts Map(UInt32, Float64)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, function, file, t, deployment)
TTL t + toIntervalDay(${HUD_METRICS_FINE_TTL_DAYS:-30})
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS ${DATABASE}.function_hourly
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), function String, file String, deployment String,
    calls SimpleAggregateFunction(sum, Float64), errors SimpleAggregateFunction(sum, Float64),
    duration_sum SimpleAggregateFunction(sum, Float64), duration_count SimpleAggregateFunction(sum, Float64),
    buckets AggregateFunction(sumForEach, Array(Float64)),
    attributes AggregateFunction(groupUniqArrayArrayMap(1000), Map(String, Array(String))),
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, Float64))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (env, service, function, file, hour, deployment);

-- A function as called by one caller function (name and file) in one flow. Error rows carry their error_type, call
-- rows ''.
CREATE TABLE IF NOT EXISTS ${DATABASE}.function_metrics
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), function String, file String, caller String,
    caller_file String, flow String, content_hash String, error_type String, deployment String,
    calls Float64, errors Float64,
    duration_sum Float64, duration_count Float64,
    buckets Array(Float64)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
ORDER BY (env, service, function, file, t, caller, caller_file, flow, content_hash, error_type, deployment)
TTL t + toIntervalDay(${HUD_METRICS_FINE_TTL_DAYS:-30})
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS ${DATABASE}.function_metrics_hourly
(
    hour DateTime, env LowCardinality(String), service LowCardinality(String), function String, file String, caller String,
    caller_file String, flow String, content_hash String, error_type String, deployment String,
    calls SimpleAggregateFunction(sum, Float64), errors SimpleAggregateFunction(sum, Float64),
    duration_sum SimpleAggregateFunction(sum, Float64), duration_count SimpleAggregateFunction(sum, Float64),
    buckets AggregateFunction(sumForEach, Array(Float64))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (env, service, function, file, hour, caller, caller_file, flow, content_hash, error_type, deployment);

-- Sessions have flow = function = '', flows have function = ''.
CREATE TABLE IF NOT EXISTS ${DATABASE}.labels
(
    env LowCardinality(String), service LowCardinality(String), flow String, function String,
    last_seen SimpleAggregateFunction(max, DateTime)
)
ENGINE = AggregatingMergeTree
ORDER BY (env, service, flow, function);

-- Fine tables, from the ingest tables. Each delta row joins its buckets p = (bucket start, the share of the interval
-- in that bucket).

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.flow_duration TO ${DATABASE}.flow
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['http.request.method'] AS method, Attributes['http.route'] AS route,
    Attributes['http.response.status_code'] AS status_code, Attributes['hud.flow.end_reason'] AS end_reason,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    sum(Count * p.2) AS duration_count, sum(Sum * p.2) AS duration_sum,
    sumForEach(arrayMap(c -> c * p.2, BucketCounts)) AS buckets,
    0 AS e2e_count, 0 AS e2e_sum, CAST([], 'Array(Float64)') AS e2e_buckets, 0 AS messages,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_histogram
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 60, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 60) * 60, we, 60)),
    [(toStartOfMinute(TimeUnix), 1.)]) AS p
WHERE MetricName = 'code.flow.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.flow_e2e TO ${DATABASE}.flow
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, '' AS method, '' AS route, '' AS status_code, '' AS end_reason,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    0 AS duration_count, 0 AS duration_sum, CAST([], 'Array(Float64)') AS buckets,
    sum(Count * p.2) AS e2e_count, sum(Sum * p.2) AS e2e_sum,
    sumForEach(arrayMap(c -> c * p.2, BucketCounts)) AS e2e_buckets, 0 AS messages,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_histogram
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 60, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 60) * 60, we, 60)),
    [(toStartOfMinute(TimeUnix), 1.)]) AS p
WHERE MetricName = 'hud.flow.e2e.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, destination, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.flow_messages TO ${DATABASE}.flow
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, '' AS method, '' AS route, '' AS status_code, '' AS end_reason,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    0 AS duration_count, 0 AS duration_sum, CAST([], 'Array(Float64)') AS buckets,
    0 AS e2e_count, 0 AS e2e_sum, CAST([], 'Array(Float64)') AS e2e_buckets, sum(Value * p.2) AS messages,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_sum
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 60, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 60) * 60, we, 60)),
    [(toStartOfMinute(TimeUnix), 1.)]) AS p
WHERE MetricName = 'hud.flow.messages' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, destination, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.session_health_gauge TO ${DATABASE}.session_health
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfMinute(TimeUnix) AS t, ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    ResourceAttributes['service.instance.id'] AS instance, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['k8s.pod.name'] AS pod,
    max(TimeUnix) AS last_seen, maxIf(Value, MetricName = 'process.uptime') AS uptime,
    sumIf(Value, MetricName = 'process.cpu.utilization') AS cpu_sum, countIf(MetricName = 'process.cpu.utilization') AS cpu_count,
    maxIf(Value, MetricName = 'process.cpu.utilization') AS cpu_max,
    0 AS memory_sum, 0 AS memory_count, 0 AS memory_max, 0 AS memory_limit,
    sumIf(Value, MetricName = 'nodejs.eventloop.utilization') AS elu_sum,
    countIf(MetricName = 'nodejs.eventloop.utilization') AS elu_count,
    maxIf(Value, MetricName = 'nodejs.eventloop.utilization') AS elu_max
FROM ${DATABASE}.ingest_gauge
WHERE MetricName IN ('process.uptime', 'process.cpu.utilization', 'nodejs.eventloop.utilization')
GROUP BY t, env, service, instance, deployment, pod;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.session_health_sum TO ${DATABASE}.session_health
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfMinute(TimeUnix) AS t, ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    ResourceAttributes['service.instance.id'] AS instance, ResourceAttributes['deployment.id'] AS deployment,
    ResourceAttributes['k8s.pod.name'] AS pod,
    max(TimeUnix) AS last_seen, 0 AS uptime, 0 AS cpu_sum, 0 AS cpu_count, 0 AS cpu_max,
    sumIf(Value, MetricName = 'process.memory.usage') AS memory_sum, countIf(MetricName = 'process.memory.usage') AS memory_count,
    maxIf(Value, MetricName = 'process.memory.usage') AS memory_max,
    maxIf(Value, MetricName = 'hud.process.memory.limit') AS memory_limit,
    0 AS elu_sum, 0 AS elu_count, 0 AS elu_max
FROM ${DATABASE}.ingest_sum
WHERE MetricName IN ('process.memory.usage', 'hud.process.memory.limit')
GROUP BY t, env, service, instance, deployment, pod;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.session_flow_runs TO ${DATABASE}.session_flow
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    ResourceAttributes['service.instance.id'] AS instance, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type,
    sum(Count * p.2) AS runs,
    sumIf(Count * p.2, startsWith(Attributes['http.response.status_code'], '5')) AS errors, 0 AS issues,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_histogram
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 60, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 60) * 60, we, 60)),
    [(toStartOfMinute(TimeUnix), 1.)]) AS p
WHERE MetricName = 'code.flow.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, instance, flow, flow_type;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.session_flow_issues TO ${DATABASE}.session_flow
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    ResourceAttributes['service.instance.id'] AS instance, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, 0 AS runs, 0 AS errors, sum(Value * p.2) AS issues, max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_sum
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 60, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 60) * 60, we, 60)),
    [(toStartOfMinute(TimeUnix), 1.)]) AS p
WHERE MetricName = 'hud.flow.issues' AND AggregationTemporality = 1
GROUP BY t, env, service, instance, flow, flow_type;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.issue_issues TO ${DATABASE}.issue
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['issue.fingerprint'] AS fingerprint,
    Attributes['hud.issue.framework_result'] AS framework_result, Attributes['hud.issue.caught'] AS caught,
    Attributes['hud.issue.user_error'] AS user_error, sum(Value * p.2) AS issues
FROM ${DATABASE}.ingest_sum
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 60, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 60) * 60, we, 60)),
    [(toStartOfMinute(TimeUnix), 1.)]) AS p
WHERE MetricName = 'hud.flow.issues' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, fingerprint, framework_result, caught, user_error;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.calling_flow_runs TO ${DATABASE}.calling_flow
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['http.response.status_code'] AS status_code,
    Attributes['hud.parent.service.name'] AS parent_service, Attributes['hud.parent.flow.name'] AS parent_flow,
    Attributes['hud.parent.multiple'] AS parent_multiple, Attributes['hud.root.service.name'] AS root_service,
    Attributes['hud.root.flow.name'] AS root_flow, Attributes['hud.root.multiple'] AS root_multiple,
    ResourceAttributes['deployment.id'] AS deployment, sum(Value * p.2) AS runs
FROM ${DATABASE}.ingest_sum
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 60, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 60) * 60, we, 60)),
    [(toStartOfMinute(TimeUnix), 1.)]) AS p
WHERE MetricName = 'hud.flow.calling_flows' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, status_code, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_duration TO ${DATABASE}.function
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    Attributes['code.function.name'] AS function, Attributes['code.file.path'] AS file,
    ResourceAttributes['deployment.id'] AS deployment,
    0 AS calls, 0 AS errors, sum(Sum * p.2) AS duration_sum, sum(Count * p.2) AS duration_count,
    sumForEach(arrayMap(c -> c * p.2, BucketCounts)) AS buckets
FROM ${DATABASE}.ingest_histogram
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 300, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 300) * 300, we, 300)),
    [(toStartOfFiveMinutes(TimeUnix), 1.)]) AS p
WHERE MetricName = 'code.function.call.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, function, file, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_calls TO ${DATABASE}.function
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    Attributes['code.function.name'] AS function, Attributes['code.file.path'] AS file,
    ResourceAttributes['deployment.id'] AS deployment,
    sumIf(Value * p.2, MetricName = 'code.function.calls') AS calls,
    sumIf(Value * p.2, MetricName = 'code.function.errors') AS errors,
    0 AS duration_sum, 0 AS duration_count, CAST([], 'Array(Float64)') AS buckets
FROM ${DATABASE}.ingest_sum
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 300, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 300) * 300, we, 300)),
    [(toStartOfFiveMinutes(TimeUnix), 1.)]) AS p
WHERE MetricName IN ('code.function.calls', 'code.function.errors') AND AggregationTemporality = 1
GROUP BY t, env, service, function, file, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_duration TO ${DATABASE}.function_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    Attributes['code.function.name'] AS function, Attributes['code.file.path'] AS file,
    Attributes['code.function.caller.name'] AS caller, Attributes['code.function.caller.file.path'] AS caller_file,
    Attributes['code.flow.name'] AS flow,
    Attributes['hud.function.content_hash'] AS content_hash, '' AS error_type, ResourceAttributes['deployment.id'] AS deployment,
    0 AS calls, 0 AS errors, sum(Sum * p.2) AS duration_sum, sum(Count * p.2) AS duration_count,
    sumForEach(arrayMap(c -> c * p.2, BucketCounts)) AS buckets
FROM ${DATABASE}.ingest_histogram
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 300, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 300) * 300, we, 300)),
    [(toStartOfFiveMinutes(TimeUnix), 1.)]) AS p
WHERE MetricName = 'code.function.call.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, function, file, caller, caller_file, flow, content_hash, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_calls TO ${DATABASE}.function_metrics
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we
SELECT p.1 AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    Attributes['code.function.name'] AS function, Attributes['code.file.path'] AS file,
    Attributes['code.function.caller.name'] AS caller, Attributes['code.function.caller.file.path'] AS caller_file,
    Attributes['code.flow.name'] AS flow,
    Attributes['hud.function.content_hash'] AS content_hash, Attributes['error.type'] AS error_type,
    ResourceAttributes['deployment.id'] AS deployment,
    sumIf(Value * p.2, MetricName = 'code.function.calls') AS calls,
    sumIf(Value * p.2, MetricName = 'code.function.errors') AS errors,
    0 AS duration_sum, 0 AS duration_count, CAST([], 'Array(Float64)') AS buckets
FROM ${DATABASE}.ingest_sum
ARRAY JOIN if(we > ws AND we - ws <= 3600,
    arrayMap(b -> (toDateTime(b), (least(b + 300, we) - greatest(b, ws)) / (we - ws)),
        range(intDiv(ws, 300) * 300, we, 300)),
    [(toStartOfFiveMinutes(TimeUnix), 1.)]) AS p
WHERE MetricName IN ('code.function.calls', 'code.function.errors') AND AggregationTemporality = 1
GROUP BY t, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.labels_sessions TO ${DATABASE}.labels
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, '' AS flow, '' AS function,
    max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_gauge
WHERE MetricName = 'process.uptime'
GROUP BY env, service;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.labels_flows TO ${DATABASE}.labels
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    '' AS function, max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_histogram
WHERE MetricName = 'code.flow.duration'
GROUP BY env, service, flow;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.labels_functions TO ${DATABASE}.labels
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.function.name'] AS function, max(TimeUnix) AS last_seen
FROM ${DATABASE}.ingest_sum
WHERE MetricName = 'code.function.calls'
GROUP BY env, service, flow, function;

-- Hourly tables: each fine-table insert rolls up into its hourly table

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.flow_hourly_rollup TO ${DATABASE}.flow_hourly
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumForEachState(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumForEachState(e2e_buckets) AS e2e_buckets,
    sum(messages) AS messages, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.flow
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.session_health_hourly_rollup TO ${DATABASE}.session_health_hourly
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, instance, deployment, pod,
    max(last_seen) AS last_seen, max(uptime) AS uptime, sum(cpu_sum) AS cpu_sum, sum(cpu_count) AS cpu_count,
    max(cpu_max) AS cpu_max, sum(memory_sum) AS memory_sum, sum(memory_count) AS memory_count, max(memory_max) AS memory_max,
    max(memory_limit) AS memory_limit, sum(elu_sum) AS elu_sum, sum(elu_count) AS elu_count, max(elu_max) AS elu_max
FROM ${DATABASE}.session_health
GROUP BY hour, env, service, instance, deployment, pod;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.session_flow_hourly_rollup TO ${DATABASE}.session_flow_hourly
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, instance, flow, flow_type,
    sum(runs) AS runs, sum(errors) AS errors, sum(issues) AS issues, max(last_seen) AS last_seen
FROM ${DATABASE}.session_flow
GROUP BY hour, env, service, instance, flow, flow_type;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.issue_hourly_rollup TO ${DATABASE}.issue_hourly
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, fingerprint, framework_result, caught, user_error,
    sum(issues) AS issues
FROM ${DATABASE}.issue
GROUP BY hour, env, service, flow, flow_type, fingerprint, framework_result, caught, user_error;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.calling_flow_hourly_rollup TO ${DATABASE}.calling_flow_hourly
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, status_code, parent_service, parent_flow, parent_multiple,
    root_service, root_flow, root_multiple, deployment, sum(runs) AS runs
FROM ${DATABASE}.calling_flow
GROUP BY hour, env, service, flow, flow_type, status_code, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_hourly_rollup TO ${DATABASE}.function_hourly
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, deployment,
    sum(calls) AS calls, sum(errors) AS errors, sum(duration_sum) AS duration_sum, sum(duration_count) AS duration_count,
    sumForEachState(buckets) AS buckets,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.function
GROUP BY hour, env, service, function, file, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_metrics_hourly_rollup TO ${DATABASE}.function_metrics_hourly
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment,
    sum(calls) AS calls, sum(errors) AS errors, sum(duration_sum) AS duration_sum, sum(duration_count) AS duration_count,
    sumForEachState(buckets) AS buckets
FROM ${DATABASE}.function_metrics
GROUP BY hour, env, service, function, file, caller, caller_file, flow, content_hash, error_type, deployment;

-- The other attributes of each run (call), from the ingest table onto the fine row of the same key, and on to the hourly
-- row with the rollup: the grouping must stay the same as the fine table's view, so the hourly rows merge. A delta is
-- not spread: it goes to the bucket its interval starts in (or of TimeUnix, as above, when it is empty or longer than an
-- hour), so the fine tables have them at the export interval.

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.flow_attributes TO ${DATABASE}.flow
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we,
    mapFilter((k, v) -> v != '' AND NOT has(['service.name', 'deployment.environment.name', 'deployment.id', 'code.flow.name',
        'code.flow.type', 'http.request.method', 'http.route', 'http.response.status_code', 'hud.flow.end_reason',
        'messaging.destination.name', 'messaging.destination.template', 'service.instance.id', 'k8s.pod.name', 'k8s.pod.uid',
        'process.pid', 'host.name', 'host.id', 'container.id'], k), mapConcat(Attributes, ResourceAttributes)) AS other
SELECT toStartOfMinute(if(we > ws AND we - ws <= 3600, StartTimeUnix, TimeUnix)) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type, Attributes['http.request.method'] AS method, Attributes['http.route'] AS route,
    Attributes['http.response.status_code'] AS status_code, Attributes['hud.flow.end_reason'] AS end_reason,
    if(Attributes['messaging.destination.name'] != '', Attributes['messaging.destination.name'],
        Attributes['messaging.destination.template']) AS destination, ResourceAttributes['deployment.id'] AS deployment,
    0 AS duration_count, 0 AS duration_sum, CAST([], 'Array(Float64)') AS buckets,
    0 AS e2e_count, 0 AS e2e_sum, CAST([], 'Array(Float64)') AS e2e_buckets, 0 AS messages,
    max(TimeUnix) AS last_seen, groupUniqArrayMap(1000)(other) AS attributes,
    sumMap(mapApply((k, v) -> (sipHash64(concat(k, '=', v)) % 100000, toFloat64(Count)), other)) AS attribute_counts
FROM ${DATABASE}.ingest_histogram
WHERE MetricName = 'code.flow.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.function_attributes TO ${DATABASE}.function
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH toUInt32(StartTimeUnix) AS ws, toUInt32(TimeUnix) AS we,
    mapFilter((k, v) -> v != '' AND NOT has(['service.name', 'deployment.environment.name', 'deployment.id', 'code.function.name',
        'code.file.path', 'code.flow.name', 'code.function.caller.name', 'code.function.caller.file.path',
        'hud.function.content_hash', 'code.flow.type', 'http.route', 'hud.endpoint.methods', 'hud.function.short_name',
        'service.instance.id', 'k8s.pod.name', 'k8s.pod.uid', 'process.pid', 'host.name', 'host.id', 'container.id'], k),
        mapConcat(Attributes, ResourceAttributes)) AS other
SELECT toStartOfFiveMinutes(if(we > ws AND we - ws <= 3600, StartTimeUnix, TimeUnix)) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service,
    Attributes['code.function.name'] AS function, Attributes['code.file.path'] AS file,
    ResourceAttributes['deployment.id'] AS deployment,
    0 AS calls, 0 AS errors, 0 AS duration_sum, 0 AS duration_count, CAST([], 'Array(Float64)') AS buckets,
    groupUniqArrayMap(1000)(other) AS attributes,
    sumMap(mapApply((k, v) -> (sipHash64(concat(k, '=', v)) % 100000, toFloat64(Count)), other)) AS attribute_counts
FROM ${DATABASE}.ingest_histogram
WHERE MetricName = 'code.function.call.duration' AND AggregationTemporality = 1
GROUP BY t, env, service, function, file, deployment;
