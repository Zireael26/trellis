#!/usr/bin/env bash
# block-destructive.sh — Codex PreToolUse on Bash. Deny rm/git-force/SQL/.env reads.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Reads Codex tool event JSON on stdin.
#   - Emits schema-valid JSON on stdout and the blocking reason on stderr;
#     exits 2 when a rule fires.
#   - Exits 0 when allowed.
#
# Rules: core-rules/hooks/rules/destructive.json, compiled into lib/guard-rules.sh
# by scripts/gen-guard-rules.py and matched with bash builtins. Change a rule in
# the JSON, never here or in the include.
#
# Dependencies: jq (required — one call per invocation).
#
# Base: github.com/iamfakeguru/claude-md (MIT). Extensions vs upstream:
#   - DELETE FROM ... without a WHERE clause now triggers.
#   - **/secrets/** glob on any reader is blocked.
#   - git reset --hard with no target, HEAD / HEAD~N / origin/* all covered.

set -u

INPUT=$(cat)

# Degrade gracefully if jq is missing — surface the problem via stderr, don't block.
# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "block-destructive: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "block-destructive" block

__gr_lib="$(dirname "${BASH_SOURCE[0]}")/lib/guard-rules.sh"
[ -f "$__gr_lib" ] || { echo "block-destructive: missing sibling lib at $__gr_lib — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/guard-rules.sh disable=SC1090
. "$__gr_lib"

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

if _gr_destructive codex "$COMMAND"; then
  printf '{"decision":"block","reason":%s}\n' "$GR_DENY_JSON"
  printf '%s\n' "$GR_DENY_REASON" >&2
  exit 2
fi
exit 0
