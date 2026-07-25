# delegation — orchestration, executor routing, teammate lifecycle

*Whether* to delegate is decided in `core-rules/CLAUDE.md` § Context management:
delegate work that is genuinely independent, parallelizable, and larger than you
would finish in a handful of tool calls. This file carries the mechanism once
that decision is made — how multi-stage work is staged, when a bounded unit
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
- **This is a capability gate, not a model choice.** The branch is on whether an
  executor node exists, never on which model is running.
- When the executor is Codex inside a Workflow, dispatch through the blocking
  `codex-worker` agent (returns results, never background handles) — never the
  fire-and-forget rescue path.
- The gate widens beyond orchestration: a bounded **work-order unit** (frozen
  spec, known repro, mechanical change) may route to an available executor node
  from any turn — advisory-first during the 009 pilot (propose, don't
  auto-route). Tiny edits, spec-writing-as-the-work, session-tool needs, and
  bright-line ops stay on the orchestrator.
- Executor output always passes the orchestrator's review gate.

## Teammate lifecycle

A named teammate/agent pane you spawned is a **held resource**: engine-run
workflow agents auto-terminate, named teammates do not.

- Keeping one warm across related subtasks is cheaper than respawning — its
  context is already paid for. Reuse the teammate that already has the context
  for a follow-on subtask rather than spawning a fresh one.
- Once you have no further work for it, release it: send the harness's graceful
  shutdown signal (e.g. a `shutdown_request` message); if it does not
  acknowledge, force-stop it (e.g. `TaskStop` by name).
- Declaring done with teammates still live leaks panes and budget — see
  `core-rules/CLAUDE.md` § Definition of done.
