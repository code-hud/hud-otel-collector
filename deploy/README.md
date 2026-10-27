# Deploying to your AWS account

Commands below run from the repository root.

The collector runs in your AWS account and writes to your Amazon Managed Service for Prometheus (AMP).
Investigations (Hud's error forensics) are sent as OTLP logs to the
[Observability Stack](https://github.com/opensearch-project/observability-stack)'s OpenSearch Ingestion (OSIS)
pipeline, so they land in its OpenSearch.

Two modes:
- `merge` (default): function metrics (`code.function.*`) from all your app pods add into one series per
  collector task/pod and deployment. Per-pod resource attributes (`process.pid`, `k8s.pod.name`, ...) are dropped
  from them; the kept ones become labels: `deployment_environment_name`, `deployment_id`, `k8s_namespace_name`,
  `cloud_provider`, `cloud_region`, `telemetry_sdk_version` and `hud_identity_version` (each only when your apps
  set it). During a rollout the old and new deployments are separate series, so for totals use
  `sum without (deployment_id, telemetry_sdk_version) (...)`. Flow and process metrics stay one series per app pod.
- `convert`: one series per app pod for every metric.

Both take the deltas the Hud SDK sends; point your apps at the collector with `HUD_EXPORTER=otlp` and `HUD_OTLP_ENDPOINT`.

> **Test links.** The "Launch in CloudFormation" links below open the console in `us-east-1` with templates
> from a temporary test bucket. They will move to the real public bucket later.

Your launch link comes from Hud's onboarding, with the `ExternalId` Hud generated for you already filled in; don't
change it. For testing, `scripts/quick-create-link.sh` prints a new ExternalId and the links of both one-stack
templates with it prefilled (the bare links below leave it empty).

## ECS Fargate

`deploy/aws/unified-ecs.yaml` creates everything in one stack (~10 minutes):
- the Observability Stack: the same resources as the official serverless
  [installer](https://github.com/opensearch-project/observability-stack/blob/main/aws/cli-installer/README.md),
  i.e. OpenSearch Serverless, an OSIS pipeline (logs, traces and service map to OpenSearch, metrics to AMP), an
  AMP workspace, and the OpenSearch UI with an Observability workspace and AMP as a PromQL data source;
- the collector as a service in your existing ECS cluster and VPC, reachable at `http://hud-collector.hud.local:4318`
  (private DNS), writing metrics to that AMP workspace and investigations to that pipeline. Defaults: 1 vCPU,
  4 GB, ARM64, 1 task;
- a read-only role Hud can assume to query that data (see [Hud access](#hud-access)).

Deploy the collector into public subnets (with a route to an internet gateway). The tasks get public IPs
(`AssignPublicIp=ENABLED`, the default) to pull the image and reach AMP and OSIS, but the security group only
opens port 4318 only to `AllowedCidr` (your VPC CIDR; `0.0.0.0/0` is rejected), so nothing is reachable from the
internet. For private subnets with a NAT gateway, see [alternatives](alternatives.md#private-subnets). The task pulls the public
`ghcr.io/code-hud/hud-otel-collector` image; to use a copy in your account's ECR, pass `Image`. The AMP
workspace is kept if the stack is deleted.

```sh
aws cloudformation deploy --stack-name hud --template-file deploy/aws/unified-ecs.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides \
  ClusterName=<cluster> VpcId=<vpc> SubnetIds=<subnet-a>,<subnet-b> AllowedCidr=<vpc cidr> \
  ExternalId=<external id from Hud>
```

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Funified-ecs.yaml&stackName=hud) (template: `deploy/aws/unified-ecs.yaml`)

**Your apps.** Set `HUD_OTLP_ENDPOINT` and `HUD_EXPORTER` in your apps to the stack's `OtlpEndpoint` and
`HudExporter` outputs. Metrics show up in the OpenSearch UI (`DashboardUrl` output) through its AMP data
source (PromQL), and investigations in its logs, for anyone in your account (see
[Who can read the collection](#who-can-read-the-collection)).

### Already running the observability stack?

`deploy/aws/unified-ecs-existing-ui.yaml` leaves yours alone. It creates Hud's own collection, pipeline and AMP
workspace next to yours, with no UI app, plus the collector and the Hud access role. Pass `ExistingUiAppId` to
add Hud's data to your OpenSearch UI app (details in
[alternatives](alternatives.md#next-to-your-observability-stack)):

```sh
aws cloudformation deploy --stack-name hud --template-file deploy/aws/unified-ecs-existing-ui.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides \
  ClusterName=<cluster> VpcId=<vpc> SubnetIds=<subnet-a>,<subnet-b> AllowedCidr=<vpc cidr> \
  ExternalId=<external id from Hud> ExistingUiAppId=<your OpenSearch UI app id, optional>
```

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Funified-ecs-existing-ui.yaml&stackName=hud) (template: `deploy/aws/unified-ecs-existing-ui.yaml`)

For separate stacks, or an AMP workspace you already have, see [Deploying with existing resources](alternatives.md).

`observability.yaml`, `unified-ecs.yaml` and `unified-ecs-existing-ui.yaml` are generated from the templates in
`deploy/aws/parts/`, `ecs-fargate.yaml` and `hud-access.yaml`: edit those, then run `scripts/unify.py`.

## EKS

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

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Feks-iam.yaml&stackName=hud-collector-iam) (template: `deploy/aws/eks-iam.yaml`)

Add `-f deploy/helm/values-convert.yaml` for `convert` mode. With IRSA, also set the service account's
`eks.amazonaws.com/role-arn` annotation to the `RoleArn` output. Your apps send to `http://hud-collector.hud:4318`.
To use an existing AMP workspace, pass `AmpWorkspaceId=<ws-...>`. On EKS only metrics are sent; investigations
aren't sent to OpenSearch yet. To give Hud access, deploy `deploy/aws/hud-access.yaml` with the stack's
`AmpWorkspaceId` output (see [Hud access](#hud-access)).

## Hud access

Hud reads your data from its own AWS account (`736129612463`) by assuming a role in yours. Both one-stack templates
create it; for other setups, deploy `deploy/aws/hud-access.yaml` on its own
([alternatives](alternatives.md#hud-access-on-its-own)).

The role trusts Hud's account, and only with the `ExternalId` Hud generated for you (prefilled in your launch
link). It can only read:
- AMP: `aps:QueryMetrics`, `aps:GetSeries`, `aps:GetLabels` and `aps:GetMetricMetadata` on the stack's AMP workspace.
- OpenSearch Serverless: describe the collection and its indexes and read documents (investigations), through a
  data access policy on the stack's collection. Its IAM policy allows `aoss:APIAccessAll`, which OpenSearch
  Serverless requires for any data call, only for that collection (`aoss:collection` condition).

It can't write to AMP or to any collection. Give Hud the `HudRoleArn`, `CollectionName` and
`CollectionEndpoint` outputs. To revoke access, delete the stack (with the one-stack deploy this removes the
collector and Observability Stack too), or delete the role in IAM.

### Who can read the collection

The collection's data access policies allow:
- the OSIS pipeline role: write (the only writer by default);
- your account root: read (describe the collection and its indexes, read documents), so any IAM role or user in
  your account that also has `aoss:APIAccessAll` (and `aoss:DashboardsAccessAll` for the OpenSearch UI) in IAM can
  read the data. This covers the OpenSearch UI setup and your OpenSearch UI users. Index patterns, saved searches,
  visualizations and dashboards are stored in the OpenSearch UI app, not in the collection, so read access is enough
  for them;
- Hud's role: read;
- the IAM roles or users in `DataWritePrincipals` (optional, comma-separated ARNs, no spaces): write, i.e. create and
  update indexes and documents, as the pipeline can. Empty by default. Use it only for something that writes to
  the collection itself, such as index or document requests in Dev Tools.

Deployed an earlier version? Its policy gave your account root read and write. Updating the stack makes everyone
in your account read-only; what the OpenSearch UI shows doesn't change. If something of yours writes to the
collection, pass its role in `DataWritePrincipals` in the same update.
