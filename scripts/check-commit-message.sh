#!/usr/bin/env bash
# Validate the first authored commit-message header using Trellis's native
# Conventional Commit grammar. Generated Git headers are exempt below.

set -euo pipefail

# Git supplies one message-file argument. Keep the historical no-op behavior
# for an absent/non-file argument; Git itself rejects an empty message.
if [ "$#" -lt 1 ] || [ ! -f "$1" ]; then
  exit 0
fi

MSG_FILE=$1
HEADER=''
BLANK_RE='^[[:space:]]*$'
COMMENT_RE='^[[:space:]]*#'

# The first line that is neither blank nor a comment is the authored header.
while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ $BLANK_RE || $line =~ $COMMENT_RE ]]; then
    continue
  fi
  HEADER=$line
  break
done < "$MSG_FILE"

[ -n "$HEADER" ] || exit 0

# Git-shaped subjects are exempt only with corresponding repository evidence.
# This is kept in sync with the standalone githooks and husky templates.
git_operation_marker() (
  marker="$(git rev-parse --git-path "$1" 2>/dev/null)" || return 1
  [ -f "$marker" ]
)

generated_header_allowed() (
  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  case "$HEADER" in
    "Merge "*)
      git_operation_marker MERGE_HEAD || return 1
      marker="$(git rev-parse --git-path MERGE_MSG 2>/dev/null)" || return 1
      [ -f "$marker" ] || return 1
      generated=""
      IFS= read -r generated < "$marker" || [ -n "$generated" ] || return 1
      [ "$HEADER" = "$generated" ] ;;
    'Revert "'*'"')
      git_operation_marker REVERT_HEAD && return 0
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          'This reverts commit '*)
            sha="${line#This reverts commit }"
            case "$sha" in *.) sha="${sha%.}" ;; *) continue ;; esac
            case "$sha" in ''|*[!0-9a-fA-F]*) continue ;; esac
            [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 64 ] || continue
            git cat-file -e "${sha}^{commit}" 2>/dev/null && return 0 ;;
        esac
      done < "$MSG_FILE"
      return 1 ;;
    'fixup! '*|'squash! '*|'amend! '*)
      target="${HEADER#*! }"
      [ -n "$target" ] || return 1
      git log --format='%s' HEAD 2>/dev/null | grep -Fx -- "$target" >/dev/null ;;
    'Applying '*)
      [ -n "${HEADER#Applying }" ] && git_operation_marker rebase-apply/applying ;;
    *) return 1 ;;
  esac
)

case "$HEADER" in
  'Merge '*|'Revert '*|'fixup!'*|'squash!'*|'amend!'*|'Applying '*)
    if generated_header_allowed; then exit 0; fi ;;
esac

TYPES='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test|draft|merge'
HEADER_RE="^(${TYPES})(\\([a-z0-9._/-]+\\))?!?: .+\$"

fail() {
  printf '[commit-msg] %s\n' "$1" >&2
  printf '\n' >&2
  printf '  header: %s\n' "$HEADER" >&2
  printf '\n' >&2
  printf '  Expected: <type>[(scope)][!]: <description>\n' >&2
  printf '  Types:    build chore ci docs feat fix perf refactor revert style test draft merge\n' >&2
  printf '\n' >&2
  printf '  e.g.  feat(baseline): track HRV on the log scale\n' >&2
  printf '        fix!: reject out-of-range nights instead of clamping\n' >&2
  exit 1
}

if [[ ! $HEADER =~ $HEADER_RE ]]; then
  fail 'not a conventional commit.'
fi

[ "${#HEADER}" -le 100 ] \
  || fail "header is ${#HEADER} chars; the limit is 100."

SUBJECT=${HEADER#*: }
[ -n "$SUBJECT" ] || fail 'description is empty.'
case "$SUBJECT" in
  *.) fail 'description must not end with a period.' ;;
esac

exit 0
