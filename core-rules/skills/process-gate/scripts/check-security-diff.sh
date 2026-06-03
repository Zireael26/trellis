#!/usr/bin/env bash
# Gate 6: Security (diff) — thin adapter to security-gate/scripts/run-diff.sh.
# Usage: check-security-diff.sh [--range=<gitspec>]
#
# Locates run-diff.sh in the project (.claude first, .agents fallback) and
# passes its exit code through verbatim: 0 pass / 2 warn / 1 fail (same verdict
# shape as process-gate). Honors SECURITY_GATE_SKIP=1 (deliberate skip ->
# pass). Adds --no-llm for a fast WIP scan when PG_MODE=push. Absence of the
# security-gate is a warn-skip, never a fail (matches the husky precedent).

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

# common.sh sets `set -euo pipefail`. This adapter runs a child gate that may
# exit 2/1 by design — disable -e so the rc passes through verbatim.
set +e

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

# Deliberate skip is non-blocking informational (husky precedent): pass.
if [ "${SECURITY_GATE_SKIP:-}" = "1" ]; then
  pg_log info "Security (diff): SECURITY_GATE_SKIP=1 — skipped (range=$RANGE)"
  exit 0
fi

# Locate run-diff.sh: .claude first, .agents fallback. Invoked via `bash` below,
# so a missing exec bit is irrelevant — test for a regular file (-f), not -x.
# This mirrors the pre-push hook's run-all.sh resolution (-f, not -x) so a
# present-but-non-executable run-diff.sh (cp without -p / archive extraction /
# core.fileMode=false) is NOT silently downgraded to a non-blocking warn-skip,
# which at merge would let a real Critical/High security finding through.
RUNDIFF=""
for cand in \
  "$PROJECT_DIR/.claude/skills/security-gate/scripts/run-diff.sh" \
  "$PROJECT_DIR/.agents/skills/security-gate/scripts/run-diff.sh"; do
  if [ -f "$cand" ]; then RUNDIFF="$cand"; break; fi
done
if [ -z "$RUNDIFF" ]; then
  pg_log warn "Security (diff): security-gate not installed — skipped (range=$RANGE)"
  exit 2
fi

# Build args; --no-llm for a fast WIP scan at push.
args=("$PROJECT_DIR" "--range=$RANGE")
[ "${PG_MODE:-}" = "push" ] && args+=("--no-llm")

out="$(bash "$RUNDIFF" "${args[@]}" 2>&1)"; rc=$?
printf "%s\n" "$out"
exit "$rc"
