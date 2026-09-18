#!/usr/bin/env python3
"""Promote a registered MLflow model version to a deterministic lakeFS location.

Why this exists
---------------
MLflow names artefacts with identifiers it mints at training time: an
auto-increment experiment id and a random logged-model id (``m-<32 hex>``). A
serving manifest that carries the resolved path therefore cannot be written
before the model exists, and has to be rewritten by whoever ran the training --
which makes the Git repository a function of a cluster run and breaks the
assumption the GitOps control loop rests on.

This script breaks that coupling. It copies the artefacts of one registered model
version to a path composed only of names that are known in advance:

    s3://<repository>/<ref>/<prefix>/<name>/<version>/

so ``base/charts/model`` can be parameterised with ``model.name`` and
``model.version`` alone. Raising the version in Git is then the promotion event:
it changes the ``storageUri``, KServe rolls a new predictor, and the change is a
reviewable commit rather than an out-of-band mutation of what a running service
reads.

The destination is lakeFS, not the object store beneath it. The copy is staged on
a branch and committed, so every promotion is a lakeFS commit that can be named,
diffed and rolled back, and a manifest may pin that commit id in place of the
branch when byte-level immutability is wanted.

Idempotent: re-promoting the same version is a no-op unless ``--force`` is given.

Environment
-----------
MLFLOW_TRACKING_URI   default http://127.0.0.1:5000   (kubectl -n platform-mlflow port-forward svc/mlflow 5000:80)
LAKEFS_ENDPOINT       default http://127.0.0.1:18000  (kubectl -n platform-lakefs port-forward svc/lakefs 18000:80)
LAKEFS_ACCESS_KEY     required -- see ml-pipelines/tools/env_from_keyvault.sh
LAKEFS_SECRET_KEY     required
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import tempfile

DEFAULT_TRACKING_URI = "http://127.0.0.1:5000"
DEFAULT_LAKEFS_ENDPOINT = "http://127.0.0.1:18000"


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    raise SystemExit(1)


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--name", required=True,
                   help="Registered model name in the MLflow Model Registry")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--version", help="Registry version to promote")
    g.add_argument("--latest", action="store_true",
                   help="Promote the highest version present (the default when no version is given)")
    p.add_argument("--repository", default=os.getenv("LAKEFS_REPO", "mlflow"),
                   help="lakeFS repository holding MLflow's artifact root (default: mlflow)")
    p.add_argument("--ref", default=os.getenv("LAKEFS_BRANCH", "main"),
                   help="lakeFS branch to write and commit on (default: main)")
    p.add_argument("--prefix", default="serving",
                   help="Path prefix inside the ref (default: serving)")
    p.add_argument("--force", action="store_true",
                   help="Overwrite a destination that is already populated")
    p.add_argument("--dry-run", action="store_true", help="Resolve and report, copy nothing")
    p.add_argument("--write-request", metavar="FILE",
                   help="Also write an Open Inference Protocol v2 request derived from the "
                        "model's input_example, so the inference check does not guess the schema")
    return p.parse_args()


def s3_client(endpoint, key, secret, region):
    import boto3
    from botocore.config import Config

    # Path-style addressing is mandatory: the lakeFS S3 gateway resolves the first
    # path segment of the key as the ref, which virtual-host addressing hides.
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=key,
        aws_secret_access_key=secret,
        region_name=region,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def flavours_of(mlmodel_text):
    """Names under the top-level `flavors:` key of an MLmodel file."""
    out, in_flavors = [], False
    for line in mlmodel_text.splitlines():
        if not line.strip():
            continue
        if not line.startswith(" "):
            in_flavors = line.startswith("flavors:")
            continue
        if in_flavors and line.startswith("  ") and not line.startswith("    "):
            out.append(line.strip().rstrip(":"))
    return out


def write_request(root, out):
    """Build an OIP v2 request from the logged input_example.

    The demonstration payloads under scripts/test/ are iris-shaped (3x4). A model
    produced by the orchestrated pipeline has a different feature width, so a
    hand-written payload is wrong by construction; derive it from the artefact.
    """
    example = root / "input_example.json"
    if not example.is_file():
        print("note         : no input_example.json logged -- cannot derive a request")
        return
    doc = json.loads(example.read_text(encoding="utf-8"))
    rows = doc.get("data") or doc.get("inputs")
    if isinstance(rows, dict):
        # Column-oriented example: transpose to rows.
        rows = [list(v) for v in zip(*rows.values())]
    if not rows:
        print("note         : input_example.json has no recognisable rows -- cannot derive a request")
        return
    payload = {
        "inputs": [{
            "name": "predict",
            "shape": [len(rows), len(rows[0])],
            "datatype": "FP64",
            "data": [[float(c) for c in r] for r in rows],
        }]
    }
    pathlib.Path(out).write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print("request      : wrote %s (%dx%d)" % (out, len(rows), len(rows[0])))


def main():
    args = parse_args()

    tracking_uri = os.getenv("MLFLOW_TRACKING_URI", DEFAULT_TRACKING_URI)
    lakefs_endpoint = os.getenv("LAKEFS_ENDPOINT", DEFAULT_LAKEFS_ENDPOINT).rstrip("/")
    ak = os.getenv("LAKEFS_ACCESS_KEY") or os.getenv("AWS_ACCESS_KEY_ID")
    sk = os.getenv("LAKEFS_SECRET_KEY") or os.getenv("AWS_SECRET_ACCESS_KEY")
    region = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
    if not ak or not sk:
        die("LAKEFS_ACCESS_KEY / LAKEFS_SECRET_KEY are required "
            "(see ml-pipelines/tools/env_from_keyvault.sh)")

    # MLflow reads artefacts that live in lakeFS through the same gateway.
    os.environ["MLFLOW_S3_ENDPOINT_URL"] = lakefs_endpoint
    os.environ["AWS_ACCESS_KEY_ID"] = ak
    os.environ["AWS_SECRET_ACCESS_KEY"] = sk
    os.environ.setdefault("AWS_DEFAULT_REGION", region)

    import mlflow
    import requests

    mlflow.set_tracking_uri(tracking_uri)
    mlflow.set_registry_uri(tracking_uri)
    client = mlflow.MlflowClient()

    # --- 1. resolve the registry entry ---------------------------------------
    if args.version:
        mv = client.get_model_version(args.name, args.version)
    else:
        versions = client.search_model_versions("name='%s'" % args.name)
        if not versions:
            die("no versions registered under '%s' at %s" % (args.name, tracking_uri))
        mv = max(versions, key=lambda v: int(v.version))

    version = str(mv.version)
    dest_prefix = "%s/%s/%s/%s" % (args.ref, args.prefix, args.name, version)
    model_uri = "s3://%s/%s" % (args.repository, dest_prefix)

    print("registry     : %s version %s (run %s)" % (args.name, version, mv.run_id))
    print("source       : %s" % mv.source)
    print("destination  : %s" % model_uri)

    if args.dry_run:
        print("dry-run: nothing copied")
        emit(args.name, version, model_uri, "")
        return

    s3 = s3_client(lakefs_endpoint, ak, sk, region)

    # --- 2. refuse to clobber silently ---------------------------------------
    existing = s3.list_objects_v2(Bucket=args.repository, Prefix=dest_prefix + "/", MaxKeys=1)
    if existing.get("KeyCount", 0) and not args.force:
        print("destination already populated -- left as-is (pass --force to overwrite)")
        emit(args.name, version, model_uri, "")
        return

    # --- 3. fetch the artefacts ----------------------------------------------
    with tempfile.TemporaryDirectory() as tmp:
        local = mlflow.artifacts.download_artifacts(artifact_uri=mv.source, dst_path=tmp)
        root = pathlib.Path(local)
        if not (root / "MLmodel").is_file():
            die("no MLmodel file under %s -- '%s' does not look like a logged MLflow model"
                % (root, mv.source))

        # The serving runtime is chosen from the flavour, so state which one it is:
        # a pyfunc flavour whose dependencies are absent from the KServe MLServer
        # image fails at model-load time, not at deploy time.
        print("flavours     : %s" % (", ".join(flavours_of(
            (root / "MLmodel").read_text(encoding="utf-8"))) or "unknown"))

        # --- 4. copy into lakeFS ---------------------------------------------
        n = 0
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            key = "%s/%s" % (dest_prefix, path.relative_to(root).as_posix())
            s3.upload_file(str(path), args.repository, key)
            n += 1
        print("copied       : %d files" % n)

        if args.write_request:
            write_request(root, args.write_request)

    # --- 5. commit, so the promotion is an addressable point in lakeFS -------
    r = requests.post(
        "%s/api/v1/repositories/%s/branches/%s/commits" % (lakefs_endpoint, args.repository, args.ref),
        auth=(ak, sk), timeout=60,
        json={
            "message": "promote %s v%s for serving" % (args.name, version),
            "metadata": {
                "model_name": args.name,
                "model_version": version,
                "mlflow_run_id": mv.run_id or "",
                "mlflow_source": mv.source or "",
            },
        },
    )
    commit = ""
    if r.status_code == 400 and "nothing to commit" in r.text.lower():
        print("lakeFS       : nothing to commit (identical bytes already on the branch)")
    elif not r.ok:
        die("lakeFS commit failed (%s): %s" % (r.status_code, r.text[:500]))
    else:
        commit = r.json().get("id", "")
        print("lakeFS commit: %s" % commit)

    emit(args.name, version, model_uri, commit, args)


def emit(name, version, model_uri, commit, args=None):
    print()
    print("MODEL_NAME=%s" % name)
    print("MODEL_VERSION=%s" % version)
    print("MODEL_URI=%s" % model_uri)
    if commit and args is not None:
        # A manifest may pin this in place of the branch to fix the exact bytes.
        print("MODEL_URI_PINNED=s3://%s/%s/%s/%s/%s"
              % (args.repository, commit, args.prefix, name, version))


if __name__ == "__main__":
    main()
