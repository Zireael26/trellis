#!/usr/bin/env bats
# Hermetic LaunchAgent and materialize-before-dispatch contract.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
RUNNER="${TEST_HEALTH_RUNNER_OVERRIDE:-$REPO_ROOT/scripts/run-test-health-host.sh}"
INSTALLER="${TEST_HEALTH_INSTALLER_OVERRIDE:-$REPO_ROOT/scripts/install-test-health-launchd.sh}"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/state"
  export TRELLIS_ROOT="$SANDBOX/canonical" TRELLIS_FLEET=personal
  export TRELLIS_LAUNCHER="$HOME/.local/bin/trellis"
  export CLAUDE_BIN="$HOME/.local/bin/claude"
  export TEST_HEALTH_LOCK_FILE="$SANDBOX/lock"
  export TEST_HEALTH_FAKE_CWD="$SANDBOX/claude-cwd"
  export TEST_HEALTH_FAKE_PROMPT="$SANDBOX/claude-prompt"
  export TEST_HEALTH_FAKE_ARGS="$SANDBOX/claude-args"
  export LAUNCHER_CALLS="$SANDBOX/launcher-calls"
  export LAUNCHCTL_CALLS="$SANDBOX/launchctl-calls"
  export TASK_ROOT="$TRELLIS_HOME/tasks/$TRELLIS_FLEET/test-health"
  export MANIFEST="$TASK_ROOT/manifest.json" PROMPT="$TASK_ROOT/prompt.md"
  RAW_PROMPT="$TRELLIS_ROOT/scheduled-tasks/test-health/prompt.md"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_ROOT/scheduled-tasks/test-health" "$TRELLIS_HOME" "$SANDBOX/bin"
  chmod 700 "$TRELLIS_HOME"
  printf '%s\n' 'RAW TEMPLATE {{TASK_ROOT}} {{OUTPUT_ROOT}}' > "$RAW_PROMPT"
  cat > "$TRELLIS_ROOT/trellis.config.json" <<'EOF'
{"schema_version":2,"maintainer_name":"Test Maintainer","github_user":"tester","harnesses":["claude"],"template":{"remote":"https://example.invalid/trellis.git","branch":"main"}}
EOF
  cat > "$TRELLIS_HOME/config.json" <<EOF
{"schema_version":1,"source_root":"$TRELLIS_ROOT","release_remote":"fixture://release","active_cli_release":"1.0.0-fixture","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$SANDBOX/projects"]},"team":{"discovery_roots":["$SANDBOX/projects"]}}}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  mkdir -p "$SANDBOX/projects"
  cat > "$SANDBOX/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -sm) printf '%s\n' "${FAKE_HOST:-Darwin arm64}" ;;
  -s) exec /usr/bin/uname -s ;;
  *) exec /usr/bin/uname "$@" ;;
esac
EOF
  cat > "$TRELLIS_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHER_CALLS"
[ "$*" = "task materialize --fleet $TRELLIS_FLEET test-health --home $TRELLIS_HOME" ] || exit 44
[ "${MATERIALIZE_FAIL:-0}" != 1 ] || exit 42
[ -f "$TEST_HEALTH_LOCK_FILE" ] || exit 43
mkdir -p "$TASK_ROOT"
if [ "${OMIT_MANIFEST:-0}" != 1 ]; then
  printf '%s\n' "${MANIFEST_BODY:-$DEFAULT_MANIFEST}" > "$MANIFEST"
fi
if [ "${OMIT_PROMPT:-0}" != 1 ]; then
  if [ "${PROMPT_BODY+x}" ]; then
    printf '%s' "$PROMPT_BODY" > "$PROMPT"
  else
    printf '%s\n' 'Materialized prompt with trailing newline.' > "$PROMPT"
  fi
fi
EOF
  cat > "$CLAUDE_BIN" <<'EOF'
#!/usr/bin/env bash
[ -f "$TEST_HEALTH_LOCK_FILE" ] || exit 45
printf '%s\n' "$PWD" > "$TEST_HEALTH_FAKE_CWD"
printf '%s\0' "$@" > "$TEST_HEALTH_FAKE_ARGS"
last="${@: -1}"
printf '%s' "$last" > "$TEST_HEALTH_FAKE_PROMPT"
EOF
  cat > "$SANDBOX/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_CALLS"
EOF
  export DEFAULT_MANIFEST='{"status":"ready","requirements":{"planned_errors":[]}}'
  chmod +x "$SANDBOX/bin/"* "$TRELLIS_LAUNCHER" "$CLAUDE_BIN"
  export PATH="$SANDBOX/bin:$PATH"
}

teardown() { rm -rf "$SANDBOX"; }

seed_ready() {
  mkdir -p "$TASK_ROOT"
  printf '%s\n' '{"status":"ready","requirements":{"planned_errors":[]}}' > "$MANIFEST"
  printf '%s\n' 'A materialized prompt.' > "$PROMPT"
}

assert_refusal() {
  local step="$1"
  [ "$status" -ne 0 ]
  [[ "$output" == "test-health: refused ($step): "* ]]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ ! -e "$TEST_HEALTH_FAKE_ARGS" ]
}

@test "installer bakes resolver HOME, config fleet, root and stable launcher into plist" {
  run /bin/bash "$INSTALLER"
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.trellis.test-health.plist"
  [ -x "$HOME/Library/LaunchAgents/com.trellis.test-health.runner.sh" ]
  run /usr/bin/plutil -lint "$plist"
  [ "$status" -eq 0 ]
  for entry in "TRELLIS_HOME:$TRELLIS_HOME" "TRELLIS_FLEET:personal" "TRELLIS_ROOT:$TRELLIS_ROOT" "TRELLIS_LAUNCHER:$TRELLIS_LAUNCHER"; do
    key="${entry%%:*}" value="${entry#*:}"
    run /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$key" "$plist"
    [ "$status" -eq 0 ] && [ "$output" = "$value" ]
  done
  run /usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Weekday' "$plist"
  [ "$output" = 1 ]
  run /usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Hour' "$plist"
  [ "$output" = 11 ]
  run /bin/bash "$INSTALLER"
  [ "$status" -eq 0 ]
  run /bin/bash "$INSTALLER" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$plist" ]
}

@test "installer uses explicit fleet before config default, and config default before personal" {
  # A non-personal default proves the config branch, not just the fallback.
  /usr/bin/python3 - "$TRELLIS_HOME/config.json" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['default_fleet']='team'; open(p,'w').write(json.dumps(c))
PY
  unset TRELLIS_FLEET
  run /bin/bash "$INSTALLER"
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.trellis.test-health.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:TRELLIS_FLEET' "$plist")" = team ]
  export TRELLIS_FLEET=personal
  run /bin/bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:TRELLIS_FLEET' "$plist")" = personal ]
}

@test "installer refuses resolver-invalid fleet and home without publishing" {
  export TRELLIS_FLEET='../escape'
  run /bin/bash "$INSTALLER"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Library/LaunchAgents/com.trellis.test-health.plist" ]
  [ ! -e "$LAUNCHCTL_CALLS" ]
  unset TRELLIS_FLEET
  export TRELLIS_HOME=relative
  run /bin/bash "$INSTALLER"
  [ "$status" -ne 0 ]
  [ ! -e "$LAUNCHCTL_CALLS" ]
}

@test "host gate precedes materialize and smoke checks" {
  export FAKE_HOST='Linux arm64'
  run /bin/bash "$RUNNER"
  [ "$status" -eq 3 ]
  [[ "$output" == 'info: test-health could not run: off-host '* ]]
  [ ! -e "$LAUNCHER_CALLS" ] && [ ! -e "$TEST_HEALTH_LOCK_FILE" ]
}

@test "smoke prints exactly four facts and never locks, materializes, or invokes Claude" {
  seed_ready
  # An already-held lock must not stop smoke.
  /usr/bin/shlock -f "$TEST_HEALTH_LOCK_FILE" -p "$$"
  run /bin/bash "$RUNNER" --smoke
  [ "$status" -eq 0 ]
  hash="$(/usr/bin/shasum -a 256 "$PROMPT")"; hash="${hash%% *}"
  [ "$output" = "$MANIFEST"$'\n'"$PROMPT"$'\n'"$hash"$'\n''placeholders: none unfilled' ]
  [ ! -e "$LAUNCHER_CALLS" ] && [ ! -e "$TEST_HEALTH_FAKE_ARGS" ]
  [ "$(cat "$TEST_HEALTH_LOCK_FILE")" = "$$" ]
  rm -f "$TEST_HEALTH_LOCK_FILE"
}

@test "runner locks before materialize and holds through Claude; prompt bytes differ from raw template" {
  export PROMPT_BODY=$'Materialized body, not raw.\n\n'
  run /bin/bash "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(cat "$LAUNCHER_CALLS")" = "task materialize --fleet personal test-health --home $TRELLIS_HOME" ]
  [ "$(cat "$TEST_HEALTH_FAKE_CWD")" = "$TRELLIS_ROOT" ]
  cmp -s "$PROMPT" "$TEST_HEALTH_FAKE_PROMPT"
  ! cmp -s "$RAW_PROMPT" "$TEST_HEALTH_FAKE_PROMPT"
  expected_args=$'-p\n--permission-mode\nbypassPermissions\n--max-turns\n100\n--max-budget-usd\n25'
  actual_args="$(/usr/bin/tr '\0' '\n' < "$TEST_HEALTH_FAKE_ARGS" | /usr/bin/head -n 7)"
  [ "$actual_args" = "$expected_args" ]
  [ ! -e "$TEST_HEALTH_LOCK_FILE" ]
  /usr/bin/shlock -f "$TEST_HEALTH_LOCK_FILE" -p "$$"
  rm -f "$LAUNCHER_CALLS" "$TEST_HEALTH_FAKE_ARGS"
  run /bin/bash "$RUNNER"
  [ "$status" -eq 0 ] && [[ "$output" == info:* ]]
  [ ! -e "$LAUNCHER_CALLS" ] && [ ! -e "$TEST_HEALTH_FAKE_ARGS" ]
  rm -f "$TEST_HEALTH_LOCK_FILE"
}

@test "materialize failure refuses before Claude" {
  export MATERIALIZE_FAIL=1
  run /bin/bash "$RUNNER"
  assert_refusal materialize
}

@test "missing manifest refuses before Claude" {
  export OMIT_MANIFEST=1
  run /bin/bash "$RUNNER"
  assert_refusal manifest
  [[ "$output" == *"$MANIFEST"* ]]
}

@test "non-ready manifest refuses before Claude" {
  export MANIFEST_BODY='{"status":"blocked","requirements":{"planned_errors":[]}}'
  run /bin/bash "$RUNNER"
  assert_refusal manifest
}

@test "planned errors refuse before Claude" {
  export MANIFEST_BODY='{"status":"ready","requirements":{"planned_errors":["missing dep"]}}'
  run /bin/bash "$RUNNER"
  assert_refusal manifest
}

@test "missing prompt refuses before Claude" {
  export OMIT_PROMPT=1
  run /bin/bash "$RUNNER"
  assert_refusal prompt
  [[ "$output" == *"$PROMPT"* ]]
}

@test "placeholder in materialized prompt refuses before Claude" {
  export PROMPT_BODY='Read {{TASK_ROOT}}'
  run /bin/bash "$RUNNER"
  assert_refusal prompt
  [[ "$output" == *'unfilled placeholder'* ]]
}

@test "relative TRELLIS_HOME refuses before lock or launcher" {
  export TRELLIS_HOME=relative
  run /bin/bash "$RUNNER"
  assert_refusal home
  [ ! -e "$LAUNCHER_CALLS" ] && [ ! -e "$TEST_HEALTH_LOCK_FILE" ]
}

@test "smoke refuses invalid manifest and prompt without materializing" {
  seed_ready
  printf '%s\n' '{"status":"blocked","requirements":{"planned_errors":[]}}' > "$MANIFEST"
  run /bin/bash "$RUNNER" --smoke
  assert_refusal manifest
  [ ! -e "$LAUNCHER_CALLS" ]
  seed_ready
  printf '%s\n' '{{OUTPUT_ROOT}}' > "$PROMPT"
  run /bin/bash "$RUNNER" --smoke
  assert_refusal prompt
  [ ! -e "$LAUNCHER_CALLS" ]
}
