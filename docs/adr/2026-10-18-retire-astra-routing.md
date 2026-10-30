# Astra leaves automatic routing; Sol at xhigh takes the security seat

- Status: accepted
- Date: 2026-10-18

## Context

The owner assesses `gpt-6.1-sol` at xhigh or max as better than
`gpt-6-astra:high` and much cheaper. On 2026-10-18 the owner ruled that new
work should use Sol rather than Astra. Astra appeared in only one automatic
chain in `core-rules/skills/herdr-foreman/roles.json`: `security_reviewer`.

## Decision

1. **`security_reviewer` becomes `sol-xhigh`, then `opus`.** Keep the existing
   quota thresholds and all resolver eligibility checks. Sol at max remains
   an explicit operator selection, not an automatic chain entry.
2. **Astra remains explicit-only.** Retain its catalog entry, model, effort,
   capabilities and named agent definition. No automatic chain names it;
   `--operator-agent astra` still resolves when eligible. The generic Pi
   `security-reviewer` agent follows the new Sol-xhigh default.
3. **The three verdict-independence rules do not change.** Every verdict seat
   differs from the producer's family; security differs from the first-pass
   reviewer's family; refuter seats are pairwise distinct and differ from the
   reviewer's family. Neither the required seat count nor quorum changes.
4. **Tests pin the routing change.** The hermetic roster and resolver tests
   check the exact security chain, absence of Astra from automatic chains,
   explicit Astra eligibility and the OpenAI-producer security fallback.
   Historical ADRs and receipts remain unchanged.

## Consequences

- Sol-xhigh takes eligible non-OpenAI security work. Sol and Astra are both
  OpenAI-family, so an OpenAI producer still excludes the first security
  candidate and resolves to Opus. If no independent eligible route exists,
  resolution stays visibly degraded rather than reviewing its own family.
- New cross-checks previously planned for Astra use Sol-xhigh or Sol-max,
  retaining a different model or effort from the author where diversity is
  requested. Different efforts do not create cross-family independence.
- No model family is added or removed. The existing degraded refuter-seat
  behavior remains unchanged; this is a routing and cost decision, not a
  relaxation of review independence.
