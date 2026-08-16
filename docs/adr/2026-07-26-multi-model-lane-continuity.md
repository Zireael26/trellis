# Multi-model lane continuity: fail closed at the caller; never substitute in the router

Date: 2026-07-26
Status: Accepted — amended to require explicit re-selection after a selected-lane failure.
Spec: `specs/021-multi-model-lane-continuity/`

## Context

A local router splits Claude Code traffic by model name: first-party models pass through to the
official endpoint on subscription auth, while a set of foreign model names is routed to a separate
lane. The lane is a second subscription, with its own limits and its own outages.

The router already **detects** lane failure. It counts consecutive errors, recognises an
auth-cooling upstream, exposes a `degraded` state, and colours the statusline red. What it does
next is return a bare 502/503, and the delegated agent dies. So an outage or a hit rate limit does
not degrade the work — it ends the unit, and the operator reconstructs why from a red statusline.

At acceptance, the agents that targeted the lane pinned the lane's model name in their
frontmatter. On a host without the router that name resolved to nothing, so the agent hard-failed
at dispatch. This is why the pre-amendment surface was not publishable: the artifacts only worked
where the infrastructure already existed.

At acceptance, the repo had solved this shape once before for a different foreign backend
(`core-rules/agents/codex-worker.md`, later retired by commit `2ad1808`): pin a
**first-party** model, reach the foreign backend over `Bash`, and return a structured
UNAVAILABLE receipt that then led the caller to repeat the identical unit locally. That
worker and automatic-repeat pattern is historical evidence only, not a current route.

## Decision

**Fail closed at the caller. Never substitute in the router or caller.**

1. At acceptance, agents explicitly selected to target the lane pinned a first-party model in
   frontmatter and reached the lane through `Bash`. The lane was an enhancement, not a
   prerequisite, and a failed foreign lane never selected the first-party route automatically.
   That Trellis-owned agent implementation is retired; current lane selection follows
   `core-rules/references/model-lanes.md`.
2. The retired `scripts/lane-preflight.sh` reported availability and nothing else: unknown,
   error, and timeout resolved to unavailable. A current lane may use an operator-supplied
   fail-closed probe under the same `model-lanes.md` contract; Trellis ships no such probe.
3. At acceptance, an unavailable agent returned `STATUS: UNAVAILABLE`,
   `CODE: LANE_UNAVAILABLE`, a reason, endpoint-configuration and probe-time fields, the target
   working directory, and an instruction to rerun the identical unit on the first-party route.
   That receipt shape and automatic-repeat instruction are historical. Current policy retains
   only the invariant that a selected failure ends the attempt; another provider or lane may run
   only after explicit caller/operator selection.
4. The router's change is confined to what it *emits*: a structured 503 with a machine-readable
   reason, so callers can tell "lane is down" from "your request was malformed."
5. The public template carries the capability contract — lanes, the predicate, and failure/
   continuity tiers — and never names the specific third-party proxy this instance happens to use.

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

The original caller-side repeat made a provider change visible and logged. That automatic-repeat
clause is historical only: current policy requires explicit caller/operator re-selection first.

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

- No Trellis-owned public agent or probe remains. An explicitly selected first-party route may
  continue; a selected foreign lane fails closed with a visible receipt and requires explicit
  reselection before another provider or lane runs.
- Failures are visible and logged. An explicit new selection, not the failure receipt itself,
  permits a rerun, so an outage cannot become a mystery bill.
- `merged`-ness and lane availability are independent concerns; nothing in the failure path
  depends on the statusline being read by a human.
- The instance keeps a private binding. The public contract has no way to name it, which is
  intentional and enforced by the lint rather than by discipline.
- Historical cost was one probe per delegated unit plus receipt handling. Current
  operator-supplied lane integrations bear their own probe cost.
