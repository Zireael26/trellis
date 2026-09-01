# ADR: reconcile spec 023's ledger and evidence as one PR

**Status:** Accepted
**Date:** 2026-08-29

## Context

Spec 023 reconciles T01–T53 plus the atomic routing, backend, result, adjudication, and review evidence. The current change exceeds the 800-line PR cap because the evidence is intentionally complete; the size is not unrelated implementation.

Splitting the cutover across PRs would leave partial states. A PR containing ledger ticks and per-unit receipts without adjudication and reconciliation counts would not describe the final ledger; a later PR could add the decisions and counts without the source evidence in the same review surface. Reviewers would have to cross-check related ticks, receipts, adjudication, and counts across PR histories, making that cross-check less clear. Rollback would likewise require selectively reversing interdependent ledger and evidence changes, making the rollback boundary less clear.

## Decision

Sanction one PR for this ledger/evidence cutover only. Keep the complete T01–T53 ledger, atomic routing/backend/result/adjudication/review evidence, adjudication, and reconciliation counts together while preserving commit-level review. The exception bypasses no tests, security gates, or process gates. Keep all 18 not-done items explicit, and exclude unrelated work. This decision records the scope exception; it does not authorize creating, merging, or deploying a PR.

## Consequences

- Reviewers get one complete, commit-level cross-check surface instead of partial ledger states or split evidence trails.
- The change remains above the generic 800-line cap, intentionally and only for complete reconciliation evidence.
- One cutover provides a clear rollback boundary without selectively reversing ledger, receipt, adjudication, or count records.
- Tests, security, and process controls remain unchanged; the 18 not-done items and unrelated-work boundary remain visible.
