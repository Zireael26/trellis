# delegation — orchestration, executor routing, teammate lifecycle

Whether to delegate is decided in `core-rules/CLAUDE.md` § Context management:
delegate work that is genuinely independent, parallelizable, and larger than you
would finish in a handful of tool calls. This file is the canonical prose
description of deterministic task-shape routing and carries the mechanism once
that decision is made: how multi-stage work is staged, when a bounded unit routes
to an executor node, and how a named teammate is released. Read it when
orchestrating a multi-stage workflow, selecting a route, considering an executor
node, or holding a live teammate.

## Deterministic task-shape routing

Classify every dispatchable unit before dispatch as exactly one finite shape. Do
not choose from overlapping subjective notions of model fit. The classifier's
preferred primary lanes and effort are:

| task shape | intended primary agent/lane | effort | Sol eligibility |
|---|---|---|---|
| `scan` | Flash | `high` | never |
| `mechanical-coding` | Luna | `max` | never |
| `bounded-review` | Muse (`cheap`) | `xhigh` | never |
| `deep-work` | GLM Flash (`glm-flash-go` first, prepaid `glm-flash` fallback) | `max` | never |
| `hard-work` | Luna / GLM Flash primary; Grok / Sol tail | `max` primary; `xhigh` tail | reserved; Sol only at `xhigh` |
| `security-review` | Grok / Sol primary; GLM Flash fallback | `xhigh` primary; `max` fallback | eligible; Sol only at `xhigh` |
| `merge-review` | Sol / Grok | `xhigh` | eligible; Sol only at `xhigh` |

`bounded-review` is a bounded first-pass review against a known scope or oracle.
It is not a merge or security verdict. `security-review` and `merge-review` are
verdict roles: their selected reviewer family must differ from the producer
family, and their compatible chains may use Sol. Sol is never `max` and is never
a bounded first-pass reviewer. `hard-work` may use a compatible deep/hard chain,
with Sol reserved for eligible `xhigh` work.

Every dispatch requires one finite task shape, including dispatches with an
operator-named agent. The operator agent then wins exactly over automatic
classification and quota selection. Resolve that name exactly or refuse loudly;
an unavailable, unknown, or incompatible named agent is not permission to choose
another agent, provider, model, or the session model. A missing or unknown shape
always refuses with exit 2 rather than guessing.

Automatic quota fallback happens only before dispatch. It may walk the declared
compatible chain while preserving the shape's required capability; for verdict
routes it must exclude candidates in the producer family. Exhaustion is an
unavailable result and fails closed. There is no generic model fallback or
in-dispatch model substitution, and a failed selected lane is not an automatic
rerun.

Use the resolver's concise classification/acceptance command before dispatch:

```text
resolve-roles.py --classify SHAPE [--operator-agent AGENT]
                 [--producer-agent AGENT] [--actual-model MODEL]
                 [--usage-file PATH] [--json]
```

Classification records the requested/chosen agent, task shape, capability,
provider/model, effort, family, producer-family check, quota source/trail, and
fallback status. After the unit runs, accept it only against observed runtime
route metadata: the receipt must expose the selected provider/model, effort,
family, trail, fallback status, and observed-route acceptance. A worker label or
requested name is not runtime evidence; a missing or mismatched observed route
rejects the unit.

## Orchestrating multi-stage work

- If your harness exposes a tool that spawns and coordinates subagents, prefer
  orchestrating through it: **decompose → fan-out → adversarially verify →
  synthesize**. If it does not, run the same stages yourself — the
  decompose / verify / synthesize discipline holds regardless of harness.
- Keep planning and synthesis on the orchestrator. It coordinates review and
  acceptance; classified review units themselves route according to the table and
  return for the orchestrator's gate.

## Which paradigm for parallel work

Prefer **dynamic workflows** when parallelism must not cost correctness: `pipeline()`
fans out without barriers, a declared `schema` forces structured returns validated at
the tool-call layer, adversarial-verify and judge-panel patterns are expressible as
control flow rather than as hope, and resume-from-run makes a failed run cheap to
re-enter. Named-teammate fan-out trades determinism for interactivity and leaves live
processes that must be `TaskStop`-ed. Plain subagents are for one-off errands. Reach
for those two when the work genuinely needs a mailbox or is a single bounded task —
not for parallel breadth.

Know the enforcement asymmetry before you concentrate work in workflows. A `Workflow`
call returns **asynchronously, before its stages finish** — metadata lands in
milliseconds while resolved-model transcripts complete minutes later — so live
post-spawn model verification sees no resolved models and fails open. Post-hoc
review over completed stages is the load-bearing surface, not the live hook.
Untyped stages carry no declared family and so cannot be classified as
mismatches at all; they are counted as inherited. Run the review after a fan-out;
do not read hook silence as a pass.

## What a delegated agent costs, and what actually reduces it

Measured 2026-08-03 on the Claude lane, one session, identical trivial prompts.

A subagent's prompt is dominated by its tool schemas: ~16K tokens for a three-tool
agent against ~95K for one inheriting the full set. Do not decompose that spread
further — the per-agent instruction body varies too and is mixed into it.

**Prefix caching makes trimming that a dead lever.** The second agent of a type reads
~85–95% of its prefix from cache; three agents launched in one message showed the
first writing the prefix and the other two hitting at 95%, so concurrent spawns do not
stampede. A marginal fan-out agent costs ~13% of the first — ten agents cost ~2.2x one
agent, not 10x. **Never restrict an agent's `tools:` frontmatter to save tokens**:
caching already removes most of what that targets, a static allowlist makes an
implementer fail when it needs a tool it was not given, and any such list would still
have to retain `Agent`, since nested advisor consultation runs through it.

**The real driver is agent-type diversity, not tool count.** Two agent types with
*identical* tool sets still share no cache — the per-agent instruction body sits ahead
of the schemas in the prefix — so every distinct type pays the full scaffold once per
session. So **fan out N same-shape units on one agent type**. Routing already selects
on unit shape, so same-shape units should land on one lane anyway; mix lanes when the
units genuinely differ, not for variety. This is a scheduling preference with no
correctness cost: it changes which agent runs a unit, never what that agent can do.

## Routing to an executor node

- When a dispatchable executor node is available, route classified
  `mechanical-coding` and eligible `hard-work` units to it. Planning and
  synthesis stay on the orchestrator; classified review units route according to
  the table and return for its acceptance gate. When no executor node is
  available, run every unit on the orchestrator itself.
- **This is a capability gate, not a model-identity branch.** Inspect the
  dispatch surfaces the session actually exposes; do not infer them from which
  model owns the main loop.
- Explicit provider or model selections remain authoritative once selected.
  Automatic quota fallback is allowed only before dispatch and only along the
  classifier's compatible chain. If the selected lane is rejected, unavailable,
  or fails, surface that lane result and fail the unit closed; never rewrite the
  request or silently substitute another provider.

- The gate widens beyond orchestration: a classified bounded **work-order unit**
  (frozen spec, known repro, mechanical change) routes to an available executor
  node from any turn. Tiny edits, spec-writing-as-the-work, session-tool needs,
  and bright-line ops still stay on the orchestrator.
- Trellis ships no custom executor-agent definitions. Deliberate direct Codex CLI
  dispatch (`codex exec --json ...` from the orchestrator, which holds Bash) is
  the supported executor route; generic Codex CLI harness support is independent
  of any plugin. Inside a Workflow engine (no shell), dispatch a general-purpose
  agent to run the executor mechanics rather than an agent-type alias for a
  removed custom agent.
- Executor output always passes the orchestrator's review gate and observed-route
  acceptance.

## Flat Agent lifecycle

Claude Code exposes one flat named-teammate roster. A named teammate cannot
create another named teammate; nested work uses unnamed direct-result Agent
calls instead.

- The root orchestrator may pass `name` only when intentionally creating a teammate mailbox.
- A named teammate or any nested Agent caller must omit `name` from its Agent calls.
  The unnamed Agent result returns directly to that caller; it is not a mailbox
  identity and needs no `SendMessage` or teardown.
- The identity returned for a named Agent is a teammate mailbox identity, not a
  background-task ID. The root waits for completion messages and uses
  `SendMessage` for follow-up. Never pass a teammate name or `name@session-...`
  identity to `TaskOutput`, and never use `TaskList` to poll it. Use
  `TaskOutput` only with an ID explicitly returned by a background task tool.

A named teammate/agent pane the root spawned is a **held resource**: engine-run
workflow agents auto-terminate, named teammates do not.

- Keeping one warm across related subtasks is cheaper than respawning only while
  another follow-up is imminent this turn.
- Once the root accepts, merges, supersedes, abandons, or otherwise finishes with
  named work, call `TaskStop` by name in the same turn that accepts that work.
  Do not batch teardown for a later cleanup pass and do not originate
  `shutdown_request`; the orchestrator owns `TaskStop`.
- A failed teammate still needs stopping. A successful `TaskStop` releases the
  orchestrator slot but does not prove the operating-system process exited.
- Declaring done with teammates still live leaks panes and memory — see
  `core-rules/CLAUDE.md` § Definition of done.
- The same rule binds **OMP panes**, which are not `TaskStop` teammates: close each
  with `herdr pane close <pane_id>` at the moment its own output is accepted, in
  the same turn, rather than batching teardown at the end of the workstream. On a
  review panel, close the reviewers before starting the judge — the judge reads
  their report files, not their sessions. See
  [`core-rules/references/herdr-foreman.md` § Panel layout and teardown](herdr-foreman.md#panel-layout-and-teardown).
- Treat a lingering pane as a spend leak, not only a housekeeping one: it holds a
  live session whose whole context is re-sent on every wake. Past **272K input
  tokens OpenAI bills 2x input and 1.5x output for the entire request**, not just
  the overage — `gpt-5.6-sol` goes $5/$30 to $10/$45 per 1M. Keep
  `compaction.methodOrder` remote-first (`remote` is provider-native server
  compaction, the mechanism that holds a session under the line) and close panes
  at acceptance so there is no context to re-send.

## Panel layout in a terminal multiplexer

Where agents occupy panes the operator can see, layout is part of the contract:
an unreadable panel is an unreviewable one, and review is the bottleneck these
fan-outs exist to feed.

The rules themselves — 2x2 grid per tab, a separate grid tab past three workers,
visible panes over headless whenever the operator wants to watch, and a finished
tab being a held resource like a pane — are stated once, in
[`core-rules/references/herdr-foreman.md` § Panel layout and teardown](herdr-foreman.md#panel-layout-and-teardown).
Harness-specific commands belong in the harness's own implementation.

## Width needs an oracle; building the oracle is serial

Fan out when units are independent **and each one has an oracle** — something that
decides pass or fail without a human reading the output. When a unit's oracle does not
exist yet, the first unit *is* building the oracle, and that one is serial by nature.
Parallelising ahead of it does not converge; it produces more confident wrong answers
faster.

Measured on the fleet, 2026-08-23. Generated route art took four rounds. Rounds 2 and 3
ran a wide fan-out with plenty of legs and both failed. What fixed it was not more legs —
it was a rasteriser over the recorded call log that caps every 8x8 window at 35% lit:

```
pre-fix  peaks 47-64 / 64 lit
post-fix peaks 19-22 / 64 lit
```

Mutation-checked: restoring the old row count fails with the slug, the phase, the grid
and the window coordinate named. Once that oracle existed the work converged in one
round. The same shape held for an arcade section in the same project: the acceptance gate
was four rendered WAVs and a played browser session, not a bigger panel.

This is the limit on every "widen the fan-out" instruction in this document. Width
converts quota into finished work only where finished is *decidable*. Where it is not,
width converts quota into plausible output nobody can check, which is worse than a
narrow run because it arrives with more agreement behind it.

Practical ordering:

1. Ask what would prove this unit done, mechanically. If the answer is "a person looks
   at it", the first unit builds the check.
2. Prove the oracle by inverting the requirement — it must fail, and name what failed.
   An oracle you cannot make fail is not an oracle.
3. Then fan out, as wide as the work decomposes.

Corollary already stated under delegation routing: a unit whose only oracle is a running
deployment cannot be delegated to a subagent that has no deployment. Route it to whoever
holds the environment, rather than delegating and verifying afterwards.

## A fact in a message decays; a check in a skill does not

When one session learns something another needs — a stale payload, a dead route,
a config that binds at start — the reflex is to send a message. Messages are the
weakest durable form available. They are read once, by one session, at one moment,
and the next session on that project never sees them.

Two sessions independently proved this in a single night. Both had been told, in
writing, that a routing fix reached only the source checkout and not the release
payload every other project resolves through. Both then dispatched fan-outs
without checking which payload they were resolving against. What eventually caught
it was not the message: it was a rule written into the skill hours later, saying
to compare each leg's **resolved** model against the requested one. The rule fired
on a project whose orchestrator already knew the fact and had not used it.

So: when a finding would change how a future session behaves, the deliverable is
not the message. It is the check — a skill rule, a resolver invariant, a `doctor`
row, a test. Send the message too, for the session that needs it now. But treat
the message as the announcement and the check as the fix, never the reverse.

Corollary for routing work: an invariant over **configuration** and a check
against **reality** are different guarantees. A resolver that validates its own
table cannot see a stale payload, a session-bound override, or a retry promotion.
Configuration checks are necessary and never sufficient.
