# Resource requests and limits

Every platform component this repository configures declares requests and limits. The
values follow one rule, so that a reader can re-derive any of them:

- **Memory request** = the working set observed in `evidence/local/E61-fitness.txt`
  (`kubectl top`, 2026-09-18, full stack on one minikube node), rounded up to the next
  power of two, at least 64Mi.
- **Memory limit** = twice the request.
- **CPU**: 10m–100m requested, 100m–1 core limit, by the same convention as the components
  that already declared resources (Redpanda Connect, Dask). CPU is compressible, so the
  CPU values bound contention rather than protect against termination.

The observation is a single snapshot taken while the node ran at 83 % memory, so the
values are a starting point. Re-derive them from Prometheus
(`container_memory_working_set_bytes`) once a run has been observed for longer.

| Component | Observed (E61) | Request | Limit | Where |
|---|---|---|---|---|
| Envoy Gateway controller | 94Mi | 128Mi | 256Mi | `apps/envoy-gateway.yaml` |
| Envoy proxy | 62Mi | 64Mi | 128Mi | `components/envoy-gateway/envoy-proxy.yaml` |
| External Secrets controller / cert controller / webhook | 66Mi / 69Mi / <61Mi | 128 / 128 / 64Mi | 256 / 256 / 128Mi | `apps/external-secrets.yaml` |
| cert-manager controller / webhook / cainjector | 72Mi† / <61Mi / 107Mi | 128 / 64 / 128Mi | 256 / 128 / 256Mi | `apps/cert-manager.yaml` |
| CloudNativePG operator | 73Mi | 128Mi | 256Mi | `apps/postgres.yaml` |
| PostgreSQL instance | 157Mi | 256Mi | 512Mi | `components/postgres/values.yaml` |
| KServe controller (manager / rbac proxy) | 95Mi (pod) | 128 / 64Mi | 256 / 128Mi | `components/kserve/values.yaml` |
| lakeFS | 67Mi | 128Mi | 256Mi | `components/lakefs/values.yaml` |
| MLflow (4 workers) | 779Mi | 1Gi | 2Gi | `components/mlflow/values.yaml` |
| Strimzi cluster operator | 277Mi | 512Mi | 1Gi | `apps/strimzi-operator.yaml` |
| Kafka UI | 402Mi | 512Mi | 1Gi | `components/kafka-ui/values.yaml` |
| Model predictor (chart default) | 271Mi | 512Mi | 1Gi | `base/charts/model/values.yaml` |
| Prometheus | 392Mi† | 512Mi | 1Gi | `components/monitoring/values.yaml` (+ local profile) |
| Grafana / each sidecar | 255Mi† (capped at the former 256Mi limit) / 95Mi† | 512 / 128Mi | 1Gi / 256Mi | `components/monitoring/values.yaml` |
| kube-state-metrics / node exporter / Prometheus operator | 68Mi† / 21Mi† / 34Mi† | 128 / 64 / 64Mi | 256 / 128 / 128Mi | `components/monitoring/values.yaml` |
| Spark operator controller | 55Mi† | 128Mi | 512Mi | `components/kubeflow-spark-operator/values.yaml` |

"<61Mi" means below the 30 largest pods the capture lists; those get the 64Mi floor.
† observed in the laptop run (`evidence/local-laptop/E61-fitness-served.txt`, 2026-09-24),
which also found that the exporters' and the Spark controller's former values sat under keys
their charts ignore. Grafana ran at its limit, so its demand is at least what was observed and
the next power of two above it was taken.

Not declared by this repository: the orchestrators delivered as upstream kustomize paths
(Kubeflow Pipelines, Katib, Trainer), which would need patches against upstream
manifests, and Argo CD itself, installed from its upstream manifest by
`scripts/install-argo.sh`.

The single-node profile sets two values below the base, both for a laptop-sized node (see
`RUNBOOK.md`): MLflow runs one server worker at 512Mi (observed 317Mi in the laptop run),
and the Kafka broker requests 512Mi (observed 404Mi; 397Mi in the laptop run).
