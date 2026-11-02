# Release-store split exceeds the line cap as a mechanical move

## Status

Proposed for spec 072 T23 (split half only). This records the size exception's
rationale, not owner approval or a merge verdict.

## Context

The 3,308-line `release-store.bats` is the battery's longest single stage
(A1: 5,636 seconds). Its historical fixture dominates setup even for tests
that never use it. The lane brief requires byte-identical test bodies and a
committed check against the original, so the original remains as a non-runnable
`.txt` alongside five runnable parts and their unchanged shared helpers.
Retaining that source makes the check independent of Git history depth.
The move therefore exceeds 800 changed lines even though no product code changes.

## Decision

Review the mechanical move together with its equivalence guard and runner
registration. Keep all eight historical group-plan cases in part1; only that
part builds the historical baseline. Group the other parts by render/retirement,
managed checkout, bulk registry, and immutable-store dependencies. Keep the
runner's existing two-job policy. Do not implement the owner-Q7 shared cache.

## Consequences

The original 86 test names and bodies must match the union of parts exactly.
The guard must reject a dropped, doubled or edited case. Each part still builds
its own required fixtures; no cross-part cache or new precomputation is added.
The oversized diff and gate-config approval remain visible review obligations.
