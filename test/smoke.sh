#!/usr/bin/env bash
# Five fake pods (three on deployment v1, two on v2) send deltas concurrently. Function metrics must merge
# into one Prometheus series per deployment holding its sum; flow and process metrics must stay one series per pod.
# Then the ClickStack path: hud-migrate creates the schema, and deltas, an exponential histogram and a log
# sent through test/clickstack.yaml must come out of PromQL and otel_logs exactly.
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
echo "--- ClickStack: ClickHouse with the playground's TimeSeries config and setup script, database $DB"
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
  -v "$PLAYGROUND/clickhouse/prometheus.xml:/etc/clickhouse-server/config.d/prometheus.xml:ro" \
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
[ "$tables" = "['metrics','otel_logs']" ] || { echo "FAIL: $DB has $tables after up, want metrics and otel_logs only"; exit 1; }
for q in "DROP TABLE $DB.otel_logs" "ALTER TABLE $DB.otel_logs ADD INDEX smoke_idx Body TYPE bloom_filter" \
  "DROP DATABASE $DB" "CREATE DATABASE hud_otel"; do
  curl -s -u hud_migrator:Migrator-pass-1234 localhost:18123 --data-binary "$q" | grep -q ACCESS_DENIED || { echo "FAIL: hud_migrator may run: $q"; exit 1; }
done
docker run --rm --network $NET "${MIGRATOR[@]}" -v "$DIR/../hud-migrate:/src" -w /src \
  -v hud-otelcol-gomod:/go/pkg/mod -v hud-otelcol-gocache:/root/.cache/go-build "$GO_IMAGE" go test -count=1 ./...

echo "--- ClickStack collector: two deltas of a counter and of a scale-2 exponential histogram, per pod and per function (merged), one log"
docker run -d --name smoke-clickstack --network $NET -p 14319:4318 -v "$DIR:/cfg:ro" -e EXPORT_INTERVAL=2s \
  -e CLICKHOUSE_ENDPOINT=http://smoke-clickhouse:8123 -e CLICKHOUSE_USER=hud_collector -e CLICKHOUSE_PASSWORD=Collector-pass-1234 \
  -e HUD_CLICKHOUSE_DATABASE=$DB "$IMAGE" --config /cfg/clickstack.yaml >/dev/null
for _ in $(seq 30); do curl -s -o /dev/null localhost:14319 && break; sleep 1; done

# Buckets (2^(k/4), 2^((k+1)/4)] s for k = -14..-12 hold 1, 2 and 2 per delta, so per delta the classic bucket
# le=0.0884 (just above 2^(-14/4)) holds 0, le=0.125 holds 3 and le=0.177 holds 5
RESOURCE='{"attributes":[{"key":"service.name","value":{"stringValue":"smoke"}},{"key":"service.instance.id","value":{"stringValue":"pod-a"}},
  {"key":"deployment.environment.name","value":{"stringValue":"smoke-env"}},{"key":"deployment.id","value":{"stringValue":"d1"}}]}'
FUNCTION='"attributes":[{"key":"code.function.name","value":{"stringValue":"f"}}]'
for r in 1 2; do
  start=$(((BASE + r) * 1000000000)) end=$(((BASE + r + 1) * 1000000000))
  curl -sf -X POST localhost:14319/v1/metrics -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":$RESOURCE,"scopeMetrics":[{"metrics":[
  {"name":"hud.flow.messages","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.flow.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[{"startTimeUnixNano":"$start","timeUnixNano":"$end",
    "count":"5","sum":0.55,"scale":2,"zeroCount":"0","positive":{"offset":-14,"bucketCounts":["1","2","2"]}}]}},
  {"name":"code.function.calls","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{$FUNCTION,"asInt":"1","startTimeUnixNano":"$start","timeUnixNano":"$end"}]}},
  {"name":"code.function.call.duration","unit":"s","exponentialHistogram":{"aggregationTemporality":1,"dataPoints":[{$FUNCTION,"startTimeUnixNano":"$start","timeUnixNano":"$end",
    "count":"5","sum":0.55,"scale":2,"zeroCount":"0","positive":{"offset":-14,"bucketCounts":["1","2","2"]}}]}}]}]}]}
EOF
done
curl -sf -X POST localhost:14319/v1/logs -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{"resourceLogs":[{"resource":$RESOURCE,"scopeLogs":[{"logRecords":[
  {"timeUnixNano":"$((BASE * 1000000000))","eventName":"hud.forensic","severityText":"ERROR","body":{"stringValue":"{}"}}]}]}]}
EOF

# As hud_backend, the read-only user Hud's backend gets
promql() {
  curl -s -u hud_backend:Backend-pass-1234 -G localhost:18123/prometheus/api/v1/query --data-urlencode table=$DB.metrics \
    --data-urlencode "query=$1" | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'
}
sql() { curl -s -u hud_backend:Backend-pass-1234 localhost:18123 --data-binary "$1"; }
# Every resource attribute is a label, as in Hud's AMP data. Per pod: instance and service_instance_id are the pod's.
# Per function: merged, both are the collector's hostname.
COLLECTOR_HOST=$(docker inspect -f '{{.Config.Hostname}}' smoke-clickstack)
poll promql smoke-clickstack \
  'sum(hud_flow_messages_total)=2' \
  'sum(hud_flow_messages_total{job="smoke",service_name="smoke",instance="pod-a",service_instance_id="pod-a",deployment_environment_name="smoke-env",deployment_id="d1"})=2' \
  'sum(code_function_calls_total{job="smoke",service_name="smoke",deployment_environment_name="smoke-env",deployment_id="d1",code_function_name="f"})=2' \
  "count(code_function_calls_total{instance=\"$COLLECTOR_HOST\",service_instance_id=\"$COLLECTOR_HOST\"})=1" \
  'count(target_info{job="smoke",instance="pod-a",deployment_id="d1",service_name="",service_instance_id=""})=1' \
  'sum(code_function_call_duration_seconds_count{deployment_environment_name="smoke-env"})=10' \
  'sum(code_function_call_duration_seconds_bucket{le="0.125000125"})=6' \
  'sum(code_flow_duration_seconds_count)=10' \
  'sum(code_flow_duration_seconds_bucket{le="0.08838843603666609"})=0' \
  'sum(code_flow_duration_seconds_bucket{le="0.125000125"})=6' \
  'sum(code_flow_duration_seconds_bucket{le="0.17677687207333218"})=10' \
  'sum(code_flow_duration_seconds_bucket{le="+Inf"})=10' \
  'count((histogram_quantile(0.5, sum by (le) (code_flow_duration_seconds_bucket)) > 0.11) < 0.125)=1'
poll sql smoke-clickstack "SELECT count() FROM $DB.otel_logs WHERE EventName = 'hud.forensic' AND ServiceName = 'smoke'=1"

echo "--- TLS: hud-migrate and the collector on the https endpoint form Cloud uses (https://host:8443, trailing slash ok for hud-migrate)"
TLS=(-e CLICKHOUSE_TLS_INSECURE_SKIP_VERIFY=true -e HUD_CLICKHOUSE_DATABASE=$DB)
docker run --rm --network $NET -e CLICKHOUSE_ENDPOINT=https://smoke-clickhouse:8443/ -e CLICKHOUSE_USER=hud_migrator \
  -e CLICKHOUSE_PASSWORD=Migrator-pass-1234 "${TLS[@]}" --entrypoint /hud-migrate "$IMAGE" up
docker run -d --name smoke-clickstack-tls --network $NET -p 14320:4318 -v "$DIR:/cfg:ro" -e EXPORT_INTERVAL=2s "${TLS[@]}" \
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
poll promql smoke-clickstack-tls 'sum(hud_flow_messages_total{job="smoke-tls"})=3'
poll sql smoke-clickstack-tls "SELECT count() FROM $DB.otel_logs WHERE ServiceName = 'smoke-tls'=1"
