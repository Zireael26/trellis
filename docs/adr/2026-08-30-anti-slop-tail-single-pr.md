# ADR: keep the anti-slop tail and its evidence in one PR

**Status:** Accepted
**Date:** 2026-08-30

## Context

The anti-slop implementation shipped before this tail: rc.29/rc.30 carried the feature and the
fleet is on sealed rc.35. This branch closes the remaining spec 037 evidence contract:
deterministic T18 verification, advisory pilot profile diffs, fresh-session probes, the full
audit, and rollback proof.

The process gate's two-dot `origin/main..HEAD` range reports 7,718 changed lines, above its
800-line hard cap. That number is the range shape, not a claim that this tail authored 7,718 new
lines: the tail fork predates later `origin/main` release work, so the two-dot diff includes that
mainline evolution as deletions. The exception applies to the named tail evidence being landed,
not to the already-shipped implementation.

Splitting that evidence would separate claims from the artifacts that prove or reverse them:

- T18's skill-size, full-suite, process-gate, and simulated post-sync mirror receipts verify the
  sealed rc.35 payload that the pilots inherited.
- T20/T21's two pilot profile commits exercise the TypeScript and Python configs.
  The TypeScript pilot's posture is branch-only; the Python pilot's base already declared advisory posture, while this
  pilot branch adds only the Python profile.
- T22's probe fixtures, VOID records, session IDs, and zero-hit results depend on the same seeded
  pilot state.
- T23's audit output and T24's posture/env rollback proof establish the operational blast radius
  and exact reversal path.

An evidence-only split could land a probe without its pilot state, an audit without the installed
profile, or a rollback claim without its manifest/hook hashes. Those partial states are harder to
review and cannot be reverted as one tail decision.

## Decision

Land the remaining spec 037 tail evidence as one PR and review each claim beside its command,
session, pilot diff, or rollback receipt. Keep the pilot profile branches PR-free and unmerged;
they are external rollout evidence, not additional merge units.

## Consequences

- One review range ties every tail claim to its command output, model/session receipt, pilot diff,
  or rollback hash.
- One revert removes the in-repo tail evidence and task closure together. It intentionally does
  not claim to remove the anti-slop implementation already shipped in rc.29/rc.30.
- Pilot profile branches can be discarded independently without writing a main checkout. The Python pilot's
  pre-existing advisory posture is outside this branch and remains explicit.
- Future cleanup of the 102 pilot audit findings is excluded and must use separate changes.
