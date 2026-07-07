---
name: orchestrate
description: Harness-neutral playbook for multi-stage work that decomposes into independent units — fan-out, verify-heavy, decompose-then-synthesize, rank-the-best, or generate-then-filter. Use when a task is too large or too parallel for one linear pass. Capability-gated: if your harness exposes a tool that spawns and coordinates subagents, it runs a recipe (or scaffolds one); otherwise it degrades to running the same stages by hand. Carries the pattern catalog and the reusable recipe library.
argument-hint: [recipe name | "new" to scaffold from template | a task to decompose]
---

# orchestrate

The playbook for work that is bigger than one linear pass: it **decomposes** the
task into independent units, **fans out** to do them, **adversarially verifies** the
results, and **synthesizes** a single answer. This SKILL.md is the durable, harness-
neutral **specification** of that discipline — the pattern catalog, the capability
gate, and each recipe's stages and verification criteria. The `.wf.js` files under
`recipes/` are **one implementation** of this spec (the implementation for a harness
that has a workflow-orchestration tool); they are not the spec. Authoritative rules
live in `engineering-process.md` and `CLAUDE.md` — when in doubt, those win.

Loaded identically whether surfaced from `.claude/skills/orchestrate/` or
`.agents/skills/orchestrate/`. Same SKILL.md, same `references/`, same `recipes/`.

## When to use

- A task decomposes into ≥2 independent units that can run in parallel — the
  parallel-dispatch triggers under *Context management* in `CLAUDE.md` are met
  (≥2 independent searches/analyses, >5 files, or an edit-heavy turn).
- The work is verify-heavy: each unit produces something that must be independently
  checked (built, typechecked, reviewed) before it counts.
- You need to **rank** or **pick the best** of many candidates at a scale one
  context can't weigh fairly (tournament), or **generate many candidates and keep
  the good ones** by an explicit metric (generate-and-filter).
- The same fan-out-per-target → verify → verdict shape recurs across targets (e.g.
  a change applied to every registered project) and you want a parametric recipe
  rather than a bespoke one-shot script.

## When NOT to use

- A single, linear, surgical change. One unit, one pass — orchestration is pure
  overhead. Just make the change (with a receipt).
- Work that is trivially serial because each step's output is the next step's input.
  There's nothing to fan out; phase it instead (the max-7-files phasing bullet under
  *Planning* in `CLAUDE.md`).
- Crossing the merge boundary. Orchestrated agents **never merge** — they produce
  verdicts. Mergeability is the `process-gate` skill; merging is a human or main-loop
  decision, not an orchestrated subagent's.

## Capability gate + two-level graceful degrade

The gate keys on **capability, not harness identity**. The question is never "am I
Claude Code?" — it is *"does my harness expose a tool that spawns and coordinates
subagents?"* Check your own tool list and act accordingly. This is what lets the
skill self-activate for any harness the day it gains such a tool, with no Trellis
change, and self-deactivate where the tool is absent.

1. **Has a workflow-orchestration tool.** Run the relevant recipe's `.wf.js`
   directly, or author a new one from `recipes/template.wf.js`. The recipe encodes
   the decompose → fan-out → verify → synthesize stages and returns structured
   verdicts the caller acts on.
2. **No workflow tool, but can spawn subagents.** Execute the recipe's stages
   **sequentially by dispatching subagents**, following the spec in this SKILL.md and
   `recipes/MANIFEST.md`. The `.wf.js` doubles as a **readable spec**: its
   `export const meta` block (name, description, `phases:[{title, detail}]`) and its
   per-agent prompt strings are plain text — read them and dispatch a subagent per
   stage with that prompt, collecting the same structured verdict by hand. You lose
   the engine's parallelism barrier but keep the full discipline.
3. **No subagents either.** Do the work **inline**, preserving the
   decompose → verify → synthesize discipline. Decompose the task on paper, do each
   unit, independently check each one, and synthesize — sequentially, in one context,
   but never collapsing verify into generate.

This degrades at **both** levels: the spec is the same prose at every tier; only the
mechanism that carries it changes (engine → subagents → your own hands).

## Pattern catalog

Six orchestration shapes, but the value is the two that are new. Four are already
doctrine in `CLAUDE.md` and practiced on every task — fan-out-and-synthesize,
adversarial-verification, generate-goal / loop-until-done, phase-decomposition; the
catalog cites where each already lives rather than restating it. The two genuinely
new shapes — **tournament** (rank or pick-best of many via pairwise comparison) and
**generate-and-filter** (generate wide and cheap, then keep what clears an explicit
metric) — get worked guidance: when, shape, and an example sketch.

Full catalog: [`references/patterns.md`](references/patterns.md).

## Proactive-loop shape + piloting

Two norms for the heavy end — large fan-outs and proactive loops (see
[`core-rules/references/loops.md`](../../references/loops.md) for *when* to reach
for one; this is *how* to run it).

**Pilot before a large fan-out.** A dynamic workflow can spawn many agents; a bad
recipe multiplied across 100 targets is 100× the waste. Before scaling, run the
recipe over a **small pilot subset** (2-3 targets), confirm the verdict shape and
the per-target cost, then fan out. `log()` the pilot cost so the full run's
`budget_ceiling_usd` is grounded, not guessed.

**The proactive-loop shape** — the five canonical stages of an unattended,
recurring loop, each mapped to machinery Trellis already ships:

1. **Detect** — a `scheduled-tasks/` entry checks for incoming work (the conductor ranks the backlog; audits surface findings).
2. **Triage** — fan out one agent per item; classify and route.
3. **Resolve** — worktree-isolated agents work each item in parallel (`isolation: "worktree"`); `drift-holdpr` is this stage for mechanical drift.
4. **Review** — an adversarial judge checks each fix before it counts (`verify-panel`: Claude + Codex consensus).
5. **Respond** — open a **HOLD PR** / update the channel; **never merge** (the Component-D merge bright-line holds at every stage).

Every stage inherits the loop-safety ceilings; a proactive routine declares a conservative `budget_ceiling_usd` and pilots first.

## Recipe library

The recipes are **generic, parametric skeletons** — not one-shot scripts. Targets,
dates, and scope come from `args` or a sidecar config (with a documented fallback to
reading `registry.md` for targets), never baked-in literals, so every shipped recipe
is path-neutral. The index lists one row per recipe with its intent, inputs,
capability needs, and degrade note.

Index: [`recipes/MANIFEST.md`](recipes/MANIFEST.md).

- **`recipes/template.wf.js`** — the blank, heavily-commented starting skeleton for
  authoring a new recipe. Carries a pure-literal `export const meta` block with
  labelled fill-in points (including the `safety` loop-safety block), a JSON-schema
  stub for structured agent output, one `phase()` call, one
  `agent(prompt, {label, phase, schema})` example, and a commented `parallel(...)`
  fan-out example. Copy it to start a new recipe.
- **`recipes/fanout-verify.wf.js`** — the reusable shape extracted from Trellis's
  one-shot fleet scripts:
  **fan-out-per-target → verify-on-host → structured VERDICT → main loop acts on
  greens.** Targets come from `args.targets` (a list of `{name, path}`) with a
  documented fallback to reading `registry.md`. Each per-target agent works in an
  **isolated worktree** (`isolation: "worktree"`), verifies the target on its host
  (install / build / typecheck per repo, lint where present), and returns a
  structured verdict of the shape
  `{target, branch, pushed, green, pr_url, notes}`. **Agents never merge** — the
  main loop reads the verdicts and auto-merges the GREEN ones, HOLDing the rest for
  human review.

When running this under degrade tier 2 (subagents, no workflow tool), read the
recipe's `meta.phases` and per-agent prompts as the stage spec and dispatch them by
hand; the verdict shape above is the contract the caller depends on either way.

## Authoring a new recipe

1. Copy `recipes/template.wf.js` to `recipes/<name>.wf.js`.
2. Fill the labelled points in the `meta` block (name, description, phases, and the
   `safety` block) and the output schema. Keep `meta` a **pure literal** — the
   engine evaluates it statically, so no function calls or computed values inside it.
3. Wire the stages: `phase()` to mark each phase, `agent(prompt, opts)` for a unit
   (pass `{label, phase, schema}`; add `isolation: "worktree"` for any agent that
   touches a repo), `parallel(thunks)` to fan out with a barrier, `pipeline(...)`
   to stream without one. Return the structured verdicts for the caller to act on.
4. Keep it **parametric and path-neutral** — `core-rules/` is the public mirror.
   Take targets, dates, and scope from `args` or a sidecar config; never bake in
   absolute paths, dates, or per-target specifics. Do **not** use the engine-rejected
   non-deterministic globals (the current-time call, the random call, the argless
   date constructor) — pass any timestamp through `args` instead.
5. Declare the `safety` block. Every recipe is a loop and **must** honor the
   loop-safety contract (`core-rules/loop-safety.md`): the three ceilings
   (`max_iterations`, `no_progress_iterations`, `budget_ceiling_usd`) plus the
   progress signal, set only to override the resolved baseline and otherwise left
   to inherit. A one-shot fan-out (single barrier, no rounds) declares
   `no_progress_iterations: null`. **A recipe with no `safety` declaration is
   non-compliant** — the `cross-project-process-audit` flags it and it is a
   `process-gate` / review finding.
6. Add a row to `recipes/MANIFEST.md`.

Before it lands, grep the new recipe (and any reference it adds) clean of personal
absolute paths, dated literals, and target-specific lists — the public-mirror scrub
is mandatory for every file under this skill.

## Claude-today (non-load-bearing)

Some harnesses ship CLI ergonomics that *feel* related but are **trigger
conventions, not agent behavior, and do not capability-gate** anything above. On
Claude Code today these include `ultracode`, the `/goal` and `/loop` commands, and a
`~/.claude/workflows` directory. They are convenient ways for a user to *invoke*
orchestration; they are not what the gate checks (the gate checks for the
subagent-spawning **tool**, which is the real capability). Mentioned only for
orientation — never depend on them, and never let a pattern read as requiring one:
the loop-until-done **pattern** rests on the verifiable-goal rule in `CLAUDE.md`, not
on a `/loop` command.
