# delegation — orchestration, executor routing, teammate lifecycle

*Whether* to delegate is decided in `core-rules/CLAUDE.md` § Context management:
delegate work that is genuinely independent, parallelizable, and larger than you
would finish in a handful of tool calls — or whose shape fits another model's
verifiable strength better than yours. *Which model* it goes to is decided in
`core-rules/references/model-routing.md`. This file carries the mechanism once
those decisions are made — how multi-stage work is staged, when a bounded unit
routes to an executor node, and how a named teammate is released. Read it when
you are orchestrating a multi-stage workflow, considering an executor node, or
holding a live teammate.

## Orchestrating multi-stage work

- If your harness exposes a tool that spawns and coordinates subagents, prefer
  orchestrating through it: **decompose → fan-out → adversarially verify →
  synthesize**. If it does not, run the same stages yourself — the
  decompose / verify / synthesize discipline holds regardless of harness.
- Keep planning, review, and synthesis on the orchestrator. Those are the stages
  that need the whole picture.

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

- When a dispatchable executor node is available, route **execution-heavy bounded
  units** to it — large mechanical edits, long-running background execution —
  while planning, review, and synthesis stay on the orchestrator. When no
  executor node is available, run every unit on the orchestrator itself.
- **This is a capability gate, not a model-identity branch.** Inspect the
  dispatch surfaces the session actually exposes; do not infer them from which
  model owns the main loop.
- Explicit provider or model selections remain authoritative. If the selected
  lane is rejected, unavailable, or fails, surface that lane result and fail the
  unit closed; never rewrite the request or silently substitute the optional
  legacy OpenAI Codex plugin companion.
- `codex-worker` is legacy compatibility only. Use its blocking direct-result
  contract, never the fire-and-forget rescue path, only when the operator has
  explicitly selected and configured that plugin-backed route. Generic Codex CLI
  harness support is independent of this optional companion.
- The gate widens beyond orchestration: a bounded **work-order unit** (frozen
  spec, known repro, mechanical change) **routes** to an available executor node
  from any turn. The 009 pilot's advisory-first posture — propose, don't
  auto-route — was retired 2026-07-30 on the pilot's own criteria (11
  delegations, 90.9% without takeover, zero bright-line incidents; see
  `specs/009-interactive-codex-delegation/pilot-ledger.md`). It had come to
  contradict the fit trigger in `core-rules/CLAUDE.md`, which makes a matching
  unit sufficient on its own. Tiny edits, spec-writing-as-the-work, session-tool
  needs, and bright-line ops still stay on the orchestrator.
- Executor output always passes the orchestrator's review gate.

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
