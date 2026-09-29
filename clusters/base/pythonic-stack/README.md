# Pythonic stack — base

The same platform tier under a different orchestration layer: Prefect and Dask in place of KFP,
Katib and the Kubeflow Trainer. It is deployed and evaluated in the companion implementation
study, not by this thesis.

## Profiles

This stack now runs in the same two environments as `k8s-native-stack` (the companion study
evaluates both stacks on Minikube and on the dataLAB cluster), so it carries the same
environment layer. `clusters/envs/<env>/pythonic-stack/` holds the generated Application layer
and the platform overlays, which are copies of the `k8s-native-stack` overlays: every key they
set is structurally neutral (replicas, resources, volumes), so both stacks get the same platform
profile. Regenerate and check the layer with

```bash
python3 scripts/gen-env-layer.py pythonic-stack
python3 scripts/preflight/env-parity.py --stack pythonic-stack
```

and deploy it with

```bash
kubectl apply -f clusters/envs/<env>/pythonic-stack/aoa-root.yaml
```

This directory, like `base/k8s-native-stack/`, is a template and not an entry point.

## Relationship to the other stacks

The platform applications are identical to `k8s-native-stack`'s in sources, chart versions, sync
waves, destination namespaces and values; what differs is the orchestrator, its supporting RBAC
(`rbac-pipeline-runner` grants each orchestrator's own custom resources) and its namespaces.

The prerequisites, port-forwards and inference request are in
[`README.md`](../../../README.md); the pipeline code is in the companion `ml-pipelines`
repository.
