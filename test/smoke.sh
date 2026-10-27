#!/usr/bin/env bash
# Five fake pods (three on deployment v1, two on v2) send deltas concurrently. Function metrics must merge
# into one Prometheus series per deployment holding its sum; flow and process metrics must stay one series per pod.
set -euo pipefail

IMAGE=${IMAGE:-hud-otelcol:dev}
PROM_IMAGE=${PROM_IMAGE:-prom/prometheus:v3.7.3}
NET=hud-otelcol-smoke
DIR=$(cd "$(dirname "$0")" && pwd)

cleanup() { docker rm -f smoke-collector smoke-prometheus >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "--- components"
components=$(docker run --rm "$IMAGE" components)
for c in otlp batch filter transform delta_to_cumulative interval prometheus_remote_write sigv4auth; do
  grep -q "name: $c\$" <<<"$components" || { echo "missing component: $c"; exit 1; }
done

echo "--- validate AMP config"
docker run --rm -v "$DIR:/cfg:ro" -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
  "$IMAGE" validate --config /cfg/amp.yaml

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
  'sum(code_function_calls_total{deployment_id="v1",telemetry_sdk_version="1.11.1"})=30'
  'sum(code_function_calls_total{deployment_id="v2",telemetry_sdk_version="1.11.1"})=20'
  'count(code_function_calls_total{instance=~"pod-.*"}) or vector(0)=0'
  'sum(hud_flow_messages_total)=50'
  'count(hud_flow_messages_total{instance=~"pod-.*"})=5'
  'count(process_memory_usage{instance=~"pod-.*"})=5'
)

for _ in $(seq 30); do
  failed=()
  for c in "${checks[@]}"; do
    got=$(query "${c%=*}"); [ "$got" = "${c##*=}" ] || failed+=("${c%=*}: got ${got:-none}, want ${c##*=}")
  done
  [ ${#failed[@]} = 0 ] && { echo "PASS: ${#checks[@]} checks"; exit 0; }
  sleep 1
done
printf 'FAIL: %s\n' "${failed[@]}"
docker logs smoke-collector | tail -30
exit 1
