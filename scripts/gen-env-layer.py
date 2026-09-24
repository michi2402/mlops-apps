"""Generate the per-environment Application layer for k8s-native-stack.

The base at clusters/base/k8s-native-stack holds the structure: every Application's
sources, sync waves, destination namespaces and chart versions, plus the neutral
values. An environment adds exactly one thing -- an overlay -- and nothing else.

The generated apps/ trees differ only in the environment token, which
scripts/preflight/check-env-parity.sh asserts.
"""
import io
import os
import re
import shutil

REPO = r"C:\Users\micmay\university\bsc\thesis\poc\mlops-apps"
STACK = "k8s-native-stack"
BASE = f"clusters/base/{STACK}"
ENVS = ["minikube", "datalab"]

# Components whose values are overridden per environment. Everything else renders
# identically in both, from the base alone.
HELM_OVERLAYS = {"postgres", "minio", "monitoring", "dask", "rp-connect", "mlflow"}
# Components delivered as raw manifests, so the overlay is a kustomize patch.
KUSTOMIZE_OVERLAYS = {"kafka"}


def p(*parts):
    return os.path.join(REPO, *parts)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    io.open(path, "w", encoding="utf-8", newline="\n").write(text.rstrip("\n") + "\n")


def read(path):
    return io.open(path, encoding="utf-8").read()


for env in ENVS:
    envroot = f"clusters/envs/{env}/{STACK}"
    # Only the Application layer is generated. platform/components/ is authored --
    # it is the environment profile itself -- and is never touched here.
    shutil.rmtree(p(envroot, "apps"), ignore_errors=True)
    shutil.rmtree(p(envroot, "platform", "apps"), ignore_errors=True)

    # ---- leaf platform Applications ------------------------------------------
    src_dir = p(BASE, "platform", "apps")
    for fn in sorted(os.listdir(src_dir)):
        if not fn.endswith(".yaml"):
            continue
        t = read(os.path.join(src_dir, fn))
        comp = fn[:-5]

        if comp in HELM_OVERLAYS:
            # Append the environment overlay after the base values file. Helm merges
            # valueFiles left to right, so the overlay wins on every key it sets.
            base_vf = f"$values/{BASE}/platform/components/{comp}/values.yaml"
            over_vf = f"$values/{envroot}/platform/components/{comp}/values.yaml"
            # Indentation of the valueFiles entry is not uniform across the
            # Applications, so match it rather than assuming it.
            m = re.search(r"^([ \t]*)-[ \t]*" + re.escape(base_vf) + r"[ \t]*$", t, re.M)
            assert m, (env, fn, "base values file entry not found")
            indent = m.group(1)
            t = t[: m.end()] + "\n" + indent + "- " + over_vf + t[m.end():]
            assert over_vf in t

        if comp in KUSTOMIZE_OVERLAYS:
            # The rendered source moves to the overlay, which pulls the base in as a
            # kustomize resource. The `ref: values` prefix stays pointed at the repo.
            t = t.replace(
                f"      path: {BASE}/platform/components/{comp}\n",
                f"      path: {envroot}/platform/components/{comp}\n",
            )
            assert f"path: {envroot}/platform/components/{comp}" in t

        write(p(envroot, "platform", "apps", fn), t)

    # ---- second-level Applications and the root ------------------------------
    for fn in sorted(os.listdir(p(BASE, "apps"))):
        t = read(p(BASE, "apps", fn)).replace(BASE, envroot)
        # Tenant workloads carry no environment profile: the model chart renders the
        # same InferenceService wherever it runs, and the artefact it names is the
        # same registry coordinate. They therefore stay in the base, and only the
        # platform tier is environment-scoped.
        t = t.replace(f"{envroot}/workloads/", f"{BASE}/workloads/")
        write(p(envroot, "apps", fn), t)

    t = read(p(BASE, "aoa-root.yaml")).replace(BASE, envroot)
    # Name the root after the environment so two clusters cannot be confused, and so
    # `kubectl get app root-<env>` states which profile a cluster carries.
    t = t.replace("  name: root\n", f"  name: root-{env}\n", 1)
    write(p(envroot, "aoa-root.yaml"), t)

print("generated app layer for:", ", ".join(ENVS))
