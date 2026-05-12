# Targets — version-drift

Reads `__TRELLIS_PATH__/registry.md` at runtime. Target set
= `registry \ blacklist`. The scope is each registered project's
*optional* root-level `trellis.config.json` plus the parent clone itself.

## Scope

- Weekly. Recommended cadence: Monday at 11:45 AM (after the existing
  Monday-morning sequence — `cross-project-process-audit` 10:00 →
  `registry-blacklist-health` 10:30 → `test-health` 11:00 →
  `dep-currency` 11:30 → `version-drift` 11:45). End of Monday means the
  user sees drift findings at the same time as dependency drift, which is
  the same mental category.
- Inputs are all on disk; no remote fetch. Cheap, single-host audit.

## Canonical version source of truth

`__TRELLIS_PATH__/core-rules/VERSION`

Single-line semver. Strip whitespace before compare. If the file is
missing, the audit aborts (an info finding documenting the absence).

## Per-project config lookup order

For each project name `<P>` in `registry \ blacklist`, look in:

1. `__PROJECTS_ROOT__/<P>/trellis.config.json`
2. `__PROJECTS_ROOT__/<P>/.trellis.config.json`

First match wins. If neither exists, the project is `no-pin` (info).

## Personal projects root override

If the personal projects root ever moves, record it here:

```
PERSONAL_ROOT=__PROJECTS_ROOT__
```

Current: `__PROJECTS_ROOT__/` (as of 2026-05-12).

## Notes

- This audit was added in Phase A.3 of the spec-kit adoption plan
  (`docs/plans/2026-05-12-spec-kit-adoption.md`). It is forward-looking:
  while the pin rollout is in progress, most rows will be `no-pin`. That
  is the expected state, not a failure.
- The drift-severity logic mirrors the one consumed by `scripts/upgrade.sh`
  — keep them in step. If the severity tiers change, update both files in
  the same commit.
