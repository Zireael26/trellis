# ADR 0001 — Security-gate stack consolidation PR

- Date: 2026-05-08
- Status: Accepted
- Authors: __MAINTAINER_NAME__ (sole maintainer)

## Context

The `security-gate` skill landed in six phases per [`security-gate-plan.md`](../../security-gate-plan.md) §7. Each phase had its own branch and PR with size <500 LOC, validation receipts against a named project, and a documented process-gate verdict. Stack:

| PR | Phase | Files | LOC | Validated against |
|---|---|---|---|---|
| [#10](https://github.com/__GITHUB_USER__/se-core/pull/10) | 1 — baseline engine + web profile | 7 | 733 | tgsc |
| [#11](https://github.com/__GITHUB_USER__/se-core/pull/11) | 2 — diff mode + pre-push wiring | 4 | 374 | tgsc |
| [#12](https://github.com/__GITHUB_USER__/se-core/pull/12) | 3 — quarterly scheduler | 3 | 212 | (prompt review) |
| [#15](https://github.com/__GITHUB_USER__/se-core/pull/15) | 4 — `web-rag-llm` profile | 6 | 273 | vericite |
| [#16](https://github.com/__GITHUB_USER__/se-core/pull/16) | 5 — `unity-game` profile | 3 | 218 | lume |
| [#17](https://github.com/__GITHUB_USER__/se-core/pull/17) | 6 — red-team Mode 3 | 4 | 325 | tgsc |

GitHub's auto-merge stacked PRs in the order they were authored, but the merge target for each (phases 2–6) was the previous phase's branch — not `claude/security-gate-plan` directly. As each PR landed, its content cascaded into intermediate branches but never reached the plan branch. Plan currently holds Phase 1 + Phase 2 only; phases 3–6 are stranded above it on `claude/security-gate-phase-5`.

## Problem

To finalize the stack, phases 3–6 must reach `main`. Two paths:

1. **Cascade**: open six trivial fast-forward PRs (`phase-5 → phase-4`, `phase-4 → phase-3`, …, `plan → main`). Each PR is a no-op merge commit because the cascading content is already audited via the original phase PRs. Process-gate would pass each individually.
2. **Consolidate**: open one PR `claude/security-gate-phase-5 → claude/security-gate-plan` (or directly to `main`) carrying the cumulative diff (phases 3–6).

The cascade path triggers six review notifications for changes the operator already reviewed. The consolidate path triggers one review for an oversized diff (~1038 LOC vs. the 800-line hard cap).

## Decision

**Consolidate.** Open a single PR off `claude/security-gate-phase-5` that brings phases 3–6 into `claude/security-gate-plan`. This ADR is the size-cap carve-out per `core-rules/skills/process-gate/references/pr-hygiene.md`'s ADR-exception path.

## Why splitting harms clarity here

- Each phase **was already** a separate, reviewed PR. The consolidation diff is the union of those six diffs. Re-reviewing them as six fast-forward merge PRs adds no signal — only review fatigue — and increases the chance of one PR landing while a parallel cascade opens a base-shift conflict.
- The cumulative process-gate verdict on the consolidated diff is the operationally meaningful one. It reproduces the per-phase verdicts (one warn for branch name, one warn for tests, all other checks green) plus the size warn this ADR closes.
- The phase boundaries are still legible in the merged history: each phase is a single feature commit, plus the merge-commits that cascaded them. Bisect remains effective.
- The validation receipts in each phase PR already capture the per-phase test runs; no information is lost.

## Consequences

- One oversized PR lands instead of six no-op fast-forwards. Branch-cleanup happens automatically as each phase branch is deleted post-merge.
- Future security-gate phase work (out of scope for the original plan, e.g. Garak end-to-end run, custom rule iteration as patterns are observed) opens fresh PRs off `main` without the stacking complication.
- This ADR sets a precedent: when a multi-phase feature stack lands via cascading PRs and the upper merges exceed the size cap purely because of the cumulative line count, a single consolidating PR with a referencing ADR is acceptable. Re-applying this pattern requires a fresh ADR each time — the carve-out is per-decision, not standing.

## Alternatives considered

- **`gh pr merge --admin` to override the size cap.** Rejected. Bypasses the discipline rather than documenting why it doesn't apply this once.
- **Raise `PROCESS_GATE_PR_SIZE_HARD` permanently.** Rejected. The 800-line cap is calibrated for normal review attention; raising it weakens the ceiling for everything.
- **Split the consolidation into two PRs** (`phases 3+4` then `phases 5+6`). Each ~500 LOC. Rejected — same review-fatigue argument applies, and the artificial split breaks the "one PR per stack consolidation" mental model that makes future consolidations recognizable.
