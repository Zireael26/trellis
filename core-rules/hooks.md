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
- **Canonical receipt marker:** the single machine-readable anchor the receipts check reads and the `execute` skill emits is `<!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->`, byte-identical to its definition in `core-rules/CLAUDE.md`. Fields map 1:1 to that prose — `cmd`→verification command, `exit`→exit code, `diff`→diff lines that prove the change.
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

### propose-rules (default-on, opt-out)
- **Event:** `Stop`
- **Status:** default-on in the canonical Claude and Codex hook manifests. Projects opt out by setting `PROCESS_GATE_PROPOSE_RULES=0` in `.claude/hooks/config.sh` and/or `.codex/hooks/config.sh`. Script copies are canonical and synced via `sync-hooks.sh` / `sync-codex-hooks.sh`.
- **Guard:** opt-out gate first (silent exit when set to 0), then `$stop_hook_active`, then dirty-tree skip (pure chat → exit), then a cheap heuristic on the transcript tail looking for explicit-correction signals ("no", "don't", "actually", "stop doing", "that's wrong", "never do"). The subagent only fires when at least one signal is present in the last ~200 transcript lines.
- **Mechanism:** dispatches a one-shot `claude -p --max-turns 1` subagent that reads the transcript tail + the project's `gotchas.md` and proposes ONE candidate gotchas entry, or emits the literal string `NONE`. The proposal is returned as `additionalContext`; this hook never blocks.
- **Budget:** 30s soft cap (timeout on the `claude` invocation).
- **Cost bound:** every fire costs tokens, so the default-on hook is bounded by both edit-heavy and correction-signal gates. Projects that never want rule proposals set `PROCESS_GATE_PROPOSE_RULES=0`.
- **Pairs with:** `gotchas-rollup` (monthly) — propose-rules surfaces n=1 candidates per turn; gotchas-rollup clusters n≥3 candidates into parent-rule promotions.

---

## Realized cores — reviewer ladder & ui-verify decision core

This section is the **authoritative implementation interface** for the two Tier-2
gates above. It refines the `code-review-subagent` and `ui-verify` specs: where the
prose above describes intent, the contracts here describe what the shipped
`core-rules/hooks/lib/*.sh` cores actually do. Where they differ, the cores win — the
differences are deliberate and called out inline. The framing convention matches the
receipt-marker note: every core emits **exactly one newline-terminated line of JSON**,
machine-readable and byte-stable; the core never decides block/allow, the **caller**
maps the payload to its own `emit_block` / exit 2.

### Reviewer ladder (`lib/code-reviewer.sh`)

Refines `code-review-subagent`. The realized reviewer is **not** an Agent-tool
dispatch; it is a three-rung ladder that emits one findings line and lets the caller
gate. Resolution order, first that applies wins:

1. **Rung 1 — operator override (`$CODE_REVIEWER_CMD`).** If set and resolvable on
   `PATH` (`command -v`), it is `exec`'d with the untouched stdin on fd 0. That command
   then owns the contract (its own stdout + exit). Unset → fall through.
2. **Rung 2 — LLM review (`claude -p`).** Skipped if `claude` is absent or the
   fork-bomb sentinel is set (see below). The verified invocation is:
   `claude -p --max-turns 1 --output-format text --tools Read --max-budget-usd 0.50 "<prompt>"`
   with the JSON envelope piped on stdin, wrapped in a **perl-alarm portable-timeout
   shim** because GNU `timeout` (and `gtimeout`) is absent on macOS. The embedded prompt
   is byte-identical to `agents/code-reviewer.md`. Output is normalized (jq-strict, with
   a jq-less tolerant fallback) to one compact `{"findings":[…]}` line. Any failure —
   `claude` nonzero, timeout (perl-alarm exit 142), perl missing, parse failure,
   multi-value or unparseable output — falls through to rung 3.
3. **Rung 3 — deterministic regex fallback.** A pure, side-effect-free scan of the raw
   unified diff. Findings carry `file=""`, `line=0`, `confidence=0.9` (a regex scan has
   no reliable file/line). This is the unit-testable core for the bats suite.

**stdin contract:** read once (single-shot), EITHER a JSON envelope
`{diff, autonomy_level, decisions_log}` (jq present and `.diff` non-null → that string is
the diff under review) OR — if not valid JSON, or jq absent — the entire stdin treated
as a raw unified diff. `decisions_log` is populated only at autonomy L4/L5.

**stdout contract:** exactly one line —
`{"findings":[{"severity":"critical|important|minor","file":"path","line":N,"msg":"short","confidence":0.0-1.0}]}`
— or `{"findings":[]}` when nothing is found. `confidence` is **optional / back-compat:
absent is treated as `1.0` by the caller**. Uniform single-`\n` framing across all three
rungs.

**fail-OPEN on infra vs fail-CLOSED on a real finding.** Every infrastructure failure
(no jq, no `claude`, timeout, SIGPIPE, unparseable LLM output) degrades to
`{"findings":[]}` and **exit 0 — never blocks on infra**. Conversely, a successfully
parsed finding with `severity=="critical"` is the one path that makes the **caller**
block (caller exits 2); every other severity is advisory and non-blocking. `critical`
is reserved for **exactly three classes**: (1) a security hole introduced by the diff,
(2) data loss, (3) a broken build. Everything else is `important` or `minor`.

**Fork-bomb sentinel `TRELLIS_REVIEW_IN_PROGRESS`.** Rung 2 spawns a child `claude`
turn, whose own `Stop` hook would otherwise re-fire the reviewer — recursively. The
usual `stop_hook_active` guard does **not** help here: it is `false` in the `claude -p`
child, since that child is a fresh, separate session, not a re-entrant stop. So the
reviewer **exports `TRELLIS_REVIEW_IN_PROGRESS=1` before the `claude` call** and the
Stop-side hook checks it; on entry, if the sentinel is `1`, rung 2 is skipped outright
and the ladder goes straight to rung 3. The sentinel is the only recursion guard on this
path.

### ui-verify decision core (`lib/ui-verify-core.sh`)

Refines `ui-verify`. The realized core **ignores stdin** and decides from git state +
env, not from the hook envelope (reading stdin in a sourced lib would hang). It emits one
line — `{"verdict":"skip|advisory|block|pass","reason":"…","artifacts":["…"]}` — and the
caller maps `verdict=="block"` to its own `emit_block` / exit 2. `artifacts` is `[]`
except on `pass`, where it holds the screenshot path. The core itself always exits 0.

Decision table (first matching row wins):

| Condition | Verdict |
|---|---|
| No UI files changed this turn (presence gate) | `skip` |
| UI changed, but **no** visual tool available (`UI_SHOT_CMD` unset and `npx --no-install playwright` not found) | `advisory` |
| UI changed, visual tool present, but **dev server not reachable** at `http://localhost:$UI_PORT$UI_PATH` | `advisory` |
| UI changed, tool present, server up, but the screenshot command **timed out** (perl-alarm 142) | `advisory` |
| UI changed, tool present, server up, command ran, **non-empty screenshot produced** | `pass` |
| UI changed, tool present, server up, command ran (not a timeout), yet **produced no artifact** | `block` |

The narrow `block` surface is the key refinement over the Tier-2 prose:

- **`block` fires only when a visual tool IS present and the dev server is up, yet the
  capture produced nothing.** "Tool can't be attempted" is never a block.
- **Server-down is `advisory`, not `block`** — an intentional divergence from the old
  `ui-verify.sh`, which blocked on server-down. "Could not attempt verification" fails
  open; only "attempted and got nothing back" gates.
- **There is no "claimed a UI change without running the hook" detection.** Because the
  core decides from git state rather than from a stdin claim, that third block condition
  from the prose above does not exist in the realized core.

**Env knobs:** `UI_REGEX` (UI-extension egrep; default `\.(tsx|jsx|vue|svelte|html|css)$`),
`UI_PORT` (default `3000`), `UI_PATH` (default `/`), `UI_SHOT_CMD` (override screenshot
command, receives `<url> <out>`; also forces tool detection to report `custom`),
`UI_VERIFY_TIMEOUT` (bounded-probe wall-clock seconds; default `20`), and the
`CODEX_PROJECT_DIR` / `CLAUDE_PROJECT_DIR` / `$PWD` project-dir fallback chain.

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

### pre-push (husky on Node projects; native `core-rules/githooks/pre-push` mirror elsewhere)
- **Runs, in order:**
  1. **PR-flow guard** — blocks direct push to `main` or `master` across all Trellis projects. Commits must land on a branch and merge via PR. Emergency override: `TRELLIS_ALLOW_MAIN_PUSH=1 git push` (use rarely; every invocation should be documented in the project's `gotchas.md` or a commit message trailer). The override bypasses only the PR-flow policy, not the merge gate below — `run-all.sh` still runs in merge mode.
  2. **The merge gate** — `process-gate/scripts/run-all.sh --mode=<merge|push>`, derived from the pushed refs: a push targeting `main`/`master` runs `--mode=merge` (full BLOCKED semantics, no downgrade), a WIP feature-branch push runs the lenient `--mode=push`. This single call supersedes the old standalone typecheck+lint+test block (`check-tests.sh` is a strict superset of those). It covers the deterministic gate set: PR-hygiene, secrets, bypass markers, tests, docs, stack profile, security-diff, and analyze. rc 1 → block (exit 1); rc 2 → warn (exit 0); rc 0 → ok.
- **Purpose:** catches anything where `stop-verify` was bypassed (manual commit outside a Claude turn, amended commit, etc.) and enforces Trellis's PR-flow policy + the deterministic merge gate at the git boundary.
- **Block:** PR-flow guard trips, or `run-all.sh --mode=merge` returns a hard failure.
- **Cross-harness reach.** Git hooks are harness-agnostic — they run on both Claude Code and Codex. So this local `pre-push` git hook is the cross-harness merge gate **for the deterministic gate set only** (the eight gates above): it is **fail-closed at push** — but **not un-bypassable**. The only escape is an explicit `--no-verify` / direct-push, itself a logged tripwire caught by the daily `bypass-tripwire` audit (`scheduled-tasks/bypass-tripwire/`), the after-the-fact backstop. There is **no** code-review / ui-verify / receipt gate in `run-all.sh`; those turn-level gates are enforced in-session on both harnesses, not at the git boundary.
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
