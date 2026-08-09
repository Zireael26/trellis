# Cross-model strength routing — steering reference

Source: the July-2026 community + benchmark consensus on Claude/Opus vs Codex/GPT-5.x (last30days engine + web search, distilled to the figures below), not model recall. This doc carries the **work-type → model** routing policy as durable steering **intent** for Trellis's dual-harness setup. It is not a rule that branches on which harness is running — the load-bearing rules live in `core-rules/CLAUDE.md`, `core-rules/autonomy.md`, `core-rules/loop-safety.md`, and the hooks, and they steer every harness **identically** (byte-identical `CLAUDE.md`/`AGENTS.md` symlinks; ADR 2026-05-08). Routing is applied by the orchestrator when it fans work out — and, since spec 009, when a bounded work-order unit surfaces in any interactive turn (§6); it never re-decides who…

The per-model prompting levers live next door: `docs/claude-steering.md` and `docs/gpt-5.x-steering.md`. This doc answers the one question those don't: given two callable models, **which unit of work goes to which**.

---

## Current status — generic Codex CLI and the optional legacy plugin

The Codex executor surface is dispatchable in two forms. **Generic Codex CLI
harness support** — `AGENTS.md`, `.agents/`, `.codex/` hooks, and deliberate
direct `codex exec` use — is supported and independent of any plugin. The
`codex-worker`, `codex-companion.mjs`, `$CODEX_PLUGIN`, and `codex-rescue`
mechanics retained below are **optional legacy compatibility** for operators who
explicitly install and select the OpenAI Codex plugin path. They are not a
required project inheritance surface and never become an implicit fallback from
an explicit selection. A rejected, unavailable, or failed explicit provider
selection stays visible and fails closed unless the operator explicitly chooses
another lane.

The older benchmark evidence and companion mechanics below remain as historical
steering and a legacy operator reference.

## 1. Topology — Claude orchestrates, Codex executors are dispatchable nodes

**Claude is the orchestrator. Deliberate direct Codex CLI execution and the optional legacy plugin companion are the dispatchable executor nodes inside Claude-driven workflows and loops.**

The orchestration surface — `ultracode`, the `Workflow` tool, `/loop` / `/goal`, the fan-out → verify → synthesize discipline — is owned by Claude **as a policy choice, not a capability absence**. Codex-native multi-agent orchestration now exists and was re-checked 2026-07-10 on source evidence (`openai/codex` @ rust-v0.144.0) — answering the spec 011 D4(d) topology question ahead of the D7 Phase-B sweep, which remains predicate-gated: `ultra` is a **harness mode, not a deeper model tier** — the API request sends `max` effort (`client.rs` maps `Ultra => Max`) while the harness injects a proactive-delegation developer message that authorizes the model to spawn subagents on its own judgment (CLI default: 4 concurrent threads/session = main + 3 subagents; the c…

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
| Bounded implementation with useful tests; mechanical refactor with a strong oracle | **Codex executor** (`codex exec`, deliberate direct CLI; effort per §3) | token-cost + autonomy edge on the expensive bulk |
| Long-running / async execution units in a fan-out | **Codex executor** matched to consequence level; direct Codex CLI only when explicitly selected | executor parallelism or deliberate detached job control |
| Second-opinion / diversity pass on a hard finding | **the other model** | cross-model diversity beats self-redundancy in a verify panel |
| Synthesis, final merge decision, orchestration itself | **Claude** | owns the workflow; merges the verdicts |

**Economics — both legs are metered; two quota pools beat one.** Codex bills per token (since 2026-04) and Claude automation draws from metered credit pools (since 2026-06), so the argument is not price-plan arbitrage — neither leg is free. With both subscriptions running, the operator holds two independent quota pools: the token-expensive bulk goes to the leg with the cost edge and the headroom (today, Codex — ~3–4× cheaper per task); the quality-sensitive minority (planning, review, synthesis) stays on the orchestrator. Balance stays structural, not a quota — the split of work is the split of spend, no per-run accounting needed to keep it honest.

The "second-opinion → **the other model**" row is deliberately model-neutral: whichever model produced the finding, the diversity pass goes to the one that didn't. That is the routing intent, expressed without a per-harness branch.

## 3. Effort — set per unit at dispatch

Every deliberate direct Codex CLI or optional legacy `codex-worker` unit declares its effort at dispatch; the orchestrator sets `--effort` explicitly. Blanket xhigh over-thinks mechanical work orders: slower and quota-hungrier for zero quality gain.

**Operating band** — on the operator's pinned Codex model, `gpt-5.6-sol` (current pin — verified by the codex-executor preflight, never assumed):

- **medium** — mechanical or frozen-scope work with a strong oracle: renames, migrations, coverage fills, dependency bumps, and bounded implementation whose tests or compiler make correctness cheap to check.
- **high** — moderately complex cross-file work with useful tests or diagnostics: implementation that needs broader context or judgment but still has a strong verification path.
- **xhigh** — weak-oracle debugging, security-sensitive work, difficult design, or high-consequence implementation where missed edge cases matter more than latency.

This ladder supersedes the temporary 2026-07-10 `xhigh`-only operating-band suspension. Dispatch validators accept the three band tiers only. **`max` is hard-rejected in every recipe as of 2026-07-30** — above `xhigh` these models spend substantially more reasoning for very little gain, so `xhigh` is the ceiling (`core-rules/references/model-routing.md` § Effort). It was previously admitted with a named justification; a justification no longer admits it. Explicit effort remains mandatory.

**Explicit effort or error.** Every direct Codex CLI or optional legacy `codex-worker` unit declares effort at dispatch. An omitted required effort is a validation error, never a default. Legacy plugin-specific Workflow recipes (`.wf.js`) retain their required per-unit effort contract (spec 011).

**Exception tiers** — above the band, opt-in per unit:

- **`max`** — **retired 2026-07-30.** Hard-rejected by all four dispatch validators
  (`verify-panel`, `codex-executor`, `codex-fanout`, `fleet-audit-remediation`). Retained
  here only so the ladder's history reads correctly; it is not selectable.
- **`ultra`** — very difficult units that genuinely decompose. Mechanism (source-verified 2026-07-10): ultra sends `max` effort on the wire plus a proactive-delegation prompt — subagent count is the model's choice, bounded by the CLI's `features.multi_agent_v2.max_concurrent_threads_per_session` (default 4 = main + 3 subagents; CLI warns at ≥8). Sol and terra only (`multi_agent_version: v2`); luna caps at max.

`ultra` requires a named justification logged in the dispatch receipt, is never a default anywhere, and is invocable only where the preflight proves the installed surface supports it. `max` no longer has an admitting path at all.

**Ultra status (2026-07-10): D4a prerequisites SATISFIED — unlocked for ATTENDED Bash-direct dispatch, still locked in recipes and all unattended contexts.** The three D4a prerequisites now exist: (1) per-run telemetry via the `turn.completed` usage events in the `codex exec --json` stream (the only usage-bearing event observed in the receipts); (2) ×4 concurrency accounting in `core-rules/loop-safety.md`, anchored to the CLI's default 4-thread session cap; (3) one instrumented paired run with recorded spend (same decomposable work order, xhigh vs ultra: input 134,508 → 258,359 = 1.92×, output 2,553 → 3,524 = 1.38×, reasoning 953 → 1,994 = 2.09×; multi-agent machinery engaged — three `collab_tool_call` wait events and files written with no parent-visible `fi…

**Receipts** carry `effort` + `justification` on every result.

**Escape hatch:** max/ultra are forbidden on the sandboxless escape hatch, and no automated recipe may use the hatch (sandbox posture — spec 011 D5b; mechanics in `core-rules/skills/orchestrate/references/codex-executor.md`).

(The Claude *session* default is governed by `docs/claude-steering.md` §1, which is canonical for Claude effort posture and is where the number and its scoping live; `core-rules/templates/claude-settings.json` enacts it.)

- **Claude** has session-only effort settings the `effortLevel` setting will not take — `max` and `ultracode` — reachable per-session via `/effort` when a task warrants it (`max` over-thinks if applied blindly; test first). `ultracode` is not a level above `xhigh`: it sends `xhigh` and additionally has Claude orchestrate dynamic workflows for substantive tasks (verified 2026-07-25, `code.claude.com/docs/en/model-config`).

## 4. Optional legacy plugin presence + fail-closed contract

The OpenAI Codex plugin companion is an **optional runtime-detected legacy
capability**, never a hard dependency. It is not part of Trellis and cannot ship
to the public mirror. Probe it only after the operator explicitly selects that
route; absence never disables generic Codex CLI harness support.

- **Legacy presence gate:** `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json` → check `ready`, `codex.available`, `auth.loggedIn`. If any is false or missing, the selected legacy lane is unavailable and the unit fails closed with that receipt.
- **No quota API, so failure == limit.** There is no rate-limit surface in the plugin. A limit hit, null, or task error is the same visible legacy-lane failure. Do not transparently re-dispatch the unit to Claude or another provider; a new lane requires an explicit caller/operator selection.
- **`log()` the failure** with the selected lane and attempted unit so an unavailable legacy route cannot look like success or silent single-family execution.

Quality is not laundered by executor routing: every successful unit flows back into the orchestrator's review gate, and the bright-line guardrails (destructive-op, external-message, secrets, DoD receipts) fire on direct Codex CLI and legacy plugin units alike.

## 4.5 Optional legacy plugin companion dispatch mechanics

The blocking worker mechanics below are retained only for an operator who
explicitly installed and selected the legacy plugin companion. In that route,
`codex-worker` launches `codex-companion.mjs`, polls from the same cwd, and
returns only a terminal result.

- **(ii) In-workflow blocking dispatch — legacy plugin only.** From inside a dynamic Workflow, dispatch `agent(prompt, { agentType: 'codex-worker' })` only after the operator selected/configured that route, with explicit effort in the work order and `isolation:'worktree'` only when the unit conflicts. The worker owns companion launch, same-cwd polling, bounded stall recovery, terminal `result`, and diff-stat receipt. The node does not resolve with a job handle. A violated blocking contract fails the selected lane; it does not silently degrade to another provider.
- **(i) Bash-direct legacy companion or deliberate generic CLI use.** The plugin-specific form is `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort <tier> "<prompt>"`. Deliberate generic CLI dispatch may instead use `codex exec --json -c model_reasoning_effort="<tier>" ... </dev/null` without the plugin; max/ultra restrictions from §3 still apply. The legacy `codex-rescue` forwarder is **interactive-rescue-only**; its fire-and-forget behavior is never a producing Workflow path.

The historical `--background` rows (§2) describe explicit direct execution. Inside a
legacy plugin-backed Workflow, the same work blocks through `codex-worker`; inside
a generic Codex-CLI Workflow, dispatch the direct CLI route instead.

## 5. Where this is enforced

This doc is the durable intent. It is *carried* by two capability-gated surfaces, neither of which branches on harness identity:

- **The `orchestrate` skill** (`core-rules/skills/orchestrate/SKILL.md`) — capability-gated on "does my harness expose a subagent-coordination tool?", not on identity. Legacy `codex-worker` recipes run only after explicit operator selection/configuration and fail their selected lane closed.
- **A model-neutral capability clause in `CLAUDE.md`** — when orchestrating, route bounded execution-heavy units to an available executor while planning/review/synthesis stay on the orchestrator and explicit provider selections are preserved. Phrased as capabilities the orchestrator may have, never as an identity branch.

As of spec 009, both surfaces cover **interactive units** too (§6) — bounded work-order units route from any turn, not only from orchestrated fan-outs.

If a future revision re-tunes the split, it lands here next to the table, sourced to the evidence rather than to model recall.

## 6. Interactive delegation — bounded work orders from any turn

Until 009, this doc lit up only inside orchestrated fan-outs: a plain interactive turn — "fix this bug", "implement this from the plan" — ran 100% on the orchestrator even when the unit fit an executor row in §2. Widened: **any bounded work-order implementation unit may route to an available executor node, from any turn.** Pick the leg by unit type and explicit provider policy first, then capability and quota headroom:

| Leg | Available? | Dispatch | Isolation | Resume | Failure | Cost |
|---|---|---|---|---|---|---|
| **Direct Codex CLI** | operator explicitly selects an installed, authenticated `codex` CLI | deliberate `codex exec --json ...`; no plugin required | Codex workspace sandbox; escape-hatch restrictions still apply | `codex exec resume <thread-id>` when captured | CLI failure stays on the selected lane and fails closed | `codex_usd_per_mtok` |
| **Legacy plugin companion** | operator selected/configured it and `setup --json` reports `ready`, `codex.available`, `auth.loggedIn` (§4) | companion `task --write --effort <ladder>` or blocking `codex-worker` | companion workspace sandbox | companion/Codex thread resume limits apply | null/error is a visible legacy-lane failure; no implicit provider substitution | `codex_usd_per_mtok` |
| **Claude worker** | permitted native subagent/teammate spawn | Agent/teammate spawn, harness-tracked | harness sandbox + permission system | message an intentionally named live thread | native failure surfaces; unit stays in-family | session budget |

Every row names an existing mechanic; none authorizes a router to rewrite an explicit provider selection.

**Teardown.** Direct-result Agents and companion-dispatched legacy units exit with their call/process. An intentionally named teammate stays live until the root calls `TaskStop` in the same turn that accepts, supersedes, fails, or abandons its work. See the teammate-teardown section of the `orchestrate` skill and the *Definition of done* teammate clause in `core-rules/CLAUDE.md`.

**Route predicate.** Delegate when the prompt reads as a **work order**: frozen spec, known repro, mechanical refactor, test/coverage fill, dep bump. Keep home when any of:

- **writing the spec IS the work** — ambiguity is design, and design stays on the orchestrator;
- **tiny edit** — ~<20 changed lines, single obvious change (soft judgment aid for delegation overhead; never a substitute for the 006 pipeline gates);
- **session tools needed** — MCP, browser, secrets;
- **bright line** — destructive/irreversible ops, releases, pushes, external messages stay on the orchestrator per existing guardrails.

**Review of executor output is never delegated to the executor that produced the diff, and never skipped** — cross-agent review inside recipes is legitimate; self-review by the producing executor is what's banned. The diff reads like a contributor PR, proof demanded; §4's review gate fires verbatim. Rationale, stated boundedly: the 5.6 system card reports increased agentic-coding overreach vs 5.5 (most pronounced at highest reasoning effort under persistence-heavy prompts) alongside a ~30% *decrease* in misrepresented completions in simulated traffic, and METR reports its highest detected ReAct-harness cheating rate, explicitly prompt/scaffold-dependent. Two failed rounds on the same unit ⇒ stop delegating, take it over directly, log the takeover.

**Posture: advisory-first pilot.** Spec 009 established the bounded work-order predicate and its ledger (`specs/009-interactive-codex-delegation/pilot-ledger.md`). Qualifying Codex units use the effort band in §3. Explicit provider locks remain authoritative; pilot history never authorizes an automatic plugin fallback. Token-efficiency framing stays bounded: the "54%" figure is a community-relayed single claim — treat as directional until Phase B.

**Mechanics:** optional legacy companion details remain in `core-rules/skills/orchestrate/references/codex-executor.md` for operators who selected/configured that path. Delegated units draw the same per-model budgets (`core-rules/loop-safety.md`) and face the same bright-lines as inline work.
