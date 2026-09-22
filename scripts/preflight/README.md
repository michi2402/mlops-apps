# Serving-runtime compatibility check

Answers one question before a cluster is involved: **can the image KServe will use actually load
the artefact the training image will produce?**

It is worth asking because the failure mode is misleading. The storage initializer downloads the
artefact successfully and the *predictor* container then crash-loops, which looks like a
serving-runtime fault rather than a producer fault, and nothing in the logs mentions the real
cause.

## Running it

```bash
D=$(mktemp -d)
cp produce-models.py "$D/" && cp load-in-runtime.py "$D/"

# Produce under the Python version the TRAINING image uses.
docker run --rm -e TAG=py3.11 -v "$D:/work" -w /work python:3.11-slim bash -lc \
  "pip install -q 'numpy<2' 'mlflow==3.3.2' scikit-learn 'torch==2.2.1' \
     --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple; \
   python produce-models.py"

# Load in the image the ClusterServingRuntime names for modelFormat: mlflow.
docker run --rm -v "$D:/work" -w /work --entrypoint python \
  docker.io/seldonio/mlserver:1.5.0 load-in-runtime.py
```

Repeat the first command with another `python:X.Y-slim` and a different `TAG` to compare; the
loader reports every `served-*` directory it finds.

## Result, 2026-09-18

| Component | Python | MLflow | torch |
|---|---|---|---|
| `seldonio/mlserver:1.5.0` — what KServe v0.15's `kserve-mlserver` runtime uses | **3.10.12** | 2.10.2 | 2.2.1 |
| `seldonio/mlserver:1.7.1-mlflow` — newest released | **3.10.12** | 2.22.1 | absent |
| `ghcr.io/julianzeilinger/trainer:main` — the pipeline's training image | **3.11** | 3.3.2 | 2.x |

Producing with mlflow 3.3.2 and loading in `mlserver:1.5.0`:

| Produced under | sklearn flavour | pytorch flavour |
|---|---|---|
| Python 3.10 | loads, predicts | loads, predicts |
| Python 3.11 | loads, predicts | **`TypeError: code expected at most 16 arguments, got 18`** |

**The MLflow major version is not the cause** — 2.10.2 reads a 3.3.2-written `MLmodel` without
difficulty. **A missing dependency is not the cause** — `torch` is present. The cause is the
**Python version**: a model class defined in `__main__` is cloudpickled *by value*, embedding
code objects whose layout changed in 3.11, and 3.10 cannot read them. A library class such as
`LogisticRegression` is pickled by reference and is unaffected.

**Remedy:** build the training image on `python:3.10-slim`, or move the model class into an
importable module so it pickles by reference. Moving to a newer serving runtime does not help —
every released MLServer through 1.7.1 is Python 3.10.

# Sync-wave order check

`wave-order.py` checks that every custom resource an Application manages has its CRD installed by
an Application in a *strictly earlier* wave. Since `install-argo.sh` makes each wave wait for the
previous one to be Healthy, a consumer in the same wave as its CRD's provider races it, and a
consumer in an *earlier* wave deadlocks the rollout: its sync fails on discovery, it never becomes
Healthy, and no later wave starts.

```bash
python scripts/preflight/wave-order.py --context minikube   # needs a cluster the stack ran on once
```

Kinds are read from the Applications' status on a live cluster; waves from the working tree, so a
reordering can be checked before it is pushed. On 2026-09-21 it found `cert-manager` shipping a
`ServiceMonitor` whose CRD `monitoring` installed two waves later — a deadlock on any fresh
cluster — and `minio` racing `monitoring` in the same wave. `monitoring` moved into a wave of its
own ahead of both; the check now reports none (`evidence/local/E21c`).
