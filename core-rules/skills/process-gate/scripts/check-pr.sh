#!/usr/bin/env bash
# Gate 1: PR hygiene — branch name, commit format, PR size.
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

# --- PR size ---------------------------------------------------------------
size_limit="${PROCESS_GATE_PR_SIZE_LIMIT:-600}"
size_hard="${PROCESS_GATE_PR_SIZE_HARD:-1200}"
size_valid=true
if [[ ! "$size_limit" =~ ^[0-9]+$ ]]; then
  findings+=("pr-size: PROCESS_GATE_PR_SIZE_LIMIT must be a non-negative integer")
  worst="fail"; size_valid=false
fi
if [[ ! "$size_hard" =~ ^[0-9]+$ ]]; then
  findings+=("pr-size: PROCESS_GATE_PR_SIZE_HARD must be a non-negative integer")
  worst="fail"; size_valid=false
fi

adr_dir="${PROCESS_GATE_ADR_DIR:-docs/adr}"
pr_size_adr_file=""

# Categories are disjoint for the receipt. Lockfiles take precedence, then
# fixtures/snapshots, tests, and generated. Match complete path segments, not
# names like src/test_runner.py or src/fixtures-helper.ts.
pg_size_class() {
  local path="$1" generated="$2" name="${1##*/}" dirs=""
  case "$path" in */*) dirs="/${path%/*}/" ;; esac
  PG_SIZE_CLASS=countable
  # Attribute policy files are always reviewed, even in excluded directories.
  [ "$name" = .gitattributes ] && return 0
  if pg_is_lockfile "$path"; then
    PG_SIZE_CLASS=lock
  else
    case "$dirs" in
      */fixtures/*|*/__fixtures__/*|*/testdata/*|*/snapshots/*|*/__snapshots__/*) PG_SIZE_CLASS=fixture ;;
    esac
    case "$name" in *.snap) PG_SIZE_CLASS=fixture ;; esac
    if [ "$PG_SIZE_CLASS" = countable ]; then
      case "$dirs" in */test/*|*/tests/*|*/__tests__/*) PG_SIZE_CLASS="test" ;; esac
      case "$name" in
        *.bats|*_test.go|*_test.py|test_*.py) PG_SIZE_CLASS="test" ;;
        *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.test.mjs|*.test.cjs|*.test.py|*.test.rb|\
        *.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|*.spec.mjs|*.spec.cjs|*.spec.py|*.spec.rb) PG_SIZE_CLASS="test" ;;
      esac
    fi
    if [ "$PG_SIZE_CLASS" = countable ] && [ "$generated" = 1 ]; then
      PG_SIZE_CLASS=generated
    fi
  fi
}

# The helper determines rename pairs in an isolated base-attribute repository,
# sniffs binaries, and counts text from each pair. Both sides of a rename or
# modification must have the same excluded class. NUL framing preserves paths.
lock_lines=0; test_lines=0; fixture_lines=0; generated_lines=0
total=0; marker_only_lines=0; binary_files=0; binary_code_lines=0
numstat_status=""
size_head="$(pg_range_head "$(pg_project_dir)" "$RANGE" || true)"
while IFS= read -r -d '' stat_adds; do
  if [ -z "$stat_adds" ]; then
    IFS= read -r -d '' numstat_status || numstat_status=1
    break
  fi
  if ! IFS= read -r -d '' stat_dels || ! IFS= read -r -d '' old_f ||
     ! IFS= read -r -d '' f || ! IFS= read -r -d '' old_present ||
     ! IFS= read -r -d '' new_present || ! IFS= read -r -d '' old_generated ||
     ! IFS= read -r -d '' new_generated || ! IFS= read -r -d '' new_marker_only ||
     ! IFS= read -r -d '' stat_binary_code; then
    numstat_status=1; break
  fi
  if [[ ! "$old_present$new_present$old_generated$new_generated$new_marker_only" =~ ^[01]{5}$ ]] ||
     [[ ! "$stat_binary_code" =~ ^[0-9]+$ ]] ||
     [ -z "$old_f" ] || [ -z "$f" ] || [ "$old_present$new_present" = 00 ]; then
    numstat_status=1; break
  fi
  if [ "$old_present" = 0 ] && [ "$new_present" = 1 ]; then
    case "$f" in "$adr_dir"/*.md) [ -n "$pr_size_adr_file" ] || pr_size_adr_file="$f" ;; esac
  fi
  if [ "$stat_adds:$stat_dels" = '-:-' ]; then
    binary_files=$((binary_files + 1))
    binary_code_lines=$((binary_code_lines + stat_binary_code))
    continue
  fi
  if [[ ! "$stat_adds" =~ ^[0-9]+$ ]] || [[ ! "$stat_dels" =~ ^[0-9]+$ ]]; then
    numstat_status=1; break
  fi
  total=$((total + stat_adds + stat_dels))
  pg_size_class "$old_f" "$old_generated"; old_class="$PG_SIZE_CLASS"
  pg_size_class "$f" "$new_generated"; new_class="$PG_SIZE_CLASS"
  [ "$old_present" = 1 ] || old_class="$new_class"
  [ "$new_present" = 1 ] || new_class="$old_class"
  if [ "$old_class" = "$new_class" ]; then
    case "$new_class" in
      lock) lock_lines=$((lock_lines + stat_adds + stat_dels)) ;;
      fixture) fixture_lines=$((fixture_lines + stat_adds + stat_dels)) ;;
      test) test_lines=$((test_lines + stat_adds + stat_dels)) ;;
      generated)
        generated_lines=$((generated_lines + stat_adds + stat_dels))
        if [ "$old_present" = 0 ] && [ "$new_marker_only" = 1 ]; then
          marker_only_lines=$((marker_only_lines + stat_adds + stat_dels))
        fi ;;
    esac
  fi
done < <(rc=0; python3 -I "$SKILL_DIR/scripts/lib/pr-size.py" "$RANGE" "$PG_CONFIG_BASE" "$size_head" 2>/dev/null || rc=$?; printf '\0%s\0' "$rc")
excluded=$((lock_lines + test_lines + fixture_lines + generated_lines))
if [ "$numstat_status" != 0 ] || [ "$excluded" -gt "$total" ]; then
  findings+=("pr-size: unable to compute diff stats for range $RANGE")
  findings+=("pr-size: unable to enumerate changed files for range $RANGE")
  findings+=("pr-size: unable to enumerate added files for range $RANGE")
  worst="fail"
  total=0; lock_lines=0; test_lines=0; fixture_lines=0; generated_lines=0; excluded=0
  marker_only_lines=0; binary_files=0; binary_code_lines=0
fi

countable=$((total - excluded))

# Invariant: hard-cap exemption requires an ADR *added* in the range (references/pr-hygiene.md
# must name the oversized change and explain why splitting harms clarity). Existing ADRs
# do not qualify; the oversized change remains a warn requiring reviewer ack even with the ADR.
# A validated decimal beyond the shell's integer range exceeds any countable
# line count; test's overflow diagnostic need not be shown for that case.
if $size_valid && [ "$countable" -gt "$size_hard" ] 2>/dev/null; then
  if [ -n "$pr_size_adr_file" ]; then
    # Exempted from `fail`, never from view: an oversized range still has to be
    # acknowledged by a reviewer, so it stays a warn rather than a silent pass.
    findings+=("pr-size: $countable lines > hard cap $size_hard — ADR exception: $pr_size_adr_file; record reviewer ack of the size in the PR description")
    [ "$worst" = "pass" ] && worst="warn"
  else
    findings+=("pr-size: $countable lines > hard cap $size_hard — split, or add an ADR under $adr_dir explaining why splitting harms clarity")
    worst="fail"
  fi
elif $size_valid && [ "$countable" -gt "$size_limit" ] 2>/dev/null; then
  findings+=("pr-size: $countable lines > $size_limit — request reviewer ack in PR description")
  [ "$worst" = "pass" ] && worst="warn"
fi

# New files excluded solely by their own marker remain visible and require
# acknowledgement above the warn threshold; they do not count toward the cap.
if $size_valid && [ "$marker_only_lines" -gt "$size_limit" ] 2>/dev/null; then
  findings+=("pr-size: $marker_only_lines marker-only generated addition lines > $size_limit — request reviewer ack in PR description")
  [ "$worst" = "pass" ] && worst="warn"
fi
if $size_valid && [ "$binary_code_lines" -gt "$size_limit" ] 2>/dev/null; then
  findings+=("pr-size: $binary_code_lines binary-code changed lines > $size_limit — request reviewer ack in PR description")
  [ "$worst" = "pass" ] && worst="warn"
fi

# --- Output ----------------------------------------------------------------
size_receipt="$countable lines countable; excluded: tests=$test_lines, fixtures=$fixture_lines, generated=$generated_lines, lockfiles=$lock_lines; marker-only=$marker_only_lines (included in generated); binary-files=$binary_files; binary-code-lines=$binary_code_lines"
case "$worst" in
  pass) pg_log pass "PR hygiene (range=$RANGE, $size_receipt)" ;;
  warn) pg_log warn "PR hygiene (range=$RANGE, $size_receipt)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "PR hygiene (range=$RANGE, $size_receipt)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
