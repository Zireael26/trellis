# analyze drift-check matrix

Full check list for the analyze skill. SKILL.md has the category overview; this file is the per-check spec.

Each check below lists: *what it looks for*, *how it looks*, *severity tiers*, and *example finding wording*.

If you add a check, also add a row to SKILL.md's "Drift checks" section.

---

## 1. Coverage — every spec criterion has at least one task

**Looks for:** Each bullet under spec.md §3 (Success criteria) appears in at least one task's "Covers" column in tasks.md.

**How to check:** Extract spec §3 bullets verbatim. For each, search tasks.md's coverage map for a row that references it. Match by substring (criteria may be abbreviated in the task table).

**Severity:**
- **critical** — criterion has zero covering tasks. Implementation will silently skip it.
- **warning** — criterion has one covering task but the task description is generic ("implement reconciliation") rather than specific.
- **info** — n/a (coverage is binary).

**Example finding:**

> **C1 (critical)** — spec.md §3 criterion *"Reconciliation job runs at most 1× per minute"* has no covering task in tasks.md. No task ID references this criterion. Add a task that gates the cron cadence, or remove the criterion if it's already enforced upstream.

---

## 2. Origin — every task traces back to plan + spec

**Looks for:** Each task in tasks.md references a file in plan.md §4 (change list) AND a spec §3 criterion.

**How to check:** For each task, the file it names appears in plan.md §4. The criterion it covers (column in the tasks table) appears in spec.md §3.

**Severity:**
- **critical** — task touches a file not in the plan's change list AND covers a criterion not in the spec. Strong signal of scope creep that bypassed both upstream artifacts.
- **warning** — task touches a file not in the plan's change list (likely an honest "noticed during planning" addition that should have been added to the plan).
- **info** — task covers a generic concern (refactor, cleanup) that doesn't map cleanly to a spec criterion; acceptable if the plan §10 (out-of-scope-deferred) hints at it.

**Example finding:**

> **W2 (warning)** — task T7 *"Add migration for `audit_log` retention policy"* touches `migrations/202605120930_audit_retention.sql`, which is not in plan.md §4 change list. Add a row to the plan or remove the task.

---

## 3. Scope — plan introduces concepts not in the spec

**Looks for:** Substantive new dependencies (databases, message queues, third-party services), new top-level files, or new architectural concepts that the spec didn't motivate.

**How to check:** Compare plan.md §1 (technical approach) and §2/§3 (schema + API) against spec.md §1 (problem) and §3 (success criteria). Any infrastructure or concept that isn't justified by the problem or a criterion is a candidate finding.

**Severity:**
- **critical** — plan introduces a Redis / Kafka / external service / new database the spec did not request. Likely scope creep that needs operator sign-off.
- **warning** — plan introduces a new in-repo abstraction (a new module, a new utility library) without spec justification.
- **info** — plan introduces a helper function in an existing file. Acceptable; flag for transparency.

**Example finding:**

> **C3 (critical)** — plan.md §1 introduces a Redis cache for sync-event deduplication. Spec.md §1 problem statement and §3 success criteria do not mention caching, deduplication, or Redis. Either add an explicit success criterion justifying the cache, or remove from the plan.

---

## 4. Constraint compliance — plan respects spec constraints

**Looks for:** Each constraint in spec.md §5 is honoured by plan.md's design.

**How to check:** Quote each spec constraint. Check plan.md §2/§3/§4/§7 for a corresponding design decision that demonstrates compliance.

**Severity:**
- **critical** — plan violates a constraint (e.g., spec says "rate limit 30 req/min", plan calls the API in a tight loop without throttling).
- **warning** — plan is silent on a constraint that probably applies (e.g., spec says "must be backwards-compatible", plan adds a schema column without specifying NOT NULL/DEFAULT).
- **info** — n/a (constraint compliance is binary).

**Example finding:**

> **C4 (critical)** — spec.md §5 constraint *"Warehouse API rate limit: 30 req/min"* is violated by plan.md §1 which describes calling the warehouse API on every POS sale event. At peak (claimed 1000 sales/min in spec §1), this fails the rate limit by 33×. Add a coalescing buffer or change the approach.

---

## 5. Intent fidelity — spec matches clarify (only when clarify.md present)

**Looks for:** Spec.md §1 (problem) and §3 (success criteria) honour the operator's voice captured in clarify.md Q1 (intent) and Q3 (success metric).

**How to check:** Quote clarify Q1 verbatim. Quote spec §1 verbatim. Do they describe the same pain? Quote clarify Q3 verbatim. Compare to spec §3 success criteria bullet-by-bullet.

**Severity:**
- **critical** — spec is solving a different problem than the operator described in clarify. The pipeline drifted at the very first translation.
- **warning** — spec narrows or broadens the problem from clarify; flag for operator review (sometimes intentional, sometimes not).
- **info** — spec rephrases clarify in cleaner language without changing meaning. Acceptable.

**Example finding:**

> **C5 (critical)** — clarify.md Q1 says *"Stock counts diverge from warehouse by end of day; manual reconciliation eats 90 min/store/week."* Spec.md §1 says *"Build a real-time inventory sync service."* Spec is solving for real-time sync; operator's pain is end-of-day divergence. These may not require the same solution. Revise spec to match operator's framing or re-clarify.

---

## 6. Rollback consistency — plan §7 matches spec §5 + clarify Q5

**Looks for:** Plan's rollout / rollback story is consistent with what the spec promised and what clarify recorded.

**How to check:** Quote plan §7. Quote spec §5 (constraints — especially "must be backwards-compatible") and clarify Q5 (rollback plan) if present.

**Severity:**
- **critical** — plan's rollback path doesn't exist or contradicts clarify Q5 (e.g., clarify says "feature flag for 1% ramp", plan says "ship to 100% on merge").
- **warning** — plan's rollback path is vague ("revert the commit") when there's a schema migration that's not reversible.
- **info** — plan's rollback is "no flagging needed; direct ship" and matches a clarify Q5 of "we will fix-forward if it goes wrong".

**Example finding:**

> **C6 (critical)** — plan.md §7 says *"Ship directly on merge; no flag needed."* But plan §2 includes a destructive migration (DROP COLUMN). Reversing this requires either a stay-shape window or a rollback migration. Add a feature flag OR add a reverse migration.

---

## 7. Test strategy completeness — every spec criterion has a test in plan §6

**Looks for:** Plan.md §6 (test strategy) names a specific test or fixture for every spec §3 criterion.

**How to check:** For each spec §3 bullet, find a row in plan §6 that names a test mapping to it.

**Severity:**
- **critical** — spec criterion has no corresponding test entry in plan §6.
- **warning** — test entry exists but level is wrong (e.g., spec criterion is "p95 latency < 600ms"; test is unit not load).
- **info** — test entry exists, level is right, fixture is unnamed. Acceptable; flag for transparency.

**Example finding:**

> **C7 (critical)** — spec.md §3 criterion *"All sync events appear in `audit_log` with timestamps"* has no row in plan.md §6 test strategy. Add an integration test that triggers a POS sale, then queries `audit_log` for the expected event + timestamp.

---

## 8. Sequencing sanity — task dependencies don't cycle; tree stays buildable

**Looks for:** Tasks.md's dependency graph has no cycles, and the implied implementation order leaves the tree in a buildable state at each step.

**How to check:** Extract `Depends:` annotations from each task row. Build a graph. Detect cycles. For sequencing, scan plan.md §5 — if the plan explicitly named a broken-window step, this check is informational only for that step.

**Severity:**
- **critical** — dependency cycle detected (T2 depends on T5; T5 depends on T2). Impossible to start.
- **warning** — tasks in the linear order would leave the tree broken at some step, and plan §5 didn't acknowledge it.
- **info** — sequencing leaves a broken window, but plan §5 explicitly named it. Acceptable.

**Example finding:**

> **C8 (critical)** — task T3 depends on T5 (per `Depends: T5`); T5 depends on T3. Cycle. Break by inlining the smaller of the two or splitting one.

---

## 9. Constitution compliance — pipeline honours the assembled constitution

**Looks for:** The spec/plan/tasks artifacts don't diverge from the project's *effective constitution* — the rule layers that actually govern this project. Three things: (a) artifact prose that contradicts a higher layer's stated rule without a written carve-out; (b) tasks that produce no Definition-of-Done receipt the constitution requires; (c) a plan that breaches a perf budget the constitution sets.

This check reads a *different* source of truth than §4. §4 (constraint compliance) checks the plan against **spec.md §5** constraints. §9 checks all three artifacts against the **assembled constitution** — the rule prose layered across parent, presets, and project-local, which the spec itself may also violate.

**How to check (read-only — this check writes nothing):**

1. Resolve the canonical project root: run `git rev-parse --git-common-dir` and take its parent (same pattern the read-only commands use; call it `<root>`). The effective rule layers are reached via the inheritance symlinks under `<root>/.claude/rules/` — *follow each symlink to its target, never hardcode a control-plane path*. This is what makes the check work inside a **downstream onboarded project** (where there is no literal `core-rules/` — only the gitignored symlinks into the control plane) exactly as it does in the control plane itself. If `<root>/.claude/rules/` has no `trellis.md`, the project isn't parented — note it (degrade to an `info` provenance-ambiguous finding) and assess only the layers present.
2. Assemble the constitution in §14.8 order (parent → presets → project-local), labelling each rule with its provenance:
   - `[parent]` — follow `<root>/.claude/rules/trellis.md` to its target and read it. The baseline.
   - `[preset:<name>]` — follow each `<root>/.claude/rules/preset-*.md` symlink (`<name>` = the filename stem after `preset-`), in filename order. Read the *present* preset symlinks, not the `.trellis.config.json` `presets` array: the effective constitution is what the harness actually loads, and declared-vs-present drift is the `preset-drift` check's job, not this one (mirrors the `/constitution` command's resolution).
   - `[project]` — `<root>/CLAUDE.md` (the project-root file, if present). Most specific.
3. Assemble; do **not** adjudicate. Layers are additive, not last-wins — there is no mechanical override (the deference contract is defined in `engineering-process.md` §14.8 and `inheritance.md`; cited here, not redefined). A more-specific layer's prose *should* carry when it conflicts, but only when the divergence is a *written* carve-out ("§X of the parent rules is relaxed here because…"). A contradiction with no such carve-out is the silent drift this check exists to catch. Report the contradiction and whether a carve-out is present; never decide which layer wins.
4. For (b)/(c): treat the assembled constitution as the source of requirements. Scan tasks.md for any task whose constitution-required DoD receipt is absent; scan plan.md against any perf budget the constitution states.

**Severity:**
- **critical** — `[project]`/`[preset]` prose contradicts a higher layer with **no written carve-out** (silent drift); OR a constitution-mandated DoD receipt is entirely absent from the tasks that need it; OR the plan breaches a stated perf budget.
- **warning** — a carve-out exists but cites no reason (§14.8 wants a written reason); OR a DoD receipt is present but underspecified; OR the plan is silent on a perf budget that probably applies.
- **info** — a lower layer contradicts a higher one *with* a written, reasoned carve-out (the legitimate deference mechanism — surfaced for transparency, not a defect); OR provenance is ambiguous (e.g., a preset symlink couldn't be resolved) and the check degraded gracefully.

**Example finding:**

> **C9 (critical)** — `tasks.md` T4 *"Disable the secrets scan for the demo build"* contradicts `[preset:compliance-strict]` *"hard-fail secrets scan, no `--no-verify` ever"*, and no carve-out for this relaxation appears in `[project]` `CLAUDE.md`. Silent drift against the assembled constitution. Either add a written, reasoned carve-out at the project layer or drop the task. (This check assembles the layers and surfaces the contradiction; it does not decide which layer wins.)

---

## Verdict rule

After running all 9 checks, the skill emits a final verdict:

- **PASS** — zero critical, zero warning findings. Pipeline coheres.
- **NEEDS-REVISION** — zero critical, ≥1 warning. Operator should address before merging.
- **BLOCKED** — ≥1 critical. Spec/plan/tasks need revision before implementation should begin.

The verdict is the skill's recommendation. The operator owns the call; "BLOCKED" findings can be accepted with a note in `gotchas.md` and a follow-up commit explaining the divergence.
