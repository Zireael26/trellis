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
branch=""
if ! branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
  findings+=("branch: unable to determine current branch")
  worst="fail"
elif [ "$branch" = "HEAD" ] || [ -z "$branch" ]; then
  pg_log info "detached HEAD; skipping branch-name check"
elif [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  pg_log info "on $branch; branch-name check is N/A"
else
  # Invariant: allowed branches are `pi-agent-*` (producer @tintinweb/pi-subagents worktree.js:70)
  # and `<type>/<kebab-slug>` where type ∈ {codex, feature, feat, fix, chore, docs, refactor, test, perf, build, ci, revert}.
  # Producer contract: spec/SKILL.md:37,58,83; plan/SKILL.md:28; tasks/SKILL.md:26 mandate `feature/<slug>`.
  if ! printf "%s" "$branch" | grep -qE '^(pi-agent-[a-z0-9][a-z0-9-]*|(codex|feature|feat|fix|chore|docs|refactor|test|perf|build|ci|revert)/[a-z0-9][a-z0-9-]*)$'; then
    findings+=("branch:$branch — does not match <type>/<kebab-slug>")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

# --- Commit messages -------------------------------------------------------
declare -a bad_subjects=()
commit_subjects=""
if ! commit_subjects="$(git log --format='%s' "$RANGE" 2>/dev/null)"; then
  findings+=("commit-subject: unable to enumerate commit subjects for range $RANGE")
  worst="fail"
else
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Invariant: harness-authored subjects `pi-agent: <description>` (@tintinweb/pi-subagents index.js)
    # and `codex: <description>` are valid types alongside conventional-commit types.
    if ! printf "%s" "$line" | grep -qE '^(pi-agent|codex|feat|fix|refactor|chore|docs|style|test|perf|build|ci|revert)(\([a-z0-9.-]+\))?!?: .{1,}$'; then
      bad_subjects+=("$line")
    elif [ "${#line}" -gt 72 ]; then
      bad_subjects+=("$line  (>72 chars)")
    fi
  done <<< "$commit_subjects"
fi

if [ "${#bad_subjects[@]}" -gt 0 ]; then
  for s in "${bad_subjects[@]}"; do findings+=("commit-subject: $s"); done
  worst="fail"
fi

# --- PR size ---------------------------------------------------------------
size_limit="${PROCESS_GATE_PR_SIZE_LIMIT:-400}"
size_hard="${PROCESS_GATE_PR_SIZE_HARD:-800}"
adr_dir="${PROCESS_GATE_ADR_DIR:-docs/adr}"
pr_size_adr_file=""

diff_stats=""
if ! diff_stats="$(git diff --shortstat "$RANGE" 2>/dev/null)"; then
  findings+=("pr-size: unable to compute diff stats for range $RANGE")
  worst="fail"
  adds=0
  dels=0
else
  adds=0
  dels=0
  if [[ "$diff_stats" =~ ([0-9]+)[[:space:]]insertion ]]; then
    adds="${BASH_REMATCH[1]}"
  fi
  if [[ "$diff_stats" =~ ([0-9]+)[[:space:]]deletion ]]; then
    dels="${BASH_REMATCH[1]}"
  fi
fi
total=$((adds + dels))

# Subtract lockfile/generated lines.
lock_lines=0
changed_files=""
if ! changed_files="$(pg_diff_files "$RANGE")"; then
  findings+=("pr-size: unable to enumerate changed files for range $RANGE")
  worst="fail"
else
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if pg_is_lockfile "$f"; then
      lstat="$(git diff --numstat "$RANGE" -- "$f" | awk '{print $1+$2}')"
      lock_lines=$((lock_lines + ${lstat:-0}))
    fi
  done <<< "$changed_files"
fi

countable=$((total - lock_lines))

# Invariant: hard-cap exemption requires an ADR *added* in the range (references/pr-hygiene.md
# must name the oversized change and explain why splitting harms clarity). Existing ADRs
# do not qualify; the oversized change remains a warn requiring reviewer ack even with the ADR.
added_files=""
if ! added_files="$(git diff --name-only --diff-filter=A "$RANGE" 2>/dev/null)"; then
  findings+=("pr-size: unable to enumerate added files for range $RANGE")
  worst="fail"
else
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      "$adr_dir"/*.md) pr_size_adr_file="$f"; break ;;
    esac
  done <<< "$added_files"
fi

if [ "$countable" -gt "$size_hard" ]; then
  if [ -n "$pr_size_adr_file" ]; then
    # Exempted from `fail`, never from view: an oversized range still has to be
    # acknowledged by a reviewer, so it stays a warn rather than a silent pass.
    findings+=("pr-size: $countable lines > hard cap $size_hard — ADR exception: $pr_size_adr_file; record reviewer ack of the size in the PR description")
    [ "$worst" = "pass" ] && worst="warn"
  else
    findings+=("pr-size: $countable lines > hard cap $size_hard — split, or add an ADR under $adr_dir explaining why splitting harms clarity")
    worst="fail"
  fi
elif [ "$countable" -gt "$size_limit" ]; then
  findings+=("pr-size: $countable lines > $size_limit — request reviewer ack in PR description")
  [ "$worst" = "pass" ] && worst="warn"
fi

# --- Output ----------------------------------------------------------------
case "$worst" in
  pass) pg_log pass "PR hygiene (range=$RANGE, $countable lines)" ;;
  warn) pg_log warn "PR hygiene (range=$RANGE)";  for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "PR hygiene (range=$RANGE)";  for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
