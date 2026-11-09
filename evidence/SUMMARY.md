# Validation Campaign — minikube (local) run summary

**Date:** 2026-09-18. **Commit at S0/E60 pre-registration:** `3e0da5e3747418b9419d7c3cd091f4ad55a0458d`.
**Commit at session end (E11):** `a938db4aaf1a6dc5d42899c1b990e504592ccdbe`.

The SHA changed mid-campaign. This is a **fitted, not predicted** change, per §B.3 — two real defects
were found and fixed during this run, and the fix commits were pushed partway through:

- `7bfd7ea` (superseded/reverted): an attempted version-bump promotion for the iris model, reverted
  because it could not be pushed from this shell in time to be exercised — see FINDING-03.
- `a938db4`: fixes `platform-rp-connect`'s Service routing to the wrong container port
  (FINDING-04) — pushed by Michael partway through the session and verified live afterwards.

`env-parity.py` was **not** re-run against `a938db4` at the end of this session — do that before
closing out B.3's pre-registration requirement, though the change (a Service `targetPort`) does not
touch the Application layer M1/M2 measure.

## What this run covers

Only `k8s-native-stack`, `minikube` profile, per §A.1/§B. The orchestrated pipeline (S5, KFP/Katib/
Spark producing `timeseries-model`) was **deferred to dataLAB** — this laptop's minikube profile
(7 vCPU / 10.5 GiB, downgraded from the plan's own 6 vCPU / 20 GiB recommendation because of the host's
15.8 GiB total RAM) cannot run the full platform tier and the full orchestration tier concurrently;
see INT-03 and E61 for the measured evidence.

## Evidence ledger status

| ID | Status | Note |
|---|---|---|
| E00 | captured | 8 vCPU / ~11.7 GiB allocatable, minikube v1.35.0, k8s v1.32.0 |
| E01, E01a, E01b | captured | see convergence notes below |
| E03–E06 | retired | per §A.1, `_skeleton` never deployed |
| E07 | captured | 46.4 min, root-apply to platform-tier all-Healthy — **not** without intervention, see below |
| E08 | captured | namespace + pod inventory |
| E09 | captured (×2) | working iris inference, request+response with headers |
| E10 | captured | real request/response pair sharing a Kafka key — **only after FINDING-04 was fixed** |
| E11 | captured | SHA changed mid-campaign, see above |
| E12 | captured (×2) | v1 promoted twice (numpy-2.x build, then the numpy-1.x fix) |
| E12a | captured | mlflow-dummy-model.py transcript |
| E13 | captured | lakeFS commit history for `mlflow/main` |
| E14 | captured | confirms lakeFS (not MinIO) is the fetch endpoint |
| E15a | captured | team2 `NoModel found` — expected unmet-declaration state |
| E15 | **not attempted** | needs the pipeline-produced `timeseries-model`; deferred to dataLAB |
| E16 | captured | `git status --porcelain` clean after full model deployment |
| E17 | **not attempted** | no PyTorch model produced locally (pipeline deferred); F75 still open upstream |
| E20–E22 | captured | Kafka topology (1 broker/1 controller, minikube profile), F24/F25 both confirmed resolved on a live cluster |
| E23 | captured | discharges F06 — see FINDING-01, the true cause is unrelated to ExternalSecret ownership |
| E24 | captured | all ExternalSecrets SecretSynced=True |
| E25 | not run | scoped to this artefact per the plan; not exercised this session |
| E26 | captured | cross-namespace destination probe — **REFUSED**, as expected |
| E27 | captured | privilege-escalation-via-project probe — **REFUSED**, as expected; self-service confirmed unaffected |
| E28 | captured | `application.namespaces: team1,team2` confirmed active |
| E29 | captured (partial) | see "S10b" note below — not a clean-cluster run |
| E30 | captured | matches the plan's own prediction exactly (minio/mlflow/cert-manager/CNPG up; kafka/gateway/lakefs/ESO/rp-connect absent) |
| E31 | captured | ServiceMonitor/PodMonitor inventory |
| E32 | **partial** | dashboard provisioning mechanism confirmed from source (4 dashboards, gnetId/URL-based); live Grafana API confirmation NOT completed — capacity constraints, see E32-dashboards-api.txt |
| E33 | captured | **no** kserve/model-level metrics exist; root cause confirmed (no ServiceMonitor targets kserve at all) — narrows §8.3.4 |
| E34 | captured | retention: 12h, matches plan |
| E40–E43 | not attempted locally | dataLAB-specific (ingress, Kafka footprint) or already answered statically |
| E50 | captured | **selfHeal did NOT revert manual drift** within 3+ minutes on `platform-minio` — correlates with FINDING-01, not a contradiction of it. Important qualification for §5.4.1 |
| E53 | attempted, not completed | v2 promoted with a real lakeFS commit, but the manifest edit needed to trigger it could not be pushed in time; reverted. Re-attempt if useful |
| E60 | captured | pre-registered before any cluster existed; M1 passes (25/25 files identical), M2 = 43/41 keys, matching the plan's stated numbers exactly |
| E61 | captured | see capacity section below |
| E62, E63 | not attempted | dataLAB-only (E62) / local-only but not run this session (E63, mis-profile control) |

## Convergence — the honest version of E07

46.4 minutes, but **not** "without further operator action." Two classes of intervention were needed
(see `INTERVENTIONS.md` for full detail):

1. **INT-01**: a Helm pre-sync hook pod hung 16+ minutes on an IPv6 pull-path issue against
   `registry.k8s.io`, blocking CRD installation and cascading into several apps' first sync attempts
   failing.
2. **INT-02 / FINDING-01**: ArgoCD does not retry an automated sync that already failed against the
   same source revision. Every app whose first attempt failed during INT-01's window stayed
   `OutOfSync` indefinitely — regardless of `selfHeal: true` — until manually resynced. This is the
   single most consequential finding for the thesis's G1 claim: qualify "without further operator
   action" explicitly, and correct §12.2.1's "precisely the ExternalSecret owners" explanation for the
   `OutOfSync` set (see E23).

## Capacity — INT-03, and why it matters beyond this session

The full platform tier (21 apps) plus the full orchestration tier (KFP's 13 components including its
own MySQL/MinIO/Argo-Workflows, Katib's 4, Dask, Spark operator) does not fit concurrently in 7 vCPU /
10.5 GiB — confirmed repeatedly across the session (`docker stats` peaked at 99.44% memory / 810% CPU
of a 700%-cap allocation). `kube-apiserver` and `argocd-application-controller` alone consumed ~3 of 7
cores under load (E61). No `OOMKilled`/`Evicted` events were observed — the failure mode is
API-server-latency-driven leader-election loss and sync timeouts, not hard memory kills. Katib, Dask,
the Spark operator, KFP, and (temporarily) monitoring were scaled down for the rest of the session;
nothing in Git was touched to do this.

**This is itself the M6 result for the local profile**: functionally correct once given room, not
sized for concurrent full-stack operation on hardware smaller than the plan's own recommendation.

## New findings this session (not predicted by any prior static analysis)

- **FINDING-01**: ArgoCD's `selfHeal` does not retry a sync that failed once against the current
  revision. Explains the true cause of F06's `OutOfSync` puzzle and qualifies G1.
- **FINDING-02**: `promote-model.py --write-request` crashes on some `input_example.json` shapes
  (bare list vs. dict), and the crash skips the lakeFS commit step entirely — not just cosmetic.
- **FINDING-03**: the reference iris model itself crash-loops if registered from an environment with
  NumPy ≥2.0 (MLServer 1.5.0's bundled runtime predates the `numpy._core` rename) — a second,
  independent instance of the producer/consumer environment-drift class of risk F75 already
  documents, this time affecting the model the plan assumed "always worked."
- **FINDING-04** (most significant): the event bus has been **non-functional since deployment** — a
  chart/Service port mismatch (`platform-rp-connect`'s Service targeted the chart's own admin port,
  not the custom `/ingest/kserve` listener) meant `inference-events` was empty regardless of how much
  serving traffic ran. This breaks G5's central Day-2 evidence entirely, not merely leaves it
  unverified. Fixed, pushed (`a938db4`), and verified via the real GitOps path.

## Not yet done (candidates for follow-up, locally or on dataLAB)

- E15/E17 (pipeline-produced model) — needs `ml-pipelines` run, deferred to dataLAB for capacity
- E32's live half (Grafana dashboard content) — retry once observability doesn't compete with the full stack
- E53 end-to-end (version-bump rolling the predictor) — the mechanics are proven (a real lakeFS commit
  exists for v2); only the manifest push-and-observe step remains
- E62/E63 — dataLAB-only / not attempted this session
- Screenshots (S01–S06) — this was a CLI-only session; no browser was used
- S10b's clean-cluster bootstrap run — this session's `E29` was against an already-partially-converged
  cluster, not a pristine one; the script also has an `Application` CRD shorthand-ambiguity bug in its
  own diagnostic fallback (unrelated to the main flow) — see `INTERVENTIONS.md`

## Interventions

Full detail in `INTERVENTIONS.md`: INT-01 (stuck image pull), INT-02 (stale-revision sync skip),
INT-03 (capacity, with the kserve leader-election detail), FINDING-01 through FINDING-04, and the E50
drift-probe result.

---

## Addendum — 2026-09-21 (post-campaign review and re-captures on the same cluster)

**Correction to the ledger above.** "E20–E22 … F24/F25 both confirmed resolved" overstates F25.
E21's creation timestamps put all eight platform waves within 17 s (13:47:20 → 13:47:37), 2–3 s apart:
the waves ordered *creation*, not *readiness*, because Argo CD has not assessed the health of
`Application` resources since v1.8. That is the mechanism behind INT-01/02's cascade. F24 stands
(E22-take2 names the bindings). F25 is **open** until a fresh sync shows waves gating (E21b note).

| ID | New capture | Result |
|---|---|---|
| E22-take2 | ClusterRoleBinding and RoleBinding names | The three CRBs are Strimzi's baseline (global, broker/client delegation); `-watched`, `-entity-operator-delegation` and the namespaced binding are RoleBindings in `platform-kafka`. Namespace-scoped watch confirmed. |
| E09b | Predictor QoS and injected resources | `Burstable`. Tenant declares `resources: {}`; KServe injects 1 CPU / 2 GiB (req = lim) on `kserve-container`, 100m/100Mi → 1/1Gi on the init and agent containers. |
| E13-take2 | Full `mlflow/main` history + `serving/` listing | Discloses FINDING-03's out-of-band fix: commit `960c7e27` put v2's bytes under the v1 path (checksums identical, incl. `registered_model_meta`). **The model served in E09-take2 is registry v2 under the v1 coordinate** — mechanism evidence (E12→E14) stands, the clean coordinate→bytes chain does not; redo it on dataLAB from the pinned producer environment. |
| E30-take2 | Scrape targets, with command line | Same split as E30; Grafana now `up`. |
| E32-take2 | Grafana `/api/search` + backing series | **Discharged.** All four declared dashboards provisioned and backed by live series. |
| E21b | `argocd-cm` Application health check applied live | Parents now report their children's health (v3.5.3). Wave gating on a fresh sync still to be observed. |
| E25 | Credential scan of both artefact repositories | No credential value; every hit is a key name. |
| E60-end | env-parity at `a938db4` | M1 25/25, M2 43/41 keys — unchanged. §B.3 end-of-campaign re-run done. |

**Artefact changes committed on `fix/local-campaign-findings` (fitted, not predicted — see
INTERVENTIONS POST-02).** Pre-register the pushed SHA with env-parity before the dataLAB session.

**M6 caveat.** The local run had 8 vCPU / 11.7 GiB allocatable against the minikube profile's
declared ~20 GiB. INT-03 shows the host was below the profile's predicted footprint; it is not a
fitness result *for the profile*.

### Addendum 2 — the OutOfSync set, settled (2026-09-21, E23c)
E23's account ("ExternalSecret ownership is incidental") was incomplete. Two independent causes:
1. **First-sync failure, never retried** (FINDING-01) -- fixed by the retry policy (13894ac); observed
   clearing on the live cluster once 47881ff arrived.
2. **ServerSideApply without server-side diff** -- API-server defaults read as drift; hits every
   SSA-synced Application owning a defaulted CR (ExternalSecrets, Strimzi CRDs, CNPG Cluster), not
   ExternalSecret ownership as such (`workloads-team1-iris` owns one, applies client-side, is Synced).
   Fixed by `controller.diff.server.side` (ce7cbd3); verified: all twelve platform Applications Synced.
What remains OutOfSync is genuine and in the orchestration tier: two Applications claim
Namespace/kubeflow, two claim ServiceAccount/pipeline-runner, and katib's webhook caBundle.

---

# Clean local run — 2026-09-21 (`evidence/local-clean/`)

Fresh minikube (deleted and recreated; settings identical to E00), manifests at origin/master
`c8b33de`, bootstrap run unattended. Scripts at local HEAD (`2967e40`, not reconciled by Argo CD).
Interventions: `local-clean/INTERVENTIONS.md`.

| ID | Result |
|---|---|
| E60 | Pre-registered at c8b33de before the cluster existed: M1 25/25, M2 43/41 keys |
| E00 | 8 vCPU / 11.7 GiB allocatable, identical to 2026-09-18 |
| E07 | **Platform tier (12 Applications) Synced/Healthy 12 min 17 s after the root was applied** (08:36:44 → 08:49:01Z). One intervention in that window (CLEAN-02, `minikube tunnel`), which ended a 3 min 49 s hold in wave −10. 2026-09-18: 46.4 min, two interventions |
| E21 | **Waves gated on health**: created at +5 s (−10), +234 s (−9), +254 s (−8), +307 s (−6), +362 s (−4), +545 s (0), +562 s (1), +717 s (2), orchestration +736 s (3) and +1037 s (4). 2026-09-18: all eight platform waves within 17 s |
| E21c | wave-order check against the fresh cluster: 0 inversions |
| E23 | Platform tier all Synced. Retries absorbed every transient failure (kserve 2, postgres 2, monitoring 1, rbac-pipeline-runner 5, workloads 5). Remaining OutOfSync is orchestration tier only and genuine: Namespace/kubeflow (katib, kubeflow-namespaces), ServiceAccount/pipeline-runner (rbac-pipeline-runner, kfp), katib webhook caBundle |
| E29 | **Three invocations, not one.** 1st: vacuous step-4 wait (CLEAN-01); 2nd: silent pipefail abort in the tier lookup (CLEAN-03); 3rd: steps 4–6 clean, step 7 timed out on a `kubectl get application` short name (CLEAN-04). All three were defects in script code written for this run, all fixed; none was a platform fault. A true one-run E29 on a fresh cluster remains outstanding |
| E12/E13/E14 | **Clean coordinate → bytes chain**: v1 registered from the pinned producer environment, promoted as lakeFS commit `15dfb1dc` (metadata: coordinate + run id), fetched by the storage initializer through the lakeFS gateway at 09:03:08Z. No hand-copied bytes (cf. FINDING-03) |
| E09 | HTTP 200 through the gateway's LoadBalancer address, `[0, 2, 1]`. iris Ready at 09:10:12Z, 33.5 min after the root; of that, 6 min 42 s pulling `seldonio/mlserver:1.5.0` (9.9 GB) and ~5 min waiting on init-container backoff after promotion |
| E10 | take3: both records under one key, one partition — **response at offset 0, request at offset 1**: co-partitioned, not ordered. take1 empty (filter), take2 incomplete (`kubectl run -i` attach loss); both kept, take2 carries a correction |
| E16 | `git status -- clusters base scripts` clean after the full deployment |
| E50 | **Drift reverted**: minio scaled 1→3 out of band, automated sync restored 1 one second later. 2026-09-18: not reverted (FINDING-01) |
| E61 | Platform tier fits; platform + orchestration reaches 98 % of 10.25 GiB and degrades monitoring/KFP (INT-03 again). `kubectl top` unavailable (no metrics-server addon on the recreated node) |

**New findings this run**
- **With health gating, an unassigned LoadBalancer address stalls the whole platform rollout in wave −10**
  (CLEAN-02). Nothing in the platform needs the gateway to be *reachable*. On dataLAB this depends on
  whether OpenStack assigns an address (E40) — decide before the session.
- The documented Application health check gates on the child's health snapshot, not its completed sync;
  one wave opened 20 s early (CLEAN-OBS-02). Harmless here.
- A namespace consumed before it is created (`platform-kubeflow`, orchestration tier) is not caught by
  wave-order.py, which checks CRDs only (CLEAN-OBS-01). Retries absorbed it.
- On a fresh cluster the tenant's storage initializer sees `AccessDenied` until lakeFS is initialised,
  then `NoSuchKey` until promotion; first serve after promotion is bounded by kubelet backoff (≤5 min).
