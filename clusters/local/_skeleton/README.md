# Local Cluster Skeleton Setup
## 1. Initialize External Secrets
```bash
tofu output -raw <output_name>

CLIENT_ID="<from tofu output>"
CLIENT_SECRET="<from tofu output>"

kubectl create namespace external-secrets
kubectl -n external-secrets create secret generic azure-sp-secret \
  --from-literal=ClientID="$CLIENT_ID" \
  --from-literal=ClientSecret="$CLIENT_SECRET"
```

## 2. Install ArgoCD
```bash
# This also automatically starts the first port forwarding from below
./mlops-apps/scripts/install-argo.sh
```

## 3. Connect to services (port forwarding)
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# ArgoCD -> https://localhost:8080
kubectl -n argocd port-forward svc/argocd-server 8080:443

# MinIO -> https://localhost:9001
kubectl -n platform-minio port-forward svc/minio-console 9001:9001

# MLFlow -> https://localhost:5000
kubectl -n platform-mlflow port-forward svc/mlflow 5000:80

kubectl -n platform-monitoring port-forward svc/monitoring-grafana 5555:80

kubectl -n platform-monitoring port-forward svc/prometheus-operated 9090:9090
```

## 4. Tunnel the Envoy Gateway
```bash
minikube tunnel
```

If the tunnel doesn't work, it could be the case that WSL/Linux has still another tunnel not properly resetted/cleaned up.
In this case run the following:
```bash
# stop the running tunnel process
sudo pkill -f "minikube tunnel" || true

# clean up routes and the tun device created by the tunnel
sudo -E minikube tunnel --cleanup
```