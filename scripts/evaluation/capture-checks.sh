#!/usr/bin/env bash
# Runs the functional checks of the evaluation against a cluster the bootstrap has just brought up,
# and records each one's output under OUT (one file per check). Run it once, right after
# scripts/bootstrap-k8s-native.sh returned 0, with the bootstrap's own log passed as BOOTSTRAP_LOG.
#
#   BOOTSTRAP_LOG=evidence/<run>/bootstrap.txt OUT=evidence/<run>/checks ./scripts/evaluation/capture-checks.sh
#
# Checks that act on the cluster (C4 drift, C11 probes, C13/C15 inference traffic) undo what they
# create. C10 (multi-node) and C12 (pipeline-produced model) are not local checks.
set -uo pipefail

: "${BOOTSTRAP_LOG:?path to the bootstrap transcript}"
OUT="${OUT:?output directory}"
mkdir -p "$OUT"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
PY="${PY:-python3}"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT
log() { printf "\033[1;36m[CHECKS]\033[0m %s\n" "$*"; }
ts() { date -u +%FT%TZ; }
pf() { kubectl -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 & PIDS+=("$!"); }
REQ='{"inputs":[{"name":"predict","shape":[3,4],"datatype":"FP64","data":[[5.1,3.5,1.4,0.2],[6.2,3.4,5.4,2.3],[5.9,3.0,4.2,1.5]]}]}'
infer() { curl -s -H "Host: iris-team1-iris.mlops.local" -H "Content-Type: application/json" -d "$REQ" "$@" http://127.0.0.1:18080/v2/models/iris/infer; }

GW=$(kubectl -n platform-envoy-gateway get svc -o name -l gateway.envoyproxy.io/owning-gateway-name=ingress-gateway)
pf platform-envoy-gateway "$GW" 18080:80
pf platform-monitoring svc/monitoring-kube-prometheus-prometheus 19090:9090
pf platform-monitoring svc/monitoring-grafana 15555:80
pf platform-lakefs svc/lakefs 18000:80
sleep 5
prom() { curl -s --get http://127.0.0.1:19090/api/v1/query --data-urlencode "query=$1"; }

# --- meta ---------------------------------------------------------------------------------------
{ ts; echo "HEAD $(git rev-parse HEAD)"; echo "tag  $(git describe --tags --exact-match 2>/dev/null || echo none)";
  kubectl version 2>/dev/null | tail -1; kubectl get node -o custom-columns=NODE:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory,ALLOC_MEM:.status.allocatable.memory --no-headers;
  minikube ssh -- "sudo grep -E '^(serializeImagePulls|maxParallelImagePulls):' /var/lib/kubelet/config.yaml" 2>/dev/null; } > "$OUT/00-meta.txt"

# --- C1/C2: convergence and wave order ------------------------------------------------------------
log "C1/C2 convergence and wave order"
kubectl get applications.argoproj.io -n argocd -o json > "$OUT/.apps.json"
T0=$(sed -n 's/.*Start: \([0-9T:-]*Z\).*/\1/p' "$BOOTSTRAP_LOG" | head -1)
CONV=$(sed -n 's/.*Convergence took \([0-9]*\)s.*/\1/p' "$BOOTSTRAP_LOG" | head -1)
T0="$T0" CONV="$CONV" "$PY" - "$OUT/.apps.json" > "$OUT/C01-C02-convergence-waves.txt" <<'EOF'
import json, os, sys, datetime as dt
p = lambda s: dt.datetime.fromisoformat(s.replace('Z', '+00:00'))
apps = json.load(open(sys.argv[1]))['items']
root = next(a for a in apps if a['metadata']['name'].startswith('root-'))
r0 = p(root['metadata']['creationTimestamp'])
t0, conv = p(os.environ['T0']), int(os.environ['CONV'])
done = t0 + dt.timedelta(seconds=conv)
print(f"root applied {r0:%H:%M:%S}Z; platform (tier: platform) Synced/Healthy by {done:%H:%M:%S}Z "
      f"(bootstrap poll, 10 s): {(done - r0).total_seconds():.0f} s after the root")
waves = {}
for a in apps:
    m = a['metadata']
    if m.get('labels', {}).get('mlops.tuwien/tier') not in ('platform', 'orchestration'):
        continue
    w = int(m.get('annotations', {}).get('argocd.argoproj.io/sync-wave', '0'))
    waves.setdefault(w, []).append(((p(m['creationTimestamp']) - r0).total_seconds(), m['name'], m['labels']['mlops.tuwien/tier']))
for w in sorted(waves):
    first = min(x[0] for x in waves[w])
    print(f"wave {w:>3}: created +{first:5.0f} s  " + ", ".join(f"{n.replace('platform-','')}" for _, n, _ in sorted(waves[w])))
EOF

# --- C3: CRD ordering -----------------------------------------------------------------------------
log "C3 wave-order preflight"
{ ts; "$PY" scripts/preflight/wave-order.py 2>&1 | tail -3; } > "$OUT/C03-crd-order.txt"

# --- C4: self-heal --------------------------------------------------------------------------------
log "C4 out-of-band change"
{ ts; echo "\$ kubectl -n platform-minio scale deploy minio --replicas=3"
  kubectl -n platform-minio scale deploy minio --replicas=3 >/dev/null; s=$(date +%s)
  for i in $(seq 1 120); do r=$(kubectl -n platform-minio get deploy minio -o jsonpath='{.spec.replicas}'); [ "$r" = "1" ] && { echo "reverted to the declared 1 replica after $(( $(date +%s)-s )) s"; break; }; sleep 1; done
  [ "$r" = "1" ] || echo "NOT reverted within 120 s (replicas=$r)"; } > "$OUT/C04-self-heal.txt"

# --- C5: repository untouched ---------------------------------------------------------------------
log "C5 repository"
{ ts; echo "\$ git status --porcelain -- . ':!evidence'"; git status --porcelain -- . ':!evidence'; echo "(end; empty = unchanged)";
  echo "HEAD $(git rev-parse --short HEAD), origin/master $(git rev-parse --short origin/master)"; } > "$OUT/C05-repository.txt"

# --- C6: no credential values ---------------------------------------------------------------------
log "C6 credential scan"
{ ts; echo "\$ git grep (password|secret|key) followed by a literal of 12+ characters, both repositories"
  for r in . ../mlops-eso-azure; do echo "## $r"; git -C "$r" grep -nIiE "(password|secret|key)[^\n]{0,20}[:=][[:space:]]*[\"']?[A-Za-z0-9/+]{12,}" -- . ':!evidence' 2>/dev/null; done; } > "$OUT/C06-credentials.txt"

# --- C7: prediction -------------------------------------------------------------------------------
log "C7 prediction"
{ ts; echo "\$ POST /v2/models/iris/infer via the gateway (Host: iris-team1-iris.mlops.local)"; infer -w '\nHTTP %{http_code}\n'; } > "$OUT/C07-prediction.txt"

# --- C8: coordinate -> bytes through lakeFS -------------------------------------------------------
log "C8 lakeFS promotion and fetch"
AK=$(kubectl -n platform-lakefs get secret platform-lakefs-admin -o jsonpath='{.data.accessKeyID}' | base64 -d)
SK=$(kubectl -n platform-lakefs get secret platform-lakefs-admin -o jsonpath='{.data.secretAccessKey}' | base64 -d)
{ ts; echo "\$ lakeFS: commits on mlflow/main"; curl -s -u "$AK:$SK" "http://127.0.0.1:18000/api/v1/repositories/mlflow/refs/main/commits?amount=5" | "$PY" -c "
import json,sys
for c in json.load(sys.stdin)['results']: print(' ', c['id'][:12], c['message'], json.dumps(c.get('metadata',{})))"
  echo "\$ storage initializer of the iris predictor"; kubectl -n team1-iris logs -l serving.kserve.io/inferenceservice=iris -c storage-initializer --tail=4 2>/dev/null | cut -c1-200
  echo "\$ InferenceService"; kubectl -n team1-iris get isvc iris -o jsonpath='{.spec.predictor.model.storageUri}{"  ready="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}'; } > "$OUT/C08-lakefs.txt"
unset AK SK

# --- C9: environment parity -----------------------------------------------------------------------
log "C9 parity"
{ ts; timeout 120 "$PY" scripts/preflight/env-parity.py 2>&1 | grep -E 'compared|RESULT|overlay files|keys set|base config|surface'; } > "$OUT/C09-parity.txt"

# --- C11: tenant boundary -------------------------------------------------------------------------
log "C11 tenant probes"
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
  for a in probe-cross-ns probe-escalate; do echo "## $a"; kubectl -n team1 get applications.argoproj.io $a -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'; done
  echo "## platform-mlflow afterwards"; kubectl -n platform-mlflow get pods --no-headers | awk '{print "  "$1, $3}'
  echo "## tenant's own model"; kubectl -n team1-iris get isvc iris -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
  kubectl -n team1 delete applications.argoproj.io probe-cross-ns probe-escalate --wait=false >/dev/null; } > "$OUT/C11-tenant-boundary.txt"

# --- C13: request/response co-partitioned ----------------------------------------------------------
log "C13 inference events"
BEFORE=$(date -u +%s)
infer -o /dev/null; sleep 10
{ ts; echo "\$ kcat -C inference-events (records of one inference)"
  kubectl -n platform-kafka run kcat-check --restart=Never --image=edenhill/kcat:1.7.1 -- -b platform-kafka-kafka-bootstrap:9092 -t inference-events -C -o beginning -e -f 'KEY=%k PARTITION=%p OFFSET=%o TS=%T TYPE=%h\n' -q >/dev/null 2>&1
  kubectl -n platform-kafka wait --for=jsonpath='{.status.phase}'=Succeeded pod/kcat-check --timeout=120s >/dev/null 2>&1
  kubectl -n platform-kafka logs kcat-check 2>/dev/null | "$PY" -c "
import sys,re
rows=[l for l in sys.stdin if l.startswith('KEY=')]
for l in rows:
    k=re.search(r'KEY=(\S+) PARTITION=(\d+) OFFSET=(\d+) TS=(\d+)',l); t=re.search(r'ce-type=([^,]+)',l,re.I)
    if k and int(k.group(4))//1000 >= $BEFORE-5: print(' ', k.group(1), 'partition', k.group(2), 'offset', k.group(3), t.group(1) if t else '')"
  kubectl -n platform-kafka delete pod kcat-check --wait=false >/dev/null; } > "$OUT/C13-inference-events.txt"

# --- C14: monitors and dashboards -----------------------------------------------------------------
log "C14 targets and dashboards"
GU=$(kubectl -n platform-monitoring get secret platform-grafana-secret -o jsonpath='{.data.username}' | base64 -d)
GP=$(kubectl -n platform-monitoring get secret platform-grafana-secret -o jsonpath='{.data.password}' | base64 -d)
{ ts; curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' | "$PY" -c "
import json,sys
from collections import defaultdict
a=defaultdict(lambda:[0,0,''])
for t in json.load(sys.stdin)['data']['activeTargets']:
    x=a[t['scrapePool']]; x[0]+=1; x[1]+=t['health']=='up'
    if t['health']!='up': x[2]=t['labels'].get('namespace','')+': '+(t.get('lastError') or '')[:60]
for k,(n,u,e) in sorted(a.items()): print(f'  {u}/{n}  {k}', ('  '+e) if e else '')
print('  TOTAL', sum(v[1] for v in a.values()), '/', sum(v[0] for v in a.values()), 'up')"
  echo "\$ Grafana dashboards"; curl -s -u "$GU:$GP" 'http://127.0.0.1:15555/api/search?type=dash-db' | "$PY" -c "
import json,sys
d=json.load(sys.stdin); print('  ', len(d), 'dashboards:', ', '.join(x['title'] for x in d))"; } > "$OUT/C14-monitoring.txt"
unset GU GP

# --- C15: model-level metrics ---------------------------------------------------------------------
log "C15 model metrics"
q='sum(rest_server_requests_total{inferenceservice="iris"})'
{ ts; b=$(prom "$q" | "$PY" -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)")
  for i in $(seq 1 20); do infer -o /dev/null; done; sleep 70
  a=$(prom "$q" | "$PY" -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)")
  echo "rest_server_requests_total{inferenceservice=iris}: before $b, after 20 requests $a"
  prom 'count by (__name__) ({namespace="team1-iris", __name__=~"model_infer.*|rest_server.*|parallel_request.*"})' | "$PY" -c "
import json,sys; print('  series:', ', '.join(sorted(x['metric']['__name__'] for x in json.load(sys.stdin)['data']['result'])))"; } > "$OUT/C15-model-metrics.txt"

# --- resources ------------------------------------------------------------------------------------
log "resource snapshot"
{ ts; kubectl top node; kubectl describe node minikube | sed -n '/Allocated resources/,/ephemeral/p'
  echo "# pods not Running/Completed"; kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
  echo "# OOM kills"; kubectl get events -A --no-headers | grep -ci oomkill
  echo "# Applications"; kubectl get applications.argoproj.io -A -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status --no-headers; } > "$OUT/R-resources.txt"

rm -f "$OUT/.apps.json"
log "done: $OUT"
