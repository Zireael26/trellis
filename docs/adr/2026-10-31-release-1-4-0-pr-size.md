# 1.4.0 lands as one PR above the size cap

## Status

Proposed on 2026-10-31 for the 1.4.0 release PR (`feature/fast-trellis`, specs 072 and 073). This records the size exception's rationale; it is not owner approval, a gate waiver or a merge verdict.

## Context

The range against 1.3.21 is 371 files changed, +56,593 / −5,557 against `69a7a3615` at `98933c792`. 72.0 % of it is tests and committed evidence (bench and timing receipts, research notes under `specs/072-fast-trellis/evidence/` and `specs/073-hc-first/evidence/`). Spec 072 removes four repeated patterns (re-proving an unchanged release or tree, spawning processes for trivial decisions, serial work that is safe in parallel, failing instead of waiting) across hooks, the launcher, session start, checkout, Stop and the gate, in two dozen task-sized lanes, and spec 073 moves Herdr integration to the Herdr desktop app's core (`hc`).

Each lane was built and reviewed on its own branch. Most stayed under 800 changed lines; these did not, by their merges and reports:

- Shared guard rules (T9, `058a5769d`): +7,982/−581, most of it the 3,536-line `core-rules/hooks/tests/parity-cases.json` table and 1,318-line `core-rules/codex/hooks/tests/action-normalize-golden.json` fixture.
- Launcher snapshot (T4/P1, `1a01e66aa`): +1,469/−129 against its stamp base (+713/−133 on the merge into `feature/fast-trellis`), most of it a pinned copy of `release_stamp.py` and pinned supervisor blocks the launcher cannot load from a payload it has not yet trusted.
- Release-store split (T23, `8ab2d9e6d`): +3,614/−3, a mechanical move into `release-store-part{1..5}.bats` that retains the original as `scripts/tests/release-store-original.txt` for the equivalence oracle. `docs/adr/2026-10-31-release-store-split-pr-size.md`, Proposed.
- pi in-process guards (T10, `a103726fd`): +984/−85 against the guard-rules lane, the TypeScript consumer plus the closed-schema and cross-engine parity tests review asked for. `docs/adr/2026-10-31-pi-guards-contract-size.md`, Proposed.
- Base-side push test-file selector (T33, `19a4a0374`): +1,437/−52 across 28 files, the mapper plus 455 lines of unit tests and the gate range-receipt suites.
- Session start (T6/T7, `b340e506f`): +710/−552 across 20 files, the single `session-start` dispatcher and stamp-backed release confirmation across both hook trees and their suites.
- Python resolver and eslint once (T1, `95a1b29cd`): +950/−30 across 15 files, `scripts/lib/trellis-python.sh` and its 465-line test suite.
- Gate queue, verdict reuse, weights, metadata audit, trace collector, tag-push reuse and weekly battery (T17, T21, T30, T31, T32, T34, `47c649e23` and `54b0b0f24`): +3,706/−218 across 44 files on `47c649e23` (queue + tag-push reuse integration) plus +578/−32 and +246/−31 on `54b0b0f24` (full-battery trace collector and `--promote-run`).
- Herdr `hc`-first migration (spec 073, `7c26da7fd`): +1,627/−2,303 across 59 files (net −676 lines), removing the legacy `herdr` CLI pane/grid/prompt scripts and their tests.
- Muse roster retirement (`lane/072-muse`, `78736e6e9`): +576/−433 across 10 files in the roster/resolver commits plus removing the eight Muse pi agent files. `docs/adr/2026-11-01-retire-muse.md`.

Every merge runs the full battery, about 94 minutes before this release, one gate at a time. Splitting the release into one PR per lane would cost one serial gate per lane, before the battery speed-ups those same lanes deliver have landed. Most of the gate-config units also need the owner's `gate-config-approved` and three-family review, which plan 072 batches per phase.

## Decision

Land 1.4.0 as one PR with one gate. Each lane joins `feature/fast-trellis` through a merge commit, so the lane's own commits, tests and review stay reviewable lane by lane. The lane ADRs above remain separate proposals; this ADR neither approves nor supersedes them.

## Consequences

- The PR-hygiene size row keeps its warning; this ADR explains it and does not waive review.
- The owner's `gate-config-approved: <sha>` and the lane ADRs' size approvals are still required at merge.
- Units not integrated by the cut move to 1.4.1.
