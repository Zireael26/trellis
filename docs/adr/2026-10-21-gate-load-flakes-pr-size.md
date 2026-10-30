# The gate load-flake fixes land as one PR above the size cap

## Status

Accepted by the owner's instruction of 2026-10-20 to finish every open Trellis PR and ship 1.3.19. Covers the test/gate-load-flakes PR only.

## Context

The v1.3.19 tag push failed its pre-push gate three times (2026-10-20, gate runs 966ae195, d85699a2 and f24d03a3) on tests that pass alone. Each failure came from load-sensitive timing or process inspection in the test harness:

- a wall-clock bound on release verification;
- the disk-janitor `lsof` and `df` shims;
- fixed sleeps in the worktree hooks;
- 3 s guard deadlines;
- the Go mutation control;
- the run-tests-local containment scan, which treated an unrelated process caught mid-exit as a run survivor.

The range is 913 changed lines (+819/−94) over 24 files, above the process gate's 800-line hard cap. About 700 of those lines are tests. The production changes are small:

- `run-tests-local.py`: the containment scan;
- `check-tests.sh`: keeping the full failing-check output;
- one message in `trellis-worktree-remove.sh`.

Splitting the PR would mean at least two more serial gate runs (about 100 minutes each on this shared host). Each part alone would still leave some of the failing tests in place, so any partial merge leaves the 1.3.19 tag gate red. It also supersedes PR #544, whose two commits it carries.

## Decision

Land the fixes as one PR, gated in merge mode on its exact head. Cut 1.3.19 from the merge commit. The version stays 1.3.19, and the release payload strips the tests, so only the gate's own tests differ from the earlier candidate.

## Consequences

- The oversized range stays visible in the gate's PR-hygiene row as a warning. The PR description records the size acknowledgement; this ADR does not grant it.
- #544 closes as superseded when this merges.
- The earlier local, never-pushed v1.3.19 tag is replaced by one cut from the new release commit.
