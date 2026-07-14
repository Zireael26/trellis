#!/usr/bin/env bash
# spec-gate.sh — mandatory-pipeline gate (spec 006). Two modes:
#   --gate  : harness-neutral CLI for the pre-push hook (the LOAD-BEARING teeth).
#             Prints the remedy on a block and exits 1; else exits 0.
#   (hook)  : Claude Stop hook early-warning. On a block verdict it emits the
#             Claude block JSON + exit 2; otherwise exit 0.
#
# Both modes call the SAME pure verdict engine (`spec-gate-core.sh`) — a function
# of git/filesystem state only, byte-identical to the Codex twin
# (core-rules/codex/hooks/spec-gate.sh). Parity by construction: the deterministic
# state decides, not the model.

DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/spec-gate-core.sh
. "$DIR/lib/spec-gate-core.sh"

# --- marker-writer mode (used by /surgical) ---------------------------------
# Writes the size-capped-work declaration marker for THIS branch so a
# subsequent push takes the surgical route. --mark-emergency writes an
# any-size emergency marker (audit-logged at gate time). No verdict needed.
if [ "$1" = "--mark" ] || [ "$1" = "--mark-emergency" ]; then
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

verdict_line=$(sg_verdict "$PWD")
verdict=${verdict_line%%$'\t'*}
reason=${verdict_line#*$'\t'}

# --- pre-push CLI mode (harness-neutral teeth) ------------------------------
if [ "$1" = "--gate" ]; then
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
    exit 0 ;;
esac
