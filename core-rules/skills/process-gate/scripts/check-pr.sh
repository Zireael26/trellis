#!/usr/bin/env bash
# Gate 1: PR hygiene — branch name and commit format.
# Usage: check-pr.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config "$@" || exit 1
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
if ! commit_subjects="$(git log --format='%H%x09%s' "$RANGE" 2>/dev/null)"; then
  findings+=("commit-subject: unable to enumerate commit subjects for range $RANGE")
  worst="fail"
else
  while IFS= read -r record; do
    [ -z "$record" ] && continue
    commit="${record%%$'\t'*}"
    line="${record#*$'\t'}"
    case "$line" in
      'Merge '*)
        parents="$(git rev-list --parents -n 1 "$commit" 2>/dev/null)" || parents=""
        read -r -a parent_fields <<< "$parents"
        if [ "${#parent_fields[@]}" -ge 3 ]; then continue; fi ;;
      'Revert "'*'"')
        body="$(git show -s --format='%b' "$commit" 2>/dev/null)" || body=""
        valid_revert=0
        while IFS= read -r body_line || [ -n "$body_line" ]; do
          case "$body_line" in
            'This reverts commit '*)
              reverted="${body_line#This reverts commit }"
              case "$reverted" in *.) reverted="${reverted%.}" ;; *) continue ;; esac
              case "$reverted" in ''|*[!0-9a-fA-F]*) continue ;; esac
              [ "${#reverted}" -ge 7 ] && [ "${#reverted}" -le 64 ] || continue
              if git cat-file -e "${reverted}^{commit}" 2>/dev/null; then valid_revert=1; break; fi ;;
          esac
        done <<< "$body"
        if [ "$valid_revert" -eq 1 ]; then continue; fi ;;
    esac
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

# --- Output ----------------------------------------------------------------
case "$worst" in
  pass) pg_log pass "PR hygiene (range=$RANGE)" ;;
  warn) pg_log warn "PR hygiene (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "PR hygiene (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
