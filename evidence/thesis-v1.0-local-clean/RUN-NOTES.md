# Local clean run — 2026-10-01 (the reported Local column)

Revision `71c9fab` on master (tree identical to `115c072`; the commits in between are a C21
promote/revert pair). Profile `CLUSTER_ENV=minikube`. Fresh node: `minikube delete`, then
`scripts/minikube-up.sh` — minikube v1.35.0, Docker driver, Kubernetes v1.32.0, 6 CPUs / 11 GiB /
40 GB, 8 CPUs allocatable, kubelet `maxParallelImagePulls: 3`; only minikube's own 9 images present,
no image cache loaded (`E00`). **No manual intervention.**

> `bootstrap.txt` prints the Argo CD admin password — redact before publishing.

| | |
|---|---|
| bootstrap | exit 0 in 1564 s: 691 s to converge, 873 s to serve `iris` |
| checks | `PROMOTE=1 ROTATE=1` (no `DRAIN`: single node) → `checks/` |

## Verdicts

19 PASS, C15 FAIL (expected), C13/C16/C23 SKIP (single node; pipeline not run locally).

Notes beyond the verdict lines:

- C1 passes on the serving path's twelve Applications; 18 of the 21 platform-labelled Applications
  were healthy — the orchestration tier does not fit the node (Ch. 12 "Workloads").
- C4 reverted after 8 s (dataLAB: 2 s). C18 target up after 133 s (dataLAB: 98 s).
- C21 promoted in 145 s, rolled back in 222 s; **1 of 311 requests not answered with 200**
  (dataLAB: 0 of 667).
- C22: Secret updated in 6 s without a commit; Grafana without restart: HTTP 401 (as on dataLAB).

minikube stopped afterwards (`minikube stop`) to free the machine for the second dataLAB run.
