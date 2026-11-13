#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
# spec-gate.sh — mandatory-pipeline gate (spec 006). Two modes:
#   --gate  : harness-neutral CLI for the pre-push hook (the LOAD-BEARING teeth).
#             Prints the remedy on a block and exits 1; else exits 0.
#   (hook)  : Codex Stop hook early-warning. On a block verdict it emits
#             Codex block JSON on stdout + exit 0; otherwise exit 0.
#
# Both modes call the SAME pure verdict engine (`spec-gate-core.sh`) as the
# Claude twin. Only the harness-facing Stop exit contract differs; the
# deterministic state decides, not the model.

# The core resolves from this script's own resolved directory, never the caller's
# cwd (spec 055 R1.1). A deployed hooks dir carries it as a sibling. Run in place
# from the payload, core-rules/codex/hooks/lib/ does not, so the fallback to the
# shared core-rules/hooks/lib/ applies only when this directory IS the declared
# runtime's Codex tree. A project path that merely ends in core-rules/codex/hooks
# gets no fallback, so it can never source a project-controlled file.
# Codex Stop block contract: stdout JSON on exit 0 (exit 2 needs a stderr prompt).
# Set outside the shared prefix below.
_SG_STOP_BLOCK_EXIT=0
_SG_HARNESS=codex
[ "${TRELLIS_HARNESS:-codex}" = "pi" ] && _SG_HARNESS=pi
DIR=$(unset CDPATH; cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
_sg_rt=$(unset CDPATH; [ -n "${TRELLIS_ROOT:-}" ] && cd -P -- "$TRELLIS_ROOT" 2>/dev/null && pwd -P)
_sg_core="$DIR/lib/spec-gate-core.sh"
if [ ! -f "$_sg_core" ] && [ -n "$_sg_rt" ] && [ "$DIR" = "$_sg_rt/core-rules/codex/hooks" ]; then
  _sg_core="$DIR/../../hooks/lib/spec-gate-core.sh"
fi
# A missing, broken, or protocol-invalid engine is not an advisory verdict.
_sg_cli_mode="${1:-}"
_sg_input=''
[ -n "$_sg_cli_mode" ] || _sg_input=$(cat 2>/dev/null || true)
# Same strict fallback as decision-receipt: a missing jq must not make a
# genuine reentrant Stop loop. Never execute a project/PATH Python shim.
_sg_trusted_python() {
  local candidate="$1" resolve resolved info uid mode magic root physical me
  [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
  if [ -x /bin/realpath ]; then resolve=/bin/realpath
  elif [ -x /usr/bin/realpath ]; then resolve=/usr/bin/realpath
  else return 1; fi
  resolved=$("$resolve" "$candidate" 2>/dev/null) || return 1
  for root in "${CLAUDE_PROJECT_DIR:-}" "${CODEX_PROJECT_DIR:-}" "$PWD"; do
    [ -n "$root" ] || continue
    physical=$("$resolve" "$root" 2>/dev/null) || continue
    if [ "$physical" = / ]; then
      if [ "$root" = "$PWD" ] && [ -n "${CLAUDE_PROJECT_DIR:-}${CODEX_PROJECT_DIR:-}" ] \
         && [ "${CLAUDE_PROJECT_DIR:-}" != "$root" ] && [ "${CODEX_PROJECT_DIR:-}" != "$root" ]; then continue; fi
      return 1
    fi
    case "$resolved/" in "$physical/"*) return 1 ;; esac
  done
  info=$(/usr/bin/stat -c '%u %a' "$resolved" 2>/dev/null) \
    || info=$(/usr/bin/stat -f '%u %Lp' "$resolved" 2>/dev/null) || return 1
  [[ "$info" =~ ^([0-9]+)[[:space:]]+([0-7]+)$ ]] || return 1
  uid=${BASH_REMATCH[1]}; mode=${BASH_REMATCH[2]}
  me=$(/usr/bin/id -u 2>/dev/null) || return 1
  [ "$uid" = 0 ] || [ "$uid" = "$me" ] || return 1
  [ "$((8#$mode & 022))" -eq 0 ] || return 1
  magic=$(/usr/bin/od -An -tx1 -N4 "$resolved" 2>/dev/null | /usr/bin/tr -d ' \n') || return 1
  case "$magic" in 7f454c46|cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca|cafebabf|bfbafeca) ;; *) return 1 ;; esac
  printf '%s' "$resolved"
}
_sg_stop_active_raw() {
  local rc candidate python selected=""
  if [ -x /usr/bin/perl ]; then
    ( unset PERL5OPT PERL5LIB PERLLIB PERL5DB
      printf '%s' "$1" | /usr/bin/perl -MJSON::PP -0777 -e '
        my $data = eval { decode_json(<STDIN>) };
        exit 1 if $@ || ref($data) ne "HASH";
        my $active = $data->{stop_hook_active};
        exit !(defined($active) && JSON::PP::is_bool($active) && $active);
      ' 2>/dev/null
    )
    rc=$?
    case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  fi
  selected=$(type -P python3 2>/dev/null) || selected=""
  for candidate in "$selected" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    python=$(_sg_trusted_python "$candidate") || continue
    printf '%s' "$1" | "$python" -I -c '
import json, sys
def reject_constant(_):
    raise ValueError("invalid JSON constant")
try:
    data = json.loads(sys.stdin.buffer.read().decode("utf-8"), parse_constant=reject_constant)
except (ValueError, UnicodeError, RecursionError):
    sys.exit(1)
sys.exit(0 if isinstance(data, dict) and data.get("stop_hook_active") is True else 1)
' 2>/dev/null
    rc=$?
    case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  done
  [ "$1" = '{"stop_hook_active":true}' ]
}
_sg_stop_active() {
  printf '%s' "$1" | jq -ers '
    if length != 1 or (.[0] | type != "object") then error("invalid Stop envelope")
    else .[0] | if has("stop_hook_active") then
      if (.stop_hook_active | type) == "boolean" then .stop_hook_active | tostring
      else error("stop_hook_active must be a JSON Boolean") end
    else "false" end end' 2>/dev/null
}
_sg_failure() {
  _sg_missing="spec-gate degraded: $1; run trellis doctor in $(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  case "$_sg_cli_mode" in
    --gate|--mark|--mark-emergency)
      echo "[spec-gate] BLOCKED: $_sg_missing" >&2
      exit 1 ;;
  esac
  _sg_stop_active_raw "$_sg_input" && exit 0
  if ! command -v jq >/dev/null 2>&1; then
    _sg_missing="$_sg_missing; jq required but not found"
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "[spec-gate] $_sg_missing" | jq -Rs .)"
  else
    # No jq: escape by hand so a path with a quote, backslash or control byte
    # still yields one valid JSON object.
    _sg_r="[spec-gate] $_sg_missing"
    _sg_r=${_sg_r//\\/\\\\}; _sg_r=${_sg_r//\"/\\\"}
    _sg_r=${_sg_r//$'\n'/\\n}; _sg_r=${_sg_r//$'\r'/\\r}; _sg_r=${_sg_r//$'\t'/\\t}
    printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$_sg_r" | /usr/bin/env LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  fi
  exit "$_SG_STOP_BLOCK_EXIT"
}
if [ ! -f "$_sg_core" ]; then
  _sg_failure "core library missing at $_sg_core"
fi
# shellcheck source=lib/spec-gate-core.sh
if ! . "$_sg_core"; then
  _sg_failure "core library failed to load at $_sg_core"
fi
for _sg_function in sg_gate_args sg_write_marker sg_verdict sg_remedy_message; do
  declare -F "$_sg_function" >/dev/null || _sg_failure "core library is missing $_sg_function"
done

# --gate accepts the carrier's exact range; no resolver means no safety verdict.
if [ "${1:-}" = "--gate" ]; then
  sg_gate_args "$@" || exit $?
fi

# --- marker-writer mode (used by /surgical) ---------------------------------
# Writes the size-capped-work declaration marker for THIS branch so a
# subsequent push takes the surgical route. --mark-emergency writes an
# any-size emergency marker (audit-logged at gate time). No verdict needed.
if [ "${1:-}" = "--mark" ] || [ "${1:-}" = "--mark-emergency" ]; then
  mode=surgical
  [ "$1" = "--mark-emergency" ] && mode=emergency
  reason=${2:-"declared via /surgical"}
  if sg_write_marker "$mode" "$reason"; then
    echo "[spec-gate] $mode declaration recorded for this branch (reason: $reason)."
    echo "[spec-gate] The next push takes the $mode route. Keep the diff within the surgical ceiling unless emergency." >&2
    exit 0
  fi
  echo "[spec-gate] could not write $mode marker (not a git work tree, or detached HEAD)." >&2
  exit 1
fi

# Validate before the verdict: malformed input is never reentry or a valid
# disabled-policy no-op. CLI/marker modes do not consume Stop input.
_sg_active=false
if [ -z "$_sg_cli_mode" ]; then
  command -v jq >/dev/null 2>&1 || _sg_failure 'jq required but not found — cannot read Stop policy'
  _sg_active=$(_sg_stop_active "$_sg_input") \
    || _sg_failure 'invalid Stop envelope: stop_hook_active must be a JSON Boolean'
fi

# The Stop early warning (no argument) lets a decided pass skip the diff range.
_sg_verdict_mode=""
[ -z "${1:-}" ] && _sg_verdict_mode=stop
if ! verdict_line=$(sg_verdict "$PWD" "${SG_REQUEST_RANGE:-}" "${SG_REQUEST_REF:-}" "${SG_REQUEST_HEAD:-}" "$_sg_verdict_mode"); then
  _sg_failure 'verdict engine failed'
fi
case "$verdict_line" in
  $'pass\t'?*|$'block\t'?*|$'advisory\t'?*) ;;
  *) _sg_failure 'verdict engine returned an invalid result' ;;
esac
verdict=${verdict_line%%$'\t'*}
reason=${verdict_line#*$'\t'}

# --- pre-push CLI mode (harness-neutral teeth) ------------------------------
if [ "${1:-}" = "--gate" ]; then
  # The shared core embeds the receipt in its reason (also visible in Stop JSON).
  case "$reason" in
    diff-base:*)
      printf '%s\n' "${reason%%$'\n'*}"
      reason=${reason#*$'\n'} ;;
  esac
  case "$verdict" in
    block)
      echo "[spec-gate] BLOCKED: $reason" >&2
      sg_remedy_message >&2
      exit 1 ;;
    advisory)
      echo "[spec-gate] advisory: $reason (not blocking)" >&2
      exit 0 ;;
    *)
      exit 0 ;;
  esac
fi

# --- Codex Stop-hook early-warning mode -------------------------------------
# Stop input/dependency failures were validated before the verdict. They
# block under SC11; operator warning-only degradation cannot clear this gate.
# Read the event JSON. Mandatory re-entrancy guard (core-rules/hooks.md): if this
# Stop is already firing because a prior Stop hook blocked, do NOT re-block — exit
# 0 to break the loop. The verdict itself is state-based, not stdin-based.
if [ "$_sg_active" = true ]; then
  exit 0
fi
case "$verdict" in
  block)
    msg="[spec-gate] $reason"$'\n'"$(sg_remedy_message)"
    jq -nc --arg reason "$msg" '{decision: "block", reason: $reason}'
    # Codex reads the JSON decision only on exit 0; exit 2 reads stderr instead.
    exit 0 ;;
  *)
    exit 0 ;;
esac
