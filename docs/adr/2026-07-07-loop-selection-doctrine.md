# ADR: Loop-selection doctrine — adopt the Claude "loops" mental model

**Date:** 2026-07-07
**Status:** Accepted
**Relates to:** the agent-loops program — `core-rules/loop-safety.md` (the halting contract) and `core-rules/skills/orchestrate/` (dynamic workflows). Source: Claude team blog *"Getting started with loops"* (2026-07).

## Context

The Claude "loops" blog codifies a clean loop mental model: four loop types (turn-based / goal-based / time-based / proactive), each with a trigger, a stop signal, and a primitive to reach for, plus a few operating practices. Grounding it against Trellis produced a sharp, two-sided result:

- **Trellis already leads the blog on loop *safety*.** `loop-safety.md` is a full halting contract — three ceilings (`max_iterations`, `no_progress_iterations`, `budget_ceiling_usd`), a progress-signal catalog, a structured halt report, token↔dollar conversion — versus the blog's "stop after N tries." Adversarial review (`verify-panel`), the Component-D HOLD-PR + merge bright-line, and the gotchas/`propose-rules`/rule-of-three self-correction loop are all beyond the blog.
- **Trellis had one real gap: loop *selection*.** `loop-safety.md` answers *how any loop halts* but never *which loop to reach for*. No taxonomy/selection doc existed anywhere in `core-rules/` or `docs/` (grep-confirmed). Trellis has every primitive (`/goal`, `/loop`, `scheduled-tasks/`, `orchestrate`) but no map from situation → primitive. Three smaller gaps rode along: no "pilot before a large fan-out" norm, no canonical proactive-loop shape, no "start simplest" restraint counterweight.

## Decision

Graft the blog's **model** onto Trellis's **machinery**, as pure doctrine (no new hook, command, or mechanism):

1. **New `core-rules/references/loops.md`** — the loop-*selection* layer. It maps the four types to Trellis primitives and, for each, **hands off halting to `loop-safety.md`** rather than restating the ceilings. Ships as a `references/` primitive (always-available, not auto-loaded), matching the RC.5 convention.
2. **`orchestrate/SKILL.md`** gains the **pilot-before-large-fan-out** norm and the canonical **proactive-loop five-stage shape** (detect → triage → resolve-in-parallel → adversarial-review → respond), cross-referencing the recipes that already embody stages (conductor, `drift-holdpr`, `verify-panel`).
3. **`loop-safety.md`** gains a cross-link (which-loop → `loops.md`; how-it-halts → itself) and the "start simplest" restraint line.
4. **The blog's operating practices are folded as pointers to machinery Trellis already ships** — verification → `stop-verify`/DoD; adversarial review → `verify-panel`; encode-the-fix → `gotchas.md`/`propose-rules`/rule-of-three; budget → the three ceilings — not re-authored, and with an explicit note of where Trellis exceeds the blog.

## Consequences

- **Positive:** agents get a selection rubric they lacked; the selection layer stays thin because it defers all halting to the existing contract (no duplication, no drift); the "pilot first" and "start simplest" norms are cheap guardrails against the orchestration-heavy default; Trellis is positioned accurately (ahead on safety, not behind).
- **Cost / risk:** low — the diff is Markdown, no behavior change to any hook, recipe, or config. The main risk is doc drift between `loops.md` and `loop-safety.md`; mitigated by making `loops.md` reference-only for halting.
- **Invariants preserved:** the halting contract is unchanged and remains the single source of truth for ceilings; `/loop` / `/goal` / `/schedule` are framed as Claude Code built-ins Trellis composes with, not Trellis-owned commands.
