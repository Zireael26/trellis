#!/usr/bin/env bash
# Gate 7: Analyze — deterministic specs/NNN-*/ analyze-report verdict gate.
# Usage: check-analyze.sh [--range=<gitspec>]
#
# If any specs/NNN-*/ path is touched in the range, read each touched spec
# dir's authoritative analyze report `## Verdict:` line:
#   PASS  /  PASS (<qualifier>) -> pass
#   NEEDS-REVISION | BLOCKED   -> warn (exact match only)
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

pg_load_config "$@" || exit 2  # this gate never exits 1; run-all blocks on config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

# Git's NUL framing preserves quoted, non-ASCII and newline-containing paths.
# Keep the directory names in an array rather than splitting them on lines.
SPEC_DIRS=()
specs_found=false
while IFS= read -r -d '' path; do
  case "$path" in specs/[0-9]*/*) ;; *) continue ;; esac
  rest="${path#specs/}"
  dir="specs/${rest%%/*}"
  duplicate=false
  for seen in ${SPEC_DIRS[@]+"${SPEC_DIRS[@]}"}; do
    if [ "$seen" = "$dir" ]; then duplicate=true; break; fi
  done
  if ! $duplicate; then SPEC_DIRS+=("$dir"); specs_found=true; fi
done < <(git -C "$PROJECT_DIR" diff --name-only -z "$RANGE" 2>/dev/null)

if ! $specs_found; then
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
for dir in ${SPEC_DIRS[@]+"${SPEC_DIRS[@]}"}; do
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
  # Invariant: `PASS` with any trailing qualifier (e.g. `PASS (1 warning)`) is still PASS.
  # NEEDS-REVISION and BLOCKED are exact only — qualified forms are intentionally unrecognized.
  # See: core-rules/skills/process-gate/tests/check-analyze.bats "analyze Verdict: PASS (qualified) -> pass (exit 0)"
  case "$verdict" in
    PASS|PASS\(*)
      passes+=("$dir: analyze verdict is PASS ($analyze_name)") ;;
    NEEDS-REVISION|BLOCKED)
      findings+=("$dir: analyze verdict is ${verdict} ($analyze_name) — resolve before merge")
      worst="warn" ;;
    *)
      findings+=("$dir: $analyze_name has no recognizable '## Verdict:' line")
      worst="warn" ;;
  esac
done

# bash 3.2 + `set -u` treats "${arr[@]}" on an EMPTY array as an unbound
# variable and aborts with exit 1 — which would BLOCK a merge and break this
# gate's load-bearing 0-or-2-only invariant. Both arrays are non-empty on their
# own branch today, but that is an invariant a future branch could silently
# break, so expand defensively rather than rely on it.
case "$worst" in
  pass) pg_log pass "Analyze (range=$RANGE)"; for p in ${passes[@]+"${passes[@]}"}; do pg_finding "$p"; done; exit 0 ;;
  *)    pg_log warn "Analyze (range=$RANGE)"; for f in ${findings[@]+"${findings[@]}"}; do pg_finding "$f"; done; exit 2 ;;
esac
