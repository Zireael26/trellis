# model-prompting-deltas — shape the prompt to the model

Per-model prompt-format guidance for Trellis's multi-harness setup. Trellis
already routes work across two harnesses — `.claude/` for Claude Code and
`.codex/` for Codex/GPT (see `core-rules/inheritance.md`) — but the *prompting
itself* has stayed one-size-fits-all. This doc captures the format each model
responds to best, so the Claude harness gets XML-shaped prompts and the
Codex/GPT harness gets JSON-schema-shaped ones. Folded in from the ai-dev-trends
weekly digest (2026-07-07).

## Per-model deltas

| Model | Prompt format | Notes |
|---|---|---|
| **Claude (Opus 4.7+)** | XML-tagged instructions | wrap instructions and inputs in tags (`<task>`, `<context>`, `<example>`) — the strongest steering lever on the `.claude/` path |
| **GPT-5.5 / Codex** | concise JSON schemas | prefer a tight schema over prose; matches the `.codex/` executor path |
| **Gemini 3** | high-level "think bigger" prompts | set temperature = 1.0; fewer micro-instructions — state the goal, not the steps |

## General (any model)

- Use **high ("xhigh") reasoning effort** when quality matters more than latency;
  drop to a cheaper tier for mechanical work.
- **Always pair the model with verification tools** — file reads, test runs — so a
  claim is observed, not asserted (the same verification discipline
  `core-rules/references/loops.md` already carries).

## Refresh trigger

Refresh this doc whenever the ai-dev-trends weekly digest reports a **new model**
(or a format shift for an existing one) — the model-specific analog to the
semi-annual re-verify cadence the frontend references carry. These deltas age
fast; treat an un-refreshed row as a hypothesis, not a fact.
