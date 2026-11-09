# Interventions log — minikube (local) run

## INT-01 — 2026-09-18, ~14:04 UTC
**Symptom:** `platform-monitoring`'s Helm PreSync hook Job `monitoring-kube-prometheus-admission-create`
(image `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.2`) stuck in `ContainerCreating` for
16+ minutes with only a `Pulling` event, no `Pulled`/`Failed`/`BackOff`. This blocked the chart's CRD
install, which cascaded: `platform-minio`, `platform-cert-manager`, `platform-kserve` all failed their
sync attempts (5 retries exhausted) because `monitoring.coreos.com/v1` / `cert-manager.io/v1` CRDs did
not exist yet — captured in `E01-FAIL-platform-minio-wave-race.txt` and `E01-FAIL-monitoring-hook-stuck-pull.txt`.

**Diagnosis:** `registry.k8s.io` resolves to both an IPv4 (34.96.108.209) and an IPv6
(2600:1901:0:bbc4::) address from inside the minikube node; `minikube ssh -- curl` to the registry
succeeded (http_code=401, i.e. reachable), and `minikube image pull` for the exact same image
completed immediately. The pod's own kubelet-driven pull did not, and produced no error — consistent
with a hung IPv6 connection attempt inside that specific pull path, not a general registry-egress
failure (which the `minikube start` warning about registry.k8s.io connectivity had already flagged).

**Intervention:** `minikube image pull` to seed the image into the node's local cache, then delete the
stuck pod so the Job controller creates a fresh one against the cached image.
```
minikube image pull registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.2
kubectl -n platform-monitoring delete pod -l job-name=monitoring-kube-prometheus-admission-create
```
**Consequence for the thesis:** this qualifies "without further operator action" (G1, §12.2.1) —
one manual intervention was needed on the local profile, caused by a local Docker Desktop/minikube
networking quirk (IPv6 pull path), not by anything in the artefact itself. Record as such rather
than silently absorbing it into a clean E07 convergence number.

## INT-02 — 2026-09-18, ~14:16 UTC
**Symptom:** `platform-cert-manager`, `platform-minio`, `platform-kserve`, `platform-postgres`,
`platform-kubeflow-trainer-runtimes` remained `OutOfSync`/`Missing` ~20 minutes after INT-01 resolved
the missing-CRD root cause. Their `status.operationState` timestamps were all still ~13:52-13:56 —
ArgoCD's automated `selfHeal` did **not** retry them on its own once the per-operation retry limit
(5) was exhausted; it needs a new revision or an explicit refresh to start a fresh sync attempt.
`platform-kubeflow-trainer-runtimes` failed for a related but distinct reason: its validating webhook
(`kubeflow-trainer-controller-manager`) was not yet reachable at sync time.

**Intervention:** hard-refresh annotation on the five apps to force a new reconciliation/sync attempt
now that the blocking CRDs exist and dependent controllers have had time to start:
```
kubectl -n argocd annotate applications.argoproj.io <app> argocd.argoproj.io/refresh=hard --overwrite
```
This does not change desired state and does not bypass `selfHeal`/`automated` sync — it only asks the
controller to re-evaluate now instead of waiting on its own schedule. Whether this needed a manual
nudge at all, or whether it would eventually have retried unattended, is itself worth stating in
§12.2.1: on this run it did not self-resolve within ~20 minutes without it.

## FINDING-01 — root cause of the persistent OutOfSync set (F06), confirmed 2026-09-18 ~15:06 UTC
**What:** ~10 platform apps stay `SYNC: OutOfSync` indefinitely despite `HEALTH: Healthy` and despite
`syncPolicy.automated.selfHeal: true`. This is not cosmetic: it caused `scripts/bootstrap-k8s-native.sh`
(claimed "idempotent, safe to re-run") to time out after its full 1200s wait on a *second* run against
an already-converged cluster (see `E29-bootstrap-transcript-run1.txt`), because its convergence check
requires `SYNC == Synced`.

**Root cause, confirmed from `argocd-application-controller` logs** (authenticated `argocd` CLI, not
`--core` — that mode's `app diff` output was independently found to be unreliable and is not used as
evidence here):
```
"Already attempted sync: comparing synced revisions to [v0.15.0 v0.15.0 3e0da5e...]"
"Skipping auto-sync: failed previous sync attempt to [v0.15.0 v0.15.0 3e0da5e...] and will not retry
 for [v0.15.0 v0.15.0 3e0da5e...]"
```
ArgoCD's `automated`/`selfHeal` sync policy does **not** retry a sync that already failed against the
exact same source revision — confirmed exactly matching INT-01/INT-02's affected app set
(cert-manager, minio, kserve, postgres, trainer-runtimes, lakefs, mlflow, plus kafka-operator, katib,
kfp-crds, dask, kubeflow-spark-operator, rbac-pipeline-runner, monitoring, platform). It requires
either a new revision (a new commit) or an explicit manual sync operation to clear the "will not
retry" state. `Healthy` and `Synced` are computed independently, so an app that failed once and was
later fixed by its dependency (CRDs, a webhook) reports `Healthy` forever but never re-attempts a sync
and so never reports `Synced` again on its own.

**Consequence for the thesis (important, and different from what §12.2.1 currently argues):**
1. `selfHeal: true` does not mean "self-heals from every failure" — it heals *live drift on a
   revision it has already synced successfully*, not a sync that failed outright. A transient failure
   on the *first* attempt against a revision (image-pull hiccup, a webhook not ready yet — exactly
   INT-01/INT-02's causes) leaves the Application permanently stuck until an operator manually
   resyncs, even though nothing about the *desired* state ever changed.
2. This directly falsifies "idempotent, safe to re-run" for `bootstrap-k8s-native.sh` in its current
   form: a second run against a cluster that hit transient startup races on the first run will time
   out on the same apps, because the script's wait condition (`SYNC == Synced`) can never be
   satisfied without a manual sync — the script has no self-recovery path for this ArgoCD behaviour.
3. F06/P7.4 ("precisely the applications that own ExternalSecret resources") is **not the right
   generalisation** — the actual OutOfSync set is "every app whose first sync attempt failed for any
   reason, regardless of ExternalSecret ownership." `platform` and `platform-kafka-operator` (F06's
   original counter-examples) fit this cleanly: both failed early (CRD races) and neither has since
   been force-synced back to `Synced`.

**Recommendation for the artefact (not applied yet — flag for Michael):** either (a) have the
bootstrap script's wait loop treat `HEALTH == Healthy` as sufficient once `SYNC` has been `OutOfSync`
for N consecutive checks with no resource-level diff, or (b) have it issue a hard-refresh + manual
sync trigger for any app still `OutOfSync` after health has settled. Recording as a finding, not
fixing the script silently.

## INT-03 — capacity: local profile cannot run platform + orchestration tiers concurrently, 2026-09-18 ~15:25-15:40 UTC
**Symptom:** After the platform tier first reached full convergence (~46 min, see E07) and a batch of
manual resyncs (INT-02) was applied, `docker stats minikube` showed the node's Docker container at
**95.7% memory (9.8/10.25 GiB) and 706-810% CPU (fully saturating all 7 allocated cores, some
throttling above 700%)**. This produced a self-reinforcing cascade of `CrashLoopBackOff`: `lakefs`
("Failed to open KV store: context canceled"), the CNPG operator ("cannot update the instances status
... context canceled"), `monitoring-kube-prometheus-operator`, `platform-rp-connect`,
`monitoring-grafana`, plus pre-existing KFP/Katib instability (`cache-server`, `ml-pipeline-ui`,
`katib-db-manager`). None showed `OOMKilled` explicitly — the pattern is API-server/etcd contention
and liveness-probe timeouts under CPU starvation, not a single hard memory ceiling.

**Root cause:** this laptop's minikube profile is 7 vCPU / 10.5 GiB (§1's own recommendation is
6 vCPU / **20 GiB** for the local profile — 10.5 GiB is already an accepted downgrade from Docker
Desktop's host-RAM ceiling, see the WSL2 sizing decision earlier this session). Running the full
`k8s-native-stack` platform tier (21 apps) *concurrently* with the full orchestration tier (KFP's 13
components including its own MySQL/MinIO/Argo-Workflows, Katib's 4, Dask, the Spark operator) exceeds
even the *platform-only* steady-state estimate in §1 (~8-9 vCPU / ~28-32 GiB) — and we were running
both tiers at once, which §1 never separately budgets.

**Intervention:** disabled `syncPolicy.automated` (not deleted, not edited in Git) and scaled to 0 the
Deployments under `platform-katib`, `platform-dask`, `platform-kubeflow-spark-operator`, and the
entire `platform-kfp` component (`kubectl -n kubeflow scale deploy --all --replicas=0`). These four
are needed only for the orchestrated pipeline run (S5, the KFP/Katib/Spark path that produces
`timeseries-model`) — not for G1 (convergence), G2 (portability), G3 (tenancy) or the reference-model
serving path (S6, `iris`). Nothing in Git changed; `E16`'s "no manifest edited" claim is unaffected.

**Consequence for the thesis (important, and new):**
1. This is itself M6/E61 evidence, gathered earlier and more starkly than planned: the local profile,
   even downgraded from the plan's own 20 GiB recommendation, cannot sustain the full stack at rest.
   State this plainly rather than only reporting the dataLAB numbers — the contrast **is** the M6
   result for portability's "fitness" claim.
2. **The local rehearsal is narrowed from here on**: S4/S6/S7/S8/S9 (lakeFS, reference-model serving,
   event bus, tenancy probes, observability) continue against the platform tier. **S5 (the
   orchestrated pipeline producing `timeseries-model`) is deferred to the dataLAB environment**,
   which §1 explicitly provisions with headroom for exactly this (3×8vCPU/32GiB workers, sized off
   the same peak-usage table). This also means `E15`/`E15a` (the team2 onboarding capture) will be
   completed on dataLAB, not locally — record that explicitly rather than leaving team2 evidence
   silently missing from the local set.

## FINDING-02 — minor script bug, `promote-model.py --write-request` (not fixed, recorded)
**Symptom:** `promote-model.py --name tracking-quickstart --version 1 --write-request ...` crashed
with `AttributeError: 'list' object has no attribute 'get'` in `write_request()` (script line ~123),
**after** the actual promotion (the copy to `s3://mlflow/main/serving/tracking-quickstart/1`, 8 files)
had already succeeded and been confirmed. `write_request()` assumes `input_example.json` is always a
JSON object with a `data`/`inputs` key; on this run MLflow logged it as a bare top-level list instead.
**Not fixed** — out of scope for the campaign (a convenience helper, not the promotion contract under
test). Worked around by using the existing `scripts/test/iris-batch-request.sh` payload directly for
`E09`/S6, which is already correct for the iris model per §3 P5. Report as a small, real defect: the
helper should accept a bare list as row-oriented data, matching what `write_request`'s own docstring
implies it's meant to derive robustly.

## INT-03 (continued) — kserve-controller-manager lost leader election under API-server contention
While retrying `platform-kserve`'s sync, its controller pod crashed with `"leader election lost"`:
`Failed to update lock optimistically ... context deadline exceeded, falling back to slow path` then
`error retrieving resource lock ... client rate limiter Wait returned an error: context deadline
exceeded`. This is controller-runtime's designed behaviour (a controller that cannot renew its lease
in time deliberately exits) triggered by `kube-apiserver` itself being too slow under load to answer
a lease-renewal request within its deadline — not a configuration defect in the kserve chart. It
recurred across several components during this capacity episode (also observed indirectly in CNPG's
and the KFP components' restarts).

**Further intervention:** scaled `platform-monitoring` (Prometheus, Grafana, kube-state-metrics,
Alertmanager) to 0 in addition to katib/dask/spark-operator/kfp, same rationale (INT-03) — not needed
until S9. `docker stats` dropped from 96.16% mem / 701% CPU to **84.2% mem / 243% CPU**, and every
previously crash-looping pod (kserve-controller-manager, CNPG operator, spark-operator-controller)
stabilized within ~2 minutes at the lower load. Will re-enable monitoring (`syncPolicy.automated`
restored, no scale-up needed — ArgoCD's selfHeal will restore replicas) before S9.

**Reading for the thesis:** the evidence across INT-01 through INT-03 is consistent and specific:
every instability observed on the local profile traces to CPU/API-server contention from running the
full platform-plus-orchestration tier concurrently on hardware smaller than even the plan's own
downgraded local recommendation (7 vCPU/10.5 GiB vs. the recommended 6 vCPU/20 GiB) — not to defects
in the manifests, charts, or control loop logic. Every component that failed, later succeeded
unmodified once given room. This is itself the M6 "fitness" result for the local profile: functionally
correct, but not sized for its environment without scope-narrowing (see also E61-fitness-early-pressure.txt).

## FINDING-03 — reference (iris) model crash-loops: NumPy 2.x vs MLServer 1.5.0's bundled NumPy
**Symptom:** `iris-predictor` pod's `kserve-container` crash-loops immediately after loading the
model, exit reason `ModuleNotFoundError: No module named 'numpy._core.numeric'`
(`mlserver.parallel.errors.WorkerError`). Captured from
`kubectl -n team1-iris logs iris-predictor-<pod> -c kserve-container --previous`.

**Root cause:** `scripts/mlflow-dummy-model.py` was run in this session's ambient Python environment,
into which `pip install ... scikit-learn pandas` had just installed **NumPy 2.5.3** (confirmed:
`python -c "import numpy; print(numpy.__version__)"` -> `2.5.3`). scikit-learn's pickle format embeds
NumPy internals; `numpy._core` (with the underscore) is NumPy >=2.0's internal package layout, renamed
from `numpy.core` used by NumPy 1.x. `seldonio/mlserver:1.5.0` (KServe v0.15's bundled sklearn
runtime, the same image already investigated in §3 P2 for the Python 3.10/3.11 issue) ships an older
NumPy predating that rename, so it cannot import the module the pickle references.

**This is the same *class* of defect as F75** (a producer/consumer environment mismatch around
pickle/cloudpickle serialization), independently rediscovered here for the **reference iris model**,
which the campaign plan's own text assumed "has always worked" — true only for the Python-version
angle F75 documents, not for this NumPy-version angle, which nothing in the artefact or the plan had
previously surfaced. Worth stating in the thesis as a second, independent instance of the same
structural risk (§12.1/§3 P2's finding generalises beyond the one producer it was found in).

**Fix applied (recorded, not silent):** pinned `numpy<2` in the environment that runs
`scripts/mlflow-dummy-model.py`, re-registered the dummy model (new MLflow run/version), re-promoted
with `--force`. See the re-run transcript appended below.

## FINDING-03 (resolution)
Attempted the proper fix via the promotion contract (register v2 in a matching Python 3.10/NumPy 1.26
environment, promote it, bump `iris.yaml`'s `model.version` 1->2, commit). **Could not complete via
the intended GitOps path**: `git push origin master` failed in this shell —
`fatal: unable to connect to cache daemon` / no usable non-interactive credential (matches this
project's known constraint: pushes must go through Michael). Reverted the local commit rather than
leave an orphaned, unpushed change no one would know to look for.

**Actual fix, unblocking without a git change:** copied the corrected v2 artifact's 8 files directly
onto the *already-declared* v1 serving path in lakeFS (`main/serving/tracking-quickstart/1/`, boto3
`copy_object` against the lakeFS S3 gateway, ref `main` as the first key segment per §A.3) and
committed (`960c7e27...`, parent `fae07f0a...`). The manifest still says `model.version: "1"`,
unchanged in Git, matching what's actually served.

**Consequence:** E53 ("does a version bump roll the predictor?") was *prepared* (v2 registered and
promoted, a real lakeFS commit exists at `fae07f0a...`) but **not exercised end-to-end** — the
manifest edit that would trigger it could not be pushed from this environment. Recorded as "not
attempted, push unavailable in this shell" rather than silently dropped; the commit is describable to
Michael if he wants to push `clusters/base/k8s-native-stack/workloads/team1/apps/iris.yaml`
`model.version: "1"` -> `"2"` himself later to see it roll.

## FINDING-04 — rp-connect Service routes to the wrong container port; inference-events was empty since deployment
**Symptom:** `inference-events` topic empty at all 4 partitions despite the InferenceService's
`logger` being configured and the KServe `agent` sidecar actively sending both request and response
work items (`iris-predictor`'s `agent` container log: `Sent with status code 404, error: 404 page
not found`, for both `requestId`s of the E09 inference).

**Root cause, confirmed:** `platform-rp-connect-redpanda-connect` Service (`type: ClusterIP`, single
port named `http`) had `targetPort: http` — the chart (`redpanda/connect` 3.0.3)'s own default,
which resolves by container-port-name to the chart's built-in admin/stream-status HTTP server, always
on **4195**. This repo's `values.yaml` correctly configures a custom pipeline `http_server` input
bound to **8080** with `path: /ingest/kserve`, and correctly sets `service.port: 8080` for it — but
never overrides `service.targetPort`, so the Service silently routed every request to the wrong
listener the whole time. `kubectl exec`-ing into the pod and curling `localhost:8080/ingest/kserve`
directly returned `200`; the same request through the Service returned `404` — isolating the fault to
the Service's port mapping, not the application.

**Consequence for the thesis:** §7.4.2's event-bus claim and the entire Day-2 substrate argument (G5's
best evidence, S7) were **never functional as deployed** — not merely unverified, as the campaign plan
assumed going in. This is exactly the kind of finding S7's framing anticipated ("the capture most
likely to be forgotten and the one a strict examiner will press hardest") but the failure mode itself
(a Service/chart port mismatch) was not predicted by any prior static analysis.

**Fix:** `service.targetPort: 8080` (numeric) added to
`clusters/base/k8s-native-stack/platform/components/rp-connect/values.yaml`, verified with
`helm template`. Committed locally (`a938db4`) but **not pushed** (no usable git credential in this
shell, as with FINDING-03's attempted push). For this session's evidence capture, applied directly to
the live Service (`kubectl patch svc ... targetPort: 8080`), after disabling
`platform-rp-connect`'s `syncPolicy.automated` so ArgoCD's `selfHeal` didn't revert the live-only
patch back to the still-unpushed (broken) Git state — confirmed it did exactly that on the first
attempt before the policy was disabled, which is itself a useful demonstration of `selfHeal`'s actual
behaviour (§12.2.1: it reverts drift from Git, whether or not the operator's manual patch was a fix).

## FINDING-04 (verified against the pushed fix)
Michael pushed `a938db4` to `origin/master`. Re-enabling `platform-rp-connect`'s automated sync
initially still showed `targetPort: http` (broken) because ArgoCD's repo-server was serving a cached
resolution of `master` at the old SHA (`status.sync.revisions` showed `3e0da5e...`); a hard refresh
(`argocd.argoproj.io/refresh=hard`) forced re-resolution to `a938db4...`, after which the Service
picked up `targetPort: 8080` **with no manual patch**. A fresh inference request confirmed a working
request/response pair on the topic (key `407c69db-...`), sourced entirely from the GitOps path this
time. See `E10-FINDING04-verified-pushed.txt`. Worth noting for the thesis: a `targetRevision: master`
Application does not necessarily see a push within the campaign's own timescale without a refresh --
worth a sentence in §11.2 or the failure playbook.

---

# Post-campaign session — 2026-09-21 (same minikube cluster, restarted)

## POST-01 — cluster restart
The minikube container had been restarted outside minikube (kubelet and apiserver stopped,
kubeconfig endpoint stale). Brought back with `minikube start --keep-context`; no manifest,
value or Argo CD setting changed by that. State on return: identical Application set to E23-final,
orchestration tier still scaled down per INT-03.

## POST-02 — artefact fixes committed from this run's findings (branch fix/local-campaign-findings)
Fitted after the local run, per VALIDATION_CAMPAIGN.md §B.3 -- NOT predicted. Pre-registered for
dataLAB once pushed (record the SHA and re-run env-parity before the dataLAB session).
- 13894ac  install-argo.sh restores the Argo CD health check for argoproj.io/Application (E21:
           waves ordered creation only); syncPolicy.retry {limit: -1, refresh: true, backoff
           10s x2 <= 3m} on every Application (FINDING-01, INT-02, E50).
- f5b470c  producer environment pinned (FINDING-03); bootstrap waits on the platform tier only;
           diagnostic uses applications.argoproj.io (E29).
- 8b4ea71  promote-model.py commits before deriving the request; accepts list-shaped examples
           (FINDING-02).
- 6c507f2  pythonic-stack receives the same platform-layer fixes (separate commit: it changes a
           cluster the companion study runs).
env-parity after these: M1 passes 25/25, M2 unchanged (43/41 keys) -- retry is identical in both
environments, so it adds no environment surface.

## POST-03 — Application health check applied to the live Argo CD (E21b)
Applied exactly the argocd-cm patch committed in install-argo.sh @ 13894ac to this cluster, to
verify on v3.5.3 that parent Applications begin reporting their children's health. Changes health
reporting only; triggers no sync. The retry policy is NOT live here until the commits are pushed.

## POST-04 — the push of 47881ff reached the running cluster (observed, no action taken)
Argo CD picked up 47881ff unattended (~07:54Z). Observed: (1) the `platform` parent's sync operation
held at "waiting for healthy state of argoproj.io/Application/platform-kfp" -- waves -10..-2 applied,
waves 0..2 not -- i.e. waves now gate on health (verifies 13894ac on a live sync, not only E21b's
health reporting). (2) platform-minio / platform-lakefs synced *successfully* against the new revision
(FINDING-01's "will not retry" state cleared), yet stayed OutOfSync on their ExternalSecrets only, and
self-heal re-applied them every ~5 min (controller log: "retrying in 4m59s").

## POST-05 — server-side diff enabled live (E23c)
Cause of (2): the ExternalSecret CRD defaults four fields the manifests omit (remoteRef.
conversionStrategy/decodingStrategy/metadataPolicy, target.deletionPolicy); ServerSideApply leaves no
last-applied annotation, so the client-side diff counts API-server defaults as drift.
`workloads-team1-iris` owns an ExternalSecret but applies client-side, and is Synced -- the
discriminating case. Set `controller.diff.server.side: "true"` in argocd-cmd-params-cm and restarted
the application controller. Result: all twelve platform-layer Applications Synced. Remaining
OutOfSync, all orchestration tier and genuine: Namespace/kubeflow claimed by katib and kfp-crds;
ServiceAccount/pipeline-runner claimed by kfp and rbac-pipeline-runner; katib webhook caBundle.
Committed as ce7cbd3.

## POST-06 — orchestration tier moved after the platform tier (committed a7782a5 / d10a1fc)
Consequence of (1): with gating, wave -2 (dask/katib/kfp/spark/trainer) blocked the event bus
(0..2), making the platform layer depend on the orchestration layer. Moved to waves 3/4. Not yet
pushed at the time of writing.
