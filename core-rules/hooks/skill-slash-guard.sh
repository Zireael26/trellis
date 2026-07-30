#!/usr/bin/env bash
# UserPromptExpansion(slash_command): deny oversized Skills before expansion.

set -u
INPUT=$(cat 2>/dev/null || true)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/skill-size.sh disable=SC1091
. "$HOOK_DIR/lib/skill-size.sh"
# shellcheck source=lib/skill-preload.sh disable=SC1091
. "$HOOK_DIR/lib/skill-preload.sh"

command -v jq >/dev/null 2>&1 || exit 0
if ! printf '%s' "$INPUT" | jq -e '
  .hook_event_name == "UserPromptExpansion"
  and .expansion_type == "slash_command"
  and (.command_name | type == "string")
  and (.command_name | length > 0)
' >/dev/null 2>&1; then
  exit 0
fi

SKILL_NAME=$(printf '%s' "$INPUT" | jq -r '.command_name')
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
USER_HOME="${HOME:-}"
[ -d "$PROJECT_DIR" ] && [ -d "$USER_HOME" ] || exit 0

REASON=$(skill_preload_check "$SKILL_NAME" "$PROJECT_DIR" "$USER_HOME")
STATUS=$?
[ "$STATUS" -eq 0 ] && exit 0

jq -nc --arg reason "$REASON" '{decision:"block",reason:$reason}'
exit 0
