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
             # then runs hud-migrate and test/clickstack.yaml against ClickHouse and checks PromQL and hud.otel_logs
```

## ClickStack

`test/clickstack.yaml` is the AMP pipeline writing to ClickHouse: metrics are remote-written into `hud.metrics`, a
`TimeSeries` table queried with PromQL, and logs go through the `clickhouse` exporter into `hud.otel_logs`. The SDK's
exponential histograms are converted to classic buckets first, because ClickHouse drops native histograms.
`playground/clickstack/` runs it end to end with HyperDX and the node SDK.

`hud-migrate` owns the schema in the `hud` database (the customer's setup script creates the database and users).
It runs as an init container before the collector, with DDL credentials the collector never gets:

| Command | Does |
| --- | --- |
| `/hud-migrate up` (default) | Re-applies every `hud-migrate/schema/*.sql`, records the version in `hud.schema_info`. Safe to run from every replica at once. Refuses to run against a schema whose recorded `min_compatible` is newer than it knows. |
| `/hud-migrate once` | Runs the `hud-migrate/schema/once/*.sql` steps not yet recorded in `hud.schema_steps` (backfills, `MATERIALIZE INDEX`). Run it from one runner only. |
| `/hud-migrate status` | Prints the recorded version and steps. |

Environment: `CLICKHOUSE_ENDPOINT` (`tcp://`, `http://` or `https://`), `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`,
`HUD_LOGS_TTL_DAYS` (default 30). With `HUD_SCHEMA_MANAGED=false`, `up` and `once` exit without connecting, for
customers who run the same command themselves.

Rules for schema changes:

- **Add only.** Never drop or rename a table or column that a still-supported collector writes or reads; that is
  what makes image rollback safe without down migrations. Add a new numbered file rather than editing a released one.
- Every statement in `schema/*.sql` must be idempotent: `CREATE ... IF NOT EXISTS`, `ADD COLUMN/INDEX IF NOT
  EXISTS`, diff-guarded `MODIFY TTL`, `MODIFY QUERY`. Anything that must run exactly once goes in `schema/once/`.
- No `CREATE DATABASE`, and nothing outside `hud`: the migrator only has DDL on `hud.*`.
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
