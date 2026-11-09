# Interventions log — clean local run (2026-09-21)

Cluster: fresh minikube (deleted and recreated; settings identical to E00 of 2026-09-18).
Manifests: origin/master c8b33de. Bootstrap run unattended from `scripts/bootstrap-k8s-native.sh`.

## CLEAN-01 — 08:36:42Z — bootstrap aborted at step 5 by a defect in the script's own wait
**What failed:** step 4 ("wait for the platform tier") passed after 61 s with only the root
Application present, because the wait had been scoped (in f5b470c) to `platform`/`platform-*`,
none of which existed yet -- a vacuous check. Step 5 then failed: `namespaces "platform-mlflow" not
found`, exit 1. Transcript: E29-bootstrap-clean.txt.
**Cluster impact:** none. Steps 1-3 (seed credential, install Argo CD, apply root) had completed; Argo
CD reconciles from there regardless of the script. No operator action was taken on the cluster, so
convergence (E07, E21) is measured from the root apply at 08:36:44Z.
**Fix:** cac17b1 -- the wait counts the expected Applications from the repository.
Committed locally; not needed on origin for Argo CD (the script is not reconciled), but recorded as
a local-HEAD script change against the c8b33de manifests.
**Plan:** let the platform converge untouched, capture E01/E07/E21/E23/E61, then re-run the fixed
script, whose steps 1-3 are idempotent, to perform steps 5-7 (lakeFS, model, serve). Reported as a
two-invocation bootstrap, not as a clean one-run E29.

## CLEAN-OBS-01 — 08:38Z — observation, no action: a namespace consumed before it is created
`platform-rbac-pipeline-runner` (wave -10) writes a ServiceAccount and RoleBinding into namespace
`platform-kubeflow`, which no wave -10 Application creates (`kubeflow-namespaces` creates compute,
mlops, kubeflow, platform-kubeflow-system); the KFP Applications create it with CreateNamespace in
wave 3. Sync fails (`namespaces "platform-kubeflow" not found`), health stays Healthy, so the wave is
not blocked, and the retry policy keeps re-attempting. Expected to self-resolve once wave 3 runs.
Orchestration tier (companion scope). scripts/preflight/wave-order.py checks CRDs, not namespaces --
a known gap. Candidate fix after the run: add platform-kubeflow to the kubeflow-namespaces manifest.

## CLEAN-02 — 08:40Z — environment intervention: `minikube tunnel` started
**What failed:** the rollout halted in wave -10: `platform` "waiting for healthy state of
platform-envoy-gateway". The Envoy `Gateway` reports `Programmed=False, AddressNotAssigned` because its
LoadBalancer Service has no external address, and Argo CD's health check for a Gateway treats that as
Progressing. Captured: E01-STALL-gateway-address.txt.
**Why it is new:** until c8b33de the health of child Applications was not assessed, so a
Progressing gateway blocked nothing. With waves gating on health, the whole platform rollout now waits
for the environment to assign an external address -- a dependency no platform service has (nothing in
the platform needs the gateway to be *reachable*, only to exist). On 2026-09-18 `minikube tunnel` was
already running (evidence/local/minikube-tunnel.log), which is why this never surfaced.
**What was done:** started `minikube tunnel` -- on minikube this *is* the LoadBalancer implementation,
the analogue of the OpenStack load balancer on dataLAB. No manifest, value or Argo CD object touched.
**Consequence for dataLAB (E40):** if OpenStack assigns no LoadBalancer address, the platform rollout
stalls in wave -10 there as well. Decide before the session: provide an LB implementation, or change
the artefact so an unassigned address does not gate the platform tier.

## CLEAN-OBS-02 — 08:40:55Z — observation, no action: the health gate opened early once
Wave -9 (monitoring) was created 08:40:35Z, wave -8 (cert-manager, minio) at 08:40:55Z -- 20 s later,
while monitoring was still inside its own first sync (pods initialising; it went Degraded at 08:41:16Z
while Prometheus/Alertmanager started, then recovered). The documented Application health check
passes through the child's *health*, which can read Healthy transiently before the child's sync has
finished; it does not wait for the child's *operation*. Harmless here (monitoring's CRDs were installed
by then, so cert-manager's and minio's monitors resolved), but it means gating is on health snapshots,
not on completed syncs. A stricter check would report Progressing while the child's
operationState.phase is Running. Not changed mid-run.
The PreSync admission hook that hung for 16 min on 2026-09-18 (INT-01) completed in 8 s this time.

## CLEAN-03 — 08:53:51Z — second invocation aborted silently after step 3 (script defect)
The tier lookup added in a29c301 used `grep && sed` in a loop; under `set -euo pipefail` a
non-matching last file fails the substitution and the script exits with status 1 and no message
(E29-bootstrap-clean-take2.txt). Reproduced, fixed in 25e4440, and step 4 then
executed under the script's shell options against the live cluster before a third invocation.
No cluster action. Both CLEAN-01 and CLEAN-03 were defects in code written for this run, not in the
platform; the lesson recorded is that the script was changed without being run under its own options.

## CLEAN-04 — ~09:08Z — third invocation: steps 4-6 succeeded, step 7 timed out on a script defect
Steps 4-6 ran clean: platform tier found converged; lakeFS admin and repositories created; the demo
model registered from the pinned producer environment (Python 3.10, NumPy 1.26.4) as
tracking-quickstart v1 and promoted -- lakeFS commit 15dfb1dc8bce..., MODEL_URI_PINNED printed,
request payload derived (120x4) with no FINDING-02 crash. This is the clean coordinate -> bytes chain
the 2026-09-18 run lost to FINDING-03.
Step 7 then timed out: it read the tenant Application as `kubectl get application`, which resolves
to KFP's applications.app.k8s.io once the orchestration tier exists, so sync/health read empty.
Fixed in 2967e40. Not a platform fault: the storage initializer had fetched the
model through the lakeFS gateway at 09:03:08Z.
Two timing facts from this step, both correct behaviour rather than defects:
- before step 5 the storage initializer got AccessDenied (lakeFS has no admin yet), not NoSuchKey;
- after promotion the fetch waited for the kubelet's next init-container retry (CrashLoopBackOff
  caps at 5 min): promotion ~08:58Z, fetch 09:03:08Z. Time-to-serve after a promotion is bounded
  by that backoff when the predictor started before the model existed.
No cluster action.

## POST-CLEAN-01 — 2026-09-21T09:48:02Z — Gateway health override (decision: option 1)
Committed 2d7e078. Tested offline against six Gateway states
(E40-gateway-health-override.txt) and applied to this cluster's argocd-cm: platform-envoy-gateway
stays Healthy. Not exercised on a fresh cluster without an address; dataLAB will do so if OpenStack
assigns none.

## OWN-01 — 11:02-11:08Z — phase 1 guard does NOT survive an ownership flip (observation, no action)
06bbf7b put `argocd.argoproj.io/sync-options: Prune=false,Delete=false` on kubeflow-namespaces' copy of
Namespace `kubeflow`; it reached the live object at 11:02:53Z. At 11:07:34Z platform-katib took the
owner stamp and the annotation was gone (E23d-phase1-guard.txt). managedFields: one entry,
manager=argocd-controller, op=Apply -- all three Applications apply as the same field manager, so under
server-side apply the last applier's copy replaces the fields the others set; copies never merge. Same
mechanism as the stripped Katib label of 0043a90. Consequence: pushing phase 2 while katib or kfp-crds
holds the stamp would still prune the namespace. Phase 2 held back; phase 1b puts the guard on every copy.

## OWN-02 — 11:19Z — phase 1b cannot roll out: capacity-degraded wave -10 blocks every later wave (observation, no action)
origin/master = c038c24. The `platform` parent's sync operation has been Running since 09:48:44Z; with
retry/refresh it now targets c038c24 but waits at wave -10 for platform-envoy-gateway, whose controller
is in CrashLoopBackOff: the node is saturated again (9.66/10.25 GiB) with the orchestration tier up --
cert-manager webhook, Prometheus, postgres crash-looping, KFP pods Pending (INT-03 again). Consequence
of health gating beyond first install: while any earlier wave is unhealthy, NO change reaches a later
wave -- including a fix. Here, phase 1b never reaches katib (wave 3) or kfp-crds (wave -4).
Evidence: E01-STALL-2-capacity-blocks-rollout.txt. Phase 2 not pushed.
