#!/usr/bin/env bash
# wiki-skill-suggest.sh — Codex PostToolUse advisory for canonical-root gotchas.md.
#
# Twin of core-rules/hooks/wiki-skill-suggest.sh. Path decisions and advisory
# text are identical; only the output uses Codex's PostToolUse-specific envelope.
# Reads one tool event from stdin and accepts tool_input.file_path or
# tool_input.filePath. Every unavailable or malformed condition fails open and
# silently; this hook never reads wiki content, invokes a skill, or blocks.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
[ -f "$LIB_DIR/deps.sh" ] || exit 0
# shellcheck source=lib/deps.sh disable=SC1090
. "$LIB_DIR/deps.sh" 2>/dev/null || exit 0
type _se_repo_root >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
FILE_PATH=$(printf '%s' "$INPUT" | jq -er '
  .tool_input? | objects
  | [.file_path?, .filePath?]
  | map(select(type == "string" and length > 0))
  | .[0] // empty
  | select((contains("\u0000") or contains("\n") or contains("\r")) | not)
' 2>/dev/null) || exit 0

# Multiple envelopes (or any multi-line path) are not one valid hook event.
case "$FILE_PATH" in
  *$'\n'*|*$'\r'*) exit 0 ;;
esac

# A bare basename is ambiguous outside its envelope's working directory. Require
# either an absolute path or an explicit relative path containing a separator.
case "$FILE_PATH" in
  /*|*/*) ;;
  *) exit 0 ;;
esac

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
[ -d "$PROJECT_DIR" ] || exit 0

git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR" 2>/dev/null) || exit 0
[ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ] || exit 0

case "$FILE_PATH" in
  /*) TARGET_PATH="$FILE_PATH" ;;
  *)  TARGET_PATH="$PROJECT_DIR/$FILE_PATH" ;;
esac

ROOT_GOTCHAS="$REPO_ROOT/gotchas.md"
[ -f "$ROOT_GOTCHAS" ] || exit 0
[ -f "$TARGET_PATH" ] || exit 0
[ "$TARGET_PATH" -ef "$ROOT_GOTCHAS" ] || exit 0

type _se_emit_hook_context >/dev/null 2>&1 || exit 0

MESSAGE='wiki-skill-suggest: project-root gotchas.md changed; consider running wiki-maintain explicitly for any qualifying procedure.'
_se_emit_hook_context "PostToolUse" "$MESSAGE" 2>/dev/null || :
exit 0
