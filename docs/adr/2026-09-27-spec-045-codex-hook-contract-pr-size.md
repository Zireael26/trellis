# Spec 045 Codex hook output contract ships as one PR over the size cap

- Status: accepted
- Date: 2026-09-27

## Context

PR #504 carries the spec 045 amendment "Codex hook output contract" and its implementation. It is about 2,100 countable lines, over the 800-line hard cap. More than half are spec-first evidence that the operator's PROTOCOL §7 (2026-09-27) requires:
- the diagnosis;
- five rounds of multi-family reviews and dispositions;
- the Claude code reviews;
- the L1/L2 live Codex receipts.

The code is the Codex hook emit and exit paths, the pi bridge, the stop-verify rollout reader, and the contract test suite with a synthetic fixture.

## Decision

Ship the amendment and its implementation as one PR, squashed into two commits (spec, then fix), following `2026-09-18-spec-050-release-size.md`.

1. **The contract only holds as a whole.** Changing the Stop exit semantics without the pi-bridge, reread-guard and rollout-reader changes would regress enforcement status or block every Codex turn. The L1 receipt shows the latter.
2. **The review record is the unit of review.**

## Consequences

- Rollback is a revert of the fix commit. The Claude twins are untouched, so a revert affects only Codex and pi.
- The reviewer acknowledges the size in the PR description.
