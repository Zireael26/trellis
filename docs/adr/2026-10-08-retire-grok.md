# Grok is retired from the herdr-foreman roster; Astra takes the security seat

- Status: accepted
- Date: 2026-10-08

## Context

Since 2026-10-07 every xAI call has returned 403 ("out of credits / need a Grok
subscription"). The owner ruled Grok retired from the roster on 2026-10-08.

Grok held four kinds of seat in `core-rules/skills/herdr-foreman/roles.json`:

- `security_reviewer` (the `security-reviewer` catalog agent and pi agent file
  both pinned `xai/grok-4.6:xhigh`);
- a refuter seat, second in the chain after Gemini;
- the last rung of `merge_reviewer`, `hard_implementer` and `foreman`;
- `xai` in the resolver's `UNMETERED` set, an operator assertion of headroom
  made on 2026-09-04 so reportless Grok routes stayed eligible.

A dead route that stays in the catalog is not harmless. With `xai` declared
unmetered, the resolver would keep choosing Grok for the security seat and
handing out a route that cannot answer. Swapping another model in behind the
same name would hide the change. The owner asked for the reverse: the role map
changes visibly, and tests pin it.

## Decision

1. **Grok leaves the roster.** The `grok` and `security-reviewer` catalog
   agents, every chain row naming `grok`, and the `grok-ro` / `grok-rw` pi agent
   files are removed. `xai` leaves `UNMETERED`, so a reportless xai route gets
   no assumed headroom. The conductor recipe's `AGENT_FAMILIES` drops `grok`.
2. **`security_reviewer` opens on Astra at high.** `astra`
   (`openai-codex/gpt-6-astra:high`, never xhigh, per the standing owner rule)
   gains the `security-review` capability and heads the chain `astra`, `opus`,
   `sol-xhigh`. The `security-reviewer` pi agent file now pins
   `openai-codex/gpt-6-astra` at `thinking: high`, and the conductor maps it to
   `openai`.
3. **Gemini 3.8 Flash at high holds the refuter seat Grok shared.** The chain
   becomes `gemini`, `cheap-2`, `sol`, `opus`, `cheap`. Gemini was already the
   first seat, and a second Google seat cannot count: spec 052 rule 3 requires
   pairwise-distinct refuter families. So Grok's seat is removed, not refilled.
4. **The spec 052 rules do not change.** `required_seats` stays 3. Rules 1–3
   and the quorum (2 votes outside the finding author's family) are unchanged.
5. **Tests pin the new map.** `test_roster_resolves.sh` checks that no catalog
   entry, chain, pi agent file or resolved role (for every implementer, with xai
   reporting full headroom) reaches an xai route. The resolver bats pin the new
   chains, seats and DEGRADED states.

## Consequences

- **The refuter is DEGRADED 2/3 beside every producer.** Four families remain:
  openai, meta, google and anthropic. Rule 1 removes the producer's family, and
  rule 3 removes the reviewer's, which always differs from the producer's. That
  leaves at most two refuter families. Every resolution therefore reports
  `DEGRADED: refuter has 2/3`, `approval_ready: false` and
  `verdict_families_distinct: false`. This is the "always red" state that
  `2026-09-27-gpt6-roster.md` warned stops being read. It is reported, not
  hidden: N-of-3 needs a fifth family on the roster, or an owner ruling that
  changes `required_seats`. This ADR makes neither change.
- **The refuter quorum still works for reviewer-authored findings.** Two seats
  outside the reviewer's family can still dismiss a finding, because rule 3
  recuses no seat. A security- or merge-authored finding whose author family
  matches a seat (for example Opus, with the Opus refuter seat) leaves one
  eligible vote, so `--panel --finding-author` exits 1 and the finding cannot
  be dismissed.
- **Astra reviews security only for non-OpenAI output.** Astra is family
  openai. For an OpenAI producer (Luna, Sol, Astra), rule 1 refuses Astra and
  Opus takes the security seat. Astra takes it for Haiku, Opus, Muse and Gemini
  output.
- **An Anthropic outage beside an OpenAI producer now leaves no security or
  merge reviewer.** Grok used to be that fallback. Now `security_reviewer` and
  `merge_reviewer` both resolve DEGRADED until Anthropic quota returns or the
  operator selects a route explicitly.
- `hard_implementer` is `sol-xhigh`, then `muse-meta`. `foreman` loses its last
  rung.
- The usage-federation layer still parses xAI quota reports
  (`scripts/lib/usage_federation`). That is telemetry, not routing, and this
  change leaves it alone.
- Dated ADRs, specs, plans and receipts that mention Grok stay unchanged as
  history.
