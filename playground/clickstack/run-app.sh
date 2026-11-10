#!/usr/bin/env bash
# Runs node-sdk's e2e fake Hud backend and the sample app on the host, exporting OTLP to the playground collector.
# Usage: ./run-app.sh <node-sdk checkout, with hud/ built>
set -euo pipefail
SDK=$(cd "${1:?usage: $0 <node-sdk checkout>}" && pwd)
cd "$(dirname "$0")/app"

[ -d node_modules ] || npm install --no-save --no-package-lock express@4 "$SDK/hud" \
  fastify axios @msgpack/msgpack @jridgewell/sourcemap-codec @grpc/proto-loader buffer-crc32 expect@29 ts-node typescript@5
export NODE_PATH=$PWD/node_modules

rm -f /tmp/fakeServerUrl.txt
TS_NODE_TRANSPILE_ONLY=true TS_NODE_SKIP_PROJECT=true TS_NODE_COMPILER_OPTIONS='{"module":"commonjs","esModuleInterop":true}' node -r ts-node/register "$SDK/e2e/startFakeServer.ts" >fake-backend.log 2>&1 &
trap 'kill %1' EXIT
for _ in $(seq 30); do [ -s /tmp/fakeServerUrl.txt ] && break; sleep 1; done
[ -s /tmp/fakeServerUrl.txt ] || { cat fake-backend.log; exit 1; }

HUD_ENABLE=true HUD_KEY=playground_0000000000000000000000000000000000000000000000000000000000000000 \
  HUD_HOST=$(cat /tmp/fakeServerUrl.txt) HUD_SERVICE=clickstack-playground \
  HUD_EXPORTER=otlp HUD_OTLP_ENDPOINT=${OTLP_ENDPOINT:-http://localhost:4318} \
  HUD_AGGREGATION_INTERVAL=10 HUD_ENABLE_INVESTIGATION=true \
  node -r hud-sdk/init app.js
