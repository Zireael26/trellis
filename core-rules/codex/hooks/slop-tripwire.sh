#!/usr/bin/env bash
# slop-tripwire.sh — Codex PostToolUse on Edit|Write|MultiEdit. Advisory only;
# never blocks.
# Source: Trellis / core-rules / codex hooks.
#
# Twin of core-rules/hooks/slop-tripwire.sh. The only divergence is the output
# shape: Codex 0.142+ requires PostToolUse context under `hookSpecificOutput`
# with a matching hookEventName, not a top-level `additionalContext`, so this
# emits through `_se_emit_hook_context` instead of building the object inline.
#
# Contract:
#   - Normalizes the event and scans every declared existing mutation target.
#   - Extension outside the anti-slop pattern set → exit 0 silently.
#   - Carved-out path (test / generated / migration / vendored / lockfile) →
#     exit 0 silently.
#   - Otherwise scans ONLY the added lines of that one file and emits
#     {"hookSpecificOutput": {"hookEventName": "PostToolUse",
#      "additionalContext": "slop-tripwire: <pattern> at <file>:<line> — …"}},
#     one line per finding, capped at 5.
#   - Exit 0 on every detection path: a finding is context, never a block
#     (spec 037 D7 — blocking on slop lives in the gate row alone).
#
# Escape: SLOP_TRIPWIRE=off short-circuits before anything else, jq included.
#
# Dependencies: jq (required, same fail-closed contract as every other hook —
# the one non-zero exit here). git is optional: no repo, no commit yet, or an
# untracked file means every line of the file counts as added.
#
# Budget: O(diff of one file). No repo walk, no linter, no network.
#
# Spec task: 037-anti-slop T6 (plan §4 file 4). The pattern set and the
# carve-out globs live in lib/slop-patterns.sh — never inline one here, or the
# audit and gate consumers drift from the tripwire.
#
# Known approximation: suppression (`SAFETY:`, a same-line idiom) is looked for
# on the matched line and the added line before it, so a pre-existing SAFETY:
# comment above a newly added `cast(` still trips. Advisory posture is what
# makes that acceptable — the cost is one context line.

set -u

# Kill switch first: an operator who turned this off gets silence even on a box
# with no jq.
[ "${SLOP_TRIPWIRE:-}" = "off" ] && exit 0

INPUT=$(cat)

# Source shared libs (siblings of this script) + enforce jq dependency.
#
# A missing sibling lib exits 0 in SILENCE, unlike every blocking hook's loud
# exit 1. Two reasons: the whole contract is "advisory, never blocks", and a
# project whose `hooks/lib` predates the anti-slop rollout would otherwise print
# a re-run-sync-hooks line on every Edit and Write of every file type, including
# the .md files this hook has no interest in — the warning fatigue the tier is
# designed to avoid. Absence is reported where it is actionable instead: doctor's
# anti-slop presence row.
__st_lib_dir="$(dirname "${BASH_SOURCE[0]}")/lib"
[ -f "$__st_lib_dir/deps.sh" ] || exit 0
# shellcheck source=lib/deps.sh disable=SC1090
. "$__st_lib_dir/deps.sh"
_se_require_jq "slop-tripwire"
[ -f "$__st_lib_dir/slop-patterns.sh" ] || exit 0
# shellcheck source=lib/slop-patterns.sh disable=SC1090
. "$__st_lib_dir/slop-patterns.sh"

__ta_lib="$(dirname "${BASH_SOURCE[0]}")/lib/action-normalize.sh"
[ -f "$__ta_lib" ] || __ta_lib="$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib/action-normalize.sh"
[ -f "$__ta_lib" ] || exit 0
# shellcheck source=../../hooks/lib/action-normalize.sh disable=SC1090
. "$__ta_lib"

NORMALIZED=$(_ta_normalize_action codex post_action "$INPUT") || exit 0
[ "$(printf '%s' "$NORMALIZED" | jq -r '.action.family')" = "file_mutation" ] || exit 0
[ "$(printf '%s' "$NORMALIZED" | jq -r '.result.status')" != "failed" ] || exit 0
ACTION_CWD=$(printf '%s' "$NORMALIZED" | jq -r '.cwd // empty')
[ -d "$ACTION_CWD" ] || ACTION_CWD="$(_se_project_dir)"

MSG=""
SHOWN=0
TOTAL=0

scan_target() {
local FILE_PATH="$1" SLOP_LANG FILE_DIR FILE_BASE SLOP_REL_PATH PAIRS FINDINGS idx id lineno

# Extension outside the pattern set: silence, no work.
SLOP_LANG=$(slop_lang_for_path "$FILE_PATH") || return 0

FILE_DIR=$(dirname "$FILE_PATH")
FILE_BASE=$(basename "$FILE_PATH")
[ -d "$FILE_DIR" ] || return 0

# Carve-outs are matched against the REPO-RELATIVE path. The harness hands this
# hook an absolute one, and the globs match a directory name anywhere in the
# path, so probing the absolute path lets any ancestor above the work-tree root
# carve out the whole project: a checkout under `~/build/proj` matches
# `**/build/**` and the tripwire goes silent everywhere, with no signal. Outside
# a work tree there is no root to strip and no ratchet either, so the absolute
# path is the only thing left to probe.
#
# `--show-prefix` rather than stripping `--show-toplevel`: the toplevel comes
# back physically resolved, so on macOS a `/var/...` path (symlinked to
# `/private/var`) never prefix-matches its own root and the strip silently
# no-ops. The prefix is relative by construction.
if __ST_PREFIX=$(git -C "$FILE_DIR" rev-parse --show-prefix 2>/dev/null); then
  SLOP_REL_PATH="${__ST_PREFIX}${FILE_BASE}"
else
  SLOP_REL_PATH="$FILE_PATH"
fi
slop_path_carved_out "$SLOP_REL_PATH" && return 0

# __st_added_lines — prints "<new-file line number>\t<content>" for every added
# line of the touched file, cheapest source first:
#   - tracked file in a repo with a commit → `git diff HEAD` at -U0, so only the
#     lines this session actually added are scanned (the ratchet);
#   - anything else (untracked file, repo with no commit, no git at all) → the
#     whole file, because every line of a new file IS an added line.
# The pathspec is `./<basename>` under `git -C <dir>` so an absolute path whose
# prefix is a symlink (macOS /var → /private/var) still resolves inside the repo.
__st_added_lines() {
  if git -C "$FILE_DIR" rev-parse --verify HEAD >/dev/null 2>&1 \
     && git -C "$FILE_DIR" ls-files --error-unmatch -- "./$FILE_BASE" >/dev/null 2>&1; then
    git -C "$FILE_DIR" diff --no-color --no-ext-diff -U0 HEAD -- "./$FILE_BASE" | awk '
      /^@@/ {
        # @@ -<old> +<new-start>[,<count>] @@ — the first +<digits> is the start.
        if (match($0, /\+[0-9]+/)) { n = substr($0, RSTART + 1, RLENGTH - 1) + 0; hunk = 1 }
        next
      }
      hunk && /^\+/ { printf "%d\t%s\n", n, substr($0, 2); n++ }
    '
  else
    [ -f "$FILE_PATH" ] || return 0
    awk '{ printf "%d\t%s\n", FNR, $0 }' "$FILE_PATH"
  fi
}

PAIRS=$(mktemp) || return 0

__st_added_lines > "$PAIRS"
[ -s "$PAIRS" ] || { rm -f "$PAIRS"; return 0; }

# slop_scan_text is grep-like: status 1 means the added lines are clean.
FINDINGS=$(cut -f2- "$PAIRS" | slop_scan_text "$SLOP_LANG") || { rm -f "$PAIRS"; return 0; }
[ -n "$FINDINGS" ] || { rm -f "$PAIRS"; return 0; }

TOTAL=$((TOTAL + $(printf '%s\n' "$FINDINGS" | grep -c '^')))
# Findings carry their index into $PAIRS, not a file line — one sed per shown
# finding (≤5) turns it back into the real line number.
while IFS=$'\t' read -r idx id _; do
  [ -n "$idx" ] || continue
  [ "$SHOWN" -lt 5 ] || continue
  lineno=$(sed -n "${idx}p" "$PAIRS" | cut -f1)
  MSG="${MSG}${MSG:+
}slop-tripwire: ${id} at ${FILE_PATH}:${lineno}"
  SHOWN=$((SHOWN + 1))
  [ "$SHOWN" -ge 5 ] && break
done < <(printf '%s\n' "$FINDINGS")
rm -f "$PAIRS"
}

while IFS=$'\t' read -r OPERATION SOURCE_PATH DESTINATION; do
  case "$OPERATION" in
    delete) continue ;;
    rename) TARGET_PATH="$DESTINATION" ;;
    create|update) TARGET_PATH="$SOURCE_PATH" ;;
    *) continue ;;
  esac
  FILE_PATH=$(_ta_resolve_path "$ACTION_CWD" "$TARGET_PATH") || continue
  [ -f "$FILE_PATH" ] || continue
  scan_target "$FILE_PATH"
done < <(_ta_targets_tsv "$NORMALIZED")

if [ "$TOTAL" -gt "$SHOWN" ]; then
  MSG="${MSG} (+$((TOTAL - SHOWN)) more)"
fi

[ -n "$MSG" ] && _se_emit_hook_context "PostToolUse" "${MSG} — evidence doctrine: ${SLOP_DOCTRINE_REF}"
exit 0
