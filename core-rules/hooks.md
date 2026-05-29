# Hook specifications

Two tiers: **fast-local** runs on every relevant turn, **heavy-gated** runs on wrap-up. A third tier — **git-boundary** husky hooks — catches anything that slipped past the agent. Specs only; implementations live per-project under `.claude/hooks/`, `.codex/hooks/`, and `.husky/`.

Claude Code and Codex use different hook envelopes, so Trellis keeps separate canonical implementations:

- Claude Code: `core-rules/hooks/*.sh`, copied to `<project>/.claude/hooks/` and registered in `<project>/.claude/settings.json`.
- Codex: `core-rules/codex/hooks.json` plus `core-rules/codex/hooks/*.sh`, copied to `<project>/.codex/`.

The policy intent is the same across harnesses. Claude-specific JSON such as `hookSpecificOutput.permissionDecision` stays in the Claude implementation; Codex blocking hooks emit `{"decision":"block","reason":"..."}` and exit 2.

---

## Tier 1 — fast-local (every turn)

Goal: sub-second feedback, zero approval fatigue. If a fast-local hook fails, Claude sees it the same turn it happened.

### block-destructive
- **Event:** `PreToolUse` on `Bash`
- **Triggers:** command matches any of —
  - `rm` with force flags targeting any **absolute path**, `~`, `$HOME`, or `..` (e.g. `rm -rf /`, `rm -rf /Users/me/foo`, `rm -rf ~/work`, `rm -rf ../sibling`); allows relative-cwd targets (`rm -rf .`, `rm -rf ./build`, `rm -rf node_modules`) so blanket cleanups in build scripts still pass
  - `git push --force` / `-f` / `--force-with-lease` on any branch
  - `git reset --hard` targeting `HEAD`, `HEAD~N`, or `origin/*`
  - SQL `DROP TABLE`, `DROP DATABASE`, `TRUNCATE TABLE`, or `DELETE FROM` without a `WHERE` clause
  - `.env*` file reads via `cat`, `less`, `head`, `tail`, `more`, `source`, `grep`, `sed`, `awk`, `bat`, or `**/secrets/**` glob on any reader
- **Block condition:** trigger matched
- **Return:** Claude emits `{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "<which rule fired, one line>" } }`; Codex emits `{ "decision": "block", "reason": "<which rule fired, one line>" }`.
- **Exit:** Claude exits 0 because PreToolUse decisions ride in the JSON payload. Codex exits 2 for a block. Non-blocking paths exit 0.

### post-edit-verify
- **Event:** `PostToolUse` on `Edit`, `Write`, `MultiEdit`
- **Scope:** the touched file only — not the whole repo. Filter by extension: `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.rs`, `.go`. Other extensions exit silently.
- **Runs:** **lint only.** Type-checking is deferred to `stop-verify` to keep this hook under the 3s budget.
- **Auto-detection:**
  - JS/TS → walk for any of `.eslintrc{,.js,.cjs,.json,.yml,.yaml}` or `eslint.config.{js,mjs,ts}`; if found, `npx eslint --quiet <file>`
  - Python → if `ruff` on path, `ruff check <file>`
  - Rust → `cargo clippy --quiet --message-format=short -- -D warnings` (project-wide; Rust has no practical per-file lint)
  - Go → `golangci-lint run <file>` if on path, else `go vet $(dirname <file>)`
- **Block condition:** linter exits non-zero
- **Return:** `{ "decision": "block", "reason": "<error output truncated to 50 lines>" }` on failure
- **Exit:** 2 on block, 0 otherwise. JSON decision takes precedence when present.
- **Invariant:** must complete in <3s for a single-file edit. Anything slower belongs in tier 2.

### truncation-check
- **Event:** `PostToolUse` on `Grep`, `Bash`, `Read`
- **Triggers:** tool result length ≥ 100,000 chars OR output ends with a `...truncated...` marker
- **Return:** `{ "additionalContext": "Result was truncated. Re-run with narrower scope or read the source file directly." }`
- **Exit:** never blocks — advisory only

### session-context
- **Event:** `SessionStart` (source: `startup` or `resume`)
- **Injects:** current git branch, last 5 commits on the branch, dirty-file count, any `context-log.md` from the last session, any outstanding `gotchas.md` entries tagged unresolved
- **Path resolution:** `context-log.md` and `gotchas.md` are read from the **canonical project root** (resolved via `git rev-parse --git-common-dir`), so worktree sessions still see the repo-level files instead of looking only inside the worktree.
- **Return:** `{ "additionalContext": "<assembled header, <2K chars>" }`
- **Exit:** never blocks

### save-context-log
- **Event:** Claude Code `PreCompact`; Codex `Stop`
- **Writes:** `context-log.md` at the **canonical project root** (resolved via `git rev-parse --git-common-dir`) with — current branch, files touched this session, open todos, last two user asks, last two assistant decisions
- **Worktree behavior:** the log is written to the main checkout regardless of which worktree the session ran in, so worktree cleanup does not destroy the log. Cross-worktree clobbering on the same canonical root is a known limitation pending the per-branch follow-up; same-branch sessions are unaffected.
- **Return:** no stdout needed; file write is the side effect
- **Exit:** never blocks

### post-compact-context
- **Event:** `SessionStart` (source: `compact` when provided)
- **Injects:** contents of `context-log.md` if present, read from the **canonical project root** (resolved via `git rev-parse --git-common-dir`)
- **Return:** `{ "additionalContext": "<contents of context-log.md>" }`
- **Exit:** never blocks

---

## Tier 2 — heavy-gated (wrap-up)

Goal: catch "claims done but isn't" before the turn ends. Runs exactly once per stop event, guarded against infinite loops.

### stop-verify
- **Event:** `Stop`
- **Guard:** if `$stop_hook_active == true`, exit 0 immediately. Also exit 0 if no file edits occurred this turn (pure chat / read-only).
- **Runs, in order:**
  1. **TodoWrite check** — if any task is `in_progress` or `pending`, block. Claude must complete, defer with reason, or abandon with reason. This is the receipts-required enforcement point.
  2. **Typecheck** — auto-detected: `tsc --noEmit` if `tsconfig.json`, `mypy .` if configured in `pyproject.toml`/`mypy.ini`, `cargo check` if `Cargo.toml`, `go vet ./...` if `go.mod`. Full repo.
  3. **Lint** — same detection as `post-edit-verify` but run repo-wide: eslint, ruff, clippy, golangci-lint.
  4. **Test** — auto-detected fast suite: `npm test` (if `test` script), `pytest` (if installed), `cargo test`, `go test ./...`. Skip e2e/integration unless explicitly configured.
- **Block condition:** any step fails OR todos are open
- **Error slicing on failure:**
  - Typecheck / lint output → **first 30 lines** (compile errors are at the top; the rest is cascade noise)
  - Test output → **last 30 lines** (assertion messages and stack traces land at the bottom)
- **Return on block:** `{ "decision": "block", "reason": "<step name>: <sliced output>" }`
- **Return on pass:** exit 0, no output
- **Budget:** 90s soft cap. If typecheck+lint+test exceeds this, split — move tests to CI-only and document in project `hooks.md`.
- **Subtree scoping:** if every changed file in the turn sits under one subdirectory that carries its own manifest (`package.json`, `go.mod`, `pyproject.toml`, or `Cargo.toml`), the hook `cd`s into that subtree before steps 2-4. Cuts wall time + noise on monorepos. Mixed-subtree changes fall back to repo root. Escape hatch: `PROCESS_GATE_FORCE_ROOT=1` always runs at root.

### code-review-subagent
- **Event:** `Stop`
- **Guard:** `$stop_hook_active` check, then runs only on **edit-heavy turns** (definition: ≥3 files touched OR ≥200 lines added/changed; project may override). Skipped on pure doc edits.
- **Mechanism:** dispatches a code-review subagent via the Agent tool against the current turn's diff (`git diff HEAD~0` since last assistant stop). The subagent has read-only tools and returns structured findings.
- **Reviewer interface (pluggable):**
  - v1: single `code-reviewer` subagent — checks correctness, obvious bugs, security red flags, matches project patterns
  - v2 (future): parallel multi-angle reviewers — security, performance, API-design, test-coverage, docs — results merged. Interface reserved; don't wire it until v1 proves useful.
- **Return:** findings appended to response as a collapsible `<review>` block. Findings are **advisory**; Claude must either resolve or explicitly acknowledge-and-defer each one in the same turn.
- **Block condition:** only if the subagent returns `decision: "block"` for a severity-critical finding (security hole, data loss, broken build path). Advisory findings don't block.
- **Budget:** 60s soft cap. If over, the hook logs a warning but does not block.
- **Design choice (parked for Phase 2):** exact "edit-heavy" threshold and whether doc-only edits truly skip. Defaults above are starting points.

### ui-verify
- **Event:** `Stop`
- **Guard:** `$stop_hook_active` check, then runs only when the turn's diff touches UI files (project-configured glob — typical: `**/*.{tsx,jsx,vue,svelte,html,css}`)
- **Runs:**
  1. Checks dev server is reachable on configured port. If not, starts it via the `monitor` tool and waits for ready signal (configured regex in stdout, e.g., `ready in \d+ms`).
  2. Takes a screenshot of the affected route(s). Preferred path: computer-use MCP `screenshot` after navigating the user's browser. Fallback path: headless Playwright (`npx playwright screenshot <url> <out>`).
  3. Attaches screenshot path to the response.
- **Block condition:** dev server fails to start, OR screenshot path is empty, OR Claude claimed a UI change without running this hook
- **Return on block:** `{ "decision": "block", "reason": "UI-visible change requires visual verification. <specific failure>" }`
- **Design choice (parked for Phase 2):** fallback policy — do we require computer-use when available and only fall back to Playwright if the user's browser is unreachable, or always prefer Playwright for determinism? Start with: prefer computer-use (matches the "verify what the user sees"), fall back to Playwright silently.

### propose-rules (experimental, opt-in)
- **Event:** `Stop`
- **Status:** experimental. Not registered in the canonical `claude-settings.json` template. Projects opt in by adding the hook entry to their own `.claude/settings.json` AND setting `PROCESS_GATE_PROPOSE_RULES=1` in `.claude/hooks/config.sh`. Script is canonical and synced via `sync-hooks.sh`; activation is per-project.
- **Guard:** opt-in gate first (silent exit), then `$stop_hook_active`, then dirty-tree skip (pure chat → exit), then a cheap heuristic on the transcript tail looking for explicit-correction signals ("no", "don't", "actually", "stop doing", "that's wrong", "never do"). The subagent only fires when at least one signal is present in the last ~200 transcript lines.
- **Mechanism:** dispatches a one-shot `claude -p --max-turns 1` subagent that reads the transcript tail + the project's `gotchas.md` and proposes ONE candidate gotchas entry, or emits the literal string `NONE`. The proposal is returned as `additionalContext`; this hook never blocks.
- **Budget:** 30s soft cap (timeout on the `claude` invocation).
- **Why opt-in:** every fire costs tokens. Projects that log lessons regularly (Neev, TGSC) get value; throwaway projects don't. Out-of-the-box this hook is silent. Promote out of "experimental" once at least two projects have run it for a month without false positives.
- **Pairs with:** `gotchas-rollup` (monthly) — propose-rules surfaces n=1 candidates per turn; gotchas-rollup clusters n≥3 candidates into parent-rule promotions.

---

## Tier 3 — git-boundary (husky)

Goal: last-line defense. If a tier-1 or tier-2 hook misfired, the local git commit/push still catches it. Never the primary gate — Claude should not rely on these running.

### pre-commit (husky + lint-staged)
- **Runs:** lint-staged on staged files only — format + lint + typecheck for touched files
- **Purpose:** blocks commits that slipped past `post-edit-verify`
- **Block:** non-zero exit from any lint-staged task

### commit-msg (husky + commitlint)
- **Runs:** commitlint with `@commitlint/config-conventional`
- **Scope policy:** **unscoped default**. Scopes are optional; when used, they must match a project-configured allowlist. Prevents invented scopes.
- **Block:** message does not parse as conventional commit

### pre-push (husky)
- **Runs, in order:**
  1. **PR-flow guard** — blocks direct push to `main` or `master` across all Trellis projects. Commits must land on a branch and merge via PR. Emergency override: `TRELLIS_ALLOW_MAIN_PUSH=1 git push` (use rarely; every invocation should be documented in the project's `gotchas.md` or a commit message trailer).
  2. Full typecheck + lint + fast test suite (same set as `stop-verify` step 2-4)
- **Purpose:** catches anything where `stop-verify` was bypassed (manual commit outside a Claude turn, amended commit, etc.) and enforces Trellis's PR-flow policy at the git boundary.
- **Block:** any step fails
- **GitHub-side complement:** local guard prevents accidents; branch protection on the remote is the durable gate. Every Trellis project should have `main` branch-protected (require PR, passing status checks, merge-commit only — squash-merge disabled in repo settings to preserve full history). Review-count enforcement is N/A here — sole-maintainer org, GitHub blocks self-approval; the PR window itself + CI is the gate.

---

## Invariants across all tiers

- **Never skip with `--no-verify`.** If a hook fails, fix the cause. If the hook is wrong, fix the hook and commit that separately.
- **`stop_hook_active` guard is mandatory** on every `Stop` hook. Missing it causes infinite loops when a blocked hook triggers another stop.
- **Exit codes matter:** `0` = pass (continue), `2` = block with stderr shown to Claude, anything else = non-blocking error (logged).
- **JSON return takes precedence over exit code** when both are present.
- **Hooks run with the user's env,** not Claude's sandbox. A hook that needs `node` or `python` assumes the project's local toolchain is installed.
- **Budget discipline:** tier 1 ≤ 3s, tier 2 ≤ 90s (stop-verify) / 60s (review) / project-configured (ui-verify). Over budget → refactor, don't accept.

---

## Project overrides

Each project may override:
- Per-file linter command for `post-edit-verify`
- Typecheck/lint/test commands for `stop-verify` and `pre-push`
- Edit-heavy threshold for `code-review-subagent`
- UI file glob and dev-server port/ready-regex for `ui-verify`
- Commit scope allowlist for `commit-msg`

Overrides live in the project's `.claude/hooks/config.sh` and/or `.codex/hooks/config.sh`. The parent hook scripts are read-only; projects point them at their tools via env vars.

---

## Lineage

Core patterns (block-destructive, post-edit-verify, stop-verify, truncation-check) trace back to [iamfakeguru/claude-md](https://github.com/iamfakeguru/claude-md) (MIT). That template was the seed for Neev and TGSC's hook stacks. This file extends the template with: the three-tier architecture, `stop-verify`'s TodoWrite guard, `code-review-subagent`, `ui-verify`, the `session-context` / `save-context-log` / `post-compact-context` hooks, and the git-boundary tier.
