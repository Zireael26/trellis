# ADR: Dual-harness orchestration — Claude orchestrator, Codex executor node

## Status

Accepted (2026-07-05)

## Context

Trellis has run Claude Code and Codex as **parity harnesses** since the Codex
parity rollout (`2026-05-04-codex-parity-rollout.md`): byte-identical parent
rules, each agent working alone. The RC.4 work
(`docs/plans/2026-07-05-codex-claude-dual-harness-integration.md`) closes the
next gap — **cross-harness orchestration**, where one harness dispatches units of
work to the other inside its own dynamic workflows and loops.

The July 2026 research basis (recorded in §2 of the RC.4 plan) gives a clean
division of labor: Claude/Opus wins at code quality, repo-level refactors,
architecture, planning, interactive decisions, code review, and hard reasoning;
Codex/GPT-5.x wins at speed, autonomy, token efficiency (~3–4× cheaper/task), and
background/async bounded execution. The consensus is not "pick one" but "run both,
build a bridge."

The tooling is asymmetric in the same direction: `Workflow`, ultracode, and
`/loop` are Claude-side orchestration surfaces today; Codex has no equivalent
orchestration engine yet. Whoever owns the loop is therefore Claude by
construction.

The control plane needs to decide the topology, how a Codex unit is dispatched
without a hard dependency Trellis cannot ship publicly, where the routing policy
lives, and how loop-safety budget accounting stays honest across two models with
different token prices.

## Decision

1. **Topology: Claude is the orchestrator; Codex is a dispatchable executor node.**
   The loop belongs to Claude (it owns `Workflow` / ultracode / `/loop`); Codex is
   one worker *type* it fans out to inside a Claude-driven workflow. "Prioritize
   dynamic workflows / ultracode / loops" and "use Codex agents in our loops and
   workflows" are the **same** requirement under this topology, not two.

2. **Capability-gated cross-harness dispatch — no in-file model conditionals.**
   Consistent with `2026-05-08-claude-md-primary-not-agents-md.md`
   (CLAUDE.md and AGENTS.md are byte-identical symlinks), the routing intent is
   expressed as *steering* in a doc plus a capability-gated skill — **never** as
   `if-claude / if-codex` conditionals in shared rules. Cross-harness dispatch
   lives in the public, capability-gated `orchestrate` skill (a `codex-executor`
   recipe + routing references), riding the same rail the dynamic-workflows spec
   established. The skill is inert without the Codex plugin, so it is safe to
   publish to the template mirror.

3. **Presence gate + degrade-to-Claude — no hard plugin dependency.** The
   `openai-codex` Claude Code plugin is **not** part of Trellis and cannot ship to
   the public mirror, so Codex-callability is a **runtime-detected capability**,
   exactly like the existing Workflow-tool capability gate. A presence gate
   (`codex-companion.mjs setup --json` → `ready` / `available` / `loggedIn`)
   decides whether routing is on. Because there is no quota API, a limit-hit and a
   task failure are the **same signal**: a null/error Codex result transparently
   falls through to a Claude `agent()` for the same unit. The framework works
   single-family when Codex is absent, and the degrade is `log()`-ed (no silent
   caps).

4. **Strength-routing policy lives in `docs/codex-routing.md`.** The
   work-type → model map (planning/review/synthesis → Claude; large bounded
   implementation and long-running/async fan-out units → Codex; second-opinion
   diversity passes → the other model) is durable steering intent sourced to the
   research, kept out of shared rules. Shipped as the fixed default map in the
   `codex-executor` recipe; no `routing` config block this release (override added
   later only if a project needs one).

5. **Per-model loop budget rate.** `core-rules/loop-safety.md` converts
   `budget_ceiling_usd` to a token budget via a single `usd_per_mtok` (Opus output
   price). A dual-model workflow also spends cheaper Codex tokens; counting them at
   Opus rates over-charges the budget and trips the ceiling early. The conversion
   extends to a **per-model rate**: `usd_per_mtok` stays the Claude/Opus rate; an
   optional `codex_usd_per_mtok` (GPT-5.x output price) attributes each unit's
   spend at its model's rate. Absent the new field → single-rate fallback
   (backward compatible).

## Deferred "Component D" — inherited guardrails

The dynamic-workflows spec (`docs/specs/2026-06-03-dynamic-workflows-design.md`)
explicitly deferred unattended, PR-opening, worktree-mutating fan-out as
**"Component D — categorically higher autonomy … deserves a dedicated spec with
its own autonomy ceiling, HOLD-only-PR policy, and bypass-permissions
discipline."** Cross-harness parallel orchestration **is** Component D. Its
guardrails are inherited verbatim, not re-decided:

- **HOLD-only PRs** from unattended cross-harness runs — never auto-merge.
- **Own autonomy ceiling** for the cross-harness recipe — it does not float up to
  L5 implicitly.
- **Bright-lines fire on every Codex unit too.** Codex output flows back into
  Claude's `code-review-subagent` / verify gate, so quality is **not** laundered
  by running work on Codex. Destructive-op, external-message, secrets, and
  DoD-receipt guards all still apply.
- **Overnight runs need bypass-permissions mode** (per the dangerous-rm autonomy
  blocker — agent `rm $VAR.*` globs stall unattended runs); Codex-unit prompt
  contracts are hardened against unbounded globs.
- **Every new loop/recipe declares a `safety` block (three ceilings)** or it is
  non-compliant (process-gate + audit finding).

## Consequences

- Cross-harness dispatch ships in the public `orchestrate` skill (a
  `codex-executor` recipe + routing references); the stale README line calling
  `orchestrate` "instance-only" is corrected.
- `docs/codex-routing.md` is added as the routing-policy source of truth; one
  model-neutral capability-conditional clause is folded into `CLAUDE.md`
  (§Context management neighborhood).
- `core-rules/loop-safety.md`, the `loop_safety` block in `trellis.config.json`,
  and the config schema gain the optional `codex_usd_per_mtok` per-model rate.
- The executor-node wrapper detects Codex presence at runtime and degrades to
  Claude on absence or task failure; no hard plugin dependency enters the mirror.
- This ADR supersedes `2026-05-20-antigravity-third-harness.md`: AntiGravity is
  stripped from the live tree in the same RC.4 release (it is not enabled in this
  instance and does not compete with Claude Code + Codex). The AntiGravity ADR is
  preserved as history and marked superseded.

## References

- `docs/plans/2026-07-05-codex-claude-dual-harness-integration.md` — the RC.4
  plan this ADR ratifies (topology §3, routing §4, degrade §5, budget §6,
  Component-D guardrails §7, AntiGravity strip §8).
- `docs/specs/2026-06-03-dynamic-workflows-design.md` — capability-gating (not
  identity-gating), the skill-symlink distribution rail, and the deferred
  Component D whose guardrails this ADR inherits.
- `docs/adr/2026-05-04-codex-parity-rollout.md` — the parity baseline this
  orchestration layer builds on (ship parent-layer harness work together).
- `docs/adr/2026-05-08-claude-md-primary-not-agents-md.md` — no in-file model
  conditionals; CLAUDE.md/AGENTS.md are byte-identical symlinks.
- `docs/adr/2026-05-20-antigravity-third-harness.md` — superseded by this ADR.
