# Kubernetes-native stack — base

The platform tier plus a Kubeflow-based orchestration layer: KFP, Katib, the Kubeflow Trainer,
the Spark operator and Dask. This is the stack the thesis describes and evaluates.

**This directory is not an entry point.** It holds the structure — which applications exist,
which charts and versions they name, their sync waves, destination namespaces and sync policy,
and the values that hold on every target. What depends on where the platform runs lives in
[`../../envs/<env>/k8s-native-stack/`](../../envs), and the root Application lives there too.
See [`../../README.md`](../../README.md) for the split.

`aoa-root.yaml` and the `apps/` trees here are the **templates** that
`scripts/gen-env-layer.py` generates the environment layer from. Applying this root directly
would deploy the stack with no environment profile at all.

## Deploying

```bash
CLUSTER_ENV=minikube CLIENT_ID=... CLIENT_SECRET=... ./scripts/bootstrap-k8s-native.sh
```

`CLUSTER_ENV` is `minikube` or `datalab` and has no default. The full walkthrough, including
the prerequisites, the port-forwards and the inference request, is in
[`RUNBOOK.md`](../../../RUNBOOK.md); the stack-agnostic reference is
[`README.md`](../../../README.md).

## What lives here

| | |
|---|---|
| `apps/` | second tier: the platform Application and one per tenant |
| `platform/apps/` | leaf Applications, one per platform service |
| `platform/components/` | value overrides and raw manifests per service |
| `workloads/team1/apps/` | tenant workload: the `iris` model (script-produced) |
| `workloads/team2/apps/` | tenant workload: `timeseries-model` (pipeline-produced) |

Tenant workloads carry **no** environment profile: the model chart renders the same
`InferenceService` wherever it runs, and it names a registry coordinate rather than an artefact
path, so they stay here rather than being duplicated per environment.

## What an environment may change

Run `python3 scripts/preflight/env-parity.py` for the exact, current answer. It also asserts
that the two environments' Application layers are identical apart from the environment token,
and exits non-zero if that has stopped being true.
