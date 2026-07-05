#!/usr/bin/env bats
# Tests for Claude ↔ Codex hook harness parity (RC.5, Workstream fold-in of the
# cross-model review finding).
#
# Trellis ships every hook twice — the Claude copy under core-rules/hooks/ and
# its Codex twin under core-rules/codex/hooks/ — kept in lockstep so both
# harnesses run the same governance. A hook added to only one tree silently
# starves the other harness of that automation (the RC.5 plan's first draft did
# exactly this). This test asserts strict bidirectional parity of the *.sh set
# so any future untwinned hook fails CI instead of shipping half-wired.
#
# Static test against the real repo (not a fixture): the trees themselves are
# the thing under test.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CLAUDE_HOOKS="$REPO/core-rules/hooks"
CODEX_HOOKS="$REPO/core-rules/codex/hooks"

_basenames() {
  # basenames of *.sh directly under $1, sorted; empty if none.
  ls "$1"/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | sort
}

@test "hook trees exist" {
  [ -d "$CLAUDE_HOOKS" ]
  [ -d "$CODEX_HOOKS" ]
}

@test "every Claude hook has a Codex twin" {
  local missing=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ -f "$CODEX_HOOKS/$h" ] || missing="$missing $h"
  done < <(_basenames "$CLAUDE_HOOKS")
  [ -z "$missing" ] || {
    echo "Claude hooks missing a Codex twin under core-rules/codex/hooks/:$missing"
    false
  }
}

@test "every Codex hook has a Claude twin" {
  local missing=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ -f "$CLAUDE_HOOKS/$h" ] || missing="$missing $h"
  done < <(_basenames "$CODEX_HOOKS")
  [ -z "$missing" ] || {
    echo "Codex hooks missing a Claude twin under core-rules/hooks/:$missing"
    false
  }
}
