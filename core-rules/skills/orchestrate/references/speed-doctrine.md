# Reference — Dual-harness speed doctrine

Use these patterns to reduce wall-clock time while preserving independent
verification, explicit budget accounting, and orchestrator ownership. Each
pattern has an entry condition and a receipt; none is a reason to weaken scope,
proof, or review gates.

## Race-the-legs

**When to use.** Use on a critical-path, bounded unit when either Claude or
Codex could produce a valid result and the wall-clock gain justifies spending
both pools. Run no more than two races per workflow.

**Mechanics.** Seed separate worktrees, launch the same work order on both legs,
and independently verify each candidate. The first candidate to pass verification
wins. Cancel and log the loser with its harness-native cancellation handle. Keep
the loser diff as a free second opinion for the final review.

**Guardrails.** A race spends BOTH metered pools, so both legs count against the
budget ceiling even when cancelled. The first raw response does not win; the first
independent verify-pass does. The loser must be cancelled and logged, never left
running. Agents do not commit or merge.

**Receipt contract.** Record the unit id, both leg/handle/worktree tuples, model
and effort per leg, both-pools spend, start and verify-pass times, proof and
verifier verdicts, winner, loser cancellation outcome, both diff stats, and how
the loser diff informed the second opinion.

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

**When to use.** Currently never: Ultra-as-a-node is LOCKED on spec 011 D4a
prerequisites. After unlock, it is reserved for coupled, decomposable work where
one ultra node can replace a wider fan-out without losing verification quality.

**Mechanics.** Once spec 011 D4a supplies token telemetry, x4 concurrency-cap
accounting, and one instrumented run, schedule one ultra node as four concurrency
slots and pass its output through the same independent verification gate.

**Guardrails.** Until every prerequisite is evidenced, reject `ultra` outright;
do not clamp or translate it. After unlock, it counts x4 against the concurrency
cap, cannot oversubscribe a wave, and remains subject to ordinary budget, scope,
proof, retry, and independent-review rules.

**Receipt contract.** While locked, record the rejected request and spec 011 D4a
reason. After unlock, record the unlock evidence, unit id, x4 slot accounting,
token telemetry, model/effort, instrumented-run reference, wall-clock, diff stat,
proof, verifier verdict, and final cap utilization.

speed comes from topology, not effort — higher effort is slower per unit; spend it only where quality gates demand.
