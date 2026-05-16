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

worst="pass"
findings=()

# Auto-detect package manager if not declared
if [ -z "${PROCESS_GATE_TYPECHECK_CMD:-}${PROCESS_GATE_LINT_CMD:-}${PROCESS_GATE_TEST_CMD:-}" ]; then
  if [ -f "pnpm-lock.yaml" ];      then PM="pnpm"
  elif [ -f "bun.lockb" ];         then PM="bun"
  elif [ -f "package-lock.json" ]; then PM="npm"
  elif [ -f "yarn.lock" ];         then PM="yarn"
  else PM=""
  fi
  if [ -n "$PM" ] && [ -f "package.json" ]; then
    PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PM typecheck}"
    PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PM lint}"
    PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PM test}"
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
    if grep -q '^\[tool\.mypy\]' pyproject.toml 2>/dev/null || [ -f "mypy.ini" ]; then
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PY_RUN mypy .}"
    fi

    # Default lint: ruff if configured.
    if grep -q '^\[tool\.ruff\]' pyproject.toml 2>/dev/null || [ -f "ruff.toml" ]; then
      PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PY_RUN ruff check .}"
    fi

    # Default tests: pytest if configured.
    if grep -q '^\[tool\.pytest\.ini_options\]' pyproject.toml 2>/dev/null \
       || [ -f "pytest.ini" ] || [ -f "conftest.py" ]; then
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PY_RUN pytest}"
    fi
  fi

  # Go toolchain detection (workspaces or single module)
  if [ -z "${PM:-}" ] && { [ -f "go.work" ] || [ -f "go.mod" ]; }; then
    # Go workspaces break `go vet ./...` and `go test ./...` from the repo
    # root — prefer a Makefile orchestrator if one exposes vet/lint/test
    # targets. clusterbid-console established this pattern.
    if [ -f "Makefile" ] && grep -qE '^(vet|lint|test):' Makefile 2>/dev/null; then
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-make vet}"
      PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-make lint}"
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-make test}"
    else
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
  if [ -z "$cmd" ]; then
    findings+=("$label: not declared in local.config.sh and not auto-detectable")
    if [ "$label" = "typecheck" ]; then
      worst="fail"
    elif [ "$worst" = "pass" ]; then
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
