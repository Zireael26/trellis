---
name: execute
description: Harness-neutral builder that walks a task list task-by-task — dispatches each unchecked checkbox to a subagent, verifies it, states the canonical DoD receipt to the transcript, and ticks the box via scripts/tick.sh. Stops at the process-gate; never commits to main and never merges.
argument-hint: <path to a specs/NNN/tasks.md OR docs/plans/<topic>.md>
---

# execute

The single canonical builder both lineages — Claude Code and Codex — converge on. It reads a task list and implements it **one unchecked checkbox at a time**, leaving a durable provenance trail. It is the executor; authoritative rules live in `engineering-process.md`, `CLAUDE.md`, and the references this doc points at. When in doubt, those win.

Loaded identically whether surfaced from `.claude/skills/execute/` (Claude) or `.agents/skills/execute/` (Codex). Same SKILL.md, same `references/`, same `scripts/`. Resolve your own root with the process-gate precedent: `SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"`.

Where available, the Stop hook (`stop-verify.sh`) hard-gates each turn. Execute still runs every check below; run the checks regardless of harness.

## When to use

- You have a completed task list (`specs/NNN/tasks.md` or `docs/plans/<topic>.md`) and want it built, checkbox by checkbox, with receipts.
- Resuming a half-built list: execute picks up at the first unchecked box and skips already-ticked ones idempotently.

## When NOT to use

- No task list exists yet. Run `spec` → `plan` → `tasks` (or write the plan) first. Execute builds a list; it does not author one.
- A one-line surgical fix that never went through the pipeline. Just make the change with a receipt.
- Crossing the merge boundary. That is the `process-gate` skill, not this one.

## Input contract — two dialects

Both dialects mark completion the same way, but the **completion locus** and the **locator** (how you name "this task") differ — and there are two loci across three shapes, all of which `scripts/tick.sh` handles. The parse, locator-extraction, locus-detection, and granularity mechanics live in [`references/loop.md`](references/loop.md) — read it; do not re-derive them here.

- **Dialect A — `specs/NNN/tasks.md`.** The canonical form the `tasks` skill emits is a **table**: `| ID | Task | Est. | Depends | Covers | Status |` rows whose **Status cell** is `[ ]` / `[x]`, keyed by a `T<N>` ID in the first cell (see [`../tasks/references/tasks-template.md`](../tasks/references/tasks-template.md)). The `Covers` / `Depends` columns are load-bearing — `analyze` reads them — so the table is never flattened. A task unit is located by its **`T<N>` ID** (exact first-cell match) and ticked at the **last cell**. The same file's `## Done criteria` block is a flat `- [ ]` **list** — that locus too. *(Tolerated variant: the flat `- [x] \`path\` — description` form under `## Phase N` headers, as in `specs/001-process-enforcement/tasks.md`'s dogfood; located by its backtick **file-path** substring.)*
- **Dialect B — `docs/plans/<topic>.md`.** A nested **list**: checkboxes `- [ ] **Step N: label**` grouped under `## Task N: <title>` headers. A task unit is located by its **"Step N:"** label; because `Step N:` repeats under every Task, scope it to the owning `## Task N` section (see below) when the bare label is not unique.

Detect the dialect from the path and shape, then drive the loop accordingly. `tick.sh` auto-detects the locus (list checkbox vs. table Status cell) during its scan; the loop's job is to hand it a section scope plus a locator that resolves to exactly one unchecked box. See [`references/loop.md`](references/loop.md) for the mechanics.

## The loop

ONE loop. For each unchecked box — a list `- [ ]` checkbox or a table `| … | [ ] |` Status cell — in document order, per [`references/loop.md`](references/loop.md):

1. **Resolve** the task unit, its **section scope**, and its locator (Dialect A `T<N>` ID or path / Dialect B "Step N:" label).
2. **Dispatch a subagent** to do the work for that one unit. Execute itself does not write the implementation inline — it orchestrates (see Hard refusals).
3. **Verify** the change per [`references/verification-step.md`](references/verification-step.md): run the verification command, capture its exit code and the diff stat.
4. **State** the canonical Definition-of-Done receipt for the unit **to the transcript** (your assistant message). The receipt grammar is fixed by `CLAUDE.md:43` — do not redefine it here. State the verification command, its exit code, and the diff lines, then render the marker. The transcript / `last_assistant_message` is where the Stop hook (`stop-verify.sh`) looks for it — the receipt is **never** written into the task file.
5. **Run the in-body advisory review** — when a core is resolvable, on the implementation diff just produced, **before the tick** — per [`references/verification-step.md`](references/verification-step.md). That per-task review is **advisory**: its findings inform what execute does for the rest of the loop; it is *not* where the `.review-done-<hash>` marker is written (that is a separate, end-of-loop step — see below).
6. **Tick** the box via `scripts/tick.sh <tasks-file> <section> <locator> <receipt>`. All checkbox mutation goes through `tick.sh`; the loop never hand-edits a checkbox. `tick.sh` re-validates the receipt against the canonical ERE (exit 3 on a missing / multi-line / malformed one), confirms the `<locator>` resolves to exactly one unchecked box within `<section>` (exit 4 = none, exit 5 = ambiguous), then flips **only that one box** — the list `- [ ]`→`- [x]` or the table row's last cell. It writes nothing else: no receipt is appended to the file.

Then advance to the next unchecked box. Cadence — when to retry a failed unit, when to stop and escalate, when to keep going unattended — is governed by `autonomy.md`; follow it, do not restate it.

## In-body advisory cores

Two **separate** concerns live here — keep them distinct:

- **Per-task review (advisory, during the loop).** Within a turn, the pre-tick step 5 can run the canonical review cores in-body — on the just-implemented diff, before the box is ticked — rather than waiting for a Stop hook. Each per-task review is **advisory feedback**: its findings inform what execute does for the rest of the loop — they do **not** trigger a marker write. The core resolution, the probe order across `<root>/.claude/hooks/lib/` and `<root>/.codex/hooks/lib/` for `code-reviewer.sh` / `ui-verify-core.sh`, and the advisory-skip when neither core exists are specified in [`references/verification-step.md`](references/verification-step.md). Follow it; do not duplicate the detail here.

- **The `.review-done-<hash>` marker (turn-level, written once, at end-of-loop).** This marker is **not** a per-task artifact and is **not** written by the per-task review (step 5). It is a single, turn-level dedup token meaning *"this exact final diff was reviewed AND cleared in-body,"* which lets the Stop hook skip its one end-of-turn review. Write it **once, after the final task's tick**, hashing `git diff HEAD | head -c 200000` (byte-identical to the hook), and **only if every in-body review that turn was critical-free** (clean or advisory-only). Any unresolved in-body critical → the marker is **not** written, so the armed Stop hook re-reviews and blocks. A legitimate deferral routes through the **exported** `TRELLIS_REVIEW_OVERRIDE=1` escape (logged to the decisions-log) — never a silent marker write. The exact hashing, the harness-matched marker path, and the override mechanics live in [`references/verification-step.md`](references/verification-step.md).

## Hard refusals

execute refuses, explicitly:

- **(a) It does not author or edit the prose of a spec / plan / tasks file.** The only byte it changes is the checkbox token (or table Status cell) `tick.sh` flips — nothing else touches the task list. It never rewrites the plan narrative, reorders phases, adds tasks, or "improves" wording. If the plan is wrong, stop and say so; the human or the `plan` / `tasks` skill fixes it.
- **(b) It refuses a monolithic, inline `/implement`.** Every task goes through the loop, one checkbox at a time, each with its own subagent dispatch and its own receipt. No "I'll just do the whole list in one pass" — that defeats the per-task provenance the receipts exist to create.
- **(c) It stops at the process-gate and never crosses the merge boundary.** No commit to `main`, no merge, no PR-merge. When the list is built, hand off to the `process-gate` skill. execute builds; process-gate decides mergeability.

## Boundaries

- **Writes only two things:** the implementation diffs its dispatched subagents produce, and the single checkbox / table-cell flip `tick.sh` makes to the task file. Never the task-file prose, and never a receipt — the receipt lives in the transcript, not the file.
- **`tick.sh` is the sole R1 isolation point** for checkbox drift — every flip is auditable. What it structurally enforces is that **a well-formed receipt is present** before it will flip (it validates the `CLAUDE.md:43` shape, not the verify's *outcome* — the ERE accepts `exit=1` as readily as `exit=0`). Refusing to tick a **red** verify is **loop discipline**, owned by [`references/verification-step.md`](references/verification-step.md), not by `tick.sh`. Re-runs are safe: a locator pointing at an already-checked box is an exit-0 no-op.
- **Harness-neutral.** Identical behavior under Claude and Codex; execute runs the same checks regardless of harness.
