#!/usr/bin/env bash
# Gate 7: Analyze — deterministic specs/NNN-*/analyze.md verdict gate.
# Usage: check-analyze.sh [--range=<gitspec>]
#
# If any specs/NNN-*/ path is touched in the range, read each touched spec
# dir's analyze.md `## Verdict:` line:
#   PASS                       -> pass
#   NEEDS-REVISION | BLOCKED   -> warn
#   analyze.md missing         -> warn ("analyze not run for <dir>")
# Worst across touched dirs wins. If no spec dir is touched -> pass.
#
# LOAD-BEARING: this gate NEVER exits 1. The constitution caps analyze at
# advisory, so it must never BLOCK a merge — exit 0 (pass) or 2 (warn) ONLY.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

# common.sh sets `set -euo pipefail`. `grep` exits 1 when no spec dir matches
# (the COMMON case) and that under -e+pipefail would abort the script with
# exit 1 -> BLOCKED. Disable -e so the only reachable exits are explicit 0/2.
set +e

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

# Touched spec dirs (unique). grep no-match (rc 1) is fine: `|| true` keeps it
# from tripping anything, and an empty list means no spec touched -> pass.
SPEC_DIRS="$(git -C "$PROJECT_DIR" diff --name-only "$RANGE" 2>/dev/null \
  | grep -E '^specs/[0-9][^/]*/' \
  | sed -E 's#^(specs/[0-9][^/]*)/.*#\1#' \
  | sort -u || true)"

if [ -z "$SPEC_DIRS" ]; then
  pg_log pass "Analyze: no spec dir touched (range=$RANGE)"
  exit 0
fi

worst="pass"
findings=()
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  analyze="$PROJECT_DIR/$dir/analyze.md"
  if [ ! -f "$analyze" ]; then
    findings+=("analyze not run for $dir (analyze.md missing)")
    worst="warn"
    continue
  fi
  # Read the `## Verdict:` line; tolerate absence / odd casing in the value.
  verdict_line="$(grep -m1 -E '^##[[:space:]]*Verdict:' "$analyze" 2>/dev/null || true)"
  verdict="$(printf "%s" "$verdict_line" | sed -E 's/^##[[:space:]]*Verdict:[[:space:]]*//' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
  case "$verdict" in
    PASS) ;;
    NEEDS-REVISION|BLOCKED)
      findings+=("$dir: analyze verdict is ${verdict} — resolve before merge")
      worst="warn" ;;
    *)
      findings+=("$dir: analyze.md has no recognizable '## Verdict:' line")
      worst="warn" ;;
  esac
done <<EOF
$SPEC_DIRS
EOF

case "$worst" in
  pass) pg_log pass "Analyze (range=$RANGE)"; exit 0 ;;
  *)    pg_log warn "Analyze (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done; exit 2 ;;
esac
