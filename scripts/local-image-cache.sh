#!/usr/bin/env bash
# Host-side image cache for the minikube profile -- for iterating, not for evidence.
#
#   save   copy every image the running node holds (minus minikube's own control-plane
#          images, which its preload supplies) to tarballs on the host
#   load   load those tarballs into a freshly started node, before the bootstrap
#   list   show what is cached
#
# Why: a cold node downloads ~35 GB of images (the MLServer runtime alone is 9.9 GB), which
# makes each clean retry cost the better part of an hour (evidence/local-laptop-clean).
#
# Why not for evidence: a cache hides what the evaluation must see. It would have kept
# serving the MinIO images upstream withdrew (evidence/local-laptop LAP-01), and it removes
# the pull time from every convergence and time-to-serve figure. The acceptance run is
# always a cold one: `minikube delete --purge`, then no `load`.
#
# The cache lives outside the repository (default ~/.cache/mlops-images, override with
# IMAGE_CACHE_DIR) and survives `minikube delete`; `--purge` does not touch it either.
set -euo pipefail

CACHE="${IMAGE_CACHE_DIR:-$HOME/.cache/mlops-images}"
# minikube's control plane and addons, provided by its preload tarball
CORE='^registry\.k8s\.io/(kube-(apiserver|controller-manager|scheduler|proxy)|etcd|pause|coredns/|metrics-server/)|^gcr\.io/k8s-minikube/|<none>'

log() { printf "\033[1;36m[IMAGE-CACHE]\033[0m %s\n" "$*"; }
file_for() { printf '%s/%s.tar' "$CACHE" "$(printf '%s' "$1" | tr '/:@' '___')"; }

case "${1:-}" in
  save)
    mkdir -p "$CACHE"
    minikube ssh -- "docker images --format '{{.Repository}}:{{.Tag}}'" | tr -d '\r' \
      | grep -v -E "$CORE" | sort -u > "$CACHE/images.txt"
    log "$(wc -l < "$CACHE/images.txt") images to cache in $CACHE"
    while read -r img; do
      f="$(file_for "$img")"
      if [ -s "$f" ]; then log "cached   $img"; continue; fi
      log "saving   $img"
      minikube image save "$img" "$f"
    done < "$CACHE/images.txt"
    log "done: $(du -sh "$CACHE" | cut -f1) on disk"
    ;;
  load)
    [ -s "$CACHE/images.txt" ] || { echo "no cache at $CACHE -- run '$0 save' on a converged node first" >&2; exit 1; }
    while read -r img; do
      f="$(file_for "$img")"
      [ -s "$f" ] || { log "missing  $img (will be pulled)"; continue; }
      log "loading  $img"
      minikube image load "$f"
    done < "$CACHE/images.txt"
    ;;
  list)
    cat "$CACHE/images.txt" 2>/dev/null || echo "empty"
    ;;
  *)
    echo "usage: $0 save|load|list" >&2; exit 2 ;;
esac
