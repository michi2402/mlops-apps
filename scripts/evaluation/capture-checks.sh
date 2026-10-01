#!/usr/bin/env bash
# The functional checks of the evaluation (thesis, Table "Functional checks").
#
# Run once per evaluation run, right after scripts/bootstrap-k8s-native.sh returned 0, with the
# bootstrap's own transcript passed as BOOTSTRAP_LOG:
#
#   BOOTSTRAP_LOG=evidence/<run>/bootstrap.txt OUT=evidence/<run>/checks \
#   PY=.venv-py310/Scripts/python.exe ./scripts/evaluation/capture-checks.sh
#
# Every check writes its evidence to OUT/<ID>-<name>.txt and ends with one verdict line,
#   RESULT <ID> PASS|FAIL|SKIP  <detail>
# which is also appended to OUT/SUMMARY.txt. The criterion each check enforces is stated in its
# header comment and is the one the thesis states. A check that cannot apply to the cluster
# (C13 on a single node, C16 without the pipeline-produced model) reports SKIP with the reason.
#
# Checks that change something outside the cluster's own reconciliation are opt-in:
#   PROMOTE=1                C21  commits to and pushes the platform repository (then reverts)
#   ROTATE=1 VAULT_NAME=...  C22  writes a new version of one vault secret (then restores it);
#                                 needs `az` logged in to the vault's tenant with the
#                                 Key Vault Secrets Officer role
#   DRAIN=1 [DRAIN_NODE=...] C23  drains one node (then uncordons it); multi-node only
# Everything else undoes what it creates (C4, C5, C14, C15, C18 and the inference traffic).
#
# PY must be the producer environment (scripts/requirements-producer.txt): C10 and C21 load and
# register models with mlflow, scikit-learn and boto3.
set -uo pipefail

: "${BOOTSTRAP_LOG:?path to the bootstrap transcript}"
OUT="${OUT:?output directory}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
PY="${PY:-python3}"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT
log() { printf "\033[1;36m[CHECKS]\033[0m %s\n" "$*"; }
ts() { date -u +%FT%TZ; }
pf() { kubectl -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 & PIDS+=("$!"); }
: > "$OUT/SUMMARY.txt"
# result <ID> <PASS|FAIL|SKIP> <detail> -- appends the verdict to the check's file and the summary
result() { local line; line=$(printf "RESULT %-4s %-4s %s" "$1" "$2" "$3"); echo "$line" | tee -a "$OUT/SUMMARY.txt"; }
# verdict <ID> <file> -- reads the file's "VERDICT <STATUS> <detail>" line (FAIL if there is none)
verdict() { local v; v=$(grep -m1 '^VERDICT ' "$2" 2>/dev/null)
  if [ -z "$v" ]; then echo "VERDICT FAIL check did not complete (see transcript)" >> "$2"; v="VERDICT FAIL check did not complete (see transcript)"; fi
  v=${v#VERDICT }; result "$1" "${v%% *}" "${v#* }"; }

# --- shared fixtures ----------------------------------------------------------------------------
GW_HOST_IRIS="iris-team1-iris.mlops.local"
REQ3='{"inputs":[{"name":"predict","shape":[3,4],"datatype":"FP64","data":[[5.1,3.5,1.4,0.2],[6.2,3.4,5.4,2.3],[5.9,3.0,4.2,1.5]]}]}'
infer() { curl -s -H "Host: $GW_HOST_IRIS" -H "Content-Type: application/json" -d "$REQ3" "$@" http://127.0.0.1:18080/v2/models/iris/infer; }
apps_json() { kubectl get applications.argoproj.io -A -o json; }
secret_field() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null; }
sha() { "$PY" -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])"; }
# Background request loop for the maintenance checks: one request per second, one HTTP code per line.
loop_start() { ( while :; do echo "$(date -u +%s) $(infer -o /dev/null -w '%{http_code}' --max-time 5)"; sleep 1; done ) > "$1" 2>/dev/null & LOOP_PID=$!; PIDS+=("$LOOP_PID"); }
loop_stop() { kill "$LOOP_PID" >/dev/null 2>&1; wait "$LOOP_PID" 2>/dev/null; }
loop_report() { awk '{n++; if ($2!="200") f++} END {printf "%d requests, %d not answered with 200", n, f+0}' "$1"; }
isvc_uri()   { kubectl -n team1-iris get isvc iris -o jsonpath='{.spec.predictor.model.storageUri}' 2>/dev/null; }
isvc_ready() { kubectl -n team1-iris get isvc iris -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }

GW=$(kubectl -n platform-envoy-gateway get svc -o name -l gateway.envoyproxy.io/owning-gateway-name=ingress-gateway)
pf platform-envoy-gateway "$GW" 18080:80
pf platform-monitoring svc/monitoring-kube-prometheus-prometheus 19090:9090
pf platform-monitoring svc/monitoring-grafana 15555:80
pf platform-lakefs svc/lakefs 18000:80
sleep 5
prom() { curl -s --get http://127.0.0.1:19090/api/v1/query --data-urlencode "query=$1"; }
LAKEFS_AK=$(secret_field platform-lakefs platform-lakefs-admin accessKeyID)
LAKEFS_SK=$(secret_field platform-lakefs platform-lakefs-admin secretAccessKey)
NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')

# --- meta ---------------------------------------------------------------------------------------
{ ts; echo "HEAD $(git rev-parse HEAD)"; echo "tag  $(git describe --tags --exact-match 2>/dev/null || echo none)"
  kubectl version 2>/dev/null | tail -1
  kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory,ALLOC_CPU:.status.allocatable.cpu,ALLOC_MEM:.status.allocatable.memory,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
  if command -v minikube >/dev/null 2>&1 && [ "$(kubectl config current-context)" = "minikube" ]; then
    minikube ssh -- "sudo grep -E '^(serializeImagePulls|maxParallelImagePulls):' /var/lib/kubelet/config.yaml" 2>/dev/null
  fi; } > "$OUT/00-meta.txt"

# ================================================================================================
# G1 -- single declarative source of truth
# ================================================================================================

# C1  The serving path converges from the root alone, within 60 min (the bootstrap's SYNC_TIMEOUT).
#     Also recorded: the health of every platform Application at check time.
log "C1 convergence"
{ ts
  CONV=$(sed -n 's/.*Convergence took \([0-9]*\)s.*/\1/p' "$BOOTSTRAP_LOG" | head -1)
  apps_json | CONV="${CONV:-}" "$PY" -c '
import json, os, sys
items = json.load(sys.stdin)["items"]
plat = [a for a in items if a["metadata"].get("labels", {}).get("mlops.tuwien/tier") in ("platform", "orchestration")]
parent = [a for a in items if a["metadata"]["name"] == "platform"]
ok = lambda a: (a.get("status") or {}).get("sync", {}).get("status") == "Synced" and (a.get("status") or {}).get("health", {}).get("status") == "Healthy"
for a in sorted(plat + parent, key=lambda a: a["metadata"]["name"]):
    s = a.get("status") or {}
    print("  %-38s %-10s %s" % (a["metadata"]["name"], s.get("sync", {}).get("status"), s.get("health", {}).get("status")))
conv = os.environ["CONV"]
healthy = sum(ok(a) for a in plat + parent)
print("serving path converged after %s s (bootstrap); %d of %d platform Applications Synced/Healthy" % (conv or "?", healthy, len(plat + parent)))
v = "PASS" if conv and int(conv) <= 3600 else "FAIL"
print("VERDICT %s converged in %s s; %d/%d platform Applications healthy" % (v, conv or "?", healthy, len(plat + parent)))
'; } > "$OUT/C01-convergence.txt"
verdict C1 "$OUT/C01-convergence.txt"

# C2  Sync waves open in their declared order: the first Application of every wave is created no
#     earlier than the first of the wave before it.
log "C2 wave order"
{ ts; apps_json | "$PY" -c '
import json, sys, datetime as dt
p = lambda s: dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
items = json.load(sys.stdin)["items"]
root = next(a for a in items if a["metadata"]["name"].startswith("root-"))
r0 = p(root["metadata"]["creationTimestamp"])
waves = {}
for a in items:
    m = a["metadata"]
    if m.get("labels", {}).get("mlops.tuwien/tier") not in ("platform", "orchestration"):
        continue
    w = int(m.get("annotations", {}).get("argocd.argoproj.io/sync-wave", "0"))
    waves.setdefault(w, []).append(((p(m["creationTimestamp"]) - r0).total_seconds(), m["name"].replace("platform-", "")))
firsts = []
for w in sorted(waves):
    first = min(x[0] for x in waves[w]); firsts.append(first)
    print("wave %3d: created +%5.0f s  %s" % (w, first, ", ".join(n for _, n in sorted(waves[w]))))
ordered = all(b >= a for a, b in zip(firsts, firsts[1:]))
print("VERDICT %s waves %d to %d opened %s" % ("PASS" if ordered else "FAIL", min(waves), max(waves), "in order" if ordered else "OUT OF ORDER"))
'; } > "$OUT/C02-wave-order.txt"
verdict C2 "$OUT/C02-wave-order.txt"

# C3  No custom resource is consumed before the wave that installs its definition.
log "C3 CRD order"
{ ts; "$PY" scripts/preflight/wave-order.py 2>&1 | tail -5; echo "exit=${PIPESTATUS[0]}"; } > "$OUT/C03-crd-order.txt"
if grep -q '^exit=0' "$OUT/C03-crd-order.txt"; then result C3 PASS "$(grep '^checked' "$OUT/C03-crd-order.txt")"
else result C3 FAIL "$(grep -E '^(INVERSION|checked)' "$OUT/C03-crd-order.txt" | tr '\n' ';')"; fi

# C4  An out-of-band change to a declared field is reverted within 120 s.
log "C4 drift: changed field"
#     The field is the tracking server's replica count: a Deployment in every profile (the object
#     store is a Deployment in one and a StatefulSet in the other), and one extra replica is harmless.
{ ts
  declared=$(kubectl -n platform-mlflow get deploy mlflow -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [ -z "$declared" ]; then echo "VERDICT FAIL deploy/mlflow not found in platform-mlflow"
  else
    changed=$(( declared + 1 )); echo "\$ kubectl -n platform-mlflow scale deploy mlflow --replicas=$changed   (declared: $declared)"
    kubectl -n platform-mlflow scale deploy mlflow --replicas="$changed" >/dev/null; s=$(date +%s); r=$changed
    for i in $(seq 1 120); do r=$(kubectl -n platform-mlflow get deploy mlflow -o jsonpath='{.spec.replicas}'); [ "$r" = "$declared" ] && break; sleep 1; done
    if [ "$r" = "$declared" ]; then echo "VERDICT PASS reverted to the declared $declared replica(s) after $(( $(date +%s)-s )) s"
    else echo "VERDICT FAIL not reverted within 120 s (replicas=$r)"; kubectl -n platform-mlflow scale deploy mlflow --replicas="$declared" >/dev/null; fi
  fi; } > "$OUT/C04-drift-field.txt"
verdict C4 "$OUT/C04-drift-field.txt"

# C5  An object the repository declares, deleted out of band, is recreated within 180 s.
#     The object is the object store's ServiceMonitor: managed by the platform, harmless to lose briefly.
log "C5 drift: deleted object"
{ ts
  if kubectl -n platform-minio get servicemonitor minio >/dev/null 2>&1; then
    uid0=$(kubectl -n platform-minio get servicemonitor minio -o jsonpath='{.metadata.uid}')
    echo "\$ kubectl -n platform-minio delete servicemonitor minio"; kubectl -n platform-minio delete servicemonitor minio >/dev/null; s=$(date +%s); uid=""
    for i in $(seq 1 180); do uid=$(kubectl -n platform-minio get servicemonitor minio -o jsonpath='{.metadata.uid}' 2>/dev/null); [ -n "$uid" ] && [ "$uid" != "$uid0" ] && break; sleep 1; done
    if [ -n "$uid" ] && [ "$uid" != "$uid0" ]; then echo "VERDICT PASS recreated after $(( $(date +%s)-s )) s"
    else echo "VERDICT FAIL not recreated within 180 s"; fi
  else echo "VERDICT SKIP servicemonitor/minio not present"; fi; } > "$OUT/C05-drift-deleted.txt"
verdict C5 "$OUT/C05-drift-deleted.txt"

# C6  A full deployment, serving included, leaves the repository unchanged.
log "C6 repository"
{ ts; echo "\$ git status --porcelain -- . ':!evidence'"; changes=$(git status --porcelain -- . ':!evidence'); echo "$changes"
  git fetch -q origin 2>/dev/null; echo "HEAD $(git rev-parse --short HEAD), origin/master $(git rev-parse --short origin/master)"
  if [ -z "$changes" ] && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ]; then echo "VERDICT PASS working tree clean, HEAD = origin/master"
  else echo "VERDICT FAIL working tree changed or HEAD differs from origin/master"; fi; } > "$OUT/C06-repository.txt"
verdict C6 "$OUT/C06-repository.txt"

# C7  Every credential is materialised from the vault at reconciliation time: every ExternalSecret
#     reports Ready (SecretSynced).
log "C7 credentials materialised"
{ ts; kubectl get externalsecrets.external-secrets.io -A -o json | "$PY" -c '
import json, sys
items = json.load(sys.stdin)["items"]
bad = []
for e in items:
    c = {x["type"]: x for x in (e.get("status") or {}).get("conditions", [])}
    r = c.get("Ready", {})
    print("  %-22s %-36s %s %s" % (e["metadata"]["namespace"], e["metadata"]["name"], r.get("status"), r.get("reason")))
    if r.get("status") != "True": bad.append(e["metadata"]["namespace"] + "/" + e["metadata"]["name"])
print("VERDICT %s %d of %d ExternalSecrets synced%s" % ("PASS" if not bad and items else "FAIL", len(items) - len(bad), len(items), (" -- not: " + ", ".join(bad)) if bad else ""))
'; } > "$OUT/C07-credentials-synced.txt"
verdict C7 "$OUT/C07-credentials-synced.txt"

# C8  No credential value in either repository. A secret scanner over the full history if gitleaks
#     is installed; otherwise a pattern search over the tracked files, in which a match counts as a
#     value only if its literal has 16+ characters and mixes letters and digits (key names do not).
log "C8 credential scan"
{ ts
  if command -v gitleaks >/dev/null 2>&1; then
    v=PASS; for r in . ../mlops-eso-azure; do echo "## $r (gitleaks, full history)"
      gitleaks detect --source "$r" --no-banner --redact > "$OUT/.gitleaks" 2>&1 || v=FAIL; tail -3 "$OUT/.gitleaks"; done; rm -f "$OUT/.gitleaks"
    echo "VERDICT $v gitleaks over the full history of both repositories"
  else
    echo "\$ git grep (password|secret|key) followed by a literal of 12+ characters, tracked files of both repositories"
    for r in . ../mlops-eso-azure; do git -C "$r" grep -nIiE "(password|secret|key)[^\n]{0,20}[:=][[:space:]]*[\"']?[A-Za-z0-9/+]{12,}" -- . ':!evidence' 2>/dev/null | sed "s|^|$r: |"; done | "$PY" -c '
import re, sys
hits = [l.rstrip("\n") for l in sys.stdin if l.strip()]
for l in hits: print("  " + l)
def value_like(l):
    m = re.search(r"[:=]\s*[\x22\x27]?([A-Za-z0-9/+]{12,})", l.split(":", 3)[-1])
    v = m.group(1) if m else ""
    return len(v) >= 16 and re.search(r"[0-9]", v) and re.search(r"[A-Za-z]", v)
sus = [l for l in hits if value_like(l)]
print("## matches with a value-like literal (16+ characters, letters and digits):")
for l in sus: print("  " + l)
print("VERDICT %s %d match(es), %s (pattern search, tracked files)" % ("FAIL" if sus else "PASS", len(hits), "%d value-like" % len(sus) if sus else "all key names"))'
  fi; } > "$OUT/C08-credential-scan.txt"
verdict C8 "$OUT/C08-credential-scan.txt"

# C9  A prediction over OIP v2 through the gateway returns the true class of three reference
#     observations (iris samples 1, 149, 62: setosa, virginica, versicolor = 0, 2, 1).
log "C9 prediction"
{ ts; echo "\$ POST /v2/models/iris/infer via the gateway (Host: $GW_HOST_IRIS)"
  body=$(infer -w '\n%{http_code}'); echo "$body"
  echo "$body" | "$PY" -c '
import json, sys
lines = sys.stdin.read().strip().split("\n"); code = lines[-1]
try: data = [int(x) for x in json.loads("\n".join(lines[:-1]))["outputs"][0]["data"]]
except Exception: data = None
ok = code == "200" and data == [0, 2, 1]
print("VERDICT %s HTTP %s, %s (expected [0, 2, 1])" % ("PASS" if ok else "FAIL", code, data))'; } > "$OUT/C09-prediction.txt"
verdict C9 "$OUT/C09-prediction.txt"

# C10 The served model predicts exactly what the promoted artefact predicts outside the cluster, on
#     all 150 iris observations (training-serving parity), and its accuracy on them is recorded.
log "C10 served = promoted predictions"
VERSION=$(kubectl -n team1-iris get isvc iris -o jsonpath='{.spec.predictor.model.storageUri}' | sed -n 's|.*/\([0-9]*\)/*$|\1|p')
{ ts; echo "storageUri $(isvc_uri)"
  LAKEFS_AK="$LAKEFS_AK" LAKEFS_SK="$LAKEFS_SK" PREFIX="main/serving/tracking-quickstart/${VERSION}/" HOST="$GW_HOST_IRIS" "$PY" - <<'EOF'
import json, os, tempfile, urllib.request
import boto3, numpy as np, mlflow.pyfunc
from botocore.config import Config
from sklearn import datasets
s3 = boto3.client("s3", endpoint_url="http://127.0.0.1:18000", aws_access_key_id=os.environ["LAKEFS_AK"],
                  aws_secret_access_key=os.environ["LAKEFS_SK"], region_name="us-east-1",
                  config=Config(s3={"addressing_style": "path"}))
d = tempfile.mkdtemp(); prefix = os.environ["PREFIX"]
for o in s3.list_objects_v2(Bucket="mlflow", Prefix=prefix).get("Contents", []):
    dest = os.path.join(d, o["Key"][len(prefix):]); os.makedirs(os.path.dirname(dest), exist_ok=True)
    s3.download_file("mlflow", o["Key"], dest)
X, y = datasets.load_iris(return_X_y=True)
local = np.asarray(mlflow.pyfunc.load_model(d).predict(X)).ravel().astype(int)
req = {"inputs": [{"name": "predict", "shape": list(X.shape), "datatype": "FP64", "data": X.tolist()}]}
r = urllib.request.Request("http://127.0.0.1:18080/v2/models/iris/infer", json.dumps(req).encode(),
                           {"Host": os.environ["HOST"], "Content-Type": "application/json"})
served = np.asarray(json.load(urllib.request.urlopen(r, timeout=60))["outputs"][0]["data"]).ravel().astype(int)
same = int((served == local).sum())
print("artefact  s3://mlflow/%s (%d files)" % (prefix, len(os.listdir(d))))
print("agreement %d of %d observations; accuracy on the full data set: served %.3f, local %.3f"
      % (same, len(X), (served == y).mean(), (local == y).mean()))
print("VERDICT %s served and local predictions agree on %d of %d observations; accuracy %.3f"
      % ("PASS" if same == len(X) else "FAIL", same, len(X), (served == y).mean()))
EOF
} > "$OUT/C10-serving-parity.txt" 2>&1
grep -q '^VERDICT' "$OUT/C10-serving-parity.txt" || echo "VERDICT FAIL check did not complete (see transcript)" >> "$OUT/C10-serving-parity.txt"
verdict C10 "$OUT/C10-serving-parity.txt"

# C11 The predictor downloads the version promoted for the registry coordinate, through LakeFS: the
#     storageUri is the promoted LakeFS path, a LakeFS commit records name and version for it, and
#     the storage initialiser fetched that path.
log "C11 promoted path through LakeFS"
{ ts; uri=$(isvc_uri); echo "storageUri $uri  ready=$(isvc_ready)"
  echo "\$ lakeFS: commits on mlflow/main"
  commits=$(curl -s -u "$LAKEFS_AK:$LAKEFS_SK" "http://127.0.0.1:18000/api/v1/repositories/mlflow/refs/main/commits?amount=20")
  echo "$commits" | "$PY" -c "
import json,sys
for c in json.load(sys.stdin)['results']: print(' ', c['id'][:12], c['message'], json.dumps(c.get('metadata',{})))"
  echo "\$ storage initializer of the iris predictor"
  init=$(kubectl -n team1-iris logs -l serving.kserve.io/inferenceservice=iris -c storage-initializer --tail=50 2>/dev/null); echo "$init" | tail -3 | cut -c1-200
  rec=$(echo "$commits" | "$PY" -c "
import json,sys
v='$VERSION'
print(any(c.get('metadata',{}).get('model_name')=='tracking-quickstart' and str(c.get('metadata',{}).get('model_version'))==v for c in json.load(sys.stdin)['results']))")
  if [ "$uri" = "s3://mlflow/main/serving/tracking-quickstart/${VERSION}" ] && [ "$rec" = "True" ] && echo "$init" | grep -q "Successfully copied s3://mlflow/main/serving/tracking-quickstart/${VERSION}"; then
    echo "VERDICT PASS version $VERSION: promoted path, recorded by a LakeFS commit, fetched by the initialiser"
  else echo "VERDICT FAIL uri=$uri commit-recorded=$rec"; fi; } > "$OUT/C11-promoted-path.txt"
verdict C11 "$OUT/C11-promoted-path.txt"

# ================================================================================================
# G2 -- environment portability
# ================================================================================================

# C12 The Application layer is identical across profiles; the environment surface is enumerated.
log "C12 parity"
{ ts; timeout 120 "$PY" scripts/preflight/env-parity.py > "$OUT/.parity" 2>&1; rc=$?
  grep -E 'compared|RESULT|overlay files|keys set|base config|surface' "$OUT/.parity"; rm -f "$OUT/.parity"
  if [ $rc -eq 0 ]; then echo "VERDICT PASS Application layer identical; environment surface enumerated"; else echo "VERDICT FAIL env-parity exit $rc"; fi; } > "$OUT/C12-parity.txt"
verdict C12 "$OUT/C12-parity.txt"

# C13 The same definition converges on a multi-node cluster (C1 on a cluster of 2+ nodes), with the
#     event bus's brokers on distinct nodes.
log "C13 multi-node"
{ ts; echo "nodes: $NODES"
  if [ "$NODES" -lt 2 ]; then echo "VERDICT SKIP single-node cluster"
  else
    brokers=$(kubectl -n platform-kafka get pods -l strimzi.io/cluster=platform-kafka,strimzi.io/broker-role=true -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --no-headers)
    echo "brokers:"; echo "$brokers" | sed 's/^/  /'
    nb=$(echo "$brokers" | grep -c .); nn=$(echo "$brokers" | awk '{print $2}' | sort -u | grep -c .)
    if grep -q '^RESULT C1   PASS' "$OUT/SUMMARY.txt" && [ "$nb" -ge 1 ] && [ "$nb" = "$nn" ]; then echo "VERDICT PASS converged on $NODES nodes; $nb brokers on $nn distinct nodes"
    else echo "VERDICT FAIL C1 not passed, or $nb brokers on $nn nodes"; fi
  fi; } > "$OUT/C13-multi-node.txt"
verdict C13 "$OUT/C13-multi-node.txt"

# ================================================================================================
# G3 -- ownership separation
# ================================================================================================

# C14 A tenant Application can neither target a platform namespace nor use another project, and the
#     tenant's own model stays ready.
log "C14 tenant project boundary"
probe() { cat <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: $1, namespace: team1}
spec:
  project: $2
  destination: {server: https://kubernetes.default.svc, namespace: platform-mlflow}
  source: {repoURL: https://github.com/michi2402/mlops-apps, targetRevision: master, path: base/charts/model}
YAML
}
{ ts; probe probe-cross-ns workloads-team1 | kubectl apply -f - >/dev/null; probe probe-escalate default | kubectl apply -f - >/dev/null; sleep 20
  m1=$(kubectl -n team1 get applications.argoproj.io probe-cross-ns -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}')
  m2=$(kubectl -n team1 get applications.argoproj.io probe-escalate -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}')
  echo "## probe-cross-ns"; echo "$m1"; echo "## probe-escalate"; echo "$m2"
  echo "## platform-mlflow afterwards"; kubectl -n platform-mlflow get pods --no-headers | awk '{print "  "$1, $3}'
  rdy=$(isvc_ready); echo "## tenant's own model ready: $rdy"
  kubectl -n team1 delete applications.argoproj.io probe-cross-ns probe-escalate --wait=false >/dev/null
  if echo "$m1" | grep -q 'do not match any of the allowed destinations' && echo "$m2" | grep -q 'not permitted to use project' && [ "$rdy" = "True" ]; then
    echo "VERDICT PASS both probes refused; tenant model ready"
  else echo "VERDICT FAIL a probe was admitted or the tenant model is not ready"; fi; } > "$OUT/C14-tenant-project.txt"
verdict C14 "$OUT/C14-tenant-project.txt"

# C15 A tenant namespace cannot obtain a platform credential from the secret store. Probed with an
#     ExternalSecret in the tenant namespace naming the monitoring administrator's password; the
#     value is never printed, only whether the synchronised Secret equals the platform's.
#     Expected to FAIL at the evaluated revision: one cluster-wide store serves every namespace.
log "C15 tenant secret boundary"
{ ts
  kubectl apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: probe-tenant-escape, namespace: team1}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: azure-keyvault, kind: ClusterSecretStore}
  target: {name: probe-tenant-escape, creationPolicy: Owner}
  data:
    - secretKey: value
      remoteRef: {key: platform-grafana-password}
YAML
  sleep 20
  st=$(kubectl -n team1 get externalsecret probe-tenant-escape -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
  echo "probe ExternalSecret in team1: Ready=$st"
  # Read before the probe is deleted: the synchronised Secret is owned by it and goes with it.
  synced=no; kubectl -n team1 get secret probe-tenant-escape >/dev/null 2>&1 && synced=yes
  got=$(secret_field team1 probe-tenant-escape value | sha); ref=$(secret_field platform-monitoring platform-grafana-secret password | sha)
  echo "synchronised Secret in team1: $synced"
  kubectl -n team1 delete externalsecret probe-tenant-escape --wait=false >/dev/null 2>&1
  if [ -z "$(secret_field platform-monitoring platform-grafana-secret password)" ]; then
    echo "VERDICT FAIL reference secret platform-monitoring/platform-grafana-secret not readable"
  elif [ "$synced" = yes ] && [ "$got" = "$ref" ]; then
    echo "VERDICT FAIL the tenant namespace obtained the platform credential (hashes equal; expected at this revision)"
  else echo "VERDICT PASS the store refused the tenant namespace"; fi; } > "$OUT/C15-tenant-secret.txt"
verdict C15 "$OUT/C15-tenant-secret.txt"

# ================================================================================================
# G4 -- constant per-unit operational cost
# ================================================================================================

# C16 A second model, produced by the pipeline in the cluster, is served in a second tenant through
#     the same chart: its InferenceService is ready and its OIP v2 ready endpoint answers 200.
log "C16 second model"
{ ts
  meta=$(curl -s -u "$LAKEFS_AK:$LAKEFS_SK" "http://127.0.0.1:18000/api/v1/repositories/mlflow/refs/main/commits?amount=50" | "$PY" -c "
import json,sys
for c in json.load(sys.stdin)['results']:
    if c.get('metadata',{}).get('model_name')=='timeseries-model': print(c['id'][:12], json.dumps(c['metadata'])); break")
  if [ -z "$meta" ]; then echo "VERDICT SKIP timeseries-model not promoted (pipeline not run on this cluster)"
  else
    echo "promotion commit: $meta"
    rdy=$(kubectl -n team2-timeseries get isvc timeseries -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: timeseries-team2-timeseries.mlops.local" http://127.0.0.1:18080/v2/models/timeseries/ready)
    echo "InferenceService ready=$rdy; GET /v2/models/timeseries/ready -> $code"
    if [ "$rdy" = "True" ] && [ "$code" = "200" ]; then echo "VERDICT PASS second model served in team2"; else echo "VERDICT FAIL ready=$rdy, HTTP $code"; fi
  fi; } > "$OUT/C16-second-model.txt"
verdict C16 "$OUT/C16-second-model.txt"

# ================================================================================================
# G5 -- composable extension points
# ================================================================================================

# C17 Request and response of one inference arrive under one key in one partition of the retained
#     topic, as a request event and a response event.
log "C17 inference events"
BEFORE=$(date -u +%s)
infer -o /dev/null; sleep 10
{ ts; echo "\$ kcat -C inference-events (records since the request)"
  kubectl -n platform-kafka delete pod kcat-check --ignore-not-found >/dev/null 2>&1
  kubectl -n platform-kafka run kcat-check --restart=Never --image=edenhill/kcat:1.7.1 -- -b platform-kafka-kafka-bootstrap:9092 -t inference-events -C -o beginning -e -f 'KEY=%k PARTITION=%p OFFSET=%o TS=%T TYPE=%h\n' -q >/dev/null 2>&1
  kubectl -n platform-kafka wait --for=jsonpath='{.status.phase}'=Succeeded pod/kcat-check --timeout=120s >/dev/null 2>&1
  kubectl -n platform-kafka logs kcat-check 2>/dev/null | BEFORE=$BEFORE "$PY" -c '
import os, re, sys
rows = []
for l in sys.stdin:
    k = re.search(r"KEY=(\S+) PARTITION=(\d+) OFFSET=(\d+) TS=(\d+)", l); t = re.search(r"ce-type=([^,\s]+)", l, re.I)
    if k and int(k.group(4)) // 1000 >= int(os.environ["BEFORE"]) - 5:
        rows.append((k.group(1), k.group(2), k.group(3), t.group(1) if t else ""))
for r in rows: print("  %s partition %s offset %s %s" % r)
# Judged per key, so traffic of other checks in the window does not matter: every inference
# answered in the window must have exactly one request and one response, in one partition.
# Their offset order is not part of the criterion: the logger posts the two independently.
by = {}
for k, p, o, t in rows: by.setdefault(k, []).append((p, t.rsplit(".", 1)[-1]))
answered = {k: v for k, v in by.items() if any(t == "response" for _, t in v)}
bad = [k for k, v in answered.items() if sorted(t for _, t in v) != ["request", "response"] or len({p for p, _ in v}) != 1]
ok = bool(answered) and not bad
print("VERDICT %s %d answered inference(s) in the window, %d with request and response in one partition"
      % ("PASS" if ok else "FAIL", len(answered), len(answered) - len(bad)))'
  kubectl -n platform-kafka delete pod kcat-check --wait=false >/dev/null; } > "$OUT/C17-inference-events.txt"
grep -q '^VERDICT' "$OUT/C17-inference-events.txt" || echo "VERDICT FAIL no records read" >> "$OUT/C17-inference-events.txt"
verdict C17 "$OUT/C17-inference-events.txt"

# C18 A tenant registers its own scrape target by declaring a monitor in its own namespace, without a
#     platform change: a PodMonitor in team1-iris yields an active target that is up within 300 s.
#     The bound is the configuration path, not the selection: the operator renders the monitor into
#     the Prometheus config Secret at once, but the kubelet delivers a changed Secret volume only on
#     its next sync (about 70 s on dataLAB, beyond 120 s in one run).
log "C18 tenant-declared monitor"
{ ts
  kubectl apply -f - >/dev/null <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata: {name: probe-tenant-monitor, namespace: team1-iris}
spec:
  selector: {matchLabels: {serving.kserve.io/inferenceservice: iris}}
  podMetricsEndpoints:
    - path: /metrics
      interval: 15s
      relabelings:
        - {sourceLabels: [__meta_kubernetes_pod_container_name], regex: kserve-container, action: keep}
        - {sourceLabels: [__meta_kubernetes_pod_ip], targetLabel: __address__, replacement: "\$1:8082"}
YAML
  s=$(date +%s); up=""
  for i in $(seq 1 60); do
    up=$(curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' | "$PY" -c "
import json,sys
print(','.join(t['health'] for t in json.load(sys.stdin)['data']['activeTargets'] if 'probe-tenant-monitor' in t['scrapePool']))")
    echo "$up" | grep -q up && break; sleep 5; done
  echo "target(s) of podMonitor/team1-iris/probe-tenant-monitor: ${up:-none}"
  kubectl -n team1-iris delete podmonitor probe-tenant-monitor --wait=false >/dev/null
  if echo "$up" | grep -q up; then echo "VERDICT PASS tenant-declared target up after $(( $(date +%s)-s )) s"; else echo "VERDICT FAIL no target up within 300 s"; fi; } > "$OUT/C18-tenant-monitor.txt"
verdict C18 "$OUT/C18-tenant-monitor.txt"

# ================================================================================================
# Observability (an expected result, not a design goal)
# ================================================================================================

# C19 Every scrape target is up, except those of models whose InferenceService is not ready; the
#     platform's four dashboards are provisioned in Grafana (rendering is not inspected).
log "C19 targets and dashboards"
GU=$(secret_field platform-monitoring platform-grafana-secret username); GP=$(secret_field platform-monitoring platform-grafana-secret password)
UNREADY=$(kubectl get isvc -A -o json | "$PY" -c "
import json,sys
print(' '.join(i['metadata']['namespace'] for i in json.load(sys.stdin)['items'] if not any(c['type']=='Ready' and c['status']=='True' for c in i.get('status',{}).get('conditions',[]))))")
{ ts; echo "namespaces of unready models: ${UNREADY:-none}"
  curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' | UNREADY="$UNREADY" "$PY" -c '
import json, os, sys
from collections import defaultdict
unready = set(os.environ["UNREADY"].split())
a = defaultdict(lambda: [0, 0, ""]); unexpected = 0; n = u = 0
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    x = a[t["scrapePool"]]; x[0] += 1; n += 1
    if t["health"] == "up": x[1] += 1; u += 1
    else:
        ns = t["labels"].get("namespace", ""); x[2] = ns + ": " + (t.get("lastError") or "")[:60]
        unexpected += ns not in unready
for k, (m, v, e) in sorted(a.items()): print("  %d/%d  %s %s" % (v, m, k, ("  " + e) if e else ""))
print("TARGETS %d/%d up; %d down unexpectedly" % (u, n, unexpected))'
  echo "\$ Grafana dashboards"
  dash=$(curl -s -u "$GU:$GP" 'http://127.0.0.1:15555/api/search?type=dash-db' | "$PY" -c "
import json,sys; d=json.load(sys.stdin); print(len(d), '|', ', '.join(x['title'] for x in d))")
  echo "  $dash"
} > "$OUT/C19-observability.txt"
tl=$(grep '^TARGETS' "$OUT/C19-observability.txt"); down=$(echo "$tl" | sed -n 's/.*; \([0-9]*\) down unexpectedly/\1/p')
miss=""; for t in "CloudNativePG" "cert-manager" "MinIO Dashboard" "Mlflow Dashboard"; do grep -q "$t" "$OUT/C19-observability.txt" || miss="$miss $t"; done
if [ "${down:-1}" = "0" ] && [ -z "$miss" ]; then echo "VERDICT PASS ${tl#TARGETS }; four platform dashboards provisioned" >> "$OUT/C19-observability.txt"
else echo "VERDICT FAIL ${tl#TARGETS }; missing dashboards:${miss:- none}" >> "$OUT/C19-observability.txt"; fi
verdict C19 "$OUT/C19-observability.txt"

# C20 Model-level serving metrics are collected for a served model: the request counter rises by
#     exactly the 20 requests sent, and latency and failure series exist.
log "C20 model metrics"
q='sum(rest_server_requests_total{inferenceservice="iris"})'
val() { prom "$q" | "$PY" -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(int(float(r[0]['value'][1])) if r else 0)"; }
{ ts; b=$(val); for i in $(seq 1 20); do infer -o /dev/null; done; sleep 70; a=$(val)
  echo "rest_server_requests_total{inferenceservice=iris}: before $b, after 20 requests $a"
  series=$(prom 'count by (__name__) ({namespace="team1-iris", __name__=~"model_infer.*|rest_server.*|parallel_request.*"})' | "$PY" -c "
import json,sys; print(' '.join(sorted(x['metric']['__name__'] for x in json.load(sys.stdin)['data']['result'])))")
  echo "series: $series"
  if [ $(( a - b )) -eq 20 ] && echo "$series" | grep -q model_infer_request_duration && echo "$series" | grep -q model_infer_request_failure; then
    echo "VERDICT PASS counter rose by 20 for 20 requests; latency and failure series present"
  else echo "VERDICT FAIL counter rose by $(( a - b )) for 20 requests, or series missing"; fi; } > "$OUT/C20-model-metrics.txt"
verdict C20 "$OUT/C20-model-metrics.txt"

# --- resource snapshot (Section "Workloads" and threats to validity) ---------------------------
log "resource snapshot"
{ ts; kubectl top nodes; kubectl describe nodes | sed -n '/^Name:/p;/Allocated resources/,/ephemeral/p'
  echo "# pods not Running/Completed"; kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
  echo "# OOM kills"; kubectl get events -A --no-headers | grep -ci oomkill
  echo "# Applications"; kubectl get applications.argoproj.io -A -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status --no-headers; } > "$OUT/R-resources.txt"

# ================================================================================================
# Maintenance operations (Day-2) -- last, because they change the running platform
# ================================================================================================

# C21 A model version is promoted by one commit and rolled back by reverting it: after the commit
#     the predictor serves the new version, after the revert the old one, each within 15 min (the
#     controller polls the repository every 3 min); requests keep being sent throughout and the
#     share not answered with 200 is recorded.
log "C21 promotion and rollback by commit"
APPFILE=clusters/base/k8s-native-stack/workloads/team1/apps/iris.yaml
wait_version() {  # $1 version, $2 timeout s -> prints seconds or "timeout"
  local s=$(date +%s)
  while [ $(( $(date +%s) - s )) -lt "$2" ]; do
    [ "$(isvc_uri)" = "s3://mlflow/main/serving/tracking-quickstart/$1" ] && [ "$(isvc_ready)" = "True" ] && \
      [ "$(infer -o /dev/null -w '%{http_code}' --max-time 5)" = "200" ] && { echo $(( $(date +%s) - s )); return 0; }
    sleep 5; done; echo timeout; return 1; }
{ ts
  if [ "${PROMOTE:-0}" != "1" ]; then echo "VERDICT SKIP opt-in (PROMOTE=1): commits to and pushes the platform repository"
  elif [ -n "$(git status --porcelain -- . ':!evidence')" ] || [ "$(git rev-parse --abbrev-ref HEAD)" != "master" ]; then echo "VERDICT SKIP working tree not clean or not on master"
  else
    old=$(sed -n 's/^ *version: "\([0-9]*\)".*/\1/p' "$APPFILE" | head -1)
    pf platform-mlflow svc/mlflow 5000:80; sleep 3
    export MLFLOW_TRACKING_URI=http://127.0.0.1:5000 LAKEFS_ENDPOINT=http://127.0.0.1:18000 LAKEFS_ACCESS_KEY="$LAKEFS_AK" LAKEFS_SECRET_KEY="$LAKEFS_SK"
    new=$("$PY" scripts/mlflow-dummy-model.py 2>&1 | sed -n "s/^Created version '\([0-9]*\)'.*/\1/p" | tail -1)
    echo "registered tracking-quickstart version ${new:-?} (serving $old)"
    "$PY" scripts/promote-model.py --name tracking-quickstart --version "$new" 2>&1 | grep -E 'registry|destination|lakeFS commit'
    loop_start "$OUT/.c21-loop"
    sed -i "s/^\( *version: \)\"$old\"/\1\"$new\"/" "$APPFILE"
    git commit -q -m "Promote tracking-quickstart to version $new (evaluation check C21)" -- "$APPFILE" && git push -q origin master
    echo "commit $(git rev-parse --short HEAD) pushed at $(ts)"
    t1=$(wait_version "$new" 900); echo "version $new served after: $t1 s"
    git revert --no-edit HEAD >/dev/null && git push -q origin master
    echo "revert $(git rev-parse --short HEAD) pushed at $(ts)"
    t2=$(wait_version "$old" 900); echo "version $old served again after: $t2 s"
    loop_stop; LR=$(loop_report "$OUT/.c21-loop"); echo "during both transitions: $LR"; rm -f "$OUT/.c21-loop"
    if [ "$t1" != "timeout" ] && [ "$t2" != "timeout" ]; then echo "VERDICT PASS promoted in ${t1} s, rolled back in ${t2} s; $LR"
    else echo "VERDICT FAIL promotion ${t1}, rollback ${t2}"; fi
  fi; } > "$OUT/C21-promotion.txt"
verdict C21 "$OUT/C21-promotion.txt"

# C22 A credential rotated in the vault reaches its Kubernetes Secret without a commit (forced
#     refresh of the ExternalSecret, within 120 s). Whether the consumer accepts the new value
#     without a restart is recorded, not required. The original value is restored afterwards.
#     The credential is the monitoring administrator's password; values are compared as hashes.
log "C22 credential rotation"
{ ts
  if [ "${ROTATE:-0}" != "1" ] || [ -z "${VAULT_NAME:-}" ]; then echo "VERDICT SKIP opt-in (ROTATE=1 VAULT_NAME=...): writes to the vault"
  else
    KV=platform-grafana-password; ES="-n platform-monitoring externalsecret platform-grafana-secret"
    orig=$(az keyvault secret show --vault-name "$VAULT_NAME" --name "$KV" --query value -o tsv)
    newv=$("$PY" -c "import secrets; print(secrets.token_urlsafe(24))")
    az keyvault secret set --vault-name "$VAULT_NAME" --name "$KV" --value "$newv" -o none; echo "rotated $KV in the vault at $(ts)"
    kubectl annotate $ES force-sync="$(date +%s)" --overwrite >/dev/null; s=$(date +%s); want=$(printf %s "$newv" | sha); got=""
    for i in $(seq 1 24); do got=$(secret_field platform-monitoring platform-grafana-secret password | sha); [ "$got" = "$want" ] && break; sleep 5; done
    if [ "$got" = "$want" ]; then t=$(( $(date +%s) - s )); echo "Secret updated after $t s (no commit)"; else t=timeout; echo "Secret not updated within 120 s"; fi
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$GU:$newv" http://127.0.0.1:15555/api/user)
    echo "consumer (Grafana) accepts the new password without a restart: HTTP $code"
    az keyvault secret set --vault-name "$VAULT_NAME" --name "$KV" --value "$orig" -o none
    kubectl annotate $ES force-sync="$(date +%s)" --overwrite >/dev/null; sleep 20
    [ "$(secret_field platform-monitoring platform-grafana-secret password | sha)" = "$(printf %s "$orig" | sha)" ] && echo "original value restored" || echo "WARNING: original value not yet restored in the Secret"
    unset orig newv
    if [ "$t" != "timeout" ]; then echo "VERDICT PASS reached the Secret in $t s without a commit; consumer without restart: HTTP $code"
    else echo "VERDICT FAIL rotated value did not reach the Secret within 120 s"; fi
  fi; } > "$OUT/C22-rotation.txt"
verdict C22 "$OUT/C22-rotation.txt"

# C23 After one node is drained, every platform Application and the model return to healthy without
#     intervention within 15 min, and every inference answered during the drain left its request
#     event on the bus. The node serving the model is drained unless DRAIN_NODE names another.
log "C23 node drain"
{ ts
  if [ "$NODES" -lt 2 ]; then echo "VERDICT SKIP single-node cluster"
  elif [ "${DRAIN:-0}" != "1" ]; then echo "VERDICT SKIP opt-in (DRAIN=1): drains a node"
  else
    node=${DRAIN_NODE:-$(kubectl -n team1-iris get pods -l serving.kserve.io/inferenceservice=iris -o jsonpath='{.items[0].spec.nodeName}')}
    echo "draining $node; brokers before:"; kubectl -n platform-kafka get pods -l strimzi.io/cluster=platform-kafka,strimzi.io/broker-role=true -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --no-headers | sed 's/^/  /'
    D0=$(date -u +%s); loop_start "$OUT/.c23-loop"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=600s 2>&1 | tail -3; s=$(date +%s); rec=timeout
    while [ $(( $(date +%s) - s )) -lt 900 ]; do
      nh=$(apps_json | "$PY" -c "
import json,sys
print(sum(1 for a in json.load(sys.stdin)['items'] if a['metadata'].get('labels',{}).get('mlops.tuwien/tier')=='platform' and ((a.get('status') or {}).get('health',{}).get('status')!='Healthy')))")
      [ "$nh" = "0" ] && [ "$(isvc_ready)" = "True" ] && [ "$(infer -o /dev/null -w '%{http_code}' --max-time 5)" = "200" ] && { rec=$(( $(date +%s) - s )); break; }
      sleep 10; done
    loop_stop; ok200=$(awk '$2=="200"' "$OUT/.c23-loop" | grep -c .); echo "during the drain: $(loop_report "$OUT/.c23-loop")"; rm -f "$OUT/.c23-loop"
    echo "recovered after drain: $rec s"
    kubectl -n platform-kafka delete pod kcat-drain --ignore-not-found >/dev/null 2>&1
    kubectl -n platform-kafka run kcat-drain --restart=Never --image=edenhill/kcat:1.7.1 -- -b platform-kafka-kafka-bootstrap:9092 -t inference-events -C -o beginning -e -f 'TS=%T TYPE=%h\n' -q >/dev/null 2>&1
    kubectl -n platform-kafka wait --for=jsonpath='{.status.phase}'=Succeeded pod/kcat-drain --timeout=180s >/dev/null 2>&1
    nreq=$(kubectl -n platform-kafka logs kcat-drain 2>/dev/null | D0=$D0 "$PY" -c "
import os,re,sys
print(sum(1 for l in sys.stdin if (m:=re.search(r'TS=(\d+)',l)) and int(m.group(1))//1000>=int(os.environ['D0']) and re.search(r'ce-type=[^,]*request',l,re.I)))")
    kubectl -n platform-kafka delete pod kcat-drain --wait=false >/dev/null
    echo "request events since the drain began: $nreq (answered requests: $ok200, plus the probes of the recovery loop)"
    kubectl uncordon "$node" >/dev/null; echo "uncordoned $node"
    if [ "$rec" != "timeout" ] && [ "${nreq:-0}" -ge "$ok200" ]; then echo "VERDICT PASS recovered in $rec s; $nreq request events for $ok200 answered requests"
    else echo "VERDICT FAIL recovery $rec s; $nreq request events for $ok200 answered requests"; fi
  fi; } > "$OUT/C23-node-drain.txt"
verdict C23 "$OUT/C23-node-drain.txt"

unset LAKEFS_AK LAKEFS_SK GU GP
log "done: $OUT"; echo; cat "$OUT/SUMMARY.txt"
