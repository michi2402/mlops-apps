# Local Cluster Skeleton
## Connect to services (port forwarding)
```bash
# ArgoCD -> https://localhost:8080
kubectl -n argocd port-forward svc/argocd-server 8080:443

# MinIO -> https://localhost:9001
kubectl -n platform port-forward svc/minio-console 9001:9001

# MLFlow -> https://localhost:5000
kubectl -n platform port-forward svc/mlflow 5000:80
```