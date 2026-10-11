# Reference — Tests & coverage

Authoritative source: `engineering-process.md` §7 (Definition of done) and §8.6 (Testing bar).

## What the gate checks

The gate enforces presence and pass-status of the project-declared test commands. Coverage thresholds, framework choice, and integration scope are project-local.

## Required commands

Declared in `<project>/.claude/skills/process-gate-local/local.config.sh` or, for Codex, `<project>/.agents/skills/process-gate-local/local.config.sh`:

```bash
PROCESS_GATE_TYPECHECK_CMD="pnpm typecheck"
PROCESS_GATE_LINT_CMD="pnpm lint"
PROCESS_GATE_TEST_CMD="pnpm test"
```

The file is read from the base of the gated range and parsed as data (see SKILL.md, "Gate config is read from the range base, as data"): changing a command in a PR takes effect only after it merges.

Web stacks default to `pnpm` if `pnpm-lock.yaml` is present, `bun` if `bun.lockb`, `npm` if `package-lock.json`. The gate auto-detects but local.config.sh wins.

Python projects auto-detect in this order: `uv.lock` → `uv run`, `pdm.lock` → `pdm run`, otherwise `pyproject.toml` alone → `python -m` (from the project's active venv). Default commands once a runner is selected:

- **typecheck:** `<runner> mypy .` when `[tool.mypy]` exists in `pyproject.toml` or a `mypy.ini` is present. Pyright remains available via an explicit `PROCESS_GATE_TYPECHECK_CMD` override; the gate does not auto-pick Pyright.
- **lint:** `<runner> ruff check .` when `[tool.ruff]` exists in `pyproject.toml` or a `ruff.toml` is present.
- **tests:** `<runner> pytest` when `[tool.pytest.ini_options]` exists in `pyproject.toml` or `pytest.ini`/`conftest.py` is present.

For other non-Node, non-Python stacks the commands are project-supplied: `cargo check && cargo clippy && cargo test`, `go vet && go test ./...`, etc.

## Posture

| Result | Posture |
|---|---|
| All three commands pass | **pass** |
| Typecheck or lint fails | **fail** — non-negotiable; same gate that `stop-verify` enforces in-session |
| Tests fail | **fail** |
| Tests timeout (default 5 min, override via `PROCESS_GATE_TEST_TIMEOUT`) | **fail** |
| Typecheck command not declared AND not auto-detectable | **fail** — typecheck is non-negotiable per `engineering-process.md` §7 (Definition of done); a project that cannot typecheck cannot meet the bar |
| Lint or test command not declared AND not auto-detectable | **warn** — declare them in `local.config.sh` |

## Coverage

Project-local. The gate does not enforce a coverage percentage. Projects that want one declare:

```bash
PROCESS_GATE_COVERAGE_CMD="pnpm test:coverage"
PROCESS_GATE_COVERAGE_FLOOR=70  # warn below this
```

Falling below floor: **warn** (don't block, but visible in verdict).

## What the gate does NOT enforce

- **Test framework choice.** Vitest, Jest, Pytest, Cargo test, Go test — project's call.
- **Test naming conventions.** Project-local.
- **Integration / E2E scope.** Run in CI, not at gate time. The gate only covers fast unit + typecheck + lint per `engineering-process.md` §8.6.
- **Mutation testing.** Project's call.

## Stack-specific extensions

Web projects often add accessibility tests (axe-core, pa11y) and visual regression tests. These run via stack-profile validators, not the canonical `check-tests.sh`. See `references/stack-profiles.md`.

## When tests should run

The gate runs tests on the *full project*, not just the diff (the one exception is an opted-in docs-only range, below). Reasoning: a change in module A can break tests in module B that the diff doesn't touch. Covered by the canonical `stop-verify` hook in-session and the `pre-push` hook at git boundary; the gate is a third confirmation at PR time.

For very large monorepos where full-project test runs exceed the 5-min budget:

```bash
# Use Turbo's affected-only mode or equivalent.
PROCESS_GATE_TEST_CMD="turbo run test --filter=...[origin/main]"
PROCESS_GATE_TEST_TIMEOUT=600
```

The trade-off (faster gate but theoretically incomplete coverage) must be acknowledged in the project's `CLAUDE.md`.

## Docs-only ranges (opt-in)

A range that changes only passive records can skip the test battery. The rule is narrow, and doubt runs the full battery.

The project opts in with a policy file at `.claude/skills/process-gate-local/docs-only-tests.policy` or `.agents/skills/process-gate-local/docs-only-tests.policy`. If both exist, they must be identical. The gate reads the policy from Git objects at the range's base, never from the range or the checkout. A policy edit carried in a PR therefore takes effect only after it merges, and the edit itself runs the full battery because it changes a dot-directory path.

The format is one directive per line. Comments are whole lines starting with `#`; the rest of a directive line is its value.

```
# allow: an anchored, case-sensitive ERE. deny: an ERE that beats every allow.
# tests: an optional command, at most once, run in place of the battery.
allow ^docs/adr/[A-Za-z0-9][A-Za-z0-9._-]*\.md$
deny ^docs/adr/0009-pinned\.md$
tests bats scripts/tests/docs-consumers.bats
```

`allow` patterns must be anchored with `^…$`. An unknown keyword, an empty or invalid pattern, or a second `tests` line makes the policy malformed.

**Eligibility.** The range narrows only when every path touched by every commit in it qualifies. That covers both sides of a rename, deleted paths, and changes made and then reverted inside the range. A path qualifies only if it meets all of these:

- It matches an `allow` entry and no `deny` entry.
- It clears the built-in floor, which no policy can widen:
  - ordinary path components only: no dot-directories, spaces, control characters or leading dashes;
  - a `.md` suffix;
  - no behaviour-bearing namespace (`core-rules/`, `scripts/`, `hooks/`, `skills/`, `commands/`, `agents/`, `prompts/`, `templates/`, test, fixture and baseline directories, secret directories);
  - no operative file name (`SKILL.md`, `CLAUDE.md`, `AGENTS.md`, `README.md`, `prompt.md`, `targets.md` and similar), and no `VERSION`, `UPGRADING` or secret-like name. These name checks are case-insensitive.
- Its blob is a plain `100644` file: not a symlink, gitlink or executable, with no NUL byte, and not an LFS pointer.

**Full battery, with a `process-gate: notice (docs-only: full tests — <reason>)` on stderr, when:**

- the policy is unreadable or malformed;
- the range start is not an ancestor of its end;
- the range has no commits or no changed paths;
- the range contains a merge commit;
- any path fails eligibility.

With no policy at the base, or a range the shared diff-base resolver (`core-rules/skills/process-gate/scripts/lib/diff-base.sh`) cannot resolve, the battery runs silently, as it always has.

**When the range narrows:**

- Typecheck and lint still run.
- The battery is replaced by the policy's `tests` command, or skipped if the policy has none. That command takes no heavy slot.
- Coverage and the mutation spot-check are skipped.
- The row prints `Tests: narrowed (docs-only: N files)`, where N is the number of changed paths in the net diff, and `run-all.sh` repeats that line under the verdict. A narrowed pass is never a full-battery pass.
- The other rows are unaffected. Secrets, Bypass markers, Docs discipline and Security run in full on every range.

The narrowing presumes that the protected base passed its own full gate. It does not reuse or verify a prior test receipt.

**Trellis's own policy** is `.claude/skills/process-gate-local/docs-only-tests.policy`. It allows `docs/`, spec and top-level Markdown, and it denies the runbooks, the process doctrine, steering, prompt and setup text. Its `tests` line runs only the checks that read repository Markdown: `scripts/tests/gpt6-roster-sweep.bats`, the A3.8 repository scan in `scripts/tests/release-tag-consumers.bats`, the tracked-source scan in `scripts/tests/check-process-liveness.bats`, and `scripts/conformance-check.sh`.

## Machine-wide heavy slots

The test battery runs through `trellis heavy` (spec 054), so parallel lanes on one host take
turns instead of starving each other. `check-tests.sh` runs `trellis heavy --check` once, before
any check. On exit 0 the battery waits for a slot, and `PROCESS_GATE_TEST_TIMEOUT` starts only once
the slot is held. On any other exit, or with no launcher, the battery runs on the old bounded
path and the gate prints `process-gate: notice (heavy-gate-unavailable: <reason>)` to stderr.
The path is chosen before the battery runs, so a failing battery is never re-run.
`PROCESS_GATE_HEAVY_LAUNCHER` names the launcher (default: `trellis` on `PATH`). Typecheck, lint,
coverage and the mutation spot-check are not gated. The battery always uses the heavy pool, never
`--light`.

## CI vs gate

The gate runs locally or in a pre-merge agent context. CI runs on the merge commit. Both must be green:

- **Gate green, CI red:** environmental difference. Investigate (env vars, OS, Node version pin).
- **Gate red, CI green:** unlikely — usually means the gate was skipped or the project's `local.config.sh` doesn't match CI commands. Reconcile.

The gate should mirror CI's fast-suite as closely as possible. Slow integration suites stay in CI only.
