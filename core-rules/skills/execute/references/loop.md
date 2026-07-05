# Reference — The execute loop (multi-shape parse + tick)

The shared, harness-neutral builder loop. `execute` walks a task list and
implements it one tickable unit at a time. It is the same loop on Claude and on
Codex. `execute` **never merges**.

For per-turn cadence and the autonomy slider, see [`autonomy.md`](../../../autonomy.md);
for the per-unit verify→receipt→tick mechanics, see
[`verification-step.md`](verification-step.md). This file specifies the *outer
loop*: how to read a task list, locate a unit, and where checkbox mutation goes.
The receipt grammar is **not** redefined here — it is `CLAUDE.md:43`.

## Input shapes — two file kinds, three checkbox shapes, two checkbox loci

`execute` consumes exactly one task-list file per run. There are two **file
kinds** (`specs/NNN/tasks.md` and `docs/plans/*.md`) and, across them, three
**checkbox shapes**. The checkbox *content* token is identical everywhere (`[ ]`
unchecked, `[x]` checked); what diverges is (a) where the box lives — a markdown
**list** item vs. a **table** Status cell — and (b) the **locator** that names a
single task. `scripts/tick.sh` auto-detects the *locus* (list vs. table) line by
line; the loop's only job is to derive, per box, a **(section, locator)** pair
that selects exactly one unchecked box.

### File-kind + shape detection

Resolve the task-list path relative to the canonical repo root, match the path
shape, then — for `specs/NNN/tasks.md` only — look at the file contents:

1. `specs/<NNN>-*/tasks.md` (three-digit-prefixed spec dir, basename literally
   `tasks.md`) → a **spec tasks file**, which is EITHER of two shapes:
   - **Canonical TABLE** (the primary shape — what the `tasks` skill emits, see
     `core-rules/skills/tasks/references/tasks-template.md`): a Markdown table
     under `## Tasks` whose header row begins `| ID | Task |` and whose rows are
     keyed by `T<N>` with a trailing `[ ]`/`[x]` **Status cell**.
   - **Flat LIST** (the `specs/001-process-enforcement/tasks.md` dogfood
     divergence): `## Phase <N> — <title>` headers with flat `- [ ]` lines.
   Tell them apart by content: a leading `| ID | Task |` table header ⇒ table;
   `## Phase` headers with `- [ ]` lines ⇒ flat list. (A canonical table file
   also contains a `## Done criteria` **list** and a Coverage-map table — see
   *Two checkbox loci* below; the file kind is still "canonical table".)
2. `docs/plans/*.md` → a **plan file** (always the nested-list shape below).

If a path matches neither file kind, do not guess — stop and surface the path to
the user. The file kind is decided once, up front. The table-vs-flat distinction
within a spec tasks file is also a one-time read of the file's structure.

### Two checkbox loci (what `tick.sh` auto-detects)

A single file may contain both loci; `tick.sh` classifies each line:

- **LIST locus** — a line matching the prefix-anchored unchecked pattern
  `^[[:space:]]*- \[ \]`. Covers the flat tasks.md lines, the plan `Step N:`
  lines, and the `## Done criteria` items in a canonical tasks.md.
- **TABLE locus** — a row that starts with `|` whose first data cell (trimmed)
  exactly equals the locator and whose **last** cell (trimmed) is `[ ]`. Covers
  the canonical `## Tasks` Status cells. (A Task or Covers cell may itself
  contain `[ ]`; the table rule flips only the *last* cell, never an interior
  one.)

The loop does not pick the locus — it derives `(section, locator)` and hands it
over; `tick.sh` detects which locus the matched line is.

### Shape 1 — Canonical TABLE `specs/NNN/tasks.md` (PRIMARY)

```
| ID | Task | Est. | Depends | Covers (spec §3 criterion) | Status |
|----|------|------|---------|------|--------|
| T1 | Add execute to onboard-project.sh | ~2h | — | §3.1 | [ ] |
| T2 | Document the receipt grammar | ~1h | T1 | §3.2 | [ ] |
```

- The `analyze` skill reads the **Covers** and **Depends** columns, so the table
  is load-bearing — it is never flattened.
- The unit is one **table row**, located by its `T<N>` ID. `T<N>` IDs are
  document-unique by construction, so no section qualifier is needed.

### Shape 2 — Flat LIST `specs/NNN/tasks.md` (dogfood divergence)

```
## Phase 0 — Seeding machinery + canonical receipt contract
- [x] `scripts/onboard-project.sh` — add `execute` to both blocks.
- [ ] `core-rules/hooks.md` — document the receipt marker grammar.
```

- Headers are `## Phase <N> — <title>` (em-dash U+2014).
- Each checkbox carries a **backtick file-path** then ` — <description>`.
- The unit is located by that backtick file-path — but a path can repeat across
  phases, so the path MUST be scoped by its **full `## Phase N — title` header
  line** (passed as `<section>`, matched by exact equality — see §3).

### Shape 3 — Nested LIST `docs/plans/*.md`

```
## Task 1: Bump VERSION 0.3.0 → 0.4.5
- [ ] **Step 1: Update VERSION**
- [ ] **Step 2: Verify**
- [ ] **Step 3: Commit**

## Task 2: Schema — add `autonomy_default` field
- [ ] **Step 1: Add field to schema**
- [ ] **Step 2: Validate the schema parses**
```

- Headers are `## Task <N>: <title>`.
- Each checkbox carries a bold `**Step <N>: <label>**`.
- The unit is located by its `Step <N>:` label, scoped by its **full
  `## Task N: title` header line** (passed as `<section>`, matched by exact
  equality — see §3) — `Step N:` labels repeat under every Task (and
  `Step N: Commit` recurs ~10× across a real plan), so the section qualifier is
  mandatory.

## The loop

### 1. Enumerate

Read the file once. Collect every **unchecked** box in **document order** —
LIST lines (`- [ ]`) and TABLE rows with a `[ ]` Status cell alike. Checked
boxes (`- [x]`, or a `[x]` Status cell) are already done — skip them. The
receipt that authorized each prior tick lives in the **transcript**, not in the
file (the tasks file carries only the flipped checkbox — see §4), so there is
nothing to read back from a checked box. Document order is the execution order;
do not reorder.

### 2. The tickable unit = the checkbox

The checkbox is the single unit common to every shape — a LIST `- [ ]` line or a
TABLE `[ ]` Status cell — and it is the unit of work, of verification, of
receipt, and of tick.

- **Default: one subagent per checkbox.** Implement it, verify it, emit its
  receipt, tick it — then move to the next.
- **Batching latitude:** consecutive checkboxes **under the same header** that
  are *trivially coupled* — the canonical case being the edit + verify + commit
  of one logical change (e.g. the plan "Step 1: Update / Step 2: Verify /
  Step 3: Commit" of a single edit) — MAY be handled by one subagent. Batching
  is a dispatch convenience only: **each box is still verified, receipted, and
  ticked individually.** Never tick a box whose work or verification was folded
  into a sibling. Never batch across a header boundary.

### 3. Locator derivation — a `(section, locator)` pair per box

For each box, derive a **`(section, locator)` pair** that selects **exactly one**
unchecked box. `tick.sh <tasks-file> <section> <locator> <receipt>` first scopes
the search to `<section>` (lines from the matching `## ` header to the next `## `
header; an empty `""` means the whole file), then within that scope requires
**exactly one** unchecked box to match `<locator>`: 0 matches → exit 4, >1 →
exit 5, file unchanged either way. The **section** is what disambiguates
collisions; the locator stays a short fixed string. tick.sh treats the locator as
a fixed string (never a regex), matching it via `index()` on a LIST line or by
**exact** first-cell equality on a TABLE row.

**Section is matched by EXACT full-header equality — never a prefix.** Pass
`<section>` as the **complete header line text** — the whole `## Phase N — title`
/ `## Task N: title` / `## Tasks` line exactly as it appears above the task.
`tick.sh` normalizes both the `<section>` arg and each `## ` header by stripping
leading `#` characters and surrounding whitespace, then scopes on **exact
equality** (`hnorm == snorm`) — so passing the header with or without the leading
`## ` both work. Because the match is exact rather than a prefix, passing the full
`## Phase 1 — …` line scopes to **that header alone**; it cannot also open at
`## Phase 10`, `## Phase 1.5`, `## Phase 1-rework`, `## Phase 1_x`, or
`## Phase 1b` — the cases a prefix/boundary-char approach admits. If **no** `## `
header normalizes to exactly the section, `tick.sh` refuses with **exit 4** (a
safe refuse — never a wrong-box tick), so the loop must pass the header
**verbatim** as it appears above the target box. An empty `<section>` (`""`) still
means whole-file (no header scoping).

Task-section headers are **`## `-level (H2)** across all three input shapes
(phase, task, and table headers); `tick.sh` opens/closes a scope only on `## `
headers, so a `### ` (H3) subheading **inside** a section does not close its
scope (its boxes stay in the enclosing `## ` section). Note `hnorm`/`snorm`
strip *all* leading `#` chars, so passing `### Tasks` as `<section>` normalizes
to `Tasks` and scopes to the `## Tasks` header — exactly as passing the header
with or without its leading `## ` does; level is not part of the match.

- **Canonical TABLE `tasks.md`** → section = the **full `## Tasks` heading line**;
  locator = the row **ID** `T<N>` (e.g. `T2`). The match is **exact string
  equality** on the trimmed first cell, so `T1` does not match `T10`. Scoping to
  `## Tasks` provably keeps the search out of the `## Done criteria` LIST (whose
  `- [ ]` lines tick.sh matches by *substring*, so a stray `T<N>` there could
  otherwise collide) and out of the Coverage-map table. `section ""` (whole file)
  also works because `T<N>` IDs are doc-unique by construction, but `## Tasks` is
  the airtight default. This is the primary shape.
- **Flat LIST `tasks.md`** → section = the enclosing header's **complete line**,
  e.g. `` `## Phase 0 — Seeding machinery + canonical receipt contract` ``;
  locator = the backtick **file-path** (e.g. `core-rules/hooks.md`). The path MUST
  be Phase-scoped: the same path can recur across phases, and only the section
  makes it unique. Pass the **full Phase header line** so the exact-equality scope
  binds `Phase 1` to its own phase and not to `## Phase 10` / `## Phase 1.5`.
- **Plan `docs/plans/*.md`** → section = the enclosing header's **complete line**,
  e.g. `` `## Task 1: Bump VERSION 0.3.0 → 0.4.5` ``; locator = the `Step N:`
  label (e.g. `Step 2: Verify`). The label MUST be Task-scoped: `Step N:` repeats
  under every Task and `Step N: Commit` recurs ~10× across a real plan; the
  section is what makes a bare `Step N:` resolve to one box. Pass the **full Task
  header line** (exact-equality scope, so `Task 1:` never leaks into `## Task 10:`).
  The locator is a contiguous fixed string from the target line; it does not span
  the header.

Self-check before calling `tick.sh`: within the chosen section, the locator must
match exactly one unchecked box. If you cannot make it unique even with the
section, the task list is malformed — surface it rather than risk the wrong box
(tick.sh will refuse with exit 5 regardless).

### 4. R1 isolation — all checkbox mutation goes through `tick.sh`

This is the entire point of the shared loop. **The loop NEVER edits a checkbox by
hand.** Every flip from `[ ]` to `[x]` — LIST line or TABLE Status cell, any
shape — is delegated to
`scripts/tick.sh <tasks-file> <section> <locator> <receipt>`. One mutation path,
one receipt-validation point, no per-shape edit code to drift apart.

`tick.sh` is the load-bearing isolation point (R1):

- It validates the receipt against the canonical ERE (copied byte-for-byte from
  `core-rules/hooks/stop-verify.sh`) and **writes nothing without a valid
  receipt** (exit 3). A receipt containing a newline is rejected outright (also
  exit 3).
- It scopes to `<section>` and locates the single matching unchecked box
  (exit 4 = none, exit 5 = ambiguous; file byte-unchanged in both).
- On exactly one match it flips **only that one checkbox** — the LIST line's
  leading `- [ ]` → `- [x]`, or the TABLE row's **last** cell `[ ]` → `[x]` —
  and writes back atomically. **It appends nothing.** The receipt is recorded in
  the transcript (where the Stop hook checks it — see §5), never written into the
  tasks file; the single flipped checkbox is the *only* byte change.
- Idempotent: a locator that already points at a checked box is a no-op (exit 0).

The loop's job is to feed it a unique `(section, locator)` pair and a valid
receipt — never to touch the markdown itself.

Why receipt validation lives in `tick.sh` and not in the Stop hook: within a
single `execute` turn the Stop hook fires once, at end of turn — it does not gate
each per-task tick. If the no-receipt-no-tick invariant lived only in prose, a
mid-turn tick could land without a receipt and the turn could still pass. Putting
it in `tick.sh` makes the invariant **structural for "a well-formed receipt is
present at tick time"** — that, and only that, is what tick.sh can guarantee. It
is *not* a guarantee that the verify passed: the canonical ERE accepts any
`exit=<digit>`, so `exit=1` (a red verify) is just as well-formed as `exit=0`.
The **"never tick a red verify" rule is loop discipline**, owned by
[`verification-step.md`](verification-step.md), not enforced by `tick.sh`.

### 5. Verification + receipt (per unit)

Each box is verified and a receipt emitted before its tick. Mechanics —
what command to run, how to read its exit code, how to compute the diff line
counts, and the in-body advisory cores — live in
[`verification-step.md`](verification-step.md), not here. The receipt's
machine-readable form is the marker defined at `CLAUDE.md:43`; the loop passes
that exact marker string as `tick.sh`'s **fourth** argument and also surfaces it
in the turn transcript, which is where the Stop hook validates it.

### 6. Termination — stop conditions and hand-off

The loop stops on any of **three** conditions:

- **All boxes are ticked** — the task list is complete. Hand off to the
  `process-gate` skill.
- **A process-gate checkpoint is reached** — a point in the list where the
  process-gate must run (e.g. a phase boundary that gates a PR, or an explicit
  gate marker in the plan). Hand off to the `process-gate` skill.
- **A task's verify is red** — a box whose verification command failed is
  **never silently skipped**. The failure (command, exit code, output) is
  surfaced and the loop **halts or defers per `autonomy.md`** (cite it; do not
  restate the level matrix). The red box is not ticked — a non-zero `exit=` is
  well-formed to `tick.sh` but ticking it is forbidden by loop discipline (§4,
  and [`verification-step.md`](verification-step.md) *Failed verify*).

**Default autonomy level when none is configured.** If no `autonomy.md` applies
or no level is set — the hook-less / non-onboarded case, where no turn-level
hooks apply — default to the **most conservative** behavior: **surface
and wait** for a human decision. Do not auto-retry or auto-defer in the absence
of an explicit configured level.

On the two completion conditions `execute` **hands off to the `process-gate`
skill** and stops. `execute` builds and ticks; it does not run the pre-PR gate
itself and it **never merges** to `main`. Merge is downstream of the gate's
verdict and outside this skill entirely.

## In-body advisory cores

When `execute` runs its in-body review/UI cores mid-loop, it follows
[`verification-step.md`](verification-step.md) — the single source for canonical-
root resolution, the core-lib probe, the advisory-skip when no core is present,
and the harness-matching `.review-done-<hash>` idempotency marker. The loop does
not re-specify any of that here.
