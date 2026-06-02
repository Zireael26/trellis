---
description: Report (read-only) disk reclaimable across the active fleet — stale build caches, dead worktrees, package stores — and, only on request, preview and apply the cleanup.
argument-hint:
---

# Trellis disk-janitor

You are running `trellis disk-janitor` to find and (only when asked) reclaim disk that the active fleet leaks: stale build caches (`.turbo/cache`, `.next/cache`, `.next/dev`), dead git worktrees, and package stores. This is the deterministic, host-side counterpart to the scheduled audits — it measures real disk, which the scheduled-task sandbox cannot do.

**Report-only by default.** A plain run mutates nothing — it scans every scope, prints a report, and writes `audits/YYYY-MM-DD-disk-janitor.md`. Deletion happens only when the user explicitly asks, only after a dry-run preview, and even then every destructive category asks for a per-category `y/N` confirmation. The scheduled LaunchAgent runs `--report` only — it never deletes.

## Steps

### 0. Run from the canonical Trellis checkout

`scripts/disk-janitor.sh` lives in the canonical Trellis instance, not in a managed project. Run it from the canonical checkout. It resolves `$TRELLIS_ROOT` / `$PROJECTS_ROOT` from `trellis.config.json` and enumerates the active fleet (registry minus blacklist minus `disk_janitor.skip_projects`) regardless of your cwd.

### 1. Report (read-only)

Run:

```
scripts/disk-janitor.sh
```

To scope to a single project, add `--project <registry-name>`. To limit which scopes are scanned, add `--scopes caches,worktrees,stores` (any subset; default is all three). This run is read-only — it deletes nothing. It writes the report to `audits/YYYY-MM-DD-disk-janitor.md` as well as stdout.

### 2. Read the result

The report has these sections — summarize them for the user, most actionable first:

- **Recurrence pre-pass: turbo outputs** — any project whose `turbo.json` has an unscoped `.next/**`-class `outputs` glob (missing the `!.next/cache/**` / `!.next/dev/**` negations). This is the root cause of the 148 GB-in-2-days incident; if a landmine is listed, relay the printed one-line fix. `turbo.json` is user-owned, so disk-janitor never edits it — it only reports.
- **Tripwire status** — free space on the projects volume vs the configured floor, and the largest single cache vs the ceiling. A `⚠` here means cleanup is overdue.
- **Build caches** — per cache dir: `[delete]` (stale past `cache_ttl_days`), `[skip]` (younger, or a build is currently running in that project), with sizes.
- **Worktrees** — per linked worktree: `[delete]` (passes all four reap gates), `[candidate]` (merge could not be verified — never auto-reaped), `[skip]` (main checkout, or fails a gate), with the gate verdict.
- **Package stores** — best-effort `pnpm store` / `npm cache` reclaim estimate (may be 0).
- **Total** — reclaimable-now bytes (stale caches + fully-gated worktrees).

Exit codes: `0` success, `1` a scan or prune error occurred, `2` bad arguments.

If nothing is reclaimable and no tripwire fired, report green and stop.

### 3. Preview — only if the user asks to clean up

Do **not** delete on a plain run. If, after seeing the report, the user asks to reclaim the space:

```
scripts/disk-janitor.sh --dry-run
```

This prints the exact deletion plan — every cache path with its size and why-it-is-safe, every worktree with its four-gate verdict — and mutates nothing. Show the plan to the user.

### 4. Apply — once the user approves

```
scripts/disk-janitor.sh --apply
```

`--apply` prints the plan, then **per category** reads a `y/N` line from stdin before deleting (caches first, then worktrees). Declining a category leaves it untouched. After deletion it re-scans and reports the bytes actually reclaimed.

To skip the per-category prompts (because the user has already confirmed in conversation), add `--yes`:

```
scripts/disk-janitor.sh --apply --yes
```

Only add `--yes` when the user has explicitly approved the previewed plan. `--scopes` and `--project` narrow what `--apply` touches, the same as in report mode.

## What this command does NOT do

- It does not delete on a plain run. Reporting is read-only; `--apply` is explicit, dry-run-previewed, and per-category confirmed.
- It never auto-edits a user's `turbo.json` (or any user-owned project file). An unscoped `outputs` glob is reported with a one-line fix — you relay it, the user edits.
- It never reaps a worktree unless **all four** gates hold: it is not the main checkout, its last commit is older than `worktree_stale_days`, its working tree is clean (untracked files count as dirty), and its branch is verifiably merged. A worktree whose merge cannot be verified (no `gh`, no remote-tracking info) is reported as a `candidate` and **never** reaped.
- It never touches a project whose build is currently running (the cache scan detects an active `next`/`vite`/`turbo`/`webpack`/`tsc` build and skips that project's caches).
- The scheduled LaunchAgent runs `--report` only — it never runs `--apply`. Destructive reclaim is always a foreground, human-approved action.
- It isolates per-project failures: a project that errors mid-scan is reported as `skipped` and the run continues.

## Config keys (`trellis.config.json` → `disk_janitor`)

All optional; the whole object may be absent and the defaults apply.

- `enabled` (default `true`) — when `false`, `--apply` is blocked (report/dry-run still work).
- `cache_ttl_days` (default `14`) — caches older than this are reclaimable.
- `worktree_stale_days` (default `30`) — the staleness gate for worktree reap.
- `free_space_floor_gb` (default `30`) — the free-space tripwire threshold.
- `cache_ceiling_gb` (default `20`) — the largest-single-cache tripwire threshold.
- `skip_projects` (default `[]`) — registry names disk-janitor never scans.

<!--
/disk-janitor is a maintainer command run from the canonical Trellis checkout —
it measures real host disk, which the scheduled-task sandbox cannot. It is
deliberately NOT in the per-project command set onboard-project.sh symlinks.
disk-janitor.sh self-resolves $TRELLIS_ROOT/$PROJECTS_ROOT from
trellis.config.json. Plan: docs/plans/2026-06-02-disk-janitor.md.
-->
