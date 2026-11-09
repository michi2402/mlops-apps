# dataLAB run — 2026-10-01

Revision: `e85054c` (master, pushed). Profile: `CLUSTER_ENV=datalab`.
Cluster: Azimuth/OpenStack, Kubernetes v1.36.2, Calico, containerd 2.3.2,
3 control-plane nodes (4 vCPU / 16 GiB) + 3 workers (8 vCPU / 32 GiB), default
StorageClass `csi-cinder`. No Azimuth monitoring / cert-manager add-ons. → `E00`.

> `bootstrap.txt` prints the Argo CD admin password — redact before publishing.

## Timeline (UTC)

| | |
|---|---|
| 09:26 | `bootstrap-k8s-native.sh` started |
| +623 s | platform tier (12 Applications) Synced/Healthy |
| +931 s | `iris` InferenceService Ready — bootstrap exit 0, **no intervention** |
| 09:47 | ml-pipelines: data bootstrap (500 entities, 336 000 rows, lakeFS commit `2cac4c1f…`), TrainingRuntime applied, KFP run submitted |
| ~10:01 | KFP run `k8s-native-ml-e2e` **SUCCEEDED** (Spark → tsfresh/Dask → Katib 10/10 trials → 2-node TrainJob → MLflow registry → evaluation) |
| 10:02 | `promote-model.py --name timeseries-model --version 1` → `s3://mlflow/main/serving/timeseries-model/1`, lakeFS commit `5a068328…`, request 5×783 |
| 10:04 | team2 storage initializer downloads the artefact through lakeFS (`E17`) |
| 10:07– | team2 predictor crash-loops: `TypeError: code expected at most 16 arguments, got 18` (`E17`) |

## Observations

- **OBS-DL-01 — transient `Degraded` on `platform-kfp-crds`.** At 09:36 Argo CD reported the
  `applications.app.k8s.io` CRD as "CRD is not established" and the Application `Degraded`;
  the CRD itself was `Established=True`. The health cleared to `Healthy` by itself within
  ~3 min and the later waves proceeded. Orchestration tier, not waited on by the bootstrap.
  No intervention.
- **OBS-DL-02 — distributed training spans nodes.** The two `TrainJob` workers ran on
  different workers (`…czg6g`, `…mxvmh`).
- Katib best trial `h-4f59fd-spxtpbpq`: `val_acc` 0.775 (lr 0.0428, epochs 9, batch 193,
  hidden 162). Final training `val_acc` 0.7375. Trainer torch 2.14.0+cpu, MLflow run
  `04107095d6b34e65b4085a1cf78b61ff`.

## Findings

- **FINDING-DL-01 = F75 reproduced on the cluster (`E17`).** The pipeline-produced PyTorch model
  cannot be loaded by the serving runtime. Trainer image `ghcr.io/julianzeilinger/trainer:main`
  is `python:3.11-slim`; `ScaledMLP`/`MLP` live in `train.py`'s `__main__`, so cloudpickle stores
  them by value with 3.11 code objects; KServe v0.15's `seldonio/mlserver:1.5.0` is Python 3.10.
  The download through lakeFS succeeds (the serving path works); the load fails. Exactly the
  pre-flight diagnosis of VALIDATION_CAMPAIGN.md §3 P2. No MLServer release ships Python 3.11
  (newest: 1.7.2-rc1, still 3.10), so the remedy is producer-side.
  - **Remedy prepared, not applied:** `ml-pipelines` `k8s-native-stack/docker/trainer/Dockerfile`
    → `FROM python:3.10-slim` (uncommitted, companion repository). Requires an image rebuild and
    push to `ghcr.io/julianzeilinger/trainer:main` (`build_docker.sh`, needs the GHCR PAT), then a
    new pipeline run → `timeseries-model` version 2, and `version: "2"` in
    `clusters/base/k8s-native-stack/workloads/team2/apps/timeseries.yaml` (one commit) — or
    re-promote over version 1 with `--force`.

  - **Resolved 2026-10-01 ~11:04.** On `ml-pipelines` branch `fix/trainer-py310` (pushed; `main`
    untouched): trainer on `python:3.10-slim`, `torch==2.2.1`, `numpy<2` — the serving runtime's
    interpreter and framework versions (`mlserver:1.5.0`: Python 3.10.12, torch 2.2.1, NumPy
    1.26.4). Checked offline with `scripts/preflight` before pushing (pytorch and sklearn flavours
    both load and predict in `mlserver:1.5.0`). Published as `ghcr.io/julianzeilinger/trainer:py310`
    and `:0cfafe4`; `:main` unchanged. The branch points the components and the TrainingRuntime
    at `:py310`.
- **FINDING-DL-02 — re-running the data bootstrap aborted** (`E40-FAIL-rerun-empty-commit.txt`):
  the generator is deterministic, so the second run had nothing to commit and lakeFS answered 400
  `commit: no changes`. Fixed on the same branch (treated as success, like `lakefs_commit`).
- **FINDING-DL-03 — the derived request did not fit a column signature**
  (`E09b-FAIL-inference-timeseries-tensor-payload.txt`, HTTP 500 "Failed to enforce schema"):
  `promote-model.py --write-request` sent a single [5, 783] tensor; the pipeline's model has a
  DataFrame signature with 783 named features. Fixed in `mlops-apps` `8b8e550`: one OIP input per
  column plus `content_type: pd`; tensor examples (iris) unchanged. Same commit: an
  already-promoted version still yields its request, and lakeFS's `commit: no changes` is
  recognised on `--force` re-runs.

## Team2, after the fix

| UTC | |
|---|---|
| 10:46–10:58 | KFP run `3eb5d666…` SUCCEEDED (TrainJob again on two workers) → `timeseries-model` v2, MLflow run `f1009ecd…` |
| 10:59:05 | promoted v2 → `s3://mlflow/main/serving/timeseries-model/2`, lakeFS commit `70c4aa12…` (`E12c`) |
| 10:59:25 | `mlops-apps` `4cb1c95`: `version: "1"` → `"2"` in team2's manifest, pushed — the whole promotion event |
| +255 s | Argo CD picked up the revision (polling), predictor spec at `/2` |
| +276 s | `timeseries` InferenceService Ready (`E15`) |
| 11:05 | gateway inference HTTP 200, 5 rows, 2 logits each (`E09b`); iris HTTP 200 (`E09`) |
| 11:06 | `inference-events`: request + response of each answered inference under one key, one partition; the 500 has a request event only (`E10`) |

## Checks run 1 (`checks/`, revision `8b8e550`, 11:08–11:47) — NOT the reported column

PASS C1–C14, C16, C19–C22; FAIL C17, C18, C23; C15 reported PASS falsely.

- **C15 false PASS (check defect).** The probe ExternalSecret in `team1` became `Ready=True
  SecretSynced` — the tenant *did* obtain `platform-grafana-password`. The check deletes the probe
  before testing that the synchronised Secret exists; owner GC removes it in between, so "absent"
  read as PASS. The true result is the expected FAIL.
- **C17 FAIL (check defect).** Two inferences fell in the window; each key had exactly one request
  and one response in one partition (criterion met). Also seen: for one key the response precedes
  the request in offset order — the logger posts the two events independently.
- **C18 FAIL — no target at all** for the tenant PodMonitor within 120 s although the Prometheus
  selectors are open (`{}`) and the Prometheus is Reconciled. To be diagnosed.
- **C22 detail.** The rotated value reached the Secret in 6 s without a commit, but Grafana still
  rejected it (HTTP 401): the consumer reads the credential at start-up only.
- **C23 FAIL — FINDING-DL-04.** Draining the iris node (`…mxvmh`): broker-2 stayed Pending,
  "2 node(s) didn't match pod topology spread constraints" (`C23-broker-pending-reason.txt`).
  The datalab profile's `DoNotSchedule` spread with the default `nodeTaintsPolicy: Ignore` counts
  the cordoned node as a zero-broker domain. Strimzi's PDB `platform-kafka-kafka` (minAvailable 5
  of 6) then refused to evict controller-5, so the drain itself timed out after 10 min.
  `platform-kafka` Degraded for the whole 15-min window. Kafka kept serving (2/3 brokers, min ISR
  2): 1194 request events for 1166 answered requests — no answered inference lost its event.
  36 of 1202 requests during the drain were not answered with 200: one predictor replica.
  Remedy: `nodeTaintsPolicy: Honor` on the controller and broker spread constraints.

## Fixes after checks run 1 (`mlops-apps` `115c072`, pushed 11:59)

- C4 drifts `deploy/mlflow` (C4 had been a **false PASS** here: `deploy/minio` does not exist in the
  datalab profile, empty compared with empty). C15 reads before deleting the probe. C17 judges per
  key. C18 waits 300 s — diagnosed live: PodMonitor created 11:52:54, rendered into the config
  Secret at once, Prometheus reload 11:53:59, target up 11:54:03 (~70 s, kubelet Secret-volume sync).
- `nodeTaintsPolicy: Honor` on both Kafka pools (datalab surface 42 → 44 keys; thesis §12.2 G2
  updated). Verified live at 12:07: drain of `…mxvmh` returned after 44 s (was: 10-min timeout),
  broker-2 rescheduled to `…czg6g` and Ready ~75 s after the drain began, Kafka Ready, Argo Healthy.
- team2 back to `version: "1"` for a fresh cluster.

## Pending

- `scripts/evaluation/capture-checks.sh` for the dataLAB column, started 11:08 with
  `PROMOTE=1 ROTATE=1 DRAIN=1` → `checks/`. Drain target: the iris node (`…mxvmh`, one MinIO pod).
  Expectation recorded before the run: the evicted Kafka broker may stay Pending while its node is
  cordoned (`DoNotSchedule`, default `nodeTaintsPolicy: Ignore`).
