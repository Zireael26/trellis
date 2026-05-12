# Targets — preset-drift

Reads `__TRELLIS_PATH__/registry.md` at runtime.
Target set = `registry \ blacklist`. Each project is checked against the
canonical preset catalogue at
`__TRELLIS_PATH__/core-rules/presets/`.

## Scope

- Weekly. Recommended cadence: Monday at 12:00 (after the existing Monday
  sequence: `cross-project-process-audit` 10:00 → `registry-blacklist-health`
  10:30 → `test-health` 11:00 → `dep-currency` 11:30 → `version-drift`
  11:45 → `preset-drift` 12:00). Preset drift lands last in the Monday
  block because the other audits define what "current" means; preset
  composition is a layer on top.
- Inputs are on-disk only; no remote fetch. Cheap, single-host audit.

## Canonical preset catalogue

`__TRELLIS_PATH__/core-rules/presets/*.md` (skip
`README.md`).

As of 2026-05-12 the catalogue contains:

- `compliance-strict`
- `experimental-loose`

New presets must be added in lockstep across:

1. `core-rules/presets/<name>.md`
2. `core-rules/presets/README.md` "Available presets" table

Adding a row to this targets.md file is NOT required — the audit reads the
canonical directory directly.

## Per-project config lookup order

For each project name `<P>` in `registry \ blacklist`, look in:

1. `__PROJECTS_ROOT__/<P>/.trellis.config.json` (preferred,
   hidden file)
2. `__PROJECTS_ROOT__/<P>/trellis.config.json` (visible
   alternative)

First match wins. If neither exists, the project is `no-presets-declared`
(info).

## Personal projects root override

If the personal projects root ever moves, record it here:

```
PERSONAL_ROOT=__PROJECTS_ROOT__
```

Current: `__PROJECTS_ROOT__/` (as of 2026-05-12).

## Notes

- Added in Phase D.4 of the spec-kit adoption plan
  (`docs/plans/2026-05-12-spec-kit-adoption.md`). Forward-looking: while
  the preset rollout is in progress, most rows will be
  `no-presets-declared`. That is the expected state, not a failure.
- The severity tiers mirror what `scripts/rollout-presets.sh` enforces.
  If you change the tiers, change both files in the same commit.
