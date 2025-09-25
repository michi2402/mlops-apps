# minikube tunnel needs to be running
# ensure ingress gateway service has LoadBalancer IP 127.0.0.1 assigned

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
  http://127.0.0.1:80/v2/models/iris/infer | jq .