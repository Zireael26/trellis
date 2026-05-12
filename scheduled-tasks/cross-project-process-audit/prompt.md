# Cross-project process audit

You are running a weekly compliance audit across the user's active personal projects. Your job is to detect **process drift** — places where a registered project has fallen out of sync with the parent engineering rules — and surface specific, fixable findings.

## Canonical paths (authoritative)

- Trellis control plane: `__TRELLIS_PATH__/`
- Parent rules file: `__TRELLIS_PATH__/core-rules/CLAUDE.md`
- Personal projects root: `__PROJECTS_ROOT__/`

These are the only authoritative paths. Any alternate paths that may appear in prior run notes, user memory, or snapshots (e.g., `~/Documents/Claude/Projects/Trellis/`) are **pre-migration artifacts**. Do not fall back to them, do not "reconcile" to them, do not treat them as equivalent.

## Environment guard

Before running any check, verify the audit environment mounts the canonical paths:

- `[ -f __TRELLIS_PATH__/core-rules/CLAUDE.md ]`
- `[ -d __PROJECTS_ROOT__ ]`

If either fails, the audit sandbox lacks access to the fleet filesystem. Emit a single **info** finding in the report — `Trellis mount not available in audit environment; checks skipped` — and stop with that note. Do **not** downgrade to alternate paths. Do **not** emit any `critical` findings based on the non-mounted state (a missing mount is an environment issue, not a project-state issue).

## Inputs

1. Read `__TRELLIS_PATH__/registry.md` — the active project list.
2. Read `__TRELLIS_PATH__/blacklist.md` — the opt-out list.
3. The set of projects to audit is `registry \ blacklist`. If blacklist has entries with a review-after date ≤ today, flag them as "overdue for review" in the report.

If any registered project's path is missing from the filesystem, report it and continue with the rest.

## Checks per project

Run these checks against each target project's root. Do **not** modify files — read-only audit.

### 1. Hook-stack presence
- Does `.claude/hooks/` exist?
- Do the parent-layer hook scripts exist in it? Compare filenames against `__TRELLIS_PATH__/core-rules/hooks/` (the canonical implementations once Phase 2 ships). Report any missing.
- Does `.claude/settings.json` register the hooks?
- If Codex is enabled in parent `trellis.config.json`, does `.codex/hooks.json` exist?
- If Codex is enabled, do the Codex hook scripts exist under `.codex/hooks/`? Compare filenames against `__TRELLIS_PATH__/core-rules/codex/hooks/`.

### 2. Hook-script staleness
- For each hook present in both the project and the parent, run `diff` (or equivalent).
- If identical → OK.
- If different → classify:
  - **Drift**: the project modified a parent hook (not expected; parent scripts should be read-only in projects).
  - **Stale**: the parent has changes the project hasn't picked up (expected after parent updates; flag for sync).

### 3. Husky presence
- Does `.husky/` exist with at least `pre-commit`, `commit-msg`, `pre-push`?
- Report any missing.

**Carve-out — native git hooks for non-Node projects.** If the project has no `package.json` (e.g., Unity / C# / Rust / Go / Python-only repos), husky is not the right tool. For these projects:

- Check whether `git config --get core.hooksPath` returns a non-empty value.
- If yes, treat that directory (e.g., `.githooks/`) as the hook directory in lieu of `.husky/`.
- The hook directory MUST be tracked in git and MUST contain a `pre-push` whose body includes the Trellis PR-flow guard string (`Direct push to .* blocked by Trellis policy.`).
- Missing or untracked native hooks → **critical: Trellis PR-flow guard not enforced**.
- Husky presence is **N/A** for projects without `package.json` — do not emit a husky-missing finding for them. The class hint comes from the project's row in `registry.md` (e.g., `game (Unity, 3D)`).

Reference example: `lume` uses `.githooks/pre-push` with `core.hooksPath = .githooks`.

### 4. `--no-verify` bypass history
- Run `git log --since="8 days ago" --grep="no-verify"` in each project.
- Also check the reflog for `--no-verify` in commit commands if possible.
- Report any occurrences with commit SHA, author, and date. Hook bypasses are a compliance red flag.

### 5. Required project files
- `CLAUDE.md` present at project root.
- `gotchas.md` present; if no entries added in the last 30 days, note it (not a failure — just a signal the project may not be logging lessons).
- `context-log.md` present (it's OK if empty — it's hook-maintained).

### 6. TodoWrite state sanity
- If the project has a TodoWrite persistence file (check `.claude/todos.json` or similar), report whether any entries have been `in_progress` for >7 days. Long-lived in-progress todos are a "claimed done but isn't" smell.

### 7. Parent rules inheritance
- If the project's `CLAUDE.md` is over ~5 KB, note it — projects should extend the parent, not duplicate it.
- Grep the project's `CLAUDE.md` for phrases that match verbatim text from the parent `CLAUDE.md`. Report any overlap > 20 lines (suggests copy-paste instead of inheritance).

### 8. Trellis rules inheritance wiring (critical)

> **Tracking policy.** Symlinks whose targets contain absolute paths under `$TRELLIS_ROOT` (`.claude/rules/trellis.md`, `.claude/skills/process-gate`, `.agents/rules/trellis.md`, `.agents/skills/process-gate`) are **per-machine state** and MUST be gitignored. Each developer recreates them post-clone via `scripts/onboard-project.sh`. Tracking them in git is the failure mode — different developers' clones produce different absolute targets that conflict on every cross-machine merge. Relative symlinks (e.g., root `AGENTS.md → CLAUDE.md`) remain tracked.

The parent rules in `core-rules/CLAUDE.md` are load-bearing — they MUST reach every child session, including headless `claude -p` invocations used by every scheduled task. Two checks:

- **Primary mechanism — `.claude/rules/trellis.md` symlink.** The file `<project-root>/.claude/rules/trellis.md` MUST exist, MUST be a symlink (not a regular file or copy), and MUST resolve to `__TRELLIS_PATH__/core-rules/CLAUDE.md` exactly.
  - Missing file → **critical: Trellis rules not inherited in headless mode** (every scheduled run against this project is running unparented).
  - File present but not a symlink → **critical: Trellis rules diverged from canonical** (report the sha256 of the file and the sha256 of the canonical so the user can see the drift).
  - Symlink present, target path string matches canonical, but `readlink -f` returns empty OR `[ -f <resolved-target> ]` fails:
    - **If the environment guard above has already confirmed the canonical target exists** (`__TRELLIS_PATH__/core-rules/CLAUDE.md` is present on this filesystem), then the symlink is genuinely broken → **critical: Trellis rules symlink dangling**.
    - **If the canonical target is not mounted in the audit environment**, treat this as a mount gap, not a project fault. The environment guard should have already emitted the single info finding and halted the audit — do not reach this case.
  - Symlink present but target path string is wrong (does not match canonical) → **critical: Trellis rules symlink points at non-canonical path** (report the actual target).
  - Symlink present and **tracked by git** (`git ls-files --error-unmatch .claude/rules/trellis.md` succeeds) → **warning: Trellis rules symlink is tracked in git but encodes a per-machine absolute path** (different `$TRELLIS_ROOT` on every developer's machine; tracked targets will conflict on every cross-machine merge — gitignore the symlink and recreate via `scripts/onboard-project.sh`).

- **Secondary mechanism — `@`-import in project `CLAUDE.md`.** The project `CLAUDE.md` SHOULD contain the line:

  ```
  @__TRELLIS_PATH__/core-rules/CLAUDE.md
  ```

  This is approval-gated and interactive-only — missing it is a **warning**, not critical, because the symlink is the load-bearing path.

Rationale for severity: `@`-imports are silently disabled in `claude -p` headless mode per Claude Code's trust-verification design. The `.claude/rules/trellis.md` symlink is the only mechanism that loads unconditionally across modes. See "Load-bearing inheritance mechanism" in `core-rules/CLAUDE.md`.

### 9. Codex parity wiring

If parent `__TRELLIS_PATH__/trellis.config.json` includes `"codex"` in `harnesses`, every registered project must also carry Codex inheritance:

- Root `AGENTS.md` exists. Symlink to `CLAUDE.md` is OK (relative symlinks are stable across machines and stay tracked); a regular file is OK only if it contains the Trellis import/path or equivalent project-specific Codex instructions.
- `<project-root>/.agents/rules/trellis.md` exists, is a symlink, and resolves to `__TRELLIS_PATH__/core-rules/CLAUDE.md`. If the symlink is **tracked by git** → **warning** per the tracking policy in §8.
- `<project-root>/.agents/skills/process-gate/` exists, is a symlink, and resolves to `__TRELLIS_PATH__/core-rules/skills/process-gate`. If the symlink is **tracked by git** → **warning** per the tracking policy in §8.
- `<project-root>/.agents/skills/process-gate-local/local.config.sh` exists.
- `<project-root>/.codex/hooks.json` exists and does not contain hardcoded absolute project paths.
- Every script in `__TRELLIS_PATH__/core-rules/codex/hooks/*.sh` exists under `<project-root>/.codex/hooks/` and is executable.

Missing `AGENTS.md`, `.agents/rules`, `.agents/skills/process-gate`, or `.codex/hooks.json` is **critical** because Codex sessions will run without the parent layer or without hook enforcement. Missing local config or non-executable Codex hook scripts are **warning**.

## Output format

Write a single compliance report to `__TRELLIS_PATH__/audits/YYYY-MM-DD-cross-project-process-audit.md` (create the `audits/` directory if missing). Structure:

```
# Weekly process audit — <date>

## Summary
- Projects audited: <count>
- Projects with issues: <count>
- Total findings: <count> (critical: N, warning: N, info: N)
- Blacklist overdue-for-review: <list or "none">

## Findings by project

### <project-name>
**Status:** <OK | N findings>
<for each finding:>
- **[severity]** <check name>: <what's wrong> → <recommended fix>

<repeat for each project>

## Cross-cutting observations
<anything that shows up in multiple projects — worth a parent-level fix>

## Next actions
<prioritized list of things to address before the next audit>
```

## Severity rubric

- **critical**: hook missing entirely, `--no-verify` bypass in the last 7 days, CLAUDE.md missing
- **warning**: stale hook (parent has updates not pulled), husky missing a standard hook, long-lived in-progress todos
- **info**: gotchas.md not updated in 30 days, minor drift, blacklist overdue-for-review

## Boundaries

- **Do not modify any files in the audited projects.** Read-only.
- Do not open PRs or commit anything. The audit reports; the user decides what to fix.
- If a check can't run (e.g., project path missing, git not initialized), log the failure and move on. Don't abort the whole audit.
- Notify on completion (scheduled-tasks default) so the user sees the report landed.

## Sensible failure modes

If `registry.md` is missing, stop with a clear error — audit cannot run without it.
If a project in the registry has no `.git/`, note it and skip git-dependent checks (bypass history, recent commits).
If `__TRELLIS_PATH__/core-rules/hooks/` doesn't exist yet (pre-Phase-2), skip the staleness check and note "parent hook canonical not yet established."
