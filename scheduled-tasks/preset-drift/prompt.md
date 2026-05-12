# Preset drift (weekly)

You are checking whether each registered project's declared presets (the
`.presets` array in its `.trellis.config.json` or `trellis.config.json`)
match the preset symlinks actually present on disk under
`.claude/rules/preset-*.md` and `.agents/rules/preset-*.md`. Presets layer
opt-in rules on top of the parent CLAUDE.md; silent drift between declaration
and disk means the project either has rules loading that it didn't sign up
for, or didn't get rules it did sign up for.

This audit was added as Phase D.4 of the spec-kit adoption plan. Until many
projects start opting in, expect most rows to be `no-presets-declared`.

## Canonical paths (authoritative)

- Trellis control plane: `__TRELLIS_PATH__/`
- Canonical presets directory: `__TRELLIS_PATH__/core-rules/presets/`
- Personal projects root: `__PROJECTS_ROOT__/`

If `__TRELLIS_PATH__/` is not mounted, emit a
single **info** finding — `Trellis mount not available in audit environment;
audit skipped` — and stop.

## Inputs

1. `__TRELLIS_PATH__/core-rules/presets/*.md` —
   the canonical preset catalogue (skip `README.md`).
2. `__TRELLIS_PATH__/registry.md` — list of active
   projects.
3. `__TRELLIS_PATH__/blacklist.md` — temporary
   opt-outs.
4. Target set = `registry \ blacklist`. For each project, look for
   `<project>/.trellis.config.json` (preferred) or
   `<project>/trellis.config.json` and read the `.presets` array if present.

## Checks per project

### 1. Declaration shape

Does the project carry a project-local config file (`.trellis.config.json`
or `trellis.config.json`)?

- File absent → `no-presets-declared` (info).
- File present but not valid JSON → `unparseable-config` (warning).
- File present but no `.presets` key → `no-presets-declared` (info).
- `.presets` key present but not an array → `malformed-presets` (warning).
- Any preset name not matching the kebab-case pattern
  `^[a-z0-9][a-z0-9-]*[a-z0-9]$` → `malformed-preset-name` (warning).

### 2. Declared vs. canonical existence

For each preset name in the declared array, check whether
`__TRELLIS_PATH__/core-rules/presets/<name>.md`
exists.

- Missing → `unknown-preset` (**critical**). The project asked for a preset
  that doesn't exist in the canonical catalogue — typo or the preset was
  removed without updating the project's config.

### 3. Symlink installation

For each declared preset, verify a symlink at
`<project>/.claude/rules/preset-<name>.md` exists and points at the
canonical preset file. If the project's `harnesses` includes Codex, also
verify the parallel symlink at `<project>/.agents/rules/preset-<name>.md`.

- Symlink missing → **critical: preset declared but not installed**. The
  rule layer isn't loading. Run `scripts/rollout-presets.sh <project>` to
  fix.
- Symlink present but pointing at wrong target → **critical: preset
  symlink drift**. Operator may have manually edited or a prior rollout
  partially failed.

### 4. Stale-symlink detection

Walk `<project>/.claude/rules/preset-*.md` (and `.agents/rules/preset-*.md`
under Codex). For each symlink whose `preset-<name>.md` name is NOT in the
declared array:

- Symlink exists but no longer declared → `stale-symlink` (**warning**).
  `rollout-presets.sh` should be re-run; it prunes stale symlinks
  automatically.

### 5. Harness parity (Codex-enabled projects)

For each preset declared, `.claude/rules/preset-<name>.md` and
`.agents/rules/preset-<name>.md` must BOTH exist and point at the same
canonical target.

- Mismatch → `harness-divergence` (**critical**). One harness has the
  preset; the other doesn't.

## Output

Write to
`__TRELLIS_PATH__/audits/YYYY-MM-DD-preset-drift.md`:

```
# Preset drift — <date>

## Summary
- Canonical presets available: <list>
- Projects checked: <N>
- No presets declared (info): <count>
- Fully synced: <count>
- Missing symlinks: <count>
- Stale symlinks: <count>
- Unknown preset names: <count>
- Harness divergence: <count>

## Critical findings

### Unknown presets

| Project | Declared name | Where to fix |
|---|---|---|
| ... | ... | <project>/.trellis.config.json |

### Missing symlinks

| Project | Preset | Harness | Fix |
|---|---|---|---|
| ... | ... | .claude / .agents | `scripts/rollout-presets.sh <project>` |

### Harness divergence

| Project | Preset | .claude state | .agents state |
|---|---|---|---|

## Warning findings

### Stale symlinks (declared once, no longer)

| Project | Preset symlink | Resolution |
|---|---|---|

### Malformed names / unparseable config

| Project | Issue |
|---|---|

## Informational

### No presets declared

| Project |
|---|
| ... |

## Recommended actions

1. For each missing or divergent symlink: run
   `scripts/rollout-presets.sh <project>` to reconcile.
2. For each unknown preset: fix the typo in `.trellis.config.json` OR add
   the preset to `core-rules/presets/` if it's a real new layer.
3. For each stale symlink: re-run `rollout-presets.sh`; it prunes
   automatically.
```

## Severity rollup

- **critical**: `unknown-preset`, missing symlinks, symlink drift, harness
  divergence.
- **warning**: `stale-symlink`, `malformed-preset-name`,
  `unparseable-config`, `malformed-presets`.
- **info**: `no-presets-declared`.

## Boundaries

- **Read-only.** Never edit any project's config or symlinks from this
  audit. Remediation goes through `scripts/rollout-presets.sh`.
- **Don't rewrite the canonical preset catalogue either.** If a project
  asks for a preset that doesn't exist, the catalogue is the source of
  truth.

## Sensible failure modes

- Project directory missing on disk → defer to `registry-blacklist-health`
  (which will already have flagged it). Skip the row.
- `core-rules/presets/` directory missing → stop with a clear error. No
  presets to compare against.
- Project has `.trellis.config.json` AND `trellis.config.json` simultaneously
  → use the hidden variant (`.trellis.config.json`) per the preferred-order
  convention, and emit an `info` finding noting both exist.
