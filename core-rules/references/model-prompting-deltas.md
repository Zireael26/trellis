# model-prompting-deltas — shape the prompt to the model

Per-model prompt guidance for Trellis's native harnesses: `.claude/` for Claude
Code and `.codex/` for the Codex/GPT executor (see `core-rules/inheritance.md`).

This file is the **only** place model-divergent guidance lives. The constitution
(`core-rules/CLAUDE.md`), the skills, and the hooks stay model-neutral by
doctrine — so when a fact is true of one model and false of another, it lands
here, phrased as a rule an agent can apply *without knowing which model it is*.

Claude rows are sourced from Anthropic's Claude-5-generation prompting docs, distilled in
`docs/research/2026-07-25-claude-5-prompting-corpus.md`. Rows without a primary
source say so. Astra guidance was checked against [OpenAI's model guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra) on 2026-09-05. Model capabilities do not establish a performance ranking for Trellis workloads.

## Per-model deltas

| Model | Prompt shape | Effort | Behavioral delta that changes how you write instructions |
|---|---|---|---|
| **Claude Opus 5** | Principles, not rules. Clear headings beat XML for an ordinary prompt. Ask for the substance and the scope; do not enumerate prohibitions. | `low`/`medium` give strong quality at a fraction of the tokens and beat the same tiers on prior Opus — use them as the primary cost/latency control. **`xhigh` remains the starting point for coding and agentic work.** Re-sweep if a setting was carried over from a prior model. | Verifies its own work unprompted — delete verification instructions (see § Verification below). Delegates to subagents **more** readily than Opus 4.8, so damp rather than encourage. Responses and written deliverables run long by default — ask for concision explicitly, and repeat the ask near the end of a long system prompt. Expands scope if unconstrained. Narrates corrections readily. On review: never write "only high-severity issues" or "be conservative" — it obeys literally and under-reports. Ask for everything, filter in a second pass. |
| **Claude Fable 5 / Mythos 5** | Brief instructions beat enumerations — one short instruction steers a whole behavior class. Give the *reason*, not only the request. | **`high` is the default for most tasks**; `xhigh` only for the most capability-sensitive; `medium`/`low` for routine. Lower Fable tiers often exceed `xhigh` on prior models. At higher effort it over-gathers and over-tidies — pair with the surgical-scope block. | Single turns run for minutes and autonomous runs for hours: check in **asynchronously** via a scheduled job, never by blocking. Dispatches parallel subagents readily and sustains them dependably; long-lived subagents that keep context across subtasks are the cheap shape. Ground every progress claim against a tool result from the same session. When the user is thinking out loud, the deliverable is the assessment — report and stop. **Never instruct it to echo, transcribe, or explain its internal reasoning as response text** — that trips the `reasoning_extraction` refusal class and falls back to Opus 4.8. Adaptive thinking is the only mode. |
| **Claude Sonnet 5** | *No primary source.* Apply § Cross-model below. | *Unsourced — do not carry an Opus or Fable ladder across without a sweep.* | The generation-wide structural facts hold (`budget_tokens` returns 400; adaptive thinking is the recommended mode); every behavioral delta is a **hypothesis** until the refresh trigger closes it. |
| **Claude Haiku 4.5** | *No primary source.* Apply § Cross-model below. | *Unsourced.* | Pre-Claude-5 **and pre-4.6**, so the 4.7+ structural facts do **not** carry: it takes `budget_tokens`, not `effort`, and has no adaptive-thinking mode. Behavioral deltas unverified. Reach for it where the task is mechanical and a wrong answer is cheap to catch. |
| **GPT-6 Astra** | State the objective, boundaries, expected evidence, and output style. Make user-request precedence over skill guidance explicit; resolve routine choices and persist through authorized work. Audit conflicting instructions before adding more. | Preserve effective effort during migration; move `none`/`minimal` to `low`. The API documents `low`, `medium`, `high`, `xhigh`, `max`; Trellis's direct-dispatch house band remains §3 of `docs/codex-routing.md`. Host-specific modes require runtime verification. | Can plan, implement, browse, and orchestrate when its host exposes those tools. Specify when delegation helps; reuse agents with related context. Calibrate tests to the change and stop repeating passing checks without a reason. Give concise prose guidance explicitly. Async tools and mid-turn steering require host support, not a prompt-only switch. |
| **Other Codex / GPT models** | Concise work orders: scope, constraints, proof obligation, expected output. Verify the selected model rather than assuming an operator pin. | The direct-dispatch ladder is operator policy in `docs/codex-routing.md` §3. Preserve workload cost and latency roles; do not replace every worker with the flagship. | A selected lane fails visibly; only explicit re-selection changes it. A direct worker's no-collaboration constraint applies to that worker, not to a user-selected Codex orchestrator. |

This table is model-specific: pi can host actively routed provider models through
workflow/subagent surfaces and therefore does not get a synthetic harness row.
Add a row only when an actively routed model has source-backed steering deltas.

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

For those Claude rows, run length and context freshness reconcile the advice.
Astra's separate guidance is to scope verification to the change and complete
required checks, then stop unless new evidence justifies more. Across models:

1. **Short run, one context window.** The work you would be checking is still in
   your context. Verify directly against the task's acceptance criteria and
   existing checks. Skip a separate verifier unless independence addresses a
   concrete risk; avoid repeated generic requests to double-check.
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
