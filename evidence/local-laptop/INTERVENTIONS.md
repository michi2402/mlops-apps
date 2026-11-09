# Local laptop run (2026-09-24) -- interventions and observations

Host: i7-10750H, 15.75 GB RAM, Windows + Docker Desktop (WSL2, .wslconfig memory=12GB).
Node: minikube v1.32.0, --cpus=6 --memory=11g, metrics-server enabled; 8 CPU / 11.68 GiB allocatable.
Revision at start: c793ff6.

## LAP-01 -- 17:36Z -- repository change: MinIO images withdrawn upstream
**What failed:** platform-minio never started: ImagePullBackOff on
quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z ("unauthorized: access to the requested resource
is not authorized"). docker.io/minio/minio no longer exists; quay.io/minio/mc refuses pulls too.
Consequence: lakeFS has no block store, job/lakefs-init fails creating the repositories (HTTP 400),
and no model can be served.
**What was done:** 6d77579 pins docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z and
docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z (Pigsty's builds from MinIO source, same
entrypoint), pushed; Argo CD picked the revision up on its own poll. Nothing applied by hand.

## LAP-OBS-01 -- 17:23Z -- observation: a ComparisonError reads Healthy
platform-external-secrets (and later platform-kfp-crds, platform-mlflow) failed to generate
manifests (repo-server DeadlineExceeded while cloning large upstream Git sources). With no
target state the Application reported Healthy while nothing was deployed, and the next wave
opened. Each recovered on its own within ~4 min, no action taken.

## LAP-OBS-02 -- observation: wave -6 opened while MinIO was not healthy
Same class as CLEAN-OBS-02: the child Application read Healthy briefly after creation, before its
Deployment reported.

## LAP-02 -- 18:00Z -- repository change: KFP's bundled MinIO
KFP's platform-agnostic manifests bundle their own MinIO; the kustomize image override pointed it at
quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z, withdrawn like the platform's (LAP-01).
2decf57 points it at the same Pigsty build. Orchestration components only; the serving path does
not depend on it.

## LAP-OBS-03 -- observation: lakefs-init retried to success
While MinIO was down the hook failed with HTTP 400 on repository creation and crash-looped; once
MinIO ran on the new image the next attempt succeeded (~225 s after the change), and its final log
shows the idempotent path ("already initialised", "already present"). No action taken.

## LAP-03 -- 18:05Z -- bootstrap re-run after convergence timeout
The first run timed out (SYNC_TIMEOUT=2400 s) waiting only on platform-mlflow, whose image
(burakince/mlflow:3.3.2) was still queued: minikube's kubelet pulls images serially, and the
orchestrators' ~20 images were queued ahead of it on a fresh node. platform-mlflow turned Healthy
seconds after the timeout. The script was re-run unchanged (it is idempotent). Candidate fix for
the laptop profile: start minikube with --extra-config=kubelet.serialize-image-pulls=false.

## LAP-OBS-04 -- 18:40Z -- observation: an unhealthy wave blocks an unrelated correction
After 0cabf59 raised Prometheus's request to 512Mi, node requests reached 96 % of allocatable and
the new Prometheus pod stayed Pending. platform-monitoring (wave -8) turned Degraded; the parent's
sync operation (running since 17:22) failed at that wave on every retry (attempt #14 at 18:39),
so the corrected KFP Application in wave -1 (2decf57, KFP's MinIO image) was never applied, although
it is unrelated to monitoring. This is the liveness cost of health-gated waves, observed.
Captured: E61-fitness-blocked.txt.

## LAP-04 / LAP-OBS-05 -- 18:50Z -- capacity restored, the blocked correction arrives unaided
4c4241d lowered three local requests to observed usage (Dask worker/scheduler, Kafka controller),
freeing 640Mi. Those children synced the change themselves; Prometheus was scheduled 32 s after the
push, platform-monitoring turned Healthy at 63 s, and the parent's next retry passed wave -8 and
applied the corrected KFP Application at ~218 s (KFP's MinIO now docker.io/pgsty/minio). No
Argo CD object was touched by hand.
