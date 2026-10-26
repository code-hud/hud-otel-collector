# Deploying to your AWS account

Commands below run from the repository root.

The collector runs in your AWS account and writes to your Amazon Managed Service for Prometheus (AMP).
Investigations (Hud's error forensics) are sent as OTLP logs to the
[Observability Stack](https://github.com/opensearch-project/observability-stack)'s OpenSearch Ingestion (OSIS)
pipeline, so they land in its OpenSearch.

Two modes:
- `merge` (default): all your app pods add into one series per collector task/pod. Your apps must set
  `HUD_OTLP_TEMPORALITY=delta`.
- `convert`: one series per app pod, no changes to your apps.

> **Test links.** The "Launch in CloudFormation" links below open the console in `us-east-1` with templates
> from a temporary test bucket. They will move to the real public bucket later.

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

Subnets need outbound internet (NAT) to pull the image and reach AMP and OSIS. The task pulls the public
`ghcr.io/code-hud/hud-otel-collector` image; to use a copy in your account's ECR, pass `Image`. The AMP
workspace is kept if the stack is deleted.

```sh
aws cloudformation deploy --stack-name hud --template-file deploy/aws/unified-ecs.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides \
  ClusterName=<cluster> VpcId=<vpc> SubnetIds=<subnet-a>,<subnet-b> AllowedCidr=<vpc cidr> \
  ExternalId=<external id from Hud>
```

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Funified-ecs.yaml&stackName=hud) (template: `deploy/aws/unified-ecs.yaml`)

**Your apps.** Set `HUD_OTLP_ENDPOINT` and `HUD_OTLP_TEMPORALITY` in your apps to the stack's `OtlpEndpoint` and
`OtlpTemporality` outputs. Metrics show up in the OpenSearch UI (`DashboardUrl` output) through its AMP data
source (PromQL), and investigations in its logs.

Already have an Observability Stack or AMP workspace? See [Deploying with existing resources](alternatives.md).

`unified-ecs.yaml` is generated from `observability.yaml`, `ecs-fargate.yaml` and `hud-access.yaml`: edit
those, then run `scripts/unify.py`.

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

Hud reads your data from its own AWS account (`736129612463`) by assuming a role in yours. The one-stack deploy
creates it; for other setups, deploy `deploy/aws/hud-access.yaml` on its own
([alternatives](alternatives.md#hud-access-on-its-own)).

The role trusts Hud's account (or only the role in `HudPrincipalArn`, if set), and only with the `ExternalId` Hud
gives you. It can only read:
- AMP: `aps:QueryMetrics`, `aps:GetSeries`, `aps:GetLabels` and `aps:GetMetricMetadata` on the stack's AMP workspace.
- OpenSearch Serverless: describe the collection and its indexes and read documents (investigations), through a
  data access policy on the stack's collection, plus `aoss:BatchGetCollection` to find its endpoint.

Give Hud the `HudRoleArn` and `HudExternalId` outputs. To revoke access, delete the stack (with the one-stack
deploy this removes the collector and Observability Stack too), or delete the role in IAM.

In the Observability Stack, the collection's own data access policy also grants your account root, so any role
in your account with `aoss:APIAccessAll`, including Hud's, can also write and delete documents there.
