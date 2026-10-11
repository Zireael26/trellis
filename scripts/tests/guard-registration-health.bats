#!/usr/bin/env bats
# Doctor rows for stall-safe bright-line guards: perl must exist (ERROR), and a
# rendered guard registration must start through guard-supervise.pl with a 30s
# timeout (WARN, re-render only). Fixtures are private copies of the templates.
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/guard-health.XXXXXX")"
  ROOT="$SANDBOX/project"
  mkdir -p "$ROOT/.claude" "$ROOT/.codex" "$SANDBOX/bin"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/health-checks.sh"
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

# Rendered settings plus the supervisor their commands reference.
render() {
  cp "$REPO/core-rules/templates/claude-settings.local.json" "$ROOT/.claude/settings.local.json"
  cp "$REPO/core-rules/templates/codex-hooks.local.json" "$ROOT/.codex/hooks.json"
  mkdir -p "$ROOT/.trellis/runtime/core-rules/hooks/lib" "$ROOT/.claude/hooks/lib"
  : > "$ROOT/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl"
  : > "$ROOT/.claude/hooks/lib/guard-supervise.pl"
}

@test "perl on PATH -> silent; missing -> ERROR" {
  run hc_guard_supervisor_perl
  [ "$status" -eq "$HC_OK" ]
  [ -z "$output" ]
  local tool
  for tool in bash sh; do ln -s "$(command -v "$tool")" "$SANDBOX/bin/$tool"; done
  if output="$(PATH="$SANDBOX/bin" hc_guard_supervisor_perl)"; then status=0; else status=$?; fi
  [ "$status" -eq "$HC_ERROR" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"perl not found"* ]]
}

@test "freshly rendered templates -> silent OK; no rendered settings -> silent OK" {
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ]
  [ -z "$output" ]
  render
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "status=$status $output"; false; }
  [ -z "$output" ]
}

@test "a 5s or unsupervised guard registration -> WARN naming file, guard and remedy" {
  local f="$ROOT/.claude/settings.local.json"
  render
  jq '(.hooks.PreToolUse[].hooks[] | select(.command | contains("/block-destructive.sh")) | .timeout) = 5' \
    "$f" > "$f.next" && mv "$f.next" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *".claude/settings.local.json: block-destructive (timeout 5)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"detach + attach"* ]]
  f="$ROOT/.codex/hooks.json"
  jq '(.hooks.PreToolUse[].hooks[] | select(.command | contains("/reread-guard.sh")) | .command) =
      "\"$PWD/.trellis/runtime/core-rules/codex/hooks/reread-guard.sh\""' "$f" > "$f.next" && mv "$f.next" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *".codex/hooks.json: reread-guard (timeout 30, unsupervised)"* ]] || { echo "$output"; false; }
}

@test "a supervised registration whose guard-supervise.pl is missing -> WARN" {
  render
  mv "$ROOT/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl" "$SANDBOX/aside.pl"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *".claude/settings.local.json: block-destructive (timeout 30, supervisor missing)"* ]] || { echo "$output"; false; }
  [[ "$output" == *".codex/hooks.json: reread-guard (timeout 30, supervisor missing)"* ]] || { echo "$output"; false; }
}

@test "a legacy direct-copy .claude/settings.json is checked too" {
  local f="$ROOT/.claude/settings.json"
  render
  cp "$REPO/core-rules/templates/claude-settings.json" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "status=$status $output"; false; }
  jq '(.hooks.PreToolUse[].hooks[] | select(.command | contains("/skill-preload-guard.sh")) | .timeout) = 5' \
    "$f" > "$f.next" && mv "$f.next" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *".claude/settings.json: skill-preload-guard (timeout 5)"* ]] || { echo "$output"; false; }
}

@test "unreadable rendered settings -> WARN" {
  printf '{' > "$ROOT/.claude/settings.local.json"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *".claude/settings.local.json: unreadable"* ]]
}

@test "portable doctor reports both rows only when they are not healthy" {
  grep -q 'if perl_row="$(hc_guard_supervisor_perl)"; then :; else' "$REPO/scripts/doctor.sh"
  grep -q 'if guard_row="$(hc_guard_registrations "$root")"; then :; else' "$REPO/scripts/doctor.sh"
}
