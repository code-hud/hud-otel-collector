#!/usr/bin/env bash
# Five fake pods (three on deployment v1, two on v2) send deltas concurrently. Function metrics must merge
# into one Prometheus series per deployment holding its sum; flow and process metrics must stay one series per pod.
# Then the ClickStack path: hud-migrate creates the schema, and deltas (with a calling flow and an issue), an exponential
# histogram, a gauge and a log sent through test/clickstack.yaml must come out of the SQL tables and otel_logs exactly.
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

echo "--- validate AMP and ClickStack configs"
docker run --rm -v "$DIR:/cfg:ro" -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
  "$IMAGE" validate --config /cfg/amp.yaml
docker run --rm -v "$DIR:/cfg:ro" -e CLICKHOUSE_ENDPOINT=http://localhost:8123 -e CLICKHOUSE_USER=u -e CLICKHOUSE_PASSWORD=p \
  "$IMAGE" validate --config /cfg/clickstack.yaml

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
echo "--- ClickStack: ClickHouse with the playground's setup script, database $DB"
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
want="['calling_flow_1m','calling_flow_1m_runs','calling_flow_hourly','calling_flow_hourly_rollup','duration_bounds',\
'flow_1m','flow_1m_duration','flow_1m_e2e','flow_1m_messages','flow_hourly','flow_hourly_rollup','function_5m',\
'function_5m_calls','function_5m_duration','function_caller_5m','function_caller_5m_calls',\
'function_caller_5m_duration','function_caller_hourly','function_caller_hourly_rollup','function_hourly',\
'function_hourly_rollup','ingest_exponential_histogram','ingest_gauge','ingest_histogram','ingest_sum',\
'ingest_summary','issue_1m','issue_1m_issues','issue_hourly','issue_hourly_rollup','labels','labels_flows',\
'labels_functions','labels_sessions','metrics','otel_logs','session_flow_1m','session_flow_1m_issues',\
'session_flow_1m_runs','session_flow_hourly','session_flow_hourly_rollup','session_health_1m',\
'session_health_1m_gauge','session_health_1m_sum','session_health_hourly','session_health_hourly_rollup']"
[ "$tables" = "$want" ] || { echo "FAIL: $DB has $tables after up, want $want"; exit 1; }
for q in "DROP TABLE $DB.otel_logs" "ALTER TABLE $DB.otel_logs ADD INDEX smoke_idx Body TYPE bloom_filter" \
  "DROP DATABASE $DB" "CREATE DATABASE hud_otel"; do
  curl -s -u hud_migrator:Migrator-pass-1234 localhost:18123 --data-binary "$q" | grep -q ACCESS_DENIED || { echo "FAIL: hud_migrator may run: $q"; exit 1; }
done
docker run --rm --network $NET "${MIGRATOR[@]}" -v "$DIR/../hud-migrate:/src" -w /src \
  -v hud-otelcol-gomod:/go/pkg/mod -v hud-otelcol-gocache:/root/.cache/go-build "$GO_IMAGE" go test -count=1 ./...

echo "--- ClickStack collector: two deltas of a counter and of a scale-2 exponential histogram per flow and function, a gauge, one log"
docker run -d --name smoke-clickstack --network $NET -p 14319:4318 -v "$DIR:/cfg:ro" \
  -e CLICKHOUSE_ENDPOINT=http://smoke-clickhouse:8123 -e CLICKHOUSE_USER=hud_collector -e CLICKHOUSE_PASSWORD=Collector-pass-1234 \
  -e HUD_CLICKHOUSE_DATABASE=$DB "$IMAGE" --config /cfg/clickstack.yaml >/dev/null
for _ in $(seq 30); do curl -s -o /dev/null localhost:14319 && break; sleep 1; done

# Buckets (2^(k/4), 2^((k+1)/4)] s for k = -14..-12 hold 1, 2 and 2 per delta, so per delta the classic bucket
# le=0.0884 (just above 2^(-14/4)) holds 0, le=0.125 holds 3 and le=0.177 holds 5
RESOURCE='{"attributes":[{"key":"service.name","value":{"stringValue":"smoke"}},{"key":"service.instance.id","value":{"stringValue":"pod-a"}},
  {"key":"deployment.environment.name","value":{"stringValue":"smoke-env"}},{"key":"deployment.id","value":{"stringValue":"d1"}}]}'
FUNCTION='"attributes":[{"key":"code.function.name","value":{"stringValue":"f"}},{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}}]'
FLOW='"attributes":[{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}},{"key":"code.flow.type","value":{"stringValue":"http"}},{"key":"http.response.status_code","value":{"intValue":"500"}}]'
CALLER='"attributes":[{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}},{"key":"hud.parent.service.name","value":{"stringValue":"caller"}},
  {"key":"hud.parent.flow.name","value":{"stringValue":"kafka|t|g"}},{"key":"hud.root.service.name","value":{"stringValue":"edge"}},{"key":"hud.root.flow.name","value":{"stringValue":"http|/y|post"}}]'
ISSUE='"attributes":[{"key":"code.flow.name","value":{"stringValue":"http|/x|get"}},{"key":"issue.fingerprint","value":{"stringValue":"fp"}},
  {"key":"hud.issue.caught","value":{"boolValue":false}},{"key":"hud.issue.user_error","value":{"stringValue":"card declined"}}]'
for r in 1 2; do
  start=$(((BASE + r) * 1000000000)) end=$(((BASE + r + 1) * 1000000000))
  curl -sf -X POST localhost:14319/v1/metrics -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":$RESOURCE,"scopeMetrics":[{"metrics":[
  {"name":"hud.flow.messages","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.flow.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[{$FLOW,"startTimeUnixNano":"$start","timeUnixNano":"$end",
    "count":"5","sum":0.55,"scale":2,"zeroCount":"0","positive":{"offset":-14,"bucketCounts":["1","2","2"]}}]}},
  {"name":"process.uptime","unit":"s","gauge":{"dataPoints":[{"asDouble":$((40 + r)),"timeUnixNano":"$end"}]}},
  {"name":"hud.flow.calling_flows","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$CALLER,"asInt":"4","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"hud.flow.issues","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$ISSUE,"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.function.calls","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$FUNCTION,"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.function.call.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[{$FUNCTION,"startTimeUnixNano":"$start","timeUnixNano":"$end",
    "count":"5","sum":0.55,"scale":2,"zeroCount":"0","positive":{"offset":-14,"bucketCounts":["1","2","2"]}}]}}]}]}]}
EOF
done
curl -sf -X POST localhost:14319/v1/logs -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceLogs":[{"resource":$RESOURCE,"scopeLogs":[{"logRecords":[
  {"timeUnixNano":"$((BASE * 1000000000))","eventName":"hud.forensic","severityText":"ERROR","body":{"stringValue":"{}"}}]}]}]}
EOF

# As hud_backend, the read-only user Hud's backend gets. Bucket k of the transform/classic grid is buckets[k + 1]:
# le=0.0884 is [14], le=0.125 is [15], le=0.177 is [16].
sql() { curl -s -u hud_backend:Backend-pass-1234 localhost:18123 --data-binary "$1"; }
F="$DB.flow_1m WHERE service = 'smoke' AND env = 'smoke-env'"
poll sql smoke-clickstack \
  "SELECT sum(messages) FROM $F=2" \
  "SELECT sum(duration_count) FROM $F AND flow = 'http|/x|get' AND status_code = '500' AND deployment = 'd1'=10" \
  "SELECT arrayCumSum(sumForEachMerge(buckets))[14] FROM $F=0" \
  "SELECT arrayCumSum(sumForEachMerge(buckets))[15] FROM $F=6" \
  "SELECT arrayCumSum(sumForEachMerge(buckets))[16] FROM $F=10" \
  "SELECT sum(duration_count) FROM $DB.flow_hourly WHERE service = 'smoke'=10" \
  "SELECT sum(runs) FROM $DB.session_flow_1m WHERE instance = 'pod-a'=10" \
  "SELECT sum(errors) FROM $DB.session_flow_1m WHERE instance = 'pod-a'=10" \
  "SELECT sum(calls) FROM $DB.function_5m WHERE function = 'f' AND deployment = 'd1'=2" \
  "SELECT sum(duration_count) FROM $DB.function_5m WHERE function = 'f'=10" \
  "SELECT arrayCumSum(sumForEachMerge(buckets))[15] FROM $DB.function_5m WHERE function = 'f'=6" \
  "SELECT sum(calls) FROM $DB.function_caller_hourly WHERE function = 'f' AND flow = 'http|/x|get'=2" \
  "SELECT max(uptime) FROM $DB.session_health_1m WHERE instance = 'pod-a' AND env = 'smoke-env' AND last_seen > 0=42" \
  "SELECT sum(runs) FROM $DB.calling_flow_1m WHERE flow = 'http|/x|get' AND parent_service = 'caller' AND parent_flow = 'kafka|t|g' AND root_service = 'edge' AND root_flow = 'http|/y|post'=8" \
  "SELECT sum(runs) FROM $DB.calling_flow_hourly WHERE parent_service = 'caller'=8" \
  "SELECT sum(issues) FROM $DB.issue_hourly WHERE fingerprint = 'fp' AND caught = 'false' AND user_error = 'card declined'=2" \
  "SELECT sum(issues) FROM $DB.session_flow_1m WHERE instance = 'pod-a'=2" \
  "SELECT groupArray(flow || '/' || function) FROM (SELECT DISTINCT flow, function FROM $DB.labels WHERE service = 'smoke' ORDER BY ALL)=['/','http|/x|get/','http|/x|get/f']"
poll sql smoke-clickstack "SELECT count() FROM $DB.otel_logs WHERE EventName = 'hud.forensic' AND ServiceName = 'smoke'=1"

echo "--- TLS: hud-migrate and the collector on the https endpoint form Cloud uses (https://host:8443, trailing slash ok for hud-migrate)"
TLS=(-e CLICKHOUSE_TLS_INSECURE_SKIP_VERIFY=true -e HUD_CLICKHOUSE_DATABASE=$DB)
docker run --rm --network $NET -e CLICKHOUSE_ENDPOINT=https://smoke-clickhouse:8443/ -e CLICKHOUSE_USER=hud_migrator \
  -e CLICKHOUSE_PASSWORD=Migrator-pass-1234 "${TLS[@]}" --entrypoint /hud-migrate "$IMAGE" up
docker run -d --name smoke-clickstack-tls --network $NET -p 14320:4318 -v "$DIR:/cfg:ro" "${TLS[@]}" \
  -e CLICKHOUSE_ENDPOINT=https://smoke-clickhouse:8443 -e CLICKHOUSE_USER=hud_collector -e CLICKHOUSE_PASSWORD=Collector-pass-1234 \
  "$IMAGE" --config /cfg/clickstack.yaml >/dev/null
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
poll sql smoke-clickstack-tls "SELECT sum(messages) FROM $DB.flow_1m WHERE service = 'smoke-tls'=3"
poll sql smoke-clickstack-tls "SELECT count() FROM $DB.otel_logs WHERE ServiceName = 'smoke-tls'=1"
