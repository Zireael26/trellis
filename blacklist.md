# Blacklist

Two scopes, both excluded from registry-driven operator checks.

> **Template note:** this file ships empty. Add entries as you decide which projects to pause or permanently exclude.

## 1. Temporarily excluded (registered projects)

Projects listed in `registry.md` that should be **temporarily** excluded from centralized process checks. Every entry needs a **reason** and a **review-after** date.

| Project | Reason | Added | Review after |
|---|---|---|---|
| — | — | — | — |

*(empty)*

## 2. Permanently excluded from management

Git repos under `__PROJECTS_ROOT__/` that should **never** be onboarded to Trellis. Operator checks that scan the filesystem should skip these paths.

If any row becomes an active project, move it to `registry.md` (step 1 of onboarding).

| Path | Reason |
|---|---|
| _(none yet)_ | |

<!--
Example rows — uncomment as you blacklist things:

| `__PROJECTS_ROOT__/scratch-tool` | One-off script, not a managed app.       |
| `__PROJECTS_ROOT__/old-experiment`| Dormant; kept locally but not maintained.|
-->

---

## Semantics

- **Temporarily excluded** (section 1) — for projects that ARE in `registry.md` but need a time-bound pause (refactor freeze, bootstrap period, noisy-audit window). Reason + review-after required.
- **Permanently excluded** (section 2) — for git repos that are NOT in `registry.md` and never will be unless explicitly moved. No review-after needed.
- Registry-driven operator checks should read both sections: a project participates iff it is in `registry.md` AND not in either blacklist section. Filesystem checks should skip every path listed in section 2.
- Temporary entries older than 90 days trigger a prompt to make them permanent or lift them.
