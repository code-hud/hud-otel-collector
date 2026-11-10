# ClickStack playground

ClickHouse with the `TimeSeries` engine and the Prometheus API, the customer setup script (`setup.sql`), `hud-migrate`
as an init container, the collector on `test/clickstack.yaml`, HyperDX, and the node SDK's sample app against its
fake Hud backend.

## Run

Needs Docker and a node-sdk checkout with `hud/` built (`cd hud && npm install && npm run build`).

```sh
make image                                    # from the repo root: hud-otelcol:dev with /hud-migrate
cd playground/clickstack
docker compose up -d                          # hud-migrate runs, exits 0, then the collector starts
./run-app.sh ~/src/node-sdk                   # HUD_ENABLE=true, HUD_EXPORTER=otlp, HUD_AGGREGATION_INTERVAL=10,
                                              # HUD_ENABLE_INVESTIGATION=true; Ctrl+C stops it
```

The collector exports every 10 s (`EXPORT_INTERVAL`), so series show up within a minute; investigations appear as
the SDK sends them (first error, baselines).

## Look

PromQL, as `hud_backend` (the read-only user Hud's backend gets):

```sh
curl -s -u hud_backend:Backend-pass-1234 -G localhost:8123/prometheus/api/v1/query --data-urlencode table=hud_otel.metrics \
  --data-urlencode 'query=histogram_quantile(0.9, sum by (code_flow_name, le) (rate(code_flow_duration_seconds_bucket[2m])))'
```

Logs:

```sh
curl -s -u hud_backend:Backend-pass-1234 localhost:8123 \
  --data-binary "SELECT Timestamp, EventName, SeverityText, LogAttributes['code.flow.name'] FROM hud_otel.otel_logs ORDER BY Timestamp DESC LIMIT 10"
```

HyperDX: open http://localhost:8080 and create an account (the first one provisions the `Hud ClickHouse` connection,
as `hud_backend`, and the sources `Hud investigations` (log, `hud_otel.otel_logs`) and `Hud metrics` (PromQL,
`hud_otel.metrics`)). Search the investigations; for metrics add a dashboard tile on the `Hud metrics` source with a PromQL
query like the one above.

With `HUD_SCHEMA_MANAGED=false docker compose up -d`, the init container exits without touching ClickHouse.

`docker compose down -v` removes everything, including ClickHouse's and Mongo's anonymous volumes.
