#!/usr/bin/env bash
# Lints the CloudFormation templates, checks unified-ecs.yaml matches scripts/unify.py, checks the Observability Stack
# pipeline and setup code, and validates every collector config they and the Helm values render (both modes) against
# the built image.
set -euo pipefail

IMAGE=${IMAGE:-hud-otelcol:dev}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
chmod 755 "$OUT" # the collector image runs as non-root
trap 'rm -rf "$OUT"' EXIT

echo "--- cfn-lint"
docker run --rm -v "$ROOT/deploy:/d:ro" python:3.13-slim sh -c \
  'pip install -q cfn-lint 2>/dev/null && cfn-lint /d/aws/*.yaml'

echo "--- unified-ecs.yaml is up to date"
docker run --rm -v "$ROOT:/r:ro" python:3.13-slim sh -c 'pip install -q pyyaml 2>/dev/null && python /r/scripts/unify.py --check'

echo "--- observability.yaml pipeline body and setup code"
docker run --rm -v "$ROOT/deploy:/d:ro" python:3.13-slim sh -c 'pip install -q pyyaml 2>/dev/null && python - <<EOF
import yaml
yaml.SafeLoader.add_multi_constructor("!", lambda l, s, n: l.construct_sequence(n) if isinstance(n, yaml.SequenceNode) else l.construct_scalar(n) if isinstance(n, yaml.ScalarNode) else l.construct_mapping(n))
r = yaml.safe_load(open("/d/aws/observability.yaml"))["Resources"]
body = yaml.safe_load(r["Pipeline"]["Properties"]["PipelineConfigurationBody"])
assert {"otlp-pipeline", "otel-logs-pipeline", "service-map-pipeline", "otel-metrics-pipeline"} <= body.keys(), body.keys()
compile(r["SetupFunction"]["Properties"]["Code"]["ZipFile"], "index.py", "exec")
print("ok")
EOF'

echo "--- render ECS configs"
docker run --rm -v "$ROOT/deploy:/d:ro" -v "$OUT:/out" python:3.13-slim sh -c 'pip install -q pyyaml 2>/dev/null && python - <<EOF
import yaml
yaml.SafeLoader.add_multi_constructor("!", lambda l, s, n: l.construct_sequence(n) if isinstance(n, yaml.SequenceNode) else l.construct_scalar(n) if isinstance(n, yaml.ScalarNode) else l.construct_mapping(n))
t = yaml.safe_load(open("/d/aws/ecs-fargate.yaml"))
env = t["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"][0]["Environment"]
tmpl, vars = next(e["Value"] for e in env if e["Name"] == "HUD_OTELCOL_CONFIG")
params = {"AWS::Region": "us-east-1", "ExportInterval": "60s", "OsisLogsUrl": "https://p.us-east-1.osis.amazonaws.com/p/v1/logs"}
def sub(s):
    for k, v in params.items(): s = s.replace("\${" + k + "}", v)
    return s
for name, on in (("merge", {"Merge"}), ("convert", set()), ("merge-logs", {"Merge", "Logs"}), ("convert-logs", {"Logs"})):
    s = tmpl
    for k, (cond, yes, no) in vars.items(): s = s.replace("\${" + k + "}", sub(yes if cond in on else no))
    open(f"/out/ecs-{name}.yaml", "w").write(sub(s).replace("\${!", "\${"))
EOF'

echo "--- render Helm configs"
for mode in merge convert; do
  extra=(); [ $mode = convert ] && extra=(-f /d/helm/values-convert.yaml)
  docker run --rm -v "$ROOT/deploy:/d:ro" alpine/helm:3.19.0 template hud opentelemetry-collector \
    --repo https://open-telemetry.github.io/opentelemetry-helm-charts --version 0.177.0 \
    -f /d/helm/values.yaml ${extra[@]+"${extra[@]}"} --show-only templates/configmap.yaml \
    | docker run --rm -i mikefarah/yq:4 '.data.relay' > "$OUT/helm-$mode.yaml"
done

echo "--- validate"
for f in "$OUT"/*.yaml; do
  docker run --rm -v "$OUT:/cfg:ro" -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
    -e AWS_REGION=us-east-1 -e MY_POD_IP=0.0.0.0 -e AMP_REMOTE_WRITE_URL=https://example.com/api/v1/remote_write \
    "$IMAGE" validate --config "/cfg/$(basename "$f")"
  echo "ok: $(basename "$f")"
done
grep -q 'transform/restamp' "$OUT/ecs-merge.yaml" "$OUT/helm-merge.yaml"
grep -q 'exporters: \[otlp_http/osis\]' "$OUT/ecs-merge-logs.yaml" "$OUT/ecs-convert-logs.yaml"
! grep -q 'osis' "$OUT/ecs-merge.yaml"
! grep -q 'processors: \[memory_limiter, batch, transform' "$OUT/helm-convert.yaml"
echo PASS
