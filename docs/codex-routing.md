# Cross-model strength routing — steering reference

Source: the July-2026 community + benchmark consensus on Claude/Opus vs Codex/GPT-5.x (last30days engine + web search, distilled to the figures below), not model recall. This doc carries the **work-type → model** routing policy as durable steering **intent** for Trellis's dual-harness setup. It is not a rule that branches on which harness is running — the load-bearing rules live in `core-rules/CLAUDE.md`, `core-rules/autonomy.md`, `core-rules/loop-safety.md`, and the hooks, and they steer every harness **identically** (byte-identical `CLAUDE.md`/`AGENTS.md` symlinks; ADR 2026-05-08). Routing is applied by the orchestrator when it fans work out; it never re-decides who *is* running. Read on demand.

The per-model prompting levers live next door: `docs/opus-4.8-steering.md` and `docs/gpt-5.x-steering.md`. This doc answers the one question those don't: given two callable models, **which unit of work goes to which**.

---

## 1. Topology — Claude orchestrates, Codex is an executor node

**Claude is the orchestrator. Codex is a dispatchable executor node inside Claude-driven workflows and loops.**

The orchestration surface — `ultracode`, the `Workflow` tool, `/loop` / `/goal`, the fan-out → verify → synthesize discipline — is owned by Claude; Codex has no equivalent orchestration surface yet. So "prioritize dynamic workflows / ultracode / loops" and "use Codex in our loops and workflows" are the **same** requirement: the loop belongs to Claude, and Codex is one worker *type* it dispatches to. A Codex unit is a stage inside a Claude workflow, not a peer loop.

This is a topology, not an identity check. Nothing here reads "if Claude, do X; if Codex, do Y." The orchestrator routes; the executor executes.

## 2. Routing policy — work-type → model

The consensus splits cleanly by strength. **Claude** wins on quality, review, planning, and hard reasoning; **Codex** wins on speed, autonomy, token cost, and background/async execution. Concrete signals:

- **Hard reasoning:** SWE-bench Pro **64.3%** (Claude) vs **58.6%** (Codex).
- **Code review, blind:** cleaner result **67%** (Claude) vs **25%** (Codex).
- **Token cost:** Codex is **~3–4× cheaper per task**; one Express refactor ran **$155** (Claude) vs **$15** (Codex).
- **Broad coding parity:** SWE-bench Verified **87.6%** (Claude) vs **88.7%** (Codex) — near-tied, so this axis does *not* drive routing; the deltas above do.

Default routing (a starting policy, tunable per project):

| Work unit | Route to | Why |
|---|---|---|
| Planning, spec, architecture, `analyze` gate | **Claude** (xhigh) | reasoning edge + downstream-shape sensitivity — a shallow plan is the most expensive place to under-think |
| Code review / adversarial verify | **Claude** (xhigh) | blind-review quality edge (67 vs 25); already the `code-review-subagent` owner |
| Large bounded implementation, mechanical refactor across many files | **Codex** (xhigh, `--write`, often `--background`) | token-cost + autonomy edge on the expensive bulk |
| Long-running / async execution units in a fan-out | **Codex** (`--background`) | detached worker + job-control |
| Second-opinion / diversity pass on a hard finding | **the other model** | cross-model diversity beats self-redundancy in a verify panel |
| Synthesis, final merge decision, orchestration itself | **Claude** | owns the workflow; merges the verdicts |

**Balance is structural, not a quota.** The token-expensive bulk (execution-heavy fan-out) lands on the cheaper, faster Codex leg; the quality-sensitive minority (planning, review, synthesis) stays on Claude. That splits *both* the work and the spend defensibly across the two families — no per-run accounting needed to keep it honest.

The "second-opinion → **the other model**" row is deliberately model-neutral: whichever model produced the finding, the diversity pass goes to the one that didn't. That is the routing intent, expressed without a per-harness branch.

## 3. Effort — both default xhigh

Both models run at **`xhigh` effort by default** (`core-rules/templates/claude-settings.json` sets `effortLevel: xhigh`; the Codex unit is dispatched with `--effort xhigh` injected, since the rescue forwarder leaves effort unset). The ceilings differ, and the difference is one-directional:

- **Claude** has session-only levels **above** xhigh — `max` and `ultracode` — reachable per-session via `/effort` when a task warrants it (they over-think if applied blindly; test first).
- **Codex tops out at xhigh. There is no `max` for Codex.** Dispatch Codex units at xhigh and do not attempt to request a higher tier.

This is a per-model capability fact, not a conditional in shared rules: the orchestrator picks the effort when it *dispatches* a unit, the same way it picks the model.

## 4. Presence + degrade contract

Codex is a **runtime-detected capability**, exactly like the Workflow-tool capability gate — never a hard dependency. The `openai-codex` plugin is not part of Trellis and cannot ship to the public mirror, so every degrade path must land on Claude.

- **Presence gate:** `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json` → check `ready`, `codex.available`, `auth.loggedIn`. If any is false or missing, Codex routing is **off** and every unit runs on Claude. The framework still works, just single-family.
- **No quota API, so failure == limit.** There is no rate-limit surface in the plugin. For routing this is moot: a limit-hit and a task failure are the **same signal**. A null or error result from a `codex-companion task` is a degrade trigger — the workflow stage **re-dispatches that same unit to Claude**. Design the executor-node wrapper so a null/error Codex result transparently falls through to a Claude dispatch for the identical unit. Never promise a quota dashboard.
- **`log()` the degrade** so a run that silently became Claude-only is visible (no-silent-caps discipline).

Quality is not laundered by routing to Codex: every Codex unit's output flows back into Claude's `code-review-subagent` / verify gate, and the bright-line guardrails (destructive-op, external-message, secrets, DoD receipts) fire on Codex units too.

## 4.5 Dispatch mechanics — the tracked wrapped path is canonical

**There is no wrapper-free way to run Codex as a native agent, and that is fine — the wrapped path is the one to prefer.** Claude Code's agent scheduler spawns **Claude models only** (its `model` enum is sonnet/opus/haiku/fable — no GPT). The `openai-codex` plugin ships **no MCP server**; its only agent is `codex-rescue` (`model: sonnet`, `tools: Bash`), a thin forwarder to `codex-companion.mjs`. So a Codex unit reaches the runtime through a cheap Claude **driver** that shells out — the Sonnet driver is a courier (≈free), Codex/GPT does 100% of the reasoning. This is not overhead to avoid; it is what makes a Codex unit a **first-class, harness-tracked node** in a workflow.

Two mechanics, and the **default is (ii)**:

- **(ii) In-workflow wrapped dispatch — CANONICAL.** From inside a dynamic Workflow, dispatch Codex as `agent(prompt, { agentType: 'codex:codex-rescue' })`. The unit shows up as a tracked node (label, phase, live progress, `TaskOutput`) exactly like a Claude subagent — no shell to babysit, no manual `status`/`result` polling. Inject the routing flags (`--write --effort xhigh`) at the head of the prompt; the forwarder applies them. **This path MUST run synchronous.** The forwarder's own heuristic will background a unit it judges "big/open-ended" and return a **job handle instead of the result** (silently dropping the work from the fan-out). Force foreground in the prompt ("run synchronously, do not `--background`") **and** have the recipe detect a job-handle-shaped result and degrade that unit to Claude — the `codex-executor` recipe does both (its `isJobHandle` guard). Never poll `status`/`result` from inside the engine; the forwarder is contractually barred from them.
- **(i) Bash-direct from the MAIN loop — fallback + async.** From a `/loop`, a scheduled task, or the main orchestrator thread (where you hold `Bash`), call `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort xhigh "<prompt>"` directly. Use this only when (a) no Workflow tool is available, or (b) you genuinely want **detached `--background` async** with `status`/`result` polling — which the in-engine forwarder cannot do. It is untracked (you manage the handle yourself), so prefer (ii) whenever the work fits a workflow.

The table's `--background` rows (§2) are the (i) Bash-direct mechanic. Inside a workflow, the same work runs synchronous via (ii).

## 5. Where this is enforced

This doc is the durable intent. It is *carried* by two capability-gated surfaces, neither of which branches on harness identity:

- **The `orchestrate` skill** (`core-rules/skills/orchestrate/SKILL.md`) — capability-gated on "does my harness expose a subagent-coordination tool?", not on identity. Its cross-harness recipe injects the routing above (model, effort, `--write`/`--background`) and the degrade fallback.
- **A model-neutral capability clause in `CLAUDE.md`** — "when orchestrating and a Codex executor is available, route execution-heavy bounded units to it; keep planning/review/synthesis on the orchestrator." Phrased as a capability the orchestrator may have, never as "if you are Codex."

If a future revision re-tunes the split, it lands here next to the table, sourced to the evidence rather than to model recall.
