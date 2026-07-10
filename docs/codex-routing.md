# Cross-model strength routing — steering reference

Source: the July-2026 community + benchmark consensus on Claude/Opus vs Codex/GPT-5.x (last30days engine + web search, distilled to the figures below), not model recall. This doc carries the **work-type → model** routing policy as durable steering **intent** for Trellis's dual-harness setup. It is not a rule that branches on which harness is running — the load-bearing rules live in `core-rules/CLAUDE.md`, `core-rules/autonomy.md`, `core-rules/loop-safety.md`, and the hooks, and they steer every harness **identically** (byte-identical `CLAUDE.md`/`AGENTS.md` symlinks; ADR 2026-05-08). Routing is applied by the orchestrator when it fans work out — and, since spec 009, when a bounded work-order unit surfaces in any interactive turn (§6); it never re-decides who *is* running. Read on demand.

The per-model prompting levers live next door: `docs/opus-4.8-steering.md` and `docs/gpt-5.x-steering.md`. This doc answers the one question those don't: given two callable models, **which unit of work goes to which**.

---

## 1. Topology — Claude orchestrates, Codex is an executor node

**Claude is the orchestrator. Codex is a dispatchable executor node inside Claude-driven workflows and loops.**

The orchestration surface — `ultracode`, the `Workflow` tool, `/loop` / `/goal`, the fan-out → verify → synthesize discipline — is owned by Claude **as a policy choice, not a capability absence**. Codex-native multi-agent orchestration now exists and was re-checked 2026-07-10 on source evidence (`openai/codex` @ rust-v0.144.0) — answering the spec 011 D4(d) topology question ahead of the D7 Phase-B sweep, which remains predicate-gated: `ultra` is a **harness mode, not a deeper model tier** — the API request sends `max` effort (`client.rs` maps `Ultra => Max`) while the harness injects a proactive-delegation developer message that authorizes the model to spawn subagents on its own judgment (CLI default: 4 concurrent threads/session = main + 3 subagents; the catalog reports `multi_agent_version: v2` on sol/terra). That delegation is prompt-nudged and non-deterministic — no orchestration script, no visibility into subagent disagreement, not resumable mid-task — where Claude's dynamic workflow writes an inspectable deterministic script with verify gates, loop-safety budgets, and review gates. So orchestration stays on the Claude side, now on capability evidence as well as policy; `ultra` is a per-unit *depth* tier Claude may dispatch, never a competing orchestration surface. Safety note (system card + METR + source): the injected ultra instruction explicitly voids earlier "don't spawn subagents without being asked" rules — an instruction-override pattern stacked on Sol's documented overreach record, which is an independent reason ultra never runs unattended in recipes or on the sandboxless hatch. "Prioritize dynamic workflows / ultracode / loops" and "use Codex in our loops and workflows" therefore remain the **same** requirement: the loop belongs to Claude, and Codex is one worker *type* it dispatches to. A Codex unit is a stage inside a Claude workflow, not a peer loop.

This is a topology, not an identity check. Nothing here reads "if Claude, do X; if Codex, do Y." The orchestrator routes; the executor executes.

## 2. Routing policy — work-type → model

> **Stale-on-launch banner (2026-07-09):** the figures below are pre-5.6 (5.5-era); re-ground pending under spec 011 Phase B. Predicate: ≥2 independent non-OpenAI evaluations of SWE-bench-Pro-class or blind-review-class quality, directionally concordant; expiry 2026-08-15 (then sweep anyway, log the shortfall).

The consensus splits cleanly by strength. **Claude** wins on quality, review, planning, and hard reasoning; **Codex** wins on speed, autonomy, token cost, and background/async execution. Concrete signals:

- **Hard reasoning:** SWE-bench Pro **64.3%** (Claude) vs **58.6%** (Codex).
- **Code review, blind:** cleaner result **67%** (Claude) vs **25%** (Codex).
- **Token cost:** Codex is **~3–4× cheaper per task**; one Express refactor ran **$155** (Claude) vs **$15** (Codex).
- **Broad coding parity:** SWE-bench Verified **87.6%** (Claude) vs **88.7%** (Codex) — near-tied, so this axis does *not* drive routing; the deltas above do.

These figures re-ground on any major model launch or pricing change — re-run the consensus research (community + benchmark sweep, same method as the figures above) and update this table with sources; never hand-edit on launch-day claims. The re-check includes whether §1's "no equivalent orchestration surface" claim still holds. (This instance automates the trigger via its ai-dev-trends adopt loop; forks without it run the sweep manually.)

Default routing (a starting policy, tunable per project):

| Work unit | Route to | Why |
|---|---|---|
| Planning, spec, architecture, `analyze` gate | **Claude** (xhigh) | reasoning edge + downstream-shape sensitivity — a shallow plan is the most expensive place to under-think |
| Code review / adversarial verify | **Claude** (xhigh) | blind-review quality edge (67 vs 25); already the `code-review-subagent` owner |
| Large bounded implementation, mechanical refactor across many files | **Codex** (xhigh, `--write`, often `--background`) | token-cost + autonomy edge on the expensive bulk |
| Long-running / async execution units in a fan-out | **Codex** (`--background`) | detached worker + job-control |
| Second-opinion / diversity pass on a hard finding | **the other model** | cross-model diversity beats self-redundancy in a verify panel |
| Synthesis, final merge decision, orchestration itself | **Claude** | owns the workflow; merges the verdicts |

**Economics — both legs are metered; two quota pools beat one.** Codex bills per token (since 2026-04) and Claude automation draws from metered credit pools (since 2026-06), so the argument is not price-plan arbitrage — neither leg is free. With both subscriptions running, the operator holds two independent quota pools: the token-expensive bulk goes to the leg with the cost edge and the headroom (today, Codex — ~3–4× cheaper per task); the quality-sensitive minority (planning, review, synthesis) stays on the orchestrator. Balance stays structural, not a quota — the split of work is the split of spend, no per-run accounting needed to keep it honest.

The "second-opinion → **the other model**" row is deliberately model-neutral: whichever model produced the finding, the diversity pass goes to the one that didn't. That is the routing intent, expressed without a per-harness branch.

## 3. Effort — set per unit at dispatch

The orchestrator picks `--effort` when it *dispatches* a unit, the same way it picks the model — matched to unit complexity, not blanket. Blanket xhigh over-thinks mechanical work orders: slower and quota-hungrier for zero quality gain.

**Operating band** — on the operator's pinned Codex model, `gpt-5.6-sol` (current pin — verified by the codex-executor preflight, never assumed):

- **xhigh** — the sole band tier while the suspension below holds: hard debugging, design-adjacent edits, verify/second-opinion passes, standard bounded implementation, and mechanical bulk.

> **Operator directive 2026-07-10 — `medium` and `high` SUSPENDED.** Permitted Codex tiers are **xhigh and max only** right now. Dispatch validation (recipe enums, the codex-worker input check) rejects medium/high. Work that previously routed at medium/high dispatches at xhigh or routes to Claude. Temporary; revert by restoring the two band lines (`high` — standard bounded implementation from a frozen spec; `medium` — mechanical bulk: renames, migrations, coverage fills, dep bumps) and the matching recipe/worker enums (ledger row in `follow-ups.md`).

**Explicit effort or error.** Every Codex unit declares its effort at dispatch; an omitted effort field is a validation error, never a default. Workflow recipes (`.wf.js`) take required per-unit effort (spec 011).

**Exception tiers** — above the band, opt-in per unit:

- **`max`** — very difficult single-agent units.
- **`ultra`** — very difficult units that genuinely decompose. Mechanism (source-verified 2026-07-10): ultra sends `max` effort on the wire plus a proactive-delegation prompt — subagent count is the model's choice, bounded by the CLI's `features.multi_agent_v2.max_concurrent_threads_per_session` (default 4 = main + 3 subagents; CLI warns at ≥8). Sol and terra only (`multi_agent_version: v2`); luna caps at max.

Both require a named justification logged in the dispatch receipt, are never a default anywhere, and are invocable only where the preflight proves the installed surface supports them. **Surface reality (verified 2026-07-10):** companion v1.0.5 rejects everything above xhigh — so max and ultra are **Bash-direct only** (`codex exec --json -c model_reasoning_effort="<tier>"`; `codex exec` has no effort flag). Recipes dispatch through codex-worker → companion, so a recipe-declared `max` fails closed at the D6 preflight and degrades to Claude until the companion catches up — working as designed, now documented. Per-run token telemetry for Bash-direct dispatch comes from the `--json` stream (`token_count` / `turn.completed` usage events).

**Ultra status (2026-07-10): D4a prerequisites SATISFIED — unlocked for ATTENDED Bash-direct dispatch, still locked in recipes and all unattended contexts.** The three D4a prerequisites now exist: (1) per-run telemetry via the `turn.completed` usage events in the `codex exec --json` stream (the only usage-bearing event observed in the receipts); (2) ×4 concurrency accounting in `core-rules/loop-safety.md`, anchored to the CLI's default 4-thread session cap; (3) one instrumented paired run with recorded spend (same decomposable work order, xhigh vs ultra: input 134,508 → 258,359 = 1.92×, output 2,553 → 3,524 = 1.38×, reasoning 953 → 1,994 = 2.09×; multi-agent machinery engaged — three `collab_tool_call` wait events and files written with no parent-visible `file_change` items; subagent threads are not itemized in the stream; receipts in `docs/adr/2026-07-10-sol-ultra-capability-reground.md`). Measured spend sits inside the ×4 structural cap. **Ultra is therefore dispatchable as an exception tier from an attended main-loop turn only** — the operator is present in the session that dispatches it. Never from `/loop`, a scheduled task, a `.wf.js` recipe, any workflow agent (a Workflow agent holding Bash must never invoke `codex exec` itself — dispatch is the orchestrator's, through codex-worker), or the sandboxless hatch: ultra's injected instruction-override plus Sol's overreach record is exactly the unattended compound the system card warns about. Dispatch form: `codex exec --json -c model_reasoning_effort="ultra" -c model_max_output_tokens=<N> ... </dev/null`, with a declared per-unit token ceiling checked against the `turn.completed` usage in the receipt — a breach halts further ultra dispatch for the run. Justification + receipts required, never a default. **Recipes keep the hard-reject**, for two reasons that survive D4a: the recipe dispatch surface (codex-worker → companion) physically caps at xhigh, and ultra's prompt-nudged delegation is invisible/non-resumable inside a deterministic workflow (§1). Reported usage is **parent-thread-only — source-verified 2026-07-10** (codex-rs @ rust-v0.144.0: child threads are separate Sessions whose usage never feeds the parent's totals, and exec filters `ThreadTokenUsageUpdated` to the primary thread id, so child usage never even reaches the JSONL): true ultra cost is strictly higher than reported; per-child usage is recoverable only from each child thread's own rollout.

**Receipts** carry `effort` + `justification` on every result.

**Escape hatch:** max/ultra are forbidden on the sandboxless escape hatch, and no automated recipe may use the hatch (sandbox posture — spec 011 D5b; mechanics in `core-rules/skills/orchestrate/references/codex-executor.md`).

(The Claude *session* default stays xhigh via `core-rules/templates/claude-settings.json`; the ladder governs the explicit effort the orchestrator places in each `codex-worker` work order or Bash-direct dispatch.)

- **Claude** has session-only levels **above** xhigh — `max` and `ultracode` — reachable per-session via `/effort` when a task warrants it (they over-think if applied blindly; test first).

## 4. Presence + degrade contract

Codex is a **runtime-detected capability**, exactly like the Workflow-tool capability gate — never a hard dependency. The `openai-codex` plugin is not part of Trellis and cannot ship to the public mirror, so every degrade path must land on Claude.

- **Presence gate:** `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json` → check `ready`, `codex.available`, `auth.loggedIn`. If any is false or missing, Codex routing is **off** and every unit runs on Claude. The framework still works, just single-family.
- **No quota API, so failure == limit.** There is no rate-limit surface in the plugin. For routing this is moot: a limit-hit and a task failure are the **same signal**. A null or error result from a `codex-companion task` is a degrade trigger — the workflow stage **re-dispatches that same unit to Claude**. Design the executor-node wrapper so a null/error Codex result transparently falls through to a Claude dispatch for the identical unit. Never promise a quota dashboard.
- **`log()` the degrade** so a run that silently became Claude-only is visible (no-silent-caps discipline).

Quality is not laundered by routing to Codex: every Codex unit's output flows back into Claude's `code-review-subagent` / verify gate, and the bright-line guardrails (destructive-op, external-message, secrets, DoD receipts) fire on Codex units too.

## 4.5 Dispatch mechanics — the tracked wrapped path is canonical

**There is no wrapper-free way to run Codex as a native agent, and that is fine — the blocking worker path is the one to prefer.** Claude Code's scheduler spawns Claude-backed agent profiles, so a Codex unit reaches the runtime through the inherited `codex-worker` driver. That driver launches `codex-companion.mjs`, polls from the same cwd, and returns only a terminal result. This is what makes a Codex unit a **first-class, harness-tracked, blocking node** in a workflow.

Two mechanics, and the **default is (ii)**:

- **(ii) In-workflow blocking dispatch — CANONICAL.** From inside a dynamic Workflow, dispatch Codex as `agent(prompt, { agentType: 'codex-worker' })`, with explicit effort in the work order and `isolation:'worktree'` only when the unit conflicts. The worker owns companion launch, same-cwd polling, bounded stall recovery, terminal `result`, and diff-stat receipt. The node does not resolve with a job handle. Recipes keep a defensive handle assertion and degrade the identical unit to Claude if that blocking contract is ever violated.
- **(i) Bash-direct from the MAIN loop — fallback + interactive rescue.** From a `/loop`, a scheduled task, or the main orchestrator thread (where you hold `Bash`), call `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort <tier> "<prompt>"` (tier from §3 — declared per unit, never defaulted) directly. The companion accepts up to xhigh (v1.0.5); the **exception tiers (max/ultra) use raw exec instead**: `codex exec --json -c model_reasoning_effort="<max|ultra>" ... </dev/null` — and ultra is additionally restricted to attended turns per §3 (never `/loop` or scheduled tasks, despite this mechanic being reachable from them). Use this when no Workflow tool is available, for the presence probe, or for a human-managed detached rescue. The legacy `codex-rescue` forwarder is **interactive-rescue-only**; its fire-and-forget behavior is never a producing Workflow path.

The table's `--background` rows (§2) are the (i) Bash-direct interactive mechanic. Inside a workflow, the same work blocks through `codex-worker` via (ii).

## 5. Where this is enforced

This doc is the durable intent. It is *carried* by two capability-gated surfaces, neither of which branches on harness identity:

- **The `orchestrate` skill** (`core-rules/skills/orchestrate/SKILL.md`) — capability-gated on "does my harness expose a subagent-coordination tool?", not on identity. Its cross-harness recipe injects the routing above (model, effort, `--write`/`--background`) and the degrade fallback.
- **A model-neutral capability clause in `CLAUDE.md`** — "when orchestrating and a Codex executor is available, route execution-heavy bounded units to it; keep planning/review/synthesis on the orchestrator." Phrased as a capability the orchestrator may have, never as "if you are Codex."

As of spec 009, both surfaces cover **interactive units** too (§6) — bounded work-order units route from any turn, not only from orchestrated fan-outs.

If a future revision re-tunes the split, it lands here next to the table, sourced to the evidence rather than to model recall.

## 6. Interactive delegation — bounded work orders from any turn

Until 009, this doc lit up only inside orchestrated fan-outs: a plain interactive turn — "fix this bug", "implement this from the plan" — ran 100% on the orchestrator even when the unit fit the Codex row in §2. Widened: **any bounded work-order implementation unit may route to an available executor node, from any turn.** The executor leg is whichever cheap leg fits — pick by unit type first, quota headroom second:

| Leg | Available? | Dispatch | Isolation | Resume | Failure + degrade | Cost |
|---|---|---|---|---|---|---|
| **Codex** | `setup --json` → `ready` / `codex.available` / `auth.loggedIn` (§4) | companion `task --write --effort <ladder>` (≤ xhigh); max/ultra via raw `codex exec --json -c model_reasoning_effort=... </dev/null` (§3) | workspace-write sandbox; sandboxless escape hatch (seeded worktree only — **this leg only**; max/ultra forbidden) | thread id captured at dispatch (`--json`); follow-up via `codex exec resume <thread-id>` (companion `--resume`/`--resume-last` is latest-only — safe only with one unit in flight per checkout) | empty/error result ⇒ re-dispatch to Claude, logged (§4) | `codex_usd_per_mtok` |
| **Claude worker** | always — native subagent/teammate spawn | Agent/teammate spawn, harness-tracked | harness sandbox + permission system | message the live thread | native failure surfaces; unit stays in-family | session budget |

No new plumbing — every column names a mechanic that already exists per leg.

**Teardown (Claude-worker leg).** A companion-dispatched Codex unit exits with its process; a **named Claude teammate does not** — it stays live (pane + budget) until released. After the review gate passes (or the unit is abandoned), the orchestrator sends the graceful shutdown signal (`shutdown_request` via `SendMessage`), force-stops on no acknowledgment (`TaskStop`), and only then counts the unit closed. See the teammate-teardown section of the `orchestrate` skill and the *Definition of done* teammate clause in `core-rules/CLAUDE.md`.

**Route predicate.** Delegate when the prompt reads as a **work order**: frozen spec, known repro, mechanical refactor, test/coverage fill, dep bump. Keep home when any of:

- **writing the spec IS the work** — ambiguity is design, and design stays on the orchestrator;
- **tiny edit** — ~<20 changed lines, single obvious change (soft judgment aid for delegation overhead; never a substitute for the 006 pipeline gates);
- **session tools needed** — MCP, browser, secrets;
- **bright line** — destructive/irreversible ops, releases, pushes, external messages stay on the orchestrator per existing guardrails.

**Review of executor output is never delegated to the executor that produced the diff, and never skipped** — cross-agent review inside recipes is legitimate; self-review by the producing executor is what's banned. The diff reads like a contributor PR, proof demanded; §4's review gate fires verbatim. Rationale, stated boundedly: the 5.6 system card reports increased agentic-coding overreach vs 5.5 (most pronounced at highest reasoning effort under persistence-heavy prompts) alongside a ~30% *decrease* in misrepresented completions in simulated traffic, and METR reports its highest detected ReAct-harness cheating rate, explicitly prompt/scaffold-dependent. Two failed rounds on the same unit ⇒ stop delegating, take it over directly, log the takeover.

**Posture: advisory-first pilot.** Propose delegation on qualifying units; the operator accepts or declines; the predicate gets tuned against real calls before flipping to auto (a one-line doctrine edit, logged). Ledger + flip criteria: `specs/009-interactive-codex-delegation/pilot-ledger.md`. **Volume:** with Sol quota headroom the pilot **proposes delegation more aggressively** on qualifying units — more bulk at explicitly-declared xhigh (medium/high suspended per §3, 2026-07-10); flip criteria unchanged (≥10 units / ≥70% acceptance / 0 incidents). Token-efficiency framing stays bounded: the "54%" figure is a community-relayed single claim — treat as directional until Phase B.

**Mechanics live in one place:** `core-rules/skills/orchestrate/references/codex-executor.md` — prompt contract, dispatch + tracking receipt, resume, takeover signals, network preflight, escape hatch. This section does not restate them. Presence gate + degrade contract are §4's, verbatim; delegated units draw the same per-model budgets (`core-rules/loop-safety.md`) and face the same bright-lines as inline work.
