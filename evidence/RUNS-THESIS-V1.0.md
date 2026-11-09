# Clean runs at the evaluated revision — overview (2026-10-01)

All four runs: fresh cluster, `scripts/bootstrap-k8s-native.sh` with defaults, no intervention,
then `scripts/evaluation/capture-checks.sh`. Platform repository tree identical to `115c072` in
every run (intervening commits are only the C21 promote/revert pairs). dataLAB runs ran the
pipeline from `ml-pipelines` branch `fix/trainer-py310` (`071bb086`, image `trainer:py310`).
The four runs were made one after another, never concurrently.

| Run | Evidence | Converged | Served | Verdicts |
|---|---|---|---|---|
| Local 1 | `thesis-v1.0-local-clean/` | 691 s | 1564 s | 19 PASS, C15 FAIL, 3 SKIP |
| Local 2 | `thesis-v1.0-local-clean-2/` | 1669 s | 3170 s | 19 PASS, C15 FAIL, 3 SKIP |
| dataLAB 1 | `thesis-v1.0-datalab-clean/` | 751 s | 1086 s | 22 PASS, C15 FAIL |
| dataLAB 2 | `thesis-v1.0-datalab-clean-2/` | 655 s | 926 s | 22 PASS, C15 FAIL |

**Means** — Local: converged 1180 s (19.7 min), served 2367 s (39.5 min).
dataLAB: converged 703 s (11.7 min), served 1006 s (16.8 min).

**Verdicts were identical within each environment.** Values that varied (per-run detail in each
`RUN-NOTES.md`):

| | Local 1 | Local 2 | dataLAB 1 | dataLAB 2 |
|---|---|---|---|---|
| C18 target up (bound 300 s) | 133 s | 149 s | 98 s | 251 s |
| C21 promote / rollback | 145 / 222 s | 266 / 195 s | 527 / 287 s | 335 / 139 s |
| C21 requests not 200 | 1 / 311 | 0 / 339 | 0 / 667 | 1 / 399 |
| C23 recovery | — | — | 109 s | 107 s |
| C23 requests not 200 during drain | — | — | 136 / 142 | 41 / 130 |
| team2 Ready after promotion | — | — | 352 s | 414 s |
| KFP pipeline run | — | — | 13 min 21 s | 13 min 2 s |

Thesis consequences to apply (NOT yet applied — thesis edits on hold):
- Runs table: Local 2 runs, 20 min / 39 min (was 2 runs, 20 / 41 min from older revisions);
  dataLAB 2 runs, 12 min / 17 min (currently 1 run, 13 / 18 min).
- Reliability: "two locally and two on dataLAB"; outcomes repeated in each environment.
- G4/C21 sentence currently quotes dataLAB run 1 only (527 s / 287 s, 0 of 667; locally 1 of 311).
  Across runs, at most one request per hand-over failed — phrase as such or quote ranges.
- G2/C23 sentence quotes run 1 (109 s, 136 of 142); run 2: 107 s, 41 of 130.
- C18 margin: 251 s against a 300 s bound in one run.

Superseded development evidence: `thesis-v1.0-datalab/` (findings that led to `115c072`),
older local directories.
