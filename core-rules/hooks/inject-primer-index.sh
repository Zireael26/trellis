#!/usr/bin/env bash
# inject-primer-index.sh — SessionStart (startup|resume). Inject primer INDEX
# with deterministic drift flags so every new session sees the available
# primers and which need /primer-refresh.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - Runs on SessionStart with source=startup or source=resume.
#   - Reads <canonical-root>/.claude/primers/INDEX.md.
#   - For each primer file: parses `pinned_to:` frontmatter + Entry points
#     section, runs `git rev-list --count <pinned>..HEAD -- <entry-paths>`,
#     buckets FRESH (0) / WARM (1-10) / STALE (11+). Verifies each entry
#     path exists.
#   - Emits {"hookSpecificOutput":{"hookEventName":"SessionStart",
#            "additionalContext":"..."}}.
#   - Output trimmed to ≤ 1500 chars. Never blocks. Exit 0 always.
#   - Skips silently if .claude/primers/INDEX.md absent (opt-in projects).
#
# Dependencies: jq (required), git (optional — degrades gracefully).
#
# Status: new in v0.3.1.

set -u

INPUT=$(cat 2>/dev/null || true)

__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "inject-primer-index: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "inject-primer-index"

SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"')
case "$SOURCE" in
  startup|resume) ;;
  *) exit 0 ;;
esac

PROJECT_DIR=$(_se_project_dir)
cd "$PROJECT_DIR" 2>/dev/null || exit 0
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")

PRIMERS_DIR="${REPO_ROOT}/.claude/primers"
INDEX="${PRIMERS_DIR}/INDEX.md"
[ -f "$INDEX" ] || exit 0  # opt-in; project hasn't bootstrapped primers

# Need git to compute drift; without it, just emit the index unchanged.
HAS_GIT=0
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HAS_GIT=1
fi

OUT="## Primers (auto-injected)"$'\n'

# Each non-empty, non-comment line in INDEX.md is expected to be:
#   - [slug](./slug.md) — description
# We parse out the slug (between `[` and `]`) and locate <slug>.md.
in_fence=0
while IFS= read -r line; do
  # toggle fence state on ``` lines; skip content inside fences
  case "$line" in
    '```'*) in_fence=$(( 1 - in_fence )); continue ;;
  esac
  [ "$in_fence" -eq 0 ] || continue

  # skip blanks + headings + comments + bold/em markers
  case "$line" in
    ''|\#*|'<!--'*) continue ;;
  esac
  # extract slug from `- [slug](./slug.md) — desc`
  slug=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*\[\([^]]*\)\].*/\1/p')
  [ -n "$slug" ] || continue

  # skip template-placeholder slugs (contain < or >)
  case "$slug" in
    *'<'*|*'>'*) continue ;;
  esac

  primer="${PRIMERS_DIR}/${slug}.md"
  if [ ! -f "$primer" ]; then
    OUT="${OUT}- ${slug} — MISSING_FILE (run /primer-check)"$'\n'
    continue
  fi

  status="FRESH"
  detail=""

  if [ "$HAS_GIT" = "1" ]; then
    pinned=$(awk '/^pinned_to:/ {print $2; exit}' "$primer")
    if [ -z "$pinned" ]; then
      status="BROKEN"
      detail="no pinned_to"
    elif ! git -C "$REPO_ROOT" cat-file -e "${pinned}^{commit}" 2>/dev/null; then
      status="UNREACHABLE_PIN"
      detail="${pinned:0:7}"
    else
      # Collect entry-point paths from the "## Entry points" section.
      # Convention: each entry is a bullet line with a backtick-wrapped path.
      paths=$(awk '
        /^## Entry points/ {flag=1; next}
        /^## / {flag=0}
        flag && /`/ {
          n = split($0, arr, "`")
          if (n >= 2) print arr[2]
        }
      ' "$primer")

      if [ -n "$paths" ]; then
        # Verify existence; collect missing.
        missing=""
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          [ -e "${REPO_ROOT}/${p}" ] || missing="${missing}${p} "
        done <<< "$paths"

        if [ -n "$missing" ]; then
          status="MISSING_PATHS"
          detail=$(printf '%s' "$missing" | awk '{print $1; if (NF>1) print "+"NF-1" more"}' | tr '\n' ' ')
        else
          # Count commits touching entry points since pinned SHA.
          __path_arr=()
          while IFS= read -r __p; do
            __path_arr+=("$__p")
          done <<< "$paths"
          count=$(git -C "$REPO_ROOT" rev-list --count "${pinned}..HEAD" -- "${__path_arr[@]}" 2>/dev/null || echo 0)
          if [ "$count" -eq 0 ]; then
            status="FRESH"
          elif [ "$count" -le 10 ]; then
            status="WARM"; detail="${count} commits"
          else
            status="STALE"; detail="${count} commits → /primer-refresh"
          fi
        fi
      else
        status="NO_ENTRY_POINTS"
        detail="primer missing ## Entry points section"
      fi
    fi
  fi

  if [ -n "$detail" ]; then
    OUT="${OUT}- ${slug} — ${status} (${detail})"$'\n'
  else
    OUT="${OUT}- ${slug} — ${status}"$'\n'
  fi
done < "$INDEX"

# Hard cap.
if [ "${#OUT}" -gt 1500 ]; then
  OUT=$(printf '%s' "$OUT" | head -c 1480)
  OUT="${OUT}
...[trimmed]"
fi

jq -nc --arg ctx "$OUT" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

exit 0
