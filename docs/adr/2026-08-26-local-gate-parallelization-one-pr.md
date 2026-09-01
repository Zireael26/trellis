# ADR: land the local gate parallelization and its shard-balance fix as one PR

**Status:** Accepted
**Date:** 2026-08-26

## Context

Branch `fix/mirror-google-antigravity-provider` carries three commits and a
1,217-line diff, above the 800-line hard cap:

1. `b5188f8a fix(mirror): allow live Google provider route` — 59 lines. Unblocks the
   rc.33 public-mirror dry-run.
2. `f502a71e perf(test): parallelize local full gate` — 772 lines. Introduces
   `scripts/run-tests-local.py`, which fans `run-tests.sh` into four shards under a
   3,600-second deadline.
3. `f1e7738f fix(test): balance local gate shards by measured weight` — 420 lines.
   Corrects (2): round-robin sharding put `doctor.bats`, `release-store.bats`, and
   `sync-hooks-settings.bats` on the same shard, measured at ~5,000 s against the
   deadline. Two clean runs of (2) alone ended with shard 1 `status=124` while shards
   2–4 finished in 1,369–1,651 s. LPT over a checked-in weight table plans four
   shards at 2,343 s each; the full battery then completed in 2,383 s.

The only battery receipt that exists is for the combined tip. Splitting at the cap
produces one of two states, both worse for review and rollback:

- A mirror-only PR (1) would have to be gated by the pre-existing serial
  `run-tests.sh`, a two-to-three-hour run with no timing receipt, to produce the
  Tests row the gate requires.
- A perf-only PR (2) would land a local gate that is known to time out on its own
  shard 1. Anyone running the merge gate between that merge and the follow-up fix
  gets a spurious `BLOCKED`, and a rollback of (3) alone re-creates the breach.

(2) and (3) are one change: the fix was found by measuring the parallel gate on
this branch, in this session, and the measurement is only meaningful against the
combined code. Reviewing them together shows the round-robin decision, its
measured failure, and its correction in one diff.

## Decision

Land all three commits in one PR. Reviewer acknowledgement of the size is recorded
in the PR description alongside the process-gate verdict.

## Consequences

- One PR, one battery receipt (73/73 stages, 2,383 s wall, four shards planned at
  2,343 s), one revert point.
- `scripts/tests/stage-weights.tsv` becomes a checked-in artifact that decays as
  suites change; the wrapper logs planned totals at startup so drift is visible.
  Re-measure when a shard total exceeds 3,000 s.
- `doctor.bats` at 1,842 s is now the floor for any four-way split; reducing the
  gate further means shortening that suite, not re-sharding.
