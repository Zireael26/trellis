#!/usr/bin/env bats
# Tests for check-bypass.sh — sections §3a (core.hooksPath active-disable)
# and §3b (commit.gpgsign actively false).
#
# Approach: each test stands up a fresh fixture git repo (single empty commit
# on `main`) and sets only the config knob under test. With no `.husky/`,
# `.githooks/`, `package.json`, or `.claude/settings.json` in the fixture,
# every other section in check-bypass.sh is silent — so the exit code is a
# clean signal for the new checks.
#
# Exit codes follow pg_exit_code: 0=pass, 1=fail, 2=warn.
#   §3a (core.hooksPath disabled) -> fail (exit 1)
#   §3b (commit.gpgsign=false)    -> warn (exit 2)

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-bypass.sh"
  # Interpreter under test. macOS hosts run these hooks under /bin/bash 3.2, so
  # default there rather than to whichever bash PATH resolves first (homebrew
  # 5.x on a dev box would let a 3.2-incompatible edit ship green). Override
  # with BASH_BIN=/path/to/bash to exercise another build.
  BASH_BIN="${BASH_BIN:-/bin/bash}"
  [ -x "$BASH_BIN" ] || BASH_BIN="bash"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Run check-bypass.sh against the fixture from inside it (so the default
# range resolves to `main..HEAD`, which is empty on a single-commit repo).
# The script is invoked through $BASH_BIN explicitly: letting its shebang
# resolve would hand execution back to `env bash` and skip the 3.2 check.
run_check() {
  run "$BASH_BIN" -c "cd '$PROJECT_DIR' && '$BASH_BIN' '$SCRIPT'"
}

# Add an empty commit carrying the given body, then run check-bypass.sh over
# just that commit (HEAD~1..HEAD) so commit-trailer detection is isolated.
commit_body_and_check() {
  local body="$1"
  (
    cd "$PROJECT_DIR" || exit 1
    git commit --allow-empty -q -m "chore: trailer test" -m "$body"
  )
  run "$BASH_BIN" -c "cd '$PROJECT_DIR' && '$BASH_BIN' '$SCRIPT' --range=HEAD~1..HEAD"
}

# --- §3a: core.hooksPath active-disable ---

@test "§3a: core.hooksPath=/dev/null -> fail with finding" {
  git -C "$PROJECT_DIR" config core.hooksPath /dev/null
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"core.hooksPath"* ]] || { echo "$output"; false; }
  [[ "$output" == *"actively set to disable hooks"* ]] || { echo "$output"; false; }
  [[ "$output" == *"/dev/null"* ]]
}

@test "§3a: core.hooksPath unset -> no finding from this check (exit 0)" {
  # Sanity: ensure key is not set in the fixture. `if`, not a leading `!`: a
  # negated command never trips `set -e`, so the bare form was inert and a
  # fixture that DID carry the key would have sailed past it.
  if git -C "$PROJECT_DIR" config --get core.hooksPath; then
    echo "fixture precondition violated: core.hooksPath is set"; false
  fi
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively set to disable hooks"* ]]
}

@test "§3a: core.hooksPath=/custom/path -> no finding (legitimate override)" {
  git -C "$PROJECT_DIR" config core.hooksPath /custom/path
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively set to disable hooks"* ]]
}

# --- §3b: commit.gpgsign actively disabled ---

@test "§3b: commit.gpgsign=false -> warn with finding (exit 2)" {
  git -C "$PROJECT_DIR" config commit.gpgsign false
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"commit.gpgsign"* ]] || { echo "$output"; false; }
  [[ "$output" == *"actively disabled via persistent config"* ]]
}

@test "§3b: commit.gpgsign=true -> no finding (exit 0)" {
  git -C "$PROJECT_DIR" config commit.gpgsign true
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively disabled via persistent config"* ]]
}

@test "§3b: commit.gpgsign unset -> no finding (exit 0)" {
  if git -C "$PROJECT_DIR" config --get commit.gpgsign; then
    echo "fixture precondition violated: commit.gpgsign is set"; false
  fi
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively disabled via persistent config"* ]]
}

# --- §1a: PROCESS_GATE_SKIP=1 commit-trailer detection ---

@test "§1a: PROCESS_GATE_SKIP=1 trailer in range -> warn (exit 2) with finding" {
  commit_body_and_check "PROCESS_GATE_SKIP=1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"PROCESS_GATE_SKIP=1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"must be justified"* ]]
}

@test "§1a: no PROCESS_GATE_SKIP trailer -> no finding from this check (exit 0)" {
  commit_body_and_check "ordinary body with no override trailers"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PROCESS_GATE_SKIP=1 found"* ]]
}

@test "§1 baseline: TRELLIS_ALLOW_MAIN_PUSH=1 trailer in range -> warn (exit 2)" {
  commit_body_and_check "TRELLIS_ALLOW_MAIN_PUSH=1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"TRELLIS_ALLOW_MAIN_PUSH=1"* ]]
}

# --- §4: hooks registration across both settings files ---
#
# Portable attachment registers hooks in the machine-local settings.local.json
# and leaves the tracked settings.json free of them, so either file satisfies
# the check.

# Write a settings file into the fixture's .claude/ dir.
write_settings() {
  mkdir -p "$PROJECT_DIR/.claude"
  cat > "$PROJECT_DIR/.claude/$1" <<EOF
$2
EOF
}

@test "§4: hooks only in settings.local.json (attachment layout) -> pass (exit 0)" {
  write_settings settings.json '{ "permissions": { "allow": [] } }'
  write_settings settings.local.json '{
  "hooks": {
    "PreToolUse": [{ "matcher": "Edit", "hooks": [{ "type": "command", "command": "reread-guard" }] }]
  }
}'
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: hooks in neither settings file -> fail naming both (exit 1)" {
  write_settings settings.json '{ "permissions": { "allow": [] } }'
  write_settings settings.local.json '{ "permissions": { "deny": [] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
  [[ "$output" == *".claude/settings.json"* ]]
  [[ "$output" == *".claude/settings.local.json"* ]]
}

@test "§4: hooks in settings.json (legacy layout) -> pass (exit 0)" {
  write_settings settings.json '{
  "hooks": {
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "dod-receipt" }] }]
  }
}'
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: empty hooks block in both -> fail (no registered event)" {
  write_settings settings.json '{ "hooks": {} }'
  write_settings settings.local.json '{ "hooks": {} }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

# The tampering shape the gate exists for: keep the event keys, strip the hook
# entries. An event key alone is not a registration.
@test "§4: event keys with no hook entries -> fail (exit 1)" {
  write_settings settings.json '{ "hooks": { "PreToolUse": [] } }'
  write_settings settings.local.json '{ "hooks": { "Stop": [], "PreToolUse": [] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: junk empty-name event key -> fail (exit 1)" {
  write_settings settings.json '{ "hooks": { "": [] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: no settings file in an unattached project -> no finding (exit 0)" {
  [ ! -e "$PROJECT_DIR/.claude" ]
  [ ! -e "$PROJECT_DIR/.trellis.json" ]
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]]
}

# Deleting the settings pair outright is otherwise the cheapest bypass: on a
# project whose manifest proves it is attached, absence fails like an emptied
# block rather than passing in silence.
@test "§4: attached project with no settings file at all -> fail (exit 1)" {
  printf '{"schema_version":1,"project_id":"fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  [ ! -e "$PROJECT_DIR/.claude" ]
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
  [[ "$output" == *"neither file exists"* ]]
}
