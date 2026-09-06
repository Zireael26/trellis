#!/usr/bin/env bash
# wiki-skill-suggest.sh — Codex PostToolUse advisory for canonical-root gotchas.md.
#
# Twin of core-rules/hooks/wiki-skill-suggest.sh. Path decisions and advisory
# text are identical; only the output uses Codex's PostToolUse-specific envelope.
# Reads one tool event and normalizes every declared mutation target. Missing
# jq or git emits one stderr degradation notice and
# exits zero; every other unavailable or malformed condition fails open silently.
# This hook never reads wiki content, invokes a skill, or blocks.

set -u

command -v jq >/dev/null 2>&1 || { printf '%s\n' 'wiki-skill-suggest: jq not found; degrading to no-op' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf '%s\n' 'wiki-skill-suggest: git not found; degrading to no-op' >&2; exit 0; }

LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
[ -f "$LIB_DIR/deps.sh" ] || exit 0
# shellcheck source=lib/deps.sh disable=SC1090
. "$LIB_DIR/deps.sh" 2>/dev/null || exit 0
type _se_repo_root >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
__ta_lib="$LIB_DIR/action-normalize.sh"
[ -f "$__ta_lib" ] || __ta_lib="$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib/action-normalize.sh"
[ -f "$__ta_lib" ] || exit 0
# shellcheck source=../../hooks/lib/action-normalize.sh disable=SC1090
. "$__ta_lib"

NORMALIZED=$(_ta_normalize_action codex post_action "$INPUT") || exit 0
[ "$(printf '%s' "$NORMALIZED" | jq -r '.action.family')" = "file_mutation" ] || exit 0
[ "$(printf '%s' "$NORMALIZED" | jq -r '.result.status')" != "failed" ] || exit 0

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
[ -d "$PROJECT_DIR" ] || exit 0

git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR" 2>/dev/null) || exit 0
[ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ] || exit 0

ROOT_GOTCHAS="$REPO_ROOT/gotchas.md"
[ -f "$ROOT_GOTCHAS" ] || exit 0

ACTION_CWD=$(printf '%s' "$NORMALIZED" | jq -r '.cwd // empty')
[ -d "$ACTION_CWD" ] || ACTION_CWD="$PROJECT_DIR"
NATIVE_CWD=$(printf '%s' "$NORMALIZED" | jq -r '.cwd // empty')
MATCHED=0
while IFS=$'\t' read -r OPERATION SOURCE_PATH DESTINATION; do
  case "$OPERATION" in
    delete) continue ;;
    rename) FILE_PATH="$DESTINATION" ;;
    create|update) FILE_PATH="$SOURCE_PATH" ;;
    *) continue ;;
  esac
  # Legacy path-only envelopes gave no reliable base for a bare basename.
  # Native events carry cwd, so their root-level apply_patch targets are safe.
  case "$FILE_PATH" in
    */*) ;;
    *) [ -n "$NATIVE_CWD" ] || continue ;;
  esac
  TARGET_PATH=$(_ta_resolve_path "$ACTION_CWD" "$FILE_PATH") || continue
  [ -f "$TARGET_PATH" ] || continue
  if [ "$TARGET_PATH" -ef "$ROOT_GOTCHAS" ]; then
    MATCHED=1
    break
  fi
done < <(_ta_targets_tsv "$NORMALIZED")
[ "$MATCHED" -eq 1 ] || exit 0

type _se_emit_hook_context >/dev/null 2>&1 || exit 0

MESSAGE='wiki-skill-suggest: project-root gotchas.md changed; consider running wiki-maintain explicitly for any qualifying procedure.'
_se_emit_hook_context "PostToolUse" "$MESSAGE" 2>/dev/null || :
exit 0
