-- Endpoint tables and their raw sources/views from v0.165.0-hud.3's 0002_sql.sql.
-- Keep this fixture at the released schema; the smoke test upgrades it in place.
CREATE DATABASE IF NOT EXISTS ${DATABASE};

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

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_durations
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), flow LowCardinality(String),
    flow_type LowCardinality(String), method LowCardinality(String), route LowCardinality(String),
    status_code LowCardinality(String), end_reason LowCardinality(String), destination LowCardinality(String),
    deployment LowCardinality(String), instance LowCardinality(String),
    duration_count UInt64, duration_sum Float64,
    buckets Map(Int16, UInt64),
    e2e_count UInt64, e2e_sum Float64,
    e2e_buckets Map(Int16, UInt64),
    last_seen DateTime,
    attributes Map(String, Array(String)),
    attribute_counts Map(UInt32, UInt64)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, flow, t)
ORDER BY (env, service, flow, t, instance, flow_type, method, route, status_code, end_reason, destination, deployment)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_counters
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), flow LowCardinality(String),
    flow_type LowCardinality(String), status_code LowCardinality(String), destination LowCardinality(String),
    deployment LowCardinality(String), fingerprint String, framework_result LowCardinality(String),
    caught LowCardinality(String), user_error String, parent_service LowCardinality(String),
    parent_flow LowCardinality(String), parent_multiple LowCardinality(String), root_service LowCardinality(String),
    root_flow LowCardinality(String), root_multiple LowCardinality(String), instance LowCardinality(String),
    messages Float64, issues Float64, calling_runs Float64, last_seen DateTime
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, flow, t)
ORDER BY (env, service, flow, t, instance, flow_type, status_code, destination, deployment, fingerprint, framework_result,
    caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple, root_multiple)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h
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

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h
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

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_durations_mv TO ${DATABASE}.endpoint_durations
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH MetricName = 'code.flow.duration' AS run,
    arrayMap(i -> toInt16(ceil((PositiveOffset + i) * exp2(2 - Scale)) - 1), arrayEnumerate(PositiveBucketCounts)) AS bucket_keys,
    mapFilter((k, n) -> n != 0, mapFromArrays(bucket_keys, PositiveBucketCounts)) AS point_buckets,
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
    sumIf(Count, run) AS duration_count, sumIf(Sum, run) AS duration_sum, sumMapIf(point_buckets, run) AS buckets,
    sumIf(Count, NOT run) AS e2e_count, sumIf(Sum, NOT run) AS e2e_sum, sumMapIf(point_buckets, NOT run) AS e2e_buckets,
    max(TimeUnix) AS last_seen, groupUniqArrayMapIf(1000)(other, run) AS attributes,
    sumMapIf(mapApply((k, v) -> (sipHash64(concat(k, '=', v)) % 100000, Count), other), run) AS attribute_counts
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName IN ('code.flow.duration', 'hud.flow.e2e.duration') AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_counters_mv TO ${DATABASE}.endpoint_counters
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toDateTime(TimeUnix) AS t,
    ResourceAttributes['deployment.environment.name'] AS env, ServiceName AS service, Attributes['code.flow.name'] AS flow,
    Attributes['code.flow.type'] AS flow_type,
    if(MetricName = 'hud.flow.calling_flows', Attributes['http.response.status_code'], '') AS status_code,
    if(MetricName != 'hud.flow.messages', '', if(Attributes['messaging.destination.name'] != '',
        Attributes['messaging.destination.name'], Attributes['messaging.destination.template'])) AS destination,
    ResourceAttributes['deployment.id'] AS deployment,
    Attributes['issue.fingerprint'] AS fingerprint, Attributes['hud.issue.framework_result'] AS framework_result,
    Attributes['hud.issue.caught'] AS caught, Attributes['hud.issue.user_error'] AS user_error,
    if(MetricName = 'hud.flow.calling_flows', Attributes['hud.parent.service.name'], '') AS parent_service,
    if(MetricName = 'hud.flow.calling_flows', Attributes['hud.parent.flow.name'], '') AS parent_flow,
    if(MetricName = 'hud.flow.calling_flows', Attributes['hud.parent.multiple'], '') AS parent_multiple,
    Attributes['hud.root.service.name'] AS root_service, Attributes['hud.root.flow.name'] AS root_flow,
    Attributes['hud.root.multiple'] AS root_multiple,
    ResourceAttributes['service.instance.id'] AS instance,
    sumIf(Value, MetricName = 'hud.flow.messages') AS messages, sumIf(Value, MetricName = 'hud.flow.issues') AS issues,
    sumIf(Value, MetricName = 'hud.flow.calling_flows') AS calling_runs, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName IN ('hud.flow.messages', 'hud.flow.issues', 'hud.flow.calling_flows') AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, status_code, destination, deployment, fingerprint, framework_result, caught,
    user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_from_durations_mv TO ${DATABASE}.endpoint_metrics_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    instance,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_from_durations_mv TO ${DATABASE}.endpoint_metrics_lean_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_from_counters_mv TO ${DATABASE}.endpoint_metrics_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, instance,
    sum(messages) AS messages, sum(issues) AS issues, sum(calling_runs) AS calling_runs, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters
GROUP BY hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint, framework_result, caught,
    user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple, instance;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_from_counters_mv TO ${DATABASE}.endpoint_metrics_lean_1h
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple,
    sum(messages) AS messages, sum(issues) AS issues, sum(calling_runs) AS calling_runs, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters
GROUP BY hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint, framework_result, caught,
    user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple;
