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
             # then runs hud-migrate and test/clickstack.yaml against ClickHouse and checks PromQL and otel_logs (database hud_otel_smoke)
```

## ClickStack

`test/clickstack.yaml` is the AMP merge-mode pipeline (the `metrics/functions` and `metrics/per_pod` pipelines of
hud-o11y-resources' deploy configs, processors copied as is) writing to ClickHouse: metrics are remote-written into
`hud_otel.metrics`, a `TimeSeries` table queried with PromQL, and logs go through the `clickhouse` exporter into
`hud_otel.otel_logs`. Two differences from the deploy configs: the SDK's exponential histograms are converted to classic
buckets before `delta_to_cumulative`, because ClickHouse drops native histograms (so PromQL uses `_bucket`/`_count`, not
`histogram_count()`), and the exporter turns every resource attribute into a label (`resource_constant_labels`), which
gives the label sets of Hud's AMP data, `service_instance_id` included. `playground/clickstack/` runs it end to end
with HyperDX and the node SDK.

The collector's `CLICKHOUSE_ENDPOINT` is the HTTP interface as `scheme://host:port`, e.g.
`https://<service>.<region>.aws.clickhouse.cloud:8443` on ClickHouse Cloud, with no path, query string or trailing
slash: the remote-write URL is built by appending `/prometheus/api/v1/write?...` to it. `hud-migrate` accepts the same
value (an `https://` endpoint implies `secure=true`, and a path is ignored), so one variable can serve both.

`hud-migrate` creates the database and its schema, like ClickStack's `migrate` (the customer's setup script only
creates users and grants). It runs as an init container before the collector, with DDL credentials the collector
never gets, and re-applies every embedded `hud-migrate/schema/*.sql` on each start. Running it from every replica at
once is safe.

Environment: `CLICKHOUSE_ENDPOINT` (`tcp://`, `http://` or `https://`), `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`,
`CLICKHOUSE_TLS_INSECURE_SKIP_VERIFY` (`true` for a self-signed certificate; the collector config reads it too),
`HUD_CLICKHOUSE_DATABASE` (default `hud_otel`; the collector config reads the same variable, like ClickStack's
`HYPERDX_OTEL_EXPORTER_CLICKHOUSE_DATABASE`), `HUD_LOGS_TTL_DAYS` (default 30; only applies when `otel_logs` is
created, later changes don't touch an existing table). With `HUD_SCHEMA_MANAGED=false` it exits without connecting, for customers who run the same SQL themselves.

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
