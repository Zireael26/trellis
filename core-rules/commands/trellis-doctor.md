---
description: Run the deterministic Trellis inheritance health check (read-only), summarize the per-project results, and — only on request — preview and apply repairs.
argument-hint:
---

# Trellis doctor

Invoked as `/trellis-doctor`. The name is deliberate: Claude Code ships its own
built-in `/doctor` (installation health, skill and `CLAUDE.md` rightsizing), and
a project-level command of the same name would shadow it. This command is the
*inheritance* health check, and Trellis wants both available.

You are running `trellis doctor` to check that every active project is still correctly parented to the canonical Trellis rules. This is the deterministic, on-demand health check — fast, mechanical, no LLM variance — and can also feed private operator audits. It catches the silent-drop failure mode: a broken symlink or dead `@`-import drops a project's parent rules with no error and no log line.

**Read-only by default.** A plain run mutates nothing — it only diagnoses and prints the exact command a repair would need. Repairs happen only when the user explicitly asks, and even then several check classes are reported as manual actions, never auto-applied (see below).

## Steps

### 0. Run from the canonical Trellis checkout

`scripts/doctor.sh` lives in the canonical Trellis instance, not in a managed project. Run it from the canonical checkout. It resolves local fleet state from `$TRELLIS_HOME` and, in explicit legacy diagnosis mode, the canonical clone from the supplied legacy config — regardless of your cwd, with no per-project root ceremony to perform here.

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

Do **not** repair on a plain `/trellis-doctor`. If, after seeing the table, the user asks to fix the drift:

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

### 4. Hook drift is a `[manual]` remedy — doctor does not re-sync hooks

`doctor` has no hook-repair action at all. Claude/Codex hook drift is classified `[manual]` in **every** mode — plain, `--fix`, and `--fix --dry-run` — and is reported, never rewritten.

The reason is mechanical, not a policy gate: `sync-hooks.sh` / `sync-codex-hooks.sh` reconcile a hook surface **only** through the recorded immutable release of a registered, attached row. They never copy a hook out of the mutable checkout that launched them. A legacy direct-link project has no local registry row and no recorded release, so there is nothing for `doctor` to delegate to.

The honest remedy `doctor` prints is to adopt a release and attach the project:

```
scripts/attach-project.sh attach <project-root>
```

After that the portable flow owns hook reconciliation. Relay this to the user as a manual action — do not run it as part of a `/trellis-doctor` repair.

`--fix-hooks` is still accepted for compatibility but is **inert**: it implies `--fix` and otherwise does nothing, and `--fix` prints a line saying so. Do not offer it as a repair.

One side effect worth stating when you relay a `--fix` plan: `onboard-project.sh` seeds *missing* hooks and a *missing* `settings.json` unconditionally (there is no `--skip-hooks`), so a plain `--fix` that runs onboard will install absent hooks. It never updates a **stale** hook.

## What this command does NOT do

- It does not repair on a plain run. Diagnosis is read-only; `--fix` is explicit and user-gated.
- It never auto-edits a user's project `CLAUDE.md` or `settings.json`. A dead or missing `@`-import in the project `CLAUDE.md`, and `settings.json` `.hooks` wiring drift, are reported as manual actions — `doctor` surfaces them, you relay them, the user edits.
- It does not auto-resolve Tier-0 issues. A canonical clone left off `main` or dirty, or version-pin lag, is reported (ERROR / INFO) and never mutated by `--fix`.
- It does not enforce remote state (e.g. GitHub branch protection). Anything unfixable locally is reported as a manual action, never guessed at.

<!--
/trellis-doctor is a maintainer command run from the canonical Trellis checkout
— it is deliberately NOT in the per-project command set that onboard-project.sh
symlinks ({primer,primer-refresh,primer-check,explore,autonomy,surgical}.md),
and so is intentionally outside HC_CANONICAL_COMMANDS in
scripts/lib/health-checks.sh. It is reachable because the canonical checkout
seeds .claude/commands/trellis-doctor.md itself. doctor.sh self-resolves
local state from $TRELLIS_HOME, so no git-common-dir canonical-root
ceremony applies here. Design: docs/adr/2026-05-30-trellis-doctor.md.

Renamed from /doctor (spec 019, audit C7): Claude Code ships a bundled /doctor,
and a same-named project command shadows it. scripts/doctor.sh is a different
thing — a shell script, not a slash command — and keeps its name.
-->
