# Offline pre-flight — results (§3 of VALIDATION_CAMPAIGN.md)

Run 2026-09-18, before the minikube session in `evidence/local/`.

## P1 — STOP CONDITION (F64)

**Already clear at session start.** `git rev-parse HEAD` (`3e0da5e...`) matched
`git ls-remote origin master` exactly — contrary to `REVISION_PLAN.md`'s note that two commits were
still unpushed. The plan document was stale on this point; no push was needed to start the campaign.

Two further commits were pushed **during** the session (see `evidence/SUMMARY.md`): `a938db4`
(FINDING-04's fix). Confirmed via `git ls-remote` after the push.

## P2 — serving runtime compatibility (Python 3.10 vs 3.11)

**Unchanged from the plan's own record.** `ml-pipelines/k8s-native-stack/docker/trainer/Dockerfile`
is still `FROM python:3.11-slim` — confirmed by reading the file directly. F75 remains open,
external to this repository, awaiting Zeilinger. **No remedy has been applied.** Since the pipeline
was not run this session (deferred to dataLAB for capacity — see INT-03), `E17` was not captured
either way; this remains open for the dataLAB session.

A **second, independent instance of the same class of defect** was found this session and is fully
resolved: FINDING-03, a NumPy-version mismatch between the environment that registered the reference
(iris) model and MLServer 1.5.0's bundled runtime. See `evidence/local/INTERVENTIONS.md`.

## P3 — Key Vault completeness

**Pass, cleanly.** `tofu plan` in `poc/mlops-eso-azure` reported no drift (vault already fully
applied from earlier work). The `comm -13` check against every `key: platform-*` reference in
`poc/mlops-apps` returned zero missing secrets, once `az keyvault secret list`'s CRLF line endings
were normalised (a tooling artifact, not a real mismatch — `az`'s TSV output uses CRLF on this
Windows host).

## P4 — pipeline non-cluster rehearsal

**Pass.** `ml-pipelines/k8s-native-stack/tools/compile_pipeline.py` compiled cleanly into
`e2e-pipeline.json` using a fresh `.venv` (kfp==2.14.*, pandas, pyarrow, fsspec, s3fs, requests).
`ghcr.io/julianzeilinger/trainer:main` is confirmed **private**; unreachable without a pull token,
reachable (multi-arch manifest returned) once `docker login` used the `platform-compute-ghcr-*`
credentials from Key Vault. Matches the plan's own warning exactly.

## P5 — request payloads

**Confirmed correct as documented.** `scripts/test/iris-batch-request.sh`'s hand-written 3×4 payload
is correct for the iris model and was used directly for `E09`. `promote-model.py --write-request` was
exercised and found to have a real bug (FINDING-02) unrelated to the iris/timeseries feature-width
question the plan raised P5 for — logged separately, not fixed (out of scope for this run).

## P6 — dry-run renders

**Pass, all four.**
- `helm template iris base/charts/model --set fullnameOverride=iris --set model.name=tracking-quickstart --set model.version=1` — succeeded, produced the expected `storageUri`.
- `helm template x base/charts/model` (no values) — failed as required: `Error: model.name is required unless storageUriOverride is set`.
- `bash -n scripts/bootstrap-k8s-native.sh scripts/install-argo.sh` — both parse.
- `python -c "import ast;ast.parse(open('scripts/promote-model.py').read())"` — parses.

## Tooling gaps found and closed before the campaign started

- `jq` was not installed — installed via `winget install jqlang.jq`.
- `argocd` CLI was not installed — installed via `winget install argoproj.argocd` (pinned to the
  same v3.5.3 the artefact's own `install-argo.sh` uses).
- Docker Desktop's WSL2 backend defaulted to 7.6 GiB (50% of host RAM); raised to ~11.7 GiB via
  `.wslconfig` (`memory=12GB`) with the user's confirmation, since the plan's own local-profile
  sizing needs headroom the default would not have given.

## What remains before submission-quality PREFLIGHT closure

- P2/F75 still needs Zeilinger's fix or the documented sklearn fallback, exercised on a cluster
  (deferred to dataLAB).
- FINDING-02 (`--write-request` bug) is unfixed; note as a known script limitation if not addressed
  before submission.
