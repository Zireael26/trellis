#!/usr/bin/env bash
# pi-output-guard.sh — doctor rows for the pi bash output guard (spec 069 C1).
# Owned by lane L-C (task C.4); L-0 ships the empty stub.
#
# hc_pi_guard_rows USER_HOME TRELLIS_HOME FIX_MODE
#
# Follows the row contract documented in worktree-layout.sh: `STATUS<TAB>MESSAGE`
# lines on stdout, FIX_MODE off|dry-run|apply, never exits the caller, returns 0.
# There is no repair: installing the guard is a guide step, so every FIX_MODE
# reads as off.
#
# Rows:
#   OK    USER_HOME/.pi/agent/extensions/trellis-bash-guard.ts equals the
#         active release's payload copy;
#   WARN  it is missing or differs; no active release payload to compare
#         against; an override the guard would not use; no perl on PATH (the
#         guard then runs commands uncapped);
#   INFO  no USER_HOME/.pi/agent (pi not set up); a timeout or cap of 0 (off).
# The overrides are read from this process's environment, which is the
# shell's when doctor runs from it. bash 3.2 compatible.

# pog_override <name> <max> <default>: one row when the variable is 0 or a
# value the guard replaces by its default (the extension's guardSettings).
pog_override() {
  local name="$1" max="$2" default="$3" value digits
  value="${!name-}"
  [ -n "$value" ] || return 0
  case "$value" in
    *[!0-9]*) ;;
    *)
      digits="${value#"${value%%[!0]*}"}"
      if [ -z "$digits" ]; then
        if [ "$name" = TRELLIS_PI_BASH_TIMEOUT_S ]; then
          printf '%s\t%s\n' "$HC_INFO" "pi bash guard: the default timeout is off ($name=0)"
        else
          printf '%s\t%s\n' "$HC_INFO" "pi bash guard: the output cap is off ($name=0)"
        fi
        return 0
      fi
      # Compare as strings: the cap's range is past bash's integers on some builds.
      if [ "${#digits}" -lt "${#max}" ] || { [ "${#digits}" -eq "${#max}" ] && [[ ! "$digits" > "$max" ]]; }; then
        return 0
      fi
      ;;
  esac
  printf '%s\t%s\n' "$HC_WARN" "pi bash guard: $name='$value' is not a whole number from 0 to $max; the guard uses $default"
}

hc_pi_guard_rows() {
  local home="$1" trellis_home="$2" installed release="" payload
  installed="$home/.pi/agent/extensions/trellis-bash-guard.ts"
  if [ ! -d "$home/.pi/agent" ]; then
    printf '%s\t%s\n' "$HC_INFO" "pi bash guard: no $home/.pi/agent; pi is not set up for this account"
    return 0
  fi
  if [ -f "$trellis_home/config.json" ]; then
    release="$(jq -r '.active_cli_release // empty' "$trellis_home/config.json" 2>/dev/null)" || release=""
  fi
  payload="$trellis_home/releases/$release/payload/core-rules/pi/extensions/trellis-bash-guard.ts"
  if [ ! -f "$installed" ]; then
    printf '%s\t%s\n' "$HC_WARN" "pi bash guard: not installed at $installed, so pi bash calls have no default timeout and no output cap; remedy: install it as AGENT_PI_SETUP.md step 2 shows"
  elif [ -z "$release" ] || [ ! -f "$payload" ]; then
    printf '%s\t%s\n' "$HC_WARN" "pi bash guard: $installed is installed, but $trellis_home has no active release payload to compare it with"
  elif cmp -s "$installed" "$payload"; then
    printf '%s\t%s\n' "$HC_OK" "pi bash guard: $installed matches the payload"
  else
    printf '%s\t%s\n' "$HC_WARN" "pi bash guard: $installed differs from the payload $payload; remedy: reinstall it as AGENT_PI_SETUP.md step 2 shows"
  fi
  pog_override TRELLIS_PI_BASH_TIMEOUT_S 2147483 1800
  pog_override TRELLIS_PI_BASH_CAP_BYTES 9007199254740991 536870912
  command -v perl >/dev/null 2>&1 ||
    printf '%s\t%s\n' "$HC_WARN" 'pi bash guard: perl is not on PATH, so the guard runs commands without the output cap'
  return 0
}
