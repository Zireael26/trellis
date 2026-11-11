# shellcheck shell=sh
# Sealed native guard adapter; inline registration program (I-A3).
r=127
if [ "${1#*=}" = "$1" ] && [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ]; then
  o=$(/usr/bin/env -i "HOME=${HOME-}" "TRELLIS_HOME=${TRELLIS_HOME:-${HOME%/}/.trellis}" PATH=/usr/bin:/bin:/usr/sbin:/sbin "TRELLIS_CALLER_PATH=${PATH-}" "TRELLIS_REVIEW_IN_PROGRESS=${TRELLIS_REVIEW_IN_PROGRESS-}" "PROCESS_GATE_FORCE_ROOT=${PROCESS_GATE_FORCE_ROOT-}" "PROCESS_GATE_NO_RECEIPTS=${PROCESS_GATE_NO_RECEIPTS-}" "TODOS_FILE=${TODOS_FILE-}" "TRELLIS_NO_JQ_DEGRADE=${TRELLIS_NO_JQ_DEGRADE-}" "RUSTUP_HOME=${RUSTUP_HOME-}" "SLOP_TRIPWIRE=${SLOP_TRIPWIRE-}" "$1" event "$2" "$3" "$4")
  r=$?
fi
case $r in
  10) exit 0 ;;
  11) printf "%s\n" "$o"; exit 0 ;;
  12) printf "%s\n" "$o"; exit 2 ;;
esac
w="trellis-hooks: native entry failed (status $r); refusing"
if [ "$2" = claude ]; then
  if [ "$3" = PreToolUse ]; then
    printf "%s\n" "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$w\"}}"
  else
    printf "%s\n" "{\"decision\":\"block\",\"reason\":\"$w\"}"
  fi
  exit 0
fi
printf "%s\n" "{\"decision\":\"block\",\"reason\":\"$w\"}"
printf "%s\n" "$w" >&2
exit 2
