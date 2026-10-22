# hud-otel-collector

A minimal OpenTelemetry Collector distribution for Hud's OTLP data plane, built with the
[OpenTelemetry Collector Builder](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder) (OCB).
It is not a fork: `manifest.yaml` lists upstream modules at pinned versions, and OCB compiles them.

| Kind | Components |
| --- | --- |
| Receivers | `otlp` |
| Processors | `transform`, `deltatocumulative`, `interval`, `memory_limiter`, `batch` |
| Exporters | `prometheusremotewrite`, `otlphttp`, `debug` |
| Extensions | `sigv4auth`, `health_check` |

Every config written for this distribution also runs on `otel/opentelemetry-collector-contrib`, which is the fallback.

## Artifacts

- Image: `ghcr.io/code-hud/hud-otel-collector:<version>` (multi-arch: `linux/amd64`, `linux/arm64`), plus `:latest`.
- Binaries: linux, darwin and windows for amd64 and arm64, attached to each [GitHub release](../../releases).

Versions follow the upstream `opentelemetry-collector-releases` version (`0.163.2`). A rebuild of the
same upstream version (for example a Go security fix) is tagged `v0.163.2-hud.1`.

## Local development

Only Docker is required; Go runs in a container.

```sh
make build   # OCB generates and compiles _build/hud-otelcol (linux, Docker host arch)
make image   # hud-otelcol:dev
make smoke   # two fake pods send deltas; expects one merged Prometheus series with the summed total
```

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
