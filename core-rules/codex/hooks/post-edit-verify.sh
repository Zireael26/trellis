#!/usr/bin/env bash
# post-edit-verify.sh — Codex PostToolUse on Edit|Write|MultiEdit. Lint the touched file.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Normalizes legacy file events and native multi-file apply_patch events.
#   - Runs the per-file linter for every declared existing mutation target.
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

__ta_lib="$(dirname "${BASH_SOURCE[0]}")/lib/action-normalize.sh"
[ -f "$__ta_lib" ] || __ta_lib="$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib/action-normalize.sh"
[ -f "$__ta_lib" ] || { echo "post-edit-verify: missing action normalizer — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=../../hooks/lib/action-normalize.sh disable=SC1090
. "$__ta_lib"

NORMALIZED=$(_ta_normalize_action codex post_action "$INPUT") || {
  echo "post-edit-verify: malformed tool envelope — verification unavailable" >&2
  exit 1
}
[ "$(printf '%s' "$NORMALIZED" | jq -r '.action.family')" = "file_mutation" ] || exit 0
[ "$(printf '%s' "$NORMALIZED" | jq -r '.result.status')" != "failed" ] || exit 0

ACTION_CWD=$(printf '%s' "$NORMALIZED" | jq -r '.cwd // empty')
[ -d "$ACTION_CWD" ] || ACTION_CWD="$(_se_project_dir)"
cd "$ACTION_CWD" 2>/dev/null || exit 0

ERRORS=""
RUST_CHECKED=0

lint_target() {
  local FILE_PATH="$1" FILE_DIR OUT

  # Only check supported source extensions. Everything else is silent.
  case "$FILE_PATH" in
    *.ts|*.tsx|*.js|*.jsx|*.py|*.rs|*.go) ;;
    *) return 0 ;;
  esac
  [ -f "$FILE_PATH" ] || return 0
  FILE_DIR=$(dirname "$FILE_PATH")

# --- JS / TS ---
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx)
    if [ -f ".eslintrc" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.cjs" ] \
       || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f ".eslintrc.yaml" ] \
       || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ] || [ -f "eslint.config.ts" ]; then
      if command -v npx >/dev/null 2>&1 && npx --no-install eslint --version >/dev/null 2>&1; then
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
    if [ "$RUST_CHECKED" -eq 0 ] && command -v cargo >/dev/null 2>&1 && [ -f "Cargo.toml" ]; then
      RUST_CHECKED=1
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
    if ! ABS_FILE_DIR=$(cd "$FILE_DIR" 2>/dev/null && pwd -P); then
      echo "post-edit-verify: skipping Go lint for ${FILE_PATH}: file directory not found" >&2
      return 0
    fi

    MODULE_ROOT="$ABS_FILE_DIR"
    while [ ! -f "$MODULE_ROOT/go.mod" ]; do
      PARENT_DIR=$(dirname "$MODULE_ROOT")
      if [ "$PARENT_DIR" = "$MODULE_ROOT" ]; then
        echo "post-edit-verify: skipping Go lint for ${FILE_PATH}: no owning go.mod found" >&2
        return 0
      fi
      MODULE_ROOT="$PARENT_DIR"
    done

    if [ "$ABS_FILE_DIR" = "$MODULE_ROOT" ]; then
      REL_DIR="."
      PACKAGE_PATH="./..."
    else
      REL_DIR=${ABS_FILE_DIR#"$MODULE_ROOT"/}
      PACKAGE_PATH="./$REL_DIR/..."
    fi
    REL_FILE="./$REL_DIR/$(basename "$FILE_PATH")"

    if command -v golangci-lint >/dev/null 2>&1; then
      OUT=$(cd "$MODULE_ROOT" && golangci-lint run "$REL_FILE" 2>&1)
      if [ $? -ne 0 ]; then
        ERRORS="${ERRORS}golangci-lint: ${FILE_PATH}
${OUT}

"
      fi
    elif command -v go >/dev/null 2>&1; then
      OUT=$(cd "$MODULE_ROOT" && go vet "$PACKAGE_PATH" 2>&1)
      if [ $? -ne 0 ]; then
        ERRORS="${ERRORS}go vet: ${FILE_DIR}
${OUT}

"
      fi
    fi
    ;;
esac
}

SEEN_PATHS=""
while IFS=$'\t' read -r OPERATION SOURCE_PATH DESTINATION; do
  case "$OPERATION" in
    delete) continue ;;
    rename) TARGET_PATH="$DESTINATION" ;;
    create|update) TARGET_PATH="$SOURCE_PATH" ;;
    *) continue ;;
  esac
  FILE_PATH=$(_ta_resolve_path "$ACTION_CWD" "$TARGET_PATH") || continue
  case "$SEEN_PATHS" in
    *$'\n'"$FILE_PATH"$'\n'*) continue ;;
  esac
  SEEN_PATHS="${SEEN_PATHS}
${FILE_PATH}
"
  lint_target "$FILE_PATH"
done < <(_ta_targets_tsv "$NORMALIZED")

if [ -n "$ERRORS" ]; then
  TRUNCATED=$(printf '%s' "$ERRORS" | head -50)
  REASON="Lint failed — fix before continuing:
${TRUNCATED}"
  jq -nc --arg reason "$REASON" '{decision: "block", reason: $reason}'
  exit 2
fi

exit 0
