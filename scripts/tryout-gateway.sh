curl -s -v \
  -H "Host: dummy-model-predictor-team1-dummy-model.127.0.0.1.sslip.io" \
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
  http://127.0.0.1:80/v2/models/dummy-model/infer | jq .