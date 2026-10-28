#!/usr/bin/env bash
# Lints the CloudFormation templates, checks the generated ones match scripts/unify.py, checks the Observability Stack
# pipeline and setup code, and validates every collector config they and the Helm values render (both modes) against
# the built image.
set -euo pipefail

IMAGE=${IMAGE:-hud-otelcol:dev}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
chmod 755 "$OUT" # the collector image runs as non-root
trap 'rm -rf "$OUT"' EXIT

echo "--- cfn-lint"
docker run --rm -v "$ROOT/deploy:/d:ro" python:3.13-slim sh -c \
  'pip install -q cfn-lint 2>/dev/null && cfn-lint /d/aws/*.yaml /d/aws/parts/*.yaml'

echo "--- generated templates are up to date"
docker run --rm -v "$ROOT:/r:ro" python:3.13-slim sh -c 'pip install -q pyyaml 2>/dev/null && python /r/scripts/unify.py --check'

echo "--- observability.yaml pipeline body, setup, attach and pipeline delay code"
docker run --rm -v "$ROOT/deploy:/d:ro" python:3.13-slim sh -c 'pip install -q pyyaml 2>/dev/null && python - <<EOF
import yaml
yaml.SafeLoader.add_multi_constructor("!", lambda l, s, n: l.construct_sequence(n) if isinstance(n, yaml.SequenceNode) else l.construct_scalar(n) if isinstance(n, yaml.ScalarNode) else l.construct_mapping(n))
r = yaml.safe_load(open("/d/aws/observability.yaml"))["Resources"]
body = yaml.safe_load(r["Pipeline"]["Properties"]["PipelineConfigurationBody"])
assert {"otlp-pipeline", "otel-logs-pipeline", "service-map-pipeline", "otel-metrics-pipeline"} <= body.keys(), body.keys()
r = yaml.safe_load(open("/d/aws/parts/observability-attach.yaml"))["Resources"]
import sys, types
class ClientError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.response = {"Error": {"Code": code, "Message": message}}
gone = lambda: ClientError("ValidationException", "Data source not found")
class Fake:
    class exceptions:
        ResourceAlreadyExistsException = type("E", (Exception,), {})
    ds = [{"dataSourceArn": "theirs", "iamRoleForDataSourceArn": "role"}]
    dqs = None
    app_gone = False
    def add_direct_query_data_source(self, DataSourceName, **_): Fake.dqs = "dqs:" + DataSourceName
    def get_direct_query_data_source(self, DataSourceName):
        if not Fake.dqs: raise gone()
        return {"DataSourceArn": Fake.dqs}
    def delete_direct_query_data_source(self, DataSourceName):
        if not Fake.dqs: raise gone()
        Fake.dqs = None
    def get_application(self, id):
        if Fake.app_gone: raise ClientError("ResourceNotFoundException", "Application not found")
        return {"dataSources": [dict(d) for d in Fake.ds]}
    def update_application(self, id, dataSources):
        if Fake.app_gone: raise ClientError("ResourceNotFoundException", "Application not found")
        Fake.ds = dataSources
sys.modules["boto3"] = types.SimpleNamespace(client=lambda _: Fake())
import json, urllib.request
sent = []
urllib.request.urlopen = lambda req, timeout: sent.append((req.get_method(), req.get_header("Content-type"), json.loads(req.data)))
def call(fn, kind, p, ok=True):
    ev = {"RequestType": kind, "ResourceProperties": p, "ResponseURL": "https://s3/presigned", "StackId": "s", "RequestId": "r", "LogicalResourceId": "l"}
    fn(ev, None)
    method, ctype, body = sent.pop()
    assert method == "PUT" and ctype == "" and body["Status"] == ("SUCCESS" if ok else "FAILED") and body["RequestId"] == "r", body
    assert ok or body["Reason"], body
    assert not sent, sent
theirs = [{"dataSourceArn": "theirs", "iamRoleForDataSourceArn": "role"}]
ns = {}
exec(r["AttachFunction"]["Properties"]["Code"]["ZipFile"], ns)
p = {"AppId": "app1", "CollectionArn": "coll", "WorkspaceArn": "ws", "DirectQueryRoleArn": "r", "DataSourceName": "hud_x_hud_prometheus"}
call(ns["handler"], "Delete", p)  # nothing was ever attached
assert Fake.ds == theirs and Fake.dqs is None, Fake.ds
for _ in range(2): call(ns["handler"], "Create", p)
assert [d["dataSourceArn"] for d in Fake.ds] == ["theirs", "coll", "dqs:hud_x_hud_prometheus_app1"], Fake.ds
assert Fake.ds[0] == theirs[0], Fake.ds
call(ns["handler"], "Delete", p)
assert Fake.ds == theirs and Fake.dqs is None, Fake.ds
call(ns["handler"], "Delete", p)  # already detached
Fake.app_gone = True
call(ns["handler"], "Delete", p)  # the app itself was deleted
Fake.app_gone = False
real_get_dqs, real_get_app = Fake.get_direct_query_data_source, Fake.get_application
Fake.get_direct_query_data_source = lambda self, DataSourceName: (_ for _ in ()).throw(ClientError("AccessDeniedException", "no"))
call(ns["handler"], "Delete", p, ok=False)  # other errors still fail
Fake.get_application = lambda self, id: 1 / 0
call(ns["handler"], "Update", p, ok=False)
Fake.get_direct_query_data_source, Fake.get_application = real_get_dqs, real_get_app
# Setup: a failure must still answer CloudFormation (Fake has no list/describe calls Setup needs), and Delete with
# nothing left to remove succeeds.
for m in ("botocore", "botocore.session", "botocore.auth", "botocore.awsrequest"):
    sys.modules[m] = types.SimpleNamespace(session=None, SigV4Auth=None, AWSRequest=None)
r = yaml.safe_load(open("/d/aws/observability.yaml"))["Resources"]
ns = {}
exec(r["SetupFunction"]["Properties"]["Code"]["ZipFile"], ns)
sp = {"AppId": "app1", "CollectionArn": "coll", "DataSourceName": "x", "DirectQueryRoleArn": "r", "WorkspaceArn": "ws"}
Fake.app_gone, Fake.dqs = True, None
call(ns["handler"], "Create", sp, ok=False)
call(ns["handler"], "Delete", sp)
# PipelineDelay: sleeps on Create only, and a bad value still answers.
import time
slept, real_sleep = [], time.sleep
time.sleep = slept.append
ns = {}
exec(r["PipelineDelayFunction"]["Properties"]["Code"]["ZipFile"], ns)
for kind in ("Create", "Update", "Delete"):
    call(ns["handler"], kind, r["PipelineDelay"]["Properties"])
assert slept == [120], slept
call(ns["handler"], "Create", {"Seconds": "x"}, ok=False)
time.sleep = real_sleep
assert r["PipelineDelay"]["DependsOn"] == ["Collection", "PipelineRole", "DataAccessPolicy"]
assert "PipelineDelay" in r["Pipeline"]["DependsOn"], r["Pipeline"]["DependsOn"]
print("ok")
EOF'

echo "--- render ECS configs"
docker run --rm -v "$ROOT/deploy:/d:ro" -v "$OUT:/out" python:3.13-slim sh -c 'pip install -q pyyaml 2>/dev/null && python - <<EOF
import yaml
yaml.SafeLoader.add_multi_constructor("!", lambda l, s, n: l.construct_sequence(n) if isinstance(n, yaml.SequenceNode) else l.construct_scalar(n) if isinstance(n, yaml.ScalarNode) else l.construct_mapping(n))
t = yaml.safe_load(open("/d/aws/ecs-fargate.yaml"))
env = t["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"][0]["Environment"]
tmpl, vars = next(e["Value"] for e in env if e["Name"] == "HUD_OTELCOL_CONFIG")
params = {"AWS::Region": "us-east-1", "ExportInterval": "300", "OsisLogsUrl": "https://p.us-east-1.osis.amazonaws.com/p/v1/logs"}
def sub(s):
    for k, v in params.items(): s = s.replace("\${" + k + "}", v)
    return s
for name, on in (("merge", {"Merge"}), ("convert", set()), ("merge-logs", {"Merge", "Logs"}), ("convert-logs", {"Logs"})):
    s = tmpl
    for k, (cond, yes, no) in vars.items(): s = s.replace("\${" + k + "}", sub(yes if cond in on else no))
    open(f"/out/ecs-{name}.yaml", "w").write(sub(s).replace("\${!", "\${"))
EOF'

echo "--- render Helm configs"
for mode in merge convert; do
  extra=(); [ $mode = convert ] && extra=(-f /d/helm/values-convert.yaml)
  docker run --rm -v "$ROOT/deploy:/d:ro" alpine/helm:3.19.0 template hud opentelemetry-collector \
    --repo https://open-telemetry.github.io/opentelemetry-helm-charts --version 0.177.0 \
    -f /d/helm/values.yaml ${extra[@]+"${extra[@]}"} --show-only templates/configmap.yaml \
    | docker run --rm -i mikefarah/yq:4 '.data.relay' > "$OUT/helm-$mode.yaml"
done

echo "--- validate"
for f in "$OUT"/*.yaml; do
  docker run --rm -v "$OUT:/cfg:ro" -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
    -e AWS_REGION=us-east-1 -e MY_POD_IP=0.0.0.0 -e AMP_REMOTE_WRITE_URL=https://example.com/api/v1/remote_write \
    "$IMAGE" validate --config "/cfg/$(basename "$f")"
  echo "ok: $(basename "$f")"
done
has() { grep -q "$1" "$OUT/$2.yaml" || { echo "FAIL: $2 lacks $1"; exit 1; }; }
lacks() { ! grep -q "$1" "$OUT/$2.yaml" || { echo "FAIL: $2 has $1"; exit 1; }; }
# transform/restamp appears on two lines when a pipeline uses it (definition + pipeline), one when only defined
uses_restamp() { [ "$(grep -c 'transform/restamp' "$OUT/$1.yaml")" -ge 2 ]; }
for f in ecs-merge ecs-merge-logs helm-merge; do
  has 'metrics/per_pod' $f; has 'keep_keys' $f; uses_restamp $f || { echo "FAIL: $f doesn't merge"; exit 1; }
done
for f in ecs-convert ecs-convert-logs helm-convert; do ! uses_restamp $f || { echo "FAIL: $f merges"; exit 1; }; done
for f in ecs-merge-logs ecs-convert-logs; do has 'exporters: \[otlp_http/osis\]' $f; done
for f in ecs-merge ecs-convert helm-merge helm-convert; do lacks 'osis' $f; done
echo PASS
