# ADR: Dual-harness orchestration — Claude orchestrator, Codex executor node

## Status

Accepted (2026-07-05); partially superseded by `2ad1808` (2026-08-09).

> **Historical / non-executable retirement banner.** Commit `2ad1808` retired the Trellis-owned `codex-worker`, `codex-executor`, and `codex-fanout` worker/recipe surfaces, including their plugin preflight, rollout, and automatic provider-fallback contracts. The decision text below preserves its 2026-07-05 rationale and receipts; it MUST NOT be used to invoke or recreate those deleted surfaces.
>
> Current execution is deliberate direct `codex exec` or, only after explicit caller/operator selection, a plugin-owned `codex-companion.mjs` command. A rejected, unavailable, or failed selected lane fails closed: it does not fall through to Claude or another provider unless the caller/operator explicitly selects that lane. See `docs/codex-routing.md` §§3–4.5.
>
> **Partial-supersession scope.** Only the retired Trellis-owned dispatch, preflight, rollout, and fallback mechanics are superseded. The dated parity/routing evidence, budget proposal, Component-D guardrail record, and AntiGravity decision remain preserved as history; they do not revive a worker or recipe.

## Context

Before RC.4, Trellis had run Claude Code and Codex as **parity harnesses** since the Codex
parity rollout (`2026-05-04-codex-parity-rollout.md`): byte-identical parent
rules, with each agent working alone. RC.4
(`docs/plans/2026-07-05-codex-claude-dual-harness-integration.md`) closed the
next gap through **cross-harness orchestration**, where one harness dispatched units of
work to the other inside its own dynamic workflows and loops.

The July 2026 research basis recorded in §2 of the RC.4 plan supported a clean
division of labor: Claude/Opus led on code quality, repo-level refactors,
architecture, planning, interactive decisions, code review, and hard reasoning;
Codex/GPT-5.x led on speed, autonomy, token efficiency (~3–4× cheaper/task), and
background/async bounded execution. The accepted answer was not "pick one" but "run both,
build a bridge."

The tooling was asymmetric in the same direction: `Workflow`, ultracode, and
`/loop` were Claude-side orchestration surfaces; Codex had no equivalent
orchestration engine. Claude therefore owned the loop by construction.

The control-plane decision covered the topology, dispatch without a hard
public plugin dependency, routing-policy placement, and honest loop-safety
budget accounting across models with different token prices.

## Historical decision (partially superseded)

The five points below record the July 2026 decision. In this historical text, an “executor node” denotes the retired Trellis-owned dispatch surface unless the retirement banner expressly identifies a current direct route.

1. **Topology: Claude was the orchestrator; Codex was a dispatchable executor node.**
   The loop belonged to Claude, which owned `Workflow`, ultracode, and `/loop`;
   Codex was one worker *type* fanned out inside a Claude-driven workflow.
   "Prioritize dynamic workflows / ultracode / loops" and "use Codex agents in
   our loops and workflows" were the **same** requirement under this topology.

2. **[Retired implementation] Capability-gated cross-harness dispatch — no in-file model conditionals.**
   Consistent with `2026-05-08-claude-md-primary-not-agents-md.md`
   (CLAUDE.md and AGENTS.md are byte-identical symlinks), the routing intent was
   expressed as *steering* in a doc plus a capability-gated skill — **never** as
   `if-claude / if-codex` conditionals in shared rules. Cross-harness dispatch
   then lived in the public, capability-gated `orchestrate` skill (a
   `codex-executor` recipe + routing references), riding the same rail the
   dynamic-workflows spec established. That retired recipe was inert without the
   Codex plugin and was safe to publish to the template mirror.

3. **[Retired implementation] Presence gate + degrade-to-Claude — no hard plugin dependency.** The
   external `openai-codex` Claude Code plugin was not part of Trellis and could
   not ship to the public mirror, so Codex-callability was designed as a
   runtime-detected capability. A presence gate (`codex-companion.mjs setup
   --json` → `ready` / `available` / `loggedIn`) decided whether routing was on.
   Because no quota API existed, the former design treated a limit-hit and task
   failure as the same signal: a null/error Codex result fell through to a
   Claude `agent()` for the same unit. The framework worked single-family when
   Codex was absent and logged each degrade. That automatic fallback is retired;
   selected lanes now fail closed as the retirement banner states.

4. **Strength-routing policy lives in `docs/codex-routing.md`.** The
   work-type → model map (planning/review/synthesis → Claude; large bounded
   implementation and long-running/async fan-out units → Codex; second-opinion
   diversity passes → the other model) remains documented routing context sourced
   to the research and kept out of shared rules. The now-retired
   `codex-executor` recipe was its former fixed-default carrier; current direct
   execution and its fail-closed selection policy are governed by
   `docs/codex-routing.md` §§3–4.5.

5. **Per-model loop budget rate.** At adoption, `core-rules/loop-safety.md`
   converted `budget_ceiling_usd` to a token budget through one `usd_per_mtok`
   Opus output rate. A dual-model workflow also spent cheaper Codex tokens, so
   the single rate overcharged the budget and tripped the ceiling early. RC.4
   extended the conversion with optional `codex_usd_per_mtok`, attributing each
   unit's spend at its model's rate while retaining the single-rate fallback
   when the optional field was absent.

## Historical "Component D" — inherited guardrails

The dynamic-workflows spec (`docs/specs/2026-06-03-dynamic-workflows-design.md`)
had explicitly deferred unattended, PR-opening, worktree-mutating fan-out as
**"Component D — categorically higher autonomy … deserves a dedicated spec with
its own autonomy ceiling, HOLD-only-PR policy, and bypass-permissions
discipline."** RC.4 classified cross-harness parallel orchestration as
Component D and inherited its guardrails rather than re-deciding them:

- Unattended cross-harness runs opened **HOLD-only PRs** and never auto-merged.
- The cross-harness recipe had its own autonomy ceiling rather than floating
  implicitly to L5.
- Bright-line guardrails fired on every Codex unit. Codex output flowed through
  Claude's `code-review-subagent` and verify gate; destructive-op,
  external-message, secrets, and DoD-receipt guards remained active.
- Overnight runs used bypass-permissions mode, while Codex-unit prompt
  contracts prohibited unbounded globs.
- Each new loop or recipe declared a three-ceiling `safety` block or was
  non-compliant.

## Consequences (historical at adoption)

- At adoption, cross-harness dispatch shipped in the public `orchestrate`
  skill as the `codex-executor` recipe plus routing references, and the stale
  README line calling `orchestrate` "instance-only" was corrected. That retired
  recipe is no longer executable.
- RC.4 added `docs/codex-routing.md` as the routing-policy source of truth and
  folded one model-neutral capability-conditional clause into `CLAUDE.md`.
- RC.4 added optional `codex_usd_per_mtok` to `core-rules/loop-safety.md`, the
  `loop_safety` block in `trellis.config.json`, and the config schema.
- The executor-node wrapper detected Codex presence at runtime and degraded to
  Claude on absence or task failure. `2ad1808` retired that wrapper; it MUST NOT
  be recreated as an automatic fallback.
- This ADR superseded `2026-05-20-antigravity-third-harness.md`: RC.4 stripped
  AntiGravity from the live tree because it was not enabled in this instance
  and did not compete with Claude Code + Codex. The AntiGravity ADR remained as
  history and was marked superseded.

## References

- `docs/plans/2026-07-05-codex-claude-dual-harness-integration.md` — the
  historical RC.4 plan this ADR originally ratified (topology §3, routing §4,
  degrade §5, budget §6, Component-D guardrails §7, AntiGravity strip §8).
- `docs/specs/2026-06-03-dynamic-workflows-design.md` — capability-gating (not
  identity-gating), the skill-symlink distribution rail, and the deferred
  Component D whose guardrails this ADR inherits.
- `docs/adr/2026-05-04-codex-parity-rollout.md` — the parity baseline this
  orchestration layer builds on (ship parent-layer harness work together).
- `docs/adr/2026-05-08-claude-md-primary-not-agents-md.md` — no in-file model
  conditionals; CLAUDE.md/AGENTS.md are byte-identical symlinks.
- `docs/adr/2026-05-20-antigravity-third-harness.md` — superseded by this ADR.
