# Cold acceptance run -- laptop, minikube profile (2026-09-24, 21:07-22:03Z)

Procedure: `minikube delete --all --purge` -> `./scripts/minikube-up.sh` -> `bootstrap-k8s-native.sh`
with default settings; no image cache; repository at b3dd06b (manifests = origin 10d8c9f).
Host: i7-10750H, 15.75 GB, Docker Desktop/WSL2 (12 GB); node 6 CPU / 11 GiB.

Result: exit 0, no intervention. 3023 s total: 1636 s to converge (12 serving-path Applications),
1387 s to serve iris (includes pulling the 9.9 GB MLServer image).

- E00: node start. The first attempt passed kubelet max-parallel-image-pulls as a flag and the kubelet
  refused to start ("unknown flag"); minikube-up.sh sets it in the kubelet config instead (c9f848b).
- E29: bootstrap transcript.
- E09: inference through the ClusterIP gateway (port-forward 18080): HTTP 200.
- E30-E33: 26/27 Prometheus targets up (the missing one is team2-timeseries, whose model only the
  pipeline produces); rest_server_requests_total{inferenceservice="iris"} = 21 after 21 requests.
- E61: 10.4 GiB used (86 %), requests 95 % of allocatable, no OOM, nothing Pending. All 22 platform
  Applications Synced/Healthy except platform-katib (OutOfSync: cert-manager injects caBundle into its
  webhooks; companion scope).

Transient conditions, all self-clearing (no action taken):
- platform-external-secrets ComparisonError ~1 min: server-side diff dry-runs the ClusterSecretStore
  through ESO's validating webhook before the webhook pod is ready.
- Container restarts during start-up (lakeFS 8, Kafka broker 3, Strimzi 6, Redpanda Connect 6, KFP and
  Katib components): start-up ordering and CPU contention while images unpack; none OOM. To be analysed.
