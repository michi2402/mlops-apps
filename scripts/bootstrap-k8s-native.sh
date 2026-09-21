#!/usr/bin/env bash
# Takes a bare cluster to a served, queryable model on the k8s-native-stack, in one run.
# Idempotent: safe to re-run against a cluster this script already bootstrapped.
#
# Required env vars:
#   CLUSTER_ENV                — which environment profile to deploy: minikube | datalab.
#                                 There is no default on purpose. The profiles differ in
#                                 event-bus topology, replica counts and storage, and
#                                 deploying the wrong one is the kind of mistake that is
#                                 only obvious an hour later.
#   CLIENT_ID, CLIENT_SECRET   — Azure Key Vault service-principal creds (tofu output
#                                 from ../mlops-eso-azure), used to seed the one
#                                 out-of-band secret ESO needs.
#
# Optional env vars (defaults match the repo's k8s-native-stack):
#   REPO_ROOT        — path to mlops-apps checkout (default: script's parent dir)
#   STACK_DIR         — stack directory name (default: k8s-native-stack)
#   SYNC_TIMEOUT      — seconds to wait for all ArgoCD Applications Healthy (default: 1200)
#   INFERENCE_TIMEOUT — seconds to wait for the iris InferenceService Ready (default: 600)
#   PYTHON            — interpreter for the model scripts (default: python3). Must carry
#                       scripts/requirements-producer.txt; checked before anything is applied.
#
# This script never writes to Git. The workload manifests name a model by registry
# name and version (see base/charts/model/values.yaml); scripts/promote-model.py
# materialises that name in lakeFS. Nothing here has to rewrite a manifest, so the
# repository state is independent of any cluster run.
set -euo pipefail

log() { printf "\n\033[1;36m[BOOTSTRAP]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR]\033[0m  %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_cmd kubectl
require_cmd python3
require_cmd curl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
STACK_DIR="${STACK_DIR:-k8s-native-stack}"
: "${CLUSTER_ENV:?CLUSTER_ENV is required — one of: minikube, datalab}"
STACK_PATH="clusters/envs/${CLUSTER_ENV}/${STACK_DIR}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-1200}"
INFERENCE_TIMEOUT="${INFERENCE_TIMEOUT:-600}"

PYTHON="${PYTHON:-python3}"

# The producer environment is checked before anything is applied: a model registered
# under NumPy >= 2 downloads fine and then crash-loops in the serving runtime, which is
# an hour into the run and looks like a serving fault.
"$PYTHON" -c 'import sys, numpy, sklearn, mlflow, boto3, requests
sys.exit(int(numpy.__version__.split(".")[0]) >= 2)' 2>/dev/null \
  || die "PYTHON=${PYTHON} is not a producer environment (needs NumPy < 2, scikit-learn, mlflow, boto3, requests).
See scripts/requirements-producer.txt"

: "${CLIENT_ID:?CLIENT_ID is required (tofu output -raw client_id in ../mlops-eso-azure)}"
: "${CLIENT_SECRET:?CLIENT_SECRET is required (tofu output -raw client_secret in ../mlops-eso-azure)}"

cd "$REPO_ROOT"
[ -f "${STACK_PATH}/aoa-root.yaml" ] || die "No such environment profile: ${STACK_PATH}
Available: $(ls -1 clusters/envs 2>/dev/null | tr '
' ' ')
(run from the mlops-apps root, and set CLUSTER_ENV)"

PORT_FORWARD_PIDS=()
cleanup() {
  for pid in "${PORT_FORWARD_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

T0=$(date -u +%s)
log "Start: $(date -u -d "@${T0}" +%FT%TZ 2>/dev/null || date -u +%FT%TZ)"

# --- 1/7: seed the one out-of-band credential (S1) ---
log "1/7 Seeding external-secrets credential"
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
if kubectl -n external-secrets get secret azure-sp-secret >/dev/null 2>&1; then
  log "azure-sp-secret already present — leaving it as-is"
else
  kubectl -n external-secrets create secret generic azure-sp-secret \
    --from-literal=ClientID="$CLIENT_ID" \
    --from-literal=ClientSecret="$CLIENT_SECRET"
fi

# --- 2/7: install Argo CD (S2 step 1) ---
log "2/7 Installing Argo CD"
SKIP_PORT_FORWARD=1 "${SCRIPT_DIR}/install-argo.sh"

# --- 3/7: apply the stack root Application (S2 step 2) ---
log "3/7 Applying ${STACK_PATH}/aoa-root.yaml (profile: ${CLUSTER_ENV})"
kubectl apply -f "${STACK_PATH}/aoa-root.yaml"

# --- 4/7: wait for the platform tier to converge ---
# Only `platform` and its `platform-*` children are waited on. workloads-team1-iris names
# a model that does not exist yet on a fresh cluster, and workloads-team2-timeseries one
# only the orchestrated KFP pipeline produces. Since install-argo.sh restores health
# assessment for Application resources, that unmet declaration propagates upward --
# to the workloads-* parents and to root-<env> -- which is correct reporting, but would
# make this wait time out on every fresh cluster if they were included.
log "4/7 Waiting up to ${SYNC_TIMEOUT}s for the platform tier to be Synced/Healthy"
deadline=$(( $(date -u +%s) + SYNC_TIMEOUT ))
while true; do
  json="$(kubectl get applications.argoproj.io -n argocd -o json)"
  total="$(echo "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')"
  not_ready="$(echo "$json" | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
bad = [i["metadata"]["name"] for i in items
       if (i["metadata"]["name"] == "platform" or i["metadata"]["name"].startswith("platform-"))
       and (i.get("status", {}).get("sync", {}).get("status") != "Synced"
            or i.get("status", {}).get("health", {}).get("status") != "Healthy")]
print(" ".join(bad))
')"
  if [ -z "$not_ready" ]; then
    log "Platform tier Synced/Healthy (${total} Application objects in -n argocd total)"
    break
  fi
  if [ "$(date -u +%s)" -ge "$deadline" ]; then
    err "Timed out after ${SYNC_TIMEOUT}s waiting on: ${not_ready}"
    for app in $not_ready; do
      # Fully qualified: KFP installs a second `Application` kind (applications.app.k8s.io),
      # and the short name resolves to that one.
      echo "--- kubectl describe applications.argoproj.io -n argocd ${app} ---"
      kubectl describe applications.argoproj.io -n argocd "$app" || true
    done
    die "Convergence failed — see descriptions above. Not proceeding to model registration."
  fi
  sleep 10
done
T1=$(date -u +%s)
log "Convergence took $(( T1 - T0 ))s"

# --- 5/7: initialise lakeFS ---
# MLflow's artifact root is the lakeFS repository `mlflow` on branch `main`. A fresh
# lakeFS has neither an admin nor any repository, so artifact upload would fail with
# no obvious cause. The admin keys are exactly the ones ESO already materialised from
# the Key Vault, so lakeFS ends up agreeing with every client that reads that secret.
log "5/7 Initialising lakeFS (admin + repositories)"
kubectl -n platform-mlflow rollout status deploy/mlflow --timeout=300s >/dev/null 2>&1 || true
LAKEFS_ACCESS_KEY="$(kubectl -n platform-mlflow get secret platform-lakefs-secret -o jsonpath='{.data.accessKeyID}' | base64 -d)"
LAKEFS_SECRET_KEY="$(kubectl -n platform-mlflow get secret platform-lakefs-secret -o jsonpath='{.data.secretAccessKey}' | base64 -d)"
[ -n "$LAKEFS_ACCESS_KEY" ] && [ -n "$LAKEFS_SECRET_KEY" ]   || die "lakeFS credentials not materialised — is the external-secrets tier Healthy?"
export LAKEFS_ACCESS_KEY LAKEFS_SECRET_KEY

kubectl -n platform-lakefs port-forward svc/lakefs 18000:80 >/tmp/lakefs-pf.log 2>&1 &
PORT_FORWARD_PIDS+=("$!")
export LAKEFS_ENDPOINT="http://127.0.0.1:18000"
for i in $(seq 1 30); do
  curl -sf "${LAKEFS_ENDPOINT}/api/v1/healthcheck" >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && die "lakeFS port-forward never became reachable (see /tmp/lakefs-pf.log)"
  sleep 2
done

state="$(curl -sf "${LAKEFS_ENDPOINT}/api/v1/setup_lakefs" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || echo "")"
if [ "$state" != "initialized" ]; then
  log "  lakeFS not yet set up — creating the admin user"
  curl -sf -X POST "${LAKEFS_ENDPOINT}/api/v1/setup_lakefs" -H 'Content-Type: application/json'     -d "{\"username\":\"admin\",\"key\":{\"access_key_id\":\"${LAKEFS_ACCESS_KEY}\",\"secret_access_key\":\"${LAKEFS_SECRET_KEY}\"}}"     >/dev/null || die "lakeFS setup failed"
else
  log "  lakeFS already initialised"
fi

# `mlflow/main` backs the artifact root; `datasets/dev` is where the orchestrated
# pipeline stages raw, curated and feature data. Creating both here means the
# pipeline needs no separate platform bootstrap.
for spec in "mlflow:main" "datasets:dev"; do
  repo="${spec%%:*}"; branch="${spec##*:}"
  code="$(curl -s -o /tmp/lakefs-repo.json -w '%{http_code}' -X POST "${LAKEFS_ENDPOINT}/api/v1/repositories"     -u "${LAKEFS_ACCESS_KEY}:${LAKEFS_SECRET_KEY}" -H 'Content-Type: application/json'     -d "{\"name\":\"${repo}\",\"storage_namespace\":\"s3://lakefs/${repo}\",\"default_branch\":\"${branch}\"}")"
  case "$code" in
    201) log "  created lakeFS repository ${repo} (branch ${branch})" ;;
    409) log "  lakeFS repository ${repo} already present" ;;
    *)   cat /tmp/lakefs-repo.json; die "creating lakeFS repository ${repo} failed (HTTP ${code})" ;;
  esac
done

# --- 6/7: register the demonstration model and promote it ---
log "6/7 Registering demo model in MLflow"
kubectl -n platform-mlflow port-forward svc/mlflow 5000:80 >/tmp/mlflow-pf.log 2>&1 &
PORT_FORWARD_PIDS+=("$!")
export MLFLOW_TRACKING_URI="http://127.0.0.1:5000"
for i in $(seq 1 30); do
  curl -sf "${MLFLOW_TRACKING_URI}/health" >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && die "MLflow port-forward never became reachable (see /tmp/mlflow-pf.log)"
  sleep 2
done

"$PYTHON" "${SCRIPT_DIR}/mlflow-dummy-model.py"

# The manifest already names `tracking-quickstart` version 1. Promotion copies that
# version to the location the manifest names — no manifest is edited, nothing is
# committed, and the Git state stays independent of this run.
log "Promoting tracking-quickstart to its serving location in lakeFS"
"$PYTHON" "${SCRIPT_DIR}/promote-model.py" --name tracking-quickstart --version 1   --write-request /tmp/iris-request.json

# --- 7/7: wait for the model to serve ---
log "7/7 Waiting up to ${INFERENCE_TIMEOUT}s for workloads-team1-iris to serve the model"
deadline=$(( $(date -u +%s) + INFERENCE_TIMEOUT ))
while true; do
  sync="$(kubectl -n team1 get application workloads-team1-iris -o jsonpath='{.status.sync.status}' 2>/dev/null || echo '')"
  health="$(kubectl -n team1 get application workloads-team1-iris -o jsonpath='{.status.health.status}' 2>/dev/null || echo '')"
  ready="$(kubectl -n team1-iris get inferenceservice iris -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '')"
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && [ "$ready" = "True" ]; then
    log "InferenceService iris is Ready"
    break
  fi
  if [ "$(date -u +%s)" -ge "$deadline" ]; then
    err "Timed out after ${INFERENCE_TIMEOUT}s (app sync=${sync} health=${health}, inferenceservice ready=${ready})"
    kubectl -n team1-iris get inferenceservice,pod || true
    kubectl -n team1-iris logs -l serving.kserve.io/inferenceservice=iris -c storage-initializer --tail=50 2>/dev/null || true
    kubectl -n team1-iris logs -l serving.kserve.io/inferenceservice=iris -c kserve-container --tail=50 2>/dev/null || true
    die "Model never became servable — see output above."
  fi
  sleep 10
done

T2=$(date -u +%s)
log "Done in $(( T2 - T0 ))s total ($(( T1 - T0 ))s to converge, $(( T2 - T1 ))s to serve)"

cat <<EOF

Model is serving. If the gateway has no external address (local cluster), first run:
  minikube tunnel

Then query it (Host header pattern: <inference-service>-<namespace>.mlops.local):

  curl -s -H "Host: iris-team1-iris.mlops.local" -H "Content-Type: application/json" \
    -d @/tmp/iris-request.json \
    http://127.0.0.1:80/v2/models/iris/infer | jq .

The second tenant workload, workloads-team2-timeseries, names a model the
orchestrated KFP pipeline produces (see the ml-pipelines repository). Run the
pipeline, then:

  python3 scripts/promote-model.py --name timeseries-model --version 1

and it becomes servable with no further change to this repository.

EOF
