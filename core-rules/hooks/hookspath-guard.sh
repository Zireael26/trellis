#!/usr/bin/env bash
# hookspath-guard.sh — PostToolUse (Bash). core.hooksPath drift advisory.
# Source: Trellis / core-rules / hooks.md (spec 055 R4.3)
#
# husky's `prepare` runs `git config core.hooksPath .husky/_` during a package
# install. Git then never invokes the Trellis dispatcher, so the pre-push gate
# goes quiet and no git hook can notice its own removal. After a Bash command
# that could have caused that, this hook re-reads the local core.hooksPath and,
# when it is not exactly the recorded managed path, adds one advisory naming
# `trellis doctor --fix`.
#
# Contract:
#   - Pre-filter first, with no subprocess: tool_input.command is matched
#     case-insensitively against whole-word npm, pnpm, yarn, bun, npx, husky,
#     corepack, make and just, and against the substrings core.hookspath,
#     core_hookspath and `worktree add`. Anything else exits 0 at once.
#   - Otherwise the shared lib/hookspath-check.sh runs the read-only R4.1 check.
#   - `git ... worktree add` with a core.hooksPath override also gets the
#     unseeded-worktree advisory: run `trellis worktree sync <path>` first.
#   - Advisory only: never writes git config or any file. Exit 0 always.
#
# Dependencies: bash; jq and git only past the pre-filter (absent → silent).

set -u

INPUT=""
IFS= read -r -d '' INPUT || true

__hp_json_str='"((\\.|[^"\\])*)"'
__hp_command_re="\"tool_input\"[[:space:]]*:[[:space:]]*\\{[^{}]*\"command\"[[:space:]]*:[[:space:]]*${__hp_json_str}"
[[ "$INPUT" =~ $__hp_command_re ]] || exit 0
CMD="${BASH_REMATCH[1]}"

__hp_edge='(^|[^A-Za-z0-9_.-])'
__hp_tail='([^A-Za-z0-9_.-]|$)'
__hp_words="${__hp_edge}(npm|pnpm|yarn|bun|npx|husky|corepack|make|just)${__hp_tail}"
shopt -s nocasematch
__hp_hit=false
__hp_override=false
if [[ "$CMD" =~ core\.hookspath|core_hookspath ]]; then
  __hp_hit=true
  __hp_override=true
fi
[[ "$CMD" =~ worktree\ add ]] && __hp_hit=true
[[ "$CMD" =~ $__hp_words ]] && __hp_hit=true
shopt -u nocasematch
[ "$__hp_hit" = true ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
__hp_lib="$(dirname "${BASH_SOURCE[0]}")/lib/hookspath-check.sh"
[ -f "$__hp_lib" ] || exit 0
# shellcheck source=lib/hookspath-check.sh disable=SC1090,SC1091
. "$__hp_lib"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MSG="$(trellis_hookspath_drift_line "$PROJECT_DIR" 2>/dev/null)"

# R2.8: a worktree created with hooks off was never seeded.
if [ "$__hp_override" = true ] && [[ "$CMD" =~ worktree\ add ]]; then
  __hp_path="<path>"
  __hp_skip=false
  read -r -a __hp_words_after <<<"${CMD#*worktree add}"
  for __hp_word in "${__hp_words_after[@]+"${__hp_words_after[@]}"}"; do
    if [ "$__hp_skip" = true ]; then __hp_skip=false; continue; fi
    case "$__hp_word" in
      -b|-B|--reason) __hp_skip=true ;;
      -*) ;;
      *) __hp_path="$__hp_word"; break ;;
    esac
  done
  __hp_sync="\`git worktree add\` ran with core.hooksPath overridden, so the new worktree was never seeded with Trellis hooks: run \`trellis worktree sync $__hp_path\` before its first push."
  MSG="${MSG}${MSG:+
}${__hp_sync}"
fi

[ -n "$MSG" ] || exit 0
jq -nc --arg msg "$MSG" '{additionalContext: $msg}'
exit 0
