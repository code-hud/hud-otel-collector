# Deploying (customer AWS account)

Commands below run from the repository root.

The collector runs in the customer's account and writes to their Amazon Managed Service for Prometheus (AMP).
Both paths create an AMP workspace unless one is given, and grant the collector only `aps:RemoteWrite` on it.

Two modes:
- `merge` (default): all app pods add into one series per collector task/pod. Apps must set
  `HUD_OTLP_TEMPORALITY=delta`.
- `convert`: one series per app pod, no changes in the apps.

Investigations (Hud's error forensics) are sent as OTLP logs to the
[Observability Stack](https://github.com/opensearch-project/observability-stack)'s OpenSearch Ingestion (OSIS)
pipeline, so they land in its OpenSearch. Without OSIS parameters, only metrics are sent.

> **Test links.** The "Launch in CloudFormation" links below use a private S3 bucket in account 736129612463
> and open the console in `us-east-1` (change the region in the console if needed). They only work when signed in
> to that account; other accounts get an access error until the public bucket exists.

## ECS Fargate

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

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Fobservability.yaml&stackName=hud-obs) (template: `deploy/aws/observability.yaml`)

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

[Launch in CloudFormation](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhud-cfn-test-736129612463.s3.amazonaws.com%2Ftest%2Fecs-fargate.yaml&stackName=hud-collector) (template: `deploy/aws/ecs-fargate.yaml`)

**3. Apps.** Set `HUD_OTLP_ENDPOINT` and `HUD_OTLP_TEMPORALITY` to the stack's `OtlpEndpoint` and
`OtlpTemporality` outputs. Metrics show up in the OpenSearch UI through its AMP data source (PromQL), and
investigations in its logs.

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
`eks.amazonaws.com/role-arn` annotation to the `RoleArn` output. Apps send to `http://hud-collector.hud:4318`.
