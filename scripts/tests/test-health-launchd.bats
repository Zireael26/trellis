#!/usr/bin/env bats
# Focused, hermetic tests for the Darwin host test-health runner and its
# LaunchAgent installer. The installer uses a fixture config/home plus a fake
# launchctl; Claude and uname are fakes, so no fleet test or API call occurs.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-test-health-host.sh"
INSTALLER="$REPO_ROOT/scripts/install-test-health-launchd.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  # config-load canonicalises source_root, so on macOS the installer writes
  # /private/var/... while an uncanonicalised fixture path stays /var/... —
  # every path assertion below would compare two spellings of the same
  # directory and fail. Canonicalise once, here, like local-registry.bats does.
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  USER_HOME="$SANDBOX/home"
  FAKE_BIN="$SANDBOX/bin"
  CONFIG="$CANON/trellis.config.json"
  PROMPT="$CANON/scheduled-tasks/test-health/prompt.md"
  LOCK_FILE="$SANDBOX/test-health.lock"
  FAKE_ARGS="$SANDBOX/claude-args.bin"
  FAKE_CWD="$SANDBOX/claude-cwd"
  LAUNCHCTL_CALLS="$SANDBOX/launchctl-calls"

  mkdir -p "$CANON" "$PROJECTS" "$USER_HOME" "$FAKE_BIN"
  # Tracked policy carries no machine paths. config-load now rejects a policy
  # file containing trellis_root / projects_root / user_home outright, so the
  # roots below moved into the machine-local config written further down.
  cat > "$CONFIG" <<EOF
{
  "schema_version": 2,
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"],
  "template": { "remote": "https://example.invalid/trellis.git", "branch": "main" }
}
EOF

  # Tracked policy no longer carries machine paths: config-load derives
  # TRELLIS_ROOT and USER_HOME from validated machine-local state, so the
  # fixture has to supply a real TRELLIS_HOME as well as the policy file.
  # Without it the installer aborts before writing anything and every
  # status assertion below reads as a spurious failure.
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  mkdir -p "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  cat > "$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$CANON",
  "release_remote": "fixture://release",
  "active_cli_release": "1.0.0-fixture",
  "default_fleet": "personal",
  "fleets": { "personal": { "discovery_roots": ["$PROJECTS"] } }
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"

  cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_CALLS"
EOF
  chmod +x "$FAKE_BIN/launchctl"
}

teardown() {
  rm -rf "$SANDBOX"
}

write_prompt() {
  mkdir -p "$(dirname "$PROMPT")"
  printf '%s\n' "$1" > "$PROMPT"
}

# The stub answers per flag rather than echoing the same string for every
# invocation. The host gate asks for `uname -sm`, but config-load now asks for
# `uname -s` alone to pick its stat(1) flavour — a stub that answered "Darwin
# arm64" to both sent it down the GNU branch and made every install look like a
# permissions failure.
# The stub simulates what the HOST GATE observes (`uname -sm`), not the kernel
# the process is really running on. `uname -s` deliberately delegates to the
# real binary: config-load uses it to pick between BSD `stat -f` and GNU
# `stat -c`, and answering "Linux" on a macOS host sends it to a stat flavour
# that does not exist there — config-load then fails with an unavailable-home
# error before the gate under test ever runs.
make_uname() {
  cat > "$FAKE_BIN/uname" <<EOF
#!/usr/bin/env bash
full='$1'
case "\$1" in
  -s) exec /usr/bin/uname -s ;;
  -m) printf '%s\\n' "\${full##* }" ;;
  *)  printf '%s\\n' "\$full" ;;
esac
EOF
  chmod +x "$FAKE_BIN/uname"
}

make_claude() {
  cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD" > "$TEST_HEALTH_FAKE_CWD"
printf '%s\0' "$@" > "$TEST_HEALTH_FAKE_ARGS"
EOF
  chmod +x "$FAKE_BIN/claude"
}

make_durable_claude() {
  mkdir -p "$USER_HOME/.local/bin"
  cat > "$USER_HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$USER_HOME/.local/bin/claude"
}


@test "installer renders a bootstrapped Monday host LaunchAgent idempotently" {
  write_prompt 'Canonical test-health prompt.'
  make_uname 'Darwin arm64'
  make_durable_claude

  run env \
    "HOME=$USER_HOME" \
    "TRELLIS_CONFIG=$CONFIG" \
    "PATH=$FAKE_BIN:$PATH" \
    "LAUNCHCTL_CALLS=$LAUNCHCTL_CALLS" \
    /bin/bash "$INSTALLER"
  [ "$status" -eq 0 ]

  plist="$USER_HOME/Library/LaunchAgents/com.trellis.test-health.plist"
  installed_runner="$USER_HOME/Library/LaunchAgents/com.trellis.test-health.runner.sh"
  durable_path="$USER_HOME/.local/bin:$USER_HOME/.nvm/default-node/bin:$USER_HOME/.pyenv/shims:$USER_HOME/.bun/bin:$USER_HOME/.cargo/bin:$USER_HOME/go/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  [ -f "$plist" ]
  [ -x "$installed_runner" ]
  [ -d "$CANON/logs" ]
  run /usr/bin/plutil -lint "$plist"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -F '__' "$plist"
  [ "$status" -eq 1 ]
  run /usr/bin/grep -F "<string>$CANON/logs/test-health.out.log</string>" "$plist"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -F "<string>$CANON/logs/test-health.err.log</string>" "$plist"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -F "<string>$durable_path</string>" "$plist"
  [ "$status" -eq 0 ]
  run /usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Weekday' "$plist"
  [ "$status" -eq 0 ]
  [ "$output" = '1' ]
  run /usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Hour' "$plist"
  [ "$status" -eq 0 ]
  [ "$output" = '11' ]
  run /usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Minute' "$plist"
  [ "$status" -eq 0 ]
  [ "$output" = '0' ]

  run env \
    "HOME=$USER_HOME" \
    "TRELLIS_CONFIG=$CONFIG" \
    "PATH=$FAKE_BIN:$PATH" \
    "LAUNCHCTL_CALLS=$LAUNCHCTL_CALLS" \
    /bin/bash "$INSTALLER"
  [ "$status" -eq 0 ]
  run cat "$LAUNCHCTL_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bootstrap gui/$(id -u) $plist"* ]]

  run env \
    "HOME=$USER_HOME" \
    "TRELLIS_CONFIG=$CONFIG" \
    "PATH=$FAKE_BIN:$PATH" \
    "LAUNCHCTL_CALLS=$LAUNCHCTL_CALLS" \
    /bin/bash "$INSTALLER" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$plist" ]
  [ ! -e "$installed_runner" ]
}

@test "host gate stops before accessing a canonical prompt off Darwin arm64" {
  make_uname 'Linux arm64'

  run env \
    "PATH=$FAKE_BIN:$PATH" \
    "TRELLIS_ROOT=$SANDBOX/missing-canonical" \
    "CLAUDE_BIN=$FAKE_BIN/missing-claude" \
    /bin/bash "$RUNNER" --smoke

  [ "$status" -eq 3 ]
  [ "$output" = 'info: test-health could not run: off-host (uname=Linux arm64); darwin node_modules cannot execute under this kernel' ]
}

@test "installer rejects an off-host install before creating artifacts" {
  write_prompt 'Canonical test-health prompt.'
  make_uname 'Linux arm64'
  make_durable_claude

  run env \
    "HOME=$USER_HOME" \
    "TRELLIS_CONFIG=$CONFIG" \
    "PATH=$FAKE_BIN:$PATH" \
    "LAUNCHCTL_CALLS=$LAUNCHCTL_CALLS" \
    /bin/bash "$INSTALLER"

  [ "$status" -eq 3 ]
  [ "$output" = 'info: test-health could not run: off-host (uname=Linux arm64); darwin node_modules cannot execute under this kernel' ]
  [ ! -e "$USER_HOME/Library/LaunchAgents/com.trellis.test-health.plist" ]
  [ ! -e "$LAUNCHCTL_CALLS" ]
  [ ! -d "$CANON/logs" ]
}

@test "installer validates the canonical prompt before creating artifacts" {
  make_uname 'Darwin arm64'
  make_durable_claude

  run env \
    "HOME=$USER_HOME" \
    "TRELLIS_CONFIG=$CONFIG" \
    "PATH=$FAKE_BIN:$PATH" \
    "LAUNCHCTL_CALLS=$LAUNCHCTL_CALLS" \
    /bin/bash "$INSTALLER"

  [ "$status" -eq 1 ]
  [ "$output" = "test-health runner: canonical prompt missing: $PROMPT" ]
  [ ! -e "$USER_HOME/Library/LaunchAgents/com.trellis.test-health.plist" ]
  [ ! -e "$LAUNCHCTL_CALLS" ]
  [ ! -d "$CANON/logs" ]
}

@test "smoke verifies Darwin arm64 and the canonical prompt without invoking Claude" {
  write_prompt 'Canonical test-health prompt.'
  make_uname 'Darwin arm64'
  make_claude

  run env \
    "PATH=$FAKE_BIN:$PATH" \
    "TRELLIS_ROOT=$CANON" \
    "CLAUDE_BIN=$FAKE_BIN/claude" \
    "TEST_HEALTH_LOCK_FILE=$LOCK_FILE" \
    /bin/bash "$RUNNER" --smoke

  [ "$status" -eq 0 ]
  prompt_hash="$(/usr/bin/shasum -a 256 "$PROMPT")"
  prompt_hash="${prompt_hash%% *}"
  [[ "$output" == *'smoke: host preflight: Darwin arm64'* ]]
  [[ "$output" == *"smoke: canonical cwd: $CANON"* ]]
  [[ "$output" == *"smoke: canonical prompt: $PROMPT"* ]]
  [[ "$output" == *"smoke: prompt sha256: $prompt_hash"* ]]
  [[ "$output" == *'--max-turns 100 --max-budget-usd 25'* ]]
  [ ! -e "$FAKE_ARGS" ]
  [ ! -e "$LOCK_FILE" ]
}

@test "runner dispatches the exact canonical prompt with bounded Claude arguments" {
  prompt_body=$'Canonical test-health prompt.\nSecond line stays in the user prompt.'
  write_prompt "$prompt_body"
  make_uname 'Darwin arm64'
  make_claude

  run env \
    "PATH=$FAKE_BIN:$PATH" \
    "TRELLIS_ROOT=$CANON" \
    "CLAUDE_BIN=$FAKE_BIN/claude" \
    "TEST_HEALTH_LOCK_FILE=$LOCK_FILE" \
    "TEST_HEALTH_FAKE_CWD=$FAKE_CWD" \
    "TEST_HEALTH_FAKE_ARGS=$FAKE_ARGS" \
    /bin/bash "$RUNNER"

  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_CWD")" = "$CANON" ]
  actual_args="$(/usr/bin/tr '\0' '\n' < "$FAKE_ARGS")"
  expected_args=$'-p\n--permission-mode\nbypassPermissions\n--max-turns\n100\n--max-budget-usd\n25\nCanonical test-health prompt.\nSecond line stays in the user prompt.'
  [ "$actual_args" = "$expected_args" ]
  [ ! -e "$LOCK_FILE" ]
}

@test "runner skips when the macOS shlock is already held" {
  write_prompt 'Canonical test-health prompt.'
  make_uname 'Darwin arm64'
  make_claude
  /usr/bin/shlock -f "$LOCK_FILE" -p "$$"

  run env \
    "PATH=$FAKE_BIN:$PATH" \
    "TRELLIS_ROOT=$CANON" \
    "CLAUDE_BIN=$FAKE_BIN/claude" \
    "TEST_HEALTH_LOCK_FILE=$LOCK_FILE" \
    "TEST_HEALTH_FAKE_CWD=$FAKE_CWD" \
    "TEST_HEALTH_FAKE_ARGS=$FAKE_ARGS" \
    /bin/bash "$RUNNER"

  [ "$status" -eq 0 ]
  [ "$output" = "info: test-health skipped: another run is active (pid=$$)" ]
  [ ! -e "$FAKE_ARGS" ]
  [ "$(cat "$LOCK_FILE")" = "$$" ]
  rm -f "$LOCK_FILE"
}
