#!/usr/bin/env bash
# Gate 6: Security (diff) — thin adapter to security-gate/scripts/run-diff.sh.
# Usage: check-security-diff.sh [--range=<gitspec>] [--target=main]
#
# Only the executing payload's sibling security-gate may run; a missing or
# project-controlled payload fails closed. Scanner verdicts pass through:
# 0 pass / 2 warn / 1 fail, and only with exactly one `Overall:` verdict line
# that matches the rc; none, several, or a disagreeing one FAILs. A passing or
# warning verdict also needs one `Baseline:` row saying the baseline it rests
# on is complete (or a pre-1.4.2 baseline of unknown completeness); a gate that
# reports none, or an incomplete one, FAILs.
# SECURITY_GATE_SKIP=1 is never a pass: an unperformed scan reports BLOCKED in
# every mode. PG_MODE=push adds --no-llm; PG_MODE is passed on as run-diff's
# --mode, and --target=main (a push that targets main/master) is passed on.

# Purge inherited functions before anything runs; the assignment turns on POSIX
# mode, where `unset`/`set` are found before functions, so the purge cannot be
# intercepted (see security-gate/scripts/run-diff.sh).
POSIXLY_CORRECT=y
unset -f builtin command type set unset compgen
set +o posix
builtin unset POSIXLY_CORRECT
for _pg_fn in $(builtin compgen -A function 2>/dev/null); do builtin unset -f "$_pg_fn"; done
builtin unset _pg_fn

set -uo pipefail

# Determine the project boundary with shell builtins, before resolving the
# executing adapter or loading or running a sibling or helper.
if [ -n "${CODEX_PROJECT_DIR:-}" ] && [ -d "$CODEX_PROJECT_DIR" ]; then
  _pg_project="$CODEX_PROJECT_DIR"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  _pg_project="$CLAUDE_PROJECT_DIR"
else
  _pg_project="$(builtin pwd -P)" || exit 1
  _pg_walk="$_pg_project"
  while :; do
    if [ -e "$_pg_walk/.git" ] || [ -L "$_pg_walk/.git" ]; then _pg_project="$_pg_walk"; break; fi
    [ "$_pg_walk" != / ] || break
    _pg_walk="${_pg_walk%/*}"; _pg_walk="${_pg_walk:-/}"
  done
fi
_pg_project="$(builtin cd -P "$_pg_project" && builtin pwd -P)" || exit 1

pg_payload_inside() {
  local p="$1" next
  while :; do
    [ "$p" -ef "$2" ] && return 0
    next="${p%/*}"; next="${next:-/}"
    [ "$next" != "$p" ] || return 1
    p="$next"
  done
}

# Derive the executing process-gate payload without a PATH helper.
_pg_self="$0"
if [ ! -e "$_pg_self" ] && [ ! -L "$_pg_self" ]; then
  _pg_self="$(builtin type -P "$_pg_self")" || exit 1
fi
case "$_pg_self" in /*) ;; *) _pg_self="$PWD/$_pg_self" ;; esac
_pg_self_links=0; _pg_self_reader=""
for _pg_reader in /usr/bin/readlink /bin/readlink; do
  if [ -x "$_pg_reader" ]; then _pg_self_reader="$_pg_reader"; break; fi
done
while [ -L "$_pg_self" ]; do
  _pg_self_links=$((_pg_self_links + 1))
  [ "$_pg_self_links" -le 40 ] && [ -n "$_pg_self_reader" ] || exit 1
  if pg_payload_inside "$_pg_self_reader" "$_pg_project"; then
    builtin printf 'fail Security (diff): unsafe readlink helper at %s for project %s\n' "$_pg_self_reader" "$_pg_project" >&2
    exit 1
  fi
  _pg_link="$("$_pg_self_reader" "$_pg_self")" || exit 1
  [ -n "$_pg_link" ] || exit 1
  case "$_pg_link" in /*) _pg_self="$_pg_link" ;; *) _pg_self="${_pg_self%/*}/$_pg_link" ;; esac
done
_pg_self_dir="${_pg_self%/*}"
SKILL_DIR="$(builtin cd -P "$_pg_self_dir/.." && builtin pwd -P)" || exit 1

# Source-checkout development is allowed only when this very adapter is in
# that checkout's core-rules/skills/process-gate. The sibling skill must also
# be a real source directory, not a project-controlled directory symlink.
_pg_dev_root=""
if [ -e "$_pg_project/.git" ] && [ "$SKILL_DIR" -ef "$_pg_project/core-rules/skills/process-gate" ]; then
  _pg_dev_ok=1
  for _pg_dir in "$_pg_project/core-rules" "$_pg_project/core-rules/skills" \
    "$_pg_project/core-rules/skills/process-gate" "$_pg_project/core-rules/skills/security-gate"; do
    [ -d "$_pg_dir" ] && [ ! -L "$_pg_dir" ] || _pg_dev_ok=0
  done
  [ "$_pg_dev_ok" -ne 1 ] || _pg_dev_root="$_pg_project/core-rules/skills/security-gate"
fi

# Bootstrap the sibling payload's path without sourcing its engine.sh first:
# a sibling link can itself point into the scanned project. Check every link
# component by identity, including links that bounce back outside. In source
# development, project components may lead only into the specified source skill.
pg_payload_path() {
  local pending="$1" dev="${2-$_pg_dev_root}" current=/ part rest candidate target links=0 reader=""
  case "$pending" in /*) pending="${pending#/}" ;; *) pending="${PWD#/}/$pending" ;; esac
  for candidate in /usr/bin/readlink /bin/readlink; do
    if [ -x "$candidate" ]; then reader="$candidate"; break; fi
  done
  while [ -n "$pending" ]; do
    part="${pending%%/*}"
    if [ "$part" = "$pending" ]; then rest=""; else rest="${pending#*/}"; fi
    pending="$rest"
    case "$part" in
      ''|.) continue ;;
      ..) current="${current%/*}"; current="${current:-/}"; continue ;;
    esac
    candidate="${current%/}/$part"
    if pg_payload_inside "$candidate" "$_pg_project"; then
      [ -n "$dev" ] || return 1
      pg_payload_inside "$candidate" "$dev" || pg_payload_inside "$dev" "$candidate" || return 1
    fi
    if [ -L "$candidate" ]; then
      links=$((links + 1))
      [ "$links" -le 40 ] && [ -n "$reader" ] || return 1
      pg_payload_inside "$reader" "$_pg_project" && return 1
      target="$("$reader" "$candidate")" || return 1
      [ -n "$target" ] || return 1
      case "$target" in /*) current=/; target="${target#/}" ;; esac
      pending="$target${pending:+/$pending}"
    else
      [ -e "$candidate" ] || return 1
      current="$candidate"
    fi
  done
  if [ -n "$dev" ]; then pg_payload_inside "$current" "$dev" || return 1; fi
  builtin printf '%s\n' "$current"
}

_pg_skills_dir="$(builtin cd -P "$SKILL_DIR/.." && builtin pwd -P)" || exit 1
RUNDIFF="$_pg_skills_dir/security-gate/scripts/run-diff.sh"
if [ ! -f "$RUNDIFF" ]; then
  builtin printf 'fail Security (diff): security-gate payload unavailable: %s\n' "$RUNDIFF" >&2
  exit 1
fi
if ! _pg_gate="$(pg_payload_path "$RUNDIFF")"; then
  builtin printf 'fail Security (diff): unsafe security-gate payload: %s\n' "$RUNDIFF" >&2
  exit 1
fi
# run-diff is invoked at its resolved path, so all of its relative imports
# are anchored there, not at the lexical sibling through which it was found.
_pg_gate_skill="$(builtin cd -P "${_pg_gate%/*}/.." && builtin pwd -P)" || exit 1
_pg_gate_skills="$(builtin cd -P "$_pg_gate_skill/.." && builtin pwd -P)" || exit 1
SG_LIB="${_pg_gate%/*}/lib"
_pg_process_dev=""
[ -z "$_pg_dev_root" ] || _pg_process_dev="$SKILL_DIR"
_pg_adapter_lib="$(pg_payload_path "$SKILL_DIR/scripts/lib" "$_pg_process_dev")" || {
  builtin printf 'fail Security (diff): unsafe or missing process-gate payload helper directory: %s/scripts/lib\n' "$SKILL_DIR" >&2
  exit 1
}

# Complete file-execution inventory for this adapter and the real diff gate.
# The test inventories source/dot/interpreter calls in these scripts so a new
# payload target cannot silently bypass this preflight. The gate-side resolver
# is optional because run-diff itself permits a sibling without process-gate;
# all other entries are required. common.sh's own diff-base is relative to its
# resolved file; run-diff's separate resolver is relative to the resolved gate.
_pg_payload_manifest=(
  gate
  security-engine
  security-osv
  security-baseline
  process-common
  process-common-diff-base
  security-diff-base
)
for _pg_item in "${_pg_payload_manifest[@]}"; do
  _pg_optional=0
  case "$_pg_item" in
    gate)                     _pg_file="$RUNDIFF"; _pg_allow="$_pg_dev_root"; _pg_label="security-gate payload" ;;
    security-engine)          _pg_file="$SG_LIB/engine.sh"; _pg_allow="$_pg_dev_root"; _pg_label="security-gate payload helper" ;;
    security-osv)             _pg_file="$SG_LIB/osv.sh"; _pg_allow="$_pg_dev_root"; _pg_label="security-gate payload helper" ;;
    security-baseline)        _pg_file="$SG_LIB/baseline_state.py"; _pg_allow="$_pg_dev_root"; _pg_label="security-gate payload baseline validator" ;;
    process-common)           _pg_file="$_pg_adapter_lib/common.sh"; _pg_allow="$_pg_process_dev"; _pg_label="process-gate payload helper" ;;
    process-common-diff-base) _pg_file="${_pg_common%/*}/diff-base.sh"; _pg_allow="$_pg_process_dev"; _pg_label="process-gate payload helper" ;;
    security-diff-base)       _pg_file="$_pg_gate_skills/process-gate/scripts/lib/diff-base.sh"; _pg_allow="$_pg_process_dev"; _pg_label="process-gate payload helper"; _pg_optional=1 ;;
    *) builtin printf 'fail Security (diff): unknown payload inventory item: %s\n' "$_pg_item" >&2; exit 1 ;;
  esac
  if [ "$_pg_optional" -eq 1 ] && [ ! -e "$_pg_file" ] && [ ! -L "$_pg_file" ]; then continue; fi
  if [ ! -f "$_pg_file" ] || ! _pg_checked="$(pg_payload_path "$_pg_file" "$_pg_allow")"; then
    builtin printf 'fail Security (diff): unsafe or missing %s: %s\n' "$_pg_label" "$_pg_file" >&2
    exit 1
  fi
  case "$_pg_item" in
    gate) _pg_gate="$_pg_checked" ;;
    security-engine) _pg_engine="$_pg_checked" ;;
    security-baseline) _pg_validator="$_pg_checked" ;;
    process-common) _pg_common="$_pg_checked" ;;
  esac
done
builtin source "$_pg_engine"
if ! sg_path_sanitize "$_pg_project" || ! sg_vet_helpers "$_pg_project" \
    bash git gh env cat grep sed awk tr mktemp rm mkdir dirname wc jq python3 perl chmod cut head date basename ls sort tail; then
  builtin printf 'fail Security (diff): unsafe external helper for project %s\n' "$_pg_project" >&2
  exit 1
fi
SG_BASH="$(sg_checked_program "$BASH" "$_pg_project")" || {
  builtin printf 'fail Security (diff): unsafe bash at %s\n' "$BASH" >&2; exit 1;
}
builtin unset BASH_ENV ENV PYTHONPATH PYTHONHOME
# shellcheck source=lib/common.sh
. "$_pg_common"

# common.sh sets `set -euo pipefail`. This adapter runs a child gate that may
# exit 2/1 by design — disable -e so the rc passes through verbatim.
set +e

pg_load_config "$@" || exit 1
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"
if [ ! "$PROJECT_DIR" -ef "$_pg_project" ]; then
  pg_log fail "Security (diff): project identity changed while loading config"
  exit 1
fi

# A skipped scan is not a verdict in any mode: it would pass a secret or a
# gate-config change unscanned.
if [ "${SECURITY_GATE_SKIP:-}" = "1" ]; then
  pg_log fail "Security (diff): SECURITY_GATE_SKIP is not honoured; the scan did not run (range=$RANGE)"
  printf '\nOverall: BLOCKED\n'
  exit 1
fi

# run-diff was verified before any project-controlled helper could run. It is
# invoked through bash, so a regular but non-executable payload remains valid.

# Build args; --no-llm for a fast WIP scan at push. The mode follows
# pg_parse_mode: anything but push is merge, where a security-config change
# needs a PR approval line.
args=("$PROJECT_DIR" "--range=$RANGE")
if [ "${PG_MODE:-}" = "push" ]; then
  args+=("--no-llm" "--mode=push")
else
  args+=("--mode=merge")
fi
for arg in "$@"; do
  [ "$arg" != --target=main ] || args+=("--target=main")
done

# `bash -p`: the gate starts with no imported functions and no BASH_ENV.
out="$("$SG_BASH" -p "$_pg_gate" "${args[@]}" 2>&1)"; rc=$?
printf "%s\n" "$out"

# The exit code alone is not a verdict: a child that exits 0 having printed
# nothing (a truncated payload) must not pass.
verdict="$(printf '%s\n' "$out" | sed -n -E 's/^Overall: (MERGEABLE|NEEDS CHANGES|BLOCKED)$/\1/p')"
if [ "$(printf '%s\n' "$out" | grep -c '^Overall:')" -gt 1 ]; then
  pg_log fail "Security (diff): run-diff printed more than one Overall line (range=$RANGE)"
  exit 1
fi
# run-diff BLOCKS on an incomplete baseline itself. This also holds an older
# payload to the same rule: one that cannot say its baseline is complete
# does not get to pass. The payload's security-gate baseline_state.py, the
# schema check run-diff uses, judges the row; without it nothing passes. It
# runs under a python3 vetted as run-diff vets its own (lib/engine.sh): PATH
# entries inside the project are dropped, and an interpreter that resolves
# into the project is refused. Only its exact "accepted" line, with exit 0,
# accepts: an empty validator exits 0 having checked nothing.
BASELINE_VALIDATOR="$SG_LIB/baseline_state.py"
case "$verdict:$rc" in
  MERGEABLE:0|"NEEDS CHANGES":2)
    if [ ! -s "$BASELINE_VALIDATOR" ] || [ ! -f "$SG_LIB/engine.sh" ]; then
      pg_log fail "Security (diff): the security-gate baseline validator is unavailable, so $verdict cannot be checked (range=$RANGE)"
      exit 1
    fi
    if ! _pg_validator="$(pg_payload_path "$BASELINE_VALIDATOR")"; then
      pg_log fail "Security (diff): unsafe security-gate payload validator at $BASELINE_VALIDATOR (range=$RANGE)"
      exit 1
    fi
    # The real binary behind any shim, run directly: a shim on the caller's
    # PATH would find its own interpreter, or bash, through project state.
    if ! VALIDATOR_PY="$(sg_resolve_python "$PROJECT_DIR")"; then
      pg_log fail "Security (diff): no trusted python3 outside the scanned project to run the baseline validator (range=$RANGE)"
      exit 1
    fi
    if [ "$(printf '%s\n' "$out" | grep -c '^Baseline:')" -ne 1 ] \
       || ! row_check="$("$VALIDATOR_PY" -I "$_pg_validator" --row "$(printf '%s\n' "$out" | grep '^Baseline:')" 2>/dev/null)" \
       || [ "$row_check" != "baseline-row: accepted" ]; then
      pg_log fail "Security (diff): run-diff reported $verdict without exactly one complete Baseline row (range=$RANGE)"
      exit 1
    fi
    exit "$rc" ;;
  BLOCKED:1) exit "$rc" ;;
  :*) pg_log fail "Security (diff): run-diff exited $rc without an Overall verdict (range=$RANGE)" ;;
  *)  pg_log fail "Security (diff): run-diff exited $rc but reported Overall: $verdict (range=$RANGE)" ;;
esac
exit 1
