# ADR: keep Usage Federation as one reviewable cutover

**Status:** Accepted
**Date:** 2026-08-28

## Context

After rebasing `feature/usage-federation` onto rc.35, the branch contains 32
commits and a 99-file diff with 42,107 insertions and 9 deletions. This exceeds
the 800-line review cap.

The size is the implementation boundary of spec 039 rather than an incidental
batch of unrelated changes. The branch introduces one closed system: the typed
usage contract, private SQLite store and migrations, transcript projectors and
watermarks, quota and inventory adapters, collection and query assembly, CLI
surfaces, fixtures, behavioral tests, operator documentation, and cutover
ledger. Those layers share schema versions, source identities, completeness
rules, privacy constraints, and exit semantics.

Splitting by layer would create intermediate branches that cannot satisfy the
contract. A store-only change has no producer or consumer; a projector-only
change cannot publish coverage safely; a CLI-only change has no compatible
query response; tests and documentation describe the combined contract. The
30 pre-rebase feature commits are intentionally preserved rather than squashed,
so reviewers can inspect those boundaries even though the PR diff remains one
cutover.

The branch is still a draft. Existing gates remain explicit: T35 warm-query
performance and T39 machine-two shadow are not closed, OpenUsage remains
running, and no push, merge, release, or consumer cutover is authorized by this
exception.

## Decision

Keep Usage Federation in one draft PR and grant a size exception for the full
`origin/main..HEAD` diff. Preserve the commit sequence. Require the focused
Usage Federation Bats suite, the one-root live refresh receipt, and the
repository process gate against the combined tip before the apex decides
whether to rewrite-push the rebased branch.

## Consequences

- Review cost is higher, but schema, collection, query, presentation, tests,
  and documentation remain mutually consistent at every accepted tip.
- Commit-level review remains available; the exception does not authorize a
  squash or bypass any gate.
- Rollback remains the existing Usage Federation cutover boundary. OpenUsage is
  not stopped until the outstanding performance and machine-two gates close.
- Future unrelated work must not enter this exception. Any follow-on feature or
  refactor requires its own bounded change and gate receipt.
