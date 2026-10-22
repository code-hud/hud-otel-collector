#!/usr/bin/env bash
# Two fake pods send delta counters; the collector must merge them into one
# Prometheus series whose value is the sum of all deltas.
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
for c in otlp transform delta_to_cumulative interval prometheus_remote_write sigv4auth; do
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

send() { # pod value
  local now; now=$(($(date +%s) * 1000000000))
  curl -sf -X POST localhost:14318/v1/metrics -H 'Content-Type: application/json' -d @- <<EOF >/dev/null
{"resourceMetrics":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"smoke"}},
  {"key":"service.instance.id","value":{"stringValue":"$1"}}]},
 "scopeMetrics":[{"metrics":[{"name":"hud.smoke","sum":{
  "aggregationTemporality":1,"isMonotonic":true,
  "dataPoints":[{"asInt":"$2","startTimeUnixNano":"$now","timeUnixNano":"$now"}]}}]}]}]}
EOF
}

echo "--- send 2 pods x 3 deltas of 5"
for _ in 1 2 3; do send pod-a 5; send pod-b 5; sleep 0.5; done

query() { curl -s localhost:19090/api/v1/query --data-urlencode "query=$1" | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'; }

for _ in $(seq 30); do
  total=$(query 'sum(hud_smoke_total)'); series=$(query 'count(hud_smoke_total)')
  [ "$total" = "30" ] && [ "$series" = "1" ] && { echo "PASS: total=$total series=$series"; exit 0; }
  sleep 1
done
echo "FAIL: total=${total:-none} series=${series:-none} (want 30 and 1)"
docker logs smoke-collector | tail -30
exit 1
