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

# Git-generated/replayed headers are not authored Conventional Commit
# subjects, so leave them to Git's own machinery.
case "$HEADER" in
  "Merge "*|"Revert "*|"fixup!"*|"squash!"*|"amend!"*|"Applying "*)
    exit 0
    ;;
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
