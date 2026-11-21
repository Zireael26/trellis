#!/usr/bin/env bash
# Shared forward-only validator for high-autonomy decision receipts.
# Sourced by the Claude/Codex wrappers. Bash 3.2 compatible; never writes
# decisions-log.md.

_dr_infrastructure_block() {
  echo "decision-receipt: $1" >&2
  exit 2
}

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
       // (if .type == "assistant" or .type == "user" then .type
           elif .type == "USER_INPUT" then "user"
           elif .type == "PLANNER_RESPONSE" then "assistant"
           else "" end));
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

# decision_receipt_run <claude|codex|pi> — the harness actually running.
decision_receipt_run() {
  local harness="$1"
  local lib_dir deps_lib autonomy_lib input stop_active project_dir repo_root
  local transcript transcript_text last_message turn_text receipt_text dirty
  local session_id transcript_path_raw _dr_key _dr_sdir _dr_baseline_ok _dr_head_moved
  local _dr_f _dr_lines _dr_hs _dr_heads _dr_current
  local _dr_armed _dr_sel
  local heading all_headings exact_headings block entries entry_count today entry

  lib_dir=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || _dr_infrastructure_block "library directory unavailable"
  deps_lib="$lib_dir/deps.sh"
  autonomy_lib="$lib_dir/autonomy.sh"
  [ -r "$deps_lib" ] || _dr_infrastructure_block "missing sibling lib at $deps_lib — re-run sync-hooks"
  [ -r "$autonomy_lib" ] || _dr_infrastructure_block "missing sibling lib at $autonomy_lib — re-run sync-hooks"
  # shellcheck source=lib/deps.sh disable=SC1090,SC1091
  . "$deps_lib" || _dr_infrastructure_block "unable to load $deps_lib — re-run sync-hooks"
  _se_load_heavy || _dr_infrastructure_block "unable to load deps-heavy.sh beside $deps_lib — re-run sync-hooks"
  # shellcheck source=lib/autonomy.sh disable=SC1090,SC1091
  . "$autonomy_lib" || _dr_infrastructure_block "unable to load $autonomy_lib — re-run sync-hooks"
  # Mandatory policy cannot become a warning-only no-op through degradation.
  if ! command -v jq >/dev/null 2>&1; then
    _dr_infrastructure_block "jq required but not found — install jq (brew install jq | apt-get install -y jq)"
  fi
  _se_require_jq "decision-receipt"
  case "$harness" in claude|codex|pi|antigravity) ;; *) _dr_infrastructure_block "unknown harness '$harness' — re-run sync-hooks" ;; esac

  input=$(cat 2>/dev/null || true)
  stop_active=$(printf '%s' "$input" | jq -ers '
    if length != 1 or (.[0] | type != "object") then error("invalid Stop envelope")
    else .[0] | if has("stop_hook_active") then
      if (.stop_hook_active | type) == "boolean" then .stop_hook_active | tostring
      else error("stop_hook_active must be a JSON Boolean") end
    elif has("continuationActive") then
      if (.continuationActive | type) == "boolean" then .continuationActive | tostring
      else error("continuationActive must be a JSON Boolean") end
    else "false" end end' 2>/dev/null) \
    || _dr_block "invalid Stop envelope: stop_hook_active must be a JSON Boolean"
  [ "$stop_active" = "true" ] && exit 0

  project_dir=$(_se_project_dir)
  [ -d "$project_dir" ] || _dr_block "project directory is unavailable"
  repo_root=$(_se_repo_root "$project_dir")
  # A malformed canonical policy cannot suppress a legacy/runtime L4 value
  # and silently turn this independent mandatory member into an L3 no-op.
  if [ -e "$repo_root/.trellis.json" ] || [ -L "$repo_root/.trellis.json" ]; then
    # Field-level portable schema: legacy partial manifests remain valid, and
    # syntax-valid preset names may be proven absent in the selected release.
    jq -es '
      def autonomy_ok:
        if has("autonomy") then
          .autonomy | if type == "number" then . >= 1 and . <= 5 and floor == . else false end
        else true end;
      def presets_ok:
        if has("presets") then .presets as $p |
          if ($p | type) != "array" then false
          else ($p | length) == ($p | unique | length)
            and all($p[]; if type == "string" then
              length >= 2 and length <= 64 and test("^[a-z0-9][a-z0-9-]*[a-z0-9]$")
              else false end)
          end
        else true end;
      length == 1 and (.[0] | if type == "object" then autonomy_ok and presets_ok else false end)
    ' "$repo_root/.trellis.json" >/dev/null 2>&1 \
      || _dr_block "canonical autonomy policy .trellis.json is present but malformed or unreadable (autonomy/presets schema)"
  fi
  _se_resolve_autonomy "$repo_root" || _dr_block "cannot resolve project autonomy policy"
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
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null || true)
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then transcript="${CLAUDE_TRANSCRIPT_PATH:-}"; fi
  transcript_text=""
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    transcript_text=$(_dr_turn_text "$transcript") || _dr_block "current-turn transcript could not be parsed"
  fi
  turn_text="$last_message"
  [ -n "$turn_text" ] || turn_text="$transcript_text"
  receipt_text=$(printf '%s\n%s\n' "$last_message" "$transcript_text")

  session_id=$(printf '%s' "$input" | jq -r '.session_id // .conversationId // empty' 2>/dev/null || true)
  transcript_path_raw=$(printf '%s' "$input" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null || true)
  _dr_baseline_ok=0
  _dr_head_moved=1
  # Armed only by the running harness's own turn-baseline registration. Pi
  # runs no turn-baseline, so it keeps the unarmed trigger.
  _dr_armed=0
  case "$harness" in
    claude|codex|antigravity) _se_turn_baseline_armed "$project_dir" "$harness" 2>/dev/null && _dr_armed=1 ;;
  esac
  if [ "$_dr_armed" -eq 0 ]; then
    _dr_baseline_ok=1
    _dr_head_moved=0
  else
    _dr_key=$(_se_state_key "$transcript_path_raw" "$session_id" 2>/dev/null) || _dr_key=""
    _dr_sdir=$(_se_turn_state_dir "$project_dir" 2>/dev/null) || _dr_sdir=""
    if [ -n "$_dr_key" ] && [ -n "$_dr_sdir" ]; then
      _dr_heads=""
      # turn-start is never checked against nonces.log: stop-verify consumes
      # those entries at every Stop, in parallel with this hook.
      _dr_f="$_dr_sdir/turn-start.$harness.$_dr_key"
      if [ -f "$_dr_f" ] && [ ! -L "$_dr_f" ] \
         && _dr_lines=$(cat "$_dr_f" 2>/dev/null) \
         && _dr_sel=$(_se_turn_baseline_select "$_dr_lines" 2>/dev/null) && [ -n "$_dr_sel" ] \
         && ! printf '%s\n' "$_dr_sel" | grep -Evq '^trellis-turn-(baseline|carry) v2 [0-9a-f]{32} (unborn|[0-9a-f]{40}|[0-9a-f]{64}) [0-9a-f]{64}$' \
         && _dr_hs=$(printf '%s\n' "$_dr_sel" | awk '{print $4}' | sort -u) && [ -n "$_dr_hs" ]; then
        _dr_baseline_ok=1
        _dr_heads="$_dr_hs"
      fi
      if [ "$_dr_baseline_ok" -eq 1 ]; then
        _dr_current=$(git -C "$project_dir" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || _dr_current=""
        [ -n "$_dr_current" ] || _dr_current="unborn"
        if printf '%s\n' "$_dr_heads" | grep -qxF -- "$_dr_current" 2>/dev/null; then
          _dr_head_moved=0
        fi
      fi
    fi
  fi

  dirty=$(git -C "$project_dir" status --porcelain 2>/dev/null) \
    || _dr_block "cannot determine git status for project directory"
  if [ "$_dr_baseline_ok" -eq 1 ] && [ "$_dr_head_moved" -eq 0 ] && [ -z "$dirty" ] && ! printf '%s\n' "$receipt_text" | grep -Eq '<!-- dod-receipt .*cmd=.*exit=[0-9].*diff=.*\+[0-9].*-->'; then
    exit 0
  fi

  # Voluntary decision logging (v1.5.3): L4/L5 turns do not force a performative
  # decision block when no consequential decision was taken. When the agent does
  # emit a `## Decisions made (L<n>)` block, validate its level, format, and
  # presence in canonical-root decisions-log.md.
  [ -n "$turn_text" ] || exit 0
  heading="## Decisions made (L${AUTONOMY_LEVEL})"
  all_headings=$(printf '%s\n' "$turn_text" | grep -Ec '^## Decisions made \(L[1-5]\)[[:blank:]]*$' || true)
  [ "$all_headings" -eq 0 ] && exit 0
  exact_headings=$(printf '%s\n' "$turn_text" | sed -E 's/[[:blank:]]+$//' | grep -Fxc "$heading" || true)
  if [ "$exact_headings" -ne 1 ]; then
    if [ "$all_headings" -gt 0 ]; then
      _dr_block "decision block level does not match resolved L${AUTONOMY_LEVEL}"
    fi
  fi
  [ "$all_headings" -eq 1 ] \
    || _dr_block "turn contains multiple or cross-level decision blocks"

  block=$(printf '%s\n' "$turn_text" | awk -v heading="$heading" '
    { sub(/[[:blank:]]+$/, "", $0) }
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
