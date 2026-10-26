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

Owner: [@ilansh](https://github.com/ilansh). The owner reviews bump PRs and handles CVE reports.

## Artifacts

- Image: `ghcr.io/code-hud/hud-otel-collector:<version>` (multi-arch: `linux/amd64`, `linux/arm64`), plus `:latest`.
- Binaries: linux, darwin and windows for amd64 and arm64, attached to each [GitHub release](../../releases).

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

## Deploying (customer AWS account)

The collector runs in the customer's account and writes to their Amazon Managed Service for Prometheus (AMP).
Both paths create an AMP workspace unless one is given, and grant the collector only `aps:RemoteWrite` on it.

Two modes:
- `merge` (default): all app pods add into one series per collector task/pod. Apps must set
  `HUD_OTLP_TEMPORALITY=delta`.
- `convert`: one series per app pod, no changes in the apps.

Investigations (Hud's error forensics) are sent as OTLP logs to the
[Observability Stack](https://github.com/opensearch-project/observability-stack)'s OpenSearch Ingestion (OSIS)
pipeline, so they land in its OpenSearch. Without OSIS parameters, only metrics are sent.

### ECS Fargate

`deploy/aws/ecs-fargate.yaml` runs the collector as a service in an existing cluster and VPC, reachable at
`http://hud-collector.hud.local:4318` (private DNS). Defaults: 1 vCPU, 4 GB, ARM64, 1 task.

**1. Observability Stack** (skip if you already have one). `deploy/aws/observability.yaml` creates the same
resources as the official serverless
[installer](https://github.com/opensearch-project/observability-stack/blob/main/aws/cli-installer/README.md):
OpenSearch Serverless, an OSIS pipeline (logs, traces and service map to OpenSearch, metrics to AMP), an AMP
workspace, and the OpenSearch UI with an Observability workspace and AMP as a PromQL data source (~10 minutes):

```sh
aws cloudformation deploy --stack-name hud-obs --template-file deploy/aws/observability.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides Name=hud-obs
out() { aws cloudformation describe-stacks --stack-name hud-obs --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
AMP_WS=$(out AmpWorkspaceId) OSIS_LOGS=$(out OsisLogsUrl); out DashboardUrl
```

With an existing stack (from the installer or built some other way), use its AMP workspace id and the full
OTLP logs URL of its OSIS pipeline (the pipeline must accept OTLP logs). The installer names both after the
pipeline: `aws amp list-workspaces --alias <pipeline>` and `https://<IngestEndpointUrls[0]>/<pipeline>/v1/logs`.

**2. Collector.** Subnets need outbound internet (NAT) to pull the image and reach AMP and OSIS. The task
pulls the public `ghcr.io/code-hud/hud-otel-collector` image; to use a copy in this account's ECR, pass `Image`.

```sh
aws cloudformation deploy --stack-name hud-collector --template-file deploy/aws/ecs-fargate.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides \
  ClusterName=<cluster> VpcId=<vpc> SubnetIds=<subnet-a>,<subnet-b> AllowedCidr=<vpc cidr> \
  AmpWorkspaceId=$AMP_WS OsisLogsUrl=$OSIS_LOGS OsisPipelineName=hud-obs
```

**3. Apps.** Set `HUD_OTLP_ENDPOINT` and `HUD_OTLP_TEMPORALITY` to the stack's `OtlpEndpoint` and
`OtlpTemporality` outputs. Metrics show up in the OpenSearch UI through its AMP data source (PromQL), and
investigations in its logs.

### EKS

`deploy/aws/eks-iam.yaml` creates the IAM role, linked to the `hud/hud-collector` service account with
EKS Pod Identity (default) or IRSA (`AuthMode=IRSA OidcProvider=<issuer without https://>`). Then install the
official chart with `deploy/helm/values.yaml`:

```sh
aws cloudformation deploy --stack-name hud-collector-iam --template-file deploy/aws/eks-iam.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides ClusterName=<cluster>
helm install hud opentelemetry-collector --repo https://open-telemetry.github.io/opentelemetry-helm-charts \
  -n hud --create-namespace -f deploy/helm/values.yaml \
  --set-string extraEnvs[0].value=<AmpRemoteWriteUrl output>,extraEnvs[1].value=<region>
```

Add `-f deploy/helm/values-convert.yaml` for `convert` mode. With IRSA, also set the service account's
`eks.amazonaws.com/role-arn` annotation to the `RoleArn` output. Apps send to `http://hud-collector.hud:4318`.

## Local development

Only Docker is required; Go runs in a container.

```sh
make build   # OCB generates and compiles _build/hud-otelcol (linux, Docker host arch)
make image   # hud-otelcol:dev
make smoke   # five fake pods send deltas concurrently; expects one merged Prometheus series with the summed total
./test/deploy.sh  # cfn-lint, checks the Observability Stack pipeline and setup code, validates every rendered collector config
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
