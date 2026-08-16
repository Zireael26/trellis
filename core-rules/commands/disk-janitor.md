---
description: Report (read-only) disk reclaimable across the active fleet — stale build caches, dead worktrees, package stores — and apply cleanup only through attended approval or a separately opted-in safe schedule.
argument-hint:
---

# Trellis disk-janitor

You are running `trellis disk-janitor` to find and, through attended approval or the separately opted-in safe schedule, reclaim disk that the active fleet leaks: stale build caches (`.turbo/cache`, `.next/cache`, `.next/dev`), dead git worktrees, and package stores. This is a deterministic host-side check — it measures real disk that a sandboxed audit runner may not see.

**Report-only by default.** A plain run mutates nothing — it scans every scope, prints a report, and writes `audits/YYYY-MM-DD-disk-janitor.md`. Attended deletion runs only after an explicit dry-run preview and per-category `y/N` confirmation. The default LaunchAgent runs `--report`; an operator may separately install the opt-in merged-only `--safe-only` apply agent.

## Steps

### 0. Run from the canonical Trellis checkout

`scripts/disk-janitor.sh` lives in the canonical Trellis instance, not in a managed project. Run it from the canonical checkout. It resolves the source checkout and fleet roots from validated machine state under `$TRELLIS_HOME` and enumerates the active fleet (local-registry rows minus `disk_janitor.skip_projects`) regardless of your cwd.

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
- **Worktrees** — per linked worktree: `[delete]` (passes the configured recoverability and safety predicate), `[candidate]` (manual review; never auto-reaped), or `[skip]` (main checkout or unsafe), with the full verdict. Default recoverability is merged or pushed; `--safe-only` narrows deletion to merged, non-detached trees.
- **Package stores** — best-effort `pnpm store` / `npm cache` reclaim estimate (may be 0).
- **Total** — reclaimable-now bytes (stale caches + fully-gated worktrees).

Exit codes: `0` success, `1` a scan or prune error occurred, `2` bad arguments.

If nothing is reclaimable and no tripwire fired, report green and stop.

### 3. Preview — only if the user asks to clean up

Do **not** delete on a plain run. If, after seeing the report, the user asks to reclaim the space:

```
scripts/disk-janitor.sh --dry-run
```

This prints the exact deletion plan — every cache path with its size and why-it-is-safe, every worktree with its configured gate verdict — and mutates nothing. Show the plan to the user.

### 4. Apply — once the user approves

```
scripts/disk-janitor.sh --apply
```

`--apply` prints the plan, then **per category** reads a `y/N` line from stdin before deleting (caches first, then worktrees). Declining a category leaves it untouched. After deletion it re-scans and reports the bytes actually reclaimed.

To skip the per-category prompts (because the user has already confirmed in conversation), add `--yes`:

```
scripts/disk-janitor.sh --apply --yes
```

In attended use, only add `--yes` after explicit approval of the previewed plan; `--scopes` and `--project` narrow it as in report mode. The separately installed apply LaunchAgent runs `--apply --yes --safe-only --scopes worktrees`, permitting only the merged-clean unattended set while attended `--apply` retains the configured normal predicate.

## What this command does NOT do

- It does not delete on a plain run. Attended `--apply` is explicit, dry-run-previewed, and per-category confirmed; only the separately opted-in schedule applies the narrower `--safe-only` set unattended.
- It never auto-edits a user's `turbo.json` (or any user-owned project file). An unscoped `outputs` glob is reported with a one-line fix — you relay it, the user edits.
- Normal worktree deletion requires a non-main, not-in-use, porcelain-clean, secret-free tree recoverable by a merged PR or a fully pushed tip. `reap_pushed_worktrees=false` restores the legacy stale+merged recoverability gate. `--safe-only` further requires a non-detached merged branch and downgrades pushed-only and ephemeral-tree candidates. Liveness-probe failure always fails closed; merge-probe failure fails closed for legacy and `--safe-only`, while normal attended apply may still accept an independently verified fully pushed tip.
- It never touches a project whose build is currently running (the cache scan detects an active `next`/`vite`/`turbo`/`webpack`/`tsc` build and skips that project's caches).
- The default LaunchAgent runs `--report` only. `scripts/install-disk-janitor-launchd.sh --with-apply` separately installs the opt-in nightly `--safe-only` worktree agent; uninstall it before rollback. Other destructive reclaim remains attended.
- It isolates per-project failures: a project that errors mid-scan is reported as `skipped` and the run continues.

## Config keys (`trellis.config.json` → `disk_janitor`)

All optional; the whole object may be absent and the defaults apply.

- `enabled` (default `true`) — when `false`, `--apply` is blocked (report/dry-run still work).
- `cache_ttl_days` (default `14`) — caches older than this are reclaimable.
- `worktree_stale_days` (default `30`) — the staleness gate used when `reap_pushed_worktrees=false`.
- `reap_pushed_worktrees` (default `true`) — allow clean, fully pushed tips as recoverable during normal attended apply; `false` restores stale+merged behavior.
- `ephemeral_tmp_ttl_days` / `worktree_count_ceiling` / `worktree_total_gb_ceiling` (defaults `2` / `25` / `80`) — `/private/tmp` TTL, per-repository count tripwire, and fleet-wide aggregate-size tripwire.
- `free_space_floor_gb` (default `30`) — the free-space tripwire threshold.
- `cache_ceiling_gb` (default `20`) — the largest-single-cache tripwire threshold.
- `skip_projects` (default `[]`) — registry names disk-janitor never scans.

<!--
/disk-janitor is a maintainer command run from the canonical Trellis checkout —
it measures real host disk, which the scheduled-task sandbox cannot. It is
deliberately NOT in the per-project command set onboard-project.sh symlinks.
disk-janitor.sh self-resolves the source checkout and fleet roots from
$TRELLIS_HOME machine state. Plan: docs/plans/2026-06-02-disk-janitor.md.
-->
