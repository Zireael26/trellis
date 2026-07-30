# Cross-model strength routing — steering reference

Source: the July-2026 community + benchmark consensus on Claude/Opus vs Codex/GPT-5.x (last30days engine + web search, distilled to the figures below), not model recall. This doc carries the **work-type → model** routing policy as durable steering **intent** for Trellis's dual-harness setup. It is not a rule that branches on which harness is running — the load-bearing rules live in `core-rules/CLAUDE.md`, `core-rules/autonomy.md`, `core-rules/loop-safety.md`, and the hooks, and they steer every harness **identically** (byte-identical `CLAUDE.md`/`AGENTS.md` symlinks; ADR 2026-05-08). Routing is applied by the orchestrator when it fans work out — and, since spec 009, when a bounded work-order unit surfaces in any interactive turn (§6); it never re-decides who *is* running. Read on demand.

The per-model prompting levers live next door: `docs/claude-steering.md` and `docs/gpt-5.x-steering.md`. This doc answers the one question those don't: given two callable models, **which unit of work goes to which**.

---

## Current status — GPTX supersedes plugin-companion delegation

As of 2026-07-29, GPTX exposes wrapper-free native GPT Agent profiles directly
through Claude Code's Agent and Workflow surfaces. When that capability is
available, `gpt-mid`, `gpt-high`, `gpt-sol`, and `gpt-terra` are the canonical GPT
executor identities for bounded units; current setup, provider enforcement, and
profile semantics live in [`docs/gptx.md`](gptx.md).

The `codex-worker`, `codex-companion.mjs`, `$CODEX_PLUGIN`, and `codex-rescue`
mechanics retained below are **optional legacy compatibility** for operators who
explicitly install and select the OpenAI Codex plugin path. They are not a
required project inheritance surface and never become an implicit fallback from
a native GPT lane. A rejected, unavailable, or failed explicit provider selection
stays visible and fails closed unless the operator explicitly chooses another
lane. Generic Codex CLI harness support — `AGENTS.md`, `.agents/`, `.codex/` hooks,
and deliberate direct `codex exec` use — remains supported and is not superseded.

The older benchmark evidence and companion mechanics below remain as historical
steering and a legacy operator reference; where they conflict with this status
section or `docs/gptx.md`, the current GPTX contract wins.

## 1. Topology — Claude orchestrates, GPT executors are dispatchable nodes

**Claude is the orchestrator. With GPTX available, native GPT Agent profiles are the canonical dispatchable executor nodes inside Claude-driven workflows and loops. Generic Codex CLI execution and the optional legacy plugin companion remain explicit operator-selected routes.**

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
| Bounded implementation with useful tests; mechanical refactor with a strong oracle | **Native GPT Agent** (`gpt-mid` for frozen/mechanical scope; `gpt-high` for moderately complex cross-file work) | token-cost + autonomy edge on the expensive bulk |
| Long-running / async execution units in a fan-out | **Native GPT Agent** matched to consequence level; direct Codex CLI only when explicitly selected | executor parallelism or deliberate detached job control |
| Second-opinion / diversity pass on a hard finding | **the other model** | cross-model diversity beats self-redundancy in a verify panel |
| Synthesis, final merge decision, orchestration itself | **Claude** | owns the workflow; merges the verdicts |

**Economics — both legs are metered; two quota pools beat one.** Codex bills per token (since 2026-04) and Claude automation draws from metered credit pools (since 2026-06), so the argument is not price-plan arbitrage — neither leg is free. With both subscriptions running, the operator holds two independent quota pools: the token-expensive bulk goes to the leg with the cost edge and the headroom (today, Codex — ~3–4× cheaper per task); the quality-sensitive minority (planning, review, synthesis) stays on the orchestrator. Balance stays structural, not a quota — the split of work is the split of spend, no per-run accounting needed to keep it honest.

The "second-opinion → **the other model**" row is deliberately model-neutral: whichever model produced the finding, the diversity pass goes to the one that didn't. That is the routing intent, expressed without a per-harness branch.

## 3. Effort — set per unit at dispatch

For native GPTX Agents, the orchestrator selects the profile whose declared effort matches the unit. For deliberate direct Codex CLI or optional legacy companion dispatch, it sets `--effort` explicitly. Blanket xhigh over-thinks mechanical work orders: slower and quota-hungrier for zero quality gain.

**Operating band** — on the operator's pinned Codex model, `gpt-5.6-sol` (current pin — verified by the codex-executor preflight, never assumed):

- **medium** — mechanical or frozen-scope work with a strong oracle: renames, migrations, coverage fills, dependency bumps, and bounded implementation whose tests or compiler make correctness cheap to check.
- **high** — moderately complex cross-file work with useful tests or diagnostics: implementation that needs broader context or judgment but still has a strong verification path.
- **xhigh** — weak-oracle debugging, security-sensitive work, difficult design, or high-consequence implementation where missed edge cases matter more than latency.

This ladder supersedes the temporary 2026-07-10 `xhigh`-only operating-band suspension. Dispatch validators accept the three band tiers only. **`max` is hard-rejected in every recipe as of 2026-07-30** — above `xhigh` these models spend substantially more reasoning for very little gain, so `xhigh` is the ceiling (`core-rules/references/model-routing.md` § Effort). It was previously admitted with a named justification; a justification no longer admits it. While explicit effort remains mandatory.

**Explicit effort or error.** A native GPTX Agent type declares its effort through the selected profile; every direct Codex CLI or optional legacy `codex-worker` unit declares effort at dispatch. An omitted required effort is a validation error, never a default. Legacy plugin-specific Workflow recipes (`.wf.js`) retain their required per-unit effort contract (spec 011).

**Exception tiers** — above the band, opt-in per unit:

- **`max`** — **retired 2026-07-30.** Hard-rejected by all four dispatch validators
  (`verify-panel`, `codex-executor`, `codex-fanout`, `fleet-audit-remediation`). Retained
  here only so the ladder's history reads correctly; it is not selectable.
- **`ultra`** — very difficult units that genuinely decompose. Mechanism (source-verified 2026-07-10): ultra sends `max` effort on the wire plus a proactive-delegation prompt — subagent count is the model's choice, bounded by the CLI's `features.multi_agent_v2.max_concurrent_threads_per_session` (default 4 = main + 3 subagents; CLI warns at ≥8). Sol and terra only (`multi_agent_version: v2`); luna caps at max.

`ultra` requires a named justification logged in the dispatch receipt, is never a default anywhere, and is invocable only where the preflight proves the installed surface supports it. `max` no longer has an admitting path at all.

**Ultra status (2026-07-10): D4a prerequisites SATISFIED — unlocked for ATTENDED Bash-direct dispatch, still locked in recipes and all unattended contexts.** The three D4a prerequisites now exist: (1) per-run telemetry via the `turn.completed` usage events in the `codex exec --json` stream (the only usage-bearing event observed in the receipts); (2) ×4 concurrency accounting in `core-rules/loop-safety.md`, anchored to the CLI's default 4-thread session cap; (3) one instrumented paired run with recorded spend (same decomposable work order, xhigh vs ultra: input 134,508 → 258,359 = 1.92×, output 2,553 → 3,524 = 1.38×, reasoning 953 → 1,994 = 2.09×; multi-agent machinery engaged — three `collab_tool_call` wait events and files written with no parent-visible `file_change` items; subagent threads are not itemized in the stream; receipts in `docs/adr/2026-07-10-sol-ultra-capability-reground.md`). Measured spend sits inside the ×4 structural cap. **Ultra is therefore dispatchable as an exception tier from an attended main-loop turn only** — the operator is present in the session that dispatches it. Never from `/loop`, a scheduled task, a `.wf.js` recipe, any workflow agent (a Workflow agent holding Bash must never invoke `codex exec` itself — direct CLI or optional legacy-worker dispatch remains the orchestrator's explicit choice), or the sandboxless hatch: ultra's injected instruction-override plus Sol's overreach record is exactly the unattended compound the system card warns about. Dispatch form: `codex exec --json -c model_reasoning_effort="ultra" -c model_max_output_tokens=<N> ... </dev/null`, with a declared per-unit token ceiling checked against the `turn.completed` usage in the receipt — a breach halts further ultra dispatch for the run. Justification + receipts required, never a default. **Optional legacy companion recipes keep the hard-reject**, for two reasons that survive D4a: their `codex-worker` → companion surface physically caps at xhigh, and ultra's prompt-nudged delegation is invisible/non-resumable inside a deterministic workflow (§1). Reported usage is **parent-thread-only — source-verified 2026-07-10** (codex-rs @ rust-v0.144.0: child threads are separate Sessions whose usage never feeds the parent's totals, and exec filters `ThreadTokenUsageUpdated` to the primary thread id, so child usage never even reaches the JSONL): true ultra cost is strictly higher than reported; per-child usage is recoverable only from each child thread's own rollout.

**Receipts** carry `effort` + `justification` on every result.

**Escape hatch:** max/ultra are forbidden on the sandboxless escape hatch, and no automated recipe may use the hatch (sandbox posture — spec 011 D5b; mechanics in `core-rules/skills/orchestrate/references/codex-executor.md`).

(The Claude *session* default is governed by `docs/claude-steering.md` §1, which is canonical for Claude effort posture and is where the number and its scoping live; `core-rules/templates/claude-settings.json` enacts it. The ladder here maps native GPTX profile choice and governs explicit effort on direct Codex CLI or optional legacy `codex-worker` dispatch.)

- **Claude** has session-only effort settings the `effortLevel` setting will not take — `max` and `ultracode` — reachable per-session via `/effort` when a task warrants it (`max` over-thinks if applied blindly; test first). `ultracode` is not a level above `xhigh`: it sends `xhigh` and additionally has Claude orchestrate dynamic workflows for substantive tasks (verified 2026-07-25, `code.claude.com/docs/en/model-config`).

## 4. Optional legacy plugin presence + fail-closed contract

The OpenAI Codex plugin companion is an **optional runtime-detected legacy
capability**, never a hard dependency. It is not part of Trellis and cannot ship
to the public mirror. Probe it only after the operator explicitly selects that
route; absence never disables native GPTX Agents or generic Codex CLI harness
support.

- **Legacy presence gate:** `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json` → check `ready`, `codex.available`, `auth.loggedIn`. If any is false or missing, the selected legacy lane is unavailable and the unit fails closed with that receipt.
- **No quota API, so failure == limit.** There is no rate-limit surface in the plugin. A limit hit, null, or task error is the same visible legacy-lane failure. Do not transparently re-dispatch the unit to Claude, a native GPT profile, or another provider; a new lane requires an explicit caller/operator selection.
- **`log()` the failure** with the selected lane and attempted unit so an unavailable legacy route cannot look like success or silent single-family execution.

Quality is not laundered by executor routing: every successful unit flows back into the orchestrator's review gate, and the bright-line guardrails (destructive-op, external-message, secrets, DoD receipts) fire on native GPT, direct Codex CLI, and legacy plugin units alike.

## 4.5 Optional legacy plugin companion dispatch mechanics

**GPTX now provides the wrapper-free native GPT Agent path.** A Workflow dispatches
`gpt-mid`, `gpt-high`, `gpt-sol`, or `gpt-terra` directly when that capability is
available. The blocking worker mechanics below are retained only for an operator
who explicitly installed and selected the legacy plugin companion. In that route,
`codex-worker` launches `codex-companion.mjs`, polls from the same cwd, and
returns only a terminal result.

Two legacy mechanics; neither is a default or fallback from native GPTX:

- **(ii) In-workflow blocking dispatch — legacy plugin only.** From inside a dynamic Workflow, dispatch `agent(prompt, { agentType: 'codex-worker' })` only after the operator selected/configured that route, with explicit effort in the work order and `isolation:'worktree'` only when the unit conflicts. The worker owns companion launch, same-cwd polling, bounded stall recovery, terminal `result`, and diff-stat receipt. The node does not resolve with a job handle. A violated blocking contract fails the selected lane; it does not silently degrade to another provider.
- **(i) Bash-direct legacy companion or deliberate generic CLI use.** The plugin-specific form is `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort <tier> "<prompt>"`. Deliberate generic CLI dispatch may instead use `codex exec --json -c model_reasoning_effort="<tier>" ... </dev/null` without the plugin; max/ultra restrictions from §3 still apply. The legacy `codex-rescue` forwarder is **interactive-rescue-only**; its fire-and-forget behavior is never a producing Workflow path.

The historical `--background` rows (§2) describe explicit direct execution. Inside a
legacy plugin-backed Workflow, the same work blocks through `codex-worker`; inside
a GPTX-capable Workflow, dispatch the native `gpt-*` profile instead.

## 5. Where this is enforced

This doc is the durable intent. It is *carried* by two capability-gated surfaces, neither of which branches on harness identity:

- **The `orchestrate` skill** (`core-rules/skills/orchestrate/SKILL.md`) — capability-gated on "does my harness expose a subagent-coordination tool?", not on identity. Generic Workflow units use native `gpt-*` Agent types when GPTX exposes them. Legacy `codex-worker` recipes run only after explicit operator selection/configuration and fail their selected lane closed.
- **A model-neutral capability clause in `CLAUDE.md`** — when orchestrating, route bounded execution-heavy units to an available executor while planning/review/synthesis stay on the orchestrator; prefer native GPT profiles under GPTX and preserve explicit provider selections. Phrased as capabilities the orchestrator may have, never as an identity branch.

As of spec 009, both surfaces cover **interactive units** too (§6) — bounded work-order units route from any turn, not only from orchestrated fan-outs.

If a future revision re-tunes the split, it lands here next to the table, sourced to the evidence rather than to model recall.

## 6. Interactive delegation — bounded work orders from any turn

Until 009, this doc lit up only inside orchestrated fan-outs: a plain interactive turn — "fix this bug", "implement this from the plan" — ran 100% on the orchestrator even when the unit fit an executor row in §2. Widened: **any bounded work-order implementation unit may route to an available executor node, from any turn.** Pick the leg by unit type and explicit provider policy first, then capability and quota headroom:

| Leg | Available? | Dispatch | Isolation | Resume | Failure | Cost |
|---|---|---|---|---|---|---|
| **Native GPTX Agent** | GPTX session exposes the registered Agent roster | `gpt-mid`, `gpt-high`, `gpt-sol`, or `gpt-terra` matched to §3 and `docs/gptx.md` | harness sandbox; worktree isolation when the unit conflicts | unnamed direct result, or message an intentionally named teammate | selected lane rejection/unavailability/error stays visible and fails closed | GPT subscription/session budget |
| **Direct Codex CLI** | operator explicitly selects an installed, authenticated `codex` CLI | deliberate `codex exec --json ...`; no plugin required | Codex workspace sandbox; escape-hatch restrictions still apply | `codex exec resume <thread-id>` when captured | CLI failure stays on the selected lane and fails closed | `codex_usd_per_mtok` |
| **Legacy plugin companion** | operator selected/configured it and `setup --json` reports `ready`, `codex.available`, `auth.loggedIn` (§4) | companion `task --write --effort <ladder>` or blocking `codex-worker` | companion workspace sandbox | companion/Codex thread resume limits apply | null/error is a visible legacy-lane failure; no implicit provider substitution | `codex_usd_per_mtok` |
| **Claude worker** | permitted native subagent/teammate spawn | Agent/teammate spawn, harness-tracked | harness sandbox + permission system | message an intentionally named live thread | native failure surfaces; unit stays in-family | session budget |

Every row names an existing mechanic; none authorizes the router to rewrite an explicit provider selection.

**Teardown.** Direct-result Agents and companion-dispatched legacy units exit with their call/process. An intentionally named teammate stays live until the root calls `TaskStop` in the same turn that accepts, supersedes, fails, or abandons its work. See the teammate-teardown section of the `orchestrate` skill and the *Definition of done* teammate clause in `core-rules/CLAUDE.md`.

**Route predicate.** Delegate when the prompt reads as a **work order**: frozen spec, known repro, mechanical refactor, test/coverage fill, dep bump. Keep home when any of:

- **writing the spec IS the work** — ambiguity is design, and design stays on the orchestrator;
- **tiny edit** — ~<20 changed lines, single obvious change (soft judgment aid for delegation overhead; never a substitute for the 006 pipeline gates);
- **session tools needed** — MCP, browser, secrets;
- **bright line** — destructive/irreversible ops, releases, pushes, external messages stay on the orchestrator per existing guardrails.

**Review of executor output is never delegated to the executor that produced the diff, and never skipped** — cross-agent review inside recipes is legitimate; self-review by the producing executor is what's banned. The diff reads like a contributor PR, proof demanded; §4's review gate fires verbatim. Rationale, stated boundedly: the 5.6 system card reports increased agentic-coding overreach vs 5.5 (most pronounced at highest reasoning effort under persistence-heavy prompts) alongside a ~30% *decrease* in misrepresented completions in simulated traffic, and METR reports its highest detected ReAct-harness cheating rate, explicitly prompt/scaffold-dependent. Two failed rounds on the same unit ⇒ stop delegating, take it over directly, log the takeover.

**Posture: advisory-first pilot.** Spec 009 established the bounded work-order predicate and its ledger (`specs/009-interactive-codex-delegation/pilot-ledger.md`). Under GPTX, qualifying GPT units use the native profile that declares `medium`, `high`, or `xhigh` effort according to §3. Explicit provider locks remain authoritative; pilot history never authorizes an automatic plugin fallback. Token-efficiency framing stays bounded: the "54%" figure is a community-relayed single claim — treat as directional until Phase B.

**Mechanics:** native profile and provider-policy behavior live in `docs/gptx.md`. Optional legacy companion details remain in `core-rules/skills/orchestrate/references/codex-executor.md` for operators who selected/configured that path. Delegated units draw the same per-model budgets (`core-rules/loop-safety.md`) and face the same bright-lines as inline work.
