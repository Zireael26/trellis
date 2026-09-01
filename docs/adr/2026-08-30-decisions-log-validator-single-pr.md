# ADR: land the decisions-log validator and mutation evidence as one PR

**Status:** Accepted
**Date:** 2026-08-30

## Context

The decisions-log validator change is 1,534 insertions across 35 files. The measured breakdown is:

- receipts: 641 lines
- fixtures: 275 lines
- Bats contract tests: 266 lines
- validator: 234 lines
- other change material: 118 lines

The validator, fixtures, and tests together are 775 lines, below the 800-line hard cap. The evidence required by spec 042 pushes the aggregate PR over the cap.

The central claim is not merely that a validator exists. It is that each test fails when the behavior it protects is removed. The committed RED/GREEN mutation receipts prove 16/16 per-test reversions and 10/10 review-refinement reversions. Omitting them would leave a code-only PR asserting that its tests are load-bearing without any reviewable evidence—the same self-authored-acceptance failure this validator exists to prevent.

A receipts-only follow-up would not be independently reviewable. Mutation output has no meaning without the exact validator branches, fixtures, and assertions beside it. Splitting the work by commit also cannot reduce the aggregate PR size checked by the gate.

## Decision

Land the validator, fixtures, Bats contracts, RED/GREEN mutation receipts, routing receipts, review shortfall, and supporting changelog/gotcha updates in one PR and one rollback unit.

Use the process-gate ADR exception for this measured evidence-driven oversize. The exception is specific to spec 042's reviewable proof; it is not a general exemption for unrelated implementation growth.

## Consequences

- Reviewers can inspect each behavior, its fixture, its GREEN result, and the corresponding RED mutation in one diff.
- A single revert removes the validator contract and the evidence that certifies it, avoiding orphaned receipts or assertions.
- The PR is larger because its proof is committed, but the executable change—validator, fixtures, and tests—remains below the normal hard cap.
- The PR-size gate should warn and require reviewer acknowledgment rather than fail once this ADR is present.
