# Loop safety

Trellis is a loop system: operator-owned recurring jobs are agentic cron loops, the `orchestrate` skill drives fan-out workflows, and `/loop` / `/goal` run agent loops on infra time. The dominant production failure mode of an agent loop is the loop that does not stop — infinite iteration, no-progress thrash, runaway spend.

This is the canonical **policy** that guarantees every Trellis loop halts. It is **doctrine plus declared fields**, not a mechanical enforcement hook — nothing here intercepts a running loop at tool-use time (that is explicitly out of scope, a possible later sub-project). The guarantee is that every loop *declares* its ceilings and *honors* them, and that a loop authored with no thought still halts because the fallback constants below apply.

*Which* loop to reach for — turn-based, goal-based, time-based, or proactive — is a separate question, answered by [`references/loops.md`](references/loops.md); this file is *how* any loop halts. And not every task needs a loop: reach for the **simplest primitive that has a real stop condition** (a turn beats a `/goal` beats a scheduled routine beats a proactive fan-out), and climb only when the work demands it.

## Loop taxonomy (ecosystem mapping)

The detailed selection guide remains [`references/loops.md`](references/loops.md); this is the compact mapping from the Claude Code team's [four loop types](https://claude.com/blog/getting-started-with-loops) (2026-06-30) to Trellis.

| Upstream type | Trellis surface |
|---|---|
| **Turn-based** | An ordinary prompted turn. Stops when the model judges the work done; verification skills harden that judgment. |
| **Goal-based** | `/goal` and recipe goal-loops. Stops when the condition is met or the turn cap trips; an evaluator checks each stop attempt. |
| **Time-based** | `/loop` for local intervals; an operator scheduler for unattended runs. |
| **Proactive** | Operator-configured research or audit routines composing schedule + goal + skills + workflows. |

Upstream `/usage`, `/goal` with no arguments, and `/workflows` are the first-party mirrors of this contract's `spent_usd / budget_ceiling_usd` report line.

## The three ceilings

Every Trellis loop declares and honors three ceilings and **halts on any one** of them. The ceiling **values** live in configuration (`trellis.config.json.loop_safety`); only the documented fallback constants are baked into this file.

1. **`max_iterations`** — hard cap on loop iterations / agent-dispatch rounds. Complements (does not replace) the Workflow engine's existing 1000-agent lifetime backstop.
2. **`no_progress_iterations`** — halt after N consecutive iterations that make no measurable progress. "Progress" is the loop's declared **progress signal** (catalog below); when the signal is unchanged for N consecutive iterations, the loop halts. A `codex-worker` stall-cancel-retry cycle counts as a no-progress iteration for the enclosing loop; the worker itself retries at most once per failure mode (spec 013). An `ultra` unit counts ×4 against any concurrency-derived budget arithmetic — the ×4 is anchored to the Codex CLI's default `features.multi_agent_v2.max_concurrent_threads_per_session = 4` (main + 3 subagents; structural default, distinct from the measured token-spend ratio — spec 011 D4a). Because recipes hard-reject ultra, the path an ultra unit can actually hit is the main-loop `budget_ceiling_usd` arithmetic: count an ultra unit's reported `turn.completed` tokens at ×4 against the dollar ceiling — reported usage is parent-thread-only (source-verified 2026-07-10: codex exec never aggregates or emits child-thread usage), so the ×4 also stands in for the invisible child spend. (Race-the-legs both-pools accounting retired with the pattern, 2026-07-10.)
3. **`budget_ceiling_usd`** — spend ceiling per loop run, in US dollars (the human-meaningful unit). The Workflow tool's `budget.total` is token-native (output tokens), so the dollar ceiling maps onto `budget.total` via the conversion below; `/loop` and operator recurring jobs track or estimate spend against the declared dollar ceiling, and surface that running spend as a `spent_usd / budget_ceiling_usd` line in **every** run report — not only on a ceiling trip — so the ceiling reads as a live gauge, not just a tripwire.

## Progress-signal catalog

A loop declares which signal defines "progress" for its class. Canonical signals:

- **commit/PR** — a new commit or opened PR since the last iteration (fleet-mutation loops).
- **file delta** — at least one file changed (edit loops).
- **new finding** — an audit/review surfaced a new item (audit loops).
- **work-list drain** — the remaining work-list shrank (queue/pipeline loops).
- **state-hash change** — a declared state hash differs from the prior iteration (catch-all).

If no signal is declared, the catch-all **state-hash change** applies.

A **one-shot fan-out with no rounds** — a single dispatch barrier, no iteration — has no meaningful "consecutive iterations" to measure. It is exempt from `no_progress` and declares `no_progress_iterations: null`. `max_iterations` and `budget_ceiling_usd` still apply.

## Halt behavior

On any ceiling trip:

- **Hard stop** — never auto-continue past a tripped ceiling.
- **Structured halt report** — emit which ceiling tripped, the last progress marker, the running `spent_usd / budget_ceiling_usd` cost line, and the work completed so far.
- **Surface for unattended loops** — overnight / cron / `--run-in-background` loops surface the halt in their run report (and notification where wired) rather than dying silently.

## Resolution order (most specific wins)

Modeled on the autonomy resolution (`core-rules/CLAUDE.md` § Autonomy, `core-rules/autonomy.md`). Each ceiling resolves independently, most specific wins:

1. **Per-loop `safety` override** — a recipe's `safety` block or an operator-run loop declaration explicitly sets a value.
2. **Project-local `.trellis.config.json.loop_safety`** — optional, for a project that needs different ceilings.
3. **Central `trellis.config.json.loop_safety`** — the instance baseline.
4. **Built-in fallback constants** (below) — so a loop in a broken / misconfigured / non-Trellis context still halts.

## Built-in fallback constants

These are the documented defaults a loop falls back to when no `loop_safety` block resolves. They are identical to the central baseline, so a loop that loses its config still halts safely:

| Ceiling | Fallback |
|---|---|
| `max_iterations` | 100 |
| `no_progress_iterations` | 3 |
| `budget_ceiling_usd` | 1000 |

## Token ↔ dollar conversion

`budget_ceiling_usd` is human-meaningful; the Workflow engine's `budget.total` is output-token-native. The conversion uses a single documented rate, `usd_per_mtok`, expressed per million output tokens and documented here so it updates in one place as model pricing moves:

```
usd_per_mtok = 25.00   # Claude Opus 4.8 output price, $25 / MTok
budget_tokens = round(budget_ceiling_usd / usd_per_mtok * 1_000_000)
```

Worked example — the fallback `budget_ceiling_usd` of **1000**:

```
1000 / 25.00 * 1_000_000 = 40,000,000 output tokens
```

So the $1000 ceiling maps onto a `budget.total` of **40,000,000 output tokens**. When model pricing changes, update `usd_per_mtok` (one constant) and every dollar ceiling re-maps automatically.

### Per-model rate (cross-harness loops)

`usd_per_mtok` is the Claude/Opus output price. A cross-harness workflow (see the Codex↔Claude dual-harness integration) spends on **both** Claude and Codex units in one loop, so a single Opus-priced rate mis-attributes the Codex spend when mapping the USD ceiling onto the engine's token budget.

An **optional** second field, `codex_usd_per_mtok`, carries the GPT-5.x / Codex output price. When both are present, each unit's spend is attributed to **its own model's rate** — Claude tokens at `usd_per_mtok`, Codex tokens at `codex_usd_per_mtok` — so the dollar ceiling maps onto each engine's token budget at the price that engine actually bills. When `codex_usd_per_mtok` is **absent**, Codex spend falls back to `usd_per_mtok`, so a single-rate config behaves exactly as before (backward compatible).

Nuance worth stating so the field is not over-relied on: Codex's per-task cost win is mostly that it spends **~3–4× fewer tokens** on an equivalent task, *not* a dramatically lower per-MTok rate. `codex_usd_per_mtok` only corrects the rate term; the larger saving already shows up because fewer Codex tokens are counted against the budget in the first place. Set the field to Codex's real output price, not to a fudge factor standing in for the token-count difference.

## Configuration keys

The ceiling values live in `trellis.config.json` under `loop_safety`; the schema (`scripts/lib/trellis.config.schema.json`) carries types, descriptions, and defaults. The block is optional — absence falls back to the constants above.

```json
"loop_safety": {
  "max_iterations": 100,
  "no_progress_iterations": 3,
  "budget_ceiling_usd": 1000,
  "usd_per_mtok": 25.00,
  "codex_usd_per_mtok": 10.00
}
```

A per-loop `safety` override (recipe block or operator-run declaration) may set any subset of these keys; unset keys resolve down the order above. Project-specific time and search caps are expressed as such overrides rather than as ad-hoc hardcoded values.

## Verification

The contract stays honest through a process drift check that scans `orchestrate` recipes and configured loop prompts for a present, non-blank loop-safety declaration and flags any loop missing one as a compliance finding. Authoring a loop without the declaration is additionally a `process-gate` / review finding.
