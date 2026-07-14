# Dependency currency — 2026-05-01

## Summary

- Projects scanned: 0
- Status: **skipped — sandbox run**

Single **info** finding emitted: `dep-currency requires host execution; sandbox run skipped`.

## Why this run was skipped

Per the operator's dependency-currency runner policy, this task must run on the user's macOS host. The trigger condition was met:

1. `uname` is `Linux` (not `Darwin`) — running in the default linux-arm64 scheduled-task sandbox.
2. Registered project paths (`__PROJECTS_ROOT__/project-a`, `__PROJECTS_ROOT__/project-b`, `__PROJECTS_ROOT__/project-c`, `__PROJECTS_ROOT__/project-d`, `__PROJECTS_ROOT__/project-e`) are unreachable from this sandbox — only `se-core` is mounted.

Both conditions matching = emit one info finding and exit, without attempting per-project outdated scans. This matches the `dep-vulnerabilities` / `test-health` pattern.

The underlying reasons (per `prompt.md` "Execution environment"):

- `node_modules` trees on the user's host are darwin-arm64-hydrated; a Linux sandbox cannot reproduce the resolved-version state reliably.
- `npm outdated` / `pnpm outdated` need a working install to compute "current" correctly; lockfile-only reads miss workspace-resolved versions.

## Target set (would-have-been-scanned)

Resolved from `registry.md` minus `blacklist.md` and the per-task skip list in `targets.md`:

| Project | Path | Class |
|---|---|---|
| project-a | `__PROJECTS_ROOT__/project-a` | monorepo SaaS |
| project-b | `__PROJECTS_ROOT__/project-b` | single Next.js app |
| project-c | `__PROJECTS_ROOT__/project-c` | portfolio site |
| project-d | `__PROJECTS_ROOT__/project-d` | app |
| project-e | `__PROJECTS_ROOT__/project-e` | app |

Skipped per `targets.md`:

| Project | Reason |
|---|---|
| project-f | Unity Package Manager has no automated outdated-check tool comparable to npm/pip; tracked manually via dep-major-upgrade-watch watchlist. |

## Findings

| Severity | Finding |
|---|---|
| info | `dep-currency requires host execution; sandbox run skipped` |

No critical, warning, or other info findings produced. Major-behind / minor-behind / patch-behind tables are empty for this run because no project was scanned.

## Drift change since last run

No prior `*-dep-currency.md` audit exists in `audits/`. This is the first scheduled run; baseline will be established on the next host-side execution.

## Cross-cutting observations

None — nothing scanned. Re-run on the macOS host to populate the cross-cutting view.

## How to run on the host

To produce a real report, execute this task on the macOS host where `__PROJECTS_ROOT__/<project>` is reachable and `node_modules` is darwin-arm64-hydrated. The task definition is unchanged; the runner just needs to be Darwin.

## Appendix

### Full runtime-direct list

(empty — no scan)

### Full dev-direct list

(empty — no scan)
