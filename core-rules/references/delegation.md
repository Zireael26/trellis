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

## Routing to an executor node

- When a dispatchable executor node is available, route **execution-heavy bounded
  units** to it — large mechanical edits, long-running background execution —
  while planning, review, and synthesis stay on the orchestrator. When no
  executor node is available, run every unit on the orchestrator itself.
- **This is a capability gate, not a model-identity branch.** Inspect the
  dispatch surfaces the session actually exposes; do not infer them from which
  model owns the main loop.
- When GPTX Agent capability is available **and** `gptx.enabled` is set (spec 028;
  capability means the installer ran, the switch means the doctrine is in force —
  an install may legitimately be switched off), the canonical GPT executor path is a
  native profile: `gpt-mid` for mechanical or strong-oracle work, `gpt-high` for
  moderately complex cross-file work, `gpt-sol` for weak-oracle or consequential
  work, and `gpt-terra` as the throughput lane for large sustained output against a
  pre-existing oracle. Pairing Terra with a stronger advisor is recommended, not
  required — the review gate below is what arbitrates its output.
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
