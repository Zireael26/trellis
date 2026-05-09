# Targets — dep-major-upgrade-watch

Reads `__SE_CORE_PATH__/registry.md` at runtime. Target set = `registry \ blacklist`. Curated watchlist is `watchlist.md` in this directory.

## Runner requirement

Standard scheduled-task sandbox is fine. File tools for project lockfiles / `package.json` / `.nvmrc` / `ProjectVersion.txt`; bash + curl for registry latest-version checks. No macOS-host requirement, no special mounts beyond what the regular runner has.

## Scope

- **Cadence:** Monthly, 1st of the month at 11:00 — runs **after** `gotchas-rollup` (1st 09:00) and `audit-report-rollup` (1st 10:00) so this month-opening audit can cite both. Major-version upgrade planning is a monthly rhythm; no point churning it weekly.
- **Cron:** `0 11 1 * *` (local time).
- **Ordering rationale:** Strategic audit, not operational. Putting it last in the monthly batch lets it reference the gotchas rollup ("X projects all hit a Next 15 → 16 footgun") and the audit-report rollup (cross-month dep-currency trends).

## Per-project overrides

Per-project version overrides for a tracked package live in `watchlist.md` (per-package `Per-project overrides` field), not here. Keep one knob in one place. This file therefore only sets task-level toggles.

## Skip list

```
# <project-name>: <reason>
```

Default skips for the current registry as of 2026-05-01:

```
# (none — for each tracked package the audit records `not-applicable` rows for projects where the package isn't part of the surface, which is the right behavior.)
```

## Tunable thresholds

- `STALE_TARGET_DAYS` — `target_set_at` older than this is flagged for review. Default `180`.
- `LONG_STALE_DRIFT_DAYS` — a project that's been `behind-by-major` longer than this with no movement escalates to `critical`. Default `180`.
- `UPSTREAM_LAG_TOLERANCE_MAJOR` — how many majors behind upstream the watchlist target can be before the watchlist itself is flagged. Default `0` (any major behind upstream is reported). Set to `1` to allow one-major lag without complaint.
- `UPSTREAM_CHECK_TIMEOUT_SEC` — per-package upstream HTTP timeout. Default `10`.

Override syntax:
```
# threshold:<name>=<value>
```

No threshold overrides set as of 2026-05-01.

## Maintenance notes

- When you add a new framework-tier package to `watchlist.md`, no change is needed here. The audit auto-discovers entries.
- When a new project joins the registry, no change is needed here either.
- When you change the cadence, update the cron above AND re-register the scheduler entry (`mcp__scheduled-tasks__update_scheduled_task`).
