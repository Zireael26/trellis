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

The gate runs tests on the *full project*, not just the diff. Reasoning: a change in module A can break tests in module B that the diff doesn't touch. Covered by the canonical `stop-verify` hook in-session and the `pre-push` hook at git boundary; the gate is a third confirmation at PR time.

For very large monorepos where full-project test runs exceed the 5-min budget:

```bash
# Use Turbo's affected-only mode or equivalent.
PROCESS_GATE_TEST_CMD="turbo run test --filter=...[origin/main]"
PROCESS_GATE_TEST_TIMEOUT=600
```

The trade-off (faster gate but theoretically incomplete coverage) must be acknowledged in the project's `CLAUDE.md`.

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
