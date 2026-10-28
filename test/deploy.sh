#!/usr/bin/env bash
# Validates the collector configs that hud-o11y-resources' ECS template and Helm values render (both modes, with and
# without logs) against the built image. The fixtures in test/configs/ are copies of those rendered configs; refresh
# them when the deploy configs change there.
set -euo pipefail

IMAGE=${IMAGE:-hud-otelcol:dev}
CFG=$(cd "$(dirname "$0")/configs" && pwd)

echo "--- validate"
for f in "$CFG"/*.yaml; do
  docker run --rm -v "$CFG:/cfg:ro" -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
    -e AWS_REGION=us-east-1 -e MY_POD_IP=0.0.0.0 -e AMP_REMOTE_WRITE_URL=https://example.com/api/v1/remote_write \
    "$IMAGE" validate --config "/cfg/$(basename "$f")"
  echo "ok: $(basename "$f")"
done
has() { grep -q "$1" "$CFG/$2.yaml" || { echo "FAIL: $2 lacks $1"; exit 1; }; }
lacks() { ! grep -q "$1" "$CFG/$2.yaml" || { echo "FAIL: $2 has $1"; exit 1; }; }
# transform/restamp appears on two lines when a pipeline uses it (definition + pipeline), one when only defined
uses_restamp() { [ "$(grep -c 'transform/restamp' "$CFG/$1.yaml")" -ge 2 ]; }
for f in ecs-merge ecs-merge-logs helm-merge; do
  has 'metrics/per_pod' $f; has 'keep_keys' $f; uses_restamp $f || { echo "FAIL: $f doesn't merge"; exit 1; }
done
for f in ecs-convert ecs-convert-logs helm-convert; do ! uses_restamp $f || { echo "FAIL: $f merges"; exit 1; }; done
for f in ecs-merge-logs ecs-convert-logs; do has 'exporters: \[otlp_http/osis\]' $f; done
for f in ecs-merge ecs-convert helm-merge helm-convert; do lacks 'osis' $f; done
echo PASS
