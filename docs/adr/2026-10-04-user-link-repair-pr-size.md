# User-link repair and its recovery tests ship together

## Status

Accepted under the apex ruling of 2026-10-04 for PR #561 only.

## Context

PR #561 fixes issue #554: `trellis relink --user` now restores missing, already-owned user symlinks through the attachment journal. Two cross-family review rounds (W46, W48) asked for repair recovery that can always be discarded, an exact release-specific remedy on interruption, a mixed 1.3.9 → 1.3.10 runtime test, and independent absence assertions. That brought the range to about 1,000 changed lines, above the process gate's 800-line hard cap. Roughly two thirds of it is hermetic `user-surface.bats` coverage for interruption, discard, lock contention and the mixed-runtime upgrade path.

## Decision

Ship the repair, its discard-on-failure recovery, and the regression matrix in one PR, with this added ADR documenting the size exception. If the work were split, one PR would land a repair whose interrupted journal can wedge the user surface (W46 F1), or would land the recovery tests before the code they test. Both halves depend on the same journal contract, so reviewers need them together.

## Consequences

- The oversized range remains visible as a warning and requires reviewer acknowledgement in the PR description; this ADR does not claim that acknowledgement has been given.
- Review and rollback cover one coherent repair/recovery contract instead of an intermediate state with a known wedge.
- The exception is specific to PR #561, not an increase in the default size caps.
