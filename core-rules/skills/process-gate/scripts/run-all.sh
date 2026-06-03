#!/usr/bin/env bash
# Run all canonical gates + project-local stack-profile validators.
# Usage: run-all.sh [--range=<gitspec>] [--mode=push|merge]
# Output: a single verdict block as defined in SKILL.md.
#
# --mode (default merge) controls PR-shape downgrade (DL-P7-02): at push, a
# FAIL in the PR-shape gates (PR hygiene, Docs discipline, Analyze) is remapped
# to WARN so a WIP push is not blocked on shape. The always-hard gates
# (Secrets, Bypass markers, Tests, Security) NEVER downgrade at any mode. At
# merge the verdict is strict — no downgrade. A missing/unknown --mode value
# resolves to merge (the fail-closed choice).

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

# common.sh sets `set -euo pipefail`. The aggregator INTENTIONALLY runs
# child gates that may exit non-zero (warn=2, fail=1) — disable -e so those
# returns get captured into RESULTS rather than exiting the aggregator.
set +e

pg_load_config
RANGE="$(pg_parse_range "$@")"
PG_MODE="$(pg_parse_mode "$@")"
export PG_MODE
PROJECT_DIR="$(pg_project_dir)"

# Bash 3.2 compatibility: parallel arrays instead of associative arrays.
# idx: 0 PR hygiene, 1 Secrets, 2 Bypass markers, 3 Tests & coverage,
#      4 Docs discipline, 5 Stack profile, 6 Security (diff), 7 Analyze.
LABELS=("PR hygiene" "Secrets" "Bypass markers" "Tests & coverage" "Docs discipline" "Stack profile" "Security (diff)" "Analyze")
RESULTS=("" "" "" "" "" "" "" "")
FINDINGS=("" "" "" "" "" "" "" "")

set_result() {
  local idx="$1" status="$2" out="$3"
  RESULTS[$idx]="$status"
  FINDINGS[$idx]="$out"
}

# PR-shape downgrade set (DL-P7-02): a FAIL in these gates is remapped to WARN
# ONLY when PG_MODE=push. The always-hard gates (1 Secrets, 2 Bypass markers,
# 3 Tests, 6 Security) are deliberately absent and NEVER downgrade. Stack
# profile (5) is set inline (not via run_gate) and keeps its validator verdict.
pg_is_pr_shape_idx() {
  case "$1" in
    0|4|7) return 0 ;;
    *)     return 1 ;;
  esac
}

run_gate() {
  local idx="$1" script="$2"
  local out rc status
  out="$(bash "$script" --range="$RANGE" 2>&1)"; rc=$?
  case "$rc" in
    0) status="pass" ;;
    2) status="warn" ;;
    *) status="fail" ;;
  esac
  # Mode-aware downgrade: at push, a PR-shape FAIL becomes WARN. Never at merge,
  # never for the always-hard gates. Keyed on idx membership + PG_MODE only.
  if [ "$status" = "fail" ] && [ "$PG_MODE" = "push" ] && pg_is_pr_shape_idx "$idx"; then
    status="warn"
    out="${out}"$'\n'"  [process-gate] mode=push: PR-shape FAIL downgraded to WARN (would BLOCK at merge)"
  fi
  set_result "$idx" "$status" "$out"
}

resolve_stack_validator() {
  local v="$1"

  if [ -z "$v" ]; then
    return 1
  fi

  case "$v" in
    /*)
      # -f (regular-file), NOT -x: the validator is run via `bash "$vpath"`
      # (idx-5 block), so the exec bit is irrelevant. A present-but-644
      # validator (the state after a mirror-sync, which does not preserve the
      # exec bit) must resolve, not be treated as missing (DL-P7-08).
      [ -f "$v" ] && printf "%s" "$v"
      return
      ;;
  esac

  local dirs=()
  if [ -n "${CODEX_PROJECT_DIR:-}" ]; then
    dirs=(
      "$PROJECT_DIR/.agents/skills/process-gate-local"
      "$PROJECT_DIR/.claude/skills/process-gate-local"
      "$PROJECT_DIR/.agents/skills/process-gate"
      "$PROJECT_DIR/.claude/skills/process-gate"
      "$SKILL_DIR"
    )
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    dirs=(
      "$PROJECT_DIR/.claude/skills/process-gate-local"
      "$PROJECT_DIR/.agents/skills/process-gate-local"
      "$PROJECT_DIR/.claude/skills/process-gate"
      "$PROJECT_DIR/.agents/skills/process-gate"
      "$SKILL_DIR"
    )
  else
    dirs=(
      "$PROJECT_DIR/.agents/skills/process-gate-local"
      "$PROJECT_DIR/.claude/skills/process-gate-local"
      "$PROJECT_DIR/.agents/skills/process-gate"
      "$PROJECT_DIR/.claude/skills/process-gate"
      "$SKILL_DIR"
    )
  fi

  local dir candidate
  for dir in "${dirs[@]}"; do
    candidate="$dir/$v"
    # -f (regular-file), NOT -x — see the absolute-path arm above (DL-P7-08).
    if [ -f "$candidate" ]; then
      printf "%s" "$candidate"
      return
    fi
  done
}

run_gate 0 "$SKILL_DIR/scripts/check-pr.sh"
run_gate 1 "$SKILL_DIR/scripts/check-secrets.sh"
run_gate 2 "$SKILL_DIR/scripts/check-bypass.sh"
run_gate 3 "$SKILL_DIR/scripts/check-tests.sh"
run_gate 4 "$SKILL_DIR/scripts/check-docs.sh"

# Stack profile (idx 5)
profile="${PROCESS_GATE_STACK_PROFILE:-}"
if [ -z "$profile" ] || [ "$profile" = "n-a" ]; then
  set_result 5 "n/a" "profile=${profile:-<unset>} (no validators run)"
else
  validators=("${PROCESS_GATE_STACK_VALIDATORS[@]:-}")
  if [ "${#validators[@]}" -eq 0 ]; then
    set_result 5 "warn" "profile=$profile but PROCESS_GATE_STACK_VALIDATORS empty"
  else
    worst="pass"; combined=""
    for v in "${validators[@]}"; do
      [ -z "$v" ] && continue
      vpath="$(resolve_stack_validator "$v")"
      if [ -z "$vpath" ]; then
        combined="${combined}validator missing: $v"$'\n'
        worst="fail"; continue
      fi
      vout="$(bash "$vpath" --range="$RANGE" 2>&1)"; vrc=$?
      combined="${combined}${vout}"$'\n'
      case "$vrc" in
        0) ;;
        2) [ "$worst" = "pass" ] && worst="warn" ;;
        *) worst="fail" ;;
      esac
    done
    set_result 5 "$worst" "$combined"
  fi
fi

# Security (diff) (idx 6) — always-hard. Adapter wraps security-gate run-diff.sh.
run_gate 6 "$SKILL_DIR/scripts/check-security-diff.sh"

# Analyze (idx 7) — PR-shape (downgrades at push). Adapter never exits 1.
run_gate 7 "$SKILL_DIR/scripts/check-analyze.sh"

# --- Render verdict --------------------------------------------------------
glyph() {
  case "$1" in
    pass) printf "✅ pass" ;;
    warn) printf "⚠️  warn" ;;
    fail) printf "❌ fail" ;;
    n/a)  printf "➖ n/a"  ;;
    *)    printf "%s" "$1" ;;
  esac
}

overall="MERGEABLE"
for r in "${RESULTS[@]}"; do
  case "$r" in
    fail) overall="BLOCKED"; break ;;
    warn) [ "$overall" = "MERGEABLE" ] && overall="NEEDS CHANGES" ;;
  esac
done

printf "## process-gate verdict (mode=%s)\n\n" "$PG_MODE"
for i in 0 1 2 3 4 5 6 7; do
  printf "%-18s %s\n" "${LABELS[$i]}:" "$(glyph "${RESULTS[$i]}")"
done
printf "\nOverall: %s\n\n" "$overall"

if [ "$overall" != "MERGEABLE" ]; then
  printf "## Findings\n\n"
  for i in 0 1 2 3 4 5 6 7; do
    case "${RESULTS[$i]}" in
      pass|n/a) ;;
      *) printf "### %s\n%s\n\n" "${LABELS[$i]}" "${FINDINGS[$i]}" ;;
    esac
  done
fi

case "$overall" in
  MERGEABLE) exit 0 ;;
  "NEEDS CHANGES") exit 2 ;;
  BLOCKED) exit 1 ;;
esac
