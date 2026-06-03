#!/usr/bin/env bash
# Gate 4: Tests & coverage — runs project-declared typecheck/lint/test commands.
# Usage: check-tests.sh

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
PROJECT_DIR="$(pg_project_dir)"
cd "$PROJECT_DIR"

# pg_has_npm_script <script-name>  (cwd is PROJECT_DIR)
#   Returns 0 only when package.json declares the named script. Portable across
#   jq → node → a grep fallback on .scripts. Used to keep an undeclared script's
#   command EMPTY rather than constructing `$PM run <name>` which exits nonzero
#   ("Missing script") and would wrongly BLOCK repos without that script.
pg_has_npm_script() {
  [ -f package.json ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg s "$1" '.scripts[$s] != null' package.json >/dev/null 2>&1
  elif command -v node >/dev/null 2>&1; then
    node -e 'var s=(require("./package.json").scripts)||{};process.exit(s[process.argv[1]]?0:1)' "$1" 2>/dev/null
  else
    # Last-resort grep tier: best-effort (COARSE) — only the jq and node tiers
    # above are exact. Scope the match to the .scripts object region first (the
    # "scripts" key to the next closing brace) so a non-script key of the same
    # name (e.g. a devDependency literally named "test") cannot false-positive
    # into building `$PM run <name>` for a script that doesn't exist → BLOCK.
    # Terminate on a closing brace ALONE on its line (DL-P7-10): a `,/}/` range
    # stops at the FIRST line containing ANY `}`, so a .scripts VALUE that itself
    # contains a literal `}` (e.g. "lint": "eslint --rule '{...}'") before the
    # target script would truncate the region → MISS a genuinely-declared later
    # script → warn-skip a real test (fail-OPEN). `/^[[:space:]]*}/` ends only on
    # a sole-`}` line, so an in-value brace no longer closes the region.
    # STILL COARSE: a multi-line script value with its own sole-`}` line could
    # truncate, and nested script maps are not parsed — only the jq and node
    # tiers are exact. (No JSON parser here — that is what those tiers are for.)
    sed -n '/"scripts"[[:space:]]*:/,/^[[:space:]]*}/p' package.json 2>/dev/null \
      | grep -Eq "\"$1\"[[:space:]]*:" 2>/dev/null
  fi
}

worst="pass"
findings=()

# Auto-detect package manager if not declared
if [ -z "${PROCESS_GATE_TYPECHECK_CMD:-}${PROCESS_GATE_LINT_CMD:-}${PROCESS_GATE_TEST_CMD:-}" ]; then
  PM="$(pg_resolve_pm "$PROJECT_DIR")"
  # Configured-but-missing PM → surface as WARN and skip the JS toolchain rather
  # than hard-failing the gate (mirrors stop-verify / pre-push skip-on-absent-PM).
  if [ -n "$PM" ] && [ -f "package.json" ] && ! command -v "$PM" >/dev/null 2>&1; then
    pg_log warn "Tests & coverage"
    pg_finding "package manager '$PM' not on PATH — JS typecheck/lint/test skipped (install $PM, or set PROCESS_GATE_*_CMD in local.config.sh)"
    exit 2
  fi
  # `$PM run <script>` is the portable form across pnpm/npm/yarn/bun — bare
  # `npm typecheck`/`npm lint` are invalid (npm only aliases test/start/stop).
  # Only build the command when package.json actually declares the script;
  # otherwise leave the cmd EMPTY so run_check downgrades it to a WARN instead
  # of running a missing npm script that exits nonzero and BLOCKS the gate.
  if [ -n "$PM" ] && [ -f "package.json" ]; then
    if pg_has_npm_script typecheck; then PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PM run typecheck}"; fi
    if pg_has_npm_script lint;      then PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PM run lint}"; fi
    if pg_has_npm_script test;      then PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PM run test}"; fi
  fi

  # Python toolchain detection (order: uv → poetry → pdm → bare pyproject)
  if [ -z "${PM:-}" ] && [ -f "pyproject.toml" ]; then
    if   [ -f "uv.lock" ];     then PY_RUN="uv run"
    elif [ -f "poetry.lock" ]; then PY_RUN="poetry run"
    elif [ -f "pdm.lock" ];    then PY_RUN="pdm run"
    else PY_RUN="python -m"
    fi

    # Default typecheck: mypy if configured (pyproject [tool.mypy] or mypy.ini).
    # Pyright is opt-in via explicit PROCESS_GATE_TYPECHECK_CMD override.
    # Config-presence is NOT enough (DL-P7-07): also probe that the tool is
    # RUNNABLE in its own env via the EXACT `$PY_RUN <tool>` invocation form
    # (so `python -m mypy`, `uv run mypy`, `poetry run mypy` each resolve a
    # venv/uv-managed tool; `--version` is fast and side-effect-free). A
    # configured-but-not-installed tool leaves the cmd EMPTY → run_check WARNs
    # (couldn't-run), instead of failing at runtime → BLOCK.
    if { grep -q '^\[tool\.mypy\]' pyproject.toml 2>/dev/null || [ -f "mypy.ini" ]; } && $PY_RUN mypy --version >/dev/null 2>&1; then
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PY_RUN mypy .}"
    fi

    # Default lint: ruff if configured and runnable.
    if { grep -q '^\[tool\.ruff\]' pyproject.toml 2>/dev/null || [ -f "ruff.toml" ]; } && $PY_RUN ruff --version >/dev/null 2>&1; then
      PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PY_RUN ruff check .}"
    fi

    # Default tests: pytest if configured and runnable.
    if { grep -q '^\[tool\.pytest\.ini_options\]' pyproject.toml 2>/dev/null \
       || [ -f "pytest.ini" ] || [ -f "conftest.py" ]; } && $PY_RUN pytest --version >/dev/null 2>&1; then
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PY_RUN pytest}"
    fi
  fi

  # Go toolchain detection (workspaces or single module).
  # Require `go` on PATH for the ENTIRE branch (DL-P7-07): a configured Go repo
  # with `go` off PATH would make `go vet`/`go test` (and any make target that
  # drives go) exit 127 at runtime → worst=fail → BLOCK. go-absent is
  # "couldn't-run", which the bright line maps to WARN, not fail — so when go
  # is absent we build NO go commands (all three downgrade to warn). This guard
  # also covers the make-target arm: a `make vet/test` that shells out to go
  # needs go present too.
  if [ -z "${PM:-}" ] && { [ -f "go.work" ] || [ -f "go.mod" ]; } && command -v go >/dev/null 2>&1; then
    # Go workspaces break `go vet ./...` and `go test ./...` from the repo
    # root — prefer a Makefile orchestrator if one exposes vet/lint/test
    # targets. clusterbid-console established this pattern.
    if [ -f "Makefile" ] && grep -qE '^(vet|lint|test):' Makefile 2>/dev/null; then
      # PER-TARGET guard (DL-P7-09): the branch enters on ANY ONE of
      # vet/lint/test being a Makefile target, but each `make <target>` command
      # is built ONLY when that SPECIFIC target is declared. A Makefile that
      # declares only a subset (e.g. just `test:`) previously ran `make vet` /
      # `make lint` anyway — each exits 2 ("No rule to make target") → worst=fail
      # → BLOCK. A missing make target is "couldn't-run", which the bright line
      # maps to WARN: leave its cmd EMPTY so run_check downgrades it. A DECLARED
      # target whose recipe genuinely fails (`make test` exits 1) still hard-fails.
      if grep -qE '^vet:'  Makefile 2>/dev/null; then PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-make vet}"; fi
      if grep -qE '^lint:' Makefile 2>/dev/null; then PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-make lint}"; fi
      if grep -qE '^test:' Makefile 2>/dev/null; then PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-make test}"; fi
    elif [ -f "go.work" ]; then
      # go.work workspace ROOT with no Makefile vet/lint/test target: the
      # root-level `go vet ./...` / `go test ./...` are BROKEN here (they exit
      # nonzero with "directory prefix . does not contain modules listed in
      # go.work") → would BLOCK. Leave typecheck/test UNDECLARED so they
      # downgrade to warn; do NOT build the broken root-level commands.
      # golangci-lint is still safe to declare (module-aware) when present.
      if command -v golangci-lint >/dev/null 2>&1; then
        PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-golangci-lint run ./...}"
      fi
    else
      # Single-module go.mod (no go.work, no Makefile targets): `go vet ./...`
      # and `go test ./...` are valid from the module root.
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-go vet ./...}"
      if command -v golangci-lint >/dev/null 2>&1; then
        PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-golangci-lint run ./...}"
      fi
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-go test ./...}"
    fi
  fi
fi

PROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-300}"

run_check() {
  local label="$1" cmd="$2"
  # Bright line: ABSENT/UNDECLARED check → WARN, never a fail. A check that is
  # declared/detected and FAILS at runtime (rc nonzero, below) stays a hard
  # fail. An empty cmd means the check was never declared or auto-detected, so
  # it must not BLOCK — every label downgrades to warn (was: typecheck→fail).
  if [ -z "$cmd" ]; then
    findings+=("$label: not declared/detected — skipped")
    if [ "$worst" = "pass" ]; then
      worst="warn"
    fi
    return 0
  fi

  local out rc
  set +e
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout "$PROCESS_GATE_TEST_TIMEOUT" bash -c "$cmd" 2>&1)"; rc=$?
  else
    out="$(bash -c "$cmd" 2>&1)"; rc=$?
  fi
  set -e

  if [ "$rc" -ne 0 ]; then
    findings+=("$label: \`$cmd\` exited $rc")
    # Last 10 lines of output for context
    while IFS= read -r line; do
      findings+=("    $line")
    done < <(printf "%s\n" "$out" | tail -n 10)
    worst="fail"
  fi
}

run_check "typecheck" "${PROCESS_GATE_TYPECHECK_CMD:-}"
run_check "lint"      "${PROCESS_GATE_LINT_CMD:-}"
run_check "tests"     "${PROCESS_GATE_TEST_CMD:-}"

# Optional: coverage
if [ -n "${PROCESS_GATE_COVERAGE_CMD:-}" ]; then
  out="$(bash -c "$PROCESS_GATE_COVERAGE_CMD" 2>&1 || true)"
  pct="$(printf "%s" "$out" | grep -oE 'All files[^|]*\|[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?$' | head -1)"
  floor="${PROCESS_GATE_COVERAGE_FLOOR:-0}"
  if [ -n "$pct" ] && [ "$(printf '%.0f' "$pct")" -lt "$floor" ]; then
    findings+=("coverage: ${pct}% < floor ${floor}%")
    if [ "$worst" = "pass" ]; then worst="warn"; fi
  fi
fi

case "$worst" in
  pass) pg_log pass "Tests & coverage" ;;
  warn) pg_log warn "Tests & coverage"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "Tests & coverage"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
