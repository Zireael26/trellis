#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/codex-worker-preflight.sh"

setup() {
  FIXTURE="$(mktemp -d)"
  FIXTURE="$(cd "$FIXTURE" && pwd -P)"
  BIN="$FIXTURE/bin"
  PLUGIN="$FIXTURE/plugin"
  CODEX="$BIN/codex"
  COMPANION="$PLUGIN/scripts/codex-companion.mjs"
  CONFIG="$FIXTURE/config.toml"
  WHICH_FILE="$FIXTURE/which.txt"
  PROCESS_FILE="$FIXTURE/processes.txt"

  mkdir -p "$BIN" "$PLUGIN/scripts" "$PLUGIN/.claude-plugin"
  write_cli_version "0.144.0"

  cat > "$COMPANION" <<'SH'
case "$1" in
  help)
    echo 'Usage: task [--effort <none|minimal|low|medium|high|xhigh>]'
    ;;
  setup)
    cat "$(dirname "$0")/../setup.json"
    ;;
  *)
    exit 2
    ;;
esac
SH
  chmod +x "$COMPANION"
  printf '{"version":"1.0.5"}\n' > "$PLUGIN/.claude-plugin/plugin.json"
  printf '{"ready":true,"codex":{"available":true},"auth":{"loggedIn":true}}\n' > "$PLUGIN/setup.json"
  printf 'model = "gpt-5.6-sol"\n' > "$CONFIG"
  printf '%s\n' "$CODEX" > "$WHICH_FILE"
  : > "$PROCESS_FILE"

  cat > "$BIN/stat" <<'SH'
#!/usr/bin/env bash
case "${PREFLIGHT_TIMESTAMP_STYLE:-}" in
  bsd)
    if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%c" ]; then
      printf '%s\n' "$PREFLIGHT_CLI_INSTALL_EPOCH"
      exit 0
    fi
    ;;
  gnu)
    if [ "${1:-}" = "-f" ]; then
      exit 1
    fi
    if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%Z" ]; then
      printf '%s\n' "$PREFLIGHT_CLI_INSTALL_EPOCH"
      exit 0
    fi
    ;;
esac
exec /usr/bin/stat "$@"
SH
  chmod +x "$BIN/stat"

  cat > "$BIN/date" <<'SH'
#!/usr/bin/env bash
case "${PREFLIGHT_TIMESTAMP_STYLE:-}" in
  bsd)
    if [ "${1:-}" = "-j" ]; then
      printf '%s\n' "$PREFLIGHT_PROCESS_START_EPOCH"
      exit 0
    fi
    ;;
  gnu)
    if [ "${1:-}" = "-j" ]; then
      exit 1
    fi
    if [ "${1:-}" = "-d" ]; then
      printf '%s\n' "$PREFLIGHT_PROCESS_START_EPOCH"
      exit 0
    fi
    ;;
esac
exec /bin/date "$@"
SH
  chmod +x "$BIN/date"
}

teardown() {
  rm -rf "$FIXTURE"
}

write_cli_version() {
  _version="$1"
  cat > "$CODEX" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "codex-cli $_version"
  exit 0
fi
exit 2
SH
  chmod +x "$CODEX"
}

run_preflight() {
  run env \
    PATH="$BIN:/usr/bin:/bin" \
    CODEX_BIN="$CODEX" \
    CODEX_WHICH_FILE="$WHICH_FILE" \
    PREFLIGHT_PROCESS_FILE="$PROCESS_FILE" \
    COMPANION_PATH="$COMPANION" \
    NODE_BIN="/bin/bash" \
    CODEX_CONFIG="$CONFIG" \
    PREFLIGHT_TIMEOUT_SECONDS=2 \
    PREFLIGHT_TIMESTAMP_STYLE="${PREFLIGHT_TIMESTAMP_STYLE:-}" \
    PREFLIGHT_CLI_INSTALL_EPOCH="${PREFLIGHT_CLI_INSTALL_EPOCH:-}" \
    PREFLIGHT_PROCESS_START_EPOCH="${PREFLIGHT_PROCESS_START_EPOCH:-}" \
    bash "$SCRIPT" --effort high --model gpt-5.6-sol --json "$@"
}

set_timestamp_fixture() {
  PREFLIGHT_TIMESTAMP_STYLE="$1"
  PREFLIGHT_CLI_INSTALL_EPOCH="$2"
  PREFLIGHT_PROCESS_START_EPOCH="$3"
  printf '904 Tue Nov 14 22:13:20 2023 %s app-server\n' "$CODEX" > "$PROCESS_FILE"
}

json_field() {
  printf '%s\n' "$output" | /usr/bin/jq -r "$1"
}

fixture_hash() {
  find "$FIXTURE" -type f -exec shasum {} \; | LC_ALL=C sort | shasum | awk '{print $1}'
}

@test "old CLI version is environment-red" {
  write_cli_version "0.143.9"

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.cli_ok')" = "false" ]
  [ "$(json_field '.cli_version')" = "0.143.9" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "multiple distinct resolved Codex installs are shadowed and red" {
  mkdir -p "$FIXTURE/other-bin"
  cp "$CODEX" "$FIXTURE/other-bin/codex"
  printf '%s\n%s\n' "$CODEX" "$FIXTURE/other-bin/codex" > "$WHICH_FILE"

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.shadowed')" = "true" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "app-server running from a different Codex binary is stale and red" {
  mkdir -p "$FIXTURE/old-bin"
  cp "$CODEX" "$FIXTURE/old-bin/codex"
  printf '901 Thu Jan  1 00:00:01 1970 %s app-server\n' "$FIXTURE/old-bin/codex" > "$PROCESS_FILE"

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.stale_app_servers')" = "1" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "same-path app-server started before an in-place CLI upgrade is stale and red" {
  printf '902 Sat Jan  1 00:00:01 2000 %s app-server\n' "$CODEX" > "$PROCESS_FILE"

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.stale_app_servers')" = "1" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "same-path app-server started after the selected CLI install is current" {
  printf '903 Thu Jan  1 00:00:01 2099 %s app-server\n' "$CODEX" > "$PROCESS_FILE"

  run_preflight

  [ "$status" -eq 0 ]
  [ "$(json_field '.stale_app_servers')" = "0" ]
  [ "$(json_field '.verdict')" = "green" ]
}

@test "same-second same-path app-server is current through BSD stat and date" {
  set_timestamp_fixture bsd 1700000000 1700000000

  run_preflight

  [ "$status" -eq 0 ]
  [ "$(json_field '.stale_app_servers')" = "0" ]
  [ "$(json_field '.verdict')" = "green" ]
}

@test "one-second-older same-path app-server is stale through BSD stat and date" {
  set_timestamp_fixture bsd 1700000000 1699999999

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.stale_app_servers')" = "1" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "same-second same-path app-server is current through GNU stat and date fallbacks" {
  set_timestamp_fixture gnu 1700000000 1700000000

  run_preflight

  [ "$status" -eq 0 ]
  [ "$(json_field '.stale_app_servers')" = "0" ]
  [ "$(json_field '.verdict')" = "green" ]
}

@test "one-second-older same-path app-server is stale through GNU stat and date fallbacks" {
  set_timestamp_fixture gnu 1700000000 1699999999

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.stale_app_servers')" = "1" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "wrong model pin is environment-red" {
  printf 'model = "gpt-5.6-codex"\n' > "$CONFIG"

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.pin_ok')" = "false" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "missing model pin is environment-red" {
  printf 'approval_policy = "never"\n' > "$CONFIG"

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.pin_ok')" = "false" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "companion absence is a legal capability degrade" {
  COMPANION="$FIXTURE/missing/codex-companion.mjs"

  run_preflight

  [ "$status" -eq 0 ]
  [ "$(json_field '.companion_present')" = "false" ]
  [ "$(json_field '.companion_ready')" = "false" ]
  [ "$(json_field '.verdict')" = "companion-absent" ]
}

@test "unsupported companion effort fails closed" {
  run_preflight --effort ultra

  [ "$status" -eq 1 ]
  [ "$(json_field '.supported_efforts | index("ultra")')" = "null" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "present companion with setup not ready is environment-red" {
  printf '{"ready":false,"codex":{"available":true},"auth":{"loggedIn":true}}\n' > "$PLUGIN/setup.json"

  run_preflight

  [ "$status" -eq 1 ]
  [ "$(json_field '.companion_present')" = "true" ]
  [ "$(json_field '.companion_ready')" = "false" ]
  [ "$(json_field '.verdict')" = "environment-red" ]
}

@test "fully ready fixture is green and exposes the effort enum" {
  run_preflight

  [ "$status" -eq 0 ]
  [ "$(json_field '.cli_ok')" = "true" ]
  [ "$(json_field '.shadowed')" = "false" ]
  [ "$(json_field '.stale_app_servers')" = "0" ]
  [ "$(json_field '.companion_present')" = "true" ]
  [ "$(json_field '.companion_ready')" = "true" ]
  [ "$(json_field '.supported_efforts | join(",")')" = "none,minimal,low,medium,high,xhigh" ]
  [ "$(json_field '.pin_ok')" = "true" ]
  [ "$(json_field '.verdict')" = "green" ]
}

@test "preflight leaves every fixture file byte-for-byte unchanged" {
  before="$(fixture_hash)"

  run_preflight

  [ "$status" -eq 0 ]
  after="$(fixture_hash)"
  [ "$before" = "$after" ]
}
