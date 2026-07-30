#!/usr/bin/env bash
# SessionStart: advisory-only scan for oversized and ambiguous Skill roots.

set -u
INPUT=$(cat 2>/dev/null || true)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/skill-size.sh disable=SC1091
. "$HOOK_DIR/lib/skill-size.sh"
# shellcheck source=lib/skill-preload.sh disable=SC1091
. "$HOOK_DIR/lib/skill-preload.sh"

command -v jq >/dev/null 2>&1 || exit 0
if ! printf '%s' "$INPUT" | jq -e '
  .hook_event_name == "SessionStart"
  and ((.source // "startup") == "startup" or (.source // "startup") == "resume")
' >/dev/null 2>&1; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
USER_HOME="${HOME:-}"
[ -d "$PROJECT_DIR" ] && [ -d "$USER_HOME" ] || exit 0

ROOTS=$(skill_size_discover_roots "$PROJECT_DIR" "$USER_HOME" 2>/dev/null) || exit 0
[ -n "$ROOTS" ] || exit 0

WARNINGS=""
SEEN_NAMES=""
while IFS= read -r root; do
  [ -n "$root" ] || continue
  name="${root##*/}"
  bytes=$(skill_size_manifest_bytes "$root" 2>/dev/null) || continue
  if [ "$bytes" -gt "$SKILL_SIZE_BUDGET_BYTES" ]; then
    owner=$(skill_preload_owner "$root" "$PROJECT_DIR" "$USER_HOME")
    WARNINGS="${WARNINGS}- oversized: '${name}' (${root}, owner=${owner}, bytes=${bytes}, budget=${SKILL_SIZE_BUDGET_BYTES})
"
  fi

  identities="$name"
  declared=$(skill_size__declared_name "$root" 2>/dev/null || true)
  if [ -n "$declared" ] && [ "$declared" != "$name" ]; then
    identities="${identities}
${declared}"
  fi
  while IFS= read -r identity; do
    [ -n "$identity" ] || continue
    case "
$SEEN_NAMES
" in
      *"
$identity
"*) continue ;;
    esac
    SEEN_NAMES="${SEEN_NAMES}${SEEN_NAMES:+
}${identity}"
    skill_size_resolve_root "$identity" "$PROJECT_DIR" "$USER_HOME" >/dev/null 2>&1
    resolve_status=$?
    if [ "$resolve_status" -eq 2 ]; then
      WARNINGS="${WARNINGS}- ambiguous: '${identity}' resolves to multiple discoverable roots; invocation will be denied
"
    fi
  done <<< "$identities"
done <<< "$ROOTS"

[ -n "$WARNINGS" ] || exit 0
CONTEXT="Skill pre-load safety advisory (warning only at SessionStart):
${WARNINGS}Oversized or ambiguous Skill invocations are denied before SKILL.md body load."

jq -nc --arg ctx "$CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
exit 0
