#!/usr/bin/env python3
"""Measure the environment surface of the k8s-native stack.

This is the instrument behind the portability result. It answers two questions
without needing a cluster:

  M1  Is the Application layer -- sources, chart versions, sync waves, destination
      namespaces, sync policy -- identical across environments?
  M2  How large is the environment surface: what exactly does an environment set,
      and how much of the definition is that?

Comparing inputs rather than fully rendered manifests is deliberate and sufficient.
M1 establishes that both environments name the same charts at the same versions, so
any difference in rendered output is exactly the image of the values difference that
M2 enumerates. Rendering both would restate that through a much larger artefact.

Exits non-zero if M1 fails, so it can gate a commit.

  python3 scripts/preflight/env-parity.py [--json]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import subprocess
import sys

STACK = "k8s-native-stack"
ENVS = ["minikube", "datalab"]
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def rel(*parts):
    return os.path.join(REPO, *parts)


def read(path):
    return io.open(path, encoding="utf-8").read()


def walk(root):
    out = []
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            full = os.path.join(dirpath, f)
            out.append((os.path.relpath(full, root).replace("\\", "/"), full))
    return sorted(out)


# --------------------------------------------------------------------- M1 ------
def check_app_layer():
    """Every environment's Application layer must be one substitution apart."""
    trees = {}
    for env in ENVS:
        root = rel("clusters", "envs", env, STACK)
        files = {}
        for name, full in walk(root):
            # The component overlays are where environments are *meant* to differ.
            if "/platform/components/" in "/" + name:
                continue
            files[name] = read(full).replace(env, "<ENV>")
        trees[env] = files

    a, b = ENVS[0], ENVS[1]
    problems = []
    only_a = sorted(set(trees[a]) - set(trees[b]))
    only_b = sorted(set(trees[b]) - set(trees[a]))
    for n in only_a:
        problems.append(f"only in {a}: {n}")
    for n in only_b:
        problems.append(f"only in {b}: {n}")
    for n in sorted(set(trees[a]) & set(trees[b])):
        if trees[a][n] != trees[b][n]:
            problems.append(f"differs beyond the environment token: {n}")
    return sorted(trees[a]), problems


# --------------------------------------------------------------------- M2 ------
def flatten(node, prefix=""):
    """Leaf key paths of a parsed YAML document."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from flatten(v, f"{prefix}.{k}" if prefix else str(k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from flatten(v, f"{prefix}[{i}]")
    else:
        yield prefix, node


def overlay_surface():
    import yaml

    surface = {}
    for env in ENVS:
        root = rel("clusters", "envs", env, STACK, "platform", "components")
        per_component = {}
        for name, full in walk(root):
            comp = name.split("/")[0]
            if name.endswith("kustomization.yaml"):
                continue  # plumbing, not a profile value
            keys = {}
            for doc in yaml.safe_load_all(read(full)):
                if not doc:
                    continue
                # A kustomize patch identifies its target by kind/name; those are not
                # profile values either.
                kind = doc.get("kind") if isinstance(doc, dict) else None
                nm = (doc.get("metadata") or {}).get("name") if isinstance(doc, dict) else None
                scope = f"{kind}/{nm}" if kind else ""
                for kp, val in flatten(doc):
                    if kp.startswith(("apiVersion", "kind", "metadata")):
                        continue
                    keys[f"{scope}:{kp}" if scope else kp] = val
            if keys:
                per_component.setdefault(comp, {}).update(keys)
        surface[env] = per_component
    return surface


def base_config_size():
    """Non-comment, non-blank lines of the base component configuration."""
    root = rel("clusters", "base", STACK, "platform", "components")
    n = 0
    for name, full in walk(root):
        if not name.endswith((".yaml", ".yml")):
            continue
        for line in read(full).splitlines():
            s = line.strip()
            if s and not s.startswith("#"):
                n += 1
    return n


def overlay_line_count():
    """Per environment. Summing both and dividing by one base would compare the cost
    of two environments against the size of one definition."""
    per_env = {}
    for env in ENVS:
        root = rel("clusters", "envs", env, STACK, "platform", "components")
        n = 0
        for name, full in walk(root):
            if name.endswith("kustomization.yaml"):
                continue
            for line in read(full).splitlines():
                s = line.strip()
                if s and not s.startswith("#"):
                    n += 1
        per_env[env] = n
    return per_env


# --------------------------------------------------------------------- M3 ------
def kafka_render_diff():
    """Build the one component whose profile is a topology, and report what differs."""
    import yaml

    rendered = {}
    for env in ENVS:
        path = rel("clusters", "envs", env, STACK, "platform", "components", "kafka")
        try:
            out = subprocess.run(
                ["kubectl", "kustomize", path],
                capture_output=True, text=True, check=True).stdout
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            return None, f"kustomize build failed for {env}: {e}"
        flat = {}
        for doc in yaml.safe_load_all(out):
            if not doc:
                continue
            key = f"{doc['kind']}/{doc['metadata']['name']}"
            for kp, val in flatten(doc):
                flat[f"{key}:{kp}"] = val
        rendered[env] = flat

    a, b = ENVS
    diffs = []
    for k in sorted(set(rendered[a]) | set(rendered[b])):
        va, vb = rendered[a].get(k, "<absent>"), rendered[b].get(k, "<absent>")
        if va != vb:
            diffs.append((k, va, vb))
    return diffs, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    app_files, problems = check_app_layer()
    surface = overlay_surface()
    kafka_diffs, kafka_err = kafka_render_diff()

    n_over_files = sum(
        len([1 for n, _ in walk(rel("clusters", "envs", e, STACK, "platform", "components"))
             if not n.endswith("kustomization.yaml")]) for e in ENVS)
    n_keys = {e: sum(len(v) for v in surface[e].values()) for e in ENVS}
    base_lines = base_config_size()
    over_lines = overlay_line_count()

    if args.json:
        print(json.dumps({
            "m1_app_layer_identical": not problems,
            "m1_problems": problems,
            "m1_files_compared": len(app_files),
            "m2_surface": {e: {c: sorted(k) for c, k in surface[e].items()} for e in ENVS},
            "m2_overlay_files": n_over_files,
            "m2_keys": n_keys,
            "m2_overlay_lines_per_env": over_lines,
            "m2_base_config_lines": base_lines,
            "m3_kafka_differing_fields": [k for k, _, _ in (kafka_diffs or [])],
        }, indent=2))
        return 0 if not problems else 1

    print("=" * 78)
    print("M1  Application layer identical across environments?")
    print("=" * 78)
    print(f"  compared {len(app_files)} files per environment "
          f"({', '.join(ENVS)}), environment token substituted")
    if problems:
        print("  RESULT: FAIL")
        for p in problems:
            print("   -", p)
    else:
        print("  RESULT: PASS -- sources, chart versions, sync waves, destination")
        print("          namespaces and sync policy are identical in both environments.")

    print()
    print("=" * 78)
    print("M2  Environment surface")
    print("=" * 78)
    for env in ENVS:
        print(f"\n  {env}:")
        for comp in sorted(surface[env]):
            keys = surface[env][comp]
            print(f"    {comp}  ({len(keys)} keys)")
            for k in sorted(keys):
                print(f"       {k} = {keys[k]}")
    print()
    print(f"  overlay files ............ {n_over_files}")
    print(f"  keys set ................. " + ", ".join(f"{e}: {n_keys[e]}" for e in ENVS))
    print("  overlay lines ............ " + ", ".join(f"{e}: {over_lines[e]}" for e in ENVS))
    print(f"  base config lines ........ {base_lines}")
    if base_lines:
        pct = ", ".join(f"{e}: {100.0 * over_lines[e] / base_lines:.1f}%" for e in ENVS)
        print(f"  environment surface ...... {pct} of the base configuration")

    print()
    print("=" * 78)
    print("M3  Event-bus topology, rendered")
    print("=" * 78)
    if kafka_err:
        print("  " + kafka_err)
    else:
        print(f"  {len(kafka_diffs)} fields differ between {ENVS[0]} and {ENVS[1]}:")
        for k, va, vb in kafka_diffs:
            print(f"    {k}")
            print(f"       {ENVS[0]:<9} = {va}")
            print(f"       {ENVS[1]:<9} = {vb}")

    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
