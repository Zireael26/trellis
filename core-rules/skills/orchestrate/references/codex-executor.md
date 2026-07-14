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
absent, a *general* probe agent runs the command. The rescue forwarder is an
interactive-rescue-only path and is contractually barred from `setup`.

Presence alone is not enough (spec 011 D6). Three further probes run
alongside it — each main-loop Bash-direct, each **fail-closed**:

- **Model pin** —
  `grep -E '^model *= *"gpt-5\.6-sol"' ~/.codex/config.toml`. The file is
  host-global and unversioned, so verify per the 009 network-preflight
  pattern, never assume; a wrong or absent pin means the unit **stays home**,
  logged.
- **Companion effort-enum probe** — the accepted `--effort` set is read from
  the *installed* companion via the canonical mechanic,
  `scripts/codex-effort-preflight.sh`. A unit requesting a tier outside the
  probed set **fails closed with a logged note — never clamps** to a lower
  tier.
- **CLI version** — `codex --version` must report ≥ 0.144 wherever
  per-dispatch `--model` pinning is needed; an older CLI **fails closed**
  (the upgrade itself, plus killing the stale `codex app-server` and
  shadowing symlinks, belongs to the 013 handoff — here we only check).

Probe results thread into recipes the same way as presence:
`args.codexAvailable` plus `args.supportedEfforts` (the probed effort set).

## Dispatch mechanics — two paths, picked by where you run

The **default is (ii) — the blocking, harness-tracked worker** whenever you are
inside a workflow. Reach for (i) from the main loop, for a human-managed
detached rescue, or for the presence gate. Claude Code still spawns a Claude
driver for an agent profile, but `codex-worker` keeps that tracked node blocking
until the companion returns a real terminal result.

**(i) Bash-direct — from the main orchestrator loop** (a `/loop`, a scheduled
task, or an agent driving the work by hand). The orchestrator is already
running, so it spends **zero** on a middleman:

```
node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort <tier> "<prompt>"
```

(`<tier>` from the `docs/codex-routing.md §3` ladder — declared per unit,
never defaulted.)

This is the **leanest** path (zero worker cost) and the right choice from the
main loop, and it remains mandatory for:

- the **presence gate** (`setup --json`) before recipe dispatch; and
- an **interactive rescue** where a human intentionally owns a detached
  `--background` job and its `status` / `result` polling.

**(ii) In-engine blocking worker — from inside a `.wf.js` — CANONICAL.** Dispatch
the inherited worker profile as a normal tracked agent node:

```js
agent(prompt, { agentType: 'codex-worker', label: 'codex:<unit>' })
```

`codex-worker` is `model: sonnet`, launches the companion in the work order's
required `TARGET_CWD`, polls status from that same cwd, applies the bounded
no-session/stall recovery, fetches `result`, and
returns that result plus its diff-stat receipt. The Workflow node therefore
resolves only on terminal success, unavailability, or failure. Producing recipes
retain a defensive job-handle assertion: a leaked handle is a worker-contract
failure and degrades the identical unit to Claude, never a completed result.

The legacy rescue forwarder remains documented only for interactive rescue. It
is fire-and-forget and MUST NOT be used as a producing dispatch path inside a
Workflow.

Never route execution through a general Opus agent that only shells out — the
most expensive of the three, buying nothing over (i) or (ii).

## The prompt contract

Spec quality decides delegation success. Every dispatch — workflow or
interactive — carries the six work-order fields plus the honest-reporting
clause. A producing workflow also carries the required execution-root header:

```
TARGET_CWD: <caller-provisioned stable worktree root>
GOAL:        <one sentence — what done looks like>
REPO/PATHS:  <repo root + the exact files/dirs in scope>
CONSTRAINTS: <don't touch X; APIs and styles to hold>
NON-GOALS:   <adjacent work explicitly out of scope>
PROOF:       <the exact command that must run green>
OUTPUT:      <report files changed + the proof output>

Report failures as failures. Never claim completion without the proof command's actual output. A claimed-complete unit without receipts is treated as failed.
```

The honest-reporting clause is the **seventh mandatory template line** —
character-identical in this template and in every runnable prompt builder,
never paraphrased. Rationale, stated boundedly: the GPT-5.6 system card
reports increased agentic-coding overreach vs 5.5 (most pronounced at highest
reasoning effort under persistence-heavy prompts) alongside a ~30% *decrease*
in misrepresented completions in simulated traffic, and METR reports its
highest detected ReAct-harness cheating rate, explicitly prompt/scaffold-dependent
— so the honesty contract must live in the runnable prompt, not only in prose.

Seven lines alone under-specify the execution environment, so the template
closes with the operational invariants the recipe already carries:

- **Base ref + branch** — the caller provisions the unit worktree from the named
  commit/branch before dispatch; never "wherever HEAD is".
- **Stable worktree + seeding** — producer and verifier receive the exact same
  `TARGET_CWD`, created by the caller via `trellis worktree add`
  (inheritance-seeded), never by either worker and never with per-stage engine
  isolation. Workers leave the diff uncommitted; the caller commits only after
  verification.
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
the **leg** (Codex or Claude worker), the **effort tier**, and the
**justification** (required when the effort is an exception tier); closed at
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

**The escape hatch — manual, operator-invoked, Codex-leg-only.**
`workspace-write` is the **default and the only automated posture**: no
automated recipe may use the hatch. A unit that is genuinely sandbox-hostile
(out-of-workspace writes, blocked tooling like docker) may run raw:

```
codex exec --dangerously-bypass-approvals-and-sandbox "<prompt>"
```

only when the operator invokes it by hand, and only under all of: an
**isolated worktree** created via `trellis worktree add`
(inheritance-seeded), with a preflight that `.codex/hooks/` exists; **never
the canonical checkout**; a **trusted prompt** (no untrusted repo content in
context). **`max` and `ultra` are forbidden on the hatch** — highest-effort
persistence risk with no OS sandbox is exactly the compound the 5.6 system
card warns about. Be honest about what this is: sandboxless is **host-wide privilege**
— the worktree confines the intended diff surface and makes rollback trivial;
it does not confine the process. The repo-scoped Codex hooks and the pre-push
guard still fire, but they are pattern-based — a complementary layer, not a
substitute for the sandbox. Same posture as the bypass-permissions-overnight
rule; the diff is reviewed like any other unit.

## Effort

The ladder — operating band, exception tiers, the explicit-effort-or-error
rule — lives in `docs/codex-routing.md §3` and is the single source; it is
not restated here. This section carries only the mechanics:

- **Workflow recipes take a required per-unit `effort`** — enum-validated at
  the top of the recipe; an omitted tier is a validation error, never a
  default. `ultra` is excluded from the recipe enum and hard-rejected with a
  logged note — the companion dispatch surface caps at xhigh and delegation is
  invisible/non-resumable in a deterministic workflow (`docs/codex-routing.md
  §3`; D4a satisfied 2026-07-10).
- **Interactive dispatch sets `--effort <tier>`** per the §3 ladder on every
  unit. In a Workflow, `codex-worker` receives the explicit effort field in its
  work order; for Bash-direct up to xhigh it is a companion `task` flag, and
  the exception tiers use raw exec:
  `codex exec --json -c model_reasoning_effort="<max|ultra>" ... </dev/null`
  (ultra: attended turns only, per §3).
- **Exception tiers require a named `justification`** logged in the dispatch
  receipt, and are invocable only where the preflight (see "The capability
  gate") proves the installed surface supports them — a tier outside the
  probed set fails closed with a logged note, never clamps.

## Degrade-to-Claude

There is **no quota API** in the plugin, so "has limits" is not observable — a
limit-hit and a task failure are the **same signal**. Both surface as a worker
UNAVAILABLE / FAILURE receipt, a thrown error, or an empty result.

On any such result, the workflow stage **re-dispatches the identical unit to the
orchestrator** and continues. The Codex dispatch carries **no output schema** so
the worker's verbatim terminal receipt remains intact and an empty value stays a
degrade trigger. Every degrade is `log()`'d so a run that silently became Claude-only
stays visible (no-silent-caps discipline).

## Quality is not laundered

Routing a unit to Codex does not lower the bar. **Review of executor output is
never delegated to the executor that produced the diff, and never skipped** —
cross-agent review inside recipes is legitimate; self-review by the producing
executor is what's banned. Every Codex artifact flows back
through the orchestrator's **review gate** before it counts: a Claude reviewer
inspects the **actual uncommitted diff in the producer's exact `TARGET_CWD`**
(not the executor's stdout self-report or a fresh isolated worktree), runs the
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
