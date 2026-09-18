# Spec 050 lean enforcement ships as two PRs, the hardening one over the size cap

- Status: accepted
- Date: 2026-09-18

## Context

Spec 050 ships as two companion PRs: `chore/lean-enforcement-050-cleanup` (the behaviour-preserving
S6 slice, 13 files, one commit, under the cap) and `feat/lean-enforcement-050` (hardening slices
S1–S5 and S7 plus every spec artifact, ~4,800 countable lines). The second exceeds the 800-line hard
PR-size cap in the process gate, which permits an ADR explaining why splitting it further harms clarity.
Decision D2 of the spec is why the cleanup is already separate.

Roughly 1,400 of those lines are the spec triad, decisions record, baseline record, release runbook
and fifteen per-unit receipts under `specs/050-lean-enforcement/`; another ~1,300 are new bats/shell
guard tests written red-first. The executable change is seven bounded units over disjoint files.

## Decision

Ship the hardening PR as one PR rather than splitting it per slice, mirroring the precedent of
`2026-09-04-de-slop-c7-single-pr.md`. Merge order: cleanup PR first, then this one, then tag `v1.3.1`.

1. **The receipts are the unit of review.** Every unit has its own receipt (route, red-then-green
   output, pass counts before/after against the recorded baseline, cross-family review verdict).
   A reviewer reads the receipt and spot-checks the diff; seven PRs would carry the same triad and
   baseline seven times.
2. **Units are already independent and reversible by file set.** The slices touch disjoint files
   (`run-all.sh`, `check-slop.sh`, `check-tests.sh`, the two review hooks, the foreman scripts, the
   probe tests, the repo-local validators). Reverting one slice is a file-set revert, which the
   squash body enumerates by unit commit.
3. **Half of the hardening is worse than none.** S1 and S2 close the same fail-open class in the
   aggregator and its child; landing one without the other leaves the gate reporting a stricter
   row over a child that can still pass silently.

## Consequences

- Review is receipt-led; the PR description links every receipt and the gate output.
- Rollback of a hardening slice is per unit by file set (or the whole squash), never a partial hunk;
  rollback of the cleanup is a revert of its single commit.
- The reviewer acknowledges the size in the PR description, where the sampling evidence belongs.
