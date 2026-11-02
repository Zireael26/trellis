# Muse is retired from the herdr-foreman roster

- Status: accepted
- Date: 2026-11-01

## Context

The owner ruled Muse unavailable on 2026-11-01. There is no Meta subscription,
and pi's OpenCode Go catalogues no longer list `muse-spark-1.3-contributor`:
`pi --list-models muse` shows only the `meta/*` models (no subscription) and the
`opencode` free-tier Muse models (not ours to use).

Muse held four catalog agents in `core-rules/skills/herdr-foreman/roles.json`,
all family `meta`: `cheap` and `cheap-2` (OpenCode Go 2, prepaid), `cheap-1`
(OpenCode Go 1, prepaid) and `muse-meta` (the Meta subscription). They sat in
seven chains: fallback rungs of `foreman`, `implementer`, `hard_implementer` and
`deep_worker`, a `scout` rung, the head and tail of `reviewer`, and two refuter
seats. `meta` was also in the resolver's `UNMETERED` set.

A prepaid or unmetered route needs no usage report to be eligible, so the
resolver kept selecting these dead routes whenever Codex quota ran out, and it
seated `cheap-2` as the first reviewer for every OpenAI or Anthropic producer.
This is the failure `2026-10-08-retire-grok.md` already removed for xAI.

## Decision

1. **Muse leaves the roster.** Following the Grok precedent, the four catalog
   entries and every chain row naming them are deleted, not marked. `meta`
   leaves `UNMETERED`, so a reportless meta route gets no assumed headroom.
   The conductor recipe's `AGENT_FAMILIES` drops the four names, so a caller
   naming one gets an unknown family (DEGRADED) rather than a route.
2. **No replacement rung is added.** The chains after removal:
   - `foreman`: `sol-xhigh`
   - `implementer`: `haiku-xhigh`, `haiku`, `luna`, `sol`
   - `hard_implementer`: `sol-xhigh`
   - `deep_worker`: `sol`, `haiku-xhigh`, `luna`
   - `scout`: `gemini`, `haiku`, `glm-flash`, `luna`
   - `reviewer`: `argon`, `gemini`, `sol`
   - `security_reviewer`: `sol-xhigh`, `opus` (unchanged)
   - `merge_reviewer`: `opus`, `sol-xhigh` (unchanged)
   - `refuter`: `gemini`, `argon`, `sol`, `opus`
3. **Google takes Muse's verdict seats.** Argon (prepaid, Google) now heads
   the reviewer chain. Gemini and Argon already held refuter seats.
4. **The spec 052 rules do not change.** `required_seats` stays 3, and rules
   1–3 and the 2-vote quorum stay as they are.

## Consequences

- **The refuter is DEGRADED 1/3 beside every producer from the implementer
  chain.** Three verdict families remain: openai, anthropic and google. Rule 1
  removes the producer's family and rule 3 removes the reviewer's, so one
  refuter family is left. Only a zai (GLM Flash, scout-only) producer leaves two.
  With one seat the 2-vote dismissal quorum cannot be met, so every finding
  stands unless an operator-selected panel supplies two independent votes.
  N-of-3 needs two more families on the roster, or an owner ruling that
  changes `required_seats`.
- **Rules 1 to 3 stay satisfiable for every producer.** OpenAI output: Argon
  reviews, Opus takes security and merge, Opus refutes. Anthropic output: Argon
  reviews, Sol xhigh takes security and merge, Sol refutes. Google output: Sol
  reviews, so rule 2 moves security to Opus, and Opus takes merge and refutes.
- **Codex exhaustion now degrades the Codex-only chains instead of
  dispatching Muse.** `foreman` and `hard_implementer` are Sol xhigh alone, and
  `implementer` and `deep_worker` stop at Sol and Luna. With Codex out, those
  roles resolve DEGRADED. The operator can still pick `sonnet` (pi foreman) or
  `astra` and `sol-max` (hard work) through `--operator-agent`.
- **With no usage report, the reviewer is Argon and the foreman is undecided.**
  Before, the prepaid `cheap-2` filled both.
- **The four DEGRADED chains are accepted (lead ruling, 2026-11-01).** No
  new rungs are added. Operator overrides through `--operator-agent` remain
  the way to run those roles while Codex quota is out.
- The usage-federation `meta` lane stays. It is telemetry, not routing.
- Dated ADRs, specs, plans and receipts that mention Muse stay unchanged as
  history.

## Follow-on: Argon moves to Antigravity

Live pi does not register the `opencode-go-2` provider at all, because
`core-rules/pi/extensions/opencode-go-2.ts` registers it only when the Muse
model is present. That left `argon` (`opencode-go-2/gemini-4-argon-contributor`)
a dead route in the reviewer seat. An owner rule from 2026-10-26 also says
every Gemini model, Argon included, runs only on the Antigravity subscription
(pi provider `antigravity`), never through OpenCode.

- **Decision.** `argon` is `antigravity/gemini-4-argon:high`. It drops
  `metered: prepaid`, so it is metered on the OpenUsage `antigravity` report
  like `gemini`, and its reviewer and refuter rows take `min_remaining` 0.2,
  the same as `gemini`. The catalog defines no `argon-2`.
- **Route probe.** On 2026-10-31 the `rv-argon` pane ran interactively on
  `antigravity/gemini-4-argon` and finished a full launcher review: 70
  assistant turns, report `reports/072/review-launcher-rv-argon.md` in the
  2026-10-23 trellis-1320 handoff. The operator's pi session file
  `2026-10-31T19-15-01-720Z_01a19363-01d8-71c5-9d9b-08386cc88bc6.jsonl`
  records `model_change` provider `antigravity`, model `gemini-4-argon`.
- **Consequences.**
  - Argon and Gemini now share one quota. An Antigravity outage beside an
    OpenAI producer leaves no reviewer, because Sol shares the producer's
    family. The reviewer then resolves DEGRADED until Antigravity quota returns
    or the operator selects a route.
  - With no usage report the reviewer is undecided, as Gemini already was.

## Follow-on: GLM Flash leaves the pi roster

GLM 5.3 Flash is free-tier only and locked to the OpenCode client, so it never
runs on pi. The `glm-flash` catalog entry (`opencode-go-2/glm-5.3-flash`,
family zai) and its scout row are deleted, and the conductor drops its family.

- `scout` is `gemini`, `haiku`, `luna`.
- No prepaid catalog agent is left. The resolver's prepaid path stays, and
  tests cover it with a fixture agent.
- No zai producer is left, so every producer gets one refuter seat (see the
  first consequence above).
- `core-rules/pi/extensions/opencode-go-2.ts` stays for now; see the pi
  agent follow-on below.

## Follow-on: pi agents leave Muse

A pi agent pinned to a Muse model fails as soon as it is dispatched.

- **Deleted, following the Grok precedent.** The `cheap-ro`, `cheap-rw`,
  `cheap-1-ro`, `cheap-1-rw`, `cheap-2-ro`, `cheap-2-rw`, `muse-meta-ro` and
  `muse-meta-rw` pi agent files.
- **Re-pinned to Haiku.** The built-in overrides `Explore` and `Plan` take the
  read-only Haiku route (`haiku-ro`: `anthropic/claude-haiku-5-5`, thinking
  high). `general-purpose` takes `haiku`, the same model and thinking. Haiku is
  first in line for cheap work.
- **Probe tests moved.** Probes that dispatched `cheap-ro` now use `haiku-ro`,
  and probes that dispatched `cheap-rw` now use `haiku`, since no read-write
  Haiku file is separate from `haiku`. Their probe parents moved off
  `opencode-go-2` too. No shipped pi agent and no probe dispatch names
  `opencode-go-2`, `opencode-go` or `meta`.
- **pi's default model.** The setup guide's `settings.json` default is now
  `openai-codex/gpt-6.1-sol`, which already sits at high in
  `modelThinkingLevels`. Only the default-model lines and their verifier
  asserts changed. An operator's live `~/.pi/agent/settings.json` differs from
  the guide until it is re-rendered.
- **`opencode-go-2.ts` is not retired.** `AGENT_PI_SETUP.md` still names it
  outside the default-model lines, which belong to spec 073:
  - its install and byte-for-byte verifier blocks
  - the auth.json `opencode-go-2` entries
  - the `provider:opencode-go-2` readiness check
  - the `opencode-go-2/muse-spark-1.3-contributor` thinking level
  - the customization notes

  `scripts/pi-guide-parity.sh` and `scripts/tests/opencode-go-2.test.mjs` cover
  it as well. Retiring the extension needs those guide entries removed first.
