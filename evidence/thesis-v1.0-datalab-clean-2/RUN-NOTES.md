# dataLAB clean run 2 — 2026-10-01

Revisions: `mlops-apps` `90bf2ca` (tree identical to `115c072`; only C21 promote/revert commits in
between); `ml-pipelines` `fix/trainer-py310` `071bb086`. Profile `CLUSTER_ENV=datalab`.
Freshly provisioned Azimuth cluster (third of the day, named `mlops-k8s-native-test` again):
Kubernetes v1.36.2, Calico, 3 control-plane nodes (4 vCPU / 16 GiB) + 3 workers (8 vCPU / 32 GiB),
`csi-cinder` default (`E00`). Run strictly after the local run; minikube stopped.
**No manual intervention.**

> `bootstrap.txt` prints the Argo CD admin password — redact before publishing.

| | |
|---|---|
| bootstrap | exit 0 in 926 s: 655 s to converge, 271 s to serve `iris` |
| pipeline | KFP run `8caaeba1…` SUCCEEDED, 14:35:51 → 14:48:53 (13 min 2 s) |
| promotion | `timeseries-model` v1, lakeFS commit `ac17d5ea…` (`E12b`); team2 Ready 414 s later, no manifest change (`E15`) |
| inference | gateway, pipeline model: HTTP 200 (`E09b`) |
| checks | `PROMOTE=1 ROTATE=1 DRAIN=1` → `checks/` |

## Verdicts — identical to clean run 1

22 PASS, C15 FAIL (expected).

| | run 1 | run 2 |
|---|---|---|
| C1 converged | 751 s | 655 s |
| C4 revert | 2 s | 0 s |
| C18 target up (bound 300 s) | 98 s | **251 s** |
| C21 promote / rollback | 527 s / 287 s | 335 s / 139 s |
| C21 requests not 200 | 0 of 667 | **1 of 399** |
| C22 Secret updated | 6 s | 5 s |
| C23 recovery | 109 s | 107 s |
| C23 requests not 200 during drain | 136 of 142 | 41 of 130 |
| team2 Ready after promotion | 352 s | 414 s |

- C18 at 251 s is within the bound but with little margin: the delay is the kubelet's delivery of
  the regenerated Prometheus config Secret, which varies widely.
- C21: one request failed during a hand-over, as locally (1 of 311); the dataLAB run 1 had none.
- C23: the drain interrupts the single-replica model in both runs; how many requests fail depends
  on when in the drain the predictor is evicted relative to the request loop.
