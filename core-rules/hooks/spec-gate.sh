#!/usr/bin/env bash
# spec-gate.sh — mandatory-pipeline gate (spec 006). Two modes:
#   --gate  : harness-neutral CLI for the pre-push hook (the LOAD-BEARING teeth).
#             Prints the remedy on a block and exits 1; else exits 0.
#   (hook)  : Claude Stop hook early-warning. On a block verdict it emits the
#             Claude block JSON + exit 2; otherwise exit 0.
#
# Both twins call the SAME pure verdict engine (`spec-gate-core.sh`) — a function
# of git/filesystem state only. Their gate/mark prefix is byte-identical; their
# Stop emitters differ by harness contract (Claude exit 2, Codex exit 0).
# Parity by construction: the deterministic state decides, not the model.

# The core resolves from this script's own resolved directory, never the caller's
# cwd (spec 055 R1.1). A deployed hooks dir carries it as a sibling. Run in place
# from the payload, core-rules/codex/hooks/lib/ does not, so the fallback to the
# shared core-rules/hooks/lib/ applies only when this directory IS the declared
# runtime's Codex tree. A project path that merely ends in core-rules/codex/hooks
# gets no fallback, so it can never source a project-controlled file.
# Claude Stop block contract: JSON + exit 2. Set outside the shared prefix below.
_SG_STOP_BLOCK_EXIT=2
_SG_HARNESS=claude
DIR=$(unset CDPATH; cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
_sg_rt=$(unset CDPATH; [ -n "${TRELLIS_ROOT:-}" ] && cd -P -- "$TRELLIS_ROOT" 2>/dev/null && pwd -P)
_sg_core="$DIR/lib/spec-gate-core.sh"
if [ ! -f "$_sg_core" ] && [ -n "$_sg_rt" ] && [ "$DIR" = "$_sg_rt/core-rules/codex/hooks" ]; then
  _sg_core="$DIR/../../hooks/lib/spec-gate-core.sh"
fi
if [ -f "$_sg_core" ]; then
  # shellcheck source=lib/spec-gate-core.sh
  . "$_sg_core"
else
  # No verdict engine: fail CLOSED in every mode (spec 055 R1.3). A silent exit 0
  # here is how the Codex pipeline block went missing.
  _sg_missing="spec-gate degraded: core library missing at $_sg_core; run trellis doctor in $(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  case "${1:-}" in
    --gate|--mark|--mark-emergency)
      echo "[spec-gate] BLOCKED: $_sg_missing" >&2
      exit 1 ;;
  esac
  _sg_input=$(cat 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1 \
    && [ "$(printf '%s' "$_sg_input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "[spec-gate] $_sg_missing" | jq -Rs .)"
  else
    # No jq: escape by hand so a path with a quote, backslash or control byte
    # still yields one valid JSON object.
    _sg_r="[spec-gate] $_sg_missing"
    _sg_r=${_sg_r//\\/\\\\}; _sg_r=${_sg_r//\"/\\\"}
    _sg_r=${_sg_r//$'\n'/\\n}; _sg_r=${_sg_r//$'\r'/\\r}; _sg_r=${_sg_r//$'\t'/\\t}
    printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$_sg_r" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  fi
  exit "$_SG_STOP_BLOCK_EXIT"
fi

# --gate accepts the carrier's exact range; no resolver means no safety verdict.
if [ "${1:-}" = "--gate" ]; then
  sg_gate_args "$@" || exit 1
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

# Stop-hook pass cache (spec 072 U8, see sg_stop_cache_key). The CLI modes
# never read it; a hit is a pass the full path would also give.
_sg_cache="" _sg_key=""
if [ -z "${1:-}" ] && command -v _se_stop_receipt_match >/dev/null 2>&1 \
   && _sg_cache=$(sg_stop_cache_file "$PWD" "$_SG_HARNESS") && _sg_key=$(sg_stop_cache_key "$PWD"); then
  if _se_stop_receipt_match "$_sg_cache" "$_sg_key"; then
    cat >/dev/null 2>&1 || true
    exit 0
  fi
else
  _sg_key=""
fi

verdict_line=$(sg_verdict "$PWD" "${SG_REQUEST_RANGE:-}" "${SG_REQUEST_REF:-}" "${SG_REQUEST_HEAD:-}")
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

# --- Claude Stop-hook early-warning mode ------------------------------------
# Read the event JSON. Mandatory re-entrancy guard (core-rules/hooks.md): if this
# Stop is already firing because a prior Stop hook blocked, do NOT re-block — exit
# 0 to break the loop. The verdict itself is state-based, not stdin-based.
_sg_input=$(cat 2>/dev/null || true)
if command -v jq >/dev/null 2>&1 \
  && [ "$(printf '%s' "$_sg_input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi
case "$verdict" in
  block)
    msg="[spec-gate] $reason"$'\n'"$(sg_remedy_message)"
    if command -v jq >/dev/null 2>&1; then
      printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$msg" | jq -Rs .)"
    else
      printf '{"decision":"block","reason":"spec-gate: %s"}\n' "$reason"
    fi
    exit 2 ;;
  *)
    if [ "$verdict" = pass ] && [ -n "$_sg_key" ]; then
      case "$reason" in
        *surgical-marker) ;;
        *) _se_stop_receipt_write "$_sg_cache" "$_sg_key" "spec-gate ${reason##*$'\n'}" ;;
      esac
    fi
    exit 0 ;;
esac
