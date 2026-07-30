# ADR — Publish the July operational snapshot atomically

**Date:** 2026-07-27 · **Status:** accepted

## Context

The local Trellis main contains one previously committed operational snapshot
covering July 11–27. It records conductor slates, audit reports, the current
slate state, and the generated research report used by those records. The
snapshot predates the shared-local-infrastructure planning work but has not yet
been published to the private canonical repository.

The snapshot exceeds the normal pull-request line cap. Splitting it by file or
date would detach the final machine-readable slate state and generated report
from the audit/conductor history that explains them. It would also make a
partial rollback capable of leaving mutually inconsistent operational records.

## Decision

Publish commit `9fb754f` as one reviewable pull request before the
shared-local-infrastructure planning chain.

- Treat the 68-file snapshot as an append-only operational ledger, not a
  runtime or product change.
- Preserve the original commit and its file relationships.
- Require an independent secret-shape and consistency review before merge.
- Keep publication limited to the current private Trellis repository because
  operational records contain local paths and environment identifiers.
- Use a merge commit so the original snapshot remains directly auditable.

This ADR is the one-time process-gate size exception for that pull request.
Future operational records continue to publish in smaller, regular increments.

## Consequences

Reviewers see a large but internally coherent historical snapshot. Runtime
behavior is unchanged. Rollback is a single revert of the merge commit, which
removes the snapshot and this exception together without rewriting history.

## Alternatives considered

- **Split by date.** Rejected because the final slate and generated report span
  the recorded period and would be misleading in a partial merge.
- **Drop generated artifacts.** Rejected because byte-for-byte regeneration is
  part of the audit receipt.
- **Leave the snapshot local.** Rejected because the operator explicitly
  requested all committed Trellis changes be published and synchronized.
