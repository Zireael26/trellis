---
description: Run the deterministic Trellis inheritance health check (read-only), summarize the per-project results, and — only on request — preview and apply repairs.
argument-hint:
---

# Trellis doctor

You are running `trellis doctor` to check that every active project is still correctly parented to the canonical Trellis rules. This is the deterministic, on-demand counterpart to the weekly scheduled audits — fast, mechanical, no LLM variance. It catches the silent-drop failure mode: a broken symlink or dead `@`-import drops a project's parent rules with no error and no log line.

**Read-only by default.** A plain run mutates nothing — it only diagnoses and prints the exact command a repair would need. Repairs happen only when the user explicitly asks, and even then several check classes are reported as manual actions, never auto-applied (see below).

## Steps

### 0. Run from the canonical Trellis checkout

`scripts/doctor.sh` lives in the canonical Trellis instance, not in a managed project. Run it from the canonical checkout. It resolves `$TRELLIS_ROOT` from `trellis.config.json` and probes the canonical clone via `git -C "$TRELLIS_ROOT" …` regardless of your cwd — there is no per-project root ceremony to perform here.

### 1. Diagnose (read-only)

Run:

```
scripts/doctor.sh
```

To scope to a single project, add `--project <registry-name>`. This run is read-only — it never calls a fix engine and never touches a project. Let it finish; it takes seconds.

### 2. Read the result

`doctor` prints a per-project `✓ / ⚠ / ✗` table plus a summary and an exit code. Summarize it for the user, grouped by severity, most-severe first:

- `✗` **ERROR** — inheritance is broken (a project gets *no* parent rules), or the canonical clone is off `main` / dirty (which silently poisons *every* project's inheritance). These are the load-bearing failures.
- `⚠` **WARN** — degraded but parented: a missing skill or command symlink, hook drift, a missing `@`-import fallback, or missing harness parity.
- **INFO** — version-pin lag: rules are current via the symlink, but the pinned feature set trails canonical `VERSION`.

Exit codes: `0` healthy (WARN/INFO are allowed and still exit `0`), `1` if any ERROR was found, `2` on bad arguments.

If everything is `✓` (exit `0`), report green and stop — there is nothing to fix.

### 3. Repair — only if the user asks

Do **not** repair on a plain `/doctor`. If, after seeing the table, the user asks to fix the drift:

**a. Preview first.** Always dry-run before mutating anything:

```
scripts/doctor.sh --fix --dry-run
```

This prints exactly what `--fix` would do per project — every delegated command, every symlink it would recreate, every manual item — and touches nothing. Show the plan to the user.

**b. Apply.** Once the user has seen the plan and approves:

```
scripts/doctor.sh --fix
```

`--fix` repairs by delegating to the idempotent, never-clobber treatments (`onboard-project.sh` for symlinks / skills / commands / harness artifacts). Scope to one project with `--project <registry-name>` when only one is broken.

**c. Confirm green.** Re-run the plain read-only check and verify the table is clean:

```
scripts/doctor.sh
```

A repair is not done until this confirmation run reports green.

### 4. The `--fix-hooks` gate

Hook re-sync is deliberately *not* part of a plain `--fix`. Re-syncing hooks changes a project's enforcement behavior, so it is gated behind an explicit flag:

```
scripts/doctor.sh --fix --fix-hooks
```

Only add `--fix-hooks` when the user has specifically agreed to update stale hook copies. Without it, drifted hooks are reported, not rewritten.

## What this command does NOT do

- It does not repair on a plain run. Diagnosis is read-only; `--fix` is explicit and user-gated.
- It never auto-edits a user's project `CLAUDE.md` or `settings.json`. A dead or missing `@`-import in the project `CLAUDE.md`, and `settings.json` `.hooks` wiring drift, are reported as manual actions — `doctor` surfaces them, you relay them, the user edits.
- It does not auto-resolve Tier-0 issues. A canonical clone left off `main` or dirty, or version-pin lag, is reported (ERROR / INFO) and never mutated by `--fix`.
- It does not enforce remote state (e.g. GitHub branch protection). Anything unfixable locally is reported as a manual action, never guessed at.

<!--
/doctor is a maintainer command run from the canonical Trellis checkout — it is
deliberately NOT in the per-project command set that onboard-project.sh
symlinks ({primer,primer-refresh,primer-check,explore}.md). doctor.sh
self-resolves $TRELLIS_ROOT from trellis.config.json, so no git-common-dir
canonical-root ceremony applies here. Design: docs/adr/2026-05-30-trellis-doctor.md.
-->
