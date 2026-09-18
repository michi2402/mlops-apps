# Pythonic stack — base

The same platform tier under a different orchestration layer: Prefect and Dask in place of KFP,
Katib and the Kubeflow Trainer. It is deployed and evaluated in the companion implementation
study, not by this thesis.

## Single profile, by design

This stack has **no environment layer**. `clusters/envs/` carries profiles for
`k8s-native-stack` only, because that is the stack instantiated in two materially different
environments; a stack that runs in one place does not need the split, and adding one it does
not use would cost drift for nothing. Its root Application therefore lives here:

```bash
kubectl apply -f clusters/base/pythonic-stack/aoa-root.yaml
```

If this stack ever has to run somewhere materially different, give it a profile the same way —
see [`../../README.md`](../../README.md).

## Relationship to the other stacks

The platform applications are identical to `k8s-native-stack`'s in sources, chart versions, sync
waves, destination namespaces and values; what differs is the orchestrator, its supporting RBAC
(`rbac-pipeline-runner` grants each orchestrator's own custom resources) and its namespaces.

The prerequisites, port-forwards and inference request are in
[`README.md`](../../../README.md); the pipeline code is in the companion `ml-pipelines`
repository.
