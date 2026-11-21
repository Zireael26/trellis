#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
# post-edit-verify.sh — Codex PostToolUse on Edit|Write|MultiEdit. Lint the touched file.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Normalizes legacy file events and native multi-file apply_patch events.
#   - Runs the per-file linter for every declared existing mutation target.
#   - On failure: emits schema-valid JSON on stdout and feedback on stderr, exit 2.
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
_se_load_heavy || { echo "post-edit-verify: missing sibling lib deps-heavy.sh beside $__se_lib — re-run sync-hooks" >&2; exit 1; }
_se_require_jq "post-edit-verify"

# Sibling first; the in-place fallback applies only inside the declared
# runtime's Codex tree (spec 055 R1.1), never a project-controlled hooks/lib/.
__h_dir=$(unset CDPATH; cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
__h_rt=$(unset CDPATH; [ -n "${TRELLIS_ROOT:-}" ] && cd -P -- "$TRELLIS_ROOT" 2>/dev/null && pwd -P)
__ta_lib="$__h_dir/lib/action-normalize.sh"
if [ ! -f "$__ta_lib" ] && [ -n "$__h_rt" ] && [ "$__h_dir" = "$__h_rt/core-rules/codex/hooks" ]; then
  __ta_lib="$__h_dir/../../hooks/lib/action-normalize.sh"
fi
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
  _se_prepare_toolchain_shims "$ACTION_CWD"
  FILE_DIR=$(dirname "$FILE_PATH")

# --- JS / TS ---
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx)
    SE_LINTER_KIND="" SE_LINTER_DIR="" SE_LINTER_BIN="" SE_LINTER_FILE=""
    SE_ESLINT_DIR="" SE_ESLINT_BIN="" SE_ESLINT_FILE=""
    if _se_find_js_linter "$FILE_PATH"; then
      case "$SE_LINTER_KIND" in
        oxlint)
          if [ -n "$SE_LINTER_BIN" ]; then
            OUT=$(cd "$SE_LINTER_DIR" && "$SE_LINTER_BIN" --quiet "$SE_LINTER_FILE" 2>&1)
            if [ $? -ne 0 ]; then
              ERRORS="${ERRORS}oxlint: ${FILE_PATH}
${OUT}

"
            fi
          else
            echo "post-edit-verify: oxlint not found on PATH; JS/TS lint skipped for ${FILE_PATH}" >&2
          fi
          ;;
        biome)
          if [ -n "$SE_LINTER_BIN" ]; then
            OUT=$(cd "$SE_LINTER_DIR" && "$SE_LINTER_BIN" check "$SE_LINTER_FILE" 2>&1)
            if [ $? -ne 0 ]; then
              ERRORS="${ERRORS}biome: ${FILE_PATH}
${OUT}

"
            fi
          else
            echo "post-edit-verify: biome not found on PATH; JS/TS lint skipped for ${FILE_PATH}" >&2
          fi
          ;;
        eslint)
          ESLINT=()
          if [ -n "$SE_ESLINT_BIN" ]; then
            ESLINT=("$SE_ESLINT_BIN")
          elif command -v npx >/dev/null 2>&1 && (cd "$SE_ESLINT_DIR" && npx --no-install eslint --version >/dev/null 2>&1); then
            ESLINT=(npx --no-install eslint)
          fi
          if [ "${#ESLINT[@]}" -gt 0 ]; then
            OUT=$(cd "$SE_ESLINT_DIR" && "${ESLINT[@]}" --quiet "$SE_ESLINT_FILE" 2>&1)
            RC=$?
            # Preserve the existing opportunistic treatment of a broken install.
            if [ "$RC" -ne 0 ] && [ -n "$SE_ESLINT_BIN" ] &&
               ! (cd "$SE_ESLINT_DIR" && "$SE_ESLINT_BIN" --version >/dev/null 2>&1); then
              RC=0
            fi
            if [ "$RC" -ne 0 ]; then
              ERRORS="${ERRORS}eslint: ${FILE_PATH}
${OUT}

"
            fi
          else
            echo "post-edit-verify: eslint not found (no local install and no npx eslint on PATH); JS/TS lint skipped for ${FILE_PATH}" >&2
          fi
          ;;
      esac
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
    else
      echo "post-edit-verify: ruff not found on PATH; Python lint skipped for ${FILE_PATH}" >&2
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
    elif [ -f "Cargo.toml" ] && ! command -v cargo >/dev/null 2>&1; then
      echo "post-edit-verify: cargo not found on PATH; Rust lint skipped for ${FILE_PATH}" >&2
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
    else
      echo "post-edit-verify: neither golangci-lint nor go found on PATH; Go lint skipped for ${FILE_PATH}" >&2
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
  printf '%s\n' "$REASON" >&2
  exit 2
fi

exit 0
