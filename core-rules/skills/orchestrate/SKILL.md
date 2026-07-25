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
- **Work you could finish yourself in a handful of tool calls.** Spawn count is a
  real cost, not a free parallelism win: dispatch, context transfer, and synthesis
  each cost more than the tool calls they replace on a small task. If one agent can
  do the unit, use one rather than several. And on a short run inside one context
  window, do not stand up a verifier subagent to check work you just did — verify
  it directly. The fresh-context verifier earns its cost on long or multi-window
  runs (the skeptical-evaluator gate below), not on a turn you can see the whole
  of. The axis is run length, not whether anyone is watching: a long attended run
  across several windows needs the fresh verifier as much as an overnight one.

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

**Prefer async over blocking, and few long-lived agents over many short ones.**
Where the harness lets you dispatch and keep working, do that rather than blocking on
each return — and check in on a running agent instead of waiting on it. When several
subtasks share context, give them to **one agent that keeps that context across
them** rather than spawning a fresh agent per subtask: the re-read cost of a cold
agent usually exceeds the parallelism it buys, and a wave of short agents bottlenecks
on its slowest member. Intervene when an agent goes off track or is missing context;
do not re-dispatch around it. `references/speed-doctrine.md` specializes this rule
for the cross-harness case; the `codex-worker` path is deliberately blocking for a
workflow-engine reason (below), not a violation of it.

**Fan-out vehicle preference (teams-enabled harnesses).** When the harness offers
both a workflow-orchestration tool and named-teammate spawning, default fan-out
units to the **workflow tool** — its agents auto-terminate, and teammate panes can
spawn with project hooks silently dead. Spawn named teammates only when the operator
asks for visible interactive panes or long-lived roles; then hook liveness in the
teammate env is part of the unit's preflight. Evidence: 2026-07-09 probe, this
instance.

## Teammate teardown — synthesis includes cleanup

Engine-run workflow agents terminate themselves; named teammates do not. Whatever
tool spawned a teammate has a paired signal to end it — use that pair as the last
step of synthesis, after the teammate's output has passed the verify gate. The
fan-out is not complete while any teammate it spawned is still live (`CLAUDE.md` §
Definition of done, teammate clause).

Synthesis also **collects what the units wrote down**. A unit that ran in its own
worktree may have left an `implementation-notes.md` recording where it deviated from
the plan (`../execute/SKILL.md`). Concatenate those, unit-labelled, into the PR
description or the main checkout's file **before** reaping the worktree — a reaped
tree must never silently discard its notes.

**Then delete the file from the worktree, before you attempt the reap.** This is
not tidiness, it is the difference between a tree that reaps and one that never
can. Every reap predicate in Trellis refuses on *any* untracked content —
`recipes/fanout-verify.wf.js` stops if `git status --porcelain` prints anything,
and `dj_worktree_clean` in `scripts/lib/disk-janitor-lib.sh` deliberately omits
`-uno` because untracked work is data we must never silently destroy. An
`implementation-notes.md` left in place therefore blocks both the orchestrator's
reap and the disk-janitor backstop, permanently, for exactly those units that had
something worth recording. Do not reach for `.gitignore` instead:
`dj_worktree_has_ignored_artifacts` vetoes a tree harboring an unrecognized
ignored entry, which moves the block rather than removing it. Collect, delete,
reap — in that order.

## Pattern catalog

Six orchestration shapes, but the value is the two that are new. Four are already
doctrine in `CLAUDE.md` and practiced on every task — fan-out-and-synthesize,
adversarial-verification, generate-goal / loop-until-done, phase-decomposition; the
catalog cites where each already lives rather than restating it. The two genuinely
new shapes — **tournament** (rank or pick-best of many via pairwise comparison) and
**generate-and-filter** (generate wide and cheap, then keep what clears an explicit
metric) — get worked guidance: when, shape, and an example sketch.

Full catalog: [`references/patterns.md`](references/patterns.md).

## Dual-harness speed doctrine

When both an orchestration surface and a Codex executor are available, wall-clock
speed comes from **topology, not effort**. Two bright lines hold regardless of
topology: never dispatch the same work order to more than one leg (no duplicate
work), and inside a Workflow, Codex units dispatch through the blocking
`codex-worker` agent only — never the fire-and-forget rescue path, whose
backgrounding breaks `parallel()`/`pipeline()` barriers. Patterns, guardrails, and
receipt contracts: [`references/speed-doctrine.md`](references/speed-doctrine.md).

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

1. **Detect** — an operator-owned recurring task checks for incoming work (a conductor can rank the backlog; audits surface findings).
2. **Triage** — fan out one agent per item; classify and route.
3. **Resolve** — worktree-isolated agents work each item in parallel (`isolation: "worktree"`); `drift-holdpr` is this stage for mechanical drift.
4. **Review** — an adversarial judge checks each fix before it counts (`verify-panel`: Claude + Codex consensus). For a build that exceeds solo-model reliability, run this judge as the **skeptical evaluator** (below) against a pre-agreed sprint contract, not the generous default.
5. **Respond** — open a **HOLD PR** / update the channel; **never merge** (the Component-D merge bright-line holds at every stage).

Every stage inherits the loop-safety ceilings; a proactive routine declares a conservative `budget_ceiling_usd` and pilots first.

## Skeptical evaluator + sprint contract (opt-in, gated)

For builds that sit **beyond what the model does reliably in one solo pass** —
multi-session work, an unattended L4/L5 run — sharpen the verify stage with a
**skeptical evaluator**: a *separate* judge (never the generator) tuned skeptical
rather than generous, that **defaults to "not done" unless the receipt proves
it**. It realizes the harness-design *planner → generator → skeptical external
evaluator* pattern. Pair it with a **sprint contract**: before the generator
writes code, generator and evaluator agree in writing on the **testable
done-criteria**, frozen up front so the bar cannot be softened to fit the output.

This is **optional and gated** — it fires only above solo-model reliability, per
the post's cost/benefit rule; on a routine turn the always-on
`code-review-subagent` is the right tool and the evaluator is pure overhead. It
**composes with, and never replaces,** the `code-review-subagent` floor, DoD
receipts (the evidence it demands), and `verify-panel` (one way to run the
persona cross-model). The gate defaults closed — when in doubt, don't stand it
up, the same restraint as "start simplest" in
[`core-rules/references/loops.md`](../../references/loops.md). Unattended runs
are where it earns its cost: at L4/L5 no human is mid-loop to catch a generous
self-assessment ([`core-rules/autonomy.md`](../../autonomy.md)).

Full contract — the gate, the sprint-contract handshake, the persona's verdict
shape, and how it composes: [`references/skeptical-evaluator.md`](references/skeptical-evaluator.md).

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
  greens.** Each per-target agent works in an isolated worktree and returns the
  verdict `{target, branch, pushed, green, pr_url, worktree_path, notes}` — the
  contract the caller depends on at every degrade tier. **Agents never merge**: the
  main loop auto-merges the GREEN ones and HOLDs the rest. Target resolution and the
  Teardown reap phase are in its `recipes/MANIFEST.md` row.

**Orchestrator reap-after-commit (general rule).** When the main loop — not a
recipe — commits+pushes a worktree it provisioned, it reaps that tree right after
the push; the disk-janitor predicate is the mechanical backstop. Full mechanic and
the `codex-fanout` conflicting-unit case: the `codex-fanout` row in
[`recipes/MANIFEST.md`](recipes/MANIFEST.md) (ADR
`2026-07-16-orchestrator-conflicting-unit-reap`).

When running this under degrade tier 2 (subagents, no workflow tool), read the
recipe's `meta.phases` and per-agent prompts as the stage spec and dispatch them by
hand; the structured verdict is the contract either way.

## Authoring a new recipe

1. Copy `recipes/template.wf.js` to `recipes/<name>.wf.js`.
2. Fill the labelled points in the `meta` block (name, description, phases, and the
   `safety` block) and the output schema. Keep `meta` a **pure literal** — the
   engine evaluates it statically, so no function calls or computed values inside it.
3. Wire the stages: `phase()` to mark each phase, `agent(prompt, opts)` for a unit
   (pass `{label, phase, schema}`; add `isolation: "worktree"` for any agent that
   touches a repo), `parallel(thunks)` to fan out with a barrier, `pipeline(...)`
   to stream without one. Return the structured verdicts for the caller to act on.
   For a verify stage on above-solo-reliability work, the reviewer agent may adopt
   the **skeptical-evaluator** persona against a pre-agreed sprint contract
   (`references/skeptical-evaluator.md`) — opt-in and gated, not the default.
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
