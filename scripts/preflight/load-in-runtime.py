"""Load every staged model inside seldonio/mlserver:1.5.0 -- the image KServe's
kserve-mlserver ClusterServingRuntime uses for modelFormat: mlflow."""
import glob
import sys
import warnings
import numpy as np
import pandas as pd
import mlflow

warnings.filterwarnings("ignore")
print(f"consumer python {sys.version.split()[0]} mlflow {mlflow.__version__}")
try:
    import torch
    print("consumer torch", torch.__version__)
except Exception as e:
    print("consumer torch MISSING:", e)

X = pd.DataFrame(np.random.default_rng(0).normal(size=(3, 12)),
                 columns=[f"f{i}" for i in range(12)])

for d in sorted(glob.glob("/work/served-*")):
    label = d.split("/")[-1]
    try:
        m = mlflow.pyfunc.load_model(d)
    except Exception as e:
        print(f"{label:34s} LOAD FAILED  {type(e).__name__}: {str(e)[:150]}")
        continue
    try:
        out = m.predict(X)
        print(f"{label:34s} OK           predict shape {np.asarray(out).shape}")
    except Exception as e:
        print(f"{label:34s} LOADED, PREDICT FAILED  {type(e).__name__}: {str(e)[:150]}")
