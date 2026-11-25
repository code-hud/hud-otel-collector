-- +goose Up
-- +goose NO TRANSACTION
-- +goose ENVSUB ON

-- Old endpoint tables and their views remain in place. Each raw insert also feeds these versioned
-- tables so fresh installs and upgrades use the same grouping and sorting keys. No historical backfill.
-- Escape percent, comma and equals in flag names so the sorted key=value format is reversible.

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_durations_v2
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
        COMMENT 'Feature flag combination: key=value pairs sorted by key with percent-encoded key delimiters, __hud_other__ on overflow, empty without flags',
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
COMMENT 'Flow (endpoint) run durations and queue latency, from the code.flow.duration and hud.flow.e2e.duration delta histograms. One row per insert for each env, service, flow, export interval end t, SDK session, deployment, flow type, method, route, status, end reason, destination and feature flag combination: sum rows to aggregate. Filled by endpoint_durations_v2_mv, kept 30 days.';

-- A flow's counters, all by method, route, status code, end reason and destination as the run had them, and each by
-- its own columns, '' in the others' rows: issues by fingerprint, framework result, caught and user error,
-- runs_by_caller (runs by the flow that called it (parent) and started it (root; multiple: the run had more than one))
-- by parent and root.
CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_counters_v2
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
COMMENT 'Flow counters, from the hud.flow.messages, hud.flow.issues and hud.flow.calling_flows delta sums. One row per insert for each env, service, flow, export interval end t, SDK session, deployment, method, route, status, end reason, destination, feature flag combination and the key columns of its metric, the others empty: issues by fingerprint, framework result, caught and user error, runs_by_caller by parent and root. Sum rows to aggregate. Filled by endpoint_counters_v2_mv, kept 30 days.';

-- Both endpoint tables as one, at the fine grain, like endpoint_metrics_1h_v2: duration rows carry '' and 0 in the
-- counter columns and counter rows the reverse, so sum over both. calls is the runs (flows aren't sampled, so
-- duration_count); averages stay duration_sum / duration_count. UNION ALL matches columns by position.
CREATE VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_union_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT t, env, service, flow, flow_type, status_code, destination, deployment, instance, feature_flags,
    method, route, end_reason,
    '' AS fingerprint, '' AS framework_result, '' AS caught, '' AS user_error,
    '' AS parent_service, '' AS parent_flow, '' AS parent_multiple, '' AS root_service, '' AS root_flow, '' AS root_multiple,
    duration_count AS calls, duration_count, duration_sum, buckets,
    e2e_count, e2e_sum, e2e_buckets,
    toFloat64(0) AS issues, toFloat64(0) AS messages, toFloat64(0) AS runs_by_caller,
    last_seen, attributes, attribute_counts
FROM ${DATABASE}.endpoint_durations_v2
UNION ALL
SELECT t, env, service, flow, flow_type, status_code, destination, deployment, instance, feature_flags,
    method, route, end_reason,
    fingerprint, framework_result, caught, user_error,
    parent_service, parent_flow, parent_multiple, root_service, root_flow, root_multiple,
    toUInt64(0), toUInt64(0), toFloat64(0), map(),
    toUInt64(0), toFloat64(0), map(),
    issues, messages, runs_by_caller,
    last_seen, map(), map()
FROM ${DATABASE}.endpoint_counters_v2
COMMENT 'endpoint_durations_v2 and endpoint_counters_v2 as one, at the fine grain: duration rows carry empty strings and 0 in the counter columns and counter rows the reverse, so sum over both. calls is the runs (duration_count).';

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_v2
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
COMMENT 'Hourly rollup of endpoint_durations_v2 and endpoint_counters_v2 with all their columns, SDK session included. AggregatingMergeTree: a key has separate duration and counter rows until merged, so read with sum, sumMap, max and groupUniqArrayArrayMapMerge(1000) grouped by the columns needed. Filled by endpoint_metrics_1h_v2_from_durations_mv and endpoint_metrics_1h_v2_from_counters_mv, kept 90 days.';

CREATE TABLE IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_v2
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
COMMENT 'Hourly rollup like endpoint_metrics_1h_v2 without the SDK session (instance), so far fewer rows: what most charts read. Read with sum, sumMap, max and groupUniqArrayArrayMapMerge(1000). Filled by endpoint_metrics_lean_1h_v2_from_durations_mv and endpoint_metrics_lean_1h_v2_from_counters_mv, kept 180 days.';
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
        arrayStringConcat(arrayMap(k -> concat(
            replaceAll(replaceAll(replaceAll(substring(k, 18), '%', '%25'), ',', '%2C'), '=', '%3D'), '=', flags[k]),
            arraySort(mapKeys(flags))), ',')) AS feature_flags,
    sumIf(Count, run) AS duration_count, sumIf(Sum, run) AS duration_sum, sumMapIf(point_buckets, run) AS buckets,
    sumIf(Count, NOT run) AS e2e_count, sumIf(Sum, NOT run) AS e2e_sum, sumMapIf(point_buckets, NOT run) AS e2e_buckets,
    max(TimeUnix) AS last_seen, groupUniqArrayMapIf(1000)(other, run) AS attributes,
    sumMapIf(mapApply((k, v) -> (sipHash64(concat(k, '=', v)) % 100000, Count), other), run) AS attribute_counts
FROM ${DATABASE}.otel_metrics_exponential_histogram
WHERE MetricName IN ('code.flow.duration', 'hud.flow.e2e.duration') AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance,
    feature_flags
COMMENT 'Reads code.flow.duration and hud.flow.e2e.duration delta points from otel_metrics_exponential_histogram, maps their buckets onto scale 2 and writes them to endpoint_durations_v2, grouped per insert.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_counters_v2_mv TO ${DATABASE}.endpoint_counters_v2
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
        arrayStringConcat(arrayMap(k -> concat(
            replaceAll(replaceAll(replaceAll(substring(k, 18), '%', '%25'), ',', '%2C'), '=', '%3D'), '=', flags[k]),
            arraySort(mapKeys(flags))), ',')) AS feature_flags,
    sumIf(Value, MetricName = 'hud.flow.messages') AS messages, sumIf(Value, MetricName = 'hud.flow.issues') AS issues,
    sumIf(Value, MetricName = 'hud.flow.calling_flows') AS runs_by_caller, max(TimeUnix) AS last_seen
FROM ${DATABASE}.otel_metrics_sum
WHERE MetricName IN ('hud.flow.messages', 'hud.flow.issues', 'hud.flow.calling_flows') AND AggregationTemporality = 1
GROUP BY t, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, instance, feature_flags
COMMENT 'Reads hud.flow.messages, hud.flow.issues and hud.flow.calling_flows delta points from otel_metrics_sum and writes them to endpoint_counters_v2, grouped per insert.';
CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_v2_from_durations_mv TO ${DATABASE}.endpoint_metrics_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    instance, feature_flags,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations_v2
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, instance,
    feature_flags
COMMENT 'Rolls each endpoint_durations_v2 insert up by hour into endpoint_metrics_1h_v2.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_v2_from_durations_mv TO ${DATABASE}.endpoint_metrics_lean_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment,
    feature_flags,
    sum(duration_count) AS duration_count, sum(duration_sum) AS duration_sum, sumMap(buckets) AS buckets,
    sum(e2e_count) AS e2e_count, sum(e2e_sum) AS e2e_sum, sumMap(e2e_buckets) AS e2e_buckets, max(last_seen) AS last_seen,
    groupUniqArrayArrayMapState(1000)(attributes) AS attributes, sumMap(attribute_counts) AS attribute_counts
FROM ${DATABASE}.endpoint_durations_v2
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, feature_flags
COMMENT 'Rolls each endpoint_durations_v2 insert up by hour into endpoint_metrics_lean_1h_v2.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_1h_v2_from_counters_mv TO ${DATABASE}.endpoint_metrics_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination,
    deployment, fingerprint, framework_result, caught, user_error, parent_service, parent_flow, parent_multiple,
    root_service, root_flow, root_multiple, instance, feature_flags,
    sum(messages) AS messages, sum(issues) AS issues, sum(runs_by_caller) AS runs_by_caller, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters_v2
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, instance, feature_flags
COMMENT 'Rolls each endpoint_counters_v2 insert up by hour into endpoint_metrics_1h_v2.';

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_lean_1h_v2_from_counters_mv TO ${DATABASE}.endpoint_metrics_lean_1h_v2
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT toStartOfHour(t) AS hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination,
    deployment, fingerprint, framework_result, caught, user_error, parent_service, parent_flow, parent_multiple,
    root_service, root_flow, root_multiple, feature_flags,
    sum(messages) AS messages, sum(issues) AS issues, sum(runs_by_caller) AS runs_by_caller, max(last_seen) AS last_seen
FROM ${DATABASE}.endpoint_counters_v2
GROUP BY hour, env, service, flow, flow_type, method, route, status_code, end_reason, destination, deployment, fingerprint,
    framework_result, caught, user_error, parent_service, parent_flow, parent_multiple, root_service, root_flow,
    root_multiple, feature_flags
COMMENT 'Rolls each endpoint_counters_v2 insert up by hour into endpoint_metrics_lean_1h_v2.';

-- The unversioned union was added after hud.3 and may already exist on later releases.
CREATE VIEW IF NOT EXISTS ${DATABASE}.endpoint_metrics_union
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT * FROM ${DATABASE}.endpoint_metrics_union_v2;
