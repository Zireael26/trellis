# Version drift (weekly)

You are checking whether each registered project — and the parent Trellis
clone itself — has a `trellis_version` pin that is still in step with the
canonical `core-rules/VERSION`. This audit was introduced as Phase A.3 of
the spec-kit adoption plan; until many projects start pinning, expect
mostly `no-pin` rows.

The canonical version of core-rules lives at
`__TRELLIS_PATH__/core-rules/VERSION` (single-line semver).
Every clone of the public template, and every project that maintains its
own root-level `trellis.config.json`, may pin to a specific canonical
version via the optional `trellis_version` field.

## Canonical paths (authoritative)

- Trellis control plane: `__TRELLIS_PATH__/`
- Personal projects root: `__PROJECTS_ROOT__/`

If `__TRELLIS_PATH__/` is not mounted in the audit
environment, emit a single **info** finding — `Trellis mount not available
in audit environment; audit skipped` — and stop. Do not read `registry.md`
or `core-rules/VERSION` from any other location.

## Inputs

1. `__TRELLIS_PATH__/core-rules/VERSION` — canonical
   semver string (e.g., `0.1.0`). Strip whitespace.
2. `__TRELLIS_PATH__/trellis.config.json` — parent clone's
   own optional `trellis_version` pin.
3. `__TRELLIS_PATH__/registry.md` — list of active projects.
4. `__TRELLIS_PATH__/blacklist.md` — temporary opt-outs.
5. Target set = `registry \ blacklist`. For each project, look at
   `<project>/trellis.config.json` (or `<project>/.trellis.config.json`,
   whichever exists — try both, in that order).

## Checks per project

### 1. Pin present?

Does the project's root carry a `trellis.config.json` (or hidden variant)?
- If neither file exists → `no-pin` (info).
- If file exists but is not valid JSON → `unparseable-config` (warning).

### 2. Pin shape

If the file parses, does it have a `trellis_version` field?
- If absent or empty string → `no-pin` (info).
- If present but does not match the strict semver regex
  `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$` →
  `malformed-version` (critical).

### 3. Drift severity

Compare the pinned `trellis_version` (call it `P`) to the canonical
`core-rules/VERSION` (call it `C`). Parse both as `MAJOR.MINOR.PATCH`
(strip any prerelease/build suffix for comparison).

- `P.MAJOR < C.MAJOR` → `major-drift` (**critical** — opt-in upgrade needed).
- `P.MAJOR == C.MAJOR && P.MINOR < C.MINOR` → `minor-drift` (warning).
- `P.MAJOR == C.MAJOR && P.MINOR == C.MINOR && P.PATCH < C.PATCH` →
  `patch-drift` (info).
- `P == C` → `current` (info, no row in tables — counted only).
- `P > C` (any axis) → `ahead-of-canonical` (warning — usually a sign
  that someone bumped a project pin manually without updating the parent;
  surface it so the parent can be tagged forward).

### 4. Parent self-pin sanity

In addition to the per-project scan, audit the parent clone itself:
- Read `__TRELLIS_PATH__/trellis.config.json`.
- If `trellis_version` is set, compare against `core-rules/VERSION` — they
  SHOULD be equal on the canonical clone. Any mismatch is **critical**
  (somebody desynced the canonical's own pin from the VERSION file).
- If unset, that's `info` — the parent doesn't have to self-pin.

## Output

Write to
`__TRELLIS_PATH__/audits/YYYY-MM-DD-version-drift.md`:

```
# Version drift — <date>

## Summary
- Canonical core-rules/VERSION: <C>
- Parent self-pin: <P or "(unset)">
- Projects checked: <N>
- Current: <count>
- No-pin: <count>
- Patch drift: <count>
- Minor drift: <count>
- Major drift: <count>
- Ahead of canonical: <count>
- Malformed / unparseable: <count>

## Major drift (critical)

| Project | Pinned | Canonical | Path to config |
|---|---|---|---|
| ... | ... | ... | ... |

## Minor drift

| Project | Pinned | Canonical |
|---|---|---|

## Patch drift

| Project | Pinned | Canonical |
|---|---|---|

## Ahead of canonical (parent likely needs a tag bump)

| Project | Pinned | Canonical |
|---|---|---|

## Malformed / unparseable

| Project | Issue |
|---|---|

## No-pin (informational)

Projects without a project-local `trellis.config.json` or without a
`trellis_version` field. This is the expected state until the pinning
rollout reaches each project.

| Project |
|---|

## Recommended actions

1. For each major drift: run `scripts/upgrade.sh --opt-in` inside the
   project (or rebase the project against the desired tag) — major drift
   is the only severity that gates real work.
2. For ahead-of-canonical: confirm the parent clone has been tagged at
   the highest pinned version; if not, tag and push.
3. For malformed: open the project's config and replace with valid semver.
```

## Severity rollup

- **critical**: `major-drift`, `malformed-version`, parent self-pin
  mismatch against `core-rules/VERSION`.
- **warning**: `minor-drift`, `ahead-of-canonical`, `unparseable-config`.
- **info**: `patch-drift`, `no-pin`, `current`.

## Boundaries

- **Read-only.** Never edit any project's `trellis.config.json` from this
  audit. The opt-in path is `scripts/upgrade.sh --opt-in`, which is a
  user-driven action, not an audit one.
- Don't rewrite `core-rules/VERSION` either.
- If `core-rules/VERSION` is missing, stop with a clear error — there's
  nothing to compare against.

## Sensible failure modes

- Project directory missing on disk → defer to `registry-blacklist-health`
  (which will already have flagged it). Skip the row.
- Project lacks any `trellis.config.json` → `no-pin`, that's the expected
  pre-rollout state.
- Schema regex doesn't match a project's `trellis_version` → flag as
  `malformed-version` but keep auditing the rest of the registry; one bad
  pin shouldn't abort the whole run.
