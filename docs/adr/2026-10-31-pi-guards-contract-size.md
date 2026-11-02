# Keep the pi guard port and its cross-engine contract tests together

## Status

Proposed for the Spec 072 T10 integration PR. This records the size exception;
it does not grant approval, waive a gate, or authorize a merge.

## Context

The original T10 port was 763 changed lines. Review `rv-muse-d` required the TS
consumer to inherit the final T9 exemption schema, reject unknown policy keys,
and pin the independent shell/TS skill budgets against drift. The requested
schema and data-driven regression tests take the combined T10 delta above the
800-line cap. Exact counts are retained in the lane report.

The T9 commits are adopted unchanged from `66bae25a7`. Shared JSON, generator,
runtime, and refusal cases have no T10-authored delta against that dependency.
The size here is the TS consumer and its tests, not a competing policy design.

## Decision

Propose reviewing the TS port, closed-schema checks, shared-table runner, native
failure accounting, and budget drift tests as one acceptance unit. Splitting
schema handling from its parity tests would leave an unproved security-sensitive
intermediate tree. Keep prerequisite adoption separate in the commit history.

## Consequences

The integration PR must disclose its size and obtain the normal size approval.
Every safety test, mutation check, and release gate still applies; this ADR
provides no bypass. The handled post-hook latency limitation remains explicit.
