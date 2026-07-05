# Bypass tripwire (daily)

You are running a daily scan for process bypasses across the user's active personal projects. **Only emit a report if you find a bypass.** Silent days are expected and correct — they mean the team is following process.

## Loop safety

This task is a Trellis loop and honors `core-rules/loop-safety.md`. Ceilings resolve per-loop override → `.trellis.config.json.loop_safety` → `trellis.config.json.loop_safety` → built-in fallback (`max_iterations` 100 / `no_progress_iterations` 3 / `budget_ceiling_usd` 1000). The loop halts on any one ceiling and emits a structured halt report (which ceiling tripped, last progress marker, work done); the halt surfaces in this run's report rather than dying silently.

- `max_iterations`: inherit default (100)
- `no_progress_iterations`: inherit default (3)
- `budget_ceiling_usd`: inherit default (1000)
- Progress signal: **new finding** (an audited project surfaces a new bypass).

## Inputs

1. Read `__TRELLIS_PATH__/registry.md`.
2. Read `__TRELLIS_PATH__/blacklist.md`.
3. Target set = `registry \ blacklist`.

## Checks per project

For each target project, scan the **last 24 hours** of git history and reflog:

### 1. `--no-verify` in commit commands
- `git log --since="24 hours ago" --format="%H|%an|%ad|%s"` — scan commit subjects and bodies for literal `--no-verify`, `--skip-hooks`, `no verify`, `skip hook`.
- Also scan `git reflog --since="24 hours ago"` for any command that included `--no-verify`.

### 2. Direct-to-main pushes
- If the project has a protected-main convention (default: `main` or `master`),
  inspect commits newly reachable from that branch in the last 24h.
- Treat a commit as a **confirmed bypass** only when there is corroborating
  evidence that it landed outside the PR flow: reflog/push evidence, no matching
  merged PR in GitHub, and no containing merge commit on protected main that
  references a PR.
- Do **not** flag a non-merge commit merely because it is reachable from
  `main`. Squash merges and rebase merges intentionally create single-parent
  commits on protected branches. Before flagging, check at least one of:
  `gh pr list --state merged --search <sha>`, commit message PR patterns
  (`(#123)` / `Merge pull request #123`), or a protected-branch merge commit
  containing the candidate SHA.
- Known Trellis automation sync subjects such as `chore(trellis): sync ...`,
  `chore(codex): sync ...`, and hook-runtime refreshes are not bypass findings
  unless paired with explicit bypass evidence.
- If evidence is incomplete, record it as `classification: needs-confirmation`
  and **warning**, not critical. Critical is reserved for confirmed bypasses.

### 3. Husky hook bypasses
- Scan `git log` for commit trailers like `hook-bypass:` or `skip-ci:` from the last 24h.
- Also check if any of `.husky/pre-commit`, `.husky/commit-msg`, `.husky/pre-push` were modified in the last 24h (someone disabling hooks mid-flight).

### 4. Force pushes to protected branches
- `git reflog show main --date=iso` and `git reflog show master --date=iso` (if present) for forced updates in the last 24h.

## Severity

Confirmed bypasses at this cadence are **critical** by construction — that's why
we run daily. If a confirmed bypass is benign-looking (e.g., `--no-verify` on a
docs-only commit), still include it but mark `classification: low-risk` in the
finding. Heuristic direct-to-main signals without corroborating evidence are
warnings with `classification: needs-confirmation`.

## Output

If **nothing** is found: do not write a file. Report "No bypasses detected across N projects in the last 24 hours" and exit.

If **anything** is found: write to `__TRELLIS_PATH__/audits/YYYY-MM-DD-bypass-tripwire.md` with:

```
# Bypass tripwire — <date>

## Summary
- Projects scanned: <count>
- Bypasses found: <count>
- Critical: <count>, Low-risk: <count>

## Findings

### <project-name>
- **<severity>** <check-type> — <short description>
  - Commit: <sha> by <author> on <date>
  - Command/message: `<exact evidence>`
  - Recommended fix: <action>

<repeat per project with findings>

## What this means
Bypasses circumvent the guardrails we put in place to catch errors before they land. Investigate each one. If legitimate, document the reason; if not, revert and re-land through the normal flow.
```

## Boundaries

- Read-only across all audited projects.
- Never rewrite git history, never suggest `git reset --hard` or force-pushes as remediation.
- If a project has no `.git/`, skip it silently.
- Do not notify on clean days — the notification is the report itself.
