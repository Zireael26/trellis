# Multi-model lane continuity: degrade at the caller, never substitute in the router

Date: 2026-07-26
Status: Accepted
Spec: `specs/021-multi-model-lane-continuity/`

## Context

A local router splits Claude Code traffic by model name: first-party models pass through to the
official endpoint on subscription auth, while a set of foreign model names is routed to a separate
lane. The lane is a second subscription, with its own limits and its own outages.

The router already **detects** lane failure. It counts consecutive errors, recognises an
auth-cooling upstream, exposes a `degraded` state, and colours the statusline red. What it does
next is return a bare 502/503, and the delegated agent dies. So an outage or a hit rate limit does
not degrade the work — it ends the unit, and the operator reconstructs why from a red statusline.

Separately, the agents that target the lane pin the lane's model name in their frontmatter. On any
host without the router that name resolves to nothing, so the agent hard-fails at dispatch. This is
why the surface has never been publishable: the artifacts only work where the infrastructure
already exists.

The repo solved this exact shape once before, for a different foreign backend
(`core-rules/agents/codex-worker.md`): pin a **first-party** model, reach the foreign backend over
`Bash`, and return a structured UNAVAILABLE receipt so the caller re-runs the identical unit
locally. The pattern was simply never applied to the newer lane.

## Decision

**Degrade at the caller. Never substitute in the router.**

1. Agents that target the lane pin a first-party model in frontmatter and reach the lane through
   `Bash`. The lane becomes an enhancement, not a prerequisite. The artifact works everywhere.
2. A fail-closed probe (`scripts/lane-preflight.sh`) reports availability and nothing else. It
   always exits 0; unknown, error, and timeout all resolve to unavailable. Callers decide.
3. On unavailable, the agent returns a structured receipt — `STATUS: UNAVAILABLE`,
   `CODE: LANE_UNAVAILABLE`, a reason, and an explicit instruction that the caller must re-run the
   identical unit on the first-party model. UNAVAILABLE is a capability result, never SUCCESS.
4. The router's change is confined to what it *emits*: a structured 503 with a machine-readable
   reason, so callers can tell "lane is down" from "your request was malformed."
5. The public template carries the capability contract — lanes, the predicate, the degrade tiers —
   and never names the specific third-party proxy this instance happens to use.

## Alternatives considered

**Silent fallback inside the router: rewrite the model to a first-party one when the lane is
degraded, and serve it.** Rejected, and this is the central decision.

It is superficially the best option: transparent, needs no agent changes, and fixes already-running
sessions because it is server-side. But it spends the first-party subscription invisibly. The
caller believes it got foreign-lane work at foreign-lane cost; the meter that actually moves is the
one nobody is watching. During a long outage the entire workload silently migrates onto the
subscription the whole arrangement exists to conserve, and the first symptom is a rate limit
somewhere unrelated.

This is not hypothetical. While writing this spec we found four agents typed for the foreign lane
that were in fact running a first-party model — the `model` parameter at spawn overrides the agent
definition — quietly consuming that quota and producing every one of the session's first-party rate
limits. A router-level silent fallback would make that behaviour the design instead of a bug.

Degrading at the caller costs one extra round trip and makes the substitution a visible, logged
decision. That trade is correct.

**Teach the orchestrator to notice the red statusline and reroute.** Rejected: it depends on the
orchestrator noticing. The repo has a recorded finding that availability is not adoption — a
capability nothing forces you to use gets skipped. A structured receipt the caller must handle is
mechanism; a status colour is a hope.

**Publish the private surface under its own name.** Not taken here. A publish-time lint fails
closed on the instance-private tokens, backed by an operator decision recorded twice, most
recently the day before this change, on the grounds that this is an unofficial proxy path rather
than an official integration. Generalising satisfies the publish request while keeping that guard
intact — and a public template coupled to one reverse-engineered proxy would be worse engineering
regardless. Reversible in one line if the operator intended otherwise.

## Consequences

- The published agent always works. Without a lane it is a first-party agent; with one it
  delegates. No inert artifacts.
- Degrades are visible and logged. A long outage shows up as a stream of explicit degrade notes,
  not as a mystery bill.
- `merged`-ness and lane availability are now independent concerns; nothing in the degrade path
  depends on the statusline being read by a human.
- The instance keeps a private binding. The public contract has no way to name it, which is
  intentional and enforced by the lint rather than by discipline.
- Cost: one extra probe per delegated unit, and callers must handle a receipt they could
  previously ignore.
