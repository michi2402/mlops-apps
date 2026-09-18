"""Produce both flavours into separate directories, so the consumer can test each.

Run under a chosen Python version to isolate whether a load failure is caused by the
MLflow version or by the Python version the artefact was pickled under.
"""
import os
import shutil
import pathlib
import numpy as np
import pandas as pd
import torch
from torch import nn
import sklearn
from sklearn.linear_model import LogisticRegression
import mlflow

TAG = os.environ.get("TAG", "x")
print(f"producer python {os.sys.version.split()[0]} mlflow {mlflow.__version__} "
      f"torch {torch.__version__} sklearn {sklearn.__version__}")


class MLP(nn.Module):
    def __init__(self, in_dim, hidden, out_dim=2):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_dim, hidden), nn.ReLU(),
            nn.Linear(hidden, hidden), nn.ReLU(),
            nn.Linear(hidden, out_dim),
        )

    def forward(self, x):
        return self.net(x)


class ScaledMLP(nn.Module):
    def __init__(self, in_dim, hidden, mu, sigma, out_dim=2):
        super().__init__()
        self.register_buffer("mu", torch.tensor(mu, dtype=torch.float32))
        self.register_buffer("sigma", torch.tensor(sigma, dtype=torch.float32))
        self.mlp = MLP(in_dim, hidden, out_dim)

    def forward(self, x):
        return self.mlp((x - self.mu) / self.sigma)


N = 12
rng = np.random.default_rng(42)
X = pd.DataFrame(rng.normal(size=(40, N)), columns=[f"f{i}" for i in range(N)])
y = (X["f0"] > 0).astype(int)

mlflow.set_tracking_uri(f"file:///work/mlruns-{TAG}")
mlflow.set_experiment("compat")


def stage(info, name):
    src = pathlib.Path(mlflow.artifacts.download_artifacts(
        artifact_uri=info.model_uri, dst_path=f"/work/dl-{TAG}-{name}"))
    dst = pathlib.Path(f"/work/served-{TAG}-{name}")
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    print(f"staged {name} -> {dst}")


model = ScaledMLP(N, 16, X.mean().values, X.std().replace(0, 1.0).values)
ex = X.head(5)
with torch.no_grad():
    preds = model(torch.tensor(ex.values, dtype=torch.float32)).numpy()
with mlflow.start_run():
    info = mlflow.pytorch.log_model(
        model, "model", signature=mlflow.models.infer_signature(ex, preds), input_example=ex)
stage(info, "torch")

lr = LogisticRegression(max_iter=1000).fit(X, y)
with mlflow.start_run():
    info = mlflow.sklearn.log_model(
        sk_model=lr, artifact_path="model",
        signature=mlflow.models.infer_signature(X, lr.predict(X)),
        input_example=ex, serialization_format="cloudpickle")
stage(info, "sklearn")
