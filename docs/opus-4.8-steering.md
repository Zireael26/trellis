# Opus 4.8 prompting — steering reference

Source: Anthropic, *Prompting best practices* — <https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices> (Opus 4.8 release).

Opus 4.8 is the Trellis daily driver. This doc captures the **deltas** between that guidance and how Trellis already steers agents, plus a library of reusable prompt snippets projects can drop into their own `CLAUDE.md`. Read it on demand — the load-bearing rules already live in `core-rules/CLAUDE.md`, `core-rules/autonomy.md`, and the hooks; this is the why and the spare parts.

The headline finding: the doc largely **validates** Trellis. Most of its system-prompt patterns are things Trellis already does as infra (hooks, the autonomy slider, the context-log/primer system). The genuinely new levers are effort configuration and a handful of behaviors that flipped direction between Opus 4.6 and 4.8.

---

## 1. Effort and thinking — the highest-value lever

The doc is emphatic: effort is "likely to be more important for this model than for any prior Opus." It is the single biggest 4.8 knob.

- **Trellis default is now `xhigh`.** `core-rules/templates/claude-settings.json` sets `"effortLevel": "xhigh"`. Claude Code's own default for Opus 4.8 is `high`; the doc recommends `xhigh` for coding and agentic work and a minimum of `high` for anything intelligence-sensitive. `xhigh` degrades gracefully — on a model that doesn't support it (e.g. Sonnet 4.6, Opus 4.6) Claude Code falls back to `high`, so the template is safe fleet-wide.
- **Accepted in `settings.json`:** `low`, `medium`, `high`, `xhigh`. `max` and `ultracode` are session-only and rejected in settings — set them per-session via `/effort` if a task warrants it. `max` can over-think; test before adopting.
- **Override paths** (highest precedence first): `CLAUDE_CODE_EFFORT_LEVEL` env var → `/effort <level>` / `--effort` flag → `effortLevel` setting → model default. A skill or subagent can pin its own effort via `effort:` frontmatter.
- **Don't run hard work at `low`/`medium` and prompt around under-thinking.** The doc's first lever for shallow reasoning is to *raise effort*, not to add "think carefully" text. 4.8 respects low effort strictly and scopes work to what was asked.
- **Thinking stays adaptive; we do not force it on.** On 4.8 thinking is adaptive at the effort level. Trellis deliberately does **not** set `alwaysThinkingEnabled: true` in the template — the doc warns that large or complex system prompts (Trellis injects a lot: parent rules + skills + hooks + primers) can over-trigger thinking. If you want to steer thinking frequency, the docs confirm the model responds to guidance placed directly in `CLAUDE.md` within its effort setting. To *reduce* thinking:

  ```text
  Thinking adds latency and should only be used when it will meaningfully improve answer quality — typically for problems that require multi-step reasoning. When in doubt, respond directly.
  ```

- **Give `xhigh`/`max` room.** At high effort, set a large max output budget so the model can think and act across tool calls and subagents (the doc suggests starting at 64k and tuning).

## 2. Verbosity and tone

4.8 calibrates response length to task complexity — short on lookups, long on open-ended analysis — and trends direct/opinionated with little validation-forward phrasing. Trellis's `CLAUDE.md` "Communication" rules ("Terse responses. No trailing prose summaries") already pull in this direction, so no change is needed. Two spare parts for projects whose product voice differs:

- Decrease verbosity: `Provide concise, focused responses. Skip non-essential context, and keep examples minimal.`
- Warmer voice: `Use a warm, collaborative tone. Acknowledge the user's framing before answering.`
- Suppress excessive markdown / bullet-spam (prose-heavy products):

  ```text
  <avoid_excessive_markdown_and_bullet_points>
  When writing reports, documents, technical explanations, analyses, or any long-form content, write in clear, flowing prose using complete paragraphs and sentences. Use standard paragraph breaks for organization and reserve markdown primarily for `inline code`, code blocks, and simple headings. Avoid using **bold** and *italics*.

  DO NOT use ordered or unordered lists unless: a) you're presenting truly discrete items where a list is the best option, or b) the user explicitly requests a list or ranking.

  Instead of listing items with bullets or numbers, incorporate them naturally into sentences. NEVER output a series of overly short bullet points.
  </avoid_excessive_markdown_and_bullet_points>
  ```

  (Note: this conflicts with Trellis's terse-bullet house style — adopt only in projects that produce long-form prose for end users, not in engineering rules.)

## 3. Subagent and tool dispatch — direction flipped at 4.8

This is the behavior change most likely to bite a prompt tuned for an older model. Opus 4.6 **over**-spawned subagents; Opus 4.8 **under**-spawns and favors reasoning over tool calls. Trellis's `CLAUDE.md` "Context management" rule gives explicit dispatch triggers (≥2 independent searches/fetches/analyses, >5 files, edit-heavy turns) — those triggers now *counteract* the model's default rather than reining it in. Honor them even when handling work inline feels easier. Raising effort to `high`/`xhigh` also increases tool usage, which is the doc's recommended lever when the model under-uses search/coding tools.

Parallel tool calls — the doc's snippet, for projects that want to push batching to ~100%:

```text
<use_parallel_tool_calls>
If you intend to call multiple tools and there are no dependencies between the tool calls, make all of the independent tool calls in parallel. Prioritize calling tools simultaneously whenever the actions can be done in parallel rather than sequentially. For example, when reading 3 files, run 3 tool calls in parallel. However, if some tool calls depend on previous calls to inform dependent values, do NOT call them in parallel — call them sequentially. Never use placeholders or guess missing parameters in tool calls.
</use_parallel_tool_calls>
```

To control subagent spawning explicitly when a project needs it:

```text
Do not spawn a subagent for work you can complete directly in a single response (e.g. refactoring a function you can already see).
Spawn multiple subagents in the same turn when fanning out across items or reading multiple files.
```

## 4. Literal instruction following — an authoring rule for Trellis itself

4.8 interprets prompts literally and explicitly, especially at lower effort. It does **not** silently generalize an instruction from one item to another, and it does not infer requests you didn't make. This is precision, not a flaw — but it changes how Trellis rules and project `CLAUDE.md` files should be written:

- **State scope explicitly.** "Apply this formatting to every section, not just the first" beats assuming the model will generalize.
- **Prefer positive examples over negatives.** Showing the desired behavior beats a list of "don't"s; the doc notes positive examples of appropriate concision outperform "never do X" instructions.
- **Dial back `CRITICAL:` / `MUST` except for true bright-lines.** 4.5/4.6+ are more responsive to the system prompt and over-trigger on aggressive language; "Use this tool when…" beats "CRITICAL: You MUST use this tool when…". Trellis keeps a deliberate few `MUST`s (the primer "you MUST read", the context-log surfacing rule) because they are genuine bright-lines — leave those, but don't add new ones reflexively.

## 5. Action posture — already a slider, not a snippet

The doc ships two opposing system-prompt snippets for how eagerly the model acts: `<default_to_action>` (infer intent, implement, use tools to discover missing details) and `<do_not_act_before_instructions>` (research and recommend, act only when explicitly asked). Trellis's autonomy slider (`core-rules/autonomy.md`) **is** that spectrum expressed as a level: L1–L2 ≈ conservative, L4–L5 ≈ default-to-action, L3 splits on the plan-approval gate. Prefer setting the level over pasting either snippet. The doc's "balancing autonomy and safety" advice (confirm before destructive / hard-to-reverse / externally-visible actions; never `--no-verify` as a shortcut) is the bright-line guardrail set, enforced by hooks at every level.

## 6. Quality guards — snippets mapped to Trellis surfaces

Each of these is a behavior Trellis already enforces somewhere; the snippet is the portable version for a project `CLAUDE.md`.

**Overengineering / overeagerness** — Trellis surface: `CLAUDE.md` "Code quality" (surgical scope, no single-use abstractions, no imaginary scenarios, no speculative defensive code).

```text
Avoid over-engineering. Only make changes that are directly requested or clearly necessary. Keep solutions simple and focused:
- Scope: Don't add features, refactor code, or make "improvements" beyond what was asked.
- Documentation: Don't add docstrings, comments, or type annotations to code you didn't change. Only comment where logic isn't self-evident.
- Defensive coding: Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees. Only validate at system boundaries.
- Abstractions: Don't create helpers or abstractions for one-time operations. The right amount of complexity is the minimum needed for the current task.
```

**Investigate before answering (anti-hallucination)** — Trellis surface: `CLAUDE.md` "Debugging" + "Edit safety".

```text
<investigate_before_answering>
Never speculate about code you have not opened. If the user references a specific file, you MUST read the file before answering. Investigate and read relevant files BEFORE answering questions about the codebase. Never make claims about code before investigating unless you are certain — give grounded, hallucination-free answers.
</investigate_before_answering>
```

**Don't hard-code to the tests** — Trellis surface: `engineering-process.md` §8.6 (testing bar) + `CLAUDE.md` DoD.

```text
Write a high-quality, general-purpose solution. Implement logic that works correctly for all valid inputs, not just the test cases. Do not hard-code values or create solutions that only work for specific test inputs. Tests verify correctness; they do not define the solution. If a task is infeasible or a test is wrong, say so rather than working around it.
```

**Code review = coverage, not filtering** — Trellis surface: `core-rules/hooks/code-review-subagent.sh` (the hook is the filter: critical blocks, rest advisory). 4.8 follows "only report high-severity" more faithfully than older models, so a reviewer prompt that says "be conservative" will investigate deeply but report fewer findings. Prompt the reviewer for coverage instead:

```text
Report every issue you find, including ones you are uncertain about or consider low-severity. Do not filter for importance or confidence at this stage — a separate step does that. For each finding, include your confidence level and an estimated severity so a downstream filter can rank them.
```

## 7. Long-horizon and multi-window work

4.8 excels at state tracking across context windows. Trellis already implements the doc's recommendations as infra: the `save-context-log` / `session-context` / `post-compact-context` hooks (state survives compaction and worktrees), the feature-primer system, and git as the checkpoint log. The one snippet worth keeping handy is the "don't stop early" guidance for harnesses that compact — relevant because Trellis projects do compact:

```text
Your context window will be automatically compacted as it approaches its limit, allowing you to continue working from where you left off. Do not stop tasks early due to token-budget concerns. As you approach the limit, save your progress and state to memory before the context refreshes. Be as persistent and autonomous as possible and complete tasks fully. Never artificially stop a task early because of remaining context.
```

Pair with structured state files (`tests.json` for pass/fail, freeform `progress.txt` for notes) and "do not remove or edit tests" reminders — the doc's pattern for multi-session iteration.

## 8. Frontend design

Not a Trellis-core concern (no frontend-design skill ships in `core-rules`), but for projects that build UI: 4.8 needs *less* design prompting than older models and has a strong default house style (cream/serif/terracotta) that suits editorial work but reads wrong for dashboards/dev-tools/fintech. Use the short snippet — not the longer pre-4.8 one, which the doc deprecates for 4.8:

```text
<frontend_aesthetics>
NEVER use generic AI-generated aesthetics like overused font families (Inter, Roboto, Arial, system fonts), clichéd color schemes (purple gradients on white/dark), predictable layouts, and cookie-cutter design that lacks context-specific character. Use unique fonts, cohesive colors and themes, and animations for effects and micro-interactions.
</frontend_aesthetics>
```

To break the default house style reliably, have the model propose directions first: *"Before building, propose 4 distinct visual directions (each as bg hex / accent hex / typeface — one-line rationale). Ask the user to pick one, then implement only that."*

## 9. Model self-knowledge

For projects whose product calls an LLM, the doc gives the canonical identity strings:

```text
When an LLM is needed, default to Claude Opus 4.8 unless the user requests otherwise. The exact model string for Claude Opus 4.8 is claude-opus-4-8.
```

---

## Deliberately NOT adopted

- **API-only mechanics.** Prefill-response migration, sampling parameters, the `thinking: {type: "adaptive"}` / `budget_tokens` API config, and `output_config.effort` are Messages-API concerns. Trellis steers Claude Code, where effort is the `effortLevel` setting (§1) and thinking is adaptive automatically — none of these are actionable here.
- **`alwaysThinkingEnabled: true` in the template.** Over-trigger risk given Trellis's large system prompt (§1).
- **The long pre-4.8 `frontend-design` snippet.** Deprecated by the doc for 4.8 (§8).
- **Forced interim progress messages.** The doc says 4.8 already gives good updates and to *remove* "summarize every N tool calls" scaffolding — Trellis never added any, so nothing to remove.
