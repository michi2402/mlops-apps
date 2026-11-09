# Local clean run 2 — 2026-10-01

Revision `69cb2df` on master (tree identical to `115c072`). Profile `CLUSTER_ENV=minikube`.
Fresh node (`minikube delete`, `scripts/minikube-up.sh`): minikube v1.35.0, Kubernetes v1.32.0,
6 CPUs / 11 GiB / 40 GB, kubelet `maxParallelImagePulls: 3`, no image cache (`E00`). Run strictly
after dataLAB clean run 2; minikube stopped afterwards. **No manual intervention.**

> `bootstrap.txt` prints the Argo CD admin password — redact before publishing.

| | |
|---|---|
| bootstrap | exit 0 in 3170 s: 1669 s to converge, 1501 s to serve `iris` |
| checks | `PROMOTE=1 ROTATE=1` → `checks/` |

## Verdicts — identical to local clean run 1

19 PASS, C15 FAIL (expected), C13/C16/C23 SKIP.

| | run 1 | run 2 |
|---|---|---|
| bootstrap converged / served | 691 s / 1564 s | 1669 s / 3170 s |
| C1 platform Applications healthy | 18 of 21 | 22 of 22 |
| C4 revert | 8 s | 1 s |
| C18 target up | 133 s | 149 s |
| C21 promote / rollback | 145 s / 222 s | 266 s / 195 s |
| C21 requests not 200 | 1 of 311 | 0 of 339 |
| C22 Secret updated | 6 s | 6 s |

The durations differ by a factor of 2.4 between the two cold runs on the same machine; the
verdicts do not differ.
