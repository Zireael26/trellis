# Upgrading a Trellis instance

A deterministic, ordered runbook for updating the Trellis control plane and
propagating the update to every managed project. Trellis is agent-operated, so
this runbook is written to be executed by an LLM/agent: each step is an explicit
command with the output and exit code to expect, and an explicit decision branch
for what to do next.

Run the steps in order. Do not skip Step 0. Do not run any `--fix` command while
Step 0 is failing.

All commands are shown as the underlying scripts under `scripts/`. The thin
dispatcher `scripts/trellis <cmd>` is an equivalent alias (`doctor` →
`doctor.sh`, `onboard` → `onboard-project.sh`, `upgrade` → `upgrade.sh`,
`sync` → `sync-hooks.sh`); either form works. Run every command from the root
of the canonical clone unless told otherwise.

---

## Why this matters (motivating incidents, 2026-05-30)

Two drift incidents in one session motivate this runbook. Read them once; they
explain every precaution below.

1. **A project ran with zero parent rules.** A managed project had no
   `.claude/rules/trellis.md` symlink and its `@`-import pointed at a dead
   cross-machine path. Claude Code drops an unresolved instruction **silently**
   — no error, no warning, no log line. The project ran unparented and nothing
   surfaced it until checked by hand. *Lesson: resolve the symlink target; never
   assume a link named `trellis.md` points where its name implies. `doctor` is
   the deterministic check that catches this.*
2. **The canonical clone was left on a feature branch.** Every project inherits
   rules through a **fixed-path symlink** into the canonical working tree
   (`.claude/rules/trellis.md` → `<canonical>/core-rules/CLAUDE.md`). The link
   resolves to whatever that file contains *right now* — i.e. whatever branch
   the canonical clone happens to be checked out on. A canonical clone on a
   feature branch, or with uncommitted edits, silently feeds **every** project
   stale/unversioned rules. *Lesson: verify the canonical clone is on `main` and
   clean before trusting any inheritance — this is Step 0.*

The fixed-path symlink is the load-bearing mechanism and the dangerous one: it
makes inheritance automatic, but it also means the canonical clone's git state
is part of every project's runtime. Step 0 guards that state.

---

## Step 0 (Tier-0 precondition) — canonical MUST be on `main` and clean

Inheritance reads the canonical working tree at a fixed path. If that tree is on
a feature branch, detached, or dirty, every project silently inherits the wrong
rules. Confirm clean `main` **before** doing anything else.

```sh
git -C __TRELLIS_PATH__ status --short --branch
```

Expected: branch line shows `## main...origin/main` and **no** file lines below
it (a clean tree). Being *ahead of* `origin/main` is normal for the
source-of-truth clone and is fine.

Decision branch:
- **On `main`, clean** → proceed to Step 1.
- **On any other branch / detached HEAD** → switch back first:
  ```sh
  git -C __TRELLIS_PATH__ checkout main
  ```
- **Dirty working tree (uncommitted changes)** → commit or stash them on the
  appropriate branch; the canonical `main` working tree must be clean before it
  can be trusted as the inheritance source. Do **not** proceed with a dirty tree.

`doctor` re-checks this same precondition in Step 4 (the Tier-0 block). If you
are unsure, you may run Step 4's read-only `doctor` now: a green Tier-0 block
(`✓ canonical clone is on main`, `✓ canonical clone is clean`) is the
authoritative confirmation. Note that `doctor` probes the canonical clone via
`git -C "$TRELLIS_ROOT"` (resolved from `trellis.config.json`), **not** its own
cwd — so it is correct even when run from a worktree.

---

## Step 1 — pull the latest canonical

Bring the canonical clone up to date with upstream.

```sh
git -C __TRELLIS_PATH__ pull --ff-only
```

Expected: `Already up to date.` or a fast-forward summary, exit 0.

Decision branch:
- **Exit 0** → proceed.
- **Fast-forward refused / merge conflict** → resolve manually on `main`, then
  re-run. Do not proceed until the pull completes cleanly and the tree is still
  clean (re-confirm Step 0).

---

## Step 2 — re-confirm canonical is on `main` and clean

The pull can leave the tree dirty (e.g. a conflict resolution, a generated
file). Re-assert the Tier-0 precondition before adopting any version.

```sh
git -C __TRELLIS_PATH__ status --short --branch
```

Expected: `## main...origin/main`, no file lines.

Decision branch: same as Step 0. Clean `main` → proceed. Anything else → fix
before continuing.

---

## Step 3 — adopt the version pin (`upgrade.sh --opt-in`)

`upgrade.sh` compares this clone's pinned `trellis_version` against the latest
upstream tag and, with `--opt-in`, writes the new pin into
`trellis.config.json`. Preview first (read-only), then adopt.

Preview (read-only, writes nothing):

```sh
scripts/upgrade.sh
```

Expected: prints `pinned: …`, `latest: …`, and a `diff core-rules/` summary.
- `up-to-date.` (exit 0) → nothing to adopt; skip to Step 4 to verify
  propagation anyway.
- `ahead-of-canonical:` → local pin is newer than the latest tag. Do **not**
  force a downgrade; tag the canonical repo and rerun. Exit 0.
- A pinned → latest diff shown → there is an upgrade to adopt; continue.

Adopt the pin:

```sh
scripts/upgrade.sh --opt-in
```

Expected: prompts `Update trellis.config.json's trellis_version from X → Y?`,
then on `y` prints `updated: <config> (trellis_version=Y)`. After writing the
pin, `upgrade.sh` runs the read-only `doctor` inline (the same check as Step 4)
and then prints the final `next: review the diff, run hooks/tests, commit the
pin change.` line (exit 0); on drift it also prints the
`doctor --fix --dry-run` (preview) and `doctor --fix` (apply) commands between
the doctor output and the `next:` line. So the emission order is
`updated:` → doctor run → (on-drift repair hints) → `next:`. For
non-interactive/agent runs, add `--yes`: `scripts/upgrade.sh --yes --opt-in`.

Decision branch:
- **Exit 0, pin updated** → proceed to Step 4.
- **`WARN: post-write schema validation reported issues` (exit 1)** → the write
  produced an invalid `trellis.config.json`. Inspect it, revert the pin field,
  and do not proceed until the config validates.

Note: adopting the pin records *intent*. It does not by itself re-link any
project. Steps 4–6 are what verify and repair actual propagation.

---

## Step 4 — verify propagation (read-only `doctor`)

Run `doctor` read-only to diagnose Tier-0 and every active project
(`registry.md` minus `blacklist.md`). This is the verification gate after any
update. (`upgrade.sh` also auto-runs this read-only check after adopting a pin;
running it explicitly here is the deterministic, always-correct instruction and
is safe to repeat.)

```sh
scripts/doctor.sh
```

Expected (healthy): a Tier-0 block of `✓` lines, a per-project table of
`✓ / ⚠ / ✗` lines, and a summary. Read-only `doctor` never mutates anything.

```
== Tier 0: global preconditions ==
  ✓ canonical clone is on main
  ✓ canonical clone is clean
  ✓ canonical is in sync with origin/main
  ✓ conformance-check passes (doc path refs resolve)
  ✓ VERSION (X.Y.Z) matches latest CHANGELOG entry
...
== Summary ==
✓ healthy — no drift detected (N project(s) checked)
```

Severity legend (drives the decision branch below):
- **`✗` ERROR** — inheritance is broken (missing/stale rules symlink, dead
  `@`-import target) **or** the canonical clone is off-main/dirty. The affected
  project gets no parent rules. Exit code **1**.
- **`⚠` WARN** — degraded but parented: missing skill/command link, hook drift,
  missing `@`-import fallback, missing harness parity. Exit code **0**.
- **`i` INFO** — `trellis_version` pin trails canonical (rules are current via
  the symlink; only pinned features lag), or canonical is behind origin. Exit
  code **0**.

Exit code summary: `0` healthy (WARN/INFO allowed), `1` on any ERROR, `2` on bad
arguments.

Decision branch on the summary:
- **`✓ healthy` (exit 0)** → done. No repair needed.
- **`✗` ERROR present (exit 1)** → there is broken inheritance or a Tier-0
  failure.
  - If Tier-0 itself shows a `✗` (canonical off-main/dirty) → **stop**. Return
    to Step 0; do not run `--fix`. `--fix` deliberately skips repair while a
    Tier-0 ERROR stands, because onboarding against an off-main/dirty canonical
    would re-link every project to the wrong rules.
  - If Tier-0 is green but a project shows a `✗` → proceed to Step 5 to preview
    a repair.
- **`⚠` WARN only (exit 0)** → degraded, not broken. Repair is recommended but
  not urgent; proceed to Step 5 to preview, or accept the warnings. Read the
  per-project lines and the `== Suggested actions ==` block: hook-drift warnings
  require the gated `--fix-hooks` (Step 5), and `@`-import / `settings.json`
  `.hooks` drift are reported as **manual** (doctor never edits a user's
  `CLAUDE.md` or guesses hook wiring).
- **`i` INFO only (exit 0)** → inheritance healthy; only the version pin or
  origin sync lags. No `--fix` needed. A pin-lag note is cleared by re-running
  Step 3 (`upgrade.sh --opt-in`), which is a deliberate opt-in, never automatic.

---

## Step 5 — preview the repair (`doctor --fix --dry-run`)

Only reached when Step 4 reported a fixable `✗`/`⚠` (Tier-0 green). `--dry-run`
prints exactly what `--fix` would do, per project, and touches nothing. It
always exits 0.

```sh
scripts/doctor.sh --fix --dry-run
```

If hook drift is among the findings and you intend to re-sync hooks (which
changes enforcement behavior), include the gate in the preview too:

```sh
scripts/doctor.sh --fix --fix-hooks --dry-run
```

Expected: a per-project plan with tagged lines — `[auto]` (symlink/skill/
command/settings repair, delegated to the idempotent never-clobber
`onboard-project.sh`), `[hooks]` (only acted on with `--fix-hooks`), `[manual]`
(dead `@`-import, `settings.json` `.hooks` drift — reported, never auto-applied),
`[info]` (version-pin lag) — ending with
`== Summary (--dry-run: nothing applied) ==`.

Decision branch:
- **Plan matches what you expect** → proceed to Step 6.
- **Plan proposes an unexpected change** (e.g. an `rm` of a symlink you did not
  expect to be stale) → stop and investigate the source link before applying.
- **Only `[manual]` items remain** → there is nothing for `--fix` to apply.
  Perform the manual edits by hand (e.g. repoint the `@`-import in the project's
  `CLAUDE.md`), then re-run Step 4. Skip Step 6.

A standalone `--dry-run` without `--fix` is rejected with exit 2
(`doctor: --dry-run is only valid with --fix`); always pair them.

---

## Step 6 — apply the repair (`doctor --fix`)

Apply the previewed plan. `--fix` mutates real project repos; it delegates to
the idempotent never-clobber treatments, so it is safe to repeat. The exit code
reflects the **post-fix** state.

```sh
scripts/doctor.sh --fix
```

To also re-sync drifted hook copies (gated because it changes enforcement
behavior), add `--fix-hooks`:

```sh
scripts/doctor.sh --fix --fix-hooks
```

To repair a single project, scope with `--project`:

```sh
scripts/doctor.sh --fix --project NAME
```

Expected: per project, the applied `[auto]`/`[hooks]` actions, then a
`-- re-checking NAME after fixes --` block showing the post-repair status, then
the summary.

Decision branch:
- **Summary `✓ healthy` (exit 0)** → repair succeeded; proceed to Step 7.
- **`✗` still present (exit 1)** → some failure was not auto-fixable (it was a
  `[manual]` item) or a Tier-0 ERROR is blocking `--fix`. Read the per-project
  lines: do the manual fix by hand, or clear Tier-0 (Step 0), then re-run.

Note: `--fix` running `onboard-project.sh` to repair a symlink also seeds any
**missing** hooks/`settings.json` as a side effect (onboard never-clobbers
existing files). It never **updates** a stale hook — that always requires
`--fix-hooks`.

---

## Step 7 — confirm green (read-only `doctor`)

Re-run the read-only check to confirm the repair held and nothing regressed.

```sh
scripts/doctor.sh
```

Expected: `== Summary ==` → `✓ healthy — no drift detected (N project(s)
checked)`, exit 0.

Decision branch:
- **Exit 0, `✓ healthy`** → the upgrade is complete and propagated. Commit the
  `trellis.config.json` pin change (and any other intended canonical edits) on
  `main`.
- **Exit non-zero** → drift remains. Return to Step 4 and work the branch again;
  do not consider the upgrade complete.

---

## Worktrees of managed projects

Every linked worktree must carry the Trellis inheritance symlinks. `git worktree
add` does not recreate gitignored files, so a fresh worktree starts unparented
by default.

- **Native-`.githooks` projects (lume, clusterbid-console):** `post-checkout`
  fires automatically — the worktree is seeded at creation, first-session-correct
  on raw `git worktree add`.
- **Husky projects and all others:** use `trellis worktree add <path>` (the
  universal eager front door). On raw `git worktree add`, the SessionStart
  safety-net detects the gap, seeds for the *next* session, and emits a loud
  restart warning — no project fails silently, but a restart is required.
- **Repair after the fact:** `trellis doctor` (Tier-1 `hc_worktree_inheritance`)
  flags any linked worktree missing inheritance; `doctor --fix` repairs it via
  the seeder.

---

## Reference — scripts used by this runbook

- `scripts/doctor.sh` — read-only inheritance health check; `--fix` repair.
  Flags: `[--project NAME] [--fix [--dry-run] [--fix-hooks]]`. Exit `0` healthy,
  `1` on ERROR, `2` on bad args.
- `scripts/upgrade.sh` — version-pin comparison; `--opt-in` adopts the latest
  tag into `trellis.config.json`; `--yes` for non-interactive; `--check` exits
  1 on drift without writing.
- `scripts/trellis <cmd>` — thin dispatcher; `doctor | onboard | upgrade | sync`
  map to the scripts above. `scripts/trellis` with no args (or `help`) lists the
  subcommands.

## One-glance sequence

```
0. git -C <canonical> status --short --branch   # MUST be: on main, clean
1. git -C <canonical> pull --ff-only
2. git -C <canonical> status --short --branch   # re-confirm main + clean
3. scripts/upgrade.sh            then  scripts/upgrade.sh --opt-in   # (--yes for agents)
4. scripts/doctor.sh                                   # read-only verify; branch on ✗/⚠/i
5. scripts/doctor.sh --fix --dry-run                   # preview (only if Step 4 found fixable drift)
6. scripts/doctor.sh --fix [--fix-hooks] [--project N] # apply
7. scripts/doctor.sh                                   # confirm ✓ healthy (exit 0)
```
