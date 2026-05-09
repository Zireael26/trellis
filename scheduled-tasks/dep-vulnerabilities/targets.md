# Targets — dep-vulnerabilities

Reads `__SE_CORE_PATH__/registry.md` at runtime. Target set = `registry \ blacklist`.

## Runner requirement

Standard scheduled-task sandbox is fine. The task uses **file tools** (`Read`, `Glob`, `Grep`) for project-local lockfile/manifest reads — these reach `__PROJECTS_ROOT__/<project>/` even though the bash sandbox does not. Vulnerability data comes from `https://api.osv.dev/v1/querybatch` over HTTPS, which the sandbox can reach.

There is **no** macOS-host requirement. An earlier version of this targets.md required Darwin and that turned out to be wrong — it gated the audit out before it tried, when in fact the necessary inputs (lockfiles + osv.dev) are reachable from the standard sandbox. If a future runtime change breaks file-tool access to `personal/`, fix the prompt's failure mode rather than restoring a uname guard.

## Scope

- **Cadence:** Weekdays 08:30 — runs after `bypass-tripwire` (08:00) so a critical CVE published overnight surfaces in the day's first audit pass. Weekday-only keeps the noise down; weekend CVEs are picked up Monday.
- **Cron:** `30 8 * * 1-5` (local time).
- **Ordering rationale:** Vulnerability scanning is independent of the Monday morning sequence (`cross-project-process-audit` → `registry-blacklist-health` → `test-health` → `dep-currency`) and runs before it on Monday. If a critical CVE is found, the Monday-morning context will already include it.

## Per-project overrides

Override the default lockfile detection or scanner command for a specific project. Format:

```
# <project-name>: <command>
# <project-name> [<workspace-path>]: <command>
```

E.g., for a Neev workspace with a non-standard layout:
```
# neev [apps/api]: skip — workspace uses an internal-only registry not reachable from sandbox
```

No overrides set as of 2026-05-01.

## Skip list

Projects that can't be vuln-scanned automatically.

```
# <project-name>: <reason>
```

Default skips for the current registry as of 2026-05-01:

```
# (none — Lume is auto-handled inside the prompt: scanned only if Packages/packages-lock.json present.)
```

## Tunable thresholds

- `OSV_BATCH_BUDGET_SEC` — per-project budget for osv.dev query batches. Default `240` (4 minutes). Increase for large monorepos with many workspaces.
- `OSV_BATCH_SIZE` — packages per `/v1/querybatch` call. Default `1000` (osv.dev's documented max). Lower if osv.dev returns rate-limit responses.
- `INCLUDE_DEV_DEPS`: include `devDependencies` in the scan. Default `true`. Set to `false` to scope to runtime deps only when devDep CVEs create noise.
- `OFFLINE_GRACE`: if the run env reports offline (curl fails), the audit emits one `warning` and stops. Set to `false` to instead error the whole run. Default `true`.

Override syntax:
```
# threshold:<name>=<value>
```

E.g.:
```
# threshold:OSV_BATCH_BUDGET_SEC=360
# threshold:INCLUDE_DEV_DEPS=false
```

No threshold overrides set as of 2026-05-01.
