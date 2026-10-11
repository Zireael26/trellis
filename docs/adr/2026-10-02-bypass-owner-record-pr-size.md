# Bypass owner-record checker and harness tests ship together

## Status

Accepted under the apex ruling of 2026-10-02 for PR #536 only.

## Context

PR #536 replaces manifest-based hook assumptions with worktree-local owner-record verification. Its pre-round-3 range is about 1,307 changed lines, above the process gate's 800-line hard cap. Most of the change is the fixture-backed per-harness matrix for Claude, Codex and Pi: ownership identity, stripped or stale registrations, runtime anchors, and fail-closed state errors. Round 3 adds common runtime pinning and owner-recorded root binding with their regressions.

## Decision

Ship the checker and its per-harness test matrix in one PR, with this added ADR documenting the size exception. Splitting would land an untested checker or tests for code that does not exist yet. Each attachment and drift case depends on the same owner-record contract, so reviewers need the implementation and its positive, negative and inversion evidence together.

## Consequences

- The oversized range remains visible as a warning and requires reviewer acknowledgement; this ADR does not claim that acknowledgement has been given.
- Review and rollback cover one coherent checker/fixture contract rather than intermediate states with missing coverage or failing tests.
- The exception is specific to PR #536, not an increase in the default size caps.
- Verification for this round is the targeted `check-bypass.bats` suite, requirement inversions and ShellCheck; no full battery is run or claimed.
