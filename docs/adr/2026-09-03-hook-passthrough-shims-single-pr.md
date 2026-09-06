# Hook pass-through shims ship as one PR

- Status: accepted
- Date: 2026-09-03

## Context

PR `fix/hook-passthrough-shims` (8 commits, ~930 changed lines, 241 of them a new
bats suite) exceeds the 800-line hard PR-size cap in the process gate, which permits
an ADR explaining why splitting harms clarity. This is that ADR.

The feature: managed hook-dir writes install pass-through shims for every prior git
hook name, so the dispatcher, validators, detach, and adoption paths agree on what a
managed dir is in the same release.

## Decision

Ship as a single PR rather than splitting.

The shims are only correct together with (a) `GIT_*` env forwarding to delegated
commit-family hooks and (b) identity-pinned shim writes matching the dispatcher
hardening. Without (a), lint-staged runs against the wrong index — a silent defect.
Without (b), recovery writes diverge from what the dispatcher verifies.

Splitting along the only natural seams would land a known-defective intermediate
release with `rc.47` imminent: shims without forwarding, or forwarding without pinned
writes. The validators, detach, and adoption paths must agree on the shim set in the
same release, or attach and adopt disagree on what a managed dir is.

## Consequences

- One larger review, mitigated by the cross-family review already run and the green
  suites: 7/7 + 14/14 + 49/49.
- No intermediate release ships shims that delegate against the wrong index or writes
  the dispatcher will not recognise.
- `check-pr.sh` reports **warn** rather than fail via the ADR exception.

## Status

Accepted 2026-09-03. The single-PR shape is the only correct cutover for the shim set.
