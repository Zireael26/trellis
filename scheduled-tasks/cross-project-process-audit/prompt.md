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

**Run `scripts/doctor.sh` (read-only) first.** It deterministically covers the inheritance / symlink / hook-freshness checks below (checks 1, 2, 8, 9), so let its output stand as the verdict for those and spend your judgment on what the script cannot mechanically check — husky/native-hook adequacy, `--no-verify` bypass history, gotchas/codebase-map staleness, long-lived in-progress todos, and copy-paste-vs-inheritance overlap.

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

### 10. Codebase map (when warranted)

Projects with **≥ 5 top-level directories** (excluding dotfiles and any path matched by canonical `permissions.deny` entries: `node_modules`, `.next`, `dist`, `build`, `out`, `target`, `vendor`, `.venv`, `venv`, `coverage`, `.turbo`, `.cache`) MUST carry a `## Codebase map` heading in their root `CLAUDE.md`. The section is one line per top-level directory describing its role.

Procedure:

- Count top-level dirs in the project root, filtering as above. Use `ls -d <project>/*/ | grep -Ev '/(node_modules|\.next|dist|build|out|target|vendor|\.venv|venv|coverage|\.turbo|\.cache)/$' | wc -l`.
- If the count is **< 5**, the section is optional — emit no finding.
- If the count is **≥ 5** and the project `CLAUDE.md` has no `## Codebase map` heading (case-insensitive, allowing hyphen or space variants): **warning**: `codebase-map missing` → suggest the user run `/primer <project>` or hand-write the section per `engineering-process.md` §9.1.
- If the heading exists but the bullet list is empty / placeholder text: **info**: `codebase-map stub-only`.
- If the heading exists but its directory entries reference paths that no longer exist on disk: **warning**: `codebase-map stale` → list the offending entries.

Skip this check entirely if `<project>/CLAUDE.md` is missing — §5 already covers that.

Rationale: large repos pay a per-session exploration cost the agent does not need to pay every time. A five-line map saves the round trip. The rule lives in `engineering-process.md` §9.1; this check enforces it.

### 11. Pipeline-skip nudge (advisory)

The `clarify → spec → plan → tasks → analyze` pipeline (`engineering-process.md` §14.7) is **opt-in**. A project is never required to run it, so mere absence of spec/plan artifacts is **not** a finding — flagging it would fire on nearly every project and bury the report in noise. This check fires only on a signal that a **feature-sized** change *should* have used the heavyweight track: a genuinely large landing in the audit window with no corresponding spec/plan artifact alongside it. The bar is deliberately high — ordinary weekly maintenance churn must NOT trip it.

Procedure (read-only). Use the same 8-day window as check 4 (this is the *weekly* audit, not the daily bypass scan). The window is wide, so the threshold must be feature-scale, not per-turn — a project doing normal maintenance (a few hundred lines across several files of routine work) must stay silent:

- **Primary signal — a new top-level subsystem appeared.** Did a brand-new top-level directory land in the window (a new feature area / subsystem, not a renamed or vendored dir)? This is the strongest, lowest-false-positive "a feature landed" indicator. Detect via `git log --since="8 days ago" --diff-filter=A --name-only` and look for files introducing a new top-level dir.
- **Secondary signal — a single substantial landing.** Scope to the *largest single commit or merge* in the window, not the cumulative weekly diff (cumulative churn over 8 days clears any per-turn bar and would re-create the mere-absence noise). A single commit/merge that is clearly feature-sized (well above routine churn — e.g. a single landing on the order of many hundreds of lines across multiple files, materially larger than the project's typical commit) qualifies; a week of small maintenance commits that merely sum to a large total does NOT.
- **No pipeline artifact alongside it:** `git log --since="8 days ago" --name-only -- docs/specs/ docs/plans/` is empty (no spec or plan file added or modified in the same window).
- If a **feature-sized landing** occurred (primary OR secondary signal) **and** no `docs/specs/` or `docs/plans/` artifact was added/modified in the window → **info**: `pipeline-skip nudge: a feature-sized change landed (<new subsystem / single large landing>) with no spec/plan artifact under docs/specs|plans in the window` → suggest, as a nudge not a block, that a change of this scale is a candidate for the opt-in `clarify → spec → plan` track next time (or a short `docs/plans/<topic>.md` retroactively if the work is still in flight).
- If no feature-sized landing occurred (only routine churn), or a spec/plan artifact was touched in the window → emit no finding. When in doubt, stay silent — a false nudge is worse than a missed one for an advisory category.

Severity is **info** by design — the pipeline is opt-in, so this is a forward-looking nudge, never a compliance failure. Skip this check if the project has no `.git/` (no window history to measure).

### 12. Steering-doc / skill-name drift (advisory)

Vendored steering docs and the skill names a project references should track the canonical set in the control plane. Two sub-checks, both read-only:

- **Steering-doc drift.** Compare the project's vendored steering docs (under its `docs/` if it carries them) against the canonical set published from `__TRELLIS_PATH__/docs/` — the `docs/*-steering.md` family (e.g. `opus-4.8-steering.md` and its sibling per-harness steering docs). If a project vendors a steering doc that no longer exists in the canonical set (a renamed/removed doc), or carries a canonical-named steering doc whose content is stale versus the canonical copy (`diff` differs), report it. A project that vendors *no* steering docs is not a finding (vendoring is not mandatory).
- **Skill-name drift.** Grep the project's `CLAUDE.md` (and any project skill prompts under `.claude/skills/`) for references to Trellis skill names. The canonical skill set lives in `__TRELLIS_PATH__/core-rules/skills/`: `analyze`, `brainstorming`, `clarify`, `execute`, `plan`, `process-gate`, `security-gate`, `spec`, `tasks`. If a project's operational instructions reference a skill name that is not in the canonical set (a renamed or removed skill — e.g. an old `writing-plans` handoff that should now point at `execute`), report it. **Do not** flag intentionally-preserved historical references (e.g. `superpowers:<skill>` mentions in CHANGELOG or dated plan history) — those are deliberately retained per the docs convention; scope this to live, operational handoffs.
- Emit **info**: `steering-doc/skill-name drift: <project references renamed/removed artifact X>` → suggest re-vendoring the current steering doc, or repointing the operational handoff at the canonical skill name.

Severity is **info** (minor drift). Rationale: model-specific steering and skill names evolve in the control plane; a project pinned to a stale name silently loses the current guidance.

### 13. Pre-push wired to the merge gate (warning)

The local `pre-push` git hook is the **cross-harness merge gate**: it runs `run-all.sh --mode=merge` on every harness — including AntiGravity, which runs no workspace hooks — and is fail-closed at push for the deterministic gate set (PR-hygiene / secrets / bypass / tests / docs / stack / security-diff / analyze). A registered project whose `pre-push` is not wired to `run-all.sh` is not getting that merge gate.

This check uses the **same detection as doctor's `hc_prepush_wired_runall`** (`scripts/lib/health-checks.sh`) so the two never disagree — doctor and this audit must reach the same verdict on the same project:

- Locate `.husky/pre-push`, else `.git/hooks/pre-push` (husky takes precedence if both exist). **Never execute the hook** — running `pre-push` runs the whole merge gate including tests; this is a read-only inspection.
- If a `pre-push` exists and its content references `run-all.sh` (literal substring, accepting either a `.claude/` or `.agents/` path) → PASS, emit no finding.
- If no `pre-push` exists at all → **warning**: `prepush-wired-runall: no pre-push hook — merge gate not wired` → re-seed the canonical `pre-push` (run `scripts/onboard-project.sh`).
- If a `pre-push` exists but does not reference `run-all.sh` → **warning**: `prepush-wired-runall: pre-push present but not wired to run-all.sh — merge gate bypassed` → re-seed the canonical `pre-push`.

Both failure sub-cases are **warning**, matching `hc_prepush_wired_runall`'s `HC_WARN` return in both — this is a wiring gap, not the §3 PR-flow-guard breach (a project can pass §3's PR-flow guard yet fail this merge-gate-wiring check). Note that the daily `bypass-tripwire` audit (`scheduled-tasks/bypass-tripwire/`) remains the after-the-fact backstop: it catches anyone who bypassed the local hook after the fact (`--no-verify`, direct-push, force-push), so an unwired or bypassed `pre-push` is a proactive nudge here while the daily scan is the reactive net.

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
- **warning**: stale hook (parent has updates not pulled), husky missing a standard hook, long-lived in-progress todos, `pre-push` not wired to the merge gate (check 13)
- **info**: gotchas.md not updated in 30 days, minor drift, blacklist overdue-for-review, pipeline-skip nudge (check 11), steering-doc/skill-name drift (check 12)

## Boundaries

- **Do not modify any files in the audited projects.** Read-only.
- Do not open PRs or commit anything. The audit reports; the user decides what to fix.
- If a check can't run (e.g., project path missing, git not initialized), log the failure and move on. Don't abort the whole audit.
- Notify on completion (scheduled-tasks default) so the user sees the report landed.

## Sensible failure modes

If `registry.md` is missing, stop with a clear error — audit cannot run without it.
If a project in the registry has no `.git/`, note it and skip git-dependent checks (bypass history, recent commits).
If `__TRELLIS_PATH__/core-rules/hooks/` doesn't exist yet (pre-Phase-2), skip the staleness check and note "parent hook canonical not yet established."
