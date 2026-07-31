#!/usr/bin/env bash
# Gate 7: Analyze — deterministic specs/NNN-*/ analyze-report verdict gate.
# Usage: check-analyze.sh [--range=<gitspec>]
#
# If any specs/NNN-*/ path is touched in the range, read each touched spec
# dir's authoritative analyze report `## Verdict:` line:
#   PASS                       -> pass
#   NEEDS-REVISION | BLOCKED   -> warn
#   analyze report missing     -> warn ("analyze not run for <dir>")
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

# Print the authoritative running-verdict report for a spec directory.
# analyze.md is round 1; analyze-<digits>.md is that numbered round. Named
# variants are situational reports and do not participate in resolution.
resolve_analyze_report() {
  local spec_dir="$1"
  local selected=""
  local highest_round="0"
  local candidate name suffix round
  local LC_ALL=C

  if [ -f "$spec_dir/analyze.md" ]; then
    selected="$spec_dir/analyze.md"
    highest_round="1"
  fi

  for candidate in "$spec_dir"/analyze-*.md; do
    [ -f "$candidate" ] || continue
    name="${candidate##*/}"
    suffix="${name#analyze-}"
    suffix="${suffix%.md}"
    case "$suffix" in
      ''|*[!0-9]*) continue ;;
    esac

    round="$suffix"
    while [ "${round#0}" != "$round" ]; do
      round="${round#0}"
    done
    [ -n "$round" ] || round="0"

    # Equal-length normalized digit strings compare lexically without integer overflow.
    # shellcheck disable=SC2071
    if [ "${#round}" -gt "${#highest_round}" ] \
      || { [ "${#round}" -eq "${#highest_round}" ] && [[ "$round" > "$highest_round" ]]; }; then
      selected="$candidate"
      highest_round="$round"
    fi
  done

  [ -n "$selected" ] && printf '%s\n' "$selected"
}

worst="pass"
findings=()
passes=()
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  analyze="$(resolve_analyze_report "$PROJECT_DIR/$dir")"
  if [ -z "$analyze" ]; then
    findings+=("analyze not run for $dir (analyze.md missing)")
    worst="warn"
    continue
  fi
  analyze_name="${analyze##*/}"
  # Read the `## Verdict:` line; tolerate absence / odd casing in the value.
  verdict_line="$(grep -m1 -E '^##[[:space:]]*Verdict:' "$analyze" 2>/dev/null || true)"
  verdict="$(printf "%s" "$verdict_line" | sed -E 's/^##[[:space:]]*Verdict:[[:space:]]*//' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
  case "$verdict" in
    PASS)
      passes+=("$dir: analyze verdict is PASS ($analyze_name)") ;;
    NEEDS-REVISION|BLOCKED)
      findings+=("$dir: analyze verdict is ${verdict} ($analyze_name) — resolve before merge")
      worst="warn" ;;
    *)
      findings+=("$dir: $analyze_name has no recognizable '## Verdict:' line")
      worst="warn" ;;
  esac
done <<EOF
$SPEC_DIRS
EOF

# bash 3.2 + `set -u` treats "${arr[@]}" on an EMPTY array as an unbound
# variable and aborts with exit 1 — which would BLOCK a merge and break this
# gate's load-bearing 0-or-2-only invariant. Both arrays are non-empty on their
# own branch today, but that is an invariant a future branch could silently
# break, so expand defensively rather than rely on it.
case "$worst" in
  pass) pg_log pass "Analyze (range=$RANGE)"; for p in ${passes[@]+"${passes[@]}"}; do pg_finding "$p"; done; exit 0 ;;
  *)    pg_log warn "Analyze (range=$RANGE)"; for f in ${findings[@]+"${findings[@]}"}; do pg_finding "$f"; done; exit 2 ;;
esac
