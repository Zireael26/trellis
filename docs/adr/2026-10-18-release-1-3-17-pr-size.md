# 1.3.17 lands as one PR above the size cap

## Status

Accepted on 2026-10-18. Covers the `chore/release-1-3-17` PR.

## Context

The range against 1.3.16 is about +1,060/−50 lines across 17 files. Most of it is tests: each of the six fixes carries a regression test that fails before the fix and passes after. The fixes come from downstream project reports on 2026-10-17 and 2026-10-18: a false missing-attachment warning, the spec-gate counting root instruction files, usage-store opens too slow to share, the Stop hook failing on missing dependencies, pre-push refusing a pending adoption only after the project's suite, and pi capability notices breaking byte-exact reads.

Every merge runs the full test suite, about 70 minutes on an idle machine and longer under the fleet's load, one gate at a time. Six PRs would cost six serial gates while fleet sessions compete for the same CPU.

## Decision

Land 1.3.17 as one PR with one gate.

## Consequences

- The PR-hygiene size row keeps its warning; this ADR explains it and does not waive review.
- The `.pi/hooks` relocation is not in this release; it needs a crash-safe adoption migration and moves to the next one.
