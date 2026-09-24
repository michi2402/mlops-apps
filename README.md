# mlops-apps — GitOps MLOps Platform

Declarative, GitOps-managed MLOps platform. This repository is the **shared implementation
artifact of two companion BSc theses at TU Wien**. The whole platform is bootstrapped from
this Git repository by **Argo CD** using the **App-of-Applications (AoA)** pattern: a single
root `Application` is applied to the cluster, and Argo CD then reconciles every platform
service and workload from the manifests in `clusters/`.

> **Authorship / scope.** This is a shared repository underpinning two BSc theses (TU Wien):
> - **Michael Mayrhofer** — *A Portable GitOps Reference Architecture for Sustainable
>   Cloud-Native MLOps*: the **platform layer** shared by every stack — Argo CD
>   App-of-Applications, External Secrets ↔ Azure Key Vault, the Envoy Gateway + KServe serving
>   path, the storage / observability base, the tenancy model, and the environment split under
>   `clusters/`.
> - **Julian Zeilinger** — *Best Practices for Automated Training and Export of Machine
>   Learning Models*: the **orchestration layers** on top of that platform — Kubeflow Pipelines,
>   Katib, the Trainer and Spark in `k8s-native-stack`, Prefect in `pythonic-stack` — and the
>   pipeline code in the companion `ml-pipelines` repository.

> **GitOps source of truth.** Argo CD pulls from
> `https://github.com/michi2402/mlops-apps` (branch `master`), **not** from your local
> working copy. Any change you make under `clusters/` or `base/` must be **committed and
> pushed** before Argo CD will see it. If you work from a fork, update `repoURL` in the
> `aoa-*.yaml` files accordingly.

> **Fast path.** To go from a bare cluster to a served, queryable model on
> `k8s-native-stack` in one command, see [`RUNBOOK.md`](RUNBOOK.md) and
> `scripts/bootstrap-k8s-native.sh`. The walkthrough below is the general, manual,
> stack-agnostic path — read it if you want to understand or adapt the individual steps.

---

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [The three stacks](#the-three-stacks)
- [Prerequisites](#prerequisites)
- [Bootstrap](#bootstrap)
- [Accessing services (port-forwarding)](#accessing-services-port-forwarding)
- [Ingress & model serving](#ingress--model-serving)
- [Demo workflow (train → register → serve)](#demo-workflow-train--register--serve)
- [Namespace reference](#namespace-reference)
- [Teardown](#teardown)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
                    apply once
   you ───────────────────────────────►  aoa-root.yaml
                                              │  (root Application + AppProjects)
                                              ▼
                                    apps/ (recursed by Argo CD)
                                       ├── aoa-platform.yaml ──► platform/apps/*  (~12–17 apps, per stack)
                                       ├── aoa-workloads-team1.yaml ──► workloads/team1/apps/*
                                       └── aoa-workloads-team2.yaml ──► workloads/team2/apps/*
                                              │
                                              ▼
              MinIO · LakeFS · PostgreSQL · MLflow · Kubeflow/Prefect ·
              KServe · Dask · Prometheus/Grafana · cert-manager · ESO …
```

- **Root app** (`aoa-root.yaml`) creates itself plus three `AppProject`s (`platform`,
  `workloads-team1`, `workloads-team2`) and recurses the `apps/` directory.
- Each file under `apps/` is itself an `Application` that points at a sub-tree
  (`platform/apps`, `workloads/team1/apps`, …), giving a two-level App-of-Apps tree.
- Every leaf `Application` has `syncPolicy.automated` with `prune: true` and
  `selfHeal: true`, and `CreateNamespace=true` — so namespaces are created automatically
  and drift is corrected continuously.
- **Secrets** are never committed. The External Secrets Operator (ESO) reads them from
  **Azure Key Vault** via a `ClusterSecretStore` (`base/external-secrets/secret-store.yaml`).
  The only secret you seed manually is the service-principal credential ESO uses to
  authenticate to the vault.

---

## Repository layout

```
mlops-apps/
├── base/
│   ├── charts/model/            # Reusable Helm chart: KServe InferenceService for an MLflow model
│   ├── dashboards/              # Grafana dashboard JSON (e.g. mlflow.json)
│   └── external-secrets/        # ClusterSecretStore pointing at Azure Key Vault
├── clusters/
│   ├── base/                    # Structure + environment-neutral values
│   │   ├── k8s-native-stack/    #   Kubeflow-centric; described and evaluated
│   │   ├── pythonic-stack/      #   Prefect-centric; companion study
│   │   └── _skeleton/           #   Template, never deployed
│   │       ├── apps/                    # Top-level AoA: platform + per-team workloads
│   │       ├── platform/
│   │       │   ├── apps/                # One Argo CD Application per platform service
│   │       │   └── components/          # Helm value overrides + extra manifests per service
│   │       └── workloads/team*/apps/    # ML workloads (e.g. the iris InferenceService)
│   └── envs/                    # What depends on where the platform runs
│       ├── minikube/k8s-native-stack/   # Single-node profile
│       └── datalab/k8s-native-stack/    # Multi-node profile
│           ├── aoa-root.yaml            # Apply this to bootstrap the stack
│           ├── apps/ platform/apps/     # The same Applications, naming this environment
│           └── platform/components/     # Only what this environment overrides
└── scripts/
    ├── install-argo.sh          # Installs Argo CD, prints admin password, port-forwards :8080
    ├── bootstrap-k8s-native.sh  # One-shot: credential → Argo CD → stack → served model (see RUNBOOK.md)
    ├── mlflow-dummy-model.py    # Trains + registers a demo iris model
    ├── promote-model.py         # Copies a registered version to its serving location in LakeFS
    ├── gen-env-layer.py         # Regenerates the per-environment Application layer
    ├── preflight/               # Offline checks: environment parity, runtime compatibility
    └── test/iris-batch-request.sh   # Sample KServe v2 inference request
```

`clusters/` is split so that a definition says one thing about the platform and a separate,
much smaller thing about the machine it runs on. See
[`clusters/README.md`](clusters/README.md).

Each stack directory also has its own short `README.md` with the exact port-forward
commands used for that stack.

---

## The three stacks

All three share the same platform layer — **MinIO, LakeFS, PostgreSQL (CloudNativePG), MLflow,
KServe behind Envoy Gateway, Kafka (Strimzi) + Redpanda Connect, Prometheus/Grafana,
cert-manager and ESO** — with identical sources, chart versions, sync waves and destination
namespaces. They differ in their **orchestration** layer and what it needs. Run **one stack per
cluster**.

| | `k8s-native-stack` | `pythonic-stack` | `_skeleton` |
|---|---|---|---|
| Role | described and evaluated | companion study | template, never deployed |
| Pipelines / orchestration | Kubeflow Pipelines, Katib, Trainer, Spark Operator | Prefect (server + worker) | — by design |
| Distributed compute | Dask | Dask | — |
| Pipeline RBAC | its own custom resources | its own custom resources | — |
| Environment profiles | `minikube`, `datalab` | single | — |
| Sample workloads | `team1/iris`, `team2/timeseries` | `team1/iris` | `team1/iris` |

Everything not in this table is the shared platform layer and is identical across all three.
`scripts/preflight/env-parity.py` reports what actually differs between the two environment
profiles of `k8s-native-stack`.

> **`_skeleton` is a template, not a stack to run.** It carries the platform layer with no
> orchestrator so that a new stack can be copied from it. Nothing is deployed from it and no
> result in either thesis is drawn from it. If you want a platform-only cluster, copy it to a
> stack of its own first.

---

## Bootstrap

The sequence below instantiates `k8s-native-stack` in a chosen environment. Set `CLUSTER_ENV`
to `minikube` or `datalab`; there is no default, because the profiles differ in event-bus
topology, replica counts and storage. To deploy `pythonic-stack` instead, apply
`clusters/base/pythonic-stack/aoa-root.yaml` — it has no environment layer. Run all commands
from the repository root (`poc/mlops-apps/`).

### 1. Provision Azure secrets backend (one time)

ESO needs an Azure Key Vault and a service principal that can read it. These are created by
the OpenTofu project in [`../mlops-eso-azure/`](../mlops-eso-azure/) — apply it first and
keep the outputs handy:

```bash
cd ../mlops-eso-azure
tofu init
tofu apply

# Read the values you'll need below:
tofu output -raw client_id
tofu output -raw client_secret
tofu output -raw tenant_id
tofu output -raw vault_uri
cd ../mlops-apps
```

> The `ClusterSecretStore` in `base/external-secrets/secret-store.yaml` has the vault URL
> and tenant ID **hard-coded**. If your `tofu output` values differ, update that file (and
> push it) before ESO can authenticate.

### 2. Start the cluster

```bash
minikube start --driver=docker --cpus=6 --memory=11g --disk-size=40g --extra-config=kubelet.serialize-image-pulls=false --extra-config=kubelet.max-parallel-image-pulls=3   # 16 GB host: see RUNBOOK.md
kubectl config use-context minikube
```

### 3. Seed the ESO bootstrap secret

ESO authenticates to Key Vault with a service-principal secret you create by hand (it is
the one secret that cannot itself come from the vault):

```bash
kubectl create namespace external-secrets

kubectl -n external-secrets create secret generic azure-sp-secret \
  --from-literal=ClientID="$(cd ../mlops-eso-azure && tofu output -raw client_id)" \
  --from-literal=ClientSecret="$(cd ../mlops-eso-azure && tofu output -raw client_secret)"
```

### 4. Install Argo CD

```bash
./scripts/install-argo.sh
```

The script installs the upstream Argo CD `stable` manifest into the `argocd` namespace,
waits for the API server to roll out, **prints the initial `admin` password**, and then
starts a foreground port-forward on `https://localhost:8080` (Ctrl+C to stop — Argo CD
keeps running).

Retrieve the admin password again at any time with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### 5. Deploy a stack

Apply the stack's root Application. Argo CD takes over and reconciles everything else:

```bash
export CLUSTER_ENV=minikube        # or: datalab
kubectl apply -f clusters/envs/${CLUSTER_ENV}/k8s-native-stack/aoa-root.yaml
```

The root Application is named `root-<env>`, so `kubectl -n argocd get app` states which profile
the cluster is carrying.

### 6. Watch the rollout

```bash
# Wait for everything to become Healthy/Synced
watch kubectl -n argocd get applications

# …or use the UI at https://localhost:8080  (user: admin)
```

Initial sync takes a while: CRDs (cert-manager, KServe, Kubeflow) install first, then the
services that depend on them. Sync waves order the rollout, and each waits for the previous one
to be Healthy (`install-argo.sh` restores Argo CD's health check for `Application` resources).
The platform tier occupies waves −9 to −2 and the orchestration tier follows in −1 and 0, so a slow or
failing orchestrator cannot hold a platform service back. Transient `OutOfSync`/`Degraded` states
during the first minutes are expected; failed syncs are retried until they succeed.

---

## Accessing services (port-forwarding)

Argo CD and most UIs are reached via `kubectl port-forward`. Open each in its own terminal
(or background them). Service names and namespaces below are taken from the
`k8s-native-stack` manifests; confirm anything unfamiliar with
`kubectl -n <ns> get svc`.

```bash
# Argo CD — https://localhost:8080  (self-signed cert; user: admin)
kubectl -n argocd port-forward svc/argocd-server 8080:443

# MinIO console — http://localhost:9001
kubectl -n platform-minio port-forward svc/minio-console 9001:9001

# MLflow — http://localhost:5000
kubectl -n platform-mlflow port-forward svc/mlflow 5000:80

# Grafana — http://localhost:5555
kubectl -n platform-monitoring port-forward svc/monitoring-grafana 5555:80

# Prometheus — http://localhost:9090
kubectl -n platform-monitoring port-forward svc/prometheus-operated 9090:9090
```

Other UIs — confirm the service name with `kubectl -n <ns> get svc` first (KFP is
`k8s-native-stack` only and Prefect is `pythonic-stack` only; LakeFS and Kafka UI ship in every
stack):

```bash
# Kubeflow Pipelines UI (k8s-native-stack) — http://localhost:8888
kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8888:80

# LakeFS (all stacks) — http://localhost:18000
kubectl -n platform-lakefs port-forward svc/lakefs 18000:80

# Prefect UI (pythonic-stack) — http://localhost:4200
kubectl -n platform-prefect port-forward svc/platform-prefect-server 4200:4200

# Kafka UI (all stacks) — http://localhost:7777
kubectl -n platform-kafka port-forward svc/platform-kafka-kafka-ui 7777:80
```

The LakeFS port is `18000` rather than `8000` because `promote-model.py` and the pipeline
tooling both default to it.

| Service | Namespace | Local URL | Credentials |
|---|---|---|---|
| Argo CD | `argocd` | https://localhost:8080 | `admin` / see step 4 |
| MinIO console | `platform-minio` | http://localhost:9001 | from MinIO secret / Key Vault |
| MLflow | `platform-mlflow` | http://localhost:5000 | none |
| Grafana | `platform-monitoring` | http://localhost:5555 | `admin` / from Grafana secret |
| Prometheus | `platform-monitoring` | http://localhost:9090 | none |
| Kubeflow Pipelines | `platform-kubeflow` | http://localhost:8081 | none |
| LakeFS | `platform-lakefs` | http://localhost:8000 | from LakeFS secret |
| Prefect *(pythonic)* | `platform-prefect` | http://localhost:4200 | basic-auth secret |
| Kafka UI *(skeleton)* | `platform-kafka` | http://localhost:7777 | none |

---

## Ingress & model serving

Model endpoints are served through the **Envoy Gateway**, which every stack deploys. Its Envoy
Service is `ClusterIP` in every environment (`platform/components/envoy-gateway/envoy-proxy.yaml`)
and is reached by port-forward, like every other platform endpoint:

```bash
kubectl -n platform-envoy-gateway port-forward \
  "$(kubectl -n platform-envoy-gateway get svc -o name \
      -l gateway.envoyproxy.io/owning-gateway-name=ingress-gateway)" 18080:80
```

Why not `LoadBalancer`: sync waves gate on health, and Argo CD's built-in check reports a Gateway
Progressing until it is Programmed, which requires an address. A `LoadBalancer` Service without a
load-balancer implementation (minikube without `minikube tunnel`, or a cloud project without one)
never gets an address, and that held the entire rollout in its first wave. A ClusterIP is always
assigned, so the upstream check applies unchanged. An environment that wants external exposure
changes the `EnvoyProxy`, not the controller.

KServe `InferenceService`s are then reachable by Host header through the forwarded port. A worked
example is in [`scripts/test/iris-batch-request.sh`](scripts/test/iris-batch-request.sh):

```bash
curl -s \
  -H "Host: iris-team1-iris.mlops.local" \
  -H "Content-Type: application/json" \
  -d '{"inputs":[{"name":"predict","shape":[3,4],"datatype":"FP64",
       "data":[[5.1,3.5,1.4,0.2],[6.2,3.4,5.4,2.3],[5.9,3.0,4.2,1.5]]}]}' \
  http://127.0.0.1:18080/v2/models/iris/infer | jq .
```

The `Host` header follows the pattern `<inference-service>-<namespace>.mlops.local`. The
serving chart (`base/charts/model`) also wires a KServe request **logger** to Redpanda
Connect (`platform-rp-connect`), so prediction traffic can be streamed onto Kafka for
monitoring.

---

## Demo workflow (train → register → serve)

1. **Train and register** a model in MLflow. Port-forward MLflow (`:5000`) first, then:

   ```bash
   python3.10 -m venv .venv-producer && source .venv-producer/bin/activate
   pip install -r scripts/requirements-producer.txt   # the runtime cannot load NumPy >= 2 pickles
   python scripts/mlflow-dummy-model.py
   ```

   This trains a logistic-regression iris classifier, logs metrics/params to the
   `demo-iris` experiment, and registers it as `tracking-quickstart`. Artifacts land in
   lakeFS, in the `mlflow` repository on branch `main` — MLflow's artifact root is the
   lakeFS S3 gateway, and MinIO is the block store underneath it rather than the interface.

2. **Promote it.** MLflow names artefacts with identifiers it mints at training time (an
   auto-increment experiment id and a random `m-<32 hex>` logged-model id), which cannot be
   written into a manifest ahead of the run. `promote-model.py` copies a registered version
   to a location composed only of names:

   ```bash
   kubectl -n platform-lakefs port-forward svc/lakefs 18000:80   # separate terminal
   export LAKEFS_ACCESS_KEY=... LAKEFS_SECRET_KEY=...            # or source ml-pipelines/tools/env_from_keyvault.sh
   python scripts/promote-model.py --name tracking-quickstart --version 1
   ```

   The copy is staged on a lakeFS branch and committed, so every promotion is an addressable,
   revertible lakeFS commit. The script prints a `MODEL_URI_PINNED` that names that commit
   instead of the branch, for when exact bytes matter more than convenience.

3. **Deploy it with KServe** using the reusable `model` chart. The workload
   ([`k8s-native-stack/workloads/team1/apps/iris.yaml`](clusters/base/k8s-native-stack/workloads/team1/apps/iris.yaml))
   renders `base/charts/model` with two values and no artifact path at all:

   ```yaml
   helm:
     valuesObject:
       fullnameOverride: "iris"
       model:
         name: "tracking-quickstart"
         version: "1"
   ```

   which the chart composes into
   `s3://mlflow/main/serving/tracking-quickstart/1`. Because both values are known in advance,
   the manifest is written **before** the model exists and is never rewritten by a cluster run.
   Raising `model.version` is the promotion event: it changes the `storageUri`, which is what
   makes KServe roll a new predictor, and it is a reviewable Git commit.

   If the promotion step has not run for that name and version, the storage-initializer fails
   with `NoSuchKey` and the predictor stays in `Init`. That is the intended signal: the manifest
   declares an intent the registry has not yet satisfied.

4. **Query it** via the gateway (see [Ingress & model serving](#ingress--model-serving)).

---

## Namespace reference

`platform-*` namespaces hold platform services; `team*-*` namespaces hold tenant workloads.
(Set shown for `k8s-native-stack`; the pythonic stack swaps the Kubeflow namespaces for
`platform-prefect`, the skeleton adds `platform-kafka` / `platform-rp-connect` /
`envoy-gateway-system`.)

| Namespace | Contents |
|---|---|
| `argocd` | Argo CD |
| `external-secrets` | External Secrets Operator + `azure-sp-secret` |
| `cert-manager` | cert-manager |
| `platform-minio` | MinIO (S3 object storage) |
| `platform-lakefs` | LakeFS (git-style data versioning) |
| `platform-mlflow` | MLflow tracking server |
| `platform-postgres` | CloudNativePG (mlflow / lakefs databases) |
| `platform-monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| `platform-compute` | Dask |
| `platform-kubeflow` | Kubeflow Pipelines, Katib |
| `platform-kubeflow-system` | Kubeflow Trainer |
| `platform-kubeflow-spark-operator` | Spark Operator |
| `platform-kserve` | KServe controller |
| `kubeflow`, `compute`, `mlops` | Shared workload / pipeline-runner namespaces |

---

## Teardown

```bash
# Remove a stack (deletes its Applications; finalizers prune the managed resources)
kubectl delete -f clusters/envs/${CLUSTER_ENV}/k8s-native-stack/aoa-root.yaml

# Or nuke the whole local cluster
minikube delete
```

Deleting the root app triggers Argo CD's `resources-finalizer`, which prunes everything it
created. Give it time before deleting namespaces manually.

---

## Troubleshooting

**lakeFS has no admin / MLflow artifact upload fails with an auth error.** The admin user and
the `mlflow` and `datasets` repositories are created by the PostSync hook `job/lakefs-init` of
`platform-lakefs`. Check it with `kubectl -n platform-lakefs logs job/lakefs-init`; a hook that
failed is retried with the Application's sync, and re-syncing `platform-lakefs` re-runs it
(both steps are idempotent).

**ExternalSecrets stay `SecretSyncError` / store `not ready`.** Check that `azure-sp-secret`
exists in `external-secrets` (keys `ClientID`/`ClientSecret`) and that the `vaultUrl`/`tenantId`
in `base/external-secrets/secret-store.yaml` match your `tofu output` values — and that your
`az login` is in the **right tenant/subscription** (the Key Vault rejects tokens from any
other tenant). Inspect with `kubectl -n external-secrets describe clustersecretstore azure-keyvault`.
If you seeded `azure-sp-secret` *after* ESO first reconciled, the `ClusterSecretStore` can stay
`Ready=False` on a stale cache — force a re-read with
`kubectl -n external-secrets rollout restart deploy/<eso-release>-external-secrets`.

**`password authentication failed` for a DB user (MLflow / LakeFS / Prefect).** Services that
embed the password into a connection URI break if the generated password contains URL
metacharacters (`%` starts percent-decoding, `@` splits userinfo/host). `secrets.tofu`
generates URL-safe passwords (`override_special = "_-"`); if you regenerated secrets with an
older charset, run `tofu apply` to rotate them and let ESO re-sync.

**Kafka pods `Pending` / "unbound immediate PersistentVolumeClaims".** The cluster has no
StorageClass matching what the manifest requests. The Strimzi storage block uses the cluster
default SC; ensure a default StorageClass exists (`kubectl get sc`). On minikube that's
`standard`; on OpenStack/Cinder it's `csi-cinder`. (Earlier revisions hard-coded
`class: standard`, which left PVCs Pending on non-minikube clusters.)

**KServe predictor `CrashLoopBackOff` with `Unrecognized serialization format: skops`.**
MLflow 3.x logs scikit-learn models in the `skops` format by default, but the KServe
MLServer runtime can only deserialize `pickle`/`cloudpickle`. Log the model with
`mlflow.sklearn.log_model(..., serialization_format="cloudpickle")` (the demo
`scripts/mlflow-dummy-model.py` already does). Then promote the new version and raise
`model.version` in the workload manifest.

**KServe predictor `CrashLoopBackOff` *after* the artefact downloaded successfully**, with
`TypeError: code expected at most 16 arguments, got 18`. The artefact was pickled under a newer
Python than the serving runtime's. `seldonio/mlserver` is **Python 3.10** on every released tag
through 1.7.1, and MLflow's PyTorch flavour cloudpickles a model class defined in `__main__` *by
value*, embedding code objects the older interpreter cannot read. Models whose class comes from a
library (scikit-learn, XGBoost) pickle by reference and are unaffected, which is why the iris
demonstration never hit this.

Fix it on the producing side: build the training image on `python:3.10-slim`, or move the model
class into an importable module so it pickles by reference. Check a runtime's versions with:

```bash
docker run --rm --entrypoint python seldonio/mlserver:1.5.0 \
  -c "import sys, mlflow, torch; print(sys.version, mlflow.__version__, torch.__version__)"
```

The MLflow *major* version is not the issue: mlflow 2.10.2 in the runtime reads an `MLmodel`
written by mlflow 3.3.2 without complaint.

**MLflow artifact upload fails against lakeFS.** The lakeFS S3 gateway reads the first path
segment of a key as the ref, so the artifact destination must carry a branch:
`artifactRoot.s3.path: main`. Without it the chart renders `--artifacts-destination=s3://mlflow/`,
MLflow writes to `s3://mlflow/<experiment-id>/…`, and lakeFS rejects the unknown ref.

**KServe predictor stuck `Pending` ("Insufficient cpu").** The predictor defaults to a
`1` CPU / `2Gi` request (request == limit). On a small/loaded cluster, set lighter
`spec.predictor.model.resources` on the InferenceService, or free capacity.

**App stuck `OutOfSync` / `Degraded` on first sync.** Usually a CRD ordering issue —
cert-manager, KServe, and Kubeflow CRDs must install before their consumers. It typically
resolves on the next auto-sync; otherwise hit **Sync** in the Argo CD UI or
`kubectl -n argocd patch app <name> ...`. Confirm CRDs with `kubectl get crd | grep -E 'cert-manager|kserve|kubeflow'`.

**My change isn't showing up.** Argo CD reconciles the **pushed** `master` branch, not your
local files. Commit and push, then `argocd app sync <name>` or wait for the poll interval.

**Argo CD shows a TLS warning at `:8080`.** Expected — it serves a self-signed certificate.
Accept it or use `--insecure` with the `argocd` CLI.

**`install-argo.sh` aborts with `metadata.annotations: Too long`.** The `applicationsets`
CRD exceeds the 256 KB client-side `last-applied-configuration` limit. The script applies the
manifest with `kubectl apply --server-side`; if you install Argo CD by hand, use
`kubectl apply --server-side=true --force-conflicts -n argocd -f <install.yaml>`.
