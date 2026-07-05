# ADR: Automation-first Component-D tier + agent-skills fold-in (RC.5)

**Date:** 2026-07-05
**Status:** Accepted
**Supersedes / relates to:** builds on `2026-07-05-dual-harness-orchestration.md` (the Codex executor node + wrapped tracked path this tier uses).

## Context

Three pressures converged: (1) the RC.4 release proved the public-mirror sync has blind spots (stale AntiGravity survived in unsynced public-only docs); (2) `addyosmani/agent-skills` offered opinionated SDLC primitives worth evaluating for fold-in; (3) the user asked for the dev process to run **more automatically without being asked**, on both the Trellis and project ends. The `last30days` trend signal was clear and two-directional: "review is the new bottleneck" (pushes toward more automation + cross-model verification) but also strong unease about **unbounded agent loops** (pushes toward restraint, bounded autonomy, and human-in-the-loop on anything irreversible).

## Decision

1. **Fold in process *primitives*, keep domain knowledge reference-only.** Trellis stays a lean process-spine. `doubt-driven-development`, `source-driven-development`, `versioning`, and `deprecation-and-migration` ship as `core-rules/references/` primitives; observability/frontend/perf/etc. remain opt-in `docs/references/` checklists, never always-on core skills.

2. **Automation-first, but every write-capable automation is a HOLD PR a human merges, and every new autonomy is a knob/flag defaulting to today's behavior.** The safe tier (audit-digest at SessionStart, execute→Codex) is advisory or attended. The **Component-D** tier (drift fan-out, conductor auto-execute, rule-of-three promotion) ships **default-OFF** — a fresh install behaves exactly as before. The **merge bright-line is absolute at every setting**: no knob, at any value, merges a PR or writes a project's / core-rules' `main`.

3. **The wrapped tracked path is the prescribed Codex dispatch.** There is no wrapper-free way to run Codex as a native agent (Claude Code spawns Claude models only; the plugin ships no MCP server). Rather than treat the Sonnet forwarder as overhead to avoid, we prescribe it: `agent(prompt, { agentType: 'codex:codex-rescue' })` inside a Workflow makes a Codex unit a first-class, harness-tracked node. In-workflow Codex is **forced synchronous** (a backgrounded unit returns a job handle that would silently drop from a fan-out).

## Consequences

- **Positive:** proactive surfacing of findings (push, not pull); cheaper day-to-day builds via the executor; cross-model verification wired (`verify-panel`); the public push is now safe-by-construction (fail-closed mirror lint); the sync no longer silently retains retired content.
- **Cost / risk:** the Component-D knobs add real capability that, if turned on carelessly, opens unattended PRs. Mitigated by default-off, per-recipe loop-safety ceilings, the absolute merge bright-line, and cross-model review of the tier before it landed.
- **Deferred (rc.5.1):** two advisory nudge hooks (C3/C6) and the L5 auto-append (C4, which needs a shared autonomy-resolution lib extracted first) — documented in `specs/005-.../tasks.md`, not dropped.
- **Invariants preserved:** no in-file model conditionals (`CLAUDE.md`/`AGENTS.md` byte-identical), the public-vs-instance distribution model, and loop-safety.
