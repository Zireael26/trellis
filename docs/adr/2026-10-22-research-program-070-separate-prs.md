# Spec 070 lands as separate PRs

## Status

Accepted under the owner's separate-landing ruling recorded in `decisions-log.md` at the `2026-10-21T07:50Z` (`[owner] [backlog]`) anchor. The earlier one-PR ADR at commit `ce0c8895` never reached `origin/main` and is not the active landing decision.

## Context

The owner ordered the research program to land as independently gated PRs: #571, then #584, then #585 revision 3, then the slices. The prior consolidation cannot be amended in place on `main` because that ADR and its umbrella branch are not on `origin/main`. This ADR and its landing plan must therefore be a small standalone docs PR from the current `origin/main` (`5be760d0`), not additions to #585.

## Decision

1. Land this ADR and `docs/plans/2026-10-22-research-program-070-landing-plan.md` in a separate docs PR, proposed branch `docs/070-land-separately-recut`, based on `origin/main`. No CHANGELOG entry: this is a landing decision, not a Trellis release change.
2. Then land #571, #584, and #585 revision 3 in that order; land the implementation slices afterward, stacked on the updated #585 branch as detailed in the plan.
3. Preserve published history. Before each applicable push gate, merge current `origin/main` forward into the published branch. Never rebase or force-push published #571, #584 or #585 branches. The unpushed slices may be rebased onto the updated #585 head after it contains current `main`.

Each PR is independently reviewed and gated. Any individual PR above 800 changed lines has its own size ADR; that ADR explains the diff and does not waive review or the gate.

## Consequences

- #571 and #584 remain separate, each with its own size ADR.
- #585 revision 3 remains separate. Its current candidate is +752/−0 across four files; adding this ADR/plan pair would cross the 800-line cap.
- The previous single-PR integration branch is not a landing vehicle. #583 remains closed and unmerged; its status is recorded in the landing plan.
- No branch update, rebase, push, PR operation or CHANGELOG change is performed by this ADR draft.
