# Reference — Per-task verification + receipt protocol

This is the step the loop runs **after each checkbox's implementation work completes** and **before** the box is ticked. It produces the one artifact that authorizes the tick: a canonical Definition-of-Done receipt. The loop never hand-edits a checkbox and never ticks without a well-formed receipt — all checkbox mutation goes through `scripts/tick.sh`, which re-validates the receipt before flipping the box (see `loop.md` for the loop mechanics, `scripts/tick.sh` for the contract).

The receipt is recorded in the **transcript** (the agent's turn message / `last_assistant_message`) — that is the receipt's durable home and what the Stop hook (`stop-verify.sh`) actually checks at end-of-turn (`docs/specs/2026-06-02-trellis-process-enforcement-design.md:168`). `tick.sh` does **not** write the receipt into the tasks file: it *validates* the receipt as the gate that proves `execute` constructed a well-formed one, and on success flips the single matching checkbox — and changes nothing else in the file. So the per-task receipt you assemble here is *stated to the transcript*, and the same string is handed to `tick.sh` purely so the flip is gated on a valid receipt.

The receipt grammar is canonical and defined once, in `CLAUDE.md:43`. This document does not redefine it — it describes how to *fill* it per task and where to hand it. The same marker is what the Stop hook checks at end-of-turn; the per-task receipt and the turn receipt are the same grammar.

## Sequence per task

1. **Run the task's verification command.** Capture its exit code.
2. **Compute the diff stat** for the work just done (including any newly-created files — see step 2).
3. **Assemble the canonical marker** by filling the `CLAUDE.md:43` grammar, and **state it in the turn transcript** (this is the receipt the Stop hook reads).
4. **Run the in-body advisory cores** over the task's just-implemented diff (code review always; UI verify for UI-affecting tasks), **before the tick**. These reviews are **advisory feedback for the rest of the loop** — they do **not** write any marker. (The `.review-done-<hash>` dedup marker is a *turn-level* artifact written once, after the final task's tick — see §4 *Write the idempotency marker*.)
5. **Hand the marker to `scripts/tick.sh`** with the box's section + locator. tick.sh re-validates and (only on a valid receipt) flips the box. It writes nothing else.

Step 5 (the tick) is conditional on step 1: **a failed verify never ticks** (see *Failed verify* below).

These two timings are **separate concerns**: per-task review happens during the loop, on the implemented diff before that task's tick (advisory); the `.review-done-<hash>` marker is written exactly once at turn-end, after the final tick, and only if every in-body review that turn was critical-free (see §4 *Write the idempotency marker*).

## 1. Run the verification command

Use what the task or plan specifies:

- **Dialect A** (`specs/NNN/tasks.md`): the task line or its Phase header names the command, or the spec's acceptance criteria do.
- **Dialect B** (`docs/plans/*.md`): the Step / Task block names the command (build, lint, the specific test).

If nothing is specified, run **the minimal command that proves *this* change** — typically the single test file or test name covering the task, not the whole suite. (The full typecheck/lint/test suite is the *turn-level* bar the Stop hook and process-gate enforce; the per-task receipt only needs to prove the task's own assertion ran.) Prefer a command that fails when the task's business intent is inverted, per `CLAUDE.md:47` — a receipt only proves the command ran, not that it asserts anything load-bearing.

Capture the exit code immediately, before any other command overwrites `$?`:

```bash
# run the task's verify command, then snapshot $? on the SAME line group
"$VERIFY_CMD" ... ; rc=$?
```

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

Fill the grammar from `CLAUDE.md:43` (do not restate the grammar here — read that line). The three fields map 1:1:

- `cmd` ← the verification command you ran (step 1)
- `exit` ← its captured exit code (step 1), a literal integer
- `diff` ← the reformatted shortstat (step 2)

Quoting note: the literal `…` (U+2026) in the `CLAUDE.md:43` template is a *placeholder* — a filled receipt puts the real command in `cmd="…"` and a real integer in `exit=`. The gate's validator rejects the unfilled template precisely because `exit=<int>` and `+N/-M` carry no digits; a filled receipt has a digit after `exit=` and a `+<digit>` in `diff=`. Do not paste the template as if it were a receipt.

**State this marker in the turn transcript.** That is where the Stop hook (`stop-verify.sh`, the `last_assistant_message`/transcript scan at line 361) looks for the turn's receipt — `docs/specs/2026-06-02-trellis-process-enforcement-design.md:168`. The receipt's home is the transcript, not the tasks file.

## 4. In-body advisory cores

After a task's work is verified — and before its box is ticked — the execute body runs the same review cores the Stop hook uses, **in-body**, so review happens per-task instead of once per turn. These are advisory here — on a hook-less / non-onboarded harness (pure AntiGravity) a skill body cannot reject a turn, and the cores may be absent entirely. The per-task reviews feed back into the rest of the loop; the dedup *marker* they relate to is written only once, at turn-end (see *Write the idempotency marker* below).

### Resolve the canonical root and the core libs

`git rev-parse --git-common-dir` returns the **relative** `.git` in an ordinary checkout (so its bare parent is `.`, cwd-dependent and wrong). Absolutize it, then gate on the **presence of the core file** (`-f`, not `-x`) — not on the directory existing, so a *partial* install advisory-skips rather than trying to run a missing script:

```bash
# worktree-safe canonical root, absolutized (bare git-common-dir is relative ".git"):
ROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir)")" 2>/dev/null && pwd)
if   [ -f "$ROOT/.claude/hooks/lib/code-reviewer.sh" ]; then
  LIBDIR="$ROOT/.claude/hooks/lib"; HARNESS=claude
elif [ -f "$ROOT/.codex/hooks/lib/code-reviewer.sh" ]; then
  LIBDIR="$ROOT/.codex/hooks/lib";  HARNESS=codex
else
  LIBDIR=""   # neither core present → advisory skip, do NOT fail
fi
```

This `cd … && pwd` resolution assumes **cwd = the project root** (which the harness guarantees), so the relative `git-common-dir` absolutizes correctly; the resulting marker is a *best-effort* dedup — a resolution miss only causes a redundant review, never an incorrect tick — so do **not** mix `git -C <dir>` with this cwd-relative `cd`.

Probing the file with `-f` (presence, not the execute bit) **matches the Codex hook's own `[ ! -f "$HOOK_DIR/lib/code-reviewer.sh" ] → skip` guard, `core-rules/codex/hooks/code-review-subagent.sh:168`**. `-x` would *false-skip* a validly-synced core: a sync may deploy the script without the execute bit, and since the body runs it via `bash "$LIBDIR/code-reviewer.sh"` (below), the execute bit is irrelevant to whether it can run. A half-synced install — the `lib/` dir exists but the script was not deployed — still advisory-skips under `-f`, because the file is genuinely absent. If `LIBDIR` is empty, **advisory skip**: note that in-body review was unavailable and move on. Never fail the task on a missing or partial core.

### Code review — every task with a diff

`code-reviewer.sh` is the canonical review decision core. Invoke it via `bash "$LIBDIR/code-reviewer.sh"` (the same way the hook does — `bash "$HOOK_DIR/lib/code-reviewer.sh"`), so the core's execute bit is never required. Its contract (see the file header — do not restate it): stdin is a review envelope (`{diff, autonomy_level, decisions_log}` JSON, or a raw unified diff); stdout is exactly one line `{"findings":[...]}`; it always exits 0 and fails open. The body decides what to do with the findings — surface and resolve, or acknowledge-and-defer per `autonomy.md`. You do not self-mark your own homework (`CLAUDE.md:45`).

### UI verify — UI-affecting tasks only

For a task that changes UI, also run `ui-verify-core.sh` (same `LIBDIR`). Its contract (see the file header): it prints one line `{"verdict":"skip|advisory|block|pass",...}` and always exits 0. `skip` = no UI files touched; `advisory` = UI changed but no visual tool / dev server reachable (surface, do not block); `pass`/`block` = tool present, screenshot produced or not. Honor `CLAUDE.md:46`: logically verified is not visually verified.

### Write the idempotency marker — ONCE, at turn-end, after the final tick

This step is **turn-level, not per-task.** The per-task reviews above are advisory feedback for the loop; they write **no** marker. The `.review-done-<hash>` marker is written **exactly once per turn**, **after the final task's tick** (§5), as a single dedup token meaning *"this exact final diff was reviewed AND cleared in-body"* — which lets the Stop hook skip its one end-of-turn review.

**Why after the final tick — not per task.** Each `tick.sh` flip mutates the *tracked* tasks file, so the working-tree diff changes with every tick. Only the diff taken **after the last tick** is byte-identical to what the Stop hook hashes when it fires at end-of-turn. Keying the marker to a per-task (pre-final-tick) diff would hash bytes the hook never sees, miss the rendezvous, and get the turn double-reviewed — the exact waste this marker exists to prevent. So compute the hash once, after the final tick.

The hash must cover the **same bytes the Stop hook hashes**: `git diff HEAD` capped at **200000** bytes (`head -c 200000`) — the single source of that cap being `core-rules/hooks/code-review-subagent.sh:168` (the Claude hook). The marker scheme (sha256 of the capped diff, harness-keyed path) is likewise defined in `core-rules/hooks/code-review-subagent.sh`. Hashing un-capped bytes would make any diff over 200 KB miss the hook's rendezvous and get double-reviewed.

```bash
DIFF=$(git diff HEAD | head -c 200000)                              # SAME cap as core-rules/hooks/code-review-subagent.sh:168
DIFF_HASH=$(printf '%s' "$DIFF" | shasum -a 256 | awk '{print $1}') # macOS has no sha256sum
case "$HARNESS" in
  claude) mkdir -p "$ROOT/.claude" && : > "$ROOT/.claude/.review-done-${DIFF_HASH}" ;;
  codex)  mkdir -p "$ROOT/.codex"  && : > "$ROOT/.codex/.review-done-${DIFF_HASH}"  ;;
esac
```

**The marker means "reviewed AND cleared", not merely "reviewed".** Write it **only if EVERY in-body review that turn came back critical-free** (clean, or advisory-only) — it is a turn-level aggregate over all the per-task reviews, not a verdict on the last task alone. This is the highest-leverage discipline in this step: the Stop hook treats the marker as permission to skip its own review, so writing it on a turn that still has an unresolved critical would *bypass the very block the hook exists to enforce* on edit-heavy turns. Therefore:

- **All in-body reviews clean / advisory-only** → write the marker (once, post-final-tick). The Stop hook skips its redundant re-review of this identical diff.
- **Any in-body review returned an unresolved `critical`** → **do NOT write the marker.** Either fix the critical (which changes the diff, re-hashes, and re-reviews anyway), or — if the operator *legitimately defers* it — route the deferral through the **exported** escape: `export TRELLIS_REVIEW_OVERRIDE=1`. It must be **exported**, not a plain shell var: the Stop hook reads it via `${TRELLIS_REVIEW_OVERRIDE:-}` in a **child process**, so a non-exported variable never crosses the process boundary and the override would be silently ignored. The override is logged to the decisions-log (`docs/specs/2026-06-02-trellis-process-enforcement-design.md:166`) — it is **not** a silent marker write. Leaving the marker unwritten keeps the enforcing Stop hook armed so it still re-reviews and blocks.
- When `LIBDIR` was empty (advisory skip), write **no** marker — there was no review to clear.

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

## Worked example

### Edit an existing file (Dialect A)

Task: ``- [ ] `src/auth/session.ts` — add idle-timeout to session refresh``

1. Verify command (named by the task's test): `pnpm vitest run src/auth/session.test.ts` → exit `0`, captured as `rc=0`.
2. `git diff --shortstat` → ` 2 files changed, 18 insertions(+), 3 deletions(-)` → `+18/-3 (2 files)`.
3. Assembled marker (state it in the turn transcript):

   ```
   <!-- dod-receipt cmd="pnpm vitest run src/auth/session.test.ts" exit=0 diff="+18/-3 (2 files)" -->
   ```

4. In-body review (advisory), **before the tick**: resolve `ROOT`, find `.claude/hooks/lib/code-reviewer.sh` (via `-f`), pipe `git diff HEAD | head -c 200000` through `bash "$LIBDIR/code-reviewer.sh"`; this task touches no UI, so skip `ui-verify-core.sh`. The review is advisory — **no marker is written here.** The single `.review-done-<hash>` marker is written once at turn-end, after the final tick, only if every in-body review that turn was critical-free (see §4 *Write the idempotency marker*).

5. Tick (section scopes to the phase; locator selects the one unchecked box in it):

   ```bash
   scripts/tick.sh specs/014/tasks.md 'Phase 2 — Session hardening' 'src/auth/session.ts' \
     '<!-- dod-receipt cmd="pnpm vitest run src/auth/session.test.ts" exit=0 diff="+18/-3 (2 files)" -->'
   ```

   tick.sh re-validates the receipt, flips the single unchecked `- [ ]` whose text contains `src/auth/session.ts` to `- [x]`, and writes nothing else.

### Create a new file (the common case — Dialect A, table locus)

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

4. In-body review (advisory), **before the tick**, as above — no marker written per task. The single turn-level `.review-done-<hash>` marker is written once at turn-end, after the final tick, only if every in-body review that turn was critical-free (see §4 *Write the idempotency marker*).
5. Tick by table ID (exact first-cell match — `T7`, not a substring; flips the row's Status cell):

   ```bash
   scripts/tick.sh specs/014/tasks.md 'Phase 1 — Middleware' 'T7' \
     '<!-- dod-receipt cmd="pnpm vitest run src/mw/ratelimit.test.ts" exit=0 diff="+64/-0 (2 files)" -->'
   ```

   tick.sh validates, finds the one table row whose first cell trims to exactly `T7` with a `[ ]` Status cell, and flips that **last** cell `[ ]` → `[x]` — leaving any `[ ]` inside the Task/Covers cells untouched.
