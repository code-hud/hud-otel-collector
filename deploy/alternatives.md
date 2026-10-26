# Deploying with existing resources (ECS Fargate)

Use these separate stacks instead of the [one-stack deploy](README.md) when you already have an
Observability Stack or an AMP workspace. Commands below run from the repository root.

The collector stack creates an AMP workspace unless you pass one, and grants the collector only
`aps:RemoteWrite` on it. Without OSIS parameters, only metrics are sent.

> **Test links.** The "Launch in CloudFormation" links below open the console in `us-east-1` with templates
> from a temporary test bucket. They will move to the real public bucket later.

`deploy/aws/ecs-fargate.yaml` runs the collector as a service in your existing ECS cluster and VPC, reachable at
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

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Fobservability.yaml&stackName=hud-obs) (template: `deploy/aws/observability.yaml`)

With an existing stack (from the installer or built some other way), use its AMP workspace id and the full
OTLP logs URL of its OSIS pipeline (the pipeline must accept OTLP logs). The installer names both after the
pipeline: `aws amp list-workspaces --alias <pipeline>` and `https://<IngestEndpointUrls[0]>/<pipeline>/v1/logs`.

**2. Collector.** Subnets need outbound internet (NAT) to pull the image and reach AMP and OSIS. The task
pulls the public `ghcr.io/code-hud/hud-otel-collector` image; to use a copy in your account's ECR, pass `Image`.

```sh
aws cloudformation deploy --stack-name hud-collector --template-file deploy/aws/ecs-fargate.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides \
  ClusterName=<cluster> VpcId=<vpc> SubnetIds=<subnet-a>,<subnet-b> AllowedCidr=<vpc cidr> \
  AmpWorkspaceId=$AMP_WS OsisLogsUrl=$OSIS_LOGS OsisPipelineName=hud-obs
```

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Fecs-fargate.yaml&stackName=hud-collector) (template: `deploy/aws/ecs-fargate.yaml`)

**3. Your apps.** Set `HUD_OTLP_ENDPOINT` and `HUD_OTLP_TEMPORALITY` in your apps to the stack's `OtlpEndpoint` and
`OtlpTemporality` outputs. Metrics show up in the OpenSearch UI through its AMP data source (PromQL), and
investigations in its logs.

## Hud access on its own

`deploy/aws/hud-access.yaml` creates only the read-only role described in [Hud access](README.md#hud-access),
for an AMP workspace and, optionally, an OpenSearch Serverless collection you already have (empty
`CollectionName` shares metrics only). Use the collector stack's `AmpWorkspaceId` output, or the Observability
Stack's `AmpWorkspaceId` and `CollectionName` outputs:

```sh
aws cloudformation deploy --stack-name hud-access --template-file deploy/aws/hud-access.yaml \
  --capabilities CAPABILITY_IAM --parameter-overrides \
  ExternalId=<external id from Hud> AmpWorkspaceId=$AMP_WS CollectionName=hud-obs
```

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Fhud-access.yaml&stackName=hud-access) (template: `deploy/aws/hud-access.yaml`)

Delete the stack to revoke access.
