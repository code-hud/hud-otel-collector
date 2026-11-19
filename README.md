# hud-otel-collector

A minimal OpenTelemetry Collector distribution for Hud's OTLP data plane, built with the
[OpenTelemetry Collector Builder](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder) (OCB).
It is not a fork: `manifest.yaml` lists upstream modules at pinned versions, and OCB compiles them.

| Kind | Components |
| --- | --- |
| Receivers | `otlp` |
| Processors | `transform`, `deltatocumulative`, `interval`, `memory_limiter`, `batch` |
| Exporters | `prometheusremotewrite`, `clickhouse`, `otlphttp`, `debug` |
| Extensions | `sigv4auth`, `basicauth`, `health_check` |

Every config written for this distribution also runs on `otel/opentelemetry-collector-contrib`, which is the fallback.

Owner: [@ilansh](https://github.com/ilansh). The owner reviews bump PRs and handles CVE reports.

## Artifacts

- Image: `ghcr.io/code-hud/hud-otel-collector:<version>` (multi-arch: `linux/amd64`, `linux/arm64`), plus `:latest`.
  It holds `/hud-otelcol` (the entrypoint) and `/hud-migrate` (see [ClickStack](#clickstack)).
- Binaries: `hud-otelcol` and `hud-migrate` for linux, darwin and windows, amd64 and arm64, attached to each
  [GitHub release](../../releases).

Versions follow the upstream `opentelemetry-collector-releases` version (`0.163.2`). A rebuild of the
same upstream version (for example a Go security fix) is tagged `v0.163.2-hud.1`.

## Verifying artifacts

Images and `checksums.txt` are signed keyless with [cosign](https://github.com/sigstore/cosign) from the release
workflow. Each archive has an SPDX SBOM (`*.sbom.json`) on the release.

```sh
ID='https://github.com/code-hud/hud-otel-collector/.github/workflows/release.yaml@.*'
ISSUER=https://token.actions.githubusercontent.com

# Image
cosign verify ghcr.io/code-hud/hud-otel-collector:<version> \
  --certificate-identity-regexp "$ID" --certificate-oidc-issuer "$ISSUER"

# Binaries: verify the checksums file, then the archive against it
cosign verify-blob checksums.txt --bundle checksums.txt.sigstore.json \
  --certificate-identity-regexp "$ID" --certificate-oidc-issuer "$ISSUER"
sha256sum --ignore-missing -c checksums.txt
```

## Deploying to your AWS account

The CloudFormation templates and Helm values live in
[hud-o11y-resources](https://github.com/code-hud/hud-o11y-resources/blob/main/deploy/README.md).

## Local development

Only Docker is required; Go runs in a container.

```sh
make build   # OCB generates and compiles _build/hud-otelcol (linux, Docker host arch)
make image   # hud-otelcol:dev
make smoke   # five fake pods send deltas concurrently; expects one merged Prometheus series with the summed total,
             # then runs hud-migrate and test/clickstack.yaml against ClickHouse and checks the SQL tables and otel_logs
             # (database hud_otel_smoke)
```

## ClickStack

`test/clickstack.yaml` sends the SDK's metrics through the `clickhouse` exporter into the `ingest_*` tables of
`hud_otel`, and logs into `hud_otel.otel_logs`. The `ingest_*` tables are `Null` tables: materialized views sum each insert
into the tables below (`hud-migrate/schema/0002_sql.sql`) and the raw rows are not kept. The collector keeps no state (no
pod merging, no `delta_to_cumulative`), so it scales out freely: it converts the SDK's exponential histograms to classic
buckets and batches the inserts.

| Tables | Grain | One row per (and what it sums) |
| --- | --- | --- |
| `flow`, `flow_hourly` | 1 minute, hour | flow, status code, method, route, end reason, queue, deployment: runs, duration, queue latency (e2e), messages |
| `session_health`, `session_health_hourly` | 1 minute, hour | SDK session (`service.instance.id`) and its pod: last report, uptime, CPU, memory and its limit, event loop utilization |
| `session_flow`, `session_flow_hourly` | 1 minute, hour | session and flow: runs, 5xx runs, issues |
| `issue`, `issue_hourly` | 1 minute, hour | flow, issue fingerprint and user error: issues |
| `calling_flow`, `calling_flow_hourly` | 1 minute, hour | flow, status code, and the flow that called it (parent) and started it (root): runs |
| `function`, `function_hourly` | 5 minutes, hour | function, file, deployment: calls, errors, duration |
| `function_metrics`, `function_metrics_hourly` | 5 minutes, hour | function, caller function (name and file), flow, content hash, error type, deployment: calls, errors, duration |
| `labels` | | every environment, service, flow and function seen (the dashboards' selectors) |

Each fine table rolls up into its hourly table. Fine tables are plain `MergeTree` of plain values (every insert's rows
kept as written, one per key, pod and view): sum them with `sum`, `sumForEach(buckets)` and
`groupUniqArrayArrayMap(1000)(attributes)`. They keep `HUD_METRICS_FINE_TTL_DAYS` days (default 30). Hourly tables are
`AggregatingMergeTree` of aggregate states and keep everything: read them with `-Merge`, or `finalizeAggregation()` a
column to union it with the fine table's. The flow and function tables also keep every other attribute the SDK sends,
so a new one needs no migration (in `flow` and `function` at the export interval, 5 minutes by default). `attributes` holds up to
1000 values per attribute and `attribute_counts` the runs (calls) per `attribute=value`, keyed by
`sipHash64('attribute=value') % 100000`; `hud_attribute_count(attribute, value, counts)` (created by the admin's
`setup.sql`, since functions are server-wide) reads one. A row holds at most 100000 counts; values that share a bucket
add up. Session and host attributes are left out, and so are a function's caller, content hash, short name and its
flow's type, route and methods: `function_metrics_*` has them as columns (the flow's in its name). Every listed value
with its runs:

```sql
SELECT k AS attribute, v AS value, hud_attribute_count(k, v, counts) AS runs
FROM (
  SELECT groupUniqArrayArrayMapMerge(1000)(attributes) AS vals, sumMap(attribute_counts) AS counts
  FROM hud_otel.function_hourly WHERE service = 'checkout' AND hour >= now() - INTERVAL 1 DAY
)
ARRAY JOIN mapKeys(vals) AS k, mapValues(vals) AS vs
ARRAY JOIN vs AS v
ORDER BY attribute, runs DESC
```

Every row has the environment (`deployment.environment.name`) and the service (`service.name`).
Durations are counts per bucket of the `transform/classic` grid: `buckets[k]` counts durations up to
`duration_bounds[k]` seconds and `buckets[34]` the rest, so any grain answers percentiles. Only deltas are summed (the
SDK sends nothing else), except the process gauges and limits. A delta covers the SDK's export interval
(`aggregationInterval`: 5 minutes by default, set per account) and is spread over the fine buckets it overlaps by
share, so a 1-minute chart shows the SDK's own resolution instead of one minute holding the whole interval. Counts are
`Float64` for that; they are whole again over whole intervals.
The `metrics` `TimeSeries` table of `0001_init.sql` is
still created but nothing writes to it. `playground/clickstack/` runs it end to end with HyperDX and the node SDK; the
dashboards are in [hud-clickstack-resources](https://github.com/code-hud/hud-clickstack-resources).

The collector's `CLICKHOUSE_ENDPOINT` is the HTTP interface as `scheme://host:port`, e.g.
`https://<service>.<region>.aws.clickhouse.cloud:8443` on ClickHouse Cloud. `hud-migrate` accepts the same value (an
`https://` endpoint implies `secure=true`, and a path is ignored), so one variable can serve both.

`hud-migrate` creates the database and its schema, like ClickStack's `migrate` (the customer's setup script only
creates users and grants). It runs as an init container before the collector, with DDL credentials the collector
never gets, and re-applies every embedded `hud-migrate/schema/*.sql` on each start. Running it from every replica at
once is safe.

Environment: `CLICKHOUSE_ENDPOINT` (`tcp://`, `http://` or `https://`), `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`,
`CLICKHOUSE_TLS_INSECURE_SKIP_VERIFY` (`true` for a self-signed certificate; the collector config reads it too),
`HUD_CLICKHOUSE_DATABASE` (default `hud_otel`; the collector config reads the same variable, like ClickStack's
`HYPERDX_OTEL_EXPORTER_CLICKHOUSE_DATABASE`), `HUD_LOGS_TTL_DAYS` (default 30) and `HUD_METRICS_FINE_TTL_DAYS`
(default 30, the 1- and 5-minute metric tables); both only apply when a table is created, later changes don't touch an
existing table. With `HUD_SCHEMA_MANAGED=false` it exits without connecting, for customers who run the same SQL themselves.

Rules for `hud-migrate/schema/*.sql`, as in ClickStack:

- The customer's admin setup (`playground/clickstack/setup.sql`) grants on the same database name: replace its
  `${HUD_CLICKHOUSE_DATABASE}` placeholder, or run `setup.sh`, which validates the name and substitutes it. The grants
  stay scoped to that one database; with another name, `hud-migrate` is denied.
- **Create only.** Statements are `CREATE ... IF NOT EXISTS` (database, tables, views) or `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`; never
  `CREATE OR REPLACE`, `MODIFY`, `RENAME` or `DROP`. Changing an existing object means a new object under a new name.
  `TestSchemaIsCreateOnly` (run by `make smoke`) fails on anything else, and the migrator's grants (`CREATE
  DATABASE, CREATE TABLE, CREATE VIEW, ALTER ADD COLUMN, SELECT, INSERT ON <database>.*`) make the server refuse it too. Add a new numbered file
  rather than editing a released one.
- A new column needs a `DEFAULT` or `MATERIALIZED` expression, so older collectors' inserts, which don't name it,
  keep working.
- Name objects as `${DATABASE}.<name>`, and touch nothing outside that database: the migrator's grants only cover it.
- Materialized views use `DEFINER = CURRENT_USER SQL SECURITY DEFINER`, so the insert-only collector user can
  write through them.

## Updating upstream

`scripts/bump.sh [tag]` pins every module to the versions in the upstream `otelcol-contrib` manifest for that
tag (latest by default).

The `bump` workflow runs this every Monday. If anything changed, it runs the smoke test and opens a PR.
Merging a PR that changes `manifest.yaml` triggers the `release` workflow, which tags `v<dist.version>` and
publishes the binaries and images.

Before merging a bump, read the contrib changelog for our components; `deltatocumulative` and `interval` are
alpha and can change behavior between versions.

## Adding a component

Add its `gomod` line to `manifest.yaml` (the module must exist in the upstream `otelcol-contrib` manifest,
or `bump.sh` fails), extend `test/` if it matters for the pipeline, and open a PR.

## License

Copyright Hud Technology Inc. Licensed under the [Apache License, Version 2.0](LICENSE).
