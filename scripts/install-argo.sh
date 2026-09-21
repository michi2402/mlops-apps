#!/usr/bin/env bash
set -euo pipefail

# --- Config (override with env vars) ---
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
PORT="${PORT:-8080}"
# Pinned, not the floating "stable" tag — a floating tag is a reproducibility hole
# (the same script run a month apart installs different Argo CD versions).
# Bump deliberately; record the version used in evidence/SUMMARY.md when validating.
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.3}"
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml}"
# Set to a non-empty value to skip the final foreground port-forward — used when
# another script calls this one and needs control back (e.g. bootstrap-k8s-native.sh).
SKIP_PORT_FORWARD="${SKIP_PORT_FORWARD:-}"

log() { printf "\n\033[1;36m[INFO]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR]\033[0m  %s\n" "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

decode_b64() {
  # Cross-platform base64 decode (GNU, BSD/macOS)
  local in="$1"
  if echo -n "$in" | base64 -d >/dev/null 2>&1; then
    echo -n "$in" | base64 -d
  elif echo -n "$in" | base64 --decode >/dev/null 2>&1; then
    echo -n "$in" | base64 --decode
  elif echo -n "$in" | base64 -D >/dev/null 2>&1; then
    echo -n "$in" | base64 -D
  else
    err "Could not decode base64 on this system."
    exit 1
  fi
}

# --- Preflight ---
require_cmd kubectl

log "Checking cluster access..."
kubectl version --client --output=yaml >/dev/null 2>&1 || true
kubectl get ns >/dev/null

# --- Create namespace ---
log "Creating namespace: ${ARGOCD_NAMESPACE} (if not present)"
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- Install Argo CD ---
# Server-side apply is required: the applicationsets.argoproj.io CRD is larger than
# the 256 KB limit for the client-side "last-applied-configuration" annotation, so a
# plain `kubectl apply` fails with "metadata.annotations: Too long".
log "Applying Argo CD install manifest (server-side apply)"
kubectl apply --server-side=true --force-conflicts -n "${ARGOCD_NAMESPACE}" -f "${MANIFEST_URL}"

# --- Enable Applications in tenant namespaces ---
# Tenant Application resources live in the tenant's own namespace rather than in
# `argocd`, so that each AppProject's `sourceNamespaces` binds them to that project
# alone. Without this, a tenant manifest could name `default` and escape its project.
# The controller only honours namespaces listed here, so the list must cover every
# tenant namespace the cluster declares.
TENANT_NAMESPACES="${TENANT_NAMESPACES:-team1,team2}"
log "Enabling Applications in namespaces: ${TENANT_NAMESPACES}"
#
# controller.diff.server.side: the platform Applications sync with ServerSideApply, which
# leaves no last-applied annotation to diff against, so Argo CD's default client-side
# diff counts every field the API server defaults (e.g. four on each ExternalSecret
# remoteRef) as drift. Those Applications then report OutOfSync forever and self-heal
# re-applies them every few minutes, which also removes Sync status as a drift signal.
# Server-side diff dry-runs the apply, so defaults appear on both sides
# (evidence/local E23c: all twelve platform Applications Synced once enabled).
kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cmd-params-cm --type merge \
  -p "{\"data\":{\"application.namespaces\":\"${TENANT_NAMESPACES}\",\"controller.diff.server.side\":\"true\"}}"

# --- Restore health assessment for Application resources ---
# Argo CD stopped assessing the health of argoproj.io/Application resources in v1.8.
# Without it a parent treats every child Application as Healthy the moment it exists,
# so the sync waves of an app-of-apps order creation and nothing else: in the
# 2026-09-18 local run all eight platform waves were created within 17 seconds, and
# kserve (wave -4) synced before cert-manager's (wave -10) CRDs existed
# (evidence/local E21, INT-01/02). This is the check from the Argo CD health
# documentation; with it, each wave waits until the previous one is Healthy.
log "Restoring health assessment for Application resources (sync waves gate on it)"
kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type merge -p "$(cat <<'EOF'
data:
  resource.customizations.health.argoproj.io_Application: |
    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil then
      if obj.status.health ~= nil then
        hs.status = obj.status.health.status
        if obj.status.health.message ~= nil then
          hs.message = obj.status.health.message
        end
      end
    end
    return hs
EOF
)"

kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deploy/argocd-server
kubectl -n "${ARGOCD_NAMESPACE}" rollout restart statefulset/argocd-application-controller

# --- Wait for the API server pod(s) ---
log "Waiting for argocd-server rollout (timeout 180s)"
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=180s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status statefulset/argocd-application-controller --timeout=180s

# --- Fetch initial admin password ---
log "Fetching initial admin password"
# Wait up to ~120s for the secret to appear
attempts=60
while ! kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret >/dev/null 2>&1; do
  attempts=$((attempts - 1))
  if [ "$attempts" -le 0 ]; then
    err "Timed out waiting for argocd-initial-admin-secret"
    exit 1
  fi
  sleep 2
done

b64pass="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')"
ADMIN_PASSWORD="$(decode_b64 "$b64pass")"
log "Initial admin password (user: admin):"
echo "$ADMIN_PASSWORD"
printf "\n"

if [ -n "$SKIP_PORT_FORWARD" ]; then
  log "SKIP_PORT_FORWARD set — not starting a port-forward. Reach the UI later with:"
  log "  kubectl -n ${ARGOCD_NAMESPACE} port-forward svc/argocd-server ${PORT}:443"
  exit 0
fi

# --- Port-forward (foreground; Ctrl+C to stop) ---
log "Starting port-forward to https://localhost:${PORT} (Ctrl+C to stop)"
log "Tip: login via 'admin' / (password above)."
exec kubectl -n "${ARGOCD_NAMESPACE}" port-forward svc/argocd-server "${PORT}:443"
