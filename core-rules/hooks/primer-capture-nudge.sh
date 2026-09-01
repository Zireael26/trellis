#!/usr/bin/env bash
# primer-capture-nudge.sh — Stop. Advisory nudge for a new subsystem after an
# edit-heavy turn.
#
# Contract:
#   - stop_hook_active=true, malformed input, a clean tree, or a missing INDEX
#     exits 0 silently. Missing git emits one stderr degradation notice, then
#     exits 0. This hook never blocks a turn.
#   - Edit-heavy means >=3 changed files OR >=200 added/deleted lines, matching
#     code-review-subagent.sh. REVIEW_MIN_FILES and REVIEW_MIN_LINES override
#     the defaults for project-local calibration.
#   - Changed paths covered by an INDEX slug or one of that primer's Entry points
#     are suppressed. Unknown subsystem slugs produce an additionalContext
#     nudge to run /primer <slug>.
#   - Tracked and untracked paths are included; .claude/ and .codex/ state is
#     excluded. Documentation-only changes do not produce a subsystem nudge.
#   - Advisory output is always exit 0. jq remains a required hook dependency;
#     set TRELLIS_NO_JQ_DEGRADE=1 to make a jq-less environment a silent no-op.
#
# Dependencies: jq (required), git (required for change discovery; absence
# emits a degradation notice and becomes an advisory no-op).
#
# Source: Trellis / core-rules / hooks.md (C6, primer-capture-nudge).

set -u

INPUT=$(cat 2>/dev/null || true)

# Source shared lib. An advisory hook must not turn an out-of-date deployment
# into a hard Stop failure; doctor/sync-hooks reports missing siblings.
__pcn_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__pcn_lib" ] || exit 0
# shellcheck source=lib/deps.sh disable=SC1090,SC1091
. "$__pcn_lib"
_se_require_jq "primer-capture-nudge"

# Stop payloads are harness-owned JSON. A malformed payload cannot be used as a
# reliable edit signal, so advisory behavior is to stay silent and pass.
if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  exit 0
fi
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if .stop_hook_active == true then "true" else "false" end' 2>/dev/null || true)
[ "$STOP_ACTIVE" = "true" ] && exit 0

PROJECT_DIR="$(_se_project_dir)"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
PROJECT_DIR="$(pwd -P 2>/dev/null || printf '%s' "$PROJECT_DIR")"

# Git is the only source of a deterministic current-turn change set. No git,
# no diff, no nudge.
command -v git >/dev/null 2>&1 || { printf '%s\n' 'primer-capture-nudge: git not found; degrading to no-op' >&2; exit 0; }
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

REPO_ROOT="$(_se_repo_root "$PROJECT_DIR")"
PRIMERS_DIR="${REPO_ROOT}/.claude/primers"
INDEX="${PRIMERS_DIR}/INDEX.md"
[ -f "$INDEX" ] || exit 0

# Keep every path operation read-only. The temporary lists let the hook handle
# paths with spaces without changing the user's index or worktree.
__pcn_tmp="$(mktemp -d "${TMPDIR:-/tmp}/trellis-primer-nudge.XXXXXX" 2>/dev/null || true)"
[ -n "$__pcn_tmp" ] && [ -d "$__pcn_tmp" ] || exit 0
trap 'rm -rf "$__pcn_tmp"' EXIT

CHANGED_FILE_LIST="${__pcn_tmp}/changed"
INDEX_SLUG_LIST="${__pcn_tmp}/slugs"
INDEX_ENTRY_LIST="${__pcn_tmp}/entries"

_pcn_tracked() {
  # Disable Git's C-style path quoting before the harness-state filter. A
  # quoted non-ASCII path no longer begins with `.claude/` or `.codex/`.
  git -c core.quotePath=false diff HEAD --name-only 2>/dev/null \
    | awk '$0 !~ /^\.(claude|codex)\//'
}

_pcn_untracked() {
  git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null \
    | awk '$0 !~ /^\.(claude|codex)\//'
}

_pcn_changed_names() {
  {
    _pcn_tracked
    _pcn_untracked
  } | sort -u | sed '/^[[:space:]]*$/d'
}

_pcn_normpath() {
  printf '%s' "$1" | sed -E 's#^\./##; s#//+#/#; s#/$##'
}

_pcn_safe_threshold() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

_pcn_doc_path() {
  case "$1" in
    *\.md|*\.mdx|*\.rst|*\.txt) return 0 ;;
    *) return 1 ;;
  esac
}

# The default edit-heavy predicate is shared with code-review-subagent. Count
# files from the same tracked+untracked union used for the path analysis below.
_pcn_changed_names > "$CHANGED_FILE_LIST" 2>/dev/null || true
[ -s "$CHANGED_FILE_LIST" ] || exit 0

MIN_FILES="$(_pcn_safe_threshold "${REVIEW_MIN_FILES:-3}" 3)"
MIN_LINES="$(_pcn_safe_threshold "${REVIEW_MIN_LINES:-200}" 200)"
CHANGED_FILES=$(awk 'END { print NR + 0 }' "$CHANGED_FILE_LIST")
TRACKED_LINES=$(git -c core.quotePath=false diff HEAD --numstat 2>/dev/null \
  | awk '$3 !~ /^\.(claude|codex)\// && $1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum + 0 }')
UNTRACKED_LINES=$(_pcn_untracked \
  | while IFS= read -r file; do
      [ -f "$file" ] && wc -l < "$file" 2>/dev/null || true
    done \
  | awk '{ sum += $1 } END { print sum + 0 }')
CHANGED_LINES=$((TRACKED_LINES + UNTRACKED_LINES))
if [ "$CHANGED_FILES" -lt "$MIN_FILES" ] && [ "$CHANGED_LINES" -lt "$MIN_LINES" ]; then
  exit 0
fi

# INDEX is a curated subsystem map. Parse only its locked link format. An
# INDEX with no valid entries is treated as unavailable rather than turning a
# malformed file into a nudge storm.
sed -nE 's/^[[:space:]]*-[[:space:]]*\[([A-Za-z0-9._/-]+)\]\(\.\/[^)]*\).*$/\1/p' "$INDEX" \
  | sort -u > "$INDEX_SLUG_LIST" 2>/dev/null || true
[ -s "$INDEX_SLUG_LIST" ] || exit 0

# For each indexed primer, retain its Entry points. A changed sibling in the
# same entry-point directory is part of that subsystem even when the exact file
# is not one of the three-to-five listed entry points.
: > "$INDEX_ENTRY_LIST"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  primer="${PRIMERS_DIR}/${slug}.md"
  [ -f "$primer" ] || continue
  awk '
    /^##[[:space:]]+Entry points[[:space:]]*$/ { in_entries = 1; next }
    in_entries && /^##[[:space:]]+/ { in_entries = 0 }
    in_entries { print }
  ' "$primer" \
    | sed -nE 's/^[[:space:]]*-[[:space:]]*`([^`]+)`.*/\1/p' \
    | while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        entry="$(_pcn_normpath "$entry")"
        [ -n "$entry" ] || continue
        printf '%s\t%s\n' "$slug" "$entry"
      done >> "$INDEX_ENTRY_LIST"
done < "$INDEX_SLUG_LIST"

_pcn_index_covers() {
  local path="$1" slug entry candidate

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    # Slugs come from a constrained INDEX grammar; reject anything that could
    # be interpreted as a shell pattern in the case expression.
    case "$slug" in *[!A-Za-z0-9._/-]*) continue ;; esac
    case "$path" in
      "$slug"|"$slug"/*|*/"$slug"|*/"$slug"/*) return 0 ;;
    esac
  done < "$INDEX_SLUG_LIST"

  while IFS=$'\t' read -r slug entry; do
    [ -n "$entry" ] || continue
    case "$path" in
      "$entry"|"$entry"/*) return 0 ;;
    esac
  done < "$INDEX_ENTRY_LIST"

  # A file-shaped subsystem (for example src/payments.py) has the same
  # candidate slug as its directory-shaped sibling (src/payments/). Treat an
  # indexed slug as covering both forms.
  candidate="$(_pcn_slug_for_path "$path" 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    while IFS= read -r slug; do
      [ "$slug" = "$candidate" ] && return 0
    done < "$INDEX_SLUG_LIST"
  fi

  return 1
}

# Pick a stable, useful slug from a repo-relative path. Generic source-layout
# roots are stripped so src/billing/... nudges /primer billing rather than the
# unhelpful /primer src. The output is sanitized to the slug alphabet accepted
# by the /primer command.
_pcn_slug_for_path() {
  local path="$1" first rest candidate
  path="$(_pcn_normpath "$path")"
  case "$path" in
    */*)
      first="${path%%/*}"
      rest="${path#*/}"
      ;;
    *)
      first="$path"
      rest=""
      ;;
  esac

  case "$first" in
    src|lib|app|apps|pkg|packages|package|modules|module|services|service|components|component|internal|cmd|server|client|backend|frontend|core|core-rules|tests|test|spec|specs|docs|scripts|config|configs|fixtures|examples|example|bin|build|dist|public|static)
      if [ -n "$rest" ]; then candidate="${rest%%/*}"; else candidate="$first"; fi
      ;;
    *)
      candidate="$first"
      ;;
  esac

  candidate=$(printf '%s' "$candidate" \
    | sed -E 's/\.[^./]+$//; s/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  case "$candidate" in
    ''|.|..|.claude|.codex|primers|INDEX) return 1 ;;
  esac
  printf '%s' "$candidate"
}

# Documentation and harness-state paths are not subsystems. For all other
# changed paths, collect unique uncovered slugs and cap the message so a broad
# refactor remains a small advisory.
MISSING_SLUGS=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .claude/*|.codex/*) continue ;;
  esac
  _pcn_doc_path "$path" && continue
  path="$(_pcn_normpath "$path")"
  _pcn_index_covers "$path" && continue

  slug="$(_pcn_slug_for_path "$path" 2>/dev/null || true)"
  [ -n "$slug" ] || continue
  case $'\n'"${MISSING_SLUGS}"$'\n' in
    *$'\n'"$slug"$'\n'*) continue ;;
  esac
  if [ -n "$MISSING_SLUGS" ]; then MISSING_SLUGS="${MISSING_SLUGS}"$'\n'; fi
  MISSING_SLUGS="${MISSING_SLUGS}${slug}"
  [ "$(printf '%s\n' "$MISSING_SLUGS" | awk 'END { print NR }')" -ge 5 ] && break
done < "$CHANGED_FILE_LIST"

[ -n "$MISSING_SLUGS" ] || exit 0

NUDGES=""
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  if [ -n "$NUDGES" ]; then NUDGES="${NUDGES}; "; fi
  NUDGES="${NUDGES}/primer ${slug}"
done <<EOF
$MISSING_SLUGS
EOF

MESSAGE="primer-capture-nudge: edit-heavy changes touched subsystem(s) without an INDEX primer. Consider ${NUDGES} to capture the context."
jq -nc --arg ctx "$MESSAGE" '{additionalContext: $ctx}'
exit 0
