# dataLAB clean run — 2026-10-01 (the reported dataLAB column)

Revisions: `mlops-apps` `115c072` (master, pushed; C6 PASS); `ml-pipelines` branch
`fix/trainer-py310` `071bb08` (trainer image `ghcr.io/julianzeilinger/trainer:py310`).
Profile `CLUSTER_ENV=datalab`. Fresh Azimuth cluster `mlops-k8s-native-temp`: Kubernetes v1.36.2,
Calico, 3 control-plane nodes (4 vCPU / 16 GiB) + 3 workers (8 vCPU / 32 GiB), `csi-cinder`
default StorageClass (`E00`). **No manual intervention anywhere in this run.**

> `bootstrap.txt` prints the Argo CD admin password — redact before publishing.

The development run on the previous cluster, its findings and the fixes they led to are in
`../thesis-v1.0-datalab/RUN-NOTES.md`.

## Timeline (UTC)

| | |
|---|---|
| ~12:17 | `bootstrap-k8s-native.sh` started |
| +751 s | platform tier (12 Applications) Synced/Healthy |
| +1086 s | `iris` Ready — bootstrap exit 0 (751 s converge + 335 s serve) |
| 12:36:37 | ml-pipelines data bootstrap, TrainingRuntime, KFP run `5064a14e…` submitted |
| 12:49:58 | KFP run SUCCEEDED (13 min 21 s) → `timeseries-model` version 1 |
| 12:50:23 | `promote-model.py --name timeseries-model --version 1` → lakeFS commit `f9a71a31…` (`E12b`) |
| +352 s | team2 `timeseries` Ready, no manifest change (`E15`); most of it is the predictor's back-off before it retried the download |
| 12:56 | gateway inference on the pipeline model: HTTP 200 on the first request (`E09b`) |
| 12:58–13:18 | `capture-checks.sh` with `PROMOTE=1 ROTATE=1 DRAIN=1` → `checks/` |

## Verdicts (`checks/SUMMARY.txt`)

22 PASS, 1 FAIL (C15, the expected one).

| | |
|---|---|
| C1 | converged in 751 s; 22/22 platform Applications healthy |
| C4 | reverted to the declared replica count after 2 s |
| C10 | 150/150 agreement, accuracy 0.980 |
| C13 | 6 nodes; 3 brokers on 3 distinct nodes |
| C15 | **FAIL as expected**: the tenant namespace obtained the platform credential |
| C16 | second (pipeline-produced) model served in team2 |
| C18 | tenant-declared target up after 98 s |
| C21 | promoted in 527 s, rolled back in 287 s; 667 requests, 0 not answered with 200 |
| C22 | Secret updated in 6 s without a commit; Grafana without restart: HTTP 401 |
| C23 | platform and model recovered 109 s after the drain; 22 request events for 6 answered requests |

## What the verdicts do not say

- **C23 — the model is unavailable while its only replica moves.** During the drain 136 of 142
  requests were not answered with 200. The criterion (recovery within 15 min, no answered
  inference without its event) holds; availability during a node drain does not, because each
  model runs one predictor replica. Kafka itself moved without loss of service
  (`nodeTaintsPolicy: Honor`): broker-2 was evicted and rescheduled.
- **C21 — 527 s to promote.** Dominated by Argo CD's repository polling and the predictor roll;
  zero failed requests across both transitions.
- **C22 — rotation reaches the Secret, not the consumer.** Grafana reads the credential at start.
