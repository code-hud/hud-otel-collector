#!/usr/bin/env bash
# Five fake pods (three on deployment v1, two on v2) send deltas concurrently. Function metrics must merge
# into one Prometheus series per deployment holding its sum; flow and process metrics must stay one series per pod.
# Then the ClickHouse path: hud-migrate creates the schema, and deltas (with a calling flow, an issue and function
# errors), an exponential histogram, process gauges and a log sent through test/clickhouse.yaml must come out of the SQL
# tables and otel_logs exactly, a metric no view reads must stay in otel_metrics_*, a flow's feature flag combinations
# must stay separate rows in the endpoint tables, and a retried insert must count once.
set -euo pipefail

IMAGE=${IMAGE:-hud-otelcol:dev}
PROM_IMAGE=${PROM_IMAGE:-prom/prometheus:v3.7.3}
CLICKHOUSE_IMAGE=${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server:26.10}
GO_IMAGE=${GO_IMAGE:-golang:1.26}
NET=hud-otelcol-smoke
DIR=$(cd "$(dirname "$0")" && pwd)
PLAYGROUND=$DIR/../playground/clickstack

cleanup() {
  docker rm -f smoke-collector smoke-prometheus smoke-clickhouse smoke-clickstack smoke-clickstack-tls >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
  [ -z "${TLS_DIR:-}" ] || rm -rf "$TLS_DIR"
}
trap cleanup EXIT
cleanup
TLS_DIR=$(mktemp -d)

echo "--- components"
components=$(docker run --rm "$IMAGE" components)
for c in otlp batch filter transform delta_to_cumulative interval prometheus_remote_write sigv4auth clickhouse basicauth; do
  grep -q "name: $c\$" <<<"$components" || { echo "missing component: $c"; exit 1; }
done

echo "--- validate AMP and ClickHouse configs"
docker run --rm -v "$DIR:/cfg:ro" -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
  "$IMAGE" validate --config /cfg/amp.yaml
docker run --rm -v "$DIR:/cfg:ro" -e CLICKHOUSE_ENDPOINT=http://localhost:8123 -e CLICKHOUSE_USER=u -e CLICKHOUSE_PASSWORD=p \
  "$IMAGE" validate --config /cfg/clickhouse.yaml

echo "--- start Prometheus and collector"
docker network create $NET >/dev/null
docker run -d --name smoke-prometheus --network $NET -p 19090:9090 "$PROM_IMAGE" \
  --config.file=/etc/prometheus/prometheus.yml --web.enable-remote-write-receiver >/dev/null
docker run -d --name smoke-collector --network $NET -p 14318:4318 -v "$DIR:/cfg:ro" \
  -e REMOTE_WRITE_URL=http://smoke-prometheus:9090/api/v1/write "$IMAGE" --config /cfg/merge.yaml >/dev/null

for _ in $(seq 30); do curl -s -o /dev/null localhost:14318 && break; sleep 1; done

BASE=$(($(date +%s) - 20))
send() { # pod pid round deployment: a delta of 1 for a function and a flow counter, plus a gauge
  local start=$(((BASE + $3) * 1000000000)) end=$(((BASE + $3 + 1) * 1000000000))
  local delta="\"aggregationTemporality\":1,\"isMonotonic\":true,\"dataPoints\":[{\"asInt\":\"1\",\"startTimeUnixNano\":\"$start\",\"timeUnixNano\":\"$end\"}]"
  curl -sf -X POST localhost:14318/v1/metrics -H 'Content-Type: application/json' -d @- <<EOF >/dev/null
{"resourceMetrics":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"smoke"}},
  {"key":"service.instance.id","value":{"stringValue":"$1"}},
  {"key":"k8s.pod.name","value":{"stringValue":"$1"}},
  {"key":"process.pid","value":{"intValue":"$2"}},
  {"key":"deployment.id","value":{"stringValue":"$4"}},
  {"key":"telemetry.sdk.version","value":{"stringValue":"1.11.1"}}]},
 "scopeMetrics":[{"metrics":[
  {"name":"code.function.calls","sum":{$delta}},
  {"name":"hud.flow.messages","sum":{$delta}},
  {"name":"process.memory.usage","gauge":{"dataPoints":[{"asInt":"$2","timeUnixNano":"$end"}]}}]}]}]}
EOF
}

echo "--- send 5 pods x 10 rounds, concurrently"
for r in $(seq 10); do
  pid=100; for p in a b c d e; do send "pod-$p" $pid "$r" $([[ $p < d ]] && echo v1 || echo v2) & pid=$((pid + 1)); done
  wait
done

query() { curl -s localhost:19090/api/v1/query --data-urlencode "query=$1" | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'; }
# function calls: pod attributes dropped, one series per deployment under the collector's instance, each the
# sum of its pods; flow messages and memory gauges: one series per pod
checks=(
  'sum(code_function_calls_total)=50'
  'count(code_function_calls_total)=2'
  'sum(code_function_calls_total{deployment_id="v1"})=30'
  'sum(code_function_calls_total{deployment_id="v2"})=20'
  'count(code_function_calls_total{instance=~"pod-.*"}) or vector(0)=0'
  'count(code_function_calls_total{telemetry_sdk_version!=""}) or vector(0)=0'
  'sum(hud_flow_messages_total)=50'
  'count(hud_flow_messages_total{instance=~"pod-.*"})=5'
  'count(hud_flow_messages_total{deployment_id="v1"})=3'
  'count(process_memory_usage{instance=~"pod-.*"})=5'
)

# poll <query function> <collector container> <query=want>...: retries until every query returns its value
poll() {
  local q=$1 container=$2 failed=() c got; shift 2
  for _ in $(seq 30); do
    failed=()
    for c in "$@"; do
      got=$($q "${c%=*}"); [ "$got" = "${c##*=}" ] || failed+=("${c%=*}: got ${got:-none}, want ${c##*=}")
    done
    [ ${#failed[@]} = 0 ] && { echo "PASS: $# checks"; return; }
    sleep 1
  done
  printf 'FAIL: %s\n' "${failed[@]}"
  docker logs "$container" | tail -30
  exit 1
}
poll query smoke-collector "${checks[@]}"

# A non-default database name, so the setup script, hud-migrate and the collector config all have to follow it
DB=hud_otel_smoke
echo "--- ClickHouse: the server with the playground's setup script, database $DB"
SETUP=(-v "$PLAYGROUND/setup.sh:/docker-entrypoint-initdb.d/setup.sh:ro" -v "$PLAYGROUND/setup.sql:/hud/setup.sql:ro")
out=$(docker run --rm "${SETUP[@]}" -e "HUD_CLICKHOUSE_DATABASE=x; DROP USER y" \
  --entrypoint /docker-entrypoint-initdb.d/setup.sh "$CLICKHOUSE_IMAGE" 2>&1 || true)
grep -q "not a plain identifier" <<<"$out" || { echo "FAIL: setup.sh took an unsafe database name: $out"; exit 1; }
# HTTPS on 8443 too, with a self-signed certificate, for the TLS checks at the end
docker run --rm --user "$(id -u):$(id -g)" -v "$TLS_DIR:/out" "$GO_IMAGE" openssl req -x509 -newkey rsa:2048 -nodes \
  -subj /CN=smoke-clickhouse -days 1 -keyout /out/key.pem -out /out/cert.pem 2>/dev/null
chmod 755 "$TLS_DIR" && chmod 644 "$TLS_DIR"/*.pem
docker run -d --name smoke-clickhouse --network $NET -p 18123:8123 \
  -e CLICKHOUSE_PASSWORD=admin-pass -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 -e HUD_CLICKHOUSE_DATABASE=$DB \
  -v "$DIR/clickhouse-tls.xml:/etc/clickhouse-server/config.d/tls.xml:ro" -v "$TLS_DIR:/etc/clickhouse-server/certs:ro" \
  "${SETUP[@]}" "$CLICKHOUSE_IMAGE" >/dev/null
# The image runs setup.sh on a temporary server, then restarts it
for _ in $(seq 60); do
  [ "$(curl -s -u hud_backend:Backend-pass-1234 localhost:18123 --data-binary 'SELECT 1')" = 1 ] && break; sleep 1
done
MIGRATOR=(-e CLICKHOUSE_ENDPOINT=tcp://smoke-clickhouse:9000 -e CLICKHOUSE_USER=hud_migrator -e CLICKHOUSE_PASSWORD=Migrator-pass-1234
  -e HUD_CLICKHOUSE_DATABASE=$DB)
migrate() { docker run --rm --network $NET "${MIGRATOR[@]}" --entrypoint /hud-migrate "$IMAGE" "$@"; }

echo "--- hud-migrate: HUD_SCHEMA_MANAGED=false doesn't connect, 4 concurrent up create $DB, grants refuse DROP, ADD INDEX and other databases, go test (incl. the create-only check)"
docker run --rm -e HUD_SCHEMA_MANAGED=false --entrypoint /hud-migrate "$IMAGE" up
pids=(); for _ in 1 2 3 4; do migrate up & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
tables=$(curl -s -u hud_backend:Backend-pass-1234 localhost:18123 \
  --data-binary "SELECT groupArray(name) FROM (SELECT name FROM system.tables WHERE database = '$DB' AND name NOT LIKE '.inner%' ORDER BY name)")
want="['endpoint_counters','endpoint_counters_mv','endpoint_durations','endpoint_durations_mv','endpoint_metrics_1h',\
'endpoint_metrics_1h_from_counters_mv','endpoint_metrics_1h_from_durations_mv','endpoint_metrics_lean_1h',\
'endpoint_metrics_lean_1h_from_counters_mv','endpoint_metrics_lean_1h_from_durations_mv','endpoint_metrics_union','endpoints',\
'endpoints_from_durations_mv','endpoints_from_process_mv','function_counters','function_counters_mv',\
'function_durations','function_durations_mv','function_metrics_1h','function_metrics_1h_from_counters_mv',\
'function_metrics_1h_from_durations_mv','function_metrics_lean_1h','function_metrics_lean_1h_from_counters_mv',\
'function_metrics_lean_1h_from_durations_mv','functions','functions_mv','otel_logs',\
'otel_metrics_exponential_histogram','otel_metrics_gauge','otel_metrics_histogram','otel_metrics_sum',\
'otel_metrics_summary','process_metrics','process_metrics_1h','process_metrics_1h_mv','process_metrics_mv']"
[ "$tables" = "$want" ] || { echo "FAIL: $DB has $tables after up, want $want"; exit 1; }
for q in "DROP TABLE $DB.otel_logs" "ALTER TABLE $DB.otel_logs ADD INDEX smoke_idx Body TYPE bloom_filter" \
  "DROP DATABASE $DB" "CREATE DATABASE hud_otel"; do
  curl -s -u hud_migrator:Migrator-pass-1234 localhost:18123 --data-binary "$q" | grep -q ACCESS_DENIED || { echo "FAIL: hud_migrator may run: $q"; exit 1; }
done
docker run --rm --network $NET "${MIGRATOR[@]}" -v "$DIR/../hud-migrate:/src" -w /src \
  -v hud-otelcol-gomod:/go/pkg/mod -v hud-otelcol-gocache:/root/.cache/go-build "$GO_IMAGE" go test -count=1 ./...

echo "--- ClickHouse collector: two deltas of a counter and of a scale-2 exponential histogram per flow and function (scale 3 for queue latency, next to a Kafka run), function errors, process gauges and memory, a metric no view reads, one log, 3-minute deltas across an hour, a 2-hour delta; no key twice in a fine table"
docker run -d --name smoke-clickstack --network $NET -p 14319:4318 -v "$DIR:/cfg:ro" \
  -e CLICKHOUSE_ENDPOINT=http://smoke-clickhouse:8123 -e CLICKHOUSE_USER=hud_collector -e CLICKHOUSE_PASSWORD=Collector-pass-1234 \
  -e HUD_CLICKHOUSE_DATABASE=$DB "$IMAGE" --config /cfg/clickhouse.yaml >/dev/null
for _ in $(seq 30); do curl -s -o /dev/null localhost:14319 && break; sleep 1; done

# Buckets (2^(k/4), 2^((k+1)/4)] s for k = -14..-12 hold 1, 2 and 2 per delta, so the median of both deltas (the 5th of
# 10) is 3/4 into k = -13 on the log scale: 2^(-12.25/4) = 0.1197 s. Queue latency's scale-3 buckets -27..-25 go to
# k = -14, -13 and -13. The Kafka flow's run (one per delta, zero-length so it adds no bucket) shares its queue
# latency's row.
RESOURCE='{"attributes":[{"key":"service.name","value":{"stringValue":"smoke"}},{"key":"service.instance.id","value":{"stringValue":"pod-a"}},
  {"key":"deployment.environment.name","value":{"stringValue":"smoke-env"}},{"key":"deployment.id","value":{"stringValue":"d1"}},
  {"key":"telemetry.sdk.version","value":{"stringValue":"1.12.5"}}]}'
FUNCTION='"attributes":[{"key":"code.function.name","value":{"stringValue":"f"}},{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}},
  {"key":"code.function.caller.name","value":{"stringValue":"g"}},{"key":"code.function.caller.file.path","value":{"stringValue":"g.ts"}},
  {"key":"hud.function.content_hash","value":{"stringValue":"h1"}},
  {"key":"hud.function.kind","value":{"stringValue":"method"}}]'
FLOW='"attributes":[{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}},{"key":"code.flow.type","value":{"stringValue":"http"}},{"key":"http.response.status_code","value":{"intValue":"500"}}]'
KAFKA='"attributes":[{"key":"code.flow.name","value":{"stringValue":"kafka|q|c"}}]'
CALLER='"attributes":[{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}},{"key":"hud.parent.service.name","value":{"stringValue":"caller"}},
  {"key":"hud.parent.flow.name","value":{"stringValue":"kafka|t|g"}},{"key":"hud.root.service.name","value":{"stringValue":"edge"}},{"key":"hud.root.flow.name","value":{"stringValue":"http|/y|post"}}]'
ISSUE='"attributes":[{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}},{"key":"issue.fingerprint","value":{"stringValue":"fp"}},
  {"key":"hud.issue.caught","value":{"boolValue":false}},{"key":"hud.issue.user_error","value":{"stringValue":"card declined"}},
  {"key":"hud.parent.service.name","value":{"stringValue":"caller"}},{"key":"hud.parent.flow.name","value":{"stringValue":"kafka|t|g"}}]'
FUNCTION_ERROR="${FUNCTION%]}"',{"key":"error.type","value":{"stringValue":"TypeError"}}]'
CPU=(0 0.25 0.75) ELU=(0 0.1 0.3)
for r in 1 2; do
  start=$(((BASE + r) * 1000000000)) end=$(((BASE + r + 1) * 1000000000))
  curl -sf -X POST localhost:14319/v1/metrics -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":$RESOURCE,"scopeMetrics":[{"metrics":[
  {"name":"hud.flow.messages","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.flow.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[{$FLOW,"startTimeUnixNano":"$start","timeUnixNano":"$end",
    "count":"5","sum":0.55,"scale":2,"zeroCount":"0","positive":{"offset":-14,"bucketCounts":["1","2","2"]}},
    {$KAFKA,"startTimeUnixNano":"$start","timeUnixNano":"$end","count":"1","sum":0,"scale":2,"zeroCount":"1"}]}},
  {"name":"hud.flow.e2e.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[{$KAFKA,"startTimeUnixNano":"$start","timeUnixNano":"$end",
    "count":"3","sum":0.3,"scale":3,"zeroCount":"0","positive":{"offset":-27,"bucketCounts":["1","1","1"]}}]}},
  {"name":"process.uptime","unit":"s","gauge":{"dataPoints":[{"asDouble":$((40 + r)),"timeUnixNano":"$end"}]}},
  {"name":"process.cpu.utilization","gauge":{"dataPoints":[{"asDouble":${CPU[$r]},"timeUnixNano":"$end"}]}},
  {"name":"nodejs.eventloop.utilization","gauge":{"dataPoints":[{"asDouble":${ELU[$r]},"timeUnixNano":"$end"}]}},
  {"name":"process.memory.usage","unit":"By","sum":{"aggregationTemporality":2,"dataPoints":[{"asInt":"$((100 * r))","startTimeUnixNano":"$((BASE * 1000000000))","timeUnixNano":"$end"}]}},
  {"name":"hud.process.memory.limit","unit":"By","sum":{"aggregationTemporality":2,"dataPoints":[{"asInt":"1000","startTimeUnixNano":"$((BASE * 1000000000))","timeUnixNano":"$end"}]}},
  {"name":"app.orders","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"asInt":"3","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.function.errors","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$FUNCTION_ERROR,"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"hud.flow.calling_flows","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$CALLER,"asInt":"4","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"hud.flow.issues","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$ISSUE,"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.function.calls","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$FUNCTION,"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.function.call.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[{$FUNCTION,"startTimeUnixNano":"$start","timeUnixNano":"$end",
    "count":"5","sum":0.55,"scale":2,"zeroCount":"0","positive":{"offset":-14,"bucketCounts":["1","2","2"]}}]}}]}]}]}
EOF
done
# A delta is one row at its end, however long, in the hour it ends in (H is an hour boundary): 9 messages from
# H - 150 s to H + 30 s, 9 calls from H - 120 s to H + 60 s, 7 messages from H - 2 h to H.
H=$((BASE / 3600 * 3600 - 3600))
curl -sf -X POST localhost:14319/v1/metrics -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-delta"}}]},"scopeMetrics":[{"metrics":[
  {"name":"hud.flow.messages","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$FLOW,"asInt":"9",
    "startTimeUnixNano":"$(((H - 150) * 1000000000))","timeUnixNano":"$(((H + 30) * 1000000000))"}]}},
  {"name":"code.function.calls","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"attributes":[{"key":"code.function.name","value":{"stringValue":"g"}}],"asInt":"9",
    "startTimeUnixNano":"$(((H - 120) * 1000000000))","timeUnixNano":"$(((H + 60) * 1000000000))"}]}}]}]},
 {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-long"}}]},"scopeMetrics":[{"metrics":[
  {"name":"hud.flow.messages","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"asInt":"7",
    "startTimeUnixNano":"$(((H - 7200) * 1000000000))","timeUnixNano":"$((H * 1000000000))"}]}}]}]}]}
EOF
curl -sf -X POST localhost:14319/v1/logs -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceLogs":[{"resource":$RESOURCE,"scopeLogs":[{"logRecords":[
  {"timeUnixNano":"$((BASE * 1000000000))","eventName":"hud.forensic","severityText":"ERROR","body":{"stringValue":"{}"}}]}]}]}
EOF

# As hud_backend, the read-only user Hud's backend gets.
sql() { curl -s -u hud_backend:Backend-pass-1234 localhost:18123 --data-binary "$1"; }
F="$DB.endpoint_durations WHERE service = 'smoke' AND env = 'smoke-env'"
FLOW_ROWS="service = 'smoke' AND flow = 'http|/x|get' AND fingerprint = '' AND parent_flow = ''"
poll sql smoke-clickstack \
  "SELECT sum(messages) FROM $DB.endpoint_counters WHERE service = 'smoke' AND env = 'smoke-env'=2" \
  "SELECT sum(duration_count) FROM $F AND flow = 'http|/x|get' AND status_code = '500' AND deployment = 'd1'=10" \
  "SELECT sumMap(buckets) FROM $F={-14:2,-13:4,-12:4}" \
  "SELECT round(hud_duration_quantile(0.5, sumMap(buckets)), 4) FROM $F=0.1197" \
  "SELECT sumMap(e2e_buckets) FROM $F AND flow = 'kafka|q|c'={-14:2,-13:4}" \
  "SELECT toString((count(), sum(duration_count), sum(e2e_count))) FROM $F AND flow = 'kafka|q|c'=(2,2,6)" \
  "SELECT sum(duration_count) FROM $DB.endpoint_metrics_lean_1h WHERE service = 'smoke'=12" \
  "SELECT sumMap(buckets) FROM $DB.endpoint_metrics_lean_1h WHERE service = 'smoke'={-14:2,-13:4,-12:4}" \
  "SELECT sumMap(buckets) FROM $DB.endpoint_metrics_1h WHERE instance = 'pod-a'={-14:2,-13:4,-12:4}" \
  "SELECT sumIf(duration_count, startsWith(status_code, '5')) FROM $DB.endpoint_metrics_1h WHERE instance = 'pod-a'=10" \
  "SELECT toString((count(), sum(calls))) FROM $DB.function_counters WHERE function = 'f' AND deployment = 'd1' AND error_type = ''=(2,2)" \
  "SELECT toString((count(), sum(errors))) FROM $DB.function_counters WHERE function = 'f' AND error_type = 'TypeError'=(2,2)" \
  "SELECT toString((count(), sum(duration_count))) FROM $DB.function_durations WHERE function = 'f'=(2,10)" \
  "SELECT sumMap(buckets) FROM $DB.function_durations WHERE function = 'f'={-14:2,-13:4,-12:4}" \
  "SELECT sumMap(buckets) FROM $DB.function_metrics_lean_1h WHERE function = 'f'={-14:2,-13:4,-12:4}" \
  "SELECT sumMap(buckets) FROM $DB.function_metrics_1h WHERE function = 'f' AND caller = 'g'={-14:2,-13:4,-12:4}" \
  "SELECT sum(calls) FROM $DB.function_metrics_1h WHERE function = 'f' AND flow = 'http|/x|get' AND caller = 'g' AND caller_file = 'g.ts' AND content_hash = 'h1'=2" \
  "SELECT sum(errors) FROM $DB.function_metrics_lean_1h WHERE function = 'f'=2" \
  "SELECT sum(errors) FROM $DB.function_metrics_1h WHERE function = 'f' AND error_type = 'TypeError'=2" \
  "SELECT hud_attribute_count('hud.function.kind', 'method', sumMap(attribute_counts)) FROM $DB.function_metrics_lean_1h WHERE function = 'f'=10" \
  "SELECT groupUniqArrayArrayMapMerge(1000)(attributes)['telemetry.sdk.version'] FROM $DB.endpoint_metrics_lean_1h WHERE service = 'smoke'=['1.12.5']" \
  "SELECT arraySort(mapKeys(groupUniqArrayArrayMapMerge(1000)(attributes))) FROM $DB.function_metrics_lean_1h WHERE function = 'f'=['hud.function.kind','telemetry.sdk.version']" \
  "SELECT length(sumMap(attribute_counts)) FROM $DB.function_metrics_1h WHERE function = 'f'=2" \
  "SELECT hud_attribute_count('hud.function.kind', 'method', sumMap(attribute_counts)) FROM $DB.function_durations WHERE function = 'f'=10" \
  "SELECT groupUniqArrayArrayMap(1000)(attributes)['telemetry.sdk.version'] FROM $F=['1.12.5']" \
  "SELECT countIf(duration_count = 0) FROM $DB.function_metrics_lean_1h FINAL WHERE function = 'f'=0" \
  "SELECT countIf(duration_count = 0) FROM $DB.function_metrics_1h FINAL WHERE function = 'f' AND error_type = ''=0" \
  "SELECT countIf(duration_count = 0) FROM $DB.endpoint_metrics_lean_1h FINAL WHERE $FLOW_ROWS=0" \
  "SELECT countIf(duration_count = 0) FROM $DB.endpoint_metrics_1h FINAL WHERE $FLOW_ROWS=0" \
  "SELECT max(uptime) FROM $DB.process_metrics WHERE instance = 'pod-a' AND env = 'smoke-env' AND last_seen > 0=42" \
  "SELECT toString((count(), sum(cpu_count), sum(memory_count), sum(elu_count))) FROM $DB.process_metrics WHERE instance = 'pod-a'=(2,2,2,2)" \
  "SELECT toString((round(sum(cpu_sum) / sum(cpu_count), 3), max(cpu_max), round(sum(elu_sum) / sum(elu_count), 3), max(elu_max), max(memory_max), max(memory_limit))) FROM $DB.process_metrics WHERE instance = 'pod-a'=(0.5,0.75,0.2,0.3,200,1000)" \
  "SELECT toString((max(cpu_max), max(memory_max))) FROM $DB.process_metrics_1h WHERE instance = 'pod-a'=(0.75,200)" \
  "SELECT sum(Value) FROM $DB.otel_metrics_sum WHERE ServiceName = 'smoke' AND MetricName = 'app.orders'=6" \
  "SELECT sum(runs_by_caller) FROM $DB.endpoint_counters WHERE flow = 'http|/x|get' AND parent_service = 'caller' AND parent_flow = 'kafka|t|g' AND root_service = 'edge' AND root_flow = 'http|/y|post'=8" \
  "SELECT sum(runs_by_caller) FROM $DB.endpoint_metrics_lean_1h WHERE parent_service = 'caller'=8" \
  "SELECT sum(issues) FROM $DB.endpoint_metrics_lean_1h WHERE fingerprint = 'fp' AND caught = 'false' AND user_error = 'card declined' AND parent_service = '' AND parent_flow = ''=2" \
  "SELECT sum(issues) FROM $DB.endpoint_metrics_1h WHERE instance = 'pod-a'=2" \
  "SELECT toString((sum(calls), sum(duration_count), sumIf(calls, startsWith(status_code, '5')), sumIf(issues, fingerprint = 'fp'), sum(runs_by_caller), sumMap(buckets))) FROM $DB.endpoint_metrics_union WHERE service = 'smoke' AND flow = 'http|/x|get'=(10,10,10,2,8,{-14:2,-13:4,-12:4})" \
  "SELECT groupArray(flow) FROM (SELECT DISTINCT flow FROM $DB.endpoints WHERE service = 'smoke' ORDER BY flow)=['','http|/x|get','kafka|q|c']" \
  "SELECT groupArray(flow || '/' || function) FROM (SELECT DISTINCT flow, function FROM $DB.functions WHERE service = 'smoke' ORDER BY ALL)=['http|/x|get/f']" \
  "SELECT toString((count(), sum(messages), toUnixTimestamp(min(t)))) FROM $DB.endpoint_counters WHERE service = 'smoke-delta'=(1,9,$((H + 30)))" \
  "SELECT toString((count(), sum(calls), toUnixTimestamp(min(t)))) FROM $DB.function_counters WHERE service = 'smoke-delta'=(1,9,$((H + 60)))" \
  "SELECT toString((sum(messages), toUnixTimestamp(min(hour)))) FROM $DB.endpoint_metrics_lean_1h WHERE service = 'smoke-delta'=(9,$H)" \
  "SELECT toString((count(), sum(messages), toUnixTimestamp(min(t)))) FROM $DB.endpoint_counters WHERE service = 'smoke-long'=(1,7,$H)"
poll sql smoke-clickstack "SELECT count() FROM $DB.otel_logs WHERE EventName = 'hud.forensic' AND ServiceName = 'smoke'=1"

echo "--- feature flags: two combinations (about 0.1 s and 2 s), an overflow and runs without flags stay separate rows in the endpoint tables, and the flow dashboard's 'By feature flag' query reads them"
FLAGS_RESOURCE='{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-flags"}},{"key":"service.instance.id","value":{"stringValue":"pod-f"}},
  {"key":"deployment.environment.name","value":{"stringValue":"smoke-env"}}]}'
ff() { # status code, then attribute name and boolean pairs
  local status=$1; shift
  echo "\"attributes\":[{\"key\":\"code.flow.name\",\"value\":{\"stringValue\":\"http|/f|get\"}},{\"key\":\"code.flow.type\",\"value\":{\"stringValue\":\"http\"}},
    {\"key\":\"http.response.status_code\",\"value\":{\"intValue\":\"$status\"}}$(printf ',{"key":"%s","value":{"boolValue":%s}}' "$@")]"
}
A=$(ff 200 hud.feature_flag.new_checkout true hud.feature_flag.fast_path false)
B=$(ff 500 hud.feature_flag.new_checkout false hud.feature_flag.fast_path true) OVERFLOW=$(ff 200 hud.feature_flags.overflow true)
NONE='"attributes":[{"key":"code.flow.name","value":{"stringValue":"http|/f|get"}},{"key":"code.flow.type","value":{"stringValue":"http"}},{"key":"http.response.status_code","value":{"intValue":"200"}}]'
start=$(((BASE + 1) * 1000000000)) end=$(((BASE + 2) * 1000000000))
point() { echo "{$1,\"startTimeUnixNano\":\"$start\",\"timeUnixNano\":\"$end\",\"count\":\"$2\",\"sum\":$3,\"scale\":2,\"zeroCount\":\"0\",\"positive\":{\"offset\":$4,\"bucketCounts\":[\"$2\"]}}"; }
curl -sf -X POST localhost:14319/v1/metrics -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":$FLAGS_RESOURCE,"scopeMetrics":[{"metrics":[
  {"name":"code.flow.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[
    $(point "$A" 4 0.4 -14),$(point "$B" 2 4 4),$(point "$OVERFLOW" 1 0.1 -14),$(point "$NONE" 3 0.3 -14)]}},
  {"name":"hud.flow.issues","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{${A%]},{"key":"issue.fingerprint","value":{"stringValue":"fp-flags"}}],
    "asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}}]}]}]}
EOF
# The tile's query, with its macros filled in for this flow and a range of fine rows and whole hours.
PANEL=$(cat <<'EOF'
SELECT multiIf(ff = '', 'no flags', ff = '__hud_other__', 'other combinations', ff) AS `Feature flags`, round(tn) AS Runs,
    round(100 * tn / sum(tn) OVER (), 1) AS `Distribution %`, round(100 * (te + tio) / tn, 1) AS `Err Rate (%)`,
    round(1000 * td / tn, 1) AS `Avg ms`, round(1e3 * hud_duration_quantile(0.9, tb), 1) AS `P90 ms`, round(ti) AS Issues
FROM (SELECT feature_flags AS ff, sum(runs) AS tn, sum(errors) AS te, sumIf(issues, flow_type != 'http') AS tio,
          sum(issues) AS ti, sum(dur) AS td, sumMap(bk) AS tb
      FROM (SELECT t, flow_type, feature_flags, duration_count AS runs, if(startsWith(status_code, '5'), duration_count, 0) AS errors, 0 AS issues, duration_sum AS dur, buckets AS bk FROM hud_otel.endpoint_durations WHERE $__fromTime >= now() - INTERVAL 30 DAY AND t >= $__fromTime AND t < $__toTime AND (t < toStartOfHour($__fromTime) + INTERVAL 1 HOUR OR (toStartOfHour($__toTime) > toStartOfHour($__fromTime) AND t >= toStartOfHour($__toTime))) AND $__filter(env, $env) AND $__filter(service, $service) AND $__filter(flow, $endpoint)
  UNION ALL SELECT t, flow_type, feature_flags, 0 AS runs, 0 AS errors, issues, 0 AS dur, map() AS bk FROM hud_otel.endpoint_counters WHERE $__fromTime >= now() - INTERVAL 30 DAY AND t >= $__fromTime AND t < $__toTime AND (t < toStartOfHour($__fromTime) + INTERVAL 1 HOUR OR (toStartOfHour($__toTime) > toStartOfHour($__fromTime) AND t >= toStartOfHour($__toTime))) AND $__filter(env, $env) AND $__filter(service, $service) AND $__filter(flow, $endpoint)
  UNION ALL SELECT hour AS t, flow_type, feature_flags, duration_count AS runs, if(startsWith(status_code, '5'), duration_count, 0) AS errors, issues, duration_sum AS dur, buckets AS bk FROM hud_otel.endpoint_metrics_lean_1h WHERE $__fromTime >= now() - INTERVAL 30 DAY AND hour >= toStartOfHour($__fromTime) + INTERVAL 1 HOUR AND hour < toStartOfHour($__toTime) AND $__filter(env, $env) AND $__filter(service, $service) AND $__filter(flow, $endpoint)
  UNION ALL SELECT hour AS t, flow_type, feature_flags, duration_count AS runs, if(startsWith(status_code, '5'), duration_count, 0) AS errors, issues, duration_sum AS dur, buckets AS bk FROM hud_otel.endpoint_metrics_lean_1h WHERE NOT ($__fromTime >= now() - INTERVAL 30 DAY) AND hour >= toStartOfHour($__fromTime) AND hour < $__toTime AND $__filter(env, $env) AND $__filter(service, $service) AND $__filter(flow, $endpoint))
      GROUP BY ff HAVING tn > 0)
ORDER BY Runs DESC
EOF
)
PANEL=${PANEL//hud_otel./$DB.} PANEL=${PANEL//\$__fromTime/toDateTime($((BASE - 7200)))} PANEL=${PANEL//\$__toTime/toDateTime($((BASE + 60)))}
PANEL=${PANEL//\$__filter(env, \$env)/env = \'smoke-env\'} PANEL=${PANEL//\$__filter(service, \$service)/service = \'smoke-flags\'}
PANEL=${PANEL//\$__filter(flow, \$endpoint)/flow = \'http|\/f|get\'}
FD="$DB.endpoint_durations WHERE service = 'smoke-flags'"
poll sql smoke-clickstack \
  "SELECT count() FROM $FD=4" \
  "SELECT toString((count(), sum(duration_count), sumMap(buckets))) FROM $FD AND feature_flags = 'fast_path=false,new_checkout=true' AND status_code = '200'=(1,4,{-14:4})" \
  "SELECT toString((count(), sum(duration_count), sumMap(buckets))) FROM $FD AND feature_flags = 'fast_path=true,new_checkout=false' AND status_code = '500'=(1,2,{4:2})" \
  "SELECT sum(duration_count) FROM $FD AND feature_flags = '__hud_other__'=1" \
  "SELECT sum(duration_count) FROM $FD AND feature_flags = ''=3" \
  "SELECT countIf(arrayExists(k -> startsWith(k, 'hud.feature_flag'), mapKeys(attributes))) FROM $FD=0" \
  "SELECT sum(issues) FROM $DB.endpoint_counters WHERE fingerprint = 'fp-flags' AND feature_flags = 'fast_path=false,new_checkout=true'=1" \
  "SELECT toString((sum(duration_count), sum(issues))) FROM $DB.endpoint_metrics_lean_1h WHERE service = 'smoke-flags' AND feature_flags = 'fast_path=false,new_checkout=true'=(4,1)" \
  "SELECT sum(duration_count) FROM $DB.endpoint_metrics_1h WHERE instance = 'pod-f' AND feature_flags = 'fast_path=true,new_checkout=false' AND status_code = '500'=2" \
  "SELECT toString(groupArray((Runs, \`Err Rate (%)\`, \`Avg ms\`, \`P90 ms\`, Issues))) FROM ($PANEL)=[(4,0,100,103.3,1),(3,0,100,103.3,0),(2,100,2000,2337.6,0),(1,0,100,103.3,0)]"

echo "--- retried insert: the exporter resends a failed batch as is (plain insert, dedup through the views, as clickhouse.yaml), which counts once; another pod's equal point still counts"
point() { echo '{"ResourceAttributes":{"service.instance.id":"'"$1"'"},"ServiceName":"smoke-retry","MetricName":"hud.flow.messages",'\
'"Attributes":{"code.flow.name":"http|/r|get"},"StartTimeUnix":'"$BASE"',"TimeUnix":'"$((BASE + 1))"',"Value":5,"AggregationTemporality":1,"IsMonotonic":true}'; }
for p in pod-a pod-a pod-b; do
  curl -sf -u hud_collector:Collector-pass-1234 "localhost:18123/?deduplicate_blocks_in_dependent_materialized_views=1&query=INSERT%20INTO%20$DB.otel_metrics_sum%20FORMAT%20JSONEachRow" \
    --data-binary "$(point $p)"
done
poll sql smoke-clickstack \
  "SELECT count() FROM $DB.otel_metrics_sum WHERE ServiceName = 'smoke-retry'=2" \
  "SELECT sum(messages) FROM $DB.endpoint_counters WHERE service = 'smoke-retry'=10" \
  "SELECT sum(messages) FROM $DB.endpoint_metrics_1h WHERE service = 'smoke-retry'=10" \
  "SELECT sum(messages) FROM $DB.endpoint_metrics_lean_1h WHERE service = 'smoke-retry'=10"

echo "--- TLS: hud-migrate and the collector on the https endpoint form Cloud uses (https://host:8443, trailing slash ok for hud-migrate)"
TLS=(-e CLICKHOUSE_TLS_INSECURE_SKIP_VERIFY=true -e HUD_CLICKHOUSE_DATABASE=$DB)
docker run --rm --network $NET -e CLICKHOUSE_ENDPOINT=https://smoke-clickhouse:8443/ -e CLICKHOUSE_USER=hud_migrator \
  -e CLICKHOUSE_PASSWORD=Migrator-pass-1234 "${TLS[@]}" --entrypoint /hud-migrate "$IMAGE" up
docker run -d --name smoke-clickstack-tls --network $NET -p 14320:4318 -v "$DIR:/cfg:ro" "${TLS[@]}" \
  -e CLICKHOUSE_ENDPOINT=https://smoke-clickhouse:8443 -e CLICKHOUSE_USER=hud_collector -e CLICKHOUSE_PASSWORD=Collector-pass-1234 \
  "$IMAGE" --config /cfg/clickhouse.yaml >/dev/null
for _ in $(seq 30); do curl -s -o /dev/null localhost:14320 && break; sleep 1; done
TLS_RESOURCE='{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-tls"}},{"key":"service.instance.id","value":{"stringValue":"pod-tls"}}]}'
curl -sf -X POST localhost:14320/v1/metrics -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":$TLS_RESOURCE,"scopeMetrics":[{"metrics":[
  {"name":"hud.flow.messages","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"asInt":"3","startTimeUnixNano":"$((BASE * 1000000000))","timeUnixNano":"$(((BASE + 1) * 1000000000))"}]}}]}]}]}
EOF
curl -sf -X POST localhost:14320/v1/logs -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceLogs":[{"resource":$TLS_RESOURCE,"scopeLogs":[{"logRecords":[
  {"timeUnixNano":"$((BASE * 1000000000))","eventName":"hud.forensic","severityText":"INFO","body":{"stringValue":"{}"}}]}]}]}
EOF
poll sql smoke-clickstack-tls "SELECT sum(messages) FROM $DB.endpoint_counters WHERE service = 'smoke-tls'=3"
poll sql smoke-clickstack-tls "SELECT count() FROM $DB.otel_logs WHERE ServiceName = 'smoke-tls'=1"
