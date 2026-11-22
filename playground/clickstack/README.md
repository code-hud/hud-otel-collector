# ClickStack playground

ClickHouse with the customer setup script (`setup.sql`, run by `setup.sh`), `hud-migrate` as an init container, the
collector on `test/clickstack.yaml`, HyperDX, and the node SDK's sample app against its fake Hud backend.

## Run

Needs Docker and a node-sdk checkout with `hud/` built (`cd hud && npm install && npm run build`).

```sh
make image                                    # from the repo root: hud-otelcol:dev with /hud-migrate
cd playground/clickstack
docker compose up -d                          # hud-migrate runs, exits 0, then the collector starts
./run-app.sh ~/src/node-sdk                   # HUD_ENABLE=true, HUD_EXPORTER=otlp, HUD_AGGREGATION_INTERVAL=10,
                                              # HUD_ENABLE_INVESTIGATION=true; Ctrl+C stops it
```

The SDK exports every minute and the collector inserts every 5 s, so the tables fill within a minute or two;
investigations appear as the SDK sends them (first error, baselines).

## Look

Metrics, as `hud_backend` (the read-only user Hud's backend gets): runs, P90 and errors per flow over the last hour,
from the 1-minute flow table:

```sh
curl -s -u hud_backend:Backend-pass-1234 localhost:8123 --data-binary "
  SELECT flow, sum(duration_count) AS runs, sumIf(duration_count, startsWith(status_code, '5')) AS errors_5xx,
    round(1e3 * hud_duration_quantile(0.9, sumMap(buckets)), 1) AS p90_ms
  FROM hud_otel.flow WHERE t >= now() - INTERVAL 1 HOUR GROUP BY flow FORMAT PrettyCompact"
```

Logs:

```sh
curl -s -u hud_backend:Backend-pass-1234 localhost:8123 \
  --data-binary "SELECT Timestamp, EventName, SeverityText, LogAttributes['code.flow.name'] FROM hud_otel.otel_logs ORDER BY Timestamp DESC LIMIT 10"
```

HyperDX: open http://localhost:8080 and create an account (the first one provisions the `Hud ClickHouse` connection,
as `hud_backend`, and the sources `Hud investigations` (log, `hud_otel.otel_logs`) and `Hud labels` (log,
`hud_otel.labels`, what the dashboards' selectors read)). Search the investigations; for metrics import the Hud
dashboards ([hud-clickstack-resources](https://github.com/code-hud/hud-clickstack-resources)) with a personal API key
from Team Settings, or add a SQL tile with a query like the one above.

The database is `hud_otel` unless you set `HUD_CLICKHOUSE_DATABASE` (a plain identifier) for `docker compose up`;
ClickHouse's setup, `hud-migrate`, the collector and HyperDX's sources all follow it. Use the same name in the queries
above. Changing it needs `docker compose down -v` first, since the setup runs on ClickHouse's first start only.

With `HUD_SCHEMA_MANAGED=false docker compose up -d`, the init container exits without touching ClickHouse.

`docker compose down -v` removes everything, including ClickHouse's and Mongo's anonymous volumes.
