---
name: analyze
description: Cross-check `spec.md`, `plan.md`, `tasks.md` (and `clarify.md` if present) for drift between intent and implementation plan. Use AFTER all three pipeline artifacts exist and BEFORE implementation begins, OR mid-implementation when something feels off. Output is `specs/<NNN>-<slug>/analyze.md` — an advisory report of drift findings (critical / warning / info). The skill is advisory, NOT gating; operator decides whether to act on findings or override.
---

# analyze

Tail step of the opt-in spec → plan → tasks pipeline. The pipeline produces three (or four, with clarify) artifacts that should mutually reinforce. In practice they drift: a plan mentions a service the spec didn't request; tasks miss a success criterion; clarify captured a constraint the plan ignores. Analyze catches that drift.

Output is `specs/<NNN>-<slug>/analyze.md` — advisory only. Operator reads it and either fixes the artifacts or explicitly notes a finding as "accepted divergence" in a follow-up commit. Skill never modifies any other file.

## When to use

- Right after `tasks` completes, before implementation begins, as a final coherence check on the pipeline.
- Mid-implementation when an engineer finds themselves writing code the plan didn't anticipate — drift detection catches whether spec / plan / tasks need revision.
- Pre-PR, as a sanity check that nothing important slipped between artifact-writing and the actual diff.

## When NOT to use

- Pipeline only partially complete (only spec exists; plan and tasks missing). Run the missing skills first.
- Surgical-default work that never used the pipeline. There's nothing to analyze.
- Pure curiosity ("does this feature still make sense"). That's a strategy question, not a drift one.

## Input contract

The skill expects these files to exist in the current branch's `specs/<NNN>-<slug>/` directory:

- `spec.md` — required.
- `plan.md` — required.
- `tasks.md` — required.
- `clarify.md` — optional; used as additional drift baseline when present.

If any required file is missing, the skill stops and tells the operator what to fix.

## Output contract

One new file: `specs/<NNN>-<slug>/analyze.md`. No edits to spec.md, plan.md, tasks.md, clarify.md, or anything else.

If a prior `analyze.md` exists, the skill refuses to overwrite. Operator removes explicitly; re-analysis lands as a new file (`analyze-2.md`, `analyze-pre-impl.md`) at the operator's discretion.

## Drift checks

The full check matrix lives in [`references/drift-checks.md`](references/drift-checks.md). Categories at a glance:

1. **Coverage** — every spec success criterion → at least one task. Uncovered criteria are critical.
2. **Origin** — every task → traces back to a plan line item AND ultimately to a spec criterion. Orphaned tasks are warning (often legitimate, sometimes scope creep).
3. **Scope** — plan introduces services/files/concepts not in the spec. Critical if substantive; warning if minor (e.g., a new utility helper).
4. **Constraint compliance** — plan respects spec constraints (rate limits, perf budgets, compliance). Violations are critical.
5. **Intent fidelity** (only when clarify.md is present) — spec's framing matches operator's voice in clarify. Drift here is critical: the spec is solving the wrong problem.
6. **Rollback consistency** — plan §7 rollback path matches spec §5 constraints and (if present) clarify Q5 rollback answer. Mismatches are critical.
7. **Test strategy completeness** — every spec criterion has a corresponding test in plan §6. Missing tests are critical.
8. **Sequencing sanity** — tasks dependencies don't form cycles; sequencing leaves the tree buildable at each step. Cycles are critical.
9. **Constitution compliance** — assembles the project's effective constitution (parent CLAUDE.md → preset(s) → project CLAUDE.md, §14.8 order) and surfaces where the pipeline diverges from it: prose that contradicts a higher layer with no written carve-out, DoD-receipt-less tasks, perf-budget breach. critical / warning / info. **Advisory cap:** a #9 finding can push the report's existing verdict line to `## Verdict: BLOCKED`, but the skill never hard-gates and its exit semantics are unchanged — the process-gate remains the only hard gate. This category *detects and surfaces*; it never adjudicates which layer wins.

## How to use

1. **Confirm input contract.** All required files exist. List them.
2. **Run each check category in order.** Don't batch findings — produce them as you go. The operator can stop reading at the first critical and act on it before the rest.
3. **Quote, don't paraphrase.** When flagging "spec says X but plan says Y", quote both verbatim with line refs.
4. **Tier severity carefully.** Critical = blocks merge. Warning = revisit before PR. Info = cosmetic, optional. Most findings should be warning or info; over-using critical desensitises.
5. **Don't propose fixes inline.** Findings only. The operator decides whether to revise spec, plan, tasks, or override. Proposed fixes belong in the follow-up commit, not in analyze.md.

## Authoring rules

- **One finding per row in the output tables.** Don't merge.
- **Every finding cites file:line.** Reviewer can jump to the offending text.
- **Severity comes with a one-line rationale.** Not "critical — fix this" but "critical — success criterion §3.2 has no covering task; implementation will silently skip it".
- **Findings are facts, not opinions.** "Plan §4 introduces a Redis dependency the spec did not request" is a fact. "Plan should not use Redis" is an opinion — out of scope.
- **End with an explicit verdict.** `## Verdict: <PASS | NEEDS-REVISION | BLOCKED>` based on the highest severity finding.

## Boundaries

- **Advisory, not gating.** The skill cannot block a merge. The operator owns the call.
- **One file written.** `specs/<NNN>-<slug>/analyze.md`. Nothing else.
- **Read-only against the rest of the tree.** Read code if it helps trace what the plan/tasks reference, but never modify.
- **Refuses to overwrite an existing analyze.md.** Re-analyses land as new files.
- **No fixes.** Findings only.

## Sensible failure modes

- Required file missing → stop, list what's missing, suggest the skill to run first (`plan` if plan.md missing; `tasks` if tasks.md missing).
- spec.md exists but is still labelled `status: draft` → still run analyze if all three files are present, but include a top-line note: "spec is draft; findings may shift on review".
- Two specs match the slug heuristic → stop and ask which one.
- Pipeline used a different artifact structure (different file names) → emit one info-level finding noting the deviation; analyze what you have.

## Relationship to the rest of the pipeline

- **After `tasks`.** Final coherence check before implementation begins.
- **Reads `clarify.md` if present.** Used as the original-intent baseline for §5 (intent fidelity) drift checks.
- **Never writes to spec/plan/tasks/clarify.** Findings are what change them, but through operator action.
- **Re-runnable.** After the operator revises an artifact, they can re-run analyze (after removing the prior file or accepting a new `analyze-2.md`) to confirm drift is closed.
