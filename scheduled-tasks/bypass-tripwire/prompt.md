# Bypass tripwire (daily)

You are running a daily scan for process bypasses across the user's active personal projects. **Only emit a report if you find a bypass.** Silent days are expected and correct — they mean the team is following process.

## Inputs

1. Read `__SE_CORE_PATH__/registry.md`.
2. Read `__SE_CORE_PATH__/blacklist.md`.
3. Target set = `registry \ blacklist`.

## Checks per project

For each target project, scan the **last 24 hours** of git history and reflog:

### 1. `--no-verify` in commit commands
- `git log --since="24 hours ago" --format="%H|%an|%ad|%s"` — scan commit subjects and bodies for literal `--no-verify`, `--skip-hooks`, `no verify`, `skip hook`.
- Also scan `git reflog --since="24 hours ago"` for any command that included `--no-verify`.

### 2. Direct-to-main pushes
- If the project has a protected-main convention (default: `main` or `master`), look at commits on main in the last 24h. Any commit whose author != merge-commit author, OR any non-merge commit on main authored directly (i.e., not via PR merge), counts as a direct push. Heuristic: non-merge commit on main whose parent count == 1 AND whose commit message does not match a squash-merge pattern (`\(#\d+\)` or `Merge pull request`).
- Noisy heuristic — err on the side of flagging and let the user confirm.

### 3. Husky hook bypasses
- Scan `git log` for commit trailers like `hook-bypass:` or `skip-ci:` from the last 24h.
- Also check if any of `.husky/pre-commit`, `.husky/commit-msg`, `.husky/pre-push` were modified in the last 24h (someone disabling hooks mid-flight).

### 4. Force pushes to protected branches
- `git reflog show main --date=iso` and `git reflog show master --date=iso` (if present) for forced updates in the last 24h.

## Severity

Everything at this cadence is **critical** by construction — that's why we run daily. If you find a benign-looking bypass (e.g., `--no-verify` on a docs-only commit), still include it but mark `classification: low-risk` in the finding.

## Output

If **nothing** is found: do not write a file. Report "No bypasses detected across N projects in the last 24 hours" and exit.

If **anything** is found: write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-bypass-tripwire.md` with:

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
