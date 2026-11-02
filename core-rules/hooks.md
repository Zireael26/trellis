# Hook specifications

Two tiers: **fast-local** runs on every relevant turn, **heavy-gated** runs on wrap-up. A third tier — **git-boundary portable dispatcher** — catches anything that slipped past the agent. Specs only; native harness surfaces live per project under `.claude/hooks/` and `.codex/hooks/` (pi shares the Codex `.agents` surface). Git-boundary ownership is deliberately local: attachment points `core.hooksPath` at an absolute dispatcher below `$TRELLIS_HOME/state/git-hooks/<checkout-id>/`; `.husky/` never carries Trellis hooks.

The harnesses use different event envelopes, so Trellis keeps two direct script
stacks:

- Claude Code: `core-rules/hooks/*.sh`; the direct-copy manifest is
  `core-rules/templates/claude-settings.json`, while portable inheritance links
  the hook tree and renders `core-rules/templates/claude-settings.local.json` to
  `<project>/.claude/settings.local.json`.
- Codex: `core-rules/codex/hooks/*.sh`; the direct-copy manifest is
  `core-rules/codex/hooks.json`, while portable inheritance links the twin tree
  and renders `core-rules/templates/codex-hooks.local.json` to
  `<project>/.codex/hooks.json`.
- Pi: no separate hook surface; pi agents share the Codex `.agents/agents` tree (`core-rules/pi/agents/`) and run as workflows/subagents.

Any model-backed hook that needs a non-Anthropic model uses pi workflows/subagents via the live role resolver, or skips the model rung and uses the deterministic fallback. It MUST NOT inherit a Claude model default; the canonical shell scripts are implementation assets, not a pi provider selection.

For a hook registered on multiple harnesses, policy intent stays the same.
Claude-specific JSON such as `hookSpecificOutput.permissionDecision` stays in
the Claude implementation. Codex Stop blocks emit
`{"decision":"block","reason":"..."}` and exit 0; Codex PreToolUse and
PostToolUse blocks exit 2 with a non-empty reason on stderr (and only
schema-valid JSON, if any, on stdout). Claude hook semantics are unchanged.

---

## Tier 1 — fast-local (every turn)

Goal: sub-second feedback, zero approval fatigue. If a fast-local hook fails, the active harness surfaces it in the same turn.

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
- **Exit:** Claude exits 0 because PreToolUse decisions ride in the JSON payload. Codex exits 2 for a block with its reason on stderr. Non-blocking paths exit 0.
- **Wrapped commands:** the rules match the command text as written. They deny some `bash -c`, `sh -c` and `eval` forms because the payload is visible in the text; others (a quoted flag, a flag that closes the quote, `$'...'` bodies, stdin-fed `xargs` targets) are known gaps for the argv-parse backlog. `block-destructive.bats` pins both sets.
- **Rule source (also `reread-guard`, `track-read`):** the rules live in `core-rules/hooks/rules/destructive.json`, and the reread warn budget, messages and edit-failure markers in `rules/reread.json`. Patterns stay inside the common subset of POSIX ERE and JavaScript RegExp, so the pi in-process guard reads the same files. `python3 -I scripts/gen-guard-rules.py --write` compiles them into `lib/guard-rules.sh` in both hook trees; `--check` (run by `guard-rules.bats`) fails on drift. The guards match per line with bash builtins in the C locale, so a decision never depends on the host locale, and spawn one `jq` per call. `tests/parity-cases.json` is the shared decision table every guard path runs (`parity.bats`).
- **Stall safety (also `reread-guard`, `skill-preload-guard`):** Claude Code lets a PreToolUse command hook that reaches its registered `timeout` fall through to the normal permission flow, so a stalled guard would be an allow. Every template (rendered and legacy direct-copy) registers each bright-line guard through a POSIX `sh -c` entry with a 30 s timeout. The entry starts `perl core-rules/hooks/lib/guard-supervise.pl` with `PERL5OPT`, `PERL5LIB`, `PERLLIB`, `PERL5DB`, `ENV` and `BASH_ENV` cleared, and emits the harness deny itself when perl or the supervisor is missing or the supervisor ends with anything but its own 10/11/12 status. The supervisor's 20 s budget runs from its own process start; it reads the event itself and gives the guard a spooled copy, owns the guard's stdout and stderr, kills the guard's process group and denies on expiry, and denies an exec failure, a signal, an unexpected exit, an exit with stdout still open, oversized output, and output that is not empty or exactly one valid decision for the harness. A Claude guard's own exit 2 (missing `jq`) becomes a deny document. The pi dispatcher runs its required guards through the same supervisor in `pi` mode. The attach-rendered Claude settings start every hook outside SessionStart in exec form (`/usr/bin/env TRELLIS_ROOT=… <script>`, no user shell) and, on Claude Code 2.1.295 or later, add `onFailure: "block"` to the three guards, so a guard that cannot start, times out, or exits with anything but 0 or 2 is also a block at the client. Below 2.1.295, or when attach cannot read `claude --version` (found on the caller PATH first, and run with it), every hook outside SessionStart keeps its previous shell-form registration byte for byte, guards included, and the supervisor alone fails closed, as before. The advisory `pr-gate-shiftleft` runs only on Bash commands that mention `gh` (`if: "Bash(*gh*)"`, 10 s) and stays synchronous. Outside the guarantee: the client's spawn and the `sh` entry before perl starts, and a client environment that already controls `PATH`. `trellis doctor` reports a missing perl as an ERROR, and a guard registration without the supervisor, below 30 s, or (rendered Claude settings on Claude Code 2.1.295+) without `onFailure: "block"` as a WARN; it also warns when Claude Code is below 2.1.295. `release adopt` does not rewrite rendered settings, so a project keeps its old 5 s, unsupervised registrations, which are not stall-safe, until detach + attach re-renders them. A legacy direct-copy install must copy `lib/guard-supervise.pl` beside its hooks; without it every guarded call is denied.
- **Client backstop:** the rendered `.claude/settings.local.json` carries `permissions.deny` rules for the plain `rm -rf`/`rm -fr` absolute, `~`, `$HOME` and `..` forms, force pushes and the `git reset --hard` forms above. Deny rules hold in every permission mode, but they don't match inside `bash -c` or `eval`. Attach refuses to render over a project whose existing `.claude/settings.local.json` already owns a `permissions.deny` value (`scripts/attach-project.sh`, owned-leaf overlap); move those rules aside or merge them by hand first. Whether the client matches the literal `$HOME` and `~` rules is not yet probed at runtime (owner item).

### pr-gate-shiftleft
- **Event:** `PreToolUse` on `Bash`, immediately after `block-destructive` in the Claude and Codex manifests.
- **Trigger:** an executable shell command contains `gh pr create`; prose, `echo gh pr create`, other `gh pr` subcommands, and malformed/non-Bash envelopes exit silently.
- **Runs:** nothing beyond recording. It never runs process-gate; the pre-push gate is the authoritative local check. On a literal `--base`, it writes `branch.<head>.trellisPrBase` on the resolved PR head branch, the base cache `diff-base.sh` reads. Head resolution uses only literal flags (`--head`/`-H` included), a leading `cd`, `git -C`, and `--repo` matching origin.
- **Return:** on a recorded base, one stderr line: `pr-gate-shiftleft: recorded PR base <base>; the full process gate runs at push`. An unresolvable PR head emits advisory `hookSpecificOutput.additionalContext`. Both twins; neither ever produces a deny/block decision.
- **Exit:** 0 on every triggered outcome; CI and branch protection remain authoritative.

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
- **Exit:** 2 on block (Codex writes the reason to stderr), 0 otherwise. JSON decision takes precedence when present.
- **Invariant:** must complete in <3s for a single-file edit. Anything slower belongs in tier 2.

### slop-tripwire
- **Event:** `PostToolUse` on `Edit`, `Write`, `MultiEdit`
- **Scope:** the touched file's **added lines only** — `git diff HEAD` at `-U0` for a tracked file, the whole file when it is untracked (every line of a new file is an added line). One file's diff, never the repo. Extension filter `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.go`, `.rs`; other extensions and carved-out paths (test, generated, fixture, migration, vendored, lockfile globs) exit silently. Carve-outs match the **repo-relative** path, so a directory name above the work-tree root cannot silence a whole checkout.
- **Patterns:** never inlined here — the pattern set and the carve-out globs come from `hooks/lib/slop-patterns.sh`, the single source shared with the anti-slop skill's `audit-slop.sh` and the process-gate `check-slop` row, so a tuned pattern lands in all three at once.
- **Triggers:** an added line matches an evidence-doctrine pattern for its language (`as any`, `: Any` on a `def`, `interface{}` in a signature, `.unwrap()`, an unjustified `cast(`, a module-level mock) and carries no suppression — a `SAFETY:` comment or the language's own idiom — on that line or the added line before it.
- **Return:** `{ "additionalContext": "slop-tripwire: <pattern> at <file>:<line> — evidence doctrine: core-rules/references/anti-slop.md" }`, one line per finding, capped at 5 with a `(+N more)` count when it caps.
- **Exit:** 0 on every detection path — advisory only, never blocks, at any `gate_profiles.anti_slop.posture`; blocking on slop lives in the gate row alone. The shared jq check (`lib/deps.sh`) is the one non-zero exit, as in every other hook. A missing sibling lib is a **silent** exit 0, not the loud exit 1 the blocking hooks use: an unsynced `hooks/lib` would otherwise print a re-run-sync-hooks line on every edit of every file type. Absence surfaces where it is actionable instead — doctor's anti-slop presence row.
- **Escape:** `SLOP_TRIPWIRE=off` short-circuits before anything else, jq included.
- **Invariant:** O(diff of one file) — no repo walk, no linter, no network.

### wiki-skill-suggest
- **Event:** `PostToolUse` on `Write`, `Edit`, and `MultiEdit`, registered only by the attach-rendered local hook templates. The Claude implementation is `core-rules/hooks/wiki-skill-suggest.sh`; the Codex twin is `core-rules/codex/hooks/wiki-skill-suggest.sh`.
- **Input:** one `PostToolUse` JSON envelope. The hook accepts the edited path from either `.tool_input.file_path` or `.tool_input.filePath`.
- **Scope:** canonical-root-only. It resolves the common repository root with `_se_repo_root` (backed by `git rev-parse --git-common-dir`), resolves relative supplied paths from the event's project directory, and triggers only when that path is the common root's regular `gotchas.md` file (filesystem identity, not merely a matching basename). Nested or linked-worktree `gotchas.md` files, basename-only paths, malformed envelopes, invalid or missing project roots, missing `jq`, and missing Git are silent no-ops.
- **Trigger:** an edit to the canonical root `gotchas.md`.
- **Claude return:** exactly one advisory line, with no blocking decision:
  `{"additionalContext":"wiki-skill-suggest: project-root gotchas.md changed; consider running wiki-maintain explicitly for any qualifying procedure."}`
- **Codex return:** the same message in the event-specific envelope:
  `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"wiki-skill-suggest: project-root gotchas.md changed; consider running wiki-maintain explicitly for any qualifying procedure."}}`
- **Exit:** always `0`, including malformed input and every unavailable-dependency or path-resolution failure. The suggestion is advisory and nonblocking; it never invokes `wiki-maintain`, another skill, GitHub, or a promotion/landing path.
- **Runtime boundary:** the hook performs only read-only Git metadata and filesystem-identity checks. It does not read or write `wiki/index.md`, `wiki/patterns/`, `wiki/skill-impact.md`, or any other wiki content, and it does not write `gotchas.md`.
- **Registration boundary:** the local templates use the `Write|Edit|MultiEdit` matcher and a five-second timeout. There is no legacy direct-copy, `SessionStart`, or `Stop` registration beyond Claude Code and Codex.

The wiki remains on demand: a session may explicitly read `wiki/index.md` and linked
pattern pages, but no hook injects wiki content. The existing `session-context`
hooks continue to inject unresolved entries from the canonical-root `gotchas.md`
at `SessionStart` exactly as before; this advisory hook does not alter that
injection or register on `SessionStart`.

### truncation-check
- **Event:** none — unregistered in every manifest since 1.3.12 (E-15); the script remains on disk. Was `PostToolUse` on `Grep`, `Bash`, `Read`
- **Triggers:** tool result length ≥ 100,000 chars OR output ends with a `...truncated...` marker
- **Return:** `{ "additionalContext": "Result was truncated. Re-run with narrower scope or read the source file directly." }`
- **Exit:** never blocks — advisory only

### skill-size-preflight
- **Event:** none — retired from Claude Code `SessionStart` in 1.3.12 (E-15): no manifest or template registers it, and the launcher's Claude Code `SessionStart` routes are now `session-start`, `session-context`, `post-compact-context` and `inject-primer-index` only. The script remains on disk. Was `SessionStart` (`startup`/`resume`), Claude Code only.
- **Did:** scanned the discoverable Skill roots for manifests over the 65,536-byte budget and for ambiguous names, and returned an advisory.
- **Enforcement now:** at use, `skill-preload-guard` still denies an oversized or ambiguous Skill and `skill-slash-guard` an oversized one. The pi dispatcher reports this check as unsupported (`docs/pi-dispatch-parity.md`).
- **Exit:** never blocked — advisory only

### session-start
- **Event:** `SessionStart`, the one registered command (spec 072 U4). Attached projects reach it through the stable launcher's `hook session-start` route under `env -i` with the attach-time `HOME` and `TRELLIS_HOME`, so it runs from the verified payload; the project's `.trellis/runtime` anchor is diagnosed, never executed, at session start.
- **Dispatch:** reads the event once and runs `session-context` then `inject-primer-index` for `startup`/`resume` (or no source), `post-compact-context` for `compact`, nothing for `clear`. Each hook gets the same event and pinned Git configuration (no system or global config, no fsmonitor, no hooks path).
- **Return:** one `additionalContext` joining the hooks' contexts with a blank line; a hook that fails or prints a malformed envelope is named in a one-line notice in its place, and the others keep their context
- **Exit:** never blocks

### session-context
- **Event:** `SessionStart` (source: `startup` or `resume`), through `session-start`
- **Release integrity (linked worktrees):** the post-attach job's `ok` verdict for the live owner record, else the release stamp, else the full release verify (which stamps), else a warning that integrity could not be confirmed. Never silent.
- **Injects:** current git branch, last 5 commits on the branch, dirty-file count, any `context-log.md` from the last session, any outstanding `gotchas.md` entries tagged unresolved
- **Path resolution:** `context-log.md` and `gotchas.md` are read from the **canonical project root** (resolved via `git rev-parse --git-common-dir`), so worktree sessions still see the repo-level files instead of looking only inside the worktree.
- **Return:** `{ "additionalContext": "<assembled header, <2K chars>" }`
- **Exit:** never blocks

### save-context-log
- **Event:** Claude Code `PreCompact`; Codex `Stop`
- **Writes:** `context-log.md` at the **canonical project root** (resolved via `git rev-parse --git-common-dir`) with — current branch, files touched this session, open todos, last two user asks, last two assistant decisions
- **Worktree behavior:** the log is written to the main checkout regardless of which worktree the session ran in, so worktree cleanup does not destroy the log. Cross-worktree clobbering on the same canonical root is a known limitation pending the per-branch follow-up; same-branch sessions are unaffected.
- **Return:** no stdout needed; file write is the side effect
- **Codex Stop (spec 072 U8):** skips the rewrite when the transcript and `context-log.md` are exactly as its last write left them (stat recorded under `<TRELLIS_HOME or ~/.trellis>/state/context-log/`); a missing transcript, record or stat always writes.
- **Exit:** never blocks

### post-compact-context
- **Event:** `SessionStart` (source: `compact` when provided), through `session-start`
- **Injects:** contents of `context-log.md` if present, read from the **canonical project root** (resolved via `git rev-parse --git-common-dir`)
- **Return:** `{ "additionalContext": "<contents of context-log.md>" }`
- **Exit:** never blocks

---

## Tier 2 — heavy-gated (wrap-up)

Goal: catch "claims done but isn't" before the turn ends. Runs exactly once per stop event, guarded against infinite loops.

### decision-receipt
- **Event:** `Stop`, after `spec-gate` and before `stop-verify` / review. Codex preserves its existing `save-context-log` call between `spec-gate` and this boundary; any model-backed step that needs a non-Anthropic model uses pi workflows/subagents via the live role resolver, otherwise the deterministic wrapper is used.
- **Guard:** if `$stop_hook_active == true`, exit 0 immediately. Resolve the effective, post-ceiling autonomy level through `lib/autonomy.sh`; L1-L3 exit 0 without parsing.
- **Substantive turn:** validate when the project worktree is dirty or the current turn contains a filled canonical DoD receipt marker. A clean read-only turn exits 0.
- **Required block:** exactly one `## Decisions made (L<n>)` block for the effective level. Every non-empty line in that block must be a canonical decision entry copied verbatim into `<canonical-root>/decisions-log.md`.
- **Entry validation:** current UTC date, valid `HH:MM:SSZ`, effective `[L<n>]`, one of `interpretation` / `pattern` / `scope` / `architectural`, and filled decision, `Reasoning:`, and `Alternatives considered:` clauses. Architectural entries alone end in ` SURFACED INLINE`.
- **Forward-only invariant:** reads the current assistant message or current-turn transcript and the canonical log; never appends, rewrites, normalizes, rotates, or validates legacy log entries.
- **Return on block:** `{"decision":"block","reason":"decision-receipt: ..."}`; Claude exits 2, Codex exits 0. Passes are silent with exit 0.
- **Budget:** 15s.

### stop-verify
- **Event:** `Stop`
- **Guard:** if `$stop_hook_active == true`, exit 0 immediately. Also exit 0 if no file edits occurred this turn (pure chat / read-only).
- **Runs, in order:**
  1. **TodoWrite check** — if any task is `in_progress` or `pending`, block. Claude must complete, defer with reason, or abandon with reason. This is the receipts-required enforcement point.
  2. **Typecheck** — auto-detected: `tsc --noEmit` if `tsconfig.json` (run as the nearest `node_modules/.bin/tsc` up to the worktree root, the copy `npx --no-install` resolves, with the same argv and without npx's startup; with none inside the worktree it stays `npx --no-install tsc --noEmit` and that Stop is never reused; eslint is planned the same way), `mypy .` if configured in `pyproject.toml`/`mypy.ini`, `cargo check` if `Cargo.toml`, `go vet ./...` if `go.mod`. Full repo.
  3. **Lint** — same detection as `post-edit-verify` but run repo-wide: eslint, ruff, clippy, golangci-lint.
  4. **Test** — auto-detected fast suite: `npm test` (if `test` script), `pytest` (if installed), `cargo test`, `go test ./...`. Skip e2e/integration unless explicitly configured. **Optional host setting:** `projects.<root>.stop_checks.fast` in `<TRELLIS_HOME or ~/.trellis>/config.json` (a one-line command, 1–1024 printable characters) replaces this step with a faster suite, run from the project root. `<root>` is the physical path of the project's main checkout, so linked worktrees share it. It is honoured only when `config.json` is a regular file owned by the hook's effective uid (perl `$>`, not the inheritable `$EUID`) with mode 0600 or stricter, in a directory with no group or other write bit; otherwise, or when the value is malformed, the detected suite runs and the advisory says why. Nothing in the checkout can set it: `.trellis.json`, the working tree, base refs and reflogs are all writable by a same-user agent, so a repo-side `stop_checks` is ignored. Typecheck and lint still run. A fast run is never reused and never writes a pass receipt; the advisory names the command, and a failure blocks as `test (stop_checks.fast: <cmd>)`. The pre-push and merge gates never read it. `trellis doctor` reports each project with a fast suite (INFO) and a value the hook would ignore (WARN).
- **Concurrency (spec 072 U8):** steps 2–4 are planned first and then run concurrently, cargo's checks in order because they share a build lock. The first failure in the order above blocks, with the same reason and slicing as a sequential run; checks still running at that point are signalled with their descendants and reaped, so none outlives the hook.
- **Pass reuse (spec 072 U8):** a later Stop skips steps 2–4 when a pass receipt in `<TRELLIS_HOME or ~/.trellis>/state/stop-receipts/<worktree hash>.<harness>` (directory 0700, file 0600) matches the reuse key exactly. The key binds: the tree fingerprint (HEAD, index, tracked and untracked content, as for C01); each planned command and its directory; the closure of every planned program; the whole exported environment, harness and agent variables (`CLAUDE_CODE_*`, `CODEX_*`, `HC_*`, `SSH_AUTH_SOCK`, …) included, since any check may read any variable — only `PWD`, `OLDPWD` and `_` are left out, because each check's `cd` and exec overwrite them from directories and commands already in the key (so a new harness session reruns once); every git-ignored input, walked recursively by lstat identity (`git status --ignored=matching` lists them, so `.env`, generated code, `node_modules` and `.venv` count at any depth); `.trellis.json`; and the hook files. Every planned program, and the interpreter named by a `#!` program, must be physically inside the worktree (`node_modules/.bin`, `.venv`, both covered above), a native Mach-O/ELF binary recognised by its magic number, or `npm`/`pnpm` with its whole installation bound: the nearest ancestor of the script's real path holding a `package.json` named for it (`npm`; `pnpm` or `corepack`) is walked entry by entry (lstat identity, at most 20000 entries, no symlink leaving it), and for corepack's `pnpm` shim so is the corepack home it dispatches into (`COREPACK_HOME`, else `<XDG_CACHE_HOME or ~/.cache>/node/corepack`); a missing root or home, an oversized tree or an escaping link means no reuse. An `npm`/`pnpm` check reuses only for `run <script>`, `run-script <script>` or `test`: every program its `pre`/main/`post` scripts start (through nested `npm`/`pnpm run`, up to four deep) must pass the same rule as resolved by npm (`node_modules/.bin` of the package and its ancestors, then `PATH`), as must `sh`. Admission is an allowlist grammar, and anything outside it just runs with no reuse: a script is simple commands joined only by `&&` (no other operator, quote, `$`, backquote, backslash, brace, parenthesis, redirection, `#` or newline); every word matches `^[A-Za-z0-9_@%+=:,./-]+$` (no `~` or glob) and never holds `://`; no leading `VAR=value`; the program is `true`, `false` or `:`, an `npm`/`pnpm` run as above (no flag after the script name except past `--`), or something that resolves the npm way and passes the closure rule — never `npx`/`pnpx`/`bunx`/`dlx` (as any word), `yarn`, `corepack`, `bun`, `deno`, a wrapper (`env`, `nice`, `nohup`, `time`, `xargs`, `command`, `exec`, `timeout`, `gtimeout`, `stdbuf`, `sudo`, `doas`) or the builtins `cd`, `export`, `set`, `source`, `.`, `eval`, `unset`; node, python, perl, ruby and the shells (sh, bash, zsh, dash, ksh, mksh, yash, ash, fish, csh, tcsh, busybox) take only allowlisted options before their first operand, value-taking ones only attached (`-Wignore`, never `-W ignore`), and refuse a flag cluster with `c` or `e` anywhere (python also any `-…[cmEI]` word); for every program, known or not, `-c`, `-e`, `-r`, `-p`, `--eval`, `--print`, `--require`, `--import`, `--loader`, `--experimental-loader` or `--input-type` anywhere refuses (a legitimate tool flag of that spelling, such as `tsc -p`, only costs a full run); and every word, plus the value of `--flag=value` or `-Xvalue`, that holds a `/` is a relative path with no `..` segment landing inside the worktree (outside `.git/`), existing or not, or an absolute path admitted as native (identity bound) or a release payload (realpath and release identity bound), while any word naming an existing entry must land inside the worktree. `npm_config_*`, `NODE_OPTIONS` and similar settings in the environment are covered by the environment binding above; and every config file the managers read is bound by content or as absent — `.npmrc`, `pnpm-workspace.yaml` and `.pnpmfile.cjs` in the check directory and every ancestor, the user and global npmrc (including `<node prefix>/etc/npmrc`), and pnpm's `rc`/`config.yaml` under `XDG_CONFIG_HOME` and `~/Library/Preferences` — with any of them setting a key that moves config or code elsewhere (`pnpmfile`, `globalconfig`, `userconfig`, `prefix`, `script-shell`, `node-options`, `use-node-version`, …) refusing reuse. A shell-form check with an operator, expansion or redirection, or any word that is `npx`, `pnpx`, `bunx`, `dlx`, `yarn`, `corepack`, `bun` or `deno`, refuses; `exec`, `dlx`, `x`, `create` and any other subcommand refuse. A worktree script that execs a bare program (pnpm's `node_modules/.bin` wrappers end in `exec node …`) or starts a line with a bare interpreter has each one resolved on `PATH`; it must be native or in the worktree and its identity is bound (or its absence), so replacing `node` in place reruns. `cargo` adds `cargo`/`rustc`/`clippy` versions and `go` adds `go version`. Anything else outside the worktree — `npx`, `yarn`, a global console script, a version-manager shim, executable text without `#!` — runs code the key cannot see, so that Stop never reuses. Nothing is skipped by name: caches (`__pycache__`, `.mypy_cache`, `.ruff_cache`) are bound like any input, so a run that rewrites them earns no receipt until they settle; `.pytest_cache`, which `--lf` reads and pytest rewrites with the same bytes every run, is bound by content; vitest's `.vite/vitest/<hash>/results.json`, rewritten with fresh durations every run, is bound by its version, sorted file list and each file's `failed` flag (durations only order files), and any other shape refuses reuse. An ignored symlink is bound by its text and the physical path its whole chain resolves to, which must be inside the worktree (not `.git/`), inside one release payload (`<TRELLIS_HOME>/releases/<version>/payload`, where `.trellis/runtime` points and the hooks themselves run from; this binds the realpath, the version and the sha256 of that release's `release.json`, and anything else under TRELLIS_HOME or a release with no `release.json` is refused), or a native binary such as a `.venv`'s python, whose identity is then bound. A dangling link, any other target, an unreadable entry, or more than 300000 ignored entries means no reuse. A receipt is written only when every check exits 0 and the full key reads the same after the run as before it, so nothing a check or another process changed mid-run is ever certified; failures are never recorded. A reuse is never silent: it adds "checks reused, not re-run" with the receipt to the advisory. A receipt with the wrong owner, group/other bits, a symlink, extra links or another key is a miss. Same-user forgery is the accepted residual: that user can already edit the hook, and the merge gate never reads a receipt. The spec 045 executed-verification receipts are unchanged: they record each execution and are never a cache, and a reused Stop records none.
- **Canonical receipt marker:** the single machine-readable anchor the receipts check reads and the `execute` skill emits is `<!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->`, byte-identical to its definition in `core-rules/CLAUDE.md`. Fields map 1:1 to that prose — `cmd`→verification command, `exit`→exit code, `diff`→diff lines that prove the change.
- **Where the receipt is read:** the final message text the Stop envelope carries as `last_assistant_message`, plus the transcript after its last user-role line. Claude Code can fire Stop before the final message reaches the transcript file, so the envelope text is read first. Only when both are missing does the check fall back to an advisory pass. Only text the user saw counts: a non-string envelope value is ignored, and from the transcript only assistant text blocks are read, never thinking, tool input or tool output.
- **Follow-ups marker (spec 012):** alongside the receipt the agent emits `<!-- follow-ups: <count> -->` or `<!-- follow-ups: none -->` (detection ERE: `<!-- follow-ups: (none|[0-9]+) -->`, filled values only — the unfilled template never matches). A receipt WITHOUT this marker triggers a non-blocking advisory warn (additionalContext / system message), never a block: explicit `none` passes clean, and warn-stays-warn is a design invariant (spec 012 D4).
- **Block condition:** any step fails OR todos are open
- **Receipt trigger (C01):** the receipts check runs only when this turn mutated the tree. `turn-baseline.sh` (`UserPromptSubmit`, Claude and Codex; pi has no completion gate) appends a fingerprint of HEAD, the index, and the content of every changed or untracked non-ignored path to `<TRELLIS_HOME or ~/.trellis>/state/turn-baseline/<worktree hash>/<harness>.<session key>` (mode 0600), with a random nonce also logged to `nonces.log` beside it. The fingerprint is incremental: `fp-cache` beside the baseline (0600) keeps each dirty file's blob id under its lstat identity (device, inode, mode, size, mtime, ctime), so only files that changed since the last fingerprint are re-read; an entry is cached only once its mtime and ctime are over two seconds old, and the resulting hash is the same as an uncached one. `stop-verify` consumes the baseline at Stop and, when the evaluation passes (exit 0 with no block, advisory included), writes the end state back as a carry line (fresh nonce, same file). A blocked Stop writes no carry, so the next Stop finds no baseline and still demands the receipt. A turn that starts without a prompt, such as a background-task notification, compares against that carry; a prompt line takes precedence over the carry when both are present. If the tree still matches every line in force, no receipt is demanded. A changed tree, a commit that left the tree clean, or a missing, malformed, unlogged-nonce or uncomputable baseline all demand the receipt. That includes a skipped prompt hook, a submodule or nested repo, and the first turn with neither a prompt baseline nor a carry. The "unknown" demand applies on every path, clean tree included, once the project's settings register `turn-baseline.sh`; before the re-render that registers it, `stop-verify` behaves as before (receipt on a dirty non-doc tree). Todos and typecheck/lint/test are not narrowed. Requires Claude Code ≥ 2.1.294 and Codex ≥ 0.116.0. Nothing checks the Codex floor yet; `trellis doctor`'s Claude Code version row (B0-5) warns below the Claude Code floor.
- **Residual (accepted, C01):** the baseline and nonce log are ordinary files owned by the agent's own user. An agent that deliberately rewrites both with the current fingerprint can suppress the receipt demand on a turn that changed code. The 0600 mode, the out-of-worktree location and the nonce stop accidental or lazy tampering only. This is the same trust level as the self-attested receipt marker itself: the demand is a nudge, and real verification stays in the pre-push and merge gates. A turn that edits and then exactly reverts to the entry state also reads as unchanged, because the check compares end states.
- **Residual (accepted, C01): un-arming.** A project counts as armed only while its settings register `turn-baseline.sh`, and `.claude/settings.local.json` is git-ignored. An agent can remove that registration without dirtying the tree. The project then behaves exactly as it did before C01: a dirty non-doc tree still demands the receipt, and a turn that committed its code and left the tree clean, with no baseline, passes, as it always has. Re-attaching re-renders the registration. Same trust level as the residual above.
- **Error slicing on failure:**
  - Typecheck / lint output → **first 30 lines** (compile errors are at the top; the rest is cascade noise)
  - Test output → **last 30 lines** (assertion messages and stack traces land at the bottom)
- **Return on block:** `{ "decision": "block", "reason": "<step name>: <sliced output>" }`
- **Return on pass:** exit 0, no output (an advisory when checks were reused or unavailable)
- **Budget:** 90s soft cap. If typecheck+lint+test exceeds this, split — move tests to CI-only and document in project `hooks.md`.
- **Subtree scoping:** if every changed file in the turn sits under one subdirectory that carries its own manifest (`package.json`, `go.mod`, `pyproject.toml`, or `Cargo.toml`), the hook `cd`s into that subtree before steps 2-4. Cuts wall time + noise on monorepos. Mixed-subtree changes fall back to repo root. Escape hatch: `PROCESS_GATE_FORCE_ROOT=1` always runs at root.

### code-review-subagent
- **Event:** `Stop`
- **Guard:** `$stop_hook_active` check, then runs only on **edit-heavy turns** (definition: ≥3 files touched OR ≥200 lines added/changed; project may override). Skipped on pure doc edits.
- **Mechanism:** Claude Code and Codex use the canonical review gate; pi workflows/subagents handle the same gate via the live non-Anthropic reviewer route. The reviewer has read-only access to the current turn's diff and returns structured findings.
- **Reviewer interface (pluggable):**
  - v1: single fresh reviewer — checks correctness, obvious bugs, security red flags, matches project patterns
  - v2 (future): parallel multi-angle reviewers — security, performance, API-design, test-coverage, docs — results merged. Interface reserved; don't wire it until v1 proves useful.
- **Return:** findings appended to response as a collapsible `<review>` block. Findings are **advisory**; the active harness must either resolve or explicitly acknowledge-and-defer each one in the same turn.
- **Block condition:** only if the subagent returns `decision: "block"` for a severity-critical finding (security hole, data loss, broken build path). Advisory findings don't block.
- **Budget:** 60s soft cap. If over, the hook logs a warning but does not block.
- **Delta review and bounded retry (spec 072 U8):** a completed review records the tree it covered in `<TRELLIS_HOME or ~/.trellis>/state/code-review/<worktree hash>/reviewed.<harness>`; the next review is sent only the change from that tree, when the recorded HEAD is an ancestor of HEAD and both trees are readable (otherwise the full diff, as before). A review that fails (reviewer error, malformed or degraded envelope, over-cap prefix) writes no marker and no tree and is retried on each Stop at most 3 times per exact diff; after that every Stop reports the diff as UNREVIEWED (additionalContext / system message) until it changes. A failure never reads as reviewed. `.review-done-*` markers and failure counts older than 7 days are swept after a completed review.
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

### propose-rules (opt-out; unregistered)
- **Event:** none — unregistered in the canonical Claude and Codex manifests since 1.3.12 (E-15); the script remains on disk. Was `Stop`.
- **Status:** not registered since 1.3.12. The Claude-only model-backed proposal path is not used from pi; any pi equivalent uses pi workflows/subagents via the live role resolver. Projects opt out by setting `PROCESS_GATE_PROPOSE_RULES=0` in `.claude/hooks/config.sh` and/or `.codex/hooks/config.sh`. Script copies are canonical and synced via `sync-hooks.sh` / `sync-codex-hooks.sh`.
- **Guard:** opt-out gate first (silent exit when set to 0), then `$stop_hook_active`, then dirty-tree skip (pure chat → exit), then a cheap heuristic on the transcript tail looking for explicit-correction signals ("no", "don't", "actually", "stop doing", "that's wrong", "never do"). The subagent only fires when at least one signal is present in the last ~200 transcript lines.
- **Mechanism:** dispatches a one-shot Claude-family subagent only from Claude Code or Codex; it reads the transcript tail + the project's `gotchas.md` and proposes ONE candidate gotchas entry, or emits the literal string `NONE`. The proposal is returned as `additionalContext`; this hook never blocks.
- **L5 persistence and screening:** candidates are screened before emission or persistence. High-confidence token fingerprints remain blocked, as do nonempty quoted and unquoted assignments to password, passwd, secret, API-key, token, and access-key names. At effective L5 only, the hook stages canonical-root `gotchas.md` and its `[L5]` `decisions-log.md` receipt as temporary siblings, then commits them with per-file atomic renames; L1–L4 remain advisory-only.
- **Rollback:** if the decisions-log rename fails after the gotchas rename, the hook restores the prior gotchas file. The backup is removed only after a successful restore or a successful two-file transaction. If restoration fails, the intact backup remains in place and the advisory output gives its recovery path; restore canonical `gotchas.md` from that path before retrying.
- **Budget:** 30s soft cap for the harness-owned proposal command.
- **Cost bound:** every fire costs tokens, so the default-on hook is bounded by both edit-heavy and correction-signal gates. Projects that never want rule proposals set `PROCESS_GATE_PROPOSE_RULES=0`.
- **Pairs with:** `gotchas-rollup` (monthly) — propose-rules surfaces n=1 candidates per turn; gotchas-rollup clusters n≥3 candidates into parent-rule promotions.

### primer-capture-nudge
- **Event:** none — unregistered in the Claude and Codex manifests since 1.3.12 (E-15); the script remains on disk. Was `Stop`, after `propose-rules` and before `ui-verify`.
- **Guard:** `stop_hook_active`, malformed input, missing git, missing `.claude/primers/INDEX.md`, a clean tree, a non-edit-heavy turn, or a documentation-only change exits silently. Edit-heavy uses the reviewer thresholds: at least 3 changed files or 200 added/deleted lines, with `REVIEW_MIN_FILES` / `REVIEW_MIN_LINES` overrides.
- **Coverage:** considers tracked and untracked project paths while excluding `.claude/` / `.codex/` state. An INDEX slug or one of the primer's `## Entry points` suppresses the nudge; otherwise the hook derives a stable subsystem slug.
- **Return:** advisory context asking for `/primer <slug>` (Claude `additionalContext`, Codex `systemMessage`), capped to the first five unknown subsystems.
- **Exit:** 0; the hook is read-only and never blocks or writes a primer.

---

## Realized cores — reviewer ladder & ui-verify decision core

This section is the **authoritative implementation interface** for the two Tier-2
gates above. It refines the `code-review-subagent` and `ui-verify` specs: where the
prose above describes intent, the contracts here describe what the shipped
`core-rules/hooks/lib/*.sh` cores actually do. Where they differ, the cores win — the
differences are deliberate and called out inline. The framing convention matches the
receipt-marker note: every core emits **exactly one newline-terminated line of JSON**,
machine-readable and byte-stable; the core never decides block/allow. The **caller**
maps the payload to its own `emit_block`: Claude Stop exits 2, Codex Stop exits 0.

### Reviewer ladder (`lib/code-reviewer.sh`)

Refines `code-review-subagent`. The realized reviewer is **not** an Agent-tool
dispatch; it is a three-rung ladder that emits one findings line and lets the caller
gate. Resolution order, first that applies wins:

1. **Rung 1 — operator or pi resolver override (`$CODE_REVIEWER_CMD`).** If set
   and resolvable on `PATH` (`command -v`), it is `exec`'d with the untouched
   stdin on fd 0. That command then owns the contract (its own stdout + exit).
   Pi workflows supply the live non-Anthropic reviewer command here via the role resolver when needed;
   unset on Claude Code/Codex → fall through, while unset on pi → skip the
   model rung and use rung 3.
2. **Rung 2 — Claude Code/Codex LLM review (`claude -p`).** This rung is
   available only to those harnesses and is skipped if `claude` is absent or
   the fork-bomb sentinel is set (see below). Pi MUST NOT enter it; pi review uses rung 1 via workflows/subagents. The
   verified invocation is:
   `claude -p --max-turns 1 --output-format text --tools Read --max-budget-usd 0.50 "<prompt>"`
   with the JSON envelope piped on stdin, wrapped in a **perl-alarm
   portable-timeout shim** because GNU `timeout` (and `gtimeout`) is absent on
   macOS. The embedded prompt is byte-identical to
   `agents/code-reviewer.md`. Output is normalized (jq-strict, with a jq-less
   tolerant fallback) to one compact `{"findings":[…]}` line. Any failure —
   `claude` nonzero, timeout (perl-alarm exit 142), perl missing, parse failure,
   multi-value or unparseable output — falls through to rung 3.
3. **Rung 3 — deterministic regex fallback.** A pure, side-effect-free scan of
   the raw unified diff. Findings carry `file=""`, `line=0`, `confidence=0.9`
   (a regex scan has no reliable file/line). This is the unit-testable core for
   the bats suite.

**stdin contract:** read once (single-shot), EITHER a JSON envelope
`{diff, autonomy_level, decisions_log}` (jq present and `.diff` non-null → that string is
the diff under review) OR — if not valid JSON, or jq absent — the entire stdin treated
as a raw unified diff. `decisions_log` is populated only at autonomy L4/L5.

**stdout contract:** exactly one line —
`{"findings":[{"severity":"critical|important|minor","file":"path","line":N,"msg":"short","confidence":0.0-1.0}]}`
— or `{"findings":[]}` when nothing is found. `confidence` is **optional / back-compat:
absent is treated as `1.0` by the caller**. Uniform single-`\n` framing across all three
rungs. Built-in LLM success carries `"status":"completed"`; any rung-2 route that fails
or is unavailable (pi absent or failing inside an hc terminal, claude absent or failing outside)
carries `"status":"degraded"` with the deterministic fallback findings. A missing status
counts as completed only for a rung-1 operator override (legacy); otherwise the caller
treats it as incomplete and mints no review marker. Only the recursion-guarded nested run
emits a bare envelope, and the Stop hooks exit on that sentinel before invoking the ladder.

**fail-OPEN on infra vs fail-CLOSED on a real finding.** Every infrastructure failure
(no jq, no eligible reviewer command, timeout, SIGPIPE, unparseable LLM output)
degrades to `{"status":"degraded","findings":[]}` and **exit 0 — never blocks on infra**. Conversely, a
successfully parsed finding with `severity=="critical"` is the one path that makes the
**caller** block (Claude Stop exits 2; Codex Stop exits 0 with block JSON); every other severity is advisory and non-blocking.
`critical` is reserved for **exactly three classes**: (1) a security hole introduced
by the diff, (2) data loss, (3) a broken build. Everything else is `important` or
`minor`.

**Fork-bomb sentinel `TRELLIS_REVIEW_IN_PROGRESS`.** The Claude-only rung 2
spawns a child `claude` turn, whose own Stop hook would otherwise re-fire the
reviewer — recursively. The usual `stop_hook_active` guard does **not** help
here: it is `false` in the `claude -p` child, since that child is a fresh,
separate session, not a re-entrant stop. So the reviewer **exports
`TRELLIS_REVIEW_IN_PROGRESS=1` before the `claude` call** and the Stop-side hook
checks it; on entry, if the sentinel is `1`, rung 2 is skipped outright and the
ladder goes straight to rung 3. The sentinel is the only recursion guard on this
Claude-only path.

### ui-verify decision core (`lib/ui-verify-core.sh`)

Refines `ui-verify`. The realized core **ignores stdin** and decides from git state +
env, not from the hook envelope (reading stdin in a sourced lib would hang). It emits one
line — `{"verdict":"skip|advisory|block|pass","reason":"…","artifacts":["…"]}` — and the
caller maps `verdict=="block"` to its own `emit_block` (Claude Stop exits 2;
Codex Stop exits 0 with block JSON). `artifacts` is `[]`
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

## Tier 3 — git-boundary (portable clone-local dispatcher)

Goal: last-line defense. If a tier-1 or tier-2 hook misfired, the local git commit/push still catches it. Never the primary gate — Claude should not rely on these running. Ownership, chaining, and recovery follow `core-rules/inheritance.md` §7; this section does not establish a competing install shape.

### Hook authority and drift
- **One owner:** attachment records the prior local `core.hooksPath` and sets the clone's active path to its absolute dispatcher below `$TRELLIS_HOME/state/git-hooks/<checkout-id>/`. The dispatcher is local clone state, not a tracked project artifact, and is the sole Trellis hook owner.
- **Husky boundary:** `.husky/` remains project-owned when present, but it never carries Trellis hooks and is never the active Trellis `core.hooksPath` while attached.
- **Chaining and detach:** the dispatcher invokes an executable prior `post-checkout` hook with its original arguments and standard input before release reconciliation, and it does not hide a prior non-zero result. Detach restores the recorded prior setting only when it still matches; a changed hook configuration is a conflict and is never clobbered.
- **Doctor:** `trellis doctor` verifies that exactly one local `core.hooksPath` equals the recorded dispatcher, and reports drift — including a package installer re-clobbering the setting — as an error. Its messages point to `trellis doctor --fix`, never to a bare `git config` write.
- **The single repair exception (spec 055 R4.6):** `trellis doctor --fix` restores the managed path when husky's `prepare` has set it to `.husky/_`, and in no other case. It takes the checkout lock that attach and detach take (serializing it against Trellis writers, not husky), and writes only when every condition holds: every worktree `git worktree list` knows is attached, exactly one record (the worktree that owns the shared exclude block) has hooks enabled with this managed path, and every other is the `{"enabled":false}` record attach writes for a linked worktree; the local value is exactly one `.husky/_`; the managed dispatcher verifies; and the recorded previous path is `.husky/_`, or null with no hook file in `.husky/` outside `_/`. Otherwise it refuses, changes nothing, and names the failed condition and its remedy. After writing it re-reads: if the value is still exactly the one it wrote but a check failed, it restores the preflight value; any other change is reported, not restored. It prints the value before and after.
- **Adopting husky (spec 055 R4.6a):** `trellis doctor --fix --adopt-husky` is the explicit operator action for a recorded previous path of null while `.husky/` holds project hooks. Under the same lock it records `.husky/_` as the previous path in the hooks-enabled owner record and in the `previous-hooks-path` sidecar every worktree shares (linked worktrees' disabled records are checked, never written), and creates one passthrough shim per passthrough-eligible hook name in `.husky/_/` (never `pre-push` or `post-checkout`). It refuses before writing unless every record of the checkout names one release, that release is the active CLI release and its payload verifies, and the managed dir holds no passthrough-named entry. It writes shims, then the record, then the sidecar; any failure, including a failed repair after it, restores every file to its original bytes and mode and removes the shims it created.
- **Harness warnings:** SessionStart (both harnesses) and a `PostToolUse(Bash)` guard after package-manager, `make`/`just`, `core.hooksPath` and `worktree add` commands add one advisory line on drift. Neither writes anything; between the drift and the repair, pushes are ungated because git no longer invokes the dispatcher.
- **Per-install workaround:** `HUSKY=0 pnpm install` (or the npm/yarn equivalent) skips husky's `prepare` for that install. Do not set `HUSKY=0` globally: it also disables husky's own hooks.
- **Installed Trellis handlers:** the dispatcher provides `post-checkout` reconciliation and the `pre-push` gate. Trellis does not install `.husky/pre-commit`, `.husky/commit-msg`, or `.husky/pre-push`.

### pre-push (portable dispatcher → `core-rules/githooks/pre-push`)
- **Runs, in order:**
  1. **PR-flow guard** — blocks direct push to `main` or `master` across all Trellis projects. Commits must land on a branch and merge via PR. Emergency override: `TRELLIS_ALLOW_MAIN_PUSH=1 git push` (use rarely; every invocation should be documented in the project's `gotchas.md` or a commit message trailer). The override bypasses only the PR-flow policy, not the merge gate below — `run-all.sh` still runs in merge mode.
  2. **Mandatory spec gate** — `spec-gate.sh --gate`; disabled by default and blocking only when explicitly enabled.
  3. **AEO warn adapter** — `lib/aeo-gate-warn.sh`; instance-only, disabled by default, relevant-page-only, exactly one non-blocking verdict when enabled.
  4. **The merge gate** — `process-gate/scripts/run-all.sh --mode=<merge|push> --range=<base>..HEAD`, derived from the pushed refs: a push targeting `main`/`master` runs `--mode=merge` (full BLOCKED semantics, no downgrade), a WIP feature-branch push runs the lenient `--mode=push`. Merge mode takes no default range and refuses without an explicit `--range` or `--base`. In push mode with neither flag, the shared diff-base resolver (`process-gate/scripts/lib/diff-base.sh`) picks the base; if it cannot derive one, run-all gates every commit not on the local `main` (else `master`), receipted `via fallback`, and otherwise refuses. There is no `HEAD~1..HEAD` fallback. This single call supersedes the old standalone typecheck+lint+test block (`check-tests.sh` is a strict superset of those). It covers the deterministic gate set: PR-hygiene, secrets, bypass markers, tests, docs, stack profile, security-diff, and analyze. rc 1 → block (exit 1); rc 2 → warn (exit 0); rc 0 → ok.
- **Purpose:** catches anything where `stop-verify` was bypassed (manual commit outside a Claude turn, amended commit, etc.) and enforces Trellis's PR-flow policy + the deterministic merge gate at the git boundary.
- **Block:** PR-flow guard trips, or `run-all.sh --mode=merge` returns a hard failure.
- **Cross-harness reach.** Git hooks are harness-agnostic — they run under Claude Code and Codex (pi has no separate git-hook surface and shares the Codex surface). This local `pre-push` git hook is therefore the cross-harness merge gate **for the deterministic gate set only** (the eight gates above): it is **fail-closed at push** — but **not un-bypassable**. The only escape is an explicit `--no-verify` / direct-push, itself a logged tripwire that an optional operator bypass audit can surface after the fact. There is **no** code-review / ui-verify / receipt gate in `run-all.sh`; those turn-level gates are enforced through each enabled harness's native session path, not at the git boundary.
- **GitHub-side complement:** local guard prevents accidents; branch protection on the remote is the durable gate. Every Trellis project should have `main` branch-protected (require PR, passing status checks, merge-commit only — squash-merge disabled in repo settings to preserve full history). Review-count enforcement is N/A here — sole-maintainer org, GitHub blocks self-approval; the PR window itself + CI is the gate.

### spec-gate (mandatory feature pipeline — spec 006)

The gate that makes "every feature gets specced" enforceable rather than aspirational. **Default OFF** — inert until a project sets `mandatory_pipeline.enabled: true`.

- **Teeth location:** the portable dispatcher invokes the verified release's `core-rules/githooks/pre-push`, which invokes `.claude/hooks/spec-gate.sh --gate` (`.agents/` fallback) **after** the PR-flow guard, **before** the process-gate. A block exits non-zero → the push is refused. This is the load-bearing enforcement point.
- **Parity by construction:** the verdict engine `lib/spec-gate-core.sh` is a **pure function of git + filesystem state** (branch diff size, changed paths, in-range spec triad, bound `/surgical` marker) with **zero model classification**. Same repository state → same verdict on Claude Code and Codex (pi reuses the same core via workflows). Determinism, not prose, does the enforcing.
- **Early-warning:** Claude Code and Codex register the script first in their Stop manifests; pi workflows surface the same block via the role resolver where needed. Each surfaces the block before push, while the git-boundary invocation remains the load-bearing gate.
- **Thresholds** (config, most-specific wins: project-local `.trellis.json` → deprecated project-local `.trellis.config.json` → immutable runtime `trellis.config.json` → built-in): `spec_required_diff_lines` (floor, default **80**) and `surgical_max_diff_lines` (surgical ceiling, default **400**).
- **Gated diff:** net added+deleted vs the protected merge-base, with non-feature paths excluded (tests, `docs/`, `specs/`, `audits/`, the root `gotchas.md`/`decisions-log.md` records and their archives, lockfiles, generated, and operational config like `*.yml`/`package.json`/`trellis.config.json`). Below the floor → passes with no spec (surgical-by-default). Above the floor → one of three routes required.
- **The three routes** (above the floor):
  1. **Spec** — a full `specs/NNN-*/{spec,plan,tasks}.md` triad **added or modified in this branch's range** (merely existing on `main` does not count — C-CRIT-1), each file non-template (≥200 bytes, no `<NNN>`/`<slug>`/`TODO-SPEC`/`SCAFFOLD-PLACEHOLDER` — C-CRIT-2), **plus** an interview artifact tied to autonomy: L1–3 needs `clarify.md` in the triad or a `.claude/spec-waiver`; L4–5 needs a `decisions-log.md` entry naming this branch.
  2. **Surgical** — a size-capped exemption via `/surgical "<why>"`, honored only while the gated diff stays ≤ the ceiling.
  3. **Emergency** — `/surgical --emergency "<why>"`, an any-size override that is audit-logged and obligates a post-facto spec.
- **Marker:** `/surgical` writes a branch-bound marker at `<canonical-root>/.claude/session-surgical` (7 fields: branch, worktree, merge-base, HEAD, session, mode, reason) via `spec-gate.sh --mark[-emergency]`. Honored only on a full bind match (same branch + worktree + merge-base) — a rebase or worktree move intentionally breaks it. Never hand-write it; the field binding is exact.
- **Stop-hook pass cache (spec 072 U8):** the Stop early warning caches a pass in `<TRELLIS_HOME or ~/.trellis>/state/spec-gate/<worktree hash>.<harness>` under a key over everything the verdict reads: worktree and canonical root, HEAD, branch, every ref, the common-dir config and reflogs, policy and preset files, the surgical marker, autonomy session, `decisions-log.md`, spec waiver, every `specs/*/*.md`, the resolver and the gate scripts, `TRELLIS_ROOT` and `SG_REQUEST_*`. Blocks and surgical-marker passes (which write the audit log) are never cached. `--gate` never reads the cache.
- **Audit log:** `sg_valid_marker` appends to `<canonical-root>/.claude/spec-gate-audit.log` — `emergency-override` on every emergency push, `oversized-surgical` when a surgical claim grows past the ceiling. Both are gitignored; the `cross-project-process-audit` surfaces them (an emergency with no follow-up spec is a visible debt).
- **Fail semantics:** fail-**open** on a broken environment (git error, absent `jq`, unresolvable baseline → `advisory`, never blocks — a hiccup must not brick a push); fail-**closed** on a present-but-malformed `mandatory_pipeline` block (an opted-in project must not be silently disabled by a typo). Absence of the block, or `enabled:false`, is byte-identical to pre-006 behavior.
- **Block message:** the three-route remedy prints to stderr on a blocked push; see `sg_remedy_message`.

### AEO diff adapter (spec 033)

`core-rules/hooks/lib/aeo-gate-warn.sh` is the git-boundary adapter for deterministic AEO Mode 2. It is deliberately not a Claude or Codex event hook; both canonical pre-push files call the same library after spec-gate and before process-gate.

- `aeo_gate.enabled` defaults to `false`. Enabling requires `project`, `url`, `marker_file`, `marker`, and an accepted `baseline` path in the repository config.
- Only changed `.html`, `.htm`, `.md`, `.mdx`, `.ts`, `.tsx`, `.js`, or `.jsx` paths invoke the diff runner.
- Evidence lands below `.git/trellis-aeo/<HEAD>` and cannot dirty source.
- PASS, REGRESSION, runner failure, missing baseline, and malformed configuration all exit zero. An enabled relevant invocation emits exactly one `[aeo-gate]` verdict on stderr; absence, disabled state, and irrelevant diffs are silent.
- This is an instance rollout surface, not fleet enforcement. Blocking requires the later operator decision named in Spec 033.

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

Core patterns (block-destructive, post-edit-verify, stop-verify, truncation-check) trace back to [iamfakeguru/claude-md](https://github.com/iamfakeguru/claude-md) (MIT). That template was the seed for this fleet's earliest hook stacks. This file extends the template with: the three-tier architecture, `stop-verify`'s TodoWrite guard, `code-review-subagent`, `ui-verify`, the `session-context` / `save-context-log` / `post-compact-context` hooks, and the git-boundary tier.
