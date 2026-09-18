# `_skeleton` — the template

The platform tier and nothing else: no pipeline orchestrator, no tenant workload beyond the
demonstration model. It exists to be **copied** when a further stack is started.

**It is never deployed.** No measurement in the thesis is drawn from it, and it carries no
environment profile. It is kept faithful by regeneration from
[`../k8s-native-stack/`](../k8s-native-stack) with only the directory name substituted, so the
two platform trees are byte-identical; if you change one, regenerate the other rather than
editing both.

## Starting a new stack from it

1. Copy this directory to `clusters/base/<your-stack>/` and substitute the directory name
   throughout (every `$values` path and every `path:` names it).
2. Add whatever orchestration layer the stack needs under `platform/apps/` and
   `platform/components/`.
3. If the stack will run in more than one environment, give it an environment layer:
   add profiles under `clusters/envs/<env>/<your-stack>/platform/components/` and generate the
   Application layer with `scripts/gen-env-layer.py`. See [`../../README.md`](../../README.md).
   A stack that only ever runs in one place does not need one — `pythonic-stack` does not have
   one.

## Deploying it anyway

Don't. If you want a platform-only cluster to look at, copy it to a stack of its own first, so
that the template stays a template. The stack-agnostic walkthrough is
[`README.md`](../../../README.md) and the scripted path is [`RUNBOOK.md`](../../../RUNBOOK.md).
