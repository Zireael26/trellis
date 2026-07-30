# model-prompting-deltas — shape the prompt to the model

Per-model prompt guidance for Trellis's two-harness setup: `.claude/` for Claude
Code and `.codex/` for the Codex/GPT executor (see `core-rules/inheritance.md`).

This file is the **only** place model-divergent guidance lives. The constitution
(`core-rules/CLAUDE.md`), the skills, and the hooks stay model-neutral by
doctrine — so when a fact is true of one model and false of another, it lands
here, phrased as a rule an agent can apply *without knowing which model it is*.

Sourced from Anthropic's Claude-5-generation prompting docs, distilled in
`docs/research/2026-07-25-claude-5-prompting-corpus.md`. Rows without a primary
source say so.

## Per-model deltas

| Model | Prompt shape | Effort | Behavioral delta that changes how you write instructions |
|---|---|---|---|
| **Claude Opus 5** | Principles, not rules. Clear headings beat XML for an ordinary prompt. Ask for the substance and the scope; do not enumerate prohibitions. | `low`/`medium` give strong quality at a fraction of the tokens and beat the same tiers on prior Opus — use them as the primary cost/latency control. **`xhigh` remains the starting point for coding and agentic work.** Re-sweep if a setting was carried over from a prior model. | Verifies its own work unprompted — delete verification instructions (see § Verification below). Delegates to subagents **more** readily than Opus 4.8, so damp rather than encourage. Responses and written deliverables run long by default — ask for concision explicitly, and repeat the ask near the end of a long system prompt. Expands scope if unconstrained. Narrates corrections readily. On review: never write "only high-severity issues" or "be conservative" — it obeys literally and under-reports. Ask for everything, filter in a second pass. |
| **Claude Fable 5 / Mythos 5** | Brief instructions beat enumerations — one short instruction steers a whole behavior class. Give the *reason*, not only the request. | **`high` is the default for most tasks**; `xhigh` only for the most capability-sensitive; `medium`/`low` for routine. Lower Fable tiers often exceed `xhigh` on prior models. At higher effort it over-gathers and over-tidies — pair with the surgical-scope block. | Single turns run for minutes and autonomous runs for hours: check in **asynchronously** via a scheduled job, never by blocking. Dispatches parallel subagents readily and sustains them dependably; long-lived subagents that keep context across subtasks are the cheap shape. Ground every progress claim against a tool result from the same session. When the user is thinking out loud, the deliverable is the assessment — report and stop. **Never instruct it to echo, transcribe, or explain its internal reasoning as response text** — that trips the `reasoning_extraction` refusal class and falls back to Opus 4.8. Adaptive thinking is the only mode. |
| **Claude Sonnet 5** | *No primary source.* Apply § Cross-model below. | *Unsourced — do not carry an Opus or Fable ladder across without a sweep.* | Live in Trellis today: `core-rules/agents/codex-worker.md` frontmatter pins `model: sonnet`. The generation-wide structural facts hold (`budget_tokens` returns 400; adaptive thinking is the recommended mode); every behavioral delta is a **hypothesis** until the refresh trigger closes it. |
| **Claude Haiku 4.5** | *No primary source.* Apply § Cross-model below. | *Unsourced.* | Pre-Claude-5 **and pre-4.6**, so the 4.7+ structural facts do **not** carry: it takes `budget_tokens`, not `effort`, and has no adaptive-thinking mode. Behavioral deltas unverified. Reach for it where the task is mechanical and a wrong answer is cheap to catch. |
| **Codex / GPT executor** (`.codex/` path; operator pin `gpt-5.6-sol`) | Concise, schema-shaped work orders: frozen scope, explicit constraints, the proof obligation, the expected output shape. Prose framing buys nothing here. | The ladder is **operator-set, not model-set** — `docs/codex-routing.md` §3 is authoritative. Use `medium` for mechanical or frozen-scope work with a strong oracle, `high` for moderately complex cross-file work with useful diagnostics, and `xhigh` for weak-oracle, security-sensitive, or consequential work. `max` and `ultra` remain justification-gated attended exceptions. Effort is declared per unit at dispatch; an omitted effort is a validation error, never a default. | A runtime-detected capability, never a hard dependency — every unit must degrade to Claude. Unattended by construction: prepend the no-collaboration-tool preamble (`core-rules/agents/codex-worker.md`). Which work goes to which model is `docs/codex-routing.md` §2; this file covers only prompt shape. |

Gemini 3 had a row here and no longer does. Trellis routes work across exactly
two harnesses, and a row for a model no dispatch path can reach was steering
nobody. If a third harness is ever added, the row comes back with a source.

**Where effort posture actually lives.** The Effort column above is a summary for
readers already in this table. `docs/claude-steering.md` §1 is canonical: it
carries the settings-accepted levels, the override precedence, the degrade
behavior, and the sweep method. When the two disagree, the steering doc wins and
this column is the thing that drifted. For the Codex path the same relationship
holds with `docs/codex-routing.md` §3, which is operator-set rather than
model-set.

## Verification — the run-length rule

Two pieces of official guidance look contradictory:

- Opus 5: *"remove explicit verification instructions … do not use subagents to
  verify or double-check your own work."*
- Fable 5: *"separate, fresh-context verifier subagents tend to outperform
  self-critique"* on long-running tasks.

They are not in conflict. The axis is **run length and context freshness**, not
model preference. Apply it without knowing which model you are:

1. **Short run, one context window.** The work you would be checking is still in
   your context; re-reading it adds no information. **Write no verification
   instruction, and spawn no verifier subagent.** Self-verification already
   happens — instructing it causes over-firing and wasted tokens with no quality
   gain.
2. **Long run — hours, many tool calls, or more than one context window.** The
   work has accumulated past what you can hold accurately, and the thing to check
   against is a written spec, not your memory. **Verify at a declared interval
   with a fresh-context subagent, against the spec.** State the interval in the
   prompt ("every N units, verify against the spec with a subagent"). The fresh
   context *is* the mechanism; a self-critique pass here only re-reads its own
   conclusions.
3. **Either way, deterministic gates are exempt.** A hook that checks a receipt
   marker, `stop-verify`, `process-gate`, the pre-push spec gate — none of these
   is an instruction a model can over-fire on. The guidance above is about
   prompt-level nagging. Do not delete enforcement machinery in its name.

The dividing question, in one line: *am I checking work that is still in my
context, or work that has left it?*

## Cross-model — true of every current Claude model

- **XML tags are less necessary than they were.** For an ordinary prompt, clear
  headings and explicit language are the modern alternative. Tags remain the
  disambiguator when one prompt genuinely mixes instructions, context, examples,
  and variable inputs — reach for them there, not by default.
- **The over-trigger inversion.** Prompts tuned against *under*-triggering now
  *over*-trigger. Dial "CRITICAL: you MUST" down to "Use this when…". Replace
  "default to X" with "use X when it would enhance your understanding". Delete
  "if in doubt, use X" outright. Effort is the fallback lever, not emphasis.
- **`budget_tokens` returns 400 on Claude 4.7+.** Adaptive thinking is the only
  mode on Fable 5 / Mythos 5 and the recommended mode everywhere else. Any
  thinking-budget number left in a config or a prompt is dead weight at best.
- **Minimum necessary structure.** The best prompt is the one that achieves the
  goal reliably with the least scaffolding. Over-engineering is a named pitfall,
  and this file is not exempt from it.
- **Say what to do, not what not to do** — and explain *why* a constraint exists.
  The model generalizes from the reason, not from the prohibition.
- **Long context (20k+):** longform data at the top, the query at the end.

## Refresh trigger

Refresh this doc whenever the ai-dev-trends weekly digest reports a **new model**
(or a format shift for an existing one) — the model-specific analog to the
semi-annual re-verify cadence the frontend references carry. These deltas age
fast; treat an un-refreshed row as a hypothesis, not a fact.

The Sonnet 5 and Haiku 4.5 rows are explicitly un-sourced today. Closing them is
the first thing the next refresh should do.
