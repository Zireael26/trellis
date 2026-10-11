# Release 1.3.10 lands as one gated integration branch

## Status

Accepted under the coordinator ruling of 2026-10-04 for the `release/1.3.10-int` integration PR only.

## Context

Spec 066 orders four reviewed 1.3.10 fixes: #566 (defect l, T48 private worktree), #565 ((q)+(s), fail-closed security scan and Pi auxiliaries), (t)+(u) (adopted worktree group exclude plans) and (r) (exact-owner registry release reconcile). Each passed cross-family review, and each carries its own targeted apex receipts (suites plus mutants). Gating them one at a time costs about 1.8 hours of serial bats per PR, because Trellis bats share `~/.trellis` state and cannot run concurrently. The combined range is about 1,800 changed lines, above the process gate's 800-line hard cap. More than half of it is hermetic bats coverage.

## Decision

Merge the four component branches, in spec order, into one integration branch cut from `main`, and run one full merge-mode gate on that exact head. The integration PR is what lands on `main`, so the gated head and the merged head are the same commit. Merge conflict resolution is glue only: both sides of CHANGELOG and UPGRADING entries are kept. Any resolution that would need new logic becomes its own reviewed fix. The component PRs are closed as superseded, each linked from the integration PR.

## Consequences

- The oversized range remains visible as a warning, and the PR description must record reviewer acknowledgement of the size; this ADR does not claim that acknowledgement has been given.
- No component head is gated on its own. If the integration gate goes red, defects are localised from the per-PR apex evidence instead of re-gating each PR.
- The exception covers this integration PR only. It does not raise the default size caps.
