# 1.3.20 lands as one PR above the size cap

## Status

Accepted on 2026-10-23. Covers the `chore/release-1-3-20` PR.

## Context

The range against 1.3.19 is about +1,905/−151 lines across 37 files. About 1,270 of those lines are tests: each fix carries a regression test that fails before the fix and passes after. The fixes come from fleet reports on 2026-10-22 and 2026-10-23 (two attached projects): stale exclude after-images left by group adoption in non-manager owners, attach and show-config walks slow enough to stall post-checkout hooks, pi refusing the pi-subagents result and steering tools, and mirror lint findings that blocked publication since 1.3.15.

The exclude after-image repair only takes effect through re-adoption with the 1.3.20 CLI, so worktrees of the two attached projects stay faulted until this release ships. Every merge runs the full test suite, about 90 minutes under the fleet's load, one gate at a time. Splitting the eight fix commits into eight PRs would cost eight serial gates while those projects wait.

## Decision

Land 1.3.20 as one PR with one gate. Each commit stays a single fix with its own test, so review can still go commit by commit.

## Consequences

- The PR-hygiene size row keeps its warning; this ADR explains it and does not waive review.
- Fixes accepted after the cut (#607 donor walk, #608 Tests range, #609 per-worktree surgical marker and the other wave-6 lanes) move to 1.3.21.
