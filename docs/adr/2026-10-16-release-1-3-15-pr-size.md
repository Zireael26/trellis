# 1.3.15 lands as one PR above the size cap

## Status

Accepted on 2026-10-16 under the owner's instruction to merge what is needed. Covers the `chore/release-1-3-15` PR.

## Context

The range against `main` is about +970/−180 lines across 58 files. Most of it is tests and fixtures; the rest is code and docs. Each fix carries a test that fails before it and passes after.

Every merge here runs the full test suite, about 70 minutes on an idle machine, one gate at a time. The release bundles eleven small fixes that share files (`roles.json`, the routing tests, `deps.sh` in both hook trees), the way 1.3.13 shipped. Review was split by author: Claude's receipt-check and OpenUsage-adapter fixes were reviewed by GPT-6.1 Sol on pi until it approved; the foreman's units, written by GPT-6 Sol, were reviewed by Claude, which held back one unit (removing the automatic code-review rung) for an owner decision and dropped a managed-exclude-block change so adoption needs no re-attach.

## Decision

Land 1.3.15 as one PR with one gate.

## Consequences

- The PR-hygiene size row keeps its warning; this ADR explains it and does not waive review.
- The held-back code-review change stays out until the owner decides; its patch is kept outside the repository.
