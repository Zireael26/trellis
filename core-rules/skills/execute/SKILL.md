---
name: execute
description: Harness-neutral builder that walks a task list in document order — implements each unchecked checkbox, verifies it, states the canonical DoD receipt to the transcript, and ticks the box via scripts/tick.sh. Stops at the process-gate; never commits to main and never merges.
argument-hint: <path to a specs/NNN/tasks.md OR docs/plans/<topic>.md>
---

# execute

The single canonical builder all three harnesses — Claude Code, Codex, and Pi — converge on. It reads a task list and works through it in document order, leaving a durable provenance trail. Two granularities are in play and must not be collapsed: the **acceptance unit** is always the single checkbox — its own locator, its own green evidence, its own receipt, its own tick — while the **execution unit** is however much work is coherent to do in one go, which may span several boxes. It is the executor; authoritative rules live in `engineering-process.md`, `CLAUDE.md`, and the references this doc points at. When in doubt, those win.

Loaded identically whether surfaced from `.claude/skills/execute/` (Claude Code) or the shared `.agents/skills/execute/` tree that Codex and Pi both discover. Same SKILL.md, same `references/`, same `scripts/`. Never guess an arbitrary checkout root or rely on misleading `$0` resolution; resolve the physical skill root from the actual loaded `SKILL.md` path using isolated Python (e.g. `Path(actual_skill_file).resolve(strict=True).parent`). From this resolved physical skill root (`<physical-skill-root>`), canonical hooks libraries are located at `<physical-skill-root>/../../hooks/lib/`.

Where available, the Stop hook (`stop-verify.sh`) hard-gates each turn. Execute still runs every check below; run the checks regardless of harness.

## When to use

- You have a completed task list (`specs/NNN/tasks.md` or `docs/plans/<topic>.md`) and want it built, checkbox by checkbox, with receipts.
- Resuming a half-built list: execute picks up at the first unchecked box and skips already-ticked ones idempotently.

## When NOT to use

- No task list exists yet. Run `spec` → `plan` → `tasks` (or write the plan) first. Execute builds a list; it does not author one.
- A one-line surgical fix that never went through the pipeline. Just make the change with a receipt. (When `mandatory_pipeline` is enabled this stays valid **below the size floor**; a larger *mechanical* change over the floor must be declared with `/surgical`, and *feature* work over the floor takes the triad — §14.7.)
- Crossing the merge boundary. That is the `process-gate` skill, not this one.

## Input contract — two dialects

Both dialects mark completion the same way, but the **completion locus** and the **locator** (how you name "this task") differ — and there are two loci across three shapes, all of which `scripts/tick.sh` handles. The parse, locator-extraction, locus-detection, and granularity mechanics live in [`references/loop.md`](references/loop.md) — read it; do not re-derive them here.

- **Dialect A — `specs/NNN/tasks.md`.** The canonical form the `tasks` skill emits is a **table**: `| ID | Task | Est. | Depends | Covers | Status |` rows whose **Status cell** is `[ ]` / `[x]`, keyed by a `T<N>` ID in the first cell (see [`../tasks/references/tasks-template.md`](../tasks/references/tasks-template.md)). The `Covers` / `Depends` columns are load-bearing — `analyze` reads them — so the table is never flattened. A task unit is located by its **`T<N>` ID** (exact first-cell match) and ticked at the **last cell**. The same file's `## Done criteria` block is a flat `- [ ]` **list** — that locus too. *(Tolerated variant: the flat `- [x] \`path\` — description` form under `## Phase N` headers, as in `specs/001-process-enforcement/tasks.md`'s dogfood; located by its backtick **file-path** substring.)*
- **Dialect B — `docs/plans/<topic>.md`.** A nested **list**: checkboxes `- [ ] **Step N: label**` grouped under `## Task N: <title>` headers. A task unit is located by its **"Step N:"** label; because `Step N:` repeats under every Task, scope it to the owning `## Task N` section (see below) when the bare label is not unique.

Detect the dialect from the path and shape, then drive the loop accordingly. `tick.sh` auto-detects the locus (list checkbox vs. table Status cell) during its scan; the loop's job is to hand it a section scope plus a locator that resolves to exactly one unchecked box. See [`references/loop.md`](references/loop.md) for the mechanics.

## The loop

### Entry task capture

At entry before beginning the loop, execute captures the explicitly selected canonical task document state:

```bash
python3 -I <physical-skill-root>/../../hooks/lib/task-state.py capture --cwd <actual-worktree> --tasks <relative-task-document> --harness <actual-harness>
```

Treat an unavailable capture result (exit 1 or `status: "unavailable"`) as an advisory failure, never as success. Do not replay task text, fake task authorization, or modify `tick.sh`.

ONE loop. For each unchecked box — a list `- [ ]` checkbox or a table `| … | [ ] |` Status cell — in document order, per [`references/loop.md`](references/loop.md):

1. **Resolve** the task unit, its **section scope**, and its locator (Dialect A `T<N>` ID or path / Dialect B "Step N:" label).
2. **Do the work** for that unit. Choose the execution unit by coherence, not by checkbox count: one box on its own, or a bounded group of boxes that share context and whose verification actually covers each of them. Independent small work and dependency-bound work may be done directly; execution-heavy bounded work (a large mechanical edit, a long file-by-file change) goes to an executor node when one is available; work needing judgment stays on the orchestrator. That is a capability gate — "does an executor node exist", never "which model am I". Dispatch mechanics, the required explicit effort tier, and every degrade path: `core-rules/references/delegation.md` and `docs/codex-routing.md`. An explicitly selected provider that turns out unavailable is surfaced as a failed lane, never silently substituted. Routing changes only *who executes* — steps 3-6 run identically on an externally-produced diff, and grouping never merges two acceptance units (see Hard refusals).
3. **Verify** the change per [`references/verification-step.md`](references/verification-step.md): run the verification command, capture its exit code and the diff stat.
4. **State** the canonical Definition-of-Done receipt for the box **to the transcript** (your assistant message). The receipt grammar is fixed by `CLAUDE.md` *Definition of done* (the `dod-receipt` marker) — do not redefine it here. State the verification command, its exit code, and the diff lines, then render the marker. The transcript / `last_assistant_message` is where the Stop hook (`stop-verify.sh`) looks for it — the receipt is **never** written into the task file.
5. **Run the in-body advisory review** — when a core is resolvable, on the implementation diff just produced, **before the tick** — per [`references/verification-step.md`](references/verification-step.md). Review at the boundary the work was actually done at: one review over a grouped unit's diff covers that whole group, and a box whose diff no review saw is not reviewed. That in-body review is **advisory**, it informs what execute does for the rest of the loop, and it **writes no marker** — the `.review-done-<hash>` marker has one producer and it is not this skill (see below).

   **Log the forks the plan did not anticipate.** When a unit forces a decision the plan did not anticipate — an interface that turned out to be shaped differently, an ambiguity with two defensible readings, a dependency the plan assumed present — append one line to `implementation-notes.md` at the repo root of the active checkout: `<locator> | <the fork> | <the branch taken> | <why it was the conservative one>`. The file is **temporary**: created lazily on the first deviation, read by the reviewer and by `process-gate`, and deleted (or folded into the PR description) when the list is merged. A run with no deviations creates no file. This is not a narration log — one line per genuine fork, not per task. It is never `git add -N`'d and never counts in a task's diff stat: it must stay untracked so the step-3 `+N/-M` and the turn's `git diff HEAD` hash are unaffected.
6. **Tick** the box via `scripts/tick.sh <tasks-file> <section> <locator> <receipt>`. All checkbox mutation goes through `tick.sh`; the loop never hand-edits a checkbox. `tick.sh` re-validates the receipt against the canonical ERE (exit 3 on a missing / multi-line / malformed one), confirms the `<locator>` resolves to exactly one unchecked box within `<section>` (exit 4 = none, exit 5 = ambiguous), then flips **only that one box** — the list `- [ ]`→`- [x]` or the table row's last cell. It writes nothing else: no receipt is appended to the file.

   Immediately AFTER a successful tick, execute captures the updated task document state:

   ```bash
   python3 -I <physical-skill-root>/../../hooks/lib/task-state.py capture --cwd <actual-worktree> --tasks <relative-task-document> --harness <actual-harness>
   ```

   Treat an unavailable capture result as an advisory failure, never as success. Do not alter task text, replay previous state, fake recovery authorization, or edit `tick.sh`.

Then advance to the next unchecked box. Cadence — when to retry a failed unit, when to stop and escalate, when to keep going unattended — is governed by `autonomy.md`; follow it, do not restate it.

## In-body advisory cores

Two **separate** concerns live here — keep them distinct:

- **In-body review (advisory, during the loop).** The pre-tick step 5 runs the canonical review cores in-body, on the diff of the unit just implemented. Its findings inform the rest of the loop. It writes no marker, and it does **not** certify the turn's final artifact: every tick mutates the tracked task file, so the diff the Stop hook sees at end-of-turn is not the diff any in-body review saw.
- **The `.review-done-<hash>` marker (turn-level, hook-owned).** `core-rules/hooks/code-review-subagent.sh` (and its Codex sibling) is the sole writer, and only after a review it validated as `completed`. execute never writes it and never hand-mints a substitute for it. A required independent review that did not run stays visibly unmet — a deterministic check is not a review.

Core resolution, the advisory skip when no core is present, and the exported `TRELLIS_REVIEW_OVERRIDE=1` escape are specified in [`references/verification-step.md`](references/verification-step.md) §4. Follow it; do not duplicate the detail here.

## Hard refusals

execute refuses, explicitly:

- **(a) It does not author or edit the prose of a spec / plan / tasks file.** The only byte it changes is the checkbox token (or table Status cell) `tick.sh` flips — nothing else touches the task list. It never rewrites the plan narrative, reorders phases, adds tasks, or "improves" wording. If the plan is wrong, stop and say so; the human or the `plan` / `tasks` skill fixes it.
- **(b) It refuses a monolithic, undifferentiated `/implement`.** Every acceptance checkbox keeps its own `(section, locator)`, its own green evidence and its own receipt — whether the work reached it directly, inside a coherent group, or through a dispatched executor. No "I'll just do the whole list in one pass and tick them all" — that defeats the per-task provenance the receipts exist to create. Grouping is an execution convenience, never a merge of two acceptance units: a group member whose evidence is red or missing stays unticked while its siblings proceed, and grouping does not lower the review or scope controls that would apply to the same work done box by box.
- **(c) It stops at the process-gate and never crosses the merge boundary.** No commit to `main`, no merge, no PR-merge. When the list is built, hand off to the `process-gate` skill. execute builds; process-gate decides mergeability.

## Boundaries

- **Writes only three things, the third conditional:** the implementation diffs the units produce — directly, as a group, or through a dispatched executor; the single checkbox / table-cell flip `tick.sh` makes to the task file; and, only when a unit deviated from the plan, one appended line in the temporary `implementation-notes.md` at the active checkout's repo root. Never the task-file prose, and never a receipt — the receipt lives in the transcript, not the file.
- **`tick.sh` is the sole R1 isolation point** for checkbox drift — every flip is auditable. What it structurally enforces is that **a well-formed receipt is present** before it will flip (it validates the canonical `dod-receipt` shape, not the verify's *outcome* — the ERE accepts `exit=1` as readily as `exit=0`). Refusing to tick a **red** verify is **loop discipline**, owned by [`references/verification-step.md`](references/verification-step.md), not by `tick.sh`. Re-runs are safe: a locator pointing at an already-checked box is an exit-0 no-op.
- **Harness-neutral.** The same process checks run under Claude Code, Codex, and Pi — native enforcement is not identical. Claude Code and Codex provide `stop-verify.sh`, but installation alone does not prove native Stop activation or enforcement; Pi's extension emits advisory context on `agent_settled` and around compaction, which is neither a hard Stop gate nor the transcript-path state recovery the Codex hooks use. Run every check above regardless of harness, and never treat a Pi advisory as the gate having fired.
