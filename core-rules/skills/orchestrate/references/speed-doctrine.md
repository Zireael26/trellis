# Reference — Dual-harness speed doctrine

Use these patterns to reduce wall-clock time while preserving independent
verification, explicit budget accounting, and orchestrator ownership. Each
pattern has an entry condition and a receipt; none is a reason to weaken scope,
proof, or review gates.

## No-duplicate-work rule (race-the-legs RETIRED)

**Rule.** Never dispatch the same work order to more than one agent or leg.
Every unit runs on exactly one executor; wall-clock speed comes from the
patterns below — overlapping *different* work — never from redundant
generation. Operator directive 2026-07-10.

**What replaced racing.** Pick the leg per unit from the routing table
(`docs/codex-routing.md §2`) and commit to it. If the chosen leg fails or
degrades, the standard degrade path re-dispatches the unit — sequentially,
never concurrently — to the other leg. Cross-model *review* of one produced
diff (verify-panel) is not duplication: generation happens once; only judgment
is duplicated, at a fraction of the cost.

**History.** Race-the-legs (launch both legs, first verify-pass wins) shipped
in spec 013 and won its one recorded outing (013 plan authoring, pilot-ledger
row 4) at 2× token cost on the unit. Retired because paying both metered pools
for one deliverable contradicts the operator's cost posture; the pattern text
lives in git history if ever re-evaluated.

## Cross-harness pipelined verify

**When to use.** Use for two or more independent or dependency-ordered units when
generation and verification can overlap.

**Mechanics.** A cheap, low-effort Claude verifier checks the actual diff and
proof for unit N while Codex generates unit N+1. Schedule continuously as units
land; do not insert a within-wave or whole-fan-out barrier.

**Guardrails.** The producing executor never verifies itself. A unit is not
merge-ready until its independent verification is green. Preserve dependency
order even though unrelated generation and verification overlap.

**Receipt contract.** Record unit id, generator handle/model/effort, verifier
handle/effort, generation start/end, verification start/end, overlap duration,
diff stat, proof output, verdict, and any retry or degradation.

## Warm-thread pool

**When to use.** Use for follow-up work in a repo and subsystem that has a recent,
relevant Codex thread whose context is cheaper to resume than reconstruct.

**Mechanics.** Maintain the gitignored project-local index
`.claude/codex-thread-pool.json`, keyed by `repo + subsystem` and storing thread
id, model, effort, and `updatedAt`. From the same repo cwd, resume with:

```sh
codex exec resume <thread-id> "<follow-up>"
```

Update the index and dispatch receipt after every resume.

**Guardrails.** Retire entries older than 24 hours. Never use a thread from a
different repo or subsystem, and never use an ambiguous latest-thread shortcut
when multiple units share a checkout. A stale, missing, or failed thread becomes
a logged fresh dispatch rather than a guessed resume.

**Receipt contract.** Record the repo+subsystem key, thread id, model, effort,
prior and updated timestamps, cold-or-resumed decision, same-cwd confirmation,
wall-clock, result, proof, diff stat, and retirement or fresh-dispatch reason.

## Primer-fed dispatch

**When to use.** Use when the orchestrator has already read the relevant feature
primer or repository context needed to bound an executor unit.

**Mechanics.** The orchestrator reads the matching `.claude/primers/INDEX.md`
entry and primer, then injects that context into the six-field work order: goal,
repo/paths, constraints, non-goals, proof, and output. The executor starts from
the supplied context and never re-explores what the orchestrator already read.

**Guardrails.** Inject only context relevant to the bounded unit, identify stale
or uncertain primer facts, and keep the exact file scope authoritative. The
executor may inspect scoped files needed to implement and prove the unit, but it
must not repeat broad discovery or silently expand scope.

**Receipt contract.** Record the unit id, primer/index paths and revision or
mtime, injected context summary, six work-order fields, any stale-context note,
executor handle/model/effort, files changed, proof output, and verification
verdict.

## Streaming merges

**When to use.** Use when verified units land at different times and their
dependency graph permits incremental integration.

**Mechanics.** Treat merge as a pipeline stage, not an end barrier. As each unit
passes verification, the main orchestrator commits or merges it serially in
dependency order. Use worktree isolation only for conflicting units; keep
non-conflicting units un-isolated.

**Guardrails.** Agents never commit or merge. The orchestrator checks the actual
diff and proof before integrating, never merges a dependent unit ahead of its
prerequisite, and stops the affected branch of the pipeline on conflict or red
verification without blocking unrelated ready units.

**Receipt contract.** Record unit id, dependency keys, isolation/worktree,
arrival time, diff stat, proof and verifier verdict, integration eligibility,
orchestrator-owned commit/merge id and time, conflict/defer reason, and resulting
dependency-ordered landing sequence.

## Ultra-as-a-node

**Status (2026-07-10).** Spec 011 D4a prerequisites are SATISFIED (telemetry
via `codex exec --json`; ×4 accounting in loop-safety anchored to the CLI's
default 4-thread cap; instrumented paired run measured 1.38–2.09× spend vs
xhigh with multi-agent machinery engaged — receipts in
`docs/adr/2026-07-10-sol-ultra-capability-reground.md`). What remains split:

- **ATTENDED main-loop Bash-direct: UNLOCKED.** Reserved for coupled,
  decomposable work where one ultra node replaces a wider fan-out without
  losing verification quality, dispatched from a turn the operator is present
  in — never `/loop`, scheduled tasks, or any unattended context. Dispatch:
  `codex exec --json -c model_reasoning_effort="ultra" -c model_max_output_tokens=<N> ... </dev/null`
  (`</dev/null` is mandatory — codex exec wedges on open stdin, gotchas
  2026-07-10). Declare a per-unit token ceiling and check it against the
  `turn.completed` usage in the captured full JSONL receipt; a breach halts
  further ultra dispatch for the run.
- **Inside `.wf.js` recipes: still hard-reject.** The recipe surface
  (codex-worker → companion ≤ 1.0.5) caps at xhigh, and ultra's prompt-nudged
  delegation is invisible and non-resumable inside a deterministic workflow.
  A workflow agent that holds Bash must never invoke `codex exec` itself at
  any effort — Codex dispatch belongs to the orchestrator, through
  codex-worker. Revisit when the companion accepts it AND per-subagent
  visibility exists.

**Guardrails.** Counts ×4 against any concurrency-derived budget arithmetic,
cannot oversubscribe a wave, requires a named justification, never a default,
never on the sandboxless hatch. Ultra's injected instruction voids "don't
spawn subagents" rules and Sol carries a documented overreach record — output
passes the same independent verification gate as any executor unit, and
reported usage is the parent-thread lower bound (subagent aggregation
unverified).

**Receipt contract.** Record the unlock-evidence pointer (the ADR), unit id,
×4 slot accounting, token telemetry from the JSONL, model/effort,
justification, wall-clock, diff stat, proof, verifier verdict, and final cap
utilization. A recipe-side ultra request still records the rejection and the
surface reason.

speed comes from topology, not effort — higher effort is slower per unit; spend it only where quality gates demand.
