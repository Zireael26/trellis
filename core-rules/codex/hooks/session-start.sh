#!/usr/bin/env bash
# session-start.sh — Codex SessionStart dispatcher (spec 072 U4).
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - The one registered SessionStart command. Reads the event once and runs
#     the sibling context hooks its source selects, each fed the same event:
#     startup, resume or no source run session-context.sh then
#     inject-primer-index.sh; compact runs post-compact-context.sh; clear and
#     anything else run nothing. Each hook still checks the source itself.
#   - Project directory: $1, else ${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}},
#     canonicalized and handed to the hooks as CODEX_PROJECT_DIR. When this
#     file sits in a payload (<root>/core-rules/codex/hooks), TRELLIS_ROOT is
#     that root.
#   - Git configuration for every hook is pinned as the launcher's SessionStart
#     route pins it: no system or global config, no fsmonitor, no hooks path.
#   - Emits one additionalContext: the hooks' contexts in that order, joined by
#     a blank line. A hook that fails or prints a malformed envelope is named
#     in a one-line notice in its place; the others keep their context. Hook
#     stderr passes through. Never blocks; exit 0 unless jq is missing.
#
# Attached projects reach it through the stable launcher's `hook session-start`
# route under `env -i` with the attach-time HOME and TRELLIS_HOME, so it runs
# from the verified payload, never from the project's runtime anchor.
#
# Dependencies: jq (required).

set -u

INPUT=$(cat 2>/dev/null || true)

__ss_dir="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 0
case "$__ss_dir" in
  */core-rules/codex/hooks) export TRELLIS_ROOT="${__ss_dir%/core-rules/codex/hooks}" ;;
esac

__ss_project="${1:-${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
if [ -n "$__ss_project" ]; then
  __ss_canonical="$(CDPATH='' cd -P -- "$__ss_project" 2>/dev/null && pwd -P)" && __ss_project="$__ss_canonical"
  export CODEX_PROJECT_DIR="$__ss_project"
fi

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null

__ss_lib="$__ss_dir/lib/deps.sh"
[ -f "$__ss_lib" ] || { echo "session-start: missing sibling lib at $__ss_lib — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090,SC1091
. "$__ss_lib"
_se_require_jq "session-start"

case "$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null)" in
  startup|resume) __ss_hooks="session-context.sh inject-primer-index.sh" ;;
  compact) __ss_hooks="post-compact-context.sh" ;;
  *) exit 0 ;;
esac

# Each hook is judged alone: a hook that exits non-zero or prints anything but
# one SessionStart envelope contributes a one-line notice instead of its
# context, and never costs another hook its context.
__ss_contexts=()
for __ss_hook in $__ss_hooks; do
  __ss_out="$(printf '%s' "$INPUT" | "$__ss_dir/$__ss_hook")"
  __ss_rc=$?
  if [ "$__ss_rc" -ne 0 ]; then
    __ss_contexts+=("$(jq -n --arg hook "$__ss_hook" --arg rc "$__ss_rc" \
      '"Trellis SessionStart: \($hook) exited \($rc); its context is missing."')")
  elif [ -n "$__ss_out" ]; then
    __ss_ctx="$(printf '%s' "$__ss_out" | jq -ce '.hookSpecificOutput.additionalContext | strings' 2>/dev/null)" ||
      __ss_ctx="$(jq -n --arg hook "$__ss_hook" \
        '"Trellis SessionStart: \($hook) returned malformed output; its context is missing."')"
    __ss_contexts+=("$__ss_ctx")
  fi
done

[ "${#__ss_contexts[@]}" -gt 0 ] || exit 0
printf '%s\n' "${__ss_contexts[@]}" | jq -cs '
  {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: join("\n\n")}}'
exit 0
