# Test health (weekly)

You are verifying that each active personal project's fast test suite is **green**. The weekly `cross-project-process-audit` checks that hooks and husky are *installed*; this check verifies they actually *pass*.

## Execution environment

This task **must** run on the user's macOS host. Every registered project's `node_modules` is hydrated for darwin-arm64 (the user's machine); running this audit in a linux-arm64 sandbox produces uniform `Cannot find module @rollup/rollup-linux-arm64-gnu` / `Cannot find module @rolldown/binding-linux-arm64-gnu` errors at vitest module load — see the 2026-04-24 / 2026-04-26 / 2026-04-27 reports for the full pattern. macOS host = arch parity = real signal.

If the macOS host is unavailable for a run, emit a single `info` finding (`test-health audit could not run: macOS host unavailable`) and stop. Do not fall back to a linux sandbox; the results are uniformly meaningless.

When sampling worktree state, do NOT invoke `git status` against project worktrees — the audit-sandbox `.git/` permission shape (write-allowed but unlink-denied) leaves a 0-byte `.git/index.lock` behind that the sandbox cannot remove and the host's next `git commit` will block. Use direct reads of `.git/HEAD` and `.git/refs/heads/<branch>` instead.

## Inputs

1. Read `__SE_CORE_PATH__/registry.md`.
2. Read `__SE_CORE_PATH__/blacklist.md`.
3. Target set = `registry \ blacklist`.

## Checks per project

For each target project, **in a read-only manner** (don't commit anything, don't leave the worktree dirty):

### 1. Auto-detect test command

Same detection order as `stop-verify.sh`:
- `package.json` with a `scripts.test` (not the "no test specified" default) → `npm test --silent` or `pnpm test` (use pnpm if the project has `pnpm-lock.yaml`; use `bun run test` if the project has `bun.lock` / `bun.lockb`).
- `pyproject.toml` / `pytest.ini` / `setup.cfg` + `pytest` available → `pytest --tb=short -q`.
- `Cargo.toml` + cargo → `cargo test --quiet`.
- `go.mod` + go → `go test ./...`.
- `tools/run-tests.sh` (executable) → `bash tools/run-tests.sh`. Use this for projects that bring their own runtime (Unity, Godot, custom toolchain) and ship a thin CLI wrapper. Wrapper exit codes per convention: 0 = green, 1 = red, 2 = environment misconfigured (treat as `errored (env)`, not red).

If no test command can be detected, mark the project as `no-test-configured` and skip execution. That itself is worth noting — a project without tests is a process gap.

### 2. Run the test command

- Budget: 5 minutes per project. Kill the process if it exceeds.
- Capture: exit code, stdout/stderr (last 50 lines on failure), wall time.
- Skip e2e-tagged suites unless the test script is explicitly the fast suite.

### 3. Git hygiene post-run

- Confirm the worktree is still clean (`git status --porcelain` empty). If a test run dirtied the tree, that's a bug in the test suite worth noting.

### 4. Find the last green commit (only if the suite is currently red)

- Iterate back through `git log` (up to 20 commits), checkout each in a detached HEAD, run the test, find the newest passing commit. Then return to the original ref.
- If no passing commit is found in the last 20, report "red for at least 20 commits — long-standing breakage."

## Output

Write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-test-health.md`:

```
# Test health — <date>

## Summary
- Projects scanned: <N>
- Green: <count>
- Red: <count>
- Not configured: <count>
- Timed out / errored: <count>

## Scoreboard

| Project | Status | Duration | Last green | Notes |
|---|---|---|---|---|
| <name> | ✅ green | 1m 23s | HEAD | — |
| <name> | ❌ red | 0m 45s | abc123 (3 commits ago) | <failing suite> |
| <name> | ⚠️ no-test-configured | — | — | package.json has no test script |

## Red projects — details

### <project-name>
- **Failing tests:** <list>
- **Last 30 lines of test output:**
  ```
  <tail>
  ```
- **Last green commit:** <sha> by <author> on <date>
- **Commits since green:** <list of subjects>
- **Recommended action:** <your read — revert, investigate, etc.>

## Not-configured projects

List with a short recommendation (e.g., "add a minimal smoke test", "configure pytest", etc.).

## Cross-cutting observations

Anything worth noting across projects — e.g., "all 3 red projects broke in the same week, possible shared-dependency issue."
```

## Severity

- **critical**: red test suite, or timeouts — these block Stop-hook verification in affected projects.
- **warning**: no-test-configured, or worktree-dirty after test run.
- **info**: green but slow (>2 minutes wall time).

## Boundaries

- **Read-only across worktree state.** If running tests dirties the tree, reset before moving on. Never commit, never force-reset.
- When bisecting for last-green-commit, use `git checkout --detach`; always return to the original HEAD before leaving the project.
- Do not `npm install` / `pip install` / equivalent — if dependencies are out of date, report it, don't auto-fix.

## Sensible failure modes

- If a project's test command needs env vars or secrets that aren't available, that's a finding — not an error. Report it: "test command requires <X>, skipped."
- If network access is required for tests and the sandbox doesn't allow it, note the skip reason and continue.
