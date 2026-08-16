#!/usr/bin/env bash
# Shared forward-only validator for high-autonomy decision receipts.
# Sourced by the Claude/Codex wrappers and executed through the same canonical
# Claude hook path by OMP. Bash 3.2 compatible; never writes decisions-log.md.

_dr_block() {
  local reason="$1"
  jq -nc --arg reason "decision-receipt: ${reason}" '{decision: "block", reason: $reason}'
  exit 2
}

_dr_turn_text() {
  local transcript="$1"
  jq -Rrs '
    def role:
      (.message.role // .role // .payload.message.role // .payload.role
       // (if .type == "assistant" or .type == "user" then .type else "" end));
    def text:
      (.message.content // .content // .payload.message.content // .payload.content // "") as $content
      | if ($content | type) == "string" then $content
        elif ($content | type) == "array" then
          [$content[]?
            | if type == "string" then .
              elif type == "object" then (.text // .content // empty)
              else empty
              end
            | select(type == "string")]
          | join("\n")
        else ""
        end;
    reduce (split("\n")[] | fromjson? // empty) as $item
      ({assistant: []};
       if ($item | role) == "user" then .assistant = []
       elif ($item | role) == "assistant" then .assistant += [($item | text)]
       else .
       end)
    | .assistant
    | join("\n")
  ' "$transcript" 2>/dev/null
}

_dr_validate_entry() {
  local entry="$1" level="$2" expected_date="$3" decisions_log="$4"
  local kind

  printf '%s\n' "$entry" | grep -Eq "^- ${expected_date}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z \\[L${level}\\] \\[(interpretation|pattern|scope|architectural)\\] [[:space:]]*[^[:space:]].*\\. Reasoning: [[:space:]]*[^[:space:]].*\\. Alternatives considered: [[:space:]]*[^[:space:]].*\\.( SURFACED INLINE)?$" \
    || _dr_block "malformed decision entry; use the canonical timestamped one-line format"

  kind=$(printf '%s\n' "$entry" | sed -E 's/^- [^ ]+ \[L[1-5]\] \[([^]]+)\].*/\1/')
  case "$kind" in
    architectural)
      case "$entry" in
        *" SURFACED INLINE") ;;
        *) _dr_block "architectural decision entry is missing SURFACED INLINE" ;;
      esac
      ;;
    *)
      case "$entry" in
        *" SURFACED INLINE") _dr_block "SURFACED INLINE is reserved for architectural decision entries" ;;
      esac
      ;;
  esac

  grep -Fqx -- "$entry" "$decisions_log" \
    || _dr_block "rendered decision entry is absent from canonical-root decisions-log.md"
}

decision_receipt_run() {
  local lib_dir deps_lib autonomy_lib input stop_active project_dir repo_root
  local transcript transcript_text last_message turn_text receipt_text dirty
  local heading all_headings exact_headings block entries entry_count today entry

  lib_dir=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  deps_lib="$lib_dir/deps.sh"
  autonomy_lib="$lib_dir/autonomy.sh"
  [ -f "$deps_lib" ] || { echo "decision-receipt: missing sibling lib at $deps_lib — re-run sync-hooks" >&2; exit 1; }
  [ -f "$autonomy_lib" ] || { echo "decision-receipt: missing sibling lib at $autonomy_lib — re-run sync-hooks" >&2; exit 1; }
  # shellcheck source=lib/deps.sh disable=SC1090,SC1091
  . "$deps_lib"
  # shellcheck source=lib/autonomy.sh disable=SC1090,SC1091
  . "$autonomy_lib"
  _se_require_jq "decision-receipt"

  input=$(cat 2>/dev/null || true)
  stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || true)
  [ "$stop_active" = "true" ] && exit 0

  project_dir=$(_se_project_dir)
  [ -d "$project_dir" ] || _dr_block "project directory is unavailable"
  repo_root=$(_se_repo_root "$project_dir")
  _se_resolve_autonomy "$repo_root"
  [ "$AUTONOMY_LEVEL" -ge 4 ] || exit 0

  last_message=$(printf '%s' "$input" | jq -r '
    def text:
      if type == "string" then .
      elif type == "object" then
        (.content // .text // "") as $content
        | if ($content | type) == "string" then $content
          elif ($content | type) == "array" then
            [$content[]? | if type == "string" then . elif type == "object" then (.text // .content // empty) else empty end]
            | map(select(type == "string"))
            | join("\n")
          else ""
          end
      else ""
      end;
    (.last_assistant_message // "") | text
  ' 2>/dev/null || true)
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then transcript="${CLAUDE_TRANSCRIPT_PATH:-}"; fi
  transcript_text=""
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    transcript_text=$(_dr_turn_text "$transcript") || _dr_block "current-turn transcript could not be parsed"
  fi
  turn_text="$last_message"
  [ -n "$turn_text" ] || turn_text="$transcript_text"
  receipt_text=$(printf '%s\n%s\n' "$last_message" "$transcript_text")

  dirty=$(git -C "$project_dir" status --porcelain 2>/dev/null || true)
  if [ -z "$dirty" ] && ! printf '%s\n' "$receipt_text" | grep -Eq '<!-- dod-receipt .*cmd=.*exit=[0-9].*diff=.*\+[0-9].*-->'; then
    exit 0
  fi

  [ -n "$turn_text" ] || _dr_block "substantive L${AUTONOMY_LEVEL} turn has no readable assistant message or transcript"
  heading="## Decisions made (L${AUTONOMY_LEVEL})"
  all_headings=$(printf '%s\n' "$turn_text" | grep -Ec '^## Decisions made \(L[1-5]\)$' || true)
  exact_headings=$(printf '%s\n' "$turn_text" | grep -Fxc "$heading" || true)
  if [ "$exact_headings" -ne 1 ]; then
    if [ "$all_headings" -gt 0 ]; then
      _dr_block "decision block level does not match resolved L${AUTONOMY_LEVEL}"
    fi
    _dr_block "substantive L${AUTONOMY_LEVEL} turn requires exactly one '${heading}' block"
  fi
  [ "$all_headings" -eq 1 ] \
    || _dr_block "turn contains multiple or cross-level decision blocks"

  block=$(printf '%s\n' "$turn_text" | awk -v heading="$heading" '
    $0 == heading { in_block = 1; next }
    in_block && /^## / { exit }
    in_block { print }
  ')
  entries=$(printf '%s\n' "$block" | sed '/^[[:space:]]*$/d')
  [ -n "$entries" ] || _dr_block "decision block contains no entries"

  entry_count=$(printf '%s\n' "$entries" | grep -c '^-' || true)
  [ "$entry_count" -eq "$(printf '%s\n' "$entries" | grep -c '^' || true)" ] \
    || _dr_block "decision block may contain only canonical one-line entries"

  [ -f "$repo_root/decisions-log.md" ] || _dr_block "canonical-root decisions-log.md is missing"
  today=$(date -u '+%Y-%m-%d')
  while IFS= read -r entry; do
    _dr_validate_entry "$entry" "$AUTONOMY_LEVEL" "$today" "$repo_root/decisions-log.md"
  done <<EOF
$entries
EOF
}
