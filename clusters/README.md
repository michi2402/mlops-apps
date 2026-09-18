# Cluster definitions

```
clusters/
  base/
    k8s-native-stack/      structure + neutral values; NOT an entry point
    pythonic-stack/        companion stack, single profile
    _skeleton/             copy-paste template, never deployed
  envs/
    minikube/k8s-native-stack/    single-node profile
    datalab/k8s-native-stack/     multi-node profile
```

## The split

`base/k8s-native-stack/` holds everything that does not depend on where the platform
runs: which applications exist, which charts and versions they name, their sync waves,
their destination namespaces, their sync policy, and the values that are the same
everywhere.

`envs/<env>/k8s-native-stack/` holds everything that does. An environment is an
*overlay*, never a copy:

- for Helm-delivered components it is a second `valueFiles` entry, merged after the
  base, so it wins on exactly the keys it sets;
- for the event bus, whose profile is a topology rather than a set of values, it is a
  kustomize overlay patching the base.

The `platform/apps/` tree under each environment is generated from the base and
differs **only** in the environment token. `scripts/preflight/env-parity.py` asserts
that and fails if anything else has drifted, which is what keeps two environments from
becoming two forks.

## Deploying

```bash
CLUSTER_ENV=minikube CLIENT_ID=... CLIENT_SECRET=... ./scripts/bootstrap-k8s-native.sh
```

`CLUSTER_ENV` has no default. The profiles differ in event-bus topology, replica counts
and storage; deploying the wrong one is a mistake that only becomes obvious later.

Applying the root by hand instead:

```bash
kubectl apply -f clusters/envs/<env>/k8s-native-stack/aoa-root.yaml
```

The root Applications are named `root-<env>`, so `kubectl get app -n argocd` states
which profile a cluster is carrying.

`base/k8s-native-stack/aoa-root.yaml` and its `apps/` tree are the **templates** the
environment layer is generated from. They are not entry points: applying the base root
would deploy the stack with no profile at all.

## What the profiles differ in

Run `python3 scripts/preflight/env-parity.py` for the current, exact answer. It prints
every key each environment sets, and the share of the base configuration that
represents.
