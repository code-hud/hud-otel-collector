-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- Feature flags as a key: the endpoint tables of 0002_sql.sql again, as _v2, with feature_flags last in their columns
-- and sorting keys, so a flow's flag combinations stay separate rows (0002 merges them, keeping only each flag's values
-- and runs in attributes). The SDK sends a combination as one hud.feature_flag.<key> attribute per flag, or only
-- hud.feature_flags.overflow when a flow has more combinations than it tracks; feature_flags is its 'key=value' pairs
-- sorted by key and joined with ',' ('fast_path=false,new_checkout=true'), '__hud_other__' (the SDK's overflow key) on
-- overflow, and '' without flags. The SDK sends at most 16 combinations per flow, so a flow has at most 17 times the
-- rows. These keys stay out of attributes. Process and function tables don't change: the SDK puts flags on flow series
-- only.
-- The 0002 tables and views stay and keep being written, so readers that don't group by flags need not move. A reader
-- that does reads the _v2 tables once they exist (system.tables), knowing they start empty when this file is first
-- applied; an admin can fill them up to that point from the 0002 tables, as rows without flags (README).
-- ponytail: a flag key holding ',' or '=' can make two combinations the same string; the SDK doesn't forbid them.

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_durations_v2
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
    attribute_counts Map(UInt32, UInt64),
    feature_flags LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, flow, t)
ORDER BY (env, service, flow, t, instance, flow_type, method, route, status_code, end_reason, destination, deployment,
    feature_flags)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_counters_v2
(
    t DateTime, env LowCardinality(String), service LowCardinality(String), flow LowCardinality(String),
    flow_type LowCardinality(String), status_code LowCardinality(String), destination LowCardinality(String),
    deployment LowCardinality(String), fingerprint String, framework_result LowCardinality(String),
    caught LowCardinality(String), user_error String, parent_service LowCardinality(String),
    parent_flow LowCardinality(String), parent_multiple LowCardinality(String), root_service LowCardinality(String),
    root_flow LowCardinality(String), root_multiple LowCardinality(String), instance LowCardinality(String),
    messages Float64, issues Float64, calling_runs Float64, last_seen DateTime,
    feature_flags LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toDate(t)
PRIMARY KEY (env, service, flow, t)
ORDER BY (env, service, flow, t, instance, flow_type, status_code, destination, deployment, fingerprint, framework_result,
    caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple, root_multiple, feature_flags)
TTL t + toIntervalDay(30)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_v2
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
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64)),
    feature_flags LowCardinality(String)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, flow, hour)
ORDER BY (env, service, flow, hour, instance, flow_type, method, route, status_code, end_reason, destination, deployment,
    fingerprint, framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple,
    root_multiple, feature_flags)
TTL hour + toIntervalDay(90)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_v2
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
    attribute_counts SimpleAggregateFunction(sumMap, Map(UInt32, UInt64)),
    feature_flags LowCardinality(String)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(hour)
PRIMARY KEY (env, service, flow, hour)
ORDER BY (env, service, flow, hour, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, root_service, root_flow, parent_multiple, root_multiple,
    feature_flags)
TTL hour + toIntervalDay(180)
SETTINGS ttl_only_drop_parts = 1, non_replicated_deduplication_window = 10000,
    replicated_deduplication_window = 10000;

-- The 0002 views with feature_flags added, from the same otel_metrics_* tables.

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_durations_v2_mv TO ${DATABASE}.endpoint_durations_v2
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
    feature_flags;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_counters_v2_mv TO ${DATABASE}.endpoint_counters_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
WITH mapFilter((k, v) -> startsWith(k, 'hud.feature_flag.'), Attributes) AS flags
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
    if(Attributes['hud.feature_flags.overflow'] = 'true', '__hud_other__',
        arrayStringConcat(arraySort(arrayMap((k, v) -> concat(substring(k, 18), '=', v), mapKeys(flags), mapValues(flags))),
        ',')) AS feature_flags,
    sumIf(Value, MetricName = 'hud.flow.messages') AS messages, sumIf(Value, MetricName = 'hud.flow.issues') AS issues,
    sumIf(Value, MetricName = 'hud.flow.calling_flows') AS calling_runs, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName IN ('hud.flow.messages', 'hud.flow.issues', 'hud.flow.calling_flows') AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, status_code, destination, deployment, fingerprint, framework_result, caught,
    user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple, instance, feature_flags;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_v2_from_durations_mv TO ${DATABASE}.endpoint_metrics_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    instance, feature_flags,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations_v2
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance,
    feature_flags;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_v2_from_durations_mv TO ${DATABASE}.endpoint_metrics_lean_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    feature_flags,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations_v2
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, feature_flags;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_v2_from_counters_mv TO ${DATABASE}.endpoint_metrics_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, instance, feature_flags,
    sum(messages) AS messages, sum(issues) AS issues, sum(calling_runs) AS calling_runs, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters_v2
GROUP BY hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint, framework_result, caught,
    user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple, instance, feature_flags;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_v2_from_counters_mv TO ${DATABASE}.endpoint_metrics_lean_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, feature_flags,
    sum(messages) AS messages, sum(issues) AS issues, sum(calling_runs) AS calling_runs, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters_v2
GROUP BY hour, env, service, flow, flow_type, status_code, destination, deployment, fingerprint, framework_result, caught,
    user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple, feature_flags;
