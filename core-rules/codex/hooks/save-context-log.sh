#!/usr/bin/env bash
# save-context-log.sh — Codex Stop. Dumps a session summary to context-log.md.
# Source: Software Engineering Core / core-rules / codex hooks.
#
# Contract:
#   - Runs on Stop because Codex does not expose the Claude PreCompact event.
#   - Writes (overwrites) context-log.md in the project root with:
#     branch, files touched this session, open todos, last two user asks,
#     last two assistant decisions.
#   - Side effect is the file write. No stdout needed. Never blocks.
#
# Dependencies: jq (required), git (optional).
#
# Status: new in this core-rules layer.
#
# Note: when the event payload exposes a `transcript_path`, we parse it for
# user/assistant messages. Todo state is checked in both Codex and Claude
# locations when present.

set -u

INPUT=$(cat 2>/dev/null || true)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "save-context-log: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "save-context-log"

# --- Envelope validation: PROJECT_DIR must be a directory; transcript_path,
# if present, must exist. A malformed envelope errors loudly to stderr instead
# of silently writing a meaningless context-log.
PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
  echo "save-context-log: PROJECT_DIR not a directory ('$PROJECT_DIR') — malformed envelope; skipping" >&2
  exit 1
fi
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
if [ -n "$TRANSCRIPT" ] && [ ! -f "$TRANSCRIPT" ]; then
  echo "save-context-log: transcript_path '$TRANSCRIPT' does not exist — malformed envelope; skipping" >&2
  exit 1
fi

OUT="${PROJECT_DIR}/context-log.md"

{
  printf '# Context log\n'
  printf '_Saved: %s_\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # --- Branch ---
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    printf '## Branch\n%s\n\n' "$BRANCH"
  fi

  # --- Files touched this session ---
  # Best-effort: list files edited vs HEAD plus untracked.
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    TOUCHED=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | awk '{print $2}' | head -40)
    if [ -n "$TOUCHED" ]; then
      printf '## Files touched\n```\n%s\n```\n\n' "$TOUCHED"
    fi
  fi

  # --- Open todos ---
  TODOS_FILE="${TODOS_FILE:-}"
  if [ -z "$TODOS_FILE" ]; then
    if [ -f "${PROJECT_DIR}/.codex/todos.json" ]; then
      TODOS_FILE="${PROJECT_DIR}/.codex/todos.json"
    else
      TODOS_FILE="${PROJECT_DIR}/.claude/todos.json"
    fi
  fi
  if [ -f "$TODOS_FILE" ]; then
    OPEN=$(jq -r '
      (.. | objects | select(.status? == "in_progress" or .status? == "pending"))
      | "- [\(.status)] \(.content // .task // "?")"
    ' "$TODOS_FILE" 2>/dev/null | head -20)
    if [ -n "$OPEN" ]; then
      printf '## Open todos\n%s\n\n' "$OPEN"
    fi
  fi

  # --- Last two user asks and assistant decisions from the transcript ---
  # Real user prompts have .message.content as a string. Tool-result wrappers
  # have .type == "user" but .message.content is an array of objects whose
  # .type is "tool_result" — those must NOT be treated as user input.
  # Real assistant decisions have .message.content as an array of text blocks;
  # extract .text from blocks where .type == "text".
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    USER_MSGS=$(jq -r 'select(.type == "user" and (.message.content | type) == "string") | .message.content' "$TRANSCRIPT" 2>/dev/null \
                | tail -n 2)
    ASSISTANT_MSGS=$(jq -r 'select(.type == "assistant" and (.message.content | type) == "array") | .message.content | map(select(.type == "text") | .text) | join("\n")' "$TRANSCRIPT" 2>/dev/null \
                | tail -n 2)

    if [ -n "$USER_MSGS" ]; then
      printf '## Last user asks\n%s\n\n' "$USER_MSGS"
    fi
    if [ -n "$ASSISTANT_MSGS" ]; then
      printf '## Last assistant decisions\n%s\n\n' "$ASSISTANT_MSGS"
    fi
  fi
} > "$OUT" 2>/dev/null || true

exit 0
