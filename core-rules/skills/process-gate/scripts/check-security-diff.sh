#!/usr/bin/env bash
# Gate 6: Security (diff) — thin adapter to security-gate/scripts/run-diff.sh.
# Usage: check-security-diff.sh [--range=<gitspec>] [--target=main]
#
# The executing payload's sibling security-gate wins; project copies are
# fallbacks only. Missing gate fails closed. Scanner verdicts pass through:
# 0 pass / 2 warn / 1 fail, and only with exactly one `Overall:` verdict line
# that matches the rc; none, several, or a disagreeing one FAILs.
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

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

# common.sh sets `set -euo pipefail`. This adapter runs a child gate that may
# exit 2/1 by design — disable -e so the rc passes through verbatim.
set +e

pg_load_config "$@" || exit 1
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

# A skipped scan is not a verdict in any mode: it would pass a secret or a
# gate-config change unscanned.
if [ "${SECURITY_GATE_SKIP:-}" = "1" ]; then
  pg_log fail "Security (diff): SECURITY_GATE_SKIP is not honoured; the scan did not run (range=$RANGE)"
  printf '\nOverall: BLOCKED\n'
  exit 1
fi

# Locate run-diff.sh: executing payload first. Invoked via `bash` below,
# so a missing exec bit is irrelevant — test for a regular file (-f), not -x.
# This mirrors the pre-push hook's run-all.sh resolution (-f, not -x) so a
# present-but-non-executable run-diff.sh (cp without -p / archive extraction /
# core.fileMode=false) is NOT silently downgraded to a non-blocking warn-skip,
# which at merge would let a real Critical/High security finding through.
#
# The executing payload is authoritative even when the checkout tracks a legacy
# or PR-authored gate. Project candidates are fallbacks when its skill is absent.
RUNDIFF=""
for cand in \
  "$SKILL_DIR/../security-gate/scripts/run-diff.sh" \
  "$PROJECT_DIR/.claude/skills/security-gate/scripts/run-diff.sh" \
  "$PROJECT_DIR/.agents/skills/security-gate/scripts/run-diff.sh" \
  "$PROJECT_DIR/core-rules/skills/security-gate/scripts/run-diff.sh"; do
  if [ -f "$cand" ]; then RUNDIFF="$cand"; break; fi
done
if [ -z "$RUNDIFF" ]; then
  pg_log fail "Security (diff): security-gate unavailable in project and payload (range=$RANGE)"
  exit 1
fi

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
out="$("$BASH" -p "$RUNDIFF" "${args[@]}" 2>&1)"; rc=$?
printf "%s\n" "$out"

# The exit code alone is not a verdict: a child that exits 0 having printed
# nothing (a truncated or hand-written fallback gate) must not pass.
verdict="$(printf '%s\n' "$out" | sed -n -E 's/^Overall: (MERGEABLE|NEEDS CHANGES|BLOCKED)$/\1/p')"
if [ "$(printf '%s\n' "$out" | grep -c '^Overall:')" -gt 1 ]; then
  pg_log fail "Security (diff): run-diff printed more than one Overall line (range=$RANGE)"
  exit 1
fi
case "$verdict:$rc" in
  MERGEABLE:0|"NEEDS CHANGES":2|BLOCKED:1) exit "$rc" ;;
  :*) pg_log fail "Security (diff): run-diff exited $rc without an Overall verdict (range=$RANGE)" ;;
  *)  pg_log fail "Security (diff): run-diff exited $rc but reported Overall: $verdict (range=$RANGE)" ;;
esac
exit 1
