# ADR: Spec 064 ships as one combined self-hosting PR above the size cap

**Status:** accepted (2026-10-02, trellis-gate apex under coordinator-delegated authority)

## Context

PR #534 carries the Spec 064 triad, Amendment 1, the qualified-containment runner (`scripts/run-tests-local.py`) and its tests, `scripts/gate-runs.sh`, `scripts/check-gate-inventory.sh`, the four-way `doctor-fix.bats` split and refreshed stage weights. The diff is far above the 800-line hard cap. Most of it is the split: about 1,800 lines move byte-for-byte from `doctor-fix.bats` into `doctor-fix-common.bash` and four parts. The rest is the runner and its synthetic containment matrix.

## Decision

Ship it as one PR. Spec 064 Amendment 1 Decision 1 grants a §8 ordering exception: the spec and its implementation merge together, because the spec cannot pass a gate until the gate is fixed. Splitting further would break that:

- **The split alone** cannot pass the old four-shard runner either.
- **The runner alone** cannot fit the inventory without the split.
- **Spec, runner and tests** have to be reviewed as one unit, because the runner gates itself.

`scripts/check-gate-inventory.sh` proves the moved lines are a pure file split, so reviewers can treat that part as mechanical.

## Consequences

- The pr-size row reports `warn` with this ADR named, and a reviewer must acknowledge the size in the PR description.
- Review effort concentrates on `run-tests-local.py`, its tests, and the two new scripts. That is the gate-path file set whose blob hashes the gate binds to the reviewed SHA.
- This exception covers PR #534 only.
