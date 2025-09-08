#!/usr/bin/env bash
set -euo pipefail

# --- Config (override with env vars) ---
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
PORT="${PORT:-8080}"
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

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
log "Applying Argo CD install manifest"
kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${MANIFEST_URL}"

# --- Wait for the API server pod(s) ---
log "Waiting for argocd-server rollout (timeout 180s)"
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=180s

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

# --- Port-forward (foreground; Ctrl+C to stop) ---
log "Starting port-forward to https://localhost:${PORT} (Ctrl+C to stop)"
log "Tip: login via 'admin' / (password above)."
exec kubectl -n "${ARGOCD_NAMESPACE}" port-forward svc/argocd-server "${PORT}:443"
