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
  It holds `/hud-otelcol` (the entrypoint) and `/hud-migrate` (see [ClickHouse](#clickhouse)).
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
[hud-opensearch-resources](https://github.com/code-hud/hud-opensearch-resources/blob/main/deploy/README.md).

## Local development

Only Docker is required; Go runs in a container.

```sh
make build   # OCB generates and compiles _build/hud-otelcol (linux, Docker host arch)
make image   # hud-otelcol:dev
make smoke   # five fake pods send deltas concurrently; expects one merged Prometheus series with the summed total,
             # then runs hud-migrate and test/clickhouse.yaml against ClickHouse and checks the SQL tables and otel_logs
             # (database hud_otel_smoke), then both with test/timeseries.yaml: the TimeSeries table in hud_otel_smoke_promql,
             # read with PromQL
```

## ClickHouse

`test/clickhouse.yaml` sends the SDK's metrics through the `clickhouse` exporter into its default `otel_metrics_*` tables
of `hud_otel`, and logs into `hud_otel.otel_logs`. The `otel_metrics_*` tables are the exporter's own layout (so HyperDX
reads them as a metrics source) and keep the raw rows 3 days, every metric the SDK sends; materialized views sum each
insert into the tables below (`hud-migrate/schema/0002_sql.sql`). A time range of those can be rebuilt from the raw rows
by running their views' `SELECT`. The collector keeps no state (no pod merging, no `delta_to_cumulative`), so it scales
out freely: it only batches the inserts.

| Tables | Grain | One row per (and what it sums) |
| --- | --- | --- |
| `endpoint_durations` | export | flow, SDK session (`service.instance.id`), deployment, status code, method, route, end reason, queue and feature flag combination: runs, duration, queue latency (e2e) |
| `endpoint_counters` | export | flow, SDK session, deployment, and per counter: queue (messages), issue fingerprint and user error (issues), status code and the flow that called it (parent) and started it (root) (`runs_by_caller`); and feature flag combination |
| `endpoint_metrics_1h` | hour | both endpoint tables |
| `endpoint_metrics_lean_1h` | hour | the same without the session |
| `process_metrics`, `process_metrics_1h` | export, hour | SDK session and its pod: last report, uptime, CPU, memory and its limit, event loop utilization |
| `function_durations` | export | function, file, caller function (name and file), flow, content hash, deployment: duration |
| `function_counters` | export | the same and error type: calls, errors |
| `function_metrics_1h` | hour | both function tables |
| `function_metrics_lean_1h` | hour | function, file, flow, deployment |
| `endpoints` | | every service (with `flow = ''`, from its process metrics) and flow seen in the last 180 days (the dashboards' selectors) |
| `functions` | | every function seen in the last 180 days, with its flow (the dashboards' selectors) |

Each fine table is filled by one view over one `otel_metrics_*` table: the exporter inserts sums, histograms and
gauges separately, so a table fed from two would get a half-empty row from each. Endpoints and functions therefore
have a durations table (`_durations`) and a counters table (`_counters`), and the collector turns the process memory
sums into gauges so `process_metrics` stays one table. A 5xx rate is
`sumIf(duration_count, startsWith(status_code, '5')) / sum(duration_count)`. Both tables of a family roll up into its
`_metrics_1h` table, and the endpoint and function tables also into their `_metrics_lean_1h` table, with far fewer rows: what
most charts read. Fine tables are plain `MergeTree` with a row per export (a point as the SDK sent it, at its end, one
row per key, pod and export): sum them with `sum`, `sumMap(buckets)` and `groupUniqArrayArrayMap(1000)(attributes)`. They keep 30
days, fixed because the dashboards read them up to 30 days back and the hourly tables beyond. Hourly tables are
`AggregatingMergeTree` of aggregate states with their fine tables' columns and keep 90 days (`_lean_1h`: 180): read
them with `-Merge`, or `finalizeAggregation()` a column to union it with the fine table's. Every table's parts are
daily, so TTL drops whole days. The views of one insert are not atomic (a failing view can leave others written) and
the collector retries the whole batch, so every metric table keeps the hashes of its last 10000 inserts
(`non_replicated_deduplication_window`, or `replicated_deduplication_window` on replicated and Cloud tables), and the
collector inserts synchronously with `deduplicate_blocks_in_dependent_materialized_views` (async inserts, the
exporter's default, are not deduplicated), so a retry only writes what is missing. The endpoint and function tables also keep every other attribute the SDK sends, so a new one needs no
migration. `attributes` holds up to
1000 values per attribute and `attribute_counts` the runs (calls) per `attribute=value`, keyed by
`sipHash64('attribute=value') % 100000`; `hud_attribute_count(attribute, value, counts)` (created by the admin's
`setup.sql`, since functions are server-wide) reads one. A row holds at most 100000 counts; values that share a bucket
add up. Session and host attributes are left out, and so are a function's short name and its flow's type, route and
methods (the flow's are in its name). The endpoint tables' `feature_flags` is the combination of feature flags a
flow's runs set (the SDK's `hud.feature_flag.<key>` attributes): the pairs sorted by key, `'fast_path=false,new_checkout=true'`,
`'__hud_other__'` past the SDK's 16 combinations per flow, `''` without flags; these attributes stay out of `attributes`.
Every listed value with its runs:

```sql
SELECT k AS attribute, v AS value, hud_attribute_count(k, v, counts) AS runs
FROM (
  SELECT groupUniqArrayArrayMapMerge(1000)(attributes) AS vals, sumMap(attribute_counts) AS counts
  FROM hud_otel.function_metrics_lean_1h WHERE service = 'checkout' AND hour >= now() - INTERVAL 1 DAY
)
ARRAY JOIN mapKeys(vals) AS k, mapValues(vals) AS vs
ARRAY JOIN vs AS v
ORDER BY attribute, runs DESC
```

Every row has the environment (`deployment.environment.name`) and the service (`service.name`).
Durations are the SDK's base2 exponential histograms at scale 2: `buckets[k]` counts durations in
(2^(k/4), 2^((k+1)/4)] seconds and leaves out the empty buckets, so any grain answers percentiles, from nanoseconds to
hours at about ±9%. `hud_duration_quantile(q, sumMap(buckets))` (created by the admin's `setup.sql`) reads one, in
seconds. Only deltas are summed (the
SDK sends nothing else), except the process gauges and limits. A delta covers the SDK's export interval
(`aggregationInterval`: 5 minutes by default, set per account) and lands whole at the interval's end (`TimeUnix`): in
that second's fine row and that hour's hourly row, so a chart is no finer than the export interval.
The `metrics` `TimeSeries` table (`0003_timeseries.sql`) is only
created with `HUD_TIMESERIES_TABLE=true`, in its own database: the SQL tables' name with suffix `_promql`
(`hud_otel_promql`), which `hud-migrate` creates too. `test/timeseries.yaml`, layered on
`test/clickhouse.yaml` (`--config clickhouse.yaml --config timeseries.yaml`), also writes the metrics into it through
ClickHouse's Prometheus remote-write endpoint, for PromQL (`/prometheus/api/v1/query`): deltas made cumulative, and the
exponential histograms as classic `le` buckets on powers of 2 (the table drops native histograms). That pipeline keeps
`delta_to_cumulative` state, so a pod's metrics must keep reaching one replica. The endpoint is server config
(`test/clickhouse-prometheus.xml`) on self-managed servers, and only exists on Cloud services in the PromQL private
preview. `playground/clickstack/` runs it end to end with HyperDX and the node SDK; the
dashboards are in [hud-clickhouse-resources](https://github.com/code-hud/hud-clickhouse-resources).

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
`HYPERDX_OTEL_EXPORTER_CLICKHOUSE_DATABASE`) and `HUD_LOGS_TTL_DAYS` (default 30; only applies when `otel_logs` is
created, later changes don't touch the existing table), `HUD_TIMESERIES_TABLE` (default `false`; `true` also creates
the `<database>_promql` database and its `metrics` `TimeSeries` table, which needs a server that allows the `TimeSeries` engine). With `HUD_SCHEMA_MANAGED=false` it exits without connecting, for customers who run the same SQL themselves.

Rules for `hud-migrate/schema/*.sql`, as in ClickStack:

- The customer's admin setup (`playground/clickstack/setup.sql`) grants on the same database name: replace its
  `${HUD_CLICKHOUSE_DATABASE}` placeholder, or run `setup.sh`, which validates the name and substitutes it. The grants
  stay scoped to that database and its `_promql` sibling; with another name, `hud-migrate` is denied.
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
