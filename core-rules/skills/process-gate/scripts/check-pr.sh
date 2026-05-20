#!/usr/bin/env bash
# Gate 1: PR hygiene — branch name, commit format, PR size.
# Usage: check-pr.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
RANGE="$(pg_parse_range "$@")"

worst="pass"
findings=()

# --- Branch name -----------------------------------------------------------
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [ "$branch" = "HEAD" ] || [ -z "$branch" ]; then
  pg_log info "detached HEAD; skipping branch-name check"
elif [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  pg_log info "on $branch; branch-name check is N/A"
else
  if ! printf "%s" "$branch" | grep -qE '^(antigravity|codex|feat|fix|chore|docs|refactor|test|perf|build|ci|revert)/[a-z0-9][a-z0-9-]*$'; then
    findings+=("branch:$branch — does not match <type>/<kebab-slug>")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

# --- Commit messages -------------------------------------------------------
declare -a bad_subjects=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Conventional Commits: type(scope)?(!)? : subject  -> first line
  if ! printf "%s" "$line" | grep -qE '^(feat|fix|refactor|chore|docs|style|test|perf|build|ci|revert)(\([a-z0-9.-]+\))?!?: .{1,}$'; then
    bad_subjects+=("$line")
  elif [ "${#line}" -gt 72 ]; then
    bad_subjects+=("$line  (>72 chars)")
  fi
done < <(git log --format='%s' "$RANGE" 2>/dev/null)

if [ "${#bad_subjects[@]}" -gt 0 ]; then
  for s in "${bad_subjects[@]}"; do findings+=("commit-subject: $s"); done
  worst="fail"
fi

# --- PR size ---------------------------------------------------------------
size_limit="${PROCESS_GATE_PR_SIZE_LIMIT:-400}"
size_hard="${PROCESS_GATE_PR_SIZE_HARD:-800}"
adr_dir="${PROCESS_GATE_ADR_DIR:-docs/adr}"
pr_size_adr_file=""

read -r adds dels < <(pg_diff_stats "$RANGE")
total=$((adds + dels))

# Subtract lockfile/generated lines.
lock_lines=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if pg_is_lockfile "$f"; then
    lstat="$(git diff --numstat "$RANGE" -- "$f" | awk '{print $1+$2}')"
    lock_lines=$((lock_lines + ${lstat:-0}))
  fi
done < <(pg_diff_files "$RANGE")

countable=$((total - lock_lines))

while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    "$adr_dir"/*.md) pr_size_adr_file="$f"; break ;;
  esac
done < <(pg_diff_files "$RANGE")

size_context=""
if [ "$countable" -gt "$size_hard" ]; then
  if [ -n "$pr_size_adr_file" ]; then
    size_context=", ADR exception: $pr_size_adr_file"
  else
    findings+=("pr-size: $countable lines > hard cap $size_hard — split or attach ADR")
    worst="fail"
  fi
elif [ "$countable" -gt "$size_limit" ]; then
  findings+=("pr-size: $countable lines > $size_limit — request reviewer ack in PR description")
  [ "$worst" = "pass" ] && worst="warn"
fi

# --- Output ----------------------------------------------------------------
case "$worst" in
  pass) pg_log pass "PR hygiene (range=$RANGE, $countable lines${size_context})" ;;
  warn) pg_log warn "PR hygiene (range=$RANGE)";  for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "PR hygiene (range=$RANGE)";  for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
