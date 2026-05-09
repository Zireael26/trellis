#!/usr/bin/env bash
# post-edit-verify.sh — Codex PostToolUse on Edit|Write|MultiEdit. Lint the touched file.
# Source: Software Engineering Core / core-rules / codex hooks.
#
# Contract:
#   - Reads tool event JSON on stdin, extracts tool_input.file_path.
#   - Runs the per-file linter for the file's extension.
#   - On failure: emits {"decision":"block","reason":...} on stdout, exit 2.
#   - On success / non-code file / no linter: exit 0 silently.
#
# Dependencies: jq (required). Linters are opportunistic: absence → skip.
#
# Budget: must complete in <3s. Type-checking is deferred to stop-verify.
#
# Base: github.com/iamfakeguru/claude-md (MIT). Extensions vs upstream:
#   - Added Go support (golangci-lint, fallback `go vet`).
#   - Added .rs support via `cargo clippy` (Rust has no practical per-file lint).
#   - Extension filter is explicit: .ts .tsx .js .jsx .py .rs .go.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "post-edit-verify: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "post-edit-verify"

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only check supported source extensions. Everything else is silent.
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.py|*.rs|*.go) ;;
  *) exit 0 ;;
esac

ERRORS=""
FILE_DIR=$(dirname "$FILE_PATH")

# --- JS / TS ---
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx)
    if [ -f ".eslintrc" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.cjs" ] \
       || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f ".eslintrc.yaml" ] \
       || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ] || [ -f "eslint.config.ts" ]; then
      if command -v npx >/dev/null 2>&1; then
        OUT=$(npx --no-install eslint --quiet "$FILE_PATH" 2>&1)
        if [ $? -ne 0 ]; then
          ERRORS="${ERRORS}eslint: ${FILE_PATH}
${OUT}

"
        fi
      fi
    fi
    ;;
esac

# --- Python ---
case "$FILE_PATH" in
  *.py)
    if command -v ruff >/dev/null 2>&1; then
      OUT=$(ruff check "$FILE_PATH" 2>&1)
      if [ $? -ne 0 ]; then
        ERRORS="${ERRORS}ruff: ${FILE_PATH}
${OUT}

"
      fi
    fi
    ;;
esac

# --- Rust (project-wide; cargo has no per-file lint) ---
case "$FILE_PATH" in
  *.rs)
    if command -v cargo >/dev/null 2>&1 && [ -f "Cargo.toml" ]; then
      OUT=$(cargo clippy --quiet --message-format=short -- -D warnings 2>&1)
      if [ $? -ne 0 ]; then
        ERRORS="${ERRORS}clippy: (project-wide)
${OUT}

"
      fi
    fi
    ;;
esac

# --- Go ---
case "$FILE_PATH" in
  *.go)
    if command -v golangci-lint >/dev/null 2>&1; then
      OUT=$(golangci-lint run "$FILE_PATH" 2>&1)
      if [ $? -ne 0 ]; then
        ERRORS="${ERRORS}golangci-lint: ${FILE_PATH}
${OUT}

"
      fi
    elif command -v go >/dev/null 2>&1; then
      OUT=$(go vet "./$FILE_DIR/..." 2>&1)
      if [ $? -ne 0 ]; then
        ERRORS="${ERRORS}go vet: ${FILE_DIR}
${OUT}

"
      fi
    fi
    ;;
esac

if [ -n "$ERRORS" ]; then
  TRUNCATED=$(printf '%s' "$ERRORS" | head -50)
  REASON="Lint failed — fix before continuing:
${TRUNCATED}"
  jq -nc --arg reason "$REASON" '{decision: "block", reason: $reason}'
  exit 2
fi

exit 0
