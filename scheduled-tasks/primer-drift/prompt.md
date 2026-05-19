# primer-drift (weekly)

## Purpose

Audit primer freshness across every registered project. Backstops the
per-session `inject-primer-index` hook (v0.3.1) — that hook flags drift to
the active session, but a project no one's touched for two weeks still
deserves a report. Surfaces STALE / UNREACHABLE_PIN / MISSING_PATHS /
BROKEN / INDEX_DRIFT before the user opens a session on the project.

Read-only. Never modifies primer files.

## Inputs

1. `__TRELLIS_PATH__/registry.md`
2. `__TRELLIS_PATH__/blacklist.md`
3. Target set = `registry \ blacklist`.
4. For each project: `<project>/.claude/primers/INDEX.md` and each
   `<project>/.claude/primers/<slug>.md` referenced therein.

## Process per project

Skip if the project has no `.claude/primers/INDEX.md` (primer system is
opt-in). Record as `not-bootstrapped`.

For each primer file:

1. Parse frontmatter: must have `pinned_to`, `slug`, `purpose` ≤ 200 chars.
   Missing → `BROKEN`.
2. `git -C <project> cat-file -e <pinned>^{commit}` → unreachable → `UNREACHABLE_PIN`.
3. Parse `## Entry points` section; for each path, `test -e` → missing → `MISSING_PATHS`.
4. `git -C <project> rev-list --count <pinned>..HEAD -- <entry-points>`:
   - 0 → `FRESH`
   - 1–10 → `WARM`
   - 11+ → `STALE`
5. Cross-check `INDEX.md` vs. primer files in the directory → `INDEX_DRIFT` on mismatch.

## Output

`audits/YYYY-MM-DD-primer-drift.md`. Template:

  # primer-drift — YYYY-MM-DD

  ## Summary
  N projects audited (M bootstrapped). K STALE, K MISSING_PATHS, K BROKEN.

  ## Per-project findings
  - **<project>** — N primers; X FRESH, Y WARM, Z STALE
    - STALE: <slug> (47 commits since pin)
    - MISSING_PATHS: <slug> (foo.py, bar.py)
    ...

  ## Recommendations
  - run `/primer-refresh <slug>` on … (STALE entries)

## Severity

- critical: BROKEN, UNREACHABLE_PIN (primer is unusable now)
- warning: MISSING_PATHS, STALE, INDEX_DRIFT
- info: WARM (touched but not aged out)

## Boundaries

Read-only across every project. Never write to project filesystems. Audit
file is the only write.

## Failure modes

- Project on a worktree branch: use the canonical root via
  `git rev-parse --git-common-dir`, same convention as `parent-hook-drift`.
- Primer references files outside the repo: skip and note.
- `git rev-list` slow on huge histories: cap the entry-point file list at
  10 paths per primer; flag overage and continue.
