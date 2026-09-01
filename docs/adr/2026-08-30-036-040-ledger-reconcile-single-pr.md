# ADR: reconcile specs 036 and 040 ledgers and receipts as one PR

**Status:** Accepted
**Date:** 2026-08-30

## Context

This change reconciles 20 stale units across specs 036 and 040 against the same immutable-release and fleet-adoption history. It keeps each ledger tick or correction with its executed command, exit, evidence, shortfall, routing/backend receipt, review remediation, and GLM refutation record. That complete evidence set exceeds the generic 800-line PR cap; the size is reconciliation evidence, not unrelated implementation.

Splitting the two ledgers or their receipts across PRs would create partial states. Spec 040's rc.33 shortfall and rc.34/rc.35 adoption depend on the release and fleet evidence reconciled in spec 036. A ledger-only PR could change checkboxes without the receipts that justify them, while a receipts-only follow-up could not be reviewed against the exact ledger state it supports. Reviewers would have to reconstruct counts and release identities across PR histories. Rollback would likewise require selecting interdependent ledger, receipt, review, and refutation changes instead of reverting one coherent evidence boundary.

## Decision

Sanction one PR for this two-ledger reconciliation and its atomic receipts. Keep the spec 036 and 040 ledger changes, all 20 unit results, route/backend receipts, review remediation, and refutation evidence together while preserving commit-level review. The exception bypasses no tests, security checks, or process gates. Keep all seven not-done and seven done-with-shortfall outcomes explicit, and exclude unrelated work. This decision records the size exception; it does not authorize creating, merging, deploying, or pushing a PR.

## Consequences

- Reviewers get one complete surface for cross-checking ledger state, release identities, counts, and evidence.
- The change remains above the generic 800-line cap, intentionally and only for complete reconciliation evidence.
- Rollback has one clear boundary instead of selectively reversing interdependent ticks and receipts.
- Tests, security, and process controls remain unchanged; incomplete outcomes and unrelated-work boundaries remain visible.
