# ADR: land the WikiSkill promotion contract as one branch

**Status:** Accepted
**Date:** 2026-08-29

## Context

Branch `feature/018-wikiskill` changes 379 files with 10,324 insertions and
7,935 deletions relative to `origin/main`: a net increase of 2,389 lines, above
the 800-line review cap.

The size comes from one versioned contract cutover:

1. The v2 clarify/spec/plan/tasks triad fixes the exact wiki catalog, pattern,
   eight-column ledger, nine-field sidecar, evaluation, rejection, and
   human-promotion contracts.
2. The two skills and their validators implement those schemas and capability
   boundaries.
3. Hermetic fixtures and behavioral tests prove the same contracts, including
   strict score comparison, durable rejection, no automatic landing, and
   human-only merge/revert transitions.
4. Dispatch receipts preserve the required model-routing and independent-review
   evidence for each implementation unit.

Splitting these across branches would leave either documentation without an
enforced implementation, implementation without its authoritative schema, or a
promotion gate without the negative-capability tests that make it safe. The
phase-boundary commits already provide bounded review and rollback points inside
the branch. Phase 5 pilot work is explicitly excluded.

## Decision

Land Spec 018 phases 1–4, their validators, fixtures, tests, hook integration,
and routing receipts as one reviewed branch. Use the phase-boundary commits as
the review sequence and require the serialized branch process gate before push.

## Consequences

- Reviewers receive one internally consistent schema and implementation cutover.
- The branch exceeds the normal size cap; this ADR and the final process-gate
  receipt make that exception explicit.
- Phase commits isolate the triad, analysis, wiki contracts, maintainer,
  proposer gate, and negative-capability safeguards for targeted rollback.
- No pilot, fleet rollout, user-global publication, merge, or deployment is
  included.
