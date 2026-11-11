# 1.5.0 lands as one PR above the size cap

## Status

Proposed on 2026-11-10 for the 1.5.0 release PR (`chore/release-1-5-0`: `feature/fast-hooks` at the T45 head plus the release cut, spec 074). This records the size exception's rationale; it is not owner approval, a gate waiver or a merge verdict.

## Context

The range against 1.4.1 (`51dd96ef8`) at `6570361e5` is 1,285 commits (251 first-parent merges) and 807 files, +911,243 / −5,104. The PR-hygiene gate counts 838,626 lines after its exclusions (tests 64,258, fixtures 13,226, lockfiles 243), against a hard cap of 1,200.

Committed qualification evidence is most of it: `specs/074-fast-hooks/evidence/` adds 775,059 lines, 92.4 % of the countable total. These are the recorder's run records for the T35–T44 cells (each policy run record is about 69,500 lines of JSON), which the T73b checker re-derives its verdicts from. They must sit at the commit the checker ran against, so they cannot move to a later PR.

The rest is the change itself: the `native/trellis-hooks` crate (+37,065, source and lockfile, excluded from the sealed payload), tests (+58,194 / −909), `scripts/` outside tests and the qualification tool (+15,398 / −2,067), the Claude and Codex hook trees (+7,501 / −1,144), and `scripts/qualification/` (+4,732). Spec 074 moved hook work into one native program across all three harnesses, in task-sized lanes, each built, tested and reviewed on its own branch and merged into `feature/fast-hooks` with a merge commit.

The 1.4.3 hardening folded into this release is in the same range (CHANGELOG "1.4.3 hardening folded into 1.5.0").

## Decision

Land 1.5.0 as one PR with one gate. Splitting it per lane would need one serial full-battery gate per lane, and the qualification receipts bind the integrated T45 head: a split release would have to re-record every cell at each step. Lane history stays reviewable lane by lane through the merge commits.

## Consequences

- The PR-hygiene size row keeps its warning; this ADR explains it and does not waive review.
- 274 commit subjects in the range are over 72 characters or not conventional-commit form. They are lane history merged with merge commits and are not rewritten (no rebase or amend under review).
- The range changes `scripts/lint-shell-tree.sh`, a declared process-gate validator dependency, so the owner's `gate-config-approved: <head-sha>` is required on the PR.
- The release tag names a payload commit that excludes `specs/` and `native/`, so none of the evidence or crate source ships in the sealed payload or reaches the public mirror.
