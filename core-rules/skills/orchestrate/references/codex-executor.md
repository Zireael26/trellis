# Reference — the codex-executor capability

How any Trellis workflow, loop, or interactive turn dispatches a **unit of
work to Codex as an executor node**. This is the prose companion to
`recipes/codex-executor.wf.js`; the recipe is one implementation, this file is
the contract it implements. The durable routing *intent* — which work-type
goes to which model, and why, including the interactive-delegation predicate —
lives in `docs/codex-routing.md`; read that for the strength map and the
benchmark sources. This file answers the mechanical questions: how you gate on
Codex, how you dispatch to it, what the dispatch prompt must say, how you
iterate, and what happens when it is absent, fails, or needs taking over.

## Topology in one line

Claude is the orchestrator; Codex is a dispatchable executor node inside
Claude-driven workflows and loops — and, since 009, for bounded work-order
units from any interactive turn (`docs/codex-routing.md §1, §6`). The loop
always belongs to Claude. A Codex unit is a *stage* inside a Claude workflow, never a
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

## The prompt contract

Spec quality decides delegation success. Every dispatch — workflow or
interactive — carries the six work-order fields:

```
GOAL:        <one sentence — what done looks like>
REPO/PATHS:  <repo root + the exact files/dirs in scope>
CONSTRAINTS: <don't touch X; APIs and styles to hold>
NON-GOALS:   <adjacent work explicitly out of scope>
PROOF:       <the exact command that must run green>
OUTPUT:      <report files changed + the proof output>
```

Six fields alone under-specify the execution environment, so the template
closes with the operational invariants the recipe already carries:

- **Base ref + branch** — name the commit the unit starts from and the branch
  the diff lands on; never "wherever HEAD is".
- **Worktree + seeding when isolated** — an isolated unit runs in a worktree
  created via `trellis worktree add` (inheritance-seeded), never a raw
  `git worktree add`.
- **Dirty-tree discipline** — the unit starts on a clean tree; a pre-existing
  dirty tree is a stop condition, not something to work around or clean up.
- **External-op ban** — the executor never pushes, opens PRs, publishes, or
  messages anyone; the diff stays local for the orchestrator's review.
- **Stop conditions** — stop when the proof passes, when a constraint blocks,
  or when the work exceeds scope; return the blocker instead of improvising.
- **Receipt format** — the report closes the tracking receipt (below): files
  changed, proof output, anything skipped and why.

Executor claims are **advisory** — the orchestrator reads the actual diff and
runs (or demands) the proof, per "Quality is not laundered" below.

## Interactive dispatch — tracked without the engine

A bounded work-order unit may route to Codex from a plain interactive turn —
no workflow required. *Whether* it routes (the work-order predicate, the
tiny-edit floor, the advisory-first pilot posture) is `docs/codex-routing.md
§6`'s call; this section owns the mechanics once it does. Dispatch is
mechanic (i), foreground, from the main loop:

```
node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort <tier> --json "<prompt>"
```

with `<tier>` set per the §3 effort ladder. Bash-direct is only "untracked" if
you track nothing, so every interactive dispatch keeps a **tracking receipt**:
opened at dispatch with the **unit id** (your name for the work order), the
**thread id** (the `--json` payload's `threadId` — the unit's resume handle),
the **leg** (Codex or Claude worker), and the **effort tier**; closed at
review with the **diff summary**, the **proof output**, the **review verdict**,
and any **degrade or takeover** note. Same DoD-receipt discipline as inline
work — budget attribution and audit survive without the Workflow engine.

## Resume — iterate on the unit's own thread

Capture the thread id at dispatch; it is the only safe handle for follow-up
rounds.

- **One unit in flight in this checkout:** `task --resume` (alias of
  `--resume-last`) is unambiguous — the companion resumes the latest tracked
  thread *per workspace root*, so a unit isolated in its own worktree owns its
  "last" by construction.
- **Two or more units sharing a checkout:** never race `--resume-last` — the
  companion's resume is id-blind and grabs whichever unit ran last. Target the
  captured id with the raw CLI, `codex exec resume <thread-id> "<follow-up>"`,
  and log the round in the receipt yourself (the raw CLI bypasses the
  companion's job tracking).
- **Fresh context with session history:** `transfer` imports the Claude
  session into a new Codex thread and prints its id — for units that need to
  see the conversation, not just the work order.

## Takeover — two failed rounds per unit

A round **fails** on any of six signals: no diff produced; a diff that is
off-goal or scope-violating; the proof command red; review-gate rejection; an
empty or errored result; a no-progress repeat of the previous round. Rounds
are counted **per unit id** — the receipt makes the count mechanical, not
vibes.

After **two failed rounds on the same unit**, stop delegating: the
orchestrator takes the unit over directly and logs the takeover in the receipt
(no-silent-degrade discipline). This is the interactive iteration rule; the
one-shot in-workflow degrade below stays as-is.

## Sandbox mechanics

**Approvals are already off on this path.** The companion pins
`approvalPolicy: "never"` (`lib/codex.mjs:67`) — Codex never stops to ask —
and `--write` runs the `workspace-write` sandbox. Dispatch is full-auto by
default; there is no approval friction for a bypass flag to remove.

**Network is not.** `workspace-write` denies network unless
`~/.codex/config.toml` carries:

```toml
[sandbox_workspace_write]
network_access = true
```

That file is host-global and unversioned, so **verify, never assume**: before
delegating a network-needing unit (dep installs, registry fetches), check
`grep -A1 'sandbox_workspace_write' ~/.codex/config.toml`; on a miss the unit
stays home. Rollback is the same two lines — set `false` or delete the block
and default-deny returns.

**The escape hatch — Codex-leg-only.** A unit that is genuinely
sandbox-hostile (out-of-workspace writes, blocked tooling like docker) may run
raw:

```
codex exec --dangerously-bypass-approvals-and-sandbox "<prompt>"
```

only under all of: an **isolated worktree** created via `trellis worktree add`
(inheritance-seeded), with a preflight that `.codex/hooks/` exists; **never
the canonical checkout**; a **trusted prompt** (no untrusted repo content in
context). Be honest about what this is: sandboxless is **host-wide privilege**
— the worktree confines the intended diff surface and makes rollback trivial;
it does not confine the process. The repo-scoped Codex hooks and the pre-push
guard still fire, but they are pattern-based — a complementary layer, not a
substitute for the sandbox. Same posture as the bypass-permissions-overnight
rule; the diff is reviewed like any other unit.

## Effort

Workflow recipes hardcode `xhigh` this cycle (threading per-unit effort
through `.wf.js` is a named follow-up). Interactive dispatch sets `--effort`
per unit from the ladder in `docs/codex-routing.md §3` — xhigh for hard
debugging, design-adjacent edits, and verify/review passes; high for standard
implementation from a frozen spec; medium/low for mechanical bulk. For the
forwarder path, the leading `--write --effort xhigh` tokens in the prompt are
recognized and applied by the codex-cli-runtime contract; for Bash-direct they
are `task` flags. **Codex's effort ceiling is `xhigh` — there is no `max` for
Codex**; do not request a higher tier. Claude has session-only tiers above
xhigh (`max`, `ultracode`) reachable per-session, but those are the
orchestrator's call, not a Codex knob.

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

- `docs/codex-routing.md` — the durable work-type → model routing intent, the
  interactive-delegation predicate (§6), the effort ladder (§3), and the
  benchmark sources.
- `recipes/codex-executor.wf.js` — the recipe skeleton implementing this contract.
- `recipes/fanout-verify.wf.js` — the single-family fan-out-per-target → verify
  shape this generalizes to a mixed harness.
- `core-rules/loop-safety.md` — the three ceilings and the per-model budget rate.
