# Release 1.3.11 lands as one PR above the size cap

## Status

Accepted under the coordinator rulings R11/R14 (one PR), R23, R30, R31, R34 and R35 (size ACKs) for PR #573 (which supersedes #572) only.

## Context

1.3.11 bundles fixes that block other projects:
- the secrets allowlist moving out of the linked process-gate skill (a project's attach refusal);
- the launcher diagnostic;
- `DOCKER_HOST` forwarding into the gate payload (one project's Docker failure);
- three doctor WARNs;
- the merge-mode range refusal (R1);
- the pre-push ref rules (R4);
- the release-store lease (R10);
- security fixes from review (R29, amended by R31, R33 and R34).

The coordinator ruled that it ships as one PR rather than a stack, because each extra PR costs a full serial gate of about two hours: Trellis bats share `~/.trellis` state and cannot run concurrently. The range is 1,980 changed lines (non-test 862, test 1,118), above the process gate's 800-line hard cap. More than half of it is hermetic bats coverage, and the byte-identical pre-push carriers count twice.

## Decision

Land #573 as one PR, gated in merge mode on its exact head. Size is bounded by explicit coordinator ACKs (R14 1,650; R23 1,815; R30 1,860; R31 1,920; R34 1,950; R35 1,980). The PR body records the test and non-test split, the twin double count, and the late hunks that each ACK covered.

## Consequences

- The oversized range stays visible in the gate's PR-hygiene row. The PR description records the coordinator's size acknowledgement; this ADR does not grant it.
- The exception covers PR #573 only. It does not raise the default size caps.
