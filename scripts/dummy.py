import mlflow
from mlflow.tracking import MlflowClient

mlflow.set_tracking_uri("http://127.0.0.1:5000")

run_id = "e82f76cf944848ad8830cdd494f739ca"  # your last run
run = MlflowClient().get_run(run_id)
print("artifact_uri:", run.info.artifact_uri)
