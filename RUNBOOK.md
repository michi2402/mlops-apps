# Runbook — bare cluster to a served model

For someone with `kubectl` against a cluster and no prior context on this repo. This is the
fast, scripted path through the `k8s-native-stack`. For the general, stack-agnostic walkthrough
(all three stacks, manual step-by-step) see [`README.md`](README.md).

---

## Prerequisites

| | |
|---|---|
| **Cluster** | Any Kubernetes cluster you have `cluster-admin` `kubectl` access to (minikube, or a cloud-provisioned cluster such as TU Wien dataLAB). Sizing: twelve platform applications including a 3-controller/3-broker Kafka cluster and a 2-instance PostgreSQL is not small — budget at least ~8 CPU cores / ~16 GiB allocatable. Check with: |
| | `kubectl get nodes -o wide && kubectl describe nodes \| grep -A5 'Allocatable:'` |
| **Azure Key Vault** | A vault + service principal with read access, provisioned once via [`../mlops-eso-azure/`](../mlops-eso-azure/) (`tofu apply`). You need its `client_id` / `client_secret` outputs before you start — nothing reconciles without them. |
| **Tools** | `kubectl`, `git`, `curl`, `python3`, and a **Python 3.10** environment built from [`scripts/requirements-producer.txt`](scripts/requirements-producer.txt), passed to the bootstrap as `PYTHON=`. The pin is not incidental: a model pickled under NumPy ≥ 2 cannot be loaded by the serving runtime. |
| **Repo state** | You are on the commit you want deployed, and it is **pushed** — Argo CD pulls from `https://github.com/michi2402/mlops-apps` over HTTPS, not your local working copy. `git status --porcelain` should be clean and `git log --oneline origin/master..HEAD` empty. The bootstrap script does not push anything, so this is a precondition, not something it fixes. |

### Local cluster on a 16 GB laptop

The `minikube` profile is sized for one node of about 11 GiB, which a 16 GB machine can
give while keeping ~4 GB for the host. On Windows with Docker Desktop (WSL 2 backend), WSL
caps memory at half the host by default, so raise it first in `%UserProfile%\.wslconfig`
and restart WSL (`wsl --shutdown`):

```ini
[wsl2]
memory=12GB
processors=6
swap=4GB
```

Then start the node below that cap, leaving room for the Docker VM itself:

```bash
minikube start --driver=docker --cpus=6 --memory=11g --disk-size=40g \
  --extra-config=kubelet.serialize-image-pulls=false
```

The last flag matters on a fresh node: by default the kubelet pulls one image at a time, and
the orchestrators' ~20 images then queue ahead of MLflow's, so the serving path waits on images
it does not need (evidence/local-laptop LAP-03).

What the profile trims for this size (values and rationale in [`RESOURCES.md`](RESOURCES.md)):
one Kafka controller and broker with small heaps, one MLflow server worker, one Dask worker
and no notebook server, one PostgreSQL instance, standalone MinIO, and 12 h in-memory
Prometheus retention. The bootstrap waits for the serving path only; the orchestrators take
the last waves, so on a tight node they are the part that degrades first (evidence/local
INT-03). Check headroom after convergence with
`kubectl describe node minikube | grep -A8 'Allocated resources'`: requests near 100 % of
allocatable mean the next pod stays `Pending`.

---

## The three operator actions

Everything else is automated by `scripts/bootstrap-k8s-native.sh`. What you provide by hand:

1. **The Key Vault credential** — the one secret that cannot itself come from the vault:
   ```bash
   cd ../mlops-eso-azure && tofu output -raw client_id     # → CLIENT_ID
   tofu output -raw client_secret                            # → CLIENT_SECRET
   cd -
   ```
2. **Run the bootstrap script** from the repo root:
   ```bash
   cd poc/mlops-apps
   CLUSTER_ENV=datalab CLIENT_ID="..." CLIENT_SECRET="..." ./scripts/bootstrap-k8s-native.sh
   ```
   It seeds the credential, installs Argo CD, applies the stack, waits for the platform tier
   to be `Synced`/`Healthy`, waits for the PostSync hook `job/lakefs-init` that the
   `platform-lakefs` Application declares to have created the lakeFS admin user and the `mlflow`
   and `datasets` repositories, trains and registers a demo iris model in MLflow, promotes that model version
   to the lakeFS location the workload manifest already names, and waits for it to be `Ready`.

   **It never writes to Git.** The manifests name a model by registry name and version, not by
   an MLflow artifact path, so nothing has to be rewritten by a cluster run. It is idempotent —
   re-running it against a cluster it already bootstrapped is safe — and it exits non-zero with
   diagnostics on any failure rather than continuing past a broken step.
3. **Forward the gateway** so the printed URL is reachable. The Envoy Service is `ClusterIP` in
   every environment (`platform/components/envoy-gateway/envoy-proxy.yaml`), so no tunnel or
   cloud load balancer is involved:
   ```bash
   kubectl -n platform-envoy-gateway port-forward \
     "$(kubectl -n platform-envoy-gateway get svc -o name \
         -l gateway.envoyproxy.io/owning-gateway-name=ingress-gateway)" 18080:80
   ```

Total unattended runtime is mostly waiting on Argo CD convergence; the script prints how long
that took.

---

## Reaching each UI

Everything else is `kubectl port-forward`; there is no public ingress to these UIs by design.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443              # https://localhost:8080  (admin / printed by install-argo.sh)
kubectl -n platform-minio port-forward svc/minio-console 9001:9001     # https://localhost:9001
kubectl -n platform-mlflow port-forward svc/mlflow 5000:80             # http://localhost:5000
kubectl -n platform-monitoring port-forward svc/monitoring-grafana 5555:80   # http://localhost:5555
kubectl -n platform-monitoring port-forward svc/prometheus-operated 9090:9090 # http://localhost:9090
kubectl -n platform-kafka port-forward svc/platform-kafka-kafka-ui 7777:80    # http://localhost:7777
kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8888:80            # http://localhost:8888 (Kubeflow Pipelines)
kubectl -n platform-lakefs port-forward svc/lakefs 18000:80            # http://localhost:18000 (lakeFS)
```

---

## The inference request

Once the script finishes, the model is reachable through the forwarded Envoy Gateway port by
`Host` header (pattern `<inference-service>-<namespace>.mlops.local`):

```bash
curl -s -H "Host: iris-team1-iris.mlops.local" -H "Content-Type: application/json" \
  -d '{"inputs":[{"name":"predict","shape":[3,4],"datatype":"FP64",
       "data":[[5.1,3.5,1.4,0.2],[6.2,3.4,5.4,2.3],[5.9,3.0,4.2,1.5]]}]}' \
  http://127.0.0.1:18080/v2/models/iris/infer | jq .
```

For any other model, do not hand-write the payload — the feature width is a property of the
artefact, and the iris shape (3x4) is wrong for anything the orchestrated pipeline produces.
`promote-model.py --write-request FILE` derives a payload from the model's logged
`input_example`; the bootstrap script leaves the iris one at `/tmp/iris-request.json`.

A successful response depends on the secret path, the tenant namespace, the object store, the
model registry and the gateway all being simultaneously operational — it is evidence about the
platform, not just the model. Every prediction is also logged to the `inference-events` Kafka
topic (`platform-kafka`); inspect it with:

```bash
kubectl -n platform-kafka run kcat --rm -it --restart=Never --image=edenhill/kcat:1.7.1 -- \
  -b platform-kafka-kafka-bootstrap:9092 -t inference-events -C -o beginning -e
```

---

## Serving a second model

The repository declares a second tenant workload, `workloads-team2-timeseries`, naming the model
the Kubernetes-native orchestrator's KFP pipeline produces (`timeseries-model`; see the companion
`ml-pipelines` repository). It stays `Degraded` until that model exists, which is the correct
behaviour rather than a fault: the manifest declares an intent the registry has not yet satisfied.

To satisfy it, run the pipeline, then promote:

```bash
python3 scripts/promote-model.py --name timeseries-model --version 1
```

No manifest is edited. Rolling out a later version is one line —
`model.version` in `clusters/base/k8s-native-stack/workloads/team2/apps/timeseries.yaml` — plus
the matching promotion. That Git commit *is* the rollout, and Argo CD rolls a new predictor from it.

---

## Teardown

```bash
kubectl delete -f clusters/envs/<env>/k8s-native-stack/aoa-root.yaml   # prunes everything Argo CD created
# or, to discard the whole cluster:
minikube delete
```

---

## Troubleshooting

See [`INTERVENTIONS.md`](INTERVENTIONS.md) for issues hit during actual validation runs, and
[`README.md#troubleshooting`](README.md#troubleshooting) for the general (stack-agnostic) list.

The repository no longer ships a stale `modelUri`: manifests name a registry coordinate and
`promote-model.py` materialises it. The first-run failures that remain are, in order of
likelihood:

| Symptom | Check |
|---|---|
| Storage initializer `CrashLoopBackOff` | `kubectl -n team1-iris logs <pod> -c storage-initializer`. Either the promotion step never ran for that name and version, or lakeFS rejected the ref. |
| Predictor container fails *after* the download succeeded | `kubectl -n <ns> logs <pod> -c kserve-container`. `TypeError: code expected at most 16 arguments, got 18` means the artefact was pickled under Python 3.11 while `seldonio/mlserver` is Python 3.10 on every tag through 1.7.1. Rebuild the training image on `python:3.10-slim`, or move the model class out of `__main__` so it pickles by reference. See [`README.md`](README.md#troubleshooting). |
| Predictor fails with `No module named 'numpy._core.numeric'` | The model was registered from an environment with NumPy ≥ 2, which the runtime's NumPy predates. Register it again from the producer environment (`scripts/requirements-producer.txt`); `mlflow-dummy-model.py` and the bootstrap now refuse to run outside it. |
| Applications stay `OutOfSync` while `Healthy`, and `selfHeal` does not revert drift | The first sync against this revision failed (a CRD or webhook from an earlier wave was not ready) and Argo CD does not re-attempt a failed automated sync against the same revision. Every Application now carries `syncPolicy.retry` (unbounded, with `refresh`), and `install-argo.sh` restores health assessment for `Application` resources so the waves wait for each other. On a cluster installed before either change: `kubectl -n argocd patch applications.argoproj.io <app> --type merge -p '{"operation":{"sync":{}}}'`. If the sync *succeeds* and the Application is still `OutOfSync` on `ExternalSecret`s, CRDs or the CNPG `Cluster`, the cause is different: API-server defaults read as drift under `ServerSideApply`. `install-argo.sh` sets `controller.diff.server.side: "true"` in `argocd-cmd-params-cm`; on an older install, set it and restart the application controller. |
| A fresh rollout stalls in an early wave, the parent waiting on one child that never becomes Healthy | A CRD consumer sits in the same or an earlier wave than the Application that installs the CRD. `python scripts/preflight/wave-order.py --context <ctx>` names it. |
| `inference-events` stays empty although inference succeeds | The `rp-connect` Service must target port 8080 numerically; the chart's default resolves to its admin server (4195), which answers the KServe logger with 404 while reporting Healthy. |
| MLflow artifact upload fails | lakeFS reads the first path segment of a key as the ref, so `artifactRoot.s3.path` must name a real branch. Without it MLflow writes to `s3://mlflow/<experiment-id>/…` and lakeFS rejects the unknown ref. |
| ExternalSecrets stuck `SecretSyncError` | Wrong Azure tenant: the vault lives in the "Azure Sandbox" tenant, not the one `az login` selects by default. |
