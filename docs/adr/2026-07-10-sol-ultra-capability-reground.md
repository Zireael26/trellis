# ADR — Sol ultra capability re-ground: mechanism verified, D4a satisfied, race-the-legs retired

**Date:** 2026-07-10 · **Status:** accepted for the 2026-07-10 Bash-direct/direct-CLI ultra mechanics and evidence. Current effort admission is governed by `docs/codex-routing.md` §3; the rc.10 worker, recipe, preflight, and revisit clauses are historical and retired by commit `2ad1808`.

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
4. **Retired rc.10 worker surface (historical).** Companion v1.0.5
   (`codex-companion.mjs:71`) rejected everything above xhigh — max AND ultra
   were Bash-direct only. The former `codex-worker → companion` recipes therefore
   capped at xhigh, and the D6 preflight handled that route. Commit `2ad1808`
   retired those Trellis-owned surfaces; this is field evidence only, not an
   installed cap or an instruction to run or revisit a preflight.
5. **Telemetry.** `codex exec --json` streams `turn.completed` usage
   (input/cached/output/reasoning tokens). *Addendum (same day, source dig):*
   those totals are **parent-thread-only** — child threads are independent
   Sessions (`agent/control/spawn.rs`) whose usage never feeds the parent's
   `TokenUsageInfo` (`session/mod.rs` → `context_manager/history.rs`), and
   exec drops child `ThreadTokenUsageUpdated` events via a primary-thread-id
   filter (`exec/src/lib.rs:1328`). True ultra cost is strictly higher than
   reported; per-child usage lives only in each child's own rollout.

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
   This dated acceptance is carried forward only through the current §3
   admission: ultra remains a separately admitted attended direct-CLI harness
   mode, not a general tier or a retired recipe route.
3. **Historical retired recipe constraint.** In rc.10, `.wf.js` recipes
   hard-rejected ultra because the `codex-worker → companion` route capped at xhigh
   and prompt-nudged delegation was invisible/non-resumable in a deterministic
   workflow. Commit `2ad1808` retired the recipes, worker integration, D6
   preflight, and the “revisit when companion accepts >xhigh and per-subagent
   visibility exists” clause. Do not use that mechanism as current rollout
   guidance. Plugin-owned commands remain a separately selected, fail-closed lane:
   plugin failure never selects direct CLI, and direct-CLI failure never selects the
   plugin.
4. **Claude keeps orchestration** — now on capability evidence, not just
   policy: ultra is a per-unit attended harness mode, never a competing
   orchestration surface (spec 011 D7 topology re-check: answered; Phase B §2
   strength re-ground stays predicate-gated).
5. **Race-the-legs retired** (operator: no duplicate work across agents).
   An explicit caller/operator selection may start a sequential dispatch on another
   lane after a visible failure; cross-model review of one produced diff remains
   legitimate. `speed-doctrine.md` carries the rule; pattern text
   stays in git history.

## Consequences

**Current policy.** This ADR preserves the 2026-07-10 capability evidence and
acceptance; it is not the current effort-selection authority. Use
`docs/codex-routing.md` §3 for every selected direct-CLI or plugin-owned
command: select `medium`, `high`, or `xhigh` explicitly; `max` is retired and
has no admitting path; and `ultra` remains separately admitted only as an
attended direct-CLI harness mode. An explicitly selected provider lane fails
closed rather than rerouting to another provider.

**Historical 2026-07-10 consequences and receipts.**

- Speed doctrine then recorded five live patterns + one retired; duplicate-generation
  spend was structurally impossible.
- `max` was then a permitted direct-CLI exception tier, subject to the same explicit
  justification and receipt discipline as ultra; no Trellis recipe mediated it.
- **Historical retired rc.10 revisit condition.** A Companion upgrade (> 1.0.5)
  was the proposed blocker check for recipe-side **max**, with per-subagent
  visibility additionally required for recipe-side **ultra**. Since commit
  `2ad1808` retired the recipes and preflight, neither condition is a current
  Trellis rollout check. Plugin-owned commands remain explicitly selected and
  fail closed; their availability never reroutes a direct-CLI unit.
- The effort band at this acceptance was `xhigh` + `max`, with `medium`/`high`
  suspended (PR #136). That interim posture is historical only and is
  superseded by the current §3 band above.
