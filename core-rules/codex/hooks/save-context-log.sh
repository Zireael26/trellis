#!/usr/bin/env bash
# save-context-log.sh — Codex Stop. Dumps a session summary to context-log.md.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Runs on Stop because Codex does not expose the Claude PreCompact event.
#   - Writes (overwrites) context-log.md at the canonical project root with:
#     branch, files touched this session, open todos, last two user asks,
#     last two assistant decisions.
#   - Storage path is resolved via `git rev-parse --git-common-dir` so the
#     log lives in the main checkout even when Codex is operating inside a
#     worktree. Worktree cleanup no longer destroys the log.
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
# Malformed JSON envelope must return 1 before any write.
TRANSCRIPT=""
if [ -n "$INPUT" ]; then
  _trimmed=$(printf '%s' "$INPUT" | tr -d '[:space:]')
  if [ -n "$_trimmed" ]; then
    if ! printf '%s' "$INPUT" | jq -e . >/dev/null; then
      echo "save-context-log: malformed envelope JSON — parse error; skipping" >&2
      exit 1
    fi
    TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
    _jq_status=$?
    if [ $_jq_status -ne 0 ]; then
      echo "save-context-log: malformed envelope JSON — parse error; skipping" >&2
      exit 1
    fi
  fi
fi
if [ -n "$TRANSCRIPT" ] && [ ! -f "$TRANSCRIPT" ]; then
  echo "save-context-log: transcript_path '$TRANSCRIPT' does not exist — malformed envelope; skipping" >&2
  exit 1
fi

# Resolve to the canonical repo root — survives worktree cleanup. Falls back
# to PROJECT_DIR outside a git repo (no worktree concern there).
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")

OUT="${REPO_ROOT}/context-log.md"
TMPDIR=""
_TMPDIR_MK=$(mktemp -d "${OUT}.tmp.XXXXXX" 2>&1)
_TMPDIR_STATUS=$?
if [ $_TMPDIR_STATUS -ne 0 ] || [ -z "$_TMPDIR_MK" ]; then
  echo "save-context-log: failed to create temp directory for $OUT — $_TMPDIR_MK" >&2
  exit 0
fi
TMPDIR="$_TMPDIR_MK"
TMP_OUT="${TMPDIR}/context-log.tmp"
_porcelain_tmp="${TMPDIR}/porcelain.tmp"
_todos_out="${TMPDIR}/todos_out.tmp"
_todos_err="${TMPDIR}/todos_err.tmp"
_user_out="${TMPDIR}/user_out.tmp"
_user_err="${TMPDIR}/user_err.tmp"
_assist_out="${TMPDIR}/assist_out.tmp"
_assist_err="${TMPDIR}/assist_err.tmp"

{
  printf '# Context log\n'
  printf '_Saved: %s_\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # --- Branch ---
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    printf '## Branch\n%s\n\n' "$BRANCH"
  fi

  # --- Files touched this session ---
  # Best-effort: list files edited vs HEAD plus untracked, NUL-delimited to preserve spaces and renames.
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" status --porcelain -z >"$_porcelain_tmp" 2>&1
    _git_status=$?
    if [ $_git_status -eq 0 ]; then
      _touched_entries=""
      _count=0
      _prev_status=""
      _prev_path=""
      while IFS= read -r -d '' _entry; do
        if [ -z "$_entry" ]; then
          continue
        fi
        case "$_entry" in
          *context-log.md.tmp.*) continue ;;
        esac
        case "$_prev_status" in
          R*|C*)
            _old="$_entry"
            _new="$_prev_path"
            _touched_entries="${_touched_entries}${_old} -> ${_new}
"
            _count=$((_count + 1))
            _prev_status=""
            _prev_path=""
            ;;
          *)
            _status=$(printf '%s' "$_entry" | cut -c1-2)
            _path=$(printf '%s' "$_entry" | cut -c4-)
            case "$_status" in
              R*|C*)
                _prev_status="$_status"
                _prev_path="$_path"
                ;;
              *)
                _touched_entries="${_touched_entries}${_path}
"
                _count=$((_count + 1))
                ;;
            esac
            ;;
        esac
        if [ $_count -ge 40 ]; then
          break
        fi
      done < "$_porcelain_tmp"
      if [ -n "$_prev_status" ] && [ -n "$_prev_path" ]; then
        _touched_entries="${_touched_entries}${_prev_path}
"
      fi
      TOUCHED=$(printf '%s' "$_touched_entries" | head -40)
      if [ -n "$TOUCHED" ]; then
        printf '## Files touched\n```\n%s\n```\n\n' "$TOUCHED"
      fi
    fi
    rm -f "$_porcelain_tmp"
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
    if jq -r '
      (.. | objects | select(.status? == "in_progress" or .status? == "pending"))
      | "- [\(.status)] \(.content // .task // "?")"
    ' "$TODOS_FILE" >"$_todos_out" 2>"$_todos_err"; then
      OPEN=$(head -20 "$_todos_out")
      if [ -n "$OPEN" ]; then
        printf '## Open todos\n%s\n\n' "$OPEN"
      fi
    else
      _todos_err_msg=$(head -n1 "$_todos_err")
      printf '## Open todos\n_todos.json malformed — %s_\n\n' "$_todos_err_msg"
      echo "save-context-log: todos.json malformed — $_todos_err_msg" >&2
    fi
    rm -f "$_todos_out" "$_todos_err"
  fi

  # --- Last two user asks and assistant decisions from the transcript ---
  # Real user prompts have .message.content as a string. Tool-result wrappers
  # have .type == "user" but .message.content is an array of objects whose
  # .type is "tool_result" — those must NOT be treated as user input.
  # Real assistant decisions have .message.content as an array of text blocks;
  # extract .text from blocks where .type == "text".
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    if jq -s -r '[ .[] | select(.type == "user" and (.message.content | type) == "string") | .message.content ] | .[-2:][]' "$TRANSCRIPT" >"$_user_out" 2>"$_user_err"; then
      USER_MSGS=$(cat "$_user_out")
      if [ -n "$USER_MSGS" ]; then
        printf '## Last user asks\n%s\n\n' "$USER_MSGS"
      fi
    else
      _user_err_msg=$(head -n1 "$_user_err")
      printf '## Last user asks\n_transcript malformed — %s_\n\n' "$_user_err_msg"
      echo "save-context-log: transcript malformed — $_user_err_msg" >&2
    fi
    rm -f "$_user_out" "$_user_err"
    if jq -s -r '[ .[] | select(.type == "assistant" and (.message.content | type) == "array") | .message.content | map(select(.type == "text") | .text) | join("\n") ] | .[-2:][]' "$TRANSCRIPT" >"$_assist_out" 2>"$_assist_err"; then
      ASSISTANT_MSGS=$(cat "$_assist_out")
      if [ -n "$ASSISTANT_MSGS" ]; then
        printf '## Last assistant decisions\n%s\n\n' "$ASSISTANT_MSGS"
      fi
    else
      _assist_err_msg=$(head -n1 "$_assist_err")
      printf '## Last assistant decisions\n_transcript malformed — %s_\n\n' "$_assist_err_msg"
      echo "save-context-log: transcript malformed — $_assist_err_msg" >&2
    fi
    rm -f "$_assist_out" "$_assist_err"
  fi
} > "$TMP_OUT"
_WRITE_STATUS=$?
if [ $_WRITE_STATUS -ne 0 ]; then
  echo "save-context-log: failed to write temp file $TMP_OUT — write error $_WRITE_STATUS" >&2
  rm -rf "${TMPDIR:?}"
  exit 0
fi

_MV_OUT=$(mv "$TMP_OUT" "$OUT" 2>&1)
_MV_STATUS=$?
if [ $_MV_STATUS -ne 0 ]; then
  echo "save-context-log: failed to rename temp file to $OUT — $_MV_OUT" >&2
  rm -rf "${TMPDIR:?}"
  exit 0
fi

rm -rf "${TMPDIR:?}"
exit 0
