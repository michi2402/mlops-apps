#!/usr/bin/env bash
# Provisions the single-node cluster the `minikube` profile is sized for: the local
# counterpart of provisioning the dataLAB cluster, not part of the platform.
#
#   ./scripts/minikube-up.sh            # 6 CPUs, 11 GiB -- a 16 GB laptop, see RUNBOOK.md
#   MINIKUBE_CPUS=8 MINIKUBE_MEMORY=14g ./scripts/minikube-up.sh
#
# Image pulls: a fresh node pulls ~35 GB. The kubelet's default, one pull at a time, queues the
# orchestrators' images ahead of the serving path's (evidence/local-laptop LAP-03); unbounded
# parallel pulls split the bandwidth so far that the 9.9 GB serving runtime took 31 min instead
# of 7 and stalled pulls were cancelled (evidence/local-laptop-clean). Three at a time is set
# through the kubelet configuration file, because maxParallelImagePulls has no command-line
# flag (the kubelet refuses to start with one, evidence/local-laptop-cold).
set -euo pipefail

CPUS="${MINIKUBE_CPUS:-6}"
MEMORY="${MINIKUBE_MEMORY:-11g}"
K8S="${MINIKUBE_K8S_VERSION:-v1.32.0}"
PARALLEL_PULLS="${MINIKUBE_PARALLEL_PULLS:-3}"

log() { printf "\n\033[1;36m[MINIKUBE-UP]\033[0m %s\n" "$*"; }

log "Starting minikube (${CPUS} CPUs, ${MEMORY}, Kubernetes ${K8S})"
minikube start --driver=docker --cpus="$CPUS" --memory="$MEMORY" --disk-size=40g \
  --kubernetes-version="$K8S" --addons=metrics-server

log "Kubelet: parallel image pulls, at most ${PARALLEL_PULLS}"
minikube ssh -- "sudo sed -i '/^serializeImagePulls:/d; /^maxParallelImagePulls:/d' /var/lib/kubelet/config.yaml \
  && printf 'serializeImagePulls: false\nmaxParallelImagePulls: ${PARALLEL_PULLS}\n' | sudo tee -a /var/lib/kubelet/config.yaml >/dev/null \
  && sudo systemctl restart kubelet"
kubectl wait --for=condition=Ready node/minikube --timeout=180s
minikube ssh -- "sudo grep -E '^(serializeImagePulls|maxParallelImagePulls):' /var/lib/kubelet/config.yaml"
log "Node ready"
