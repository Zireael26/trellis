# Targets — dep-currency

Reads `__SE_CORE_PATH__/registry.md` at runtime. Target set = `registry \ blacklist`.

## Runner requirement

Standard scheduled-task sandbox is fine. Same model as `dep-vulnerabilities`: file tools for project-local reads, bash + curl for registry HTTP queries (npm, pypi, crates.io, proxy.golang.org). No macOS-host requirement.

The earlier "host required" guard in this file was wrong — it gated the audit out before it tried. `npm outdated` / `pnpm outdated` would have needed a working install, but the audit's actual approach is "compute current from lockfile + compute latest from registry HTTP + diff yourself," which works in the sandbox.

## Scope

- **Cadence:** Weekly, Monday at 11:30 AM — runs **after** `test-health` (11:00) so we know which projects are green before drowning them in upgrade noise.
- **Cron:** `30 11 * * 1` (local time).
- **Ordering rationale:** Currency drift is a planning input, not an emergency. Putting it after the Mon-morning compliance + test sweep means the user sees one merged Mon-morning picture: hooks OK → tests OK → here's the dep drift to triage this week.

## Per-project overrides

Override the default behavior for a project. Format:

```
# <project-name>: <directive>
# <project-name> [<workspace-path>]: <directive>
```

Available directives:
- `skip` — exclude from this run.
- `registry=<url>` — use an alternate registry base URL for npm queries from this project's workspaces.

E.g.:
```
# vericite: registry=https://registry.private.example
```

No overrides set as of 2026-05-01.

## Skip list

```
# <project-name>: <reason>
```

Default skips for the current registry as of 2026-05-01:

```
# lume: Unity Package Manager has no public registry HTTP endpoint comparable to npm/pypi; tracked manually via dep-major-upgrade-watch watchlist.
```

## Tunable thresholds

- `MINOR_BEHIND_DAYS_THRESHOLD` — minimum `time_behind` (days) before a minor-behind dep appears in the main "Minor-behind" table. Default `30`. Lower to surface more, raise to focus on long-stale deps.
- `INCLUDE_DEV_DEPS_FULL` — include full dev-direct per-package list in the main report (not just the rollup). Default `false`.
- `REGISTRY_QUERY_BUDGET_SEC` — per-project budget for the registry-fetch loop. Default `240` (4 minutes).
- `INCLUDE_PRERELEASES` — treat upstream prereleases as "latest" for drift calc. Default `false`.
- `MAJOR_GRACE_DAYS` — suppress `major-behind` findings if the upstream major was published less than N days ago. Default `14`.
- `REGISTRY_QUERY_CONCURRENCY` — parallel curl workers when fetching latest versions. Default `16`. Lower if you hit rate limits.

Override syntax:
```
# threshold:<name>=<value>
```

E.g.:
```
# threshold:MINOR_BEHIND_DAYS_THRESHOLD=60
# threshold:MAJOR_GRACE_DAYS=30
```

No threshold overrides set as of 2026-05-01.
