#!/usr/bin/env bash
# Pins every module in manifest.yaml to the version used by the upstream
# otelcol-contrib release (latest by default, or the tag given as $1).
set -euo pipefail
cd "$(dirname "$0")/.."

tag=${1:-$(gh api repos/open-telemetry/opentelemetry-collector-releases/releases/latest -q .tag_name)}
upstream=$(curl -sfL "https://raw.githubusercontent.com/open-telemetry/opentelemetry-collector-releases/$tag/distributions/otelcol-contrib/manifest.yaml")

tmp=$(mktemp)
awk -v ver="${tag#v}" '
  NR == FNR { if ($2 == "gomod:") v[$3] = $4; next }
  $1 == "version:" && !done { sub(/version: .*/, "version: " ver); done = 1 }
  $2 == "gomod:" {
    if (!($3 in v)) { print "not in upstream otelcol-contrib: " $3 > "/dev/stderr"; exit 1 }
    sub($4 "$", v[$3])
  }
  { print }
' <(echo "$upstream") manifest.yaml >"$tmp"
mv "$tmp" manifest.yaml
sed -i.bak -E "s/(hud-otel-collector:)[0-9][^ \"]*/\1${tag#v}/; s/^(  tag: \")[^\"]*/\1${tag#v}/" \
  deploy/aws/ecs-fargate.yaml deploy/helm/values.yaml && rm deploy/aws/*.bak deploy/helm/*.bak
echo "$tag"
