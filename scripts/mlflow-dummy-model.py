import os
import time
import mlflow
import mlflow.sklearn
from mlflow.models.signature import infer_signature

import numpy as np
import pandas as pd
from sklearn.datasets import load_diabetes
from sklearn.linear_model import LinearRegression
from sklearn.metrics import mean_squared_error
from sklearn.model_selection import train_test_split

mlflow.set_tracking_uri("http://127.0.0.1:5000")

EXPERIMENT_NAME = "demo-diabetes-experiment"
mlflow.set_experiment(EXPERIMENT_NAME)

# Simple dataset
X, y = load_diabetes(return_X_y=True, as_frame=True)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

with mlflow.start_run(run_name=f"linreg-{int(time.time())}") as run:
    model = LinearRegression()
    model.fit(X_train, y_train)

    preds = model.predict(X_test)
    rmse = mean_squared_error(y_test, preds, squared=False)

    # Log basic stuff
    mlflow.log_param("model_type", "LinearRegression")
    mlflow.log_param("test_size", 0.2)
    mlflow.log_metric("rmse", rmse)

    # Log artifacts
    df_pred = pd.DataFrame({"y_true": y_test.values, "y_pred": preds})
    out_csv = "predictions.csv"
    df_pred.to_csv(out_csv, index=False)
    mlflow.log_artifact(out_csv, artifact_path="eval")

    # Log model
    sig = infer_signature(X_test, preds)
    # This both logs the model artifact and (if registry is enabled) can auto-register:
    mlflow.sklearn.log_model(
        model,
        artifact_path="model",
        signature=sig,
        input_example=X_test.head(2),
        registered_model_name="demo-diabetes-linreg"  # comment out if you don't want registry use
    )

    print("Run ID:", run.info.run_id)
    print("Artifact URI:", mlflow.get_artifact_uri())