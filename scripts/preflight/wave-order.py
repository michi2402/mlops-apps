"""Check that every custom resource an Application manages has its definition installed
by an Application in a strictly earlier sync wave.

Why it matters: install-argo.sh makes each wave wait until the previous one is Healthy.
A consumer placed in the same wave as the Application that installs its CRD races it; a
consumer placed *earlier* can never sync (the discovery of its kind fails and nothing is
applied), never becomes Healthy, and so holds its own wave -- and every later one --
forever. On 2026-09-21 this found cert-manager (wave -10) shipping a ServiceMonitor whose
CRD came from monitoring (wave -8): a deadlock on any fresh cluster.

Needs a cluster on which the stack has been applied once: the kinds each Application
manages are read from its status, not rendered from charts. Waves are read from the
repository, so a proposed reordering can be checked before it is pushed.

    python scripts/preflight/wave-order.py [--context minikube] [--stack k8s-native-stack]

Exit status 1 if any inversion is found.
"""
import argparse
import glob
import json
import subprocess
import sys

import yaml


def kubectl_json(context, *args):
    cmd = ["kubectl"] + (["--context", context] if context else []) + list(args) + ["-o", "json"]
    return json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--context", default="")
    ap.add_argument("--stack", default="k8s-native-stack")
    args = ap.parse_args()

    wave = {}
    for f in glob.glob(f"clusters/base/{args.stack}/platform/apps/*.yaml"):
        with open(f, encoding="utf-8") as fh:
            meta = yaml.safe_load(fh)["metadata"]
        wave[meta["name"]] = int(meta.get("annotations", {}).get("argocd.argoproj.io/sync-wave", 0))
    if not wave:
        sys.exit("no Applications under clusters/base/%s/platform/apps -- run from the repo root" % args.stack)

    apps = {a["metadata"]["name"]: a
            for a in kubectl_json(args.context, "get", "applications.argoproj.io", "-A")["items"]}
    crd_of = {(c["spec"]["group"], c["spec"]["names"]["kind"]): c["metadata"]["name"]
              for c in kubectl_json(args.context, "get", "crd")["items"]}
    provider = {r["name"]: name for name, a in apps.items()
                for r in a.get("status", {}).get("resources", [])
                if r["kind"] == "CustomResourceDefinition"}

    inversions = set()
    for name, a in apps.items():
        if name not in wave:
            continue
        for r in a.get("status", {}).get("resources", []):
            crd = crd_of.get((r.get("group", ""), r["kind"]))
            p = provider.get(crd)
            if p is None or p == name or p not in wave:
                continue  # built-in kind, self-provided, or installed outside this tier
            if wave[p] >= wave[name]:
                inversions.add((name, wave[name], r["kind"], p, wave[p]))

    for c in sorted(inversions, key=lambda x: (x[1], x[0])):
        print("INVERSION %-34s wave %3d needs %-24s from %-34s wave %3d" % c)
    missing = sorted(set(wave) - set(apps))
    if missing:
        print("note: not on the cluster, not checked: %s" % ", ".join(missing))
    print("checked %d Applications of %s: %d inversion(s)"
          % (len(set(wave) & set(apps)), args.stack, len(inversions)))
    sys.exit(1 if inversions else 0)


if __name__ == "__main__":
    main()
