# ADR — Sol ultra capability re-ground: mechanism verified, D4a satisfied, race-the-legs retired

**Date:** 2026-07-10 · **Status:** accepted

## Context

Operator directives (2026-07-10, post-rc.10): (1) never run the same work on
both agents; (2) GPT-5.6-sol now has ultracode-like capability — research it
and fold it into doctrine. A three-way research fan-out (official
docs/changelog + community sweep + local surface probe, 4 agents, all
high-confidence) plus an instrumented paired dispatch produced the evidence
below. Full sources live in the research workflow transcript; probe JSONL in
`specs/011-gpt-5-6-effort-reground/research/ultra-probe-2026-07-10/`.

## Findings (verified)

1. **Ultra is a harness mode, not a deeper model tier.** `openai/codex` @
   rust-v0.144.0: `client.rs` maps `ReasoningEffortConfig::Ultra => Max` on the
   API request; the harness separately maps ultra to proactive multi-agent
   mode, injecting a developer message that authorizes unprompted subagent
   spawning — including the line that earlier instructions requiring an
   explicit user request "no longer apply" (a built-in instruction-override;
   safety-relevant given Sol's METR/system-card overreach record).
2. **No fixed subagent count.** The model decides; CLI default
   `features.multi_agent_v2.max_concurrent_threads_per_session = 4` (main + 3
   subagents), warning at ≥ 8. "4 cooperating subagents by default" is
   blog-tier rumor; the evidenced 4 is a concurrency ceiling.
3. **Scope.** Ultra on sol + terra (`multi_agent_version: v2`); luna caps at
   max. Native 5.6 requires CLI ≥ 0.144 (installed: 0.144.0). No `--effort`
   flag on `codex exec`; tier set via `-c model_reasoning_effort=...`.
4. **Surface split.** Companion v1.0.5 (`codex-companion.mjs:71`) rejects
   everything above xhigh — max AND ultra are Bash-direct only. Recipes
   (codex-worker → companion) therefore physically cap at xhigh regardless of
   doctrine; the D6 preflight fail-close already handles this correctly.
5. **Telemetry.** `codex exec --json` streams `turn.completed` usage
   (input/cached/output/reasoning tokens). Subagent aggregation into those
   totals is unverified — treat as parent-thread lower bound.

## Instrumented paired run (D4a prerequisite 3)

Same decomposable work order (three independent Python modules), same scratch
layout, sequential dispatch, full JSONL captured (no tail/head — 2026-07-10
gotcha). Both legs satisfied the work order — same 3-file layout, all demos
exit 0 — with differing implementations and demo inputs (fizzbuzz str-vs-int
lists; `primes_below(30)` vs `primes_below(20)`): the runs are
task-equivalent, not output-identical, which is the honest comparability basis
for the token measurement below.

| metric | xhigh | ultra | ratio |
|---|---|---|---|
| input tokens | 134,508 | 258,359 | 1.92× |
| cached input | 116,224 | 223,488 | — |
| output tokens | 2,553 | 3,524 | 1.38× |
| reasoning tokens | 953 | 1,994 | 2.09× |

Multi-agent machinery engaged on the ultra leg — the evidence is indirect:
three `collab_tool_call` (`wait`) events (carrying only the parent's thread
id; `receiver_thread_ids` empty) plus the three files appearing with no
parent-visible `file_change`/write items, where the xhigh leg shows an
explicit `file_change`. Subagent threads are NOT itemized in the exec JSONL —
the visibility gap is real, confirming the §1 orchestration stance. Operational lesson: `codex exec`
under automation needs `</dev/null` or it wedges on "Reading additional input
from stdin...".

## Decisions

1. **D4a prerequisites: SATISFIED** (telemetry mechanism + ×4 accounting
   anchored to the 4-thread default in `core-rules/loop-safety.md` +
   instrumented run above). Measured spend (1.38–2.09×) sits inside the ×4
   structural cap; ×4 stays as the accounting figure (concurrency-anchored,
   conservative vs measurement).
2. **Ultra unlocked for ATTENDED main-loop Bash-direct dispatch** as an
   exception tier: operator present in the dispatching session; never `/loop`,
   scheduled tasks, workflow agents, or the sandboxless hatch. Mechanism:
   `-c model_max_output_tokens=<N>` plus a declared per-unit token ceiling
   checked against `turn.completed` usage in the receipt (breach halts further
   ultra dispatch for the run); justification + receipts, never a default.
3. **Ultra stays hard-rejected in `.wf.js` recipes** — the dispatch surface
   caps at xhigh, and prompt-nudged delegation is invisible/non-resumable
   inside a deterministic workflow. Revisit when the companion accepts >xhigh
   AND per-subagent visibility exists.
4. **Claude keeps orchestration** — now on capability evidence, not just
   policy: ultra is a per-unit depth tier, never a competing orchestration
   surface (spec 011 D7 topology re-check: answered; Phase B §2 strength
   re-ground stays predicate-gated).
5. **Race-the-legs retired** (operator: no duplicate work across agents).
   Sequential degrade replaces racing; cross-model review of one produced diff
   remains legitimate. `speed-doctrine.md` carries the rule; pattern text
   stays in git history.

## Consequences

- Speed doctrine is now five live patterns + one retired; duplicate-generation
  spend is structurally impossible.
- Max remains permitted-band but recipe-degraded (surface); doctrine now says
  so explicitly instead of papering over it.
- Companion upgrade (> 1.0.5) is the single blocker for recipe-side **max**;
  recipe-side **ultra** additionally requires per-subagent visibility
  (Decision 3). Re-check both on plugin updates.
- The effort band itself (xhigh+max only, medium/high suspended) is unchanged
  by this ADR — see PR #136.
