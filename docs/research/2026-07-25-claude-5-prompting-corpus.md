# Claude 5 generation — prompting & context-engineering corpus (2026-07-25)

Primary-source distillation used as the input to spec 019 (Claude-5 alignment).
Every claim below traces to one of the sources in § Sources. Treat this file as the
**reference**, not as doctrine — doctrine lands in `core-rules/`.

---

## 1. The headline shift: unhobbling

Anthropic removed **over 80% of Claude Code's system prompt** for Opus 5 / Fable 5
class models **without performance loss**. The governing insight: newer models need
fewer constraints and can be trusted with judgment. Six named shifts:

| Then | Now |
|---|---|
| Give Claude **rules** | Give Claude **principles**, let it use judgment |
| Give Claude **examples** | Design better **interfaces** (expressive params, clear enums) |
| Put it **all upfront** | **Progressive disclosure** (skills, deferred tools, nested files) |
| **Repeat yourself** across prompt + tool descriptions | Instructions live **once**, in the tool description |
| **Manual** memory in CLAUDE.md | **Auto-memory** |
| Simple markdown **specs** | **Rich references**: HTML artifacts, code specs, test suites, rubrics, dynamic workflows with verifier agents |

Canonical example of the rules→principles move, from Anthropic's own diff:

- **Before:** "default to writing no comments. Never write multi-paragraph docstrings."
- **After:** "Write code that reads like the surrounding code: match its comment
  density, naming, and idiom."

Rationale: older models needed guardrails against worst cases; newer models handle
the nuanced call themselves. Over-constraint now *costs* quality.

### Where each layer belongs

- **System prompt** — product/role context. Rarely user-edited. Invest here when
  building your own harness.
- **CLAUDE.md** — lightweight. Briefly describe repo purpose. **Spend tokens on
  gotchas, not on facts Claude can infer.** Use progressive disclosure for anything
  complex.
- **Skills** — lightweight guides activated on demand. **Avoid over-constraining**
  except in critical areas. Split long skills across files.
- **References (@-mentions)** — in-depth current-plan info. **Prefer code over
  descriptions.** HTML mockups generally outperform screenshots or prose.

Anthropic ships `/doctor` in Claude Code to rightsize skills, system prompts, and
CLAUDE.md.

---

## 2. Prompting Claude Opus 5 (behavioral deltas)

Opus 5 runs well on Opus 4.8 prompts out of the box. What needs tuning:

### 2.1 Remove verification scaffolding — it over-fires
> "Claude Opus 5 verifies its own work without being told to. If your prompt
> contains explicit verification instructions ('include a final verification step
> for any non-trivial task', 'use a subagent to verify'), **remove them**:
> instructions like these cause over-verification on Claude Opus 5, and removing
> them reduces wasted tokens with no loss in quality. The same applies to legacy
> harness scaffolding that adds separate verification steps."

Also: avoid "double-check your answer" / "re-verify before responding" — the model
already self-corrects; these compound and add cost without improving results.

**Nuance that matters for Trellis:** this targets *prompt-level nagging*, not
*deterministic gates*. A hook that mechanically checks a receipt marker is not an
instruction the model can over-fire on.

### 2.2 Damp subagent spawning
> "Delegate to a subagent only for large tasks that are genuinely independent and
> parallelizable, such as a wide multi-file investigation. Do not delegate work you
> can finish yourself in a handful of tool calls, and do not use subagents to verify
> or double-check your own work. If one subagent can complete the task, use one
> rather than several, and keep spawn counts low."

Opus 5 delegates **more readily** than prior models. This is the exact inverse of
the Opus 4.8-era instruction "honor these triggers even when inlining feels easier."

### 2.3 Verbosity is not effort-controlled
Effort controls *thinking*, not *visible response length*. Opus 5's default
user-facing responses run **longer** than prior Opus models. Prompt for concision
explicitly; in a long system prompt, repeat a short reminder near the end.

Written deliverables (files on disk) are also longer by default — calibrate length
explicitly: "cover the substance, but do not pad with filler sections, redundant
summaries, or boilerplate."

### 2.4 Narration cadence is promptable
Opus 5 narrates readily during agentic work. Describe the cadence you want; positive
examples of the style beat prohibitions.

### 2.5 Scope containment
Opus 5 can expand scope, adding unrequested steps. The canonical constraint text:
> "Deliver what was asked, at the scope intended. Make routine judgment calls
> yourself, and check in only when different readings of the request would lead to
> materially different work. If the request seems mistaken or a better approach
> exists, say so in a sentence and continue with the task as asked rather than
> quietly narrowing, widening, or transforming it. Finish the whole task, and stop
> short of actions that are clearly beyond what was asked."

### 2.6 Correction narration
Opus 5 narrates corrections to its own earlier statements more than prior models.
> "Only correct an earlier statement when the error would change the user's code,
> conclusions, or decisions. State corrections plainly and briefly, then continue."

### 2.7 Effort
`low`/`medium` produce strong quality at a fraction of tokens and beat the same
settings on prior Opus models. **Use them liberally as the primary cost/latency
control.** For coding and agentic work, **`xhigh` remains the recommended starting
point.** Re-run an effort sweep if defaults were carried over from a prior model.

### 2.8 Code review
High precision *and* recall; accuracy holds at lower effort (supports a fast pass at
review time, thorough pass later). **Do not** write "only report high-severity
issues" or "be conservative" — Opus 5 follows it literally and under-reports. Ask
for everything, filter in a separate pass.

### 2.9 Other
- 1M context is both default and maximum; instruction-following stays consistent
  across the window.
- Vision is strong; re-validate old vision workarounds. Tools to crop/iterate beat
  thinking alone.
- Multi-agent coordination is good — writer/verifier patterns work, few overwrites.
- Thinking-disabled artifacts (tool calls leaking as text, internal XML tags in
  output) — mitigate by keeping thinking on and lowering effort instead.

---

## 3. Prompting Claude Fable 5 / Mythos 5

### 3.1 Long turns, long runs
Individual requests can run many minutes; autonomous runs extend for hours. Restructure
harnesses to **check on runs asynchronously (scheduled jobs) rather than blocking**.

Anti-overplanning text:
> "When you have enough information to act, act. Do not re-derive facts already
> established in the conversation, re-litigate a decision the user has already made,
> or narrate options you will not pursue in user-facing messages. If you are weighing
> a choice, give a recommendation, not an exhaustive survey."

### 3.2 Effort
`high` is the default for most tasks; `xhigh` for the most capability-sensitive;
`medium`/`low` for routine. Lower Fable settings often exceed `xhigh` on prior models.

At higher effort Fable can over-gather and over-tidy. Anti-gold-plating text is the
familiar surgical-scope block (no unrequested refactors, no speculative defensive
code, no feature flags or compat shims when you can just change the code).

### 3.3 Brief instructions beat enumerations
Instruction-following is strong enough to steer a whole behavior class with one short
instruction rather than naming each pattern. Same for checkpoint behavior:
> "Pause for the user only when the work genuinely requires them: a destructive or
> irreversible action, a real scope change, or input that only they can provide. If
> you hit one of these, ask and end the turn, rather than ending on a promise."

### 3.4 Ground progress claims (anti-fabrication)
Nearly eliminated fabricated status reports in Anthropic's testing:
> "Before reporting progress, audit each claim against a tool result from this
> session. Only report work you can point to evidence for; if something is not yet
> verified, say so explicitly. Report outcomes faithfully: if tests fail, say so with
> the output; if a step was skipped, say that; when something is done and verified,
> state it plainly without hedging."

### 3.5 State the boundaries
Fable can take unrequested actions (drafting an email, creating defensive git
backups). When the user is describing a problem or thinking out loud, **the
deliverable is the assessment** — report and stop.

### 3.6 Parallel subagents
Fable dispatches parallel subagents more readily and is **significantly more
dependable** at sustaining them. Prefer **asynchronous** orchestrator↔subagent
communication over blocking. **Long-lived subagents that keep context across
subtasks** save time and cost (cache reads) and avoid bottlenecking on the slowest.
> "Delegate independent subtasks to subagents and keep working while they run.
> Intervene if a subagent goes off track or is missing relevant context."

### 3.7 Memory system
Fable performs particularly well when it can record and reference lessons:
> "Store one lesson per file with a one-line summary at the top. Record corrections
> and confirmed approaches alike, including why they mattered. Don't save what the
> repo or chat history already records; update an existing note rather than creating
> a duplicate; delete notes that turn out to be wrong."

### 3.8 Early stopping (autonomous pipelines)
> "You are operating autonomously. The user is not watching in real time and cannot
> answer questions mid-task, so asking 'Want me to…?' or 'Shall I…?' will block the
> work. For reversible actions that follow from the original request, proceed without
> asking. … Before ending your turn, check your last paragraph. If it is a plan, an
> analysis, a question, a list of next steps, or a promise about work you have not
> done ('I'll…', 'let me know when…'), do that work now with tool calls. End your
> turn only when the task is complete or you are blocked on input only the user can
> provide."

### 3.9 Context-budget concern — do not surface countdowns
In very long sessions Fable may suggest a new session or trim its own work. **Most
often triggered when the harness shows a remaining-token countdown to the model.**
Avoid surfacing explicit context-budget counts. If unavoidable, reassure:
> "You have ample context remaining. Do not stop, summarize, or suggest a new session
> on account of context limits. Continue the work."

### 3.10 Give the reason, not only the request
> "I'm working on [the larger task] for [who it's for]. They need [what the output
> enables]. With that in mind: [request]."

### 3.11 Readability of the final message (long unattended runs)
This is a **doctrine-level** point, not a style nit:
> "Terse shorthand is fine between tool calls (that's you thinking out loud, and
> brevity there is good). Your final summary is different: it's for a reader who
> didn't see any of that. If you've been working for a while without the user watching
> (overnight, across many tool calls, since they last spoke), your final message is
> their first look at any of it. Write it as a re-grounding, not a continuation of
> your working thread. … Drop the working shorthand. Write complete sentences. Spell
> out terms. Don't use arrow chains, hyphen-stacked compounds, or labels you made up
> earlier. … Open with the outcome. … If you have to choose between short and clear,
> choose clear."

### 3.12 send-to-user tool
For long async agents, define a tool whose input is rendered verbatim to the user
without ending the turn. **Tool inputs are never summarized**, so content arrives
intact. Defining it is not enough — pair with elicitation language, and do not route
narration through it.

### 3.13 Recommended scaffolding changes (verbatim intent)
- **Start at the top of your difficulty range.**
- **Make self-verification explicit in long-run prompts.** *"Separate, fresh-context
  verifier subagents tend to outperform self-critique."* For long-running tasks:
  "Establish a method for checking your own work at an interval of [X] as you build.
  Run this every [X interval], verifying your work with subagents against the
  specification."
- **Refactor existing prompts and skills.** *"Skills developed for prior models are
  often too prescriptive for Claude Fable 5 and can degrade output quality. Review
  and consider removing older instructions if default performance is better."*
- **Don't instruct Claude to reproduce its reasoning in the response.** Prompts,
  skills, or harness instructions that tell the model to **echo, transcribe, or
  explain its internal reasoning as response text** can trigger the
  `reasoning_extraction` refusal category on Fable 5, causing elevated fallbacks to
  Opus 4.8. **Audit existing skills and system prompts for reflection or
  show-your-thinking instructions when migrating.**
- **Create a send-to-user tool** for long async agents.

### 3.14 Safety classifiers
Fable 5 runs classifiers targeting offensive cybersecurity, biology/life-sciences,
and extraction of summarized thinking. Benign security work may trip them. Configure
fallback to Opus 4.8 (`stop_reason: "refusal"`).

---

## 4. Cross-model techniques (all current Claude models)

- **Be clear and direct.** Golden rule: if a colleague with minimal context would be
  confused by your prompt, so will Claude. Ask explicitly for "above and beyond"
  behavior if you want it.
- **Add context / motivation.** Explain *why* a constraint exists; Claude generalizes
  from the explanation. ("NEVER use ellipses" → "your response will be read aloud by
  a TTS engine, which can't pronounce them.")
- **Examples:** relevant, diverse, wrapped in `<example>`/`<examples>` tags. 3–5 for
  best results — but note the Claude-5 shift toward *one-shot then stop*, and toward
  interface design over examples.
- **XML tags:** still the disambiguator when a prompt mixes instructions, context,
  examples, and variable inputs. **Less necessary than it used to be** — clear
  headings and explicit language are the modern alternative for ordinary prompts.
- **Long context (20k+):** put longform data **at the top**, query at the **end**
  (up to ~30% quality lift). Wrap documents in `<document>`/`<document_content>`/
  `<source>`. Ask for grounding quotes first.
- **Tool use:** be explicit that you want action, not suggestions. If prompts were
  tuned against *under*-triggering, they now **over**-trigger — dial back "CRITICAL:
  you MUST" to "Use this tool when…".
- **Parallel tool calls:** default behavior is already good; the canonical
  `<use_parallel_tool_calls>` block pushes it to ~100%.
- **Overthinking:** replace blanket defaults ("default to using X") with targeted
  ones ("use X when it would enhance your understanding"). Remove "if in doubt, use
  X" — it over-triggers now. Effort is the fallback lever.
- **Adaptive thinking** is the only mode on Fable 5 / Mythos 5 and the recommended
  mode elsewhere. `budget_tokens` returns 400 on Claude 4.7+.
- **Permission to express uncertainty** reduces hallucination.
- **Format:** say what to do, not what not to do. Match prompt style to desired
  output style.
- **Minimum necessary structure.** "The best prompt isn't the longest or most
  complex — it's the one that achieves your goals reliably with the minimum necessary
  structure." Over-engineering prompts is a named pitfall.
- **Role prompting:** overly specific personas can *limit* helpfulness; prefer
  describing the framing.

### Agentic systems
- **Multi-window workflows:** first context window builds the framework (tests, setup
  scripts); later windows iterate a todo list. Keep structured state in JSON
  (`tests.json`), freeform progress in text, and **use git as the state log**.
  Prefer starting a **fresh** context window over compaction — modern models are
  extremely effective at discovering state from the filesystem. Be prescriptive about
  how a fresh window starts (`pwd`, read `progress.txt`, read git log, run an
  integration test).
- **Do not stop early on token-budget concerns**; save state and continue.
- **Reversibility framing** for autonomy/safety: local reversible actions are
  encouraged; destructive, hard-to-reverse, or externally-visible actions warrant
  confirmation. Never use destructive actions as a shortcut (no `--no-verify`).
- **Research:** competing hypotheses, tracked confidence levels, self-critique,
  persisted hypothesis tree.
- **Anti-hardcoding:** tests verify correctness, they don't define the solution.
- **Anti-hallucination:** never speculate about code you have not opened.

---

## 5. Finding your unknowns (the Fable field guide)

Frame: your instructions are the **map**; the implementation constraints are the
**territory**. The gap is where Claude has to guess.
> "Claude Fable is the first model where I find the quality of the work is
> bottlenecked by my ability to clarify its unknowns."

Four quadrants: known knowns (in the prompt), known unknowns (gaps you know about),
**unknown knowns** (obvious-to-you context you'd never document but recognize on
sight), **unknown unknowns**.

Techniques, by phase:

**Before**
- **Blind spot pass** — "I'm working on [task] but know nothing about [domain]. Can
  you do a blind spot pass to help me figure out my relevant unknown unknowns?"
  Disclose your expertise level.
- **Brainstorms and prototypes** — for unknown knowns. Generate multiple variations
  before implementation; mock with fake data to test layout before wiring anything.
- **Interviews** — have Claude question you, prioritizing questions **"where my
  answer would change the architecture."**
- **References** — source code beats description: "this Rust crate implements the
  exact semantics I want; read it and reimplement in our language."
- **Implementation plans** — highlight the decisions most likely to change (data
  models, type interfaces, UX flows); bury mechanical detail.

**During**
- **Implementation notes** — a temporary `implementation-notes.md` where the agent
  logs deviations from the plan and the conservative choice it made at each fork.

**After**
- **Pitches and explainers** — package prototype + spec + notes into one document for
  approval; lead with demo content.
- **Quizzes** — a comprehension check the human must pass, plus an HTML report.

**Instructional balance:** too specific and Claude follows even when pivoting is
right; too vague and it defaults to generic industry best practice. Disclose your
experience level and your current thinking; treat Claude as a thought partner.

> "Every explainer, brainstorm, interview, prototype, and reference is a cheap way to
> find out what you didn't know before it gets expensive to fix."

---

## 6. Designing before building (Claude Design)

- **Write the prompt before you design.** Clarify vision away from the computer
  (dictation, voice memos) so the session executes rather than explores.
- **Set direction upfront** — fonts, colors, mood boards, references — or the model
  falls back on recognizable defaults.
- **Minimize fidelity while exploring.** Wireframes move faster and keep attention on
  structure.
- **Remix:** generate many options, pick 1–2, then "smoosh these together."
- **Separate ideation from production.** Design-space exploration and shipping code
  are different tools and different loops.
- **Make ideas alive** — interactive simulations beat static mockups for buy-in.
- **Direct-edit the last 5%.** Manual nudges cost no tokens and eyeballing beats
  prompting for sizing and alignment.

---

## 7. Verification loops with skills

Definition: *"a repeating cycle where an AI agent checks its own work — running
tests, linters, or custom checks — and fixes what fails before moving on."*

Sits in the agentic loop: gather context → take action → **verify results**.

Native surfaces: the built-in `/verify` skill, toolchain error codes, Code Review,
GitHub Actions on every push/PR, spec validation against markdown specs, and rubrics
in Managed Agents where a grader agent's failure loops automatically.

Minimal custom skill shape:

```markdown
---
name: verify-log-hygiene
description: Check error logs include request IDs, never expose request bodies
allowed-tools: [Read, Edit, Grep]
---
Read error-handling paths in diffs.
For each log call, confirm request ID inclusion and payload stripping.
Report violations with file:line, then fix each issue.
```

Four deployment patterns:
1. **Standalone** — deliberately invoked for cross-cutting checks. If you run it
   after *every* change, that's the signal to embed or chain it.
2. **Embedded** — verification appended to the producing skill's body. Only works on
   editable project-level skills.
3. **Chained** — one skill calls the next. Anthropic's own chain:
   `/code-review` → `/simplify` → `/verify` → custom `/design` check. Wrapper skills
   add verification to skills you cannot modify.
4. **On every PR** — the same chain in CI, standardized team-wide.

What qualifies for encoding: repetitive manual corrections you make after
implementation; deterministic rules generic linters won't catch ("reject migrations
dropping columns without backfills"); team patterns you'd otherwise explain at
onboarding.

**Caution:** chained loops increase token spend — test before broad deployment.

---

## 8. Direct implications for Trellis (pointers, not decisions)

Recorded here so the audit tracks share one starting hypothesis list. Each is
confirmed or rejected in `specs/019-claude-5-alignment/`.

1. `core-rules/CLAUDE.md` is 24 KB against its own stated `<5 KB` target — a 4.8×
   drift, injected into every session of every registered project.
2. In-file model conditionals in the constitution ("Opus 4.8 under-dispatches
   subagents") have **inverted** and violate Trellis's own no-model-conditionals
   doctrine. Model-divergent facts belong in `references/model-prompting-deltas.md`.
3. `references/model-prompting-deltas.md` predates the entire Claude 5 line.
4. Opus 5 says remove verifier-subagent instructions; Fable 5 says fresh-context
   verifier subagents beat self-critique on long runs. Both are true — the axis is
   **run length**, not model preference.
5. `reasoning_extraction` is an availability risk, not a style issue. Audit for
   instructions that ask the model to transcribe its own reasoning as response text.
   Artifacts *for the user* (quizzes, explainers, decision logs) are explicitly fine.
6. "Terse responses, no trailing prose summaries" conflicts with §3.11 for
   **unattended** runs. Scope by attendedness.
7. Context-budget thresholds stated to the agent ("when ctx use ≥40%…") are the exact
   trigger §3.9 warns about.
8. Rules written as prohibitions ("Default to no comments") should become principles.

---

## Sources

- Anthropic, *The new rules of context engineering for Claude 5 generation models* —
  https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models
- Anthropic, *A field guide to Claude Fable: finding your unknowns* —
  https://claude.com/blog/a-field-guide-to-claude-fable-finding-your-unknowns
- Anthropic, *How the product designer who built Claude Design uses it* —
  https://claude.com/blog/how-the-product-designer-who-built-claude-design-uses-it-to-explore-ideas-before-building-them
- Anthropic, *Building verification loops in Claude Code with Skills* —
  https://claude.com/blog/building-verification-loops-in-claude-code-with-skills
- Claude Platform Docs, *Prompting Claude Opus 5* —
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5
- Claude Platform Docs, *Prompting Claude Fable 5* —
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5
- Claude Platform Docs, *Prompting best practices* —
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- Anthropic, *Prompt engineering best practices for 2026* —
  https://claude.com/blog/best-practices-for-prompt-engineering
