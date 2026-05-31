#!/usr/bin/env bash
# stop-verify.sh — Stop. TodoWrite → typecheck → lint → test, auto-detected.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - stop_hook_active guard: if set, exit 0 immediately (infinite-loop guard).
#   - Pure chat / no edits: exit 0 (skip).
#   - Runs checks in order. On any failure, emit
#     {"decision":"block","reason":"<step>: <sliced output>"} and exit 2.
#   - Error slicing: typecheck/lint → first 30 lines; tests → last 30 lines.
#   - Budget: 90s soft cap.
#
# Subtree scoping: when every changed file in this turn sits under a single
# subdirectory that carries its own manifest (package.json, go.mod,
# pyproject.toml, or Cargo.toml), checks run scoped to that subtree instead
# of repo root. Cuts wall time + noise on monorepos. Escape hatch:
# PROCESS_GATE_FORCE_ROOT=1 → always run at repo root (legacy behaviour).
#
# Dependencies: jq (required). Toolchains are detected; absence → skip that step.
#
# Todo state: read from $CLAUDE_PROJECT_DIR/.claude/todos.json. If missing or
# unparseable, we pass that step (don't block). This matches Claude Code's
# current persistence location; if that location changes, override via
# project `.claude/hooks/config.sh` exporting TODOS_FILE.
#
# Base: github.com/iamfakeguru/claude-md (MIT). Extensions vs upstream:
#   - Step 1: TodoWrite state check (receipts-required enforcement).
#   - Go support (go vet / go test / golangci-lint).
#   - Test output uses last-30 lines; lint/typecheck use first-30.
#   - Subtree scoping (auto-detects nested manifests; PROCESS_GATE_FORCE_ROOT escape).

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "stop-verify: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "stop-verify"

# Optional: package-manager resolver (config-driven, lockfile fallback). Absent
# copy → test step falls back to npm (legacy behaviour).
__se_pm_lib="$(dirname "${BASH_SOURCE[0]}")/lib/pm.sh"
# shellcheck source=lib/pm.sh disable=SC1090
[ -f "$__se_pm_lib" ] && . "$__se_pm_lib"

# --- Guard 1: stop_hook_active ---
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

emit_block() {
  local step="$1"
  local output="$2"
  local reason="${step}: ${output}"
  jq -nc --arg reason "$reason" '{decision: "block", reason: $reason}'
  exit 2
}

# _se_find_subtree — echo the deepest subtree (relative to PROJECT_DIR) that
# contains every changed file in this turn AND carries its own manifest. Echo
# nothing if changed files span multiple subtrees, none have a nested manifest,
# or git isn't here. Quiet by design.
_se_find_subtree() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local file dir found common=""

  while IFS= read -r file; do
    [ -z "$file" ] && continue

    dir="$(dirname "$file")"
    found=""
    # Walk up. Stop one level above the worktree root.
    while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
      if [ -f "$dir/package.json" ] || [ -f "$dir/go.mod" ] \
         || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Cargo.toml" ]; then
        found="$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done

    # File has no nested manifest above it → caller falls back to repo root.
    [ -z "$found" ] && return 0

    if [ -z "$common" ]; then
      common="$found"
    elif [ "$common" != "$found" ]; then
      # Changed files span multiple subtrees → fall back to repo root.
      return 0
    fi
  done < <(
    { git diff --name-only HEAD 2>/dev/null; \
      git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
  )

  printf '%s' "$common"
}

# --- Step 1: TodoWrite check (runs before the dirty-tree skip — pure-chat turns
# can close todos via TodoWrite without touching files; receipts-required must
# still hold). ---
TODOS_FILE="${TODOS_FILE:-${PROJECT_DIR}/.claude/todos.json}"
if [ -f "$TODOS_FILE" ]; then
  # Grab any pending/in_progress task content. If jq errors, we silently pass.
  OPEN_TODOS=$(jq -r '
    [.. | objects | select(.status? == "in_progress" or .status? == "pending")]
    | map("- [\(.status)] \(.content // .task // "?")")
    | .[]
  ' "$TODOS_FILE" 2>/dev/null | head -20)

  if [ -n "$OPEN_TODOS" ]; then
    emit_block "TodoWrite" "open tasks remain — complete, defer with reason, or abandon with reason:
${OPEN_TODOS}"
  fi
fi

# --- Guard 2: no file edits this turn → pure chat; skip typecheck/lint/test.
# Best-effort: check git worktree dirtiness. If git isn't here, fall through
# and let downstream steps no-op when no config files exist.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Porcelain output is empty iff worktree matches HEAD (no staged, unstaged, or untracked changes).
  # NOTE: earlier versions used `grep -c '^' || echo 0` here — that doubles output to "0\n0"
  # when empty (grep -c prints 0 AND exits non-zero), breaking the numeric test.
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    # Nothing changed this turn → treat as pure chat and skip checks.
    exit 0
  fi
fi

# --- Subtree scoping. If every changed file shares one subtree with its own
# manifest, run scoped checks there instead of repo-root. Opt-out:
# PROCESS_GATE_FORCE_ROOT=1.
if [ "${PROCESS_GATE_FORCE_ROOT:-0}" != "1" ]; then
  SUBTREE="$(_se_find_subtree)"
  if [ -n "$SUBTREE" ] && [ -d "$SUBTREE" ]; then
    cd "$SUBTREE" 2>/dev/null || true
  fi
fi

CHECKS_RUN=0

# --- Step 2: Typecheck ---
# TypeScript
if [ -f "tsconfig.json" ] && command -v npx >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(npx --no-install tsc --noEmit 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "typecheck (tsc)" "$SLICED"
  fi
fi

# Python (mypy)
if command -v mypy >/dev/null 2>&1; then
  HAS_MYPY_CFG=0
  [ -f "mypy.ini" ] && HAS_MYPY_CFG=1
  if [ -f "pyproject.toml" ] && grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; then
    HAS_MYPY_CFG=1
  fi
  if [ "$HAS_MYPY_CFG" = "1" ]; then
    CHECKS_RUN=$((CHECKS_RUN + 1))
    OUT=$(mypy . 2>&1)
    if [ $? -ne 0 ]; then
      SLICED=$(printf '%s' "$OUT" | head -30)
      emit_block "typecheck (mypy)" "$SLICED"
    fi
  fi
fi

# Rust
if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(cargo check 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "typecheck (cargo check)" "$SLICED"
  fi
fi

# Go
if [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(go vet ./... 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "typecheck (go vet)" "$SLICED"
  fi
fi

# --- Step 3: Lint (repo-wide) ---
# ESLint
if [ -f ".eslintrc" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.cjs" ] \
   || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f ".eslintrc.yaml" ] \
   || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ] || [ -f "eslint.config.ts" ]; then
  if command -v npx >/dev/null 2>&1; then
    CHECKS_RUN=$((CHECKS_RUN + 1))
    OUT=$(npx --no-install eslint . --quiet 2>&1)
    if [ $? -ne 0 ]; then
      SLICED=$(printf '%s' "$OUT" | head -30)
      emit_block "lint (eslint)" "$SLICED"
    fi
  fi
fi

# ruff
if command -v ruff >/dev/null 2>&1 && { [ -f "pyproject.toml" ] || [ -f "ruff.toml" ] || [ -f ".ruff.toml" ]; }; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(ruff check . 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "lint (ruff)" "$SLICED"
  fi
fi

# clippy
if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(cargo clippy --quiet --message-format=short -- -D warnings 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "lint (clippy)" "$SLICED"
  fi
fi

# golangci-lint
if [ -f "go.mod" ] && command -v golangci-lint >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(golangci-lint run 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "lint (golangci-lint)" "$SLICED"
  fi
fi

# --- Step 4: Test (fast suite; skip e2e unless explicitly configured) ---
TEST_CMD=""
if [ -f "package.json" ] && command -v jq >/dev/null 2>&1; then
  HAS_TEST=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
  if [ -n "$HAS_TEST" ] && [ "$HAS_TEST" != "echo \"Error: no test specified\" && exit 1" ]; then
    if command -v trellis_resolve_pm >/dev/null 2>&1; then
      _PM="$(trellis_resolve_pm "$PROJECT_DIR")"
    else
      _PM="npm"
    fi
    # Configured-but-missing PM → skip the test step rather than hard-fail.
    if [ -n "$_PM" ] && command -v "$_PM" >/dev/null 2>&1; then
      TEST_CMD="$_PM run test"
    fi
  fi
elif { [ -f "pyproject.toml" ] || [ -f "pytest.ini" ] || [ -f "setup.cfg" ]; } && command -v pytest >/dev/null 2>&1; then
  TEST_CMD="pytest --tb=short -q"
elif [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  TEST_CMD="cargo test --quiet"
elif [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
  TEST_CMD="go test ./..."
fi

if [ -n "$TEST_CMD" ]; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(eval "$TEST_CMD" 2>&1)
  if [ $? -ne 0 ]; then
    # Tests: last 30 lines (stack traces / assertions land at the end).
    SLICED=$(printf '%s' "$OUT" | tail -30)
    emit_block "test (${TEST_CMD})" "$SLICED"
  fi
fi

# --- Pass / no-check advisory ---
if [ "$CHECKS_RUN" -eq 0 ]; then
  jq -nc '{additionalContext: "stop-verify: no typecheck/lint/test configured for this repo. Task completion is unverified — state this to the user."}'
  exit 0
fi

exit 0
