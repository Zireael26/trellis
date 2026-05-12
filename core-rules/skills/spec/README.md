# spec skill — quick reference

Authoritative content is in [`SKILL.md`](./SKILL.md). This file is the short-form for humans who want to skim before invoking.

## When to invoke

Use the spec skill when a change won't fit Trellis's surgical default. The decision rule from `engineering-process.md` §14.6: invoke when any of —

- The request lists three or more acceptance criteria.
- The change introduces net-new behaviour across more than two files.
- The change is cross-cutting or load-bearing.
- The operator explicitly asks for a write-up.

If none apply, skip the pipeline and stay surgical.

## Walk-through

A complete clarify → spec → plan → tasks → analyze cycle for a feature called `webhook-replay`:

```bash
# 1. Scaffold the directory + branch + a template spec.md.
scripts/new-feature.sh webhook-replay
# → checks out feature/webhook-replay
# → creates specs/001-webhook-replay/spec.md from the canonical template
#   (placeholders, not real content yet)

# 2. (Optional, recommended) Run the clarify skill BEFORE filling the spec
#    when the request is vague. Captures operator's voice across the five
#    canonical questions (intent, users, success metric, edge cases,
#    rollback plan). Writes specs/001-webhook-replay/clarify.md alongside
#    the template spec.md.

# 3. Invoke the spec skill to fill in spec.md (replacing the template
#    placeholders with real content). If clarify.md exists, the spec skill
#    reads it first and quotes from it. Sections in order:
#      problem → users → success criteria → non-goals → constraints
#      → open questions → risks → out-of-scope
#    Commit when the spec is ready for review.

# 4. After the spec is reviewed, invoke the plan skill (by name, in the
#    agent's skill picker or via tool invocation — there is no separate
#    plan.sh script; the skill reads spec.md and writes plan.md).
#    Plan lives at: specs/001-webhook-replay/plan.md

# 5. After the plan is reviewed, invoke the tasks skill the same way.
#    Tasks live at: specs/001-webhook-replay/tasks.md

# 6. (Recommended) Run the analyze skill BEFORE implementation. Cross-
#    checks spec/plan/tasks (and clarify if present) for drift across
#    8 categories. Writes specs/001-webhook-replay/analyze.md with a
#    PASS/NEEDS-REVISION/BLOCKED verdict. Advisory only; operator owns
#    whether to act on findings or accept divergence.

# 7. Implementation begins. Work the checkbox list in tasks.md, mirroring
#    the active 3–5-item slice into TodoWrite. tasks.md is source of truth.
```

## Common pitfalls

- **Don't put implementation detail in the spec.** File names, function names, schema shapes belong in `plan.md`. The spec answers *what* + *why*.
- **Don't paper over open questions.** If you don't know whether the cron runs nightly or hourly, write "Open question: cadence?" Don't pick silently.
- **Don't generate plan/tasks in the same turn as spec.** Each artifact is reviewed before the next is written. Stopping points are deliberate.
- **Don't duplicate `tasks.md` into TodoWrite.** Mirror the active slice (3–5 items), not the whole list. `tasks.md` wins on conflict.

## Override paths

- **Continue an in-flight feature without a new branch:** `scripts/new-feature.sh <slug> --no-branch`. Creates the directory; leaves the current branch untouched.
- **Working tree is dirty but you really want a spec now:** commit or stash first. The dirty-tree guard exists to keep the spec on a clean branch.

## Where artifacts live

```
<project-root>/specs/<NNN>-<slug>/
├── clarify.md        # clarify skill (optional, runs before spec)
├── spec.md           # this skill writes the scaffold
├── plan.md           # plan skill writes after spec is reviewed
├── tasks.md          # tasks skill writes after plan is reviewed
└── analyze.md        # analyze skill (advisory verdict before implementation)
```

After a feature ships, the directory stays in git as historical record. Don't delete or rewrite; spawn a new spec if revisions are needed.
