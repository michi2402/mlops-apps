# team2 — placeholder tenant tier

This directory is intentionally empty of workloads.

The `workloads-team2` `AppProject` and the `aoa-workloads-team2` `Application` are declared so
that the repository demonstrates the full tenant-onboarding path: adding a second team requires
one second-level `Application`, one `AppProject`, and a directory such as this one. Dropping a
model `Application` here — the same shape as `../../team1/apps/iris.yaml` — is the entire
onboarding action.

ArgoCD renders no resources from this directory, so the `aoa-workloads-team2` `Application`
reports `Synced`/`Healthy` while carrying no workload.
