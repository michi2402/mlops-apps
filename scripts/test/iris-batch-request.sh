# The Envoy Service is ClusterIP; forward it first:
#   kubectl -n platform-envoy-gateway port-forward \
#     "$(kubectl -n platform-envoy-gateway get svc -o name \
#         -l gateway.envoyproxy.io/owning-gateway-name=ingress-gateway)" 18080:80

curl -s -v \
  -H "Host: iris-team1-iris.mlops.local" \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [{
      "name": "predict",
      "shape": [3, 4],
      "datatype": "FP64",
      "data": [
        [5.1, 3.5, 1.4, 0.2],
        [6.2, 3.4, 5.4, 2.3],
        [5.9, 3.0, 4.2, 1.5]
      ]
    }]
  }' \
  http://127.0.0.1:18080/v2/models/iris/infer | jq .