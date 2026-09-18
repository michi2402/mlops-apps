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
| **Tools** | `kubectl`, `git`, `curl`, `python3` with `mlflow scikit-learn pandas` installed |
| **Repo state** | You are on the commit you want deployed, and it is **pushed** — Argo CD pulls from `https://github.com/michi2402/mlops-apps` over HTTPS, not your local working copy. `git status --porcelain` should be clean and `git log --oneline origin/master..HEAD` empty. The bootstrap script does not push anything, so this is a precondition, not something it fixes. |

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
   CLIENT_ID="..." CLIENT_SECRET="..." ./scripts/bootstrap-k8s-native.sh
   ```
   It seeds the credential, installs Argo CD, applies the stack, waits for the platform tier
   to be `Synced`/`Healthy`, initialises lakeFS (admin user plus the `mlflow` and `datasets`
   repositories), trains and registers a demo iris model in MLflow, promotes that model version
   to the lakeFS location the workload manifest already names, and waits for it to be `Ready`.

   **It never writes to Git.** The manifests name a model by registry name and version, not by
   an MLflow artifact path, so nothing has to be rewritten by a cluster run. It is idempotent —
   re-running it against a cluster it already bootstrapped is safe — and it exits non-zero with
   diagnostics on any failure rather than continuing past a broken step.
3. **(local clusters only) Tunnel the gateway** so the printed URL is reachable:
   ```bash
   minikube tunnel
   ```
   Cloud-backed clusters (e.g. dataLAB/OpenStack) get a real external IP automatically — find
   it with `kubectl -n platform-envoy-gateway get svc --field-selector spec.type=LoadBalancer`.

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

Once the script finishes, the model is reachable through the Envoy Gateway by `Host` header
(pattern `<inference-service>-<namespace>.mlops.local`):

```bash
curl -s -H "Host: iris-team1-iris.mlops.local" -H "Content-Type: application/json" \
  -d '{"inputs":[{"name":"predict","shape":[3,4],"datatype":"FP64",
       "data":[[5.1,3.5,1.4,0.2],[6.2,3.4,5.4,2.3],[5.9,3.0,4.2,1.5]]}]}' \
  http://127.0.0.1:80/v2/models/iris/infer | jq .
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
`model.version` in `clusters/local/k8s-native-stack/workloads/team2/apps/timeseries.yaml` — plus
the matching promotion. That Git commit *is* the rollout, and Argo CD rolls a new predictor from it.

---

## Teardown

```bash
kubectl delete -f clusters/local/k8s-native-stack/aoa-root.yaml   # prunes everything Argo CD created
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
| Predictor container fails *after* the download succeeded | `kubectl -n team1-iris logs <pod> -c kserve-container`. The MLServer MLflow runtime loads through `mlflow.pyfunc`; a flavour whose dependencies are absent from `seldonio/mlserver` (notably `torch`) fails here, not at deploy time. |
| MLflow artifact upload fails | lakeFS reads the first path segment of a key as the ref, so `artifactRoot.s3.path` must name a real branch. Without it MLflow writes to `s3://mlflow/<experiment-id>/…` and lakeFS rejects the unknown ref. |
| ExternalSecrets stuck `SecretSyncError` | Wrong Azure tenant: the vault lives in the "Azure Sandbox" tenant, not the one `az login` selects by default. |
