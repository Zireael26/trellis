# 2026-06-05 — Debrief teach-it-back skill

## Context

Trellis ships a responsibility slider (L1–L5). At L4/L5 the agent answers most
interactive gates itself and makes decisions on the human's behalf. That buys
throughput, but it has a cost the slider does not address: the human steadily
loses the mental model of their own codebase. Work lands that nobody walked
through. Over a long autonomous run the operator becomes a reviewer of diffs
they did not reason about — exactly the position from which subtle wrong calls
slip past.

A member of the Claude Code team published a "wise teacher" `CLAUDE.md` prompt
that turns the agent into a tutor: it teaches the human to *understand* a coding
session — incremental, mastery-gated, restate-first, drilling the whys, with a
quiz and a "don't stop until understood" goal. The shape is a direct
counterweight to the autonomy slider. We want it in Trellis so every managed
project inherits it.

The source prompt is Claude-specific and personal: gendered voice, an
`AskUserQuestion`-driven quiz, a `/goal` CLI stop condition, and informal
phrasing. Trellis skills are **harness-agnostic** (must run on Claude Code and
Codex) and the `core-rules/**` tree publishes to a public mirror, so it must be
free of personal paths, fleet names, and harness-specific assumptions.

Two shape questions had to be answered before porting:

1. **Command, skill, or both?** The teaching flow is explicit — the human asks
   to be taught; the agent must never decide on its own to start lecturing.
   Claude Code resolves a command and a skill of the same name by letting the
   **skill win and shadowing the command**, so a `debrief` command + `debrief`
   skill pair collides and the command is dead. A single skill is the only
   non-colliding shape.

2. **How to suppress auto-fire?** A teaching skill that the model invokes on its
   own initiative is the opposite of the intent. `disable-model-invocation: true`
   makes the skill user-invocable only (`/debrief`) while removing it from the
   model's ambient context — confirmed against the Claude Code skills docs.

## Decision

Ship `debrief` as a **single, explicit-invoke-only skill** under
`core-rules/skills/debrief/` (`SKILL.md` + `references/quiz-and-degrade.md`),
inherited to both harnesses through the existing skill-symlink rail and
published to the public mirror like every other canonical skill.

- **`disable-model-invocation: true`** carries the never-auto-fire intent
  directly. The user runs `/debrief [PR# | path | blank = this session] [--keep]`.
- **Harness-neutral port.** Gendered voice → neutral; the `AskUserQuestion` quiz
  and the show-code debugger are **capability-gated** with a numbered-inline
  degrade so the skill still works where those tools are absent; the `/goal`
  "don't stop until understood" maps to the **verifiable-goal rule** already in
  `core-rules/CLAUDE.md`, with no CLI dependency.
- **Bounded stop condition.** The session ends when every checklist item is
  demonstrated, with a defer/abandon escape hatch mirroring the open-todos rule
  — so a human who must leave is never trapped.
- **Onboarding.** `onboard-project.sh` seeds the symlink on both surfaces. In the
  same pass it fixes a pre-existing seed gap: `execute` and `brainstorming` were
  in the untrack lists but never seeded, so freshly-onboarded projects silently
  missed them.

The skill is the eleventh canonical skill. Distribution is identical across the
private control-plane clone and the public mirror — Trellis does not gatekeep
features between the two.

## Consequences

- Every managed project gains a teaching counterweight to L4/L5 autonomy, on
  explicit demand, with no risk of the agent auto-lecturing.
- The capability-gated quiz/debugger means the skill degrades rather than breaks
  on harnesses without `AskUserQuestion` or a code-display tool.
- The `disable-model-invocation` behaviour (auto-fire off, `/debrief` on) is
  validated by the first real invocation on a managed project — the canonical
  clone does not surface `.claude/skills/` itself.
- Existing projects need a fleet re-onboard to pick up `debrief` (and the
  execute/brainstorming seed-gap fix). Tracked as a rollout follow-on alongside
  the `HC_CANONICAL_SKILLS` roster bump.

## Status

Accepted. Design: `docs/specs/2026-06-05-debrief-skill-design.md`.
