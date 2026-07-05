# Reference — the codex-executor capability

How any Trellis workflow or loop dispatches a **unit of work to Codex as an
executor node**. This is the prose companion to `recipes/codex-executor.wf.js`;
the recipe is one implementation, this file is the contract it implements. The
durable routing *intent* — which work-type goes to which model, and why — lives
in `docs/codex-routing.md`; read that for the strength map and the benchmark
sources. This file answers the mechanical questions: how you gate on Codex, how
you dispatch to it, and what happens when it is absent or fails.

## Topology in one line

Claude is the orchestrator; Codex is a dispatchable executor node inside
Claude-driven workflows and loops (`docs/codex-routing.md §1`). The loop always
belongs to Claude. A Codex unit is a *stage* inside a Claude workflow, never a
peer loop. Routing decides which units leave the orchestrator; it never
re-decides who is running.

**What routes out:** execution-heavy bounded units — a large mechanical edit, a
refactor across many files, a long-running background execution. These carry the
token-expensive bulk, and Codex is ~3–4× cheaper per task with the autonomy edge.

**What stays home:** planning, spec, architecture, code review / adversarial
verify, synthesis, and the final merge decision. These are the quality-sensitive
minority where Claude's reasoning and blind-review edge pay off, and the
orchestrator owns them by definition. This split balances *both* the work and the
spend structurally — no per-run quota accounting needed.

## The capability gate (presence)

Codex is a **runtime-detected capability**, exactly like the workflow-tool gate
in `SKILL.md` — never a hard dependency. The `openai-codex` plugin is not part of
Trellis and cannot ship to the public mirror, so the recipe is **inert without
it** and every degrade path lands on Claude.

Before routing anything to Codex, resolve availability:

```
node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json
```

Codex is available only when `ready && codex.available && auth.loggedIn`. If any
is false or missing — or `$CODEX_PLUGIN` is unset, or the command errors — Codex
routing is **off** and *every* unit runs on the orchestrator. Unknown resolves to
OFF: the safe degrade, and the public-mirror-inert behavior. The framework still
works, just single-family.

Because a `.wf.js` runs inside the Workflow engine, which exposes **no shell
primitive**, the gate is run by the **main loop** (Bash-direct) and its boolean
result is threaded into the recipe via `args.codexAvailable`; when that arg is
absent, a *general* probe agent runs the command (the `codex:codex-rescue`
forwarder is contractually barred from `setup`).

## Dispatch mechanics — two paths, picked by where you run

The **default is (ii) — the wrapped, harness-tracked path** whenever you are
inside a workflow. Reach for (i) from the main loop, for detached async, or for
the presence gate. There is **no wrapper-free way** to run Codex as a native
agent (Claude Code spawns Claude models only; the plugin ships no MCP server),
so the Sonnet forwarder is the bridge — and that is a feature, because it makes
a Codex unit a first-class tracked node instead of a shell you babysit.

**(i) Bash-direct — from the main orchestrator loop** (a `/loop`, a scheduled
task, or an agent driving the work by hand). The orchestrator is already
running, so it spends **zero** on a middleman:

```
node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort xhigh "<prompt>"
```

This is the **leanest** path (zero forwarder cost) and the right choice from the
main loop, and it is **mandatory** for two operations that cannot go through the
forwarder at all:

- the **presence gate** (`setup --json`) — the forwarder is task-only and may
  not call `setup`;
- **`--background` async units** — the forwarder strips `--background` and cannot
  call `status` / `result`, so polling a detached job is Bash-direct only.

**(ii) In-engine forwarder — from inside a `.wf.js`.** The engine has no shell,
so the only way to reach Codex is a subagent:

```js
agent(prompt, { agentType: 'codex:codex-rescue', label: 'codex:<unit>', isolation: 'worktree' })
```

`codex:codex-rescue` is `model: sonnet` — the **cheapest available forwarder**,
cheaper than making a general Opus agent shell out to Bash. It forwards one
`codex-companion task --write` and returns raw stdout. This is the **canonical
in-workflow dispatch**: the unit is a tracked node (label, phase, live progress,
`TaskOutput`), and the Sonnet driver is a courier — Codex/GPT does all the
reasoning.

**§4 correctness requirement — this path MUST run synchronous.** The forwarder's
own heuristic (`codex-rescue.md:24`) may background a unit it judges
"big/open-ended" and return a **job handle instead of the result** — a non-empty
string that slips past the empty-degrade check and silently drops the work from
the fan-out. The recipe defends on two fronts: (a) the prompt orders foreground
("run synchronously, do not `--background`"), and (b) a job-handle-shaped result
is detected (`isJobHandle`) and that unit **degrades to Claude** rather than
returning handle text. Detached `--background` execution is mechanic (i)'s job,
never this in-engine path.

Never route execution through a general Opus agent that only shells out — the
most expensive of the three, buying nothing over (i) or (ii).

## Effort — xhigh by default

Both models default to `xhigh`. For the forwarder path, the leading
`--write --effort xhigh` tokens in the prompt are recognized and applied by the
codex-cli-runtime contract; for Bash-direct they are `task` flags. **Codex's
effort ceiling is `xhigh` — there is no `max` for Codex**; do not request a
higher tier. Claude has session-only tiers above xhigh (`max`, `ultracode`)
reachable per-session, but those are the orchestrator's call, not a Codex knob.

## Degrade-to-Claude

There is **no quota API** in the plugin, so "has limits" is not observable — a
limit-hit and a task failure are the **same signal**. Both surface as a
null / empty / errored Codex result (the forwarder "returns nothing" on failure).

On any such result, the workflow stage **re-dispatches the identical unit to the
orchestrator** and continues. The Codex dispatch carries **no output schema** for
exactly this reason: the forwarder returns raw stdout, so empty *is* the degrade
trigger — a schema would make the engine try to validate raw text and mask the
signal. Every degrade is `log()`'d so a run that silently became Claude-only
stays visible (no-silent-caps discipline).

## Quality is not laundered

Routing a unit to Codex does not lower the bar. Every Codex artifact flows back
through the orchestrator's **review gate** before it counts: a Claude reviewer
inspects the **actual diff** (not the executor's stdout self-report), runs the
on-host install/build/typecheck green check, and applies the bright-line
guardrails (destructive-op, secrets, external-message, DoD receipts) to the
Codex output — the same discipline `fanout-verify` applies on-host. This is
Component-D territory (`docs/codex-routing.md §4`, the dynamic-workflows spec):
HOLD-only PRs from unattended runs, its own autonomy ceiling, bright-lines on
every Codex unit, bypass-permissions for overnight, and Codex-unit prompts
hardened against unbounded `rm` / `$VAR.*` globs and confined to isolated
worktrees.

## Loop safety

The recipe is a one-shot fan-out (a single dispatch barrier, no rounds), so it
declares `no_progress_iterations: null` and lets `max_iterations` /
`budget_ceiling_usd` inherit the resolved baseline (`core-rules/loop-safety.md`).
Because it is a **cross-harness** loop, budget accounting attributes Claude
tokens at `usd_per_mtok` and Codex tokens at the optional `codex_usd_per_mtok`,
so the dollar ceiling maps onto each engine's token budget at the price that
engine actually bills; absent the Codex rate, spend falls back to the single rate
(backward compatible). Those rate values live in `trellis.config.json`, not in
the recipe.

## See also

- `docs/codex-routing.md` — the durable work-type → model routing intent and its
  benchmark sources.
- `recipes/codex-executor.wf.js` — the recipe skeleton implementing this contract.
- `recipes/fanout-verify.wf.js` — the single-family fan-out-per-target → verify
  shape this generalizes to a mixed harness.
- `core-rules/loop-safety.md` — the three ceilings and the per-model budget rate.
