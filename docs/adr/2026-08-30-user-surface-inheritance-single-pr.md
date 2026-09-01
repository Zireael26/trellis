# ADR: land user-global orchestration inheritance as one PR

**Status:** Accepted
**Date:** 2026-08-30

## Context

The branch exceeds the 800-line cap because one ownership contract spans inheritance manifest/surface planning, attach-detach-relink transactions, doctor drift/missing-leaf checks, release-owned Claude/OMP orchestration, resolver policy, doctrine, and their Bats coverage.

Splitting that contract would harm review and rollback:

- An intermediate PR would expose unsafe schemas and consumers while the manifest, surface plan, transactions, doctor, and resolver still disagree about ownership.
- Separating release orchestration from rendering allows the release payload and rendered ownership to drift apart.
- User `HOME` rollback and previous sidecars are coupled to attach semantics; separate landings could make rollback state inconsistent with the transaction that created it.
- Test and gate receipts are meaningful only at the integrated tip, where the cross-surface contract is present together.

## Decision

Land user-global orchestration inheritance as one PR, keeping the manifest, transactions, doctor checks, release-owned orchestration, resolver policy, doctrine, and Bats coverage in the same review and rollback unit.

Operator/release actions T16 and T27-T30 remain out of scope and open. This ADR does not claim process-gate success or rollout success.

## Consequences

- Review sees the ownership contract and its consumers together instead of approving an unsafe intermediate state.
- One revert point preserves the coupling among rendered ownership, release payloads, attach semantics, user `HOME` rollback, and previous sidecars.
- Future receipts must be evaluated against the integrated tip; partial slices do not establish this contract.
