# Forward-only high-autonomy decision receipts

**Date:** 2026-08-10
**Status:** Accepted
**Relates to:** `docs/adr/2026-05-20-autonomy-slider.md`, spec `034`, and GOV-01 in Trellis PR #263

## Context

Trellis documents an L4/L5 decision-log contract but had no deterministic boundary proving that a substantive turn appended and rendered its current decisions. The repair spans the shared parser, thin Claude/Codex wrappers, OMP Stop handling, deployment paths, adversarial fixtures, and operator contracts.

The complete branch exceeds the normal 800-line PR cap after adding its mandatory post-facto spec pipeline. Splitting by harness or separating deployment from proof would create a merge boundary where only part of the fleet enforces the contract or where shipped behavior lacks its regression oracle.

## Decision

Add one forward-only Stop boundary backed by the Claude-canonical shared core. Claude and Codex source thin wrappers; OMP executes the same core through the canonical hook runner. Resolve the effective autonomy level and canonical root through the existing shared helper.

Validate exactly one current-turn, current-UTC-date receipt for substantive L4/L5 work. Require the canonical one-line fields and verbatim presence in the canonical-root `decisions-log.md`; require `SURFACED INLINE` for architectural entries. Never rewrite, rotate, normalize, or back-validate historical log content.

Keep the shared core, wrappers, manifests, OMP ordering, sync/onboarding deployment, tests, docs, and spec artifacts in one atomic PR. This ADR grants the process-gate size exception because every proposed split weakens either enforcement parity, deployability, or reviewer proof.

## Consequences

- L1-L3 and non-substantive turns preserve prior behavior.
- All three harnesses enforce one parser and fail-closed dependency policy.
- Existing decision logs remain untouched; only the current receipt is validated.
- Rollback is one commit-range revert of the registration, wrappers, shared core, tests, and docs; no data migration is required.
- The PR is larger than the default cap, but contains the complete behavior/proof/deployment unit reviewers must assess together.

## Alternatives considered

- Split by harness: rejected because the unmerged harnesses would remain unprotected.
- Split implementation from tests or deployment: rejected because an intermediate merge would ship unverifiable or unreachable behavior.
- Normalize legacy logs first: rejected because it mutates audit history and widens GOV-01.
- Keep prose-only guidance: rejected because it cannot deterministically enforce cross-harness parity.
