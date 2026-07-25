# Claude prompting — steering reference

Source: `docs/research/2026-07-25-claude-5-prompting-corpus.md` — the distilled primary-source base (8 official Anthropic sources) for the Claude 5 generation. Cited below as `corpus §`. Superseded generation-specific guidance is recorded in `docs/adr/2026-05-29-opus-4.8-prompting-best-practices.md` (historical; do not edit).

Claude is the Trellis daily driver. This doc captures the **deltas** between the official guidance and how Trellis already steers agents, plus a library of reusable prompt snippets projects can drop into their own `CLAUDE.md`. Read it on demand — the load-bearing rules live in `core-rules/CLAUDE.md`, `core-rules/autonomy.md`, and the hooks; this is the why and the spare parts.

**The honest headline, in two halves.** The *spine* validates: hooks, the autonomy slider, DoD receipts, the loop-safety ceilings, the context-log/primer system, and the code-review filter are all things the guidance recommends and Trellis already implements as infrastructure rather than as prompt text. The *prompt-level nudges* do not: three of the behaviors Trellis tuned for a prior generation have inverted, and correcting them is the substance of this revision. Where a rule and this doc disagree, the corpus wins and the rule gets fixed — not the other way round.

**Relationship to `core-rules/references/model-prompting-deltas.md`.** That file is the terse per-model table — one row per model, always in context, covering every harness (Claude, GPT-5.x/Codex, Gemini). It answers *what is the delta, right now* for an agent mid-task. This doc is the long-form Claude-only companion: the reasoning, the scoping, the sweep method, and the snippet library. **Where they overlap — effort — this doc is canonical**, and the table's job is bounded to a single number (the session default) plus a pointer here. That bound is what keeps them from drifting; see §1.

---

## 1. Effort — the highest-value lever

Effort matters more on this generation than on any prior one, and it is the first thing to reach for when output quality is off.

- **`xhigh` is the starting point for coding and agentic work — not a universal default.** `core-rules/templates/claude-settings.json` pins `"effortLevel": "xhigh"`, which is right for a Claude Code session, since those are overwhelmingly coding and agentic (corpus §2.7). Treat it as where a sweep *begins*, not where it ends.
- **`low` and `medium` are the primary cost and latency control.** On this generation they produce strong quality at a fraction of the tokens, and corpus §2.7 says to use them liberally for everything that is not coding or agentic work. "This task feels hard, therefore `xhigh`" is no longer a safe inference — measure it.
- **On a Fable-hosted session, `high` is the default.** `xhigh` is reserved for the most capability-sensitive work, and lower Fable settings frequently exceed `xhigh` on prior models (corpus §3.2). Do not carry the Opus posture across.
- **Re-run the sweep; do not carry the number over.** Corpus §2.7 is explicit that a default inherited from a prior model generation is the thing to re-measure. The sweep method is below; record its result here so the next generation has a baseline.
- **If reasoning looks shallow, raise effort — don't add "think carefully" text.** That lever is unchanged. Prompting around under-thinking is the second-best fix at best.

**This section is the canonical statement of Claude effort posture.** `core-rules/references/model-prompting-deltas.md` carries a per-model Effort column as a summary for a mid-task agent who should not have to open a second file; where the two disagree on a **Claude** model, this section wins and the column is what drifted. The reasoning behind each number — task-type scoping, why Fable defaults lower than Opus, the sweep result — belongs here rather than in the table.

Two things this section does **not** own. The Codex row's ladder is operator-set, and `docs/codex-routing.md` §3 is authoritative for it. And the unsourced rows (Sonnet 5, Haiku 4.5) are deliberately empty in both files until a primary source exists; do not fill them in from either side.

**How to sweep.** A carried-over effort default is a guess until it is measured, and the sweep is cheap because a session-level `/effort` outranks the configured value — no template edit is needed to run one:

1. **Corpus.** Pick 6–8 already-completed units of real work with known-good outcomes, so quality is judged against an actual diff rather than a rubric.
2. **Arms.** `medium`, `high`, `xhigh` — the levels a settings default can actually take (see the mechanics below). Skip `max` and `ultracode`: neither is accepted in `settings.json`, so neither can answer "what should the pin be".
3. **Measure**, per unit: did the process gate pass first time; did the review subagent surface a critical; turns to DoD; tokens.
4. **Decide.** Keep the higher setting only if it wins on the first two. Record the result and its date here, so the next model generation has a baseline to compare against instead of an inherited number.

*Last sweep: none — the current pin was set for a prior generation and carried over.*

**Harness mechanics.** The Claude Code settings surface, not the prompting corpus — the corpus says nothing about any of this. Verified 2026-07-25 against `code.claude.com/docs/en/model-config`:

- **Accepted in `settings.json`:** `low`, `medium`, `high`, `xhigh`. `max` and `ultracode` are not accepted there. `max` applies to the current session only, except when set through the `CLAUDE_CODE_EFFORT_LEVEL` environment variable; `ultracode` is accepted by neither the setting nor that variable, and is session-only in every form.
- **`ultracode` is not a level above `xhigh`.** It is a Claude Code setting rather than a model effort level: it sends `xhigh` to the model and additionally has Claude orchestrate dynamic workflows for substantive tasks.
- **Override precedence:** the `CLAUDE_CODE_EFFORT_LEVEL` environment variable takes precedence over every other method, then the configured level (`/effort`, `--effort`, the `effortLevel` setting), then the model default. Skill and subagent `effort:` frontmatter applies while that skill or subagent is active, overriding the session level but not the environment variable. A configured `effortLevel` is a starting default rather than enforcement — a session can change it with `/effort` or `--effort`, and the configured value re-asserts as the default in the next session.
- **Unsupported levels degrade downward, not sideways.** If you set a level the active model does not support, Claude Code falls back to the highest supported level at or below it — `xhigh` runs as `high` on Opus 4.6 — so the template pin is safe fleet-wide.
- **The harness default is `high`** on every model that supports effort (Opus 4.7 is the lone exception, defaulting to `xhigh`). The Trellis pin is therefore a deliberate lift above the harness default, not a restatement of it.

**Thinking stays adaptive; we do not force it on.** Trellis deliberately does not set `alwaysThinkingEnabled: true` in the template — a large injected system prompt (parent rules + skills + hooks + primers) can over-trigger thinking. To *reduce* thinking frequency, guidance placed directly in `CLAUDE.md` works within the effort setting:

```text
Thinking adds latency and should only be used when it will meaningfully improve answer quality — typically for problems that require multi-step reasoning. When in doubt, respond directly.
```

## 2. Verbosity, narration, and attendedness

**This is the section that inverted.** Trellis's terse house voice used to be enough on its own. It no longer is, and terseness is no longer uniformly correct.

Three separate things, on two axes:

| What | Position |
|---|---|
| Conversational response length | Runs **longer** by default on this generation, and **effort does not reliably shorten it** — it controls thinking, not visible output. Prompt for concision explicitly (corpus §2.3). |
| Written deliverables (files on disk) | Also run longer. This needs its **own** instruction; the conversational one does not cover it (corpus §2.3). |
| The final message of a long **unattended** run | Must be **readable**, not terse. This is the reader's first look at hours of work (corpus §3.11). |

**The reconciliation is attendedness, not a compromise length** (corpus §8, implication 6). Terse is right between tool calls and on attended turns — that is `core-rules/CLAUDE.md` "Communication" working as designed, and it stays. The hand-back message at the end of an unattended run is a different artifact with a different reader, and compressing it is a false economy.

**Trellis surface:** `core-rules/CLAUDE.md` "Communication" and `core-rules/autonomy.md` § Reporting register (attended turns); the context-log / `save-context-log` hooks and overnight-run reporting (unattended hand-back).

**Concision — for the conversational default:**

```text
Keep responses focused and concise. Skip non-essential context and keep examples minimal. Put most of the response on the main answer; keep disclaimers and caveats brief.
```

In a long system prompt, repeat a short reminder near the end — corpus §2.3 notes the instruction lands better when it is not buried at the top.

**Deliverable length — for files the agent writes:**

```text
Match the length of written deliverables to what the task needs: cover the substance, but do not pad with filler sections, redundant summaries, or boilerplate.
```

**Readability of the hand-back message — for long unattended runs (corpus §3.11):**

```text
Terse shorthand is fine between tool calls. Your final message is different: it is for a reader who did not watch any of it. Drop the working shorthand. Write complete sentences and spell terms out. Do not use arrow chains, hyphen-stacked compounds, or labels you invented earlier — the reader cannot decode them. Open with the outcome: one sentence on what happened or what you found, then the supporting detail. If you have to choose between short and clear, choose clear.
```

**Narration cadence is promptable and scoped by attendedness** (corpus §2.4). On attended turns, add nothing — the model paces itself and "summarize every N tool calls" scaffolding is noise. On unattended runs, the requirement is the readable hand-back above, not a mid-run cadence. (The GPT-5.x harness pins an explicit mid-run progress floor instead — see `docs/gpt-5.x-steering.md §3`. Same axis, different cadence value.)

**Suppress excessive markdown / bullet-spam** — for prose-heavy end-user products only:

```text
<avoid_excessive_markdown_and_bullet_points>
When writing reports, documents, technical explanations, analyses, or any long-form content, write in clear, flowing prose using complete paragraphs and sentences. Use standard paragraph breaks for organization and reserve markdown primarily for `inline code`, code blocks, and simple headings. Avoid using **bold** and *italics*.

DO NOT use ordered or unordered lists unless: a) you're presenting truly discrete items where a list is the best option, or b) the user explicitly requests a list or ranking.

Instead of listing items with bullets or numbers, incorporate them naturally into sentences. NEVER output a series of overly short bullet points.
</avoid_excessive_markdown_and_bullet_points>
```

(Conflicts with Trellis's terse-bullet engineering voice — adopt only in projects that produce long-form prose for end users, not in engineering rules.)

## 3. Delegation and tool dispatch

**This section inverted.** The prior generation *under*-spawned subagents and the rule was to honor Trellis's dispatch triggers even when inlining felt easier. **That is now backwards.** This generation delegates **more readily** (corpus §2.2), so `core-rules/CLAUDE.md` "Context management" — delegate when the work is genuinely independent, parallelizable, and larger than you would finish in a handful of tool calls — functions as a **ceiling**, a description of when delegation is *worth it*, not as a floor to be pushed against.

Every subagent re-establishes context, re-explores, reports back, and is then re-read by the caller. That overhead is real and this generation under-weights it. The restraint snippet below is now primary guidance, not an optional spare part.

**Trellis surface:** `core-rules/CLAUDE.md` "Context management" and `core-rules/references/delegation.md`; the loop-safety ceilings (`core-rules/loop-safety.md`) are the deterministic backstop and are unaffected.

```text
Do not spawn a subagent for work you can complete directly in a single response (e.g. refactoring a function you can already see, a handful of file reads, a simple search). Delegate when work is genuinely independent and sizeable — a wide multi-file investigation, unrelated tracks that can run concurrently. When you do delegate, brief the subagent precisely the first time and commit to the result: do not re-derive its findings. Spawn multiple subagents in the same turn only for genuinely independent tracks, and keep spawn counts low.
```

**Parallel tool calls stay exactly as they were** — corpus §4 keeps this block:

```text
<use_parallel_tool_calls>
If you intend to call multiple tools and there are no dependencies between the tool calls, make all of the independent tool calls in parallel. Prioritize calling tools simultaneously whenever the actions can be done in parallel rather than sequentially. For example, when reading 3 files, run 3 tool calls in parallel. However, if some tool calls depend on previous calls to inform dependent values, do NOT call them in parallel — call them sequentially. Never use placeholders or guess missing parameters in tool calls.
</use_parallel_tool_calls>
```

Note the interaction with §6's anti-verification guidance: "do not use a subagent to double-check your work" and "delete your verification scaffolding" are the same fix seen from two angles — except on long unattended runs, where §7's run-length axis applies.

**The code-review gate is not discretionary delegation.** `code-review-subagent` is threshold-triggered infrastructure reviewing an artifact — the diff. Damping exploratory dispatch never touches it.

## 4. Literal instruction following — an authoring rule for Trellis itself

Claude interprets prompts literally and explicitly, especially at lower effort. It does not silently generalize an instruction from one item to another, and it does not infer requests you didn't make. This is precision, not a flaw — but it changes how Trellis rules and project `CLAUDE.md` files should be written.

- **State scope explicitly.** "Apply this formatting to every section, not just the first" beats assuming the model will generalize.
- **Prefer positive examples over negatives.** Showing the desired behavior beats a list of "don't"s; positive examples of appropriate concision outperform "never do X".
- **Dial back `CRITICAL:` / `MUST` except for true bright-lines.** This generation is more responsive to the system prompt and over-triggers on aggressive language. "Use this tool when…" beats "CRITICAL: You MUST use this tool when…". Trellis keeps a deliberate few `MUST`s (the primer "you MUST read", the context-log surfacing rule) because they are genuine bright-lines — leave those, don't add new ones reflexively.
- **This applies to tool *descriptions*, not just the system prompt** (corpus §4). Tool-use prompts written to overcome an older model's reluctance now over-trigger. A description that states *when* to call the tool outperforms one that shouts.
- **Minimum necessary structure.** XML tags are less necessary than they used to be (corpus §4). Keep them where they delimit a genuinely separable block; don't wrap every paragraph.

## 5. Action posture and autonomous operation

The guidance ships two opposing system-prompt snippets for how eagerly the model acts: `<default_to_action>` (infer intent, implement, use tools to discover missing details) and `<do_not_act_before_instructions>` (research and recommend, act only when asked). Trellis's autonomy slider (`core-rules/autonomy.md`) **is** that spectrum expressed as a level: L1–L2 ≈ conservative, L4–L5 ≈ default-to-action, L3 splits on the plan-approval gate. Prefer setting the level over pasting either snippet. The bright-line guardrails — confirm before destructive / hard-to-reverse / externally-visible actions, never `--no-verify` as a shortcut — are enforced by hooks at every level and are unchanged.

**What the slider did not cover: how an autonomous run *ends*.** A long unattended run can stop on a promise ("I'll now run the tests") instead of a tool call, or ask a permission it does not need. Corpus §3.8 gives the counter, and it belongs alongside L4–L5.

**Trellis surface:** `core-rules/autonomy.md` § Unattended runs (L4/L5, cron, background); the loop-safety ceilings; the `stop-verify` hook is the deterministic backstop.

```text
You are operating autonomously. The user is not watching in real time and cannot answer questions mid-task, so asking "Want me to…?" will block the work. For reversible actions that follow from the original request, proceed without asking. Before ending your turn, check your last paragraph. If it is a plan, an analysis, a question, a list of next steps, or a promise about work you have not done ("I'll…", "let me know when…"), do that work now with tool calls. End your turn only when the task is complete or you are blocked on input only the user can provide.
```

## 6. Quality guards — the snippet library

Each snippet below is a behavior Trellis already enforces somewhere; the snippet is the portable version for a project `CLAUDE.md`. **The Trellis surface is the authority — the snippet is for projects that don't have the infrastructure.** Where a hook enforces the behavior deterministically, do not also nag for it in prose.

**Overengineering and over-tidying** — Trellis surface: `core-rules/CLAUDE.md` "Code quality" (surgical scope, no single-use abstractions, no speculative defensive code). Newly load-bearing on two models: at higher effort this generation gathers more context and tidies more than asked (corpus §3.2).

```text
Avoid over-engineering. Only make changes that are directly requested or clearly necessary. Keep solutions simple and focused:
- Scope: Don't add features, refactor code, or make "improvements" beyond what was asked. A bug fix doesn't need surrounding cleanup.
- Documentation: Don't add docstrings, comments, or type annotations to code you didn't change. Only comment where logic isn't self-evident.
- Defensive coding: Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees. Only validate at system boundaries.
- Abstractions: Don't create helpers or abstractions for one-time operations. Avoid premature abstraction and don't design for hypothetical future requirements. The right amount of complexity is the minimum needed for the current task.
```

**Scope containment** (corpus §2.5) — *new*. Distinct from overengineering: that one is about *elaboration*, this one is about the task quietly becoming a different task. Trellis surface: `core-rules/CLAUDE.md` "Code quality"; the `/surgical` escape hatch.

```text
Deliver what was asked, at the scope intended. Interpret ambiguity the way a careful colleague would: make routine judgment calls yourself, and check in only when different readings would lead to materially different work. If you conclude the ask is mistaken or a better approach exists, say so in a sentence and keep going with the task as asked — don't quietly narrow, widen, or transform it. Finish the whole task, not just the easy part of it; only report completion when it is fully done. If you genuinely can't complete something, do the rest and state plainly what is missing and why.
```

**Anti-fabrication** (corpus §3.4) — *replaces* the older `<investigate_before_answering>` block, which mixed useful read-before-claiming guidance with generic verification nagging that now over-fires. This version is evidence-anchored rather than exhortative. Trellis surface: the DoD receipts rule (the deterministic twin — a claim without a receipt fails the gate) and `core-rules/CLAUDE.md` "Debugging" / "Edit safety".

```text
Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for; if something is not yet verified, say so explicitly. Report outcomes faithfully: if tests fail, say so with the output; if a step was skipped, say that; when something is done and verified, state it plainly without hedging. Never speculate about code you have not opened.
```

**Correction narration** (corpus §2.6) — *new*. This generation flags and explains its own earlier mistakes at length, which reads as thrash. Trellis surface: none today; this is a pure gap the snippet fills.

```text
Only correct an earlier statement when the error would change the user's code, conclusions, or decisions. State corrections plainly and concisely and continue the task; combine multiple corrections rather than enumerating them. For slips that change nothing for the user, just make the correction and move on. No apologies, no preambles, no tallying past errors. A follow-up question about earlier work is not by itself a signal that you got something wrong — answer what was asked. This does not apply to thinking.
```

**Don't hard-code to the tests** — Trellis surface: `engineering-process.md` §8.6 (testing bar) + `core-rules/CLAUDE.md` DoD. Unchanged.

```text
Write a high-quality, general-purpose solution. Implement logic that works correctly for all valid inputs, not just the test cases. Do not hard-code values or create solutions that only work for specific test inputs. Tests verify correctness; they do not define the solution. If a task is infeasible or a test is wrong, say so rather than working around it.
```

**Code review = coverage, not filtering** — Trellis surface: `core-rules/hooks/code-review-subagent.sh` (**the hook is the filter**: critical blocks, the rest is advisory). Independently re-confirmed for this generation by corpus §2.8: do **not** write "only report high-severity" or "be conservative" — the model follows it faithfully, investigates just as deeply, and then declines to report. Ask for everything and filter in a separate step. Trellis's finder/filter split is exactly the architecture the guidance recommends.

```text
Report every issue you find, including ones you are uncertain about or consider low-severity. Do not filter for importance or confidence at this stage — a separate step does that. For each finding, include your confidence level and an estimated severity so a downstream filter can rank them.
```

**On removing verification scaffolding** (corpus §2.1). Prompt-level nagging — "double-check your answer", "re-verify before responding", "include a final verification step" — over-fires on this generation and should be **deleted**, not softened. Note this inverts a standard prompting best practice, so a prompt library that applies "ask Claude to self-check" uniformly needs a carve-out here. **This does not apply to deterministic gates.** `post-edit-verify`, `stop-verify`, `spec-gate`, and the DoD receipts rule are mechanisms, not prompts; they stay exactly as they are. The distinction is: if a human can't skip it, it isn't scaffolding.

## 7. Long-horizon and multi-window work

Claude tracks state well across context windows, and Trellis already implements the recommended patterns as infrastructure: the `save-context-log` / `session-context` / `post-compact-context` hooks (state survives compaction and worktrees), the feature-primer system (`core-rules/primers.md`), and git as the checkpoint log.

The snippet worth keeping handy is the don't-stop-early guidance, since Trellis projects compact:

```text
Your context window will be automatically compacted as it approaches its limit, allowing you to continue working from where you left off. Do not stop tasks early due to token-budget concerns. As you approach the limit, save your progress and state to memory before the context refreshes. Be as persistent and autonomous as possible and complete tasks fully. Never artificially stop a task early because of remaining context.
```

Pair with structured state files (`tests.json` for pass/fail, freeform `progress.txt` for notes) and "do not remove or edit tests" reminders.

**Verifier subagents: the axis is run length, not model preference.** §6 says to delete verification scaffolding; the long-horizon guidance says fresh-context verifier subagents beat self-critique. Both are true and they do not conflict (corpus §8, implication 4):

| Run shape | Verification |
|---|---|
| Attended turn, minutes | Delete the scaffolding. Self-verification is already happening; prompting for it over-fires. |
| Long unattended run, hours | A **fresh-context verifier subagent** beats self-critique — the working context is precisely what makes self-critique unreliable at that length. |

For Trellis this means: don't add "verify your work" to `CLAUDE.md`, **do** keep the verifier step in `orchestrate`'s long workflows and overnight loops. Establish a checking method up front and run it on a cadence rather than only at the end.

**Memory surface.** A place to write learnings — even a plain `.md` file — measurably improves long-run behavior. Trellis has this as the context-log and primer system; a project without it should give the agent one and say where it is.

## 8. Frontend design

Not a Trellis-core concern (no frontend-design skill ships in `core-rules`), but for projects that build UI: this generation needs *less* design prompting than older models and has a strong default house style (cream / serif / terracotta) that suits editorial work but reads wrong for dashboards, dev-tools, and fintech. Use the short snippet:

```text
<frontend_aesthetics>
NEVER use generic AI-generated aesthetics like overused font families (Inter, Roboto, Arial, system fonts), clichéd color schemes (purple gradients on white/dark), predictable layouts, and cookie-cutter design that lacks context-specific character. Use unique fonts, cohesive colors and themes, and animations for effects and micro-interactions.
</frontend_aesthetics>
```

To break the default house style reliably, have the model propose directions first: *"Before building, propose 4 distinct visual directions (each as bg hex / accent hex / typeface — one-line rationale). Ask the user to pick one, then implement only that."* Generic redirection ("don't use cream", "make it minimal") tends to swap one fixed palette for another rather than producing variety.

## 9. Model self-knowledge

For projects whose product calls an LLM:

```text
When an LLM is needed, default to Claude Opus 5 unless the user requests otherwise. The exact model string for Claude Opus 5 is claude-opus-5. Do not append a date suffix — the ID is complete as written.
```

Exact IDs, for reference. **Never write a model ID from memory** — this doc and the bundled `claude-api` skill are the sources; `specs/001-process-enforcement/decisions.md` (DL-P8b-04) is the standing rule that a published fleet-wide doc must not carry invented specifics.

| Model | ID | Use |
|---|---|---|
| Claude Opus 5 | `claude-opus-5` | default |
| Claude Fable 5 | `claude-fable-5` | most demanding reasoning / long-horizon agentic work |
| Claude Mythos 5 | `claude-mythos-5` | Project Glasswing participants only; otherwise use Fable 5 |
| Claude Opus 4.8 | `claude-opus-4-8` | prior generation; the documented refusal-fallback target |

## 10. Per-model deltas

Effort posture is in §1, which is canonical for it. This section carries the model-specific *behaviors* — what each model does differently that changes how you prompt it.

**Opus 5** — the default. Delegates more readily than the prior generation (§3), writes longer user-facing responses and longer files (§2), verifies itself without being asked (§6), and can expand task scope (§6). `xhigh` starts the sweep for coding and agentic work; `low`/`medium` are the primary cost lever elsewhere (§1).

**Fable 5 / Mythos 5** — for the hardest reasoning and longest-horizon agentic work. **The effort posture does not carry across**, and prompts written for a prior model usually need loosening. Everything else in this doc applies unchanged. The differences:

- **Effort:** `high` is the default — *not* `xhigh`. Reserve `xhigh` for the most capability-sensitive work and use `medium`/`low` for routine; lower Fable settings often exceed `xhigh` on prior models (corpus §3.2).
- **Prompts written for prior models are often too prescriptive** and reduce output quality. When migrating a prompt or skill, A/B it with the older step-by-step scaffolding removed — state the goal and the constraints, not the steps.
- **Over-gathering at high effort.** The anti-overengineering block in §6 is not optional here — it is the counter to a specific behavior.
- **Turns run long.** Single requests on hard tasks can run many minutes. Plan timeouts, streaming, and progress UX accordingly; structure work so callers check in asynchronously rather than blocking.
- **Start at the top of your difficulty range** (corpus §3.13). The best outcomes came from giving it the hardest unsolved problem first, letting it scope and ask, then execute — not from easing it in on work a prior model already handled.
- **Refusals are an availability concern, not a style one.** Safety classifiers can decline a request (`stop_reason: "refusal"`); the documented fallback target is `claude-opus-4-8`. Separately, a prompt that tries to elicit the model's internal reasoning *in the visible response* can be declined with a `reasoning_extraction` category — relevant to Trellis's `debrief` skill and any "show your reasoning" review pattern. Read the summarized thinking rather than prompting for reasoning.
- **Mythos 5 is Fable 5** for every purpose in this doc — same capabilities, same guidance, different ID and access path.

**Opus 4.8** — prior generation, retained as the refusal-fallback target. Guidance specific to it is historical and lives in `docs/adr/2026-05-29-opus-4.8-prompting-best-practices.md`.

---

## Deliberately NOT adopted

- **API-only mechanics.** Prefill migration, sampling parameters, thinking configuration, max-output-token sizing, and `output_config.effort` are Messages-API concerns. Trellis steers Claude Code, where effort is the `effortLevel` setting (§1) and thinking is adaptive automatically — none of these are actionable here. Projects that call the API directly should use the bundled `claude-api` skill, which tracks the current request surface.
- **`alwaysThinkingEnabled: true` in the template.** Over-trigger risk given Trellis's large injected system prompt (§1).
- **Removing the deterministic gates.** The guidance to strip verification scaffolding (§6) targets prompt-level nagging. `post-edit-verify`, `stop-verify`, `spec-gate`, the DoD receipts rule, and the loop-safety ceilings are mechanisms, not prompts. They stay.
- **The long pre-4.8 `frontend-design` snippet.** Deprecated for this generation (§8).
