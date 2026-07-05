#!/usr/bin/env bash
# Gate 5: Docs discipline — CHANGELOG, gotchas, ADR triggers.
# Usage: check-docs.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"
cd "$PROJECT_DIR"

worst="pass"
findings=()

# Defaults — overridable via local.config.sh
DEFAULT_CHANGELOG_PATHS=("src/" "app/" "lib/" "components/" "packages/" "scripts/" "content/")
CHANGELOG_PATHS=("${PROCESS_GATE_CHANGELOG_PATHS[@]:-${DEFAULT_CHANGELOG_PATHS[@]}}")
CHANGELOG_FILE="${PROCESS_GATE_CHANGELOG_FILE:-CHANGELOG.md}"
ADR_DIR="${PROCESS_GATE_ADR_DIR:-docs/adr}"
DEFAULT_ADR_TRIGGERS=("next.config." "middleware." "package.json" "tsconfig.json" "drizzle.config." "prisma/schema.prisma" "vite.config.")
ADR_TRIGGERS=("${PROCESS_GATE_ADR_TRIGGERS[@]:-${DEFAULT_ADR_TRIGGERS[@]}}")
PROJECT_EPM="${PROCESS_GATE_PROJECT_EPM:-}"

# Get changed files
changed_files="$(pg_diff_files "$RANGE" || true)"

# --- Changelog presence ----------------------------------------------------
if [ ! -f "$CHANGELOG_FILE" ]; then
  findings+=("$CHANGELOG_FILE: missing — seed via Keep a Changelog 1.1.0 format")
  worst="fail"
else
  # Did any code-trigger path change?
  code_changed=false
  for f in $changed_files; do
    for prefix in "${CHANGELOG_PATHS[@]}"; do
      case "$f" in
        "$prefix"*) code_changed=true; break 2 ;;
      esac
    done
  done

  if $code_changed; then
    if ! printf "%s\n" "$changed_files" | grep -Fxq "$CHANGELOG_FILE"; then
      findings+=("$CHANGELOG_FILE: not updated despite code changes under: ${CHANGELOG_PATHS[*]}")
      worst="fail"
    else
      # Touched, but did it gain a real entry? docs.md advertises this warn; the
      # script never implemented it (RC.5 closes the reference↔script gap). An
      # entry is a new '- ' bullet or a '### ' impact subhead; whitespace- or
      # heading-only touches don't count. WARN only (never fail) — advisory, and
      # a diff hiccup must not wedge the gate. Doctrine: core-rules/references/versioning.md.
      if ! git diff "$RANGE" -- "$CHANGELOG_FILE" 2>/dev/null | grep -Eq '^\+[[:space:]]*(- |### )'; then
        findings+=("$CHANGELOG_FILE: touched but no new entry added — add a '- ' bullet under the right impact group (Added/Changed/Fixed/Deprecated/Removed/Security); see core-rules/references/versioning.md")
        [ "$worst" = "pass" ] && worst="warn"
      fi
    fi
  fi
fi

# --- ADR triggers ----------------------------------------------------------
adr_trigger_changed=false
for f in $changed_files; do
  for trigger in "${ADR_TRIGGERS[@]}"; do
    case "$f" in
      *"$trigger"*) adr_trigger_changed=true; break 2 ;;
    esac
  done
done

if $adr_trigger_changed; then
  # Either a new/modified file in $ADR_DIR, OR a commit body referencing an existing ADR
  adr_diff="$(printf "%s\n" "$changed_files" | grep -E "^${ADR_DIR}/" || true)"
  body_ref="$(git log --format='%B' "$RANGE" 2>/dev/null | grep -oE 'ADR-[0-9]+' | head -1 || true)"
  if [ -z "$adr_diff" ] && [ -z "$body_ref" ]; then
    findings+=("ADR: trigger paths changed without new/updated ADR or commit-body reference")
    worst="fail"
  fi
fi

# --- gotchas.md hint -------------------------------------------------------
gotcha_phrases='turns out|surprised|took two hours|weird interaction|incompatible with|silently'
if git log --format='%B' "$RANGE" 2>/dev/null | grep -qiE "$gotcha_phrases"; then
  if ! printf "%s\n" "$changed_files" | grep -qE '^gotchas\.md$'; then
    findings+=("gotchas.md: commit message hints suggest a gotcha entry might be useful (warn only)")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

# --- Project EPM -----------------------------------------------------------
if [ -n "$PROJECT_EPM" ] && [ -f "$PROJECT_EPM" ]; then
  process_change=false
  for f in $changed_files; do
    case "$f" in
      .husky/*|.githooks/*|.claude/hooks/*|.claude/skills/*) process_change=true; break ;;
    esac
  done
  if $process_change && ! printf "%s\n" "$changed_files" | grep -qF "$PROJECT_EPM"; then
    findings+=("$PROJECT_EPM: process trigger paths changed without EPM update")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

case "$worst" in
  pass) pg_log pass "Docs discipline (range=$RANGE)" ;;
  warn) pg_log warn "Docs discipline (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "Docs discipline (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
