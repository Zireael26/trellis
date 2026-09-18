# Reference — Per-task verification + receipt protocol

This is the step the loop runs once a checkbox's implementation work is complete — whether that box was implemented alone or inside a coherent group — and **before** the box is ticked. It produces the one artifact that authorizes the tick: a canonical Definition-of-Done receipt. Grouping changes who ran the work, never what a tick costs: every box needs evidence that actually covers *its* acceptance, and its own receipt. The loop never hand-edits a checkbox and never ticks without a well-formed receipt — all checkbox mutation goes through `scripts/tick.sh`, which re-validates the receipt before flipping the box (see `loop.md` for the loop mechanics, `scripts/tick.sh` for the contract).

The receipt is recorded in the **transcript** (the agent's turn message / `last_assistant_message`) — that is the receipt's durable home and what the Stop hook (`stop-verify.sh`) actually checks at end-of-turn (`docs/specs/2026-06-02-trellis-process-enforcement-design.md:168`). `tick.sh` does **not** write the receipt into the tasks file: it *validates* the receipt as the gate that proves `execute` constructed a well-formed one, and on success flips the single matching checkbox — and changes nothing else in the file. So the per-task receipt you assemble here is *stated to the transcript*, and the same string is handed to `tick.sh` purely so the flip is gated on a valid receipt.

The receipt grammar is canonical and defined once, as the `dod-receipt` marker in `CLAUDE.md` *Definition of done*. This document does not redefine it — it describes how to *fill* it per task and where to hand it. The same marker is what the Stop hook checks at end-of-turn; the per-task receipt and the turn receipt are the same grammar.

## Sequence per task

1. **Run the task's verification command.** Capture its exit code.
2. **Compute the diff stat** for the work just done (including any newly-created files — see step 2).
3. **Assemble the canonical marker** by filling the `dod-receipt` grammar, and **state it in the turn transcript** (this is the receipt the Stop hook reads).
4. **Run the in-body advisory cores** over the just-implemented diff at the boundary the work was done at (code review; UI verify when the work touched UI), **before the tick**. These reviews are **advisory feedback for the rest of the loop** — they write **no** marker (see §4).
5. **Hand the marker to `scripts/tick.sh`** with the box's section + locator. tick.sh re-validates and (only on a valid receipt) flips the box. It writes nothing else.

Step 5 (the tick) is conditional on step 1: **a failed verify never ticks** (see *Failed verify* below).

## 1. Run the verification command

Use what the task or plan specifies:

- **Dialect A** (`specs/NNN/tasks.md`): the task line or its Phase header names the command, or the spec's acceptance criteria do.
- **Dialect B** (`docs/plans/*.md`): the Step / Task block names the command (build, lint, the specific test).

If nothing is specified, run **the minimal command that proves *this* change** — typically the single test file or test name covering the task, not the whole suite. (The full typecheck/lint/test suite is the *turn-level* bar the Stop hook and process-gate enforce; the per-task receipt only needs to prove the task's own assertion ran.) Prefer a command that fails when the task's business intent is inverted, per `CLAUDE.md` *Definition of done* — a receipt only proves the command ran, not that it asserts anything load-bearing.

Capture the exit code immediately, before any other command overwrites `$?`:

```bash
# run the task's verify command, then snapshot $? on the SAME line group
"$VERIFY_CMD" ... ; rc=$?
```

### Explicitly opt-in Bash syntax adapter

When verifying shell scripts in the repository, an explicitly opt-in Bash syntax adapter is available under the canonical hooks library (`<same-canonical-hooks-lib>`):

```bash
python3 -I <same-canonical-hooks-lib>/verification-bash.py --cwd <actual-worktree> --harness <actual-harness>
```

Contract and outcomes:
- The adapter emits a structured JSON envelope with status `executed`, `reused`, or `unavailable`.
- **Unavailable**: When dependencies, storage, or execution fail, it exits with status 3 (`status: "unavailable"`).
- **Executed / Reused**: Successful validation returns exit code 0; repeated execution across harnesses with unchanged files and runtime returns `status: "reused"` (exit 0).
- **Parser failures preserved**: Real nonzero parser exit codes (e.g. syntax errors) are strictly preserved and propagated. Failed parsing is never cached or reused as success.
- **Strict bounds**: This adapter is an explicit Bash syntax check only. It is **not** a generic command cache and **never** replaces tests, linters, typechecks, or publication gates.

## 2. Compute the diff stat

The receipt's `diff` field is `git diff --shortstat` reformatted to `+N/-M (K files)`:

```bash
# unstaged working-tree changes:
git diff --shortstat
# → " 3 files changed, 42 insertions(+), 7 deletions(-)"

# staged changes instead (use --cached when the task's work is already staged):
git diff --cached --shortstat
```

**New (untracked) files do not show in `git diff --shortstat` at all** — git only diffs tracked paths, so a task whose entire work is *creating* a file would otherwise produce `+0/-0 (0 files)` and fail to receipt its real change. New-file creation is the most common task kind, so this must work. Before computing the stat, **intent-to-add** the new paths so the diff sees them:

```bash
# make newly-created files visible to `git diff` without staging their content:
git add -N path/to/new-file.ts ...   # intent-to-add (-N); leaves content unstaged
git diff --shortstat                 # now counts the new file's lines as insertions
```

(Equivalently, `git diff HEAD --shortstat` after a real `git add` of the new files; `git add -N` is preferred because it does not stage content you may not yet want staged. Either way the new file must reach the diff before you read the stat.)

Map the `--shortstat` numbers to the marker's three fields:

| `--shortstat` token | marker field |
|---|---|
| `N insertions(+)` | the `+N` |
| `M deletions(-)` | the `-M` |
| `K files changed` | the `(K files)` |

A field `--shortstat` omits is `0` (e.g. an insertions-only change — the common new-file case — prints no `deletions(-)` → `-0`). Result: `diff="+42/-7 (3 files)"`. The ERE the gate validates requires a literal `+<digit>` somewhere in `diff=`, so always emit the `+N` even when `N` is `0`.

## 3. Assemble the canonical marker

Fill the `dod-receipt` grammar from `CLAUDE.md` *Definition of done* (do not restate the grammar here — read it there). The three fields map 1:1:

- `cmd` ← the verification command you ran (step 1)
- `exit` ← its captured exit code (step 1), a literal integer
- `diff` ← the reformatted shortstat (step 2)

Quoting note: the literal `…` (U+2026) in the canonical template is a *placeholder* — a filled receipt puts the real command in `cmd="…"` and a real integer in `exit=`. The gate's validator rejects the unfilled template precisely because `exit=<int>` and `+N/-M` carry no digits; a filled receipt has a digit after `exit=` and a `+<digit>` in `diff=`. Do not paste the template as if it were a receipt.

**State this marker in the turn transcript.** That is where the Stop hook (`stop-verify.sh`, the `last_assistant_message`/transcript scan at line 361) looks for the turn's receipt — `docs/specs/2026-06-02-trellis-process-enforcement-design.md:168`. The receipt's home is the transcript, not the tasks file.

## 4. In-body advisory cores

After a unit's work is verified — and before its boxes are ticked — the execute body runs the same review cores the Stop hook uses, **in-body**, so findings arrive while the loop can still act on them rather than only at end of turn. These are advisory here: they feed back into the rest of the loop, and the cores may be absent entirely.

Review at the **coherent boundary the work was done at**, not once per checkbox. One review over a grouped unit's diff covers that unit; a box whose changes no in-body review saw simply has not been reviewed in-body, and the Stop hook remains armed for it. Do not manufacture a separate review call per box to satisfy a cadence — proportionality is the point. And do not treat a deterministic check as a review: where an independent review is *required*, a green test suite does not supply it, and an unavailable reviewer leaves that requirement visibly unmet rather than quietly satisfied.

### Resolve the canonical root and the core libs

`git rev-parse --git-common-dir` returns the **relative** `.git` in an ordinary checkout (so its bare parent is `.`, cwd-dependent and wrong). Absolutize it, then gate on the **presence of the core file** (`-f`, not `-x`) — not on the directory existing, so a *partial* install advisory-skips rather than trying to run a missing script:

```bash
# worktree-safe canonical root, absolutized (bare git-common-dir is relative ".git"):
ROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir)")" 2>/dev/null && pwd)
if   [ -f "$ROOT/.claude/hooks/lib/code-reviewer.sh" ]; then
  LIBDIR="$ROOT/.claude/hooks/lib"
elif [ -f "$ROOT/.codex/hooks/lib/code-reviewer.sh" ]; then
  LIBDIR="$ROOT/.codex/hooks/lib"
else
  LIBDIR=""   # neither core present → advisory skip, do NOT fail
fi
```

This `cd … && pwd` resolution assumes **cwd = the project root** (which the harness guarantees), so the relative `git-common-dir` absolutizes correctly; a resolution miss only costs a skipped in-body review, never an incorrect tick — so do **not** mix `git -C <dir>` with this cwd-relative `cd`.

Probe with `-f` (presence), not `-x` — the body runs the core via `bash "$LIBDIR/…"`, so the execute bit is irrelevant and `-x` would false-skip a validly-synced core. This matches how the hooks themselves source their siblings. If `LIBDIR` is empty, **advisory skip**: note that in-body review was unavailable and move on. Never fail the task on a missing or partial core.

### Code review — once per unit with a diff

`code-reviewer.sh` is the canonical review decision core. Invoke it via `bash "$LIBDIR/code-reviewer.sh"` (the same way the hook does — `bash "$HOOK_DIR/lib/code-reviewer.sh"`), so the core's execute bit is never required. Read its current header and ladder for the contract. The operator-selected reviewer is exec'd directly and its nonzero exit propagates; keep failed, malformed or unavailable results visible. Internal deterministic fallback can return exit 0 and a findings-only envelope without `status`, so neither an empty findings array nor the absence of `degraded` proves that a model reviewed the artifact. A required independent review remains outstanding without actual reviewer provenance. Surface and resolve findings, or acknowledge-and-defer per `autonomy.md`; do not self-mark your own homework (`CLAUDE.md` *Definition of done*).

### UI verify — UI-affecting tasks only

For a unit that changes UI, also run `ui-verify-core.sh` (same `LIBDIR`). Its contract (see the file header): it prints one line `{"verdict":"skip|advisory|block|pass",...}` and always exits 0. `skip` = no UI files touched; `advisory` = UI changed but no visual tool / dev server reachable (surface, do not block); `pass`/`block` = tool present, screenshot produced or not. Honor `CLAUDE.md` *Definition of done*: logically verified is not visually verified.

### The `.review-done-<hash>` marker is NOT yours to write

**execute writes no review marker — ever.** The marker has exactly one producer: `core-rules/hooks/code-review-subagent.sh` (and its Codex sibling under `core-rules/codex/hooks/`). Read that hook rather than reconstructing it; the details below are a summary of its behavior, not a recipe to reimplement.

The hook keys the marker on `git hash-object --stdin` over its own FULL change set — `git diff HEAD` **plus** the contents of untracked non-ignored files, excluding `.claude/`/`.codex/` — while the reviewer payload stays capped at 200000 bytes — and writes `<repo-root>/.claude/.review-done-<hash>` (`.codex/` in the Codex sibling). It touches that file **only after validating a reviewer envelope normalized to `completed`**; current legacy compatibility treats a missing status as completed. That normalization is not evidence of independent model review. A `degraded` status, a malformed envelope, a failed reviewer, the critical-block path, and an over-cap (prefix-reviewed) diff all deliberately leave no marker, so the next Stop re-reviews.

Three consequences for this skill:

- **Do not hand-mint a marker.** Any prose recipe here would be a second, drifting implementation of a content hash — and hashing the wrong bytes (or with the wrong algorithm) either misses the hook's rendezvous or, worse, writes a name that suppresses a review that never happened. If you find yourself computing a diff hash in the execute body, stop.
- **In-body review does not certify the turn's final artifact.** Every `tick.sh` flip mutates the tracked tasks file, so the diff at end of turn is not the diff any in-body review saw. In-body findings are real feedback on the code as written; they are not a clearance of the post-tick tree, and claiming otherwise would assert a review that did not occur.
- **A legitimate deferral goes through the exported escape, not through a marker.** `export TRELLIS_REVIEW_OVERRIDE=1` — **exported**, not a plain shell var, because the hook reads it via `${TRELLIS_REVIEW_OVERRIDE:-}` in a **child process**. The hook itself appends the dated deferral line to `decisions-log.md`, so the skip is recorded rather than silent. Leaving the marker unwritten is the normal, correct state: it keeps the enforcing Stop hook armed.

When `LIBDIR` was empty (advisory skip), say so — in-body review was unavailable, and the Stop hook is the only review that turn will get.

## 5. Hand the marker to tick.sh

```bash
scripts/tick.sh <tasks-file> <section> <locator> <receipt-marker>
```

- `<tasks-file>` — the `specs/NNN/tasks.md` or `docs/plans/*.md` being walked.
- `<section>` — the **complete header line** that **scopes** the search to a single phase/task block, matched by **exact full-header equality** (`tick.sh` strips leading `#`/whitespace on both the `<section>` arg and each `## ` header, then compares for equality — never a prefix); the scope runs from that matching header to the next `## ` header. A section that equals **no** header → exit 4 (a safe refuse). Pass `""` (empty) to search the whole file. The section is what disambiguates a locator that repeats across the document — a plan that has `Step N: Commit` under every Task, or a file-path that recurs across phases. See `loop.md` for how the loop derives the section.
- `<locator>` — a **fixed string** (not a regex) that, *within the section scope*, matches **exactly one unchecked** checkbox:
  - **LIST locus** (flat `tasks.md`, plan steps, Done-criteria) — Dialect A: the backtick **file-path** substring of the task line; Dialect B: the `Step N:` label. The locator must appear verbatim in the unchecked `- [ ]` line's text.
  - **TABLE locus** (canonical `tasks.md` table) — the task **ID** (e.g. `T7`) that exactly equals the row's first data cell. `tick.sh` matches the first cell by *exact string equality* (`T1` will not match `T10`) and flips the row's **Status** cell.
  - See `loop.md` for how the loop derives the locator and self-checks uniqueness before handing it over. If `tick.sh` finds 0 matches it exits 4; if it finds >1 it exits 5 — in both cases the file is unchanged. Narrow the section or extend the locator and retry; never tick the wrong box.
- `<receipt-marker>` — the assembled marker from step 3, passed as a **single argument** (quote it; it contains spaces). It must be **single-line** — `tick.sh` refuses any receipt containing a newline (exit 3).

tick.sh re-validates the receipt against the canonical ERE before flipping — the no-tick-without-a-well-formed-receipt invariant lives in tick.sh, not in this prose, because within one execute turn the Stop hook does not gate each per-task tick. A malformed, empty, or multi-line marker makes tick.sh exit non-zero and leave the file **byte-unchanged**; treat that as a verify failure and fix the marker rather than the box. **tick.sh writes nothing into the file but the single checkbox flip** — it does not append the receipt.

### What tick.sh structurally enforces (and what it does not)

`tick.sh` structurally guarantees exactly one thing about a tick: that a **well-formed receipt is present** when the box flips. It does **not** — and cannot — enforce that the *verify passed*: a well-formed receipt carrying `exit=1` validates against the ERE just as cleanly as one carrying `exit=0`. **Not ticking a RED verify (`exit ≠ 0`) is loop discipline enforced HERE, in this verify step** (see *Failed verify* below) — it is not, and is not claimed to be, enforced by `tick.sh`. tick.sh proves *a receipt exists*; this step is responsible for *only ticking when that receipt is green*.

## Failed verify (exit ≠ 0)

If the verification command failed:

- **Do NOT tick.** Do not call tick.sh. (tick.sh would happily flip a box for a well-formed `exit=1` receipt — see the note above — so the green-only discipline is yours to hold here, not tick.sh's.)
- **Surface the failure** — the command, its exit code, and the relevant output.
- **Decide retry / stop / continue per `autonomy.md`** — defer to its level matrix; do not restate the levels here. The active level governs *who decides*. Regardless of level, the always-on guardrails hold: a Definition-of-Done receipt for every "done" claim, never `--no-verify`, and **never tick a red verify away**.

A failing receipt is also legitimate provenance when the *task itself* is "make this failing test pass": you record the marker for the **passing** run that completes the task, not the red one that motivated it.

## Worked example — create a new file (the common case; Dialect A, table locus)

Task row (canonical table): `| T7 | Add rate-limiter module `src/mw/ratelimit.ts` | S | T3 | FR-9 | [ ] |`

1. Verify command: `pnpm vitest run src/mw/ratelimit.test.ts` → exit `0`.
2. The module is brand-new, so make it visible to the diff first:

   ```bash
   git add -N src/mw/ratelimit.ts
   git diff --shortstat            # → " 2 files changed, 64 insertions(+)"  → +64/-0 (2 files)
   ```

   (Without the `git add -N`, `git diff --shortstat` would print nothing for the untracked file and the receipt would be `+0/-0`.)
3. Assembled marker (state it in the turn transcript):

   ```
   <!-- dod-receipt cmd="pnpm vitest run src/mw/ratelimit.test.ts" exit=0 diff="+64/-0 (2 files)" -->
   ```

4. In-body review (advisory), **before the tick**: resolve `ROOT`, find `.claude/hooks/lib/code-reviewer.sh` (via `-f`), pipe the unit's diff through `bash "$LIBDIR/code-reviewer.sh"`; this task touches no UI, so skip `ui-verify-core.sh`. Had T7 been implemented alongside a coupled sibling box, this one review over their shared diff would serve both. No marker is written here or anywhere else in the loop (§4).
5. Tick by table ID (exact first-cell match — `T7`, not a substring; flips the row's Status cell):

   ```bash
   scripts/tick.sh specs/014/tasks.md 'Phase 1 — Middleware' 'T7' \
     '<!-- dod-receipt cmd="pnpm vitest run src/mw/ratelimit.test.ts" exit=0 diff="+64/-0 (2 files)" -->'
   ```

   tick.sh validates, finds the one table row whose first cell trims to exactly `T7` with a `[ ]` Status cell, and flips that **last** cell `[ ]` → `[x]` — leaving any `[ ]` inside the Task/Covers cells untouched.
