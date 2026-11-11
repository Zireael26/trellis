#!/usr/bin/env bats
# Fake homes and tool stubs only; the real launchctl and janitor never run.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  # The installer lints its launchd templates and the agent scan reads plists
  # with the fixed /usr/bin/plutil; launchd agents exist only on macOS.
  [ "$(uname -s)" = Darwin ] || skip 'launchd agents and /usr/bin/plutil are macOS-only'
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-dry-run.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"
  TRELLIS_HOME="$SANDBOX/trellis"
  FIXTURE_SCRIPTS="$SANDBOX/scripts"
  STUB_BIN="$SANDBOX/bin"
  LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
  AGENTS="$HOME/Library/LaunchAgents"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME" "$FIXTURE_SCRIPTS/lib" "$STUB_BIN" "$AGENTS"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  printf '%s\n' '{"schema_version":1,"active_cli_release":"1.2.3"}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/trellis"
  chmod 755 "$HOME/.local/bin/trellis"
  for tool in launchctl git gh; do
    printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/$tool"
    chmod 755 "$STUB_BIN/$tool"
  done
  cp "$REPO_ROOT/scripts/lib/disk-janitor-agents.sh" "$FIXTURE_SCRIPTS/lib/disk-janitor-agents.sh"
  export HOME TRELLIS_HOME LAUNCHCTL_LOG
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "${SANDBOX:?}"
}

run_fixture_installer() {
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    /bin/bash -c '
      . "$1/scripts/install-disk-janitor-launchd.sh"
      SCRIPT_DIR="$2"
      PATH="$3:$PATH"; export PATH
      launchctl_run() { printf "%s\t%s\n" "$1" "$2" >> "$LAUNCHCTL_LOG"; }
      [ "${PRESERVE_TEST_SKIP:-0}" = 1 ] || unset TRELLIS_TEST_SKIP_JANITOR_DRY_RUN
      main --with-apply
    ' _ "$REPO_ROOT" "$FIXTURE_SCRIPTS" "$STUB_BIN"
}

write_fake_janitor() {
  cat > "$FIXTURE_SCRIPTS/disk-janitor.sh" <<'SH'
#!/bin/sh
[ "$*" = '--apply --yes --safe-only --dehydrate --scopes worktrees,caches,releases,pi,tmp,docker --dry-run' ]
SH
}

@test "installer refuses missing and non-executable janitors and accepts a passing dry run" {
  run_fixture_installer
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing to load org.trellis.disk-janitor-apply"* ]] || { echo "$output"; false; }
  [ ! -e "$AGENTS/org.trellis.disk-janitor-apply.plist" ]
  ! grep -q 'load.*org.trellis.disk-janitor-apply' "$LAUNCHCTL_LOG"

  write_fake_janitor
  chmod 600 "$FIXTURE_SCRIPTS/disk-janitor.sh"
  run_fixture_installer
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing to load org.trellis.disk-janitor-apply"* ]] || { echo "$output"; false; }
  [ ! -e "$AGENTS/org.trellis.disk-janitor-apply.plist" ]
  ! grep -q 'load.*org.trellis.disk-janitor-apply' "$LAUNCHCTL_LOG"

  chmod 700 "$FIXTURE_SCRIPTS/disk-janitor.sh"
  run_fixture_installer
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$AGENTS/org.trellis.disk-janitor-apply.plist" ]
  grep -q 'load.*org.trellis.disk-janitor-apply' "$LAUNCHCTL_LOG"
}

run_fixture_scan() {
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" PATH="$STUB_BIN:$PATH" \
    /bin/bash -c '[ "${PRESERVE_TEST_SKIP:-0}" = 1 ] || unset TRELLIS_TEST_SKIP_JANITOR_DRY_RUN; . "$1/lib/disk-janitor-agents.sh"; SCRIPT_DIR="$1"; dj_agent_scan "$2" "$HOME" "$TRELLIS_HOME"' \
    _ "$FIXTURE_SCRIPTS" "$AGENTS"
}

@test "ambient test skip cannot bypass apply dry-run validation" {
  local plist="$AGENTS/org.trellis.disk-janitor-apply.plist"
  printf '#!/bin/sh\nexit 77\n' > "$FIXTURE_SCRIPTS/disk-janitor.sh"
  chmod 700 "$FIXTURE_SCRIPTS/disk-janitor.sh"
  export TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 PRESERVE_TEST_SKIP=1
  run_fixture_installer
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"nightly apply argv failed dry-run"* ]] || { echo "$output"; false; }
  [ ! -e "$plist" ]
  ! grep -q 'load.*org.trellis.disk-janitor-apply' "$LAUNCHCTL_LOG"

  sed -e "s|__USER_HOME__|$HOME|g" -e "s|__TRELLIS_HOME__|$TRELLIS_HOME|g" \
    "$REPO_ROOT/core-rules/templates/org.trellis.disk-janitor-apply.plist" > "$plist"
  run_fixture_scan
  [[ "$output" == degraded$'\t'* ]] || { echo "$output"; false; }
  ! grep -q TRELLIS_TEST_SKIP_JANITOR_DRY_RUN "$REPO_ROOT/scripts/install-disk-janitor-launchd.sh"
  ! grep -q TRELLIS_TEST_SKIP_JANITOR_DRY_RUN "$FIXTURE_SCRIPTS/lib/disk-janitor-agents.sh"
}

@test "agent scan degrades missing or non-executable janitors and accepts a passing dry run" {
  local plist="$AGENTS/org.trellis.disk-janitor-apply.plist"
  sed -e "s|__USER_HOME__|$HOME|g" -e "s|__TRELLIS_HOME__|$TRELLIS_HOME|g" \
    "$REPO_ROOT/core-rules/templates/org.trellis.disk-janitor-apply.plist" > "$plist"
  run_fixture_scan
  [ "$status" -eq 0 ]
  [[ "$output" == degraded$'\t'* ]] || { echo "$output"; false; }

  write_fake_janitor
  chmod 600 "$FIXTURE_SCRIPTS/disk-janitor.sh"
  run_fixture_scan
  [[ "$output" == degraded$'\t'* ]] || { echo "$output"; false; }

  chmod 700 "$FIXTURE_SCRIPTS/disk-janitor.sh"
  run_fixture_scan
  [[ "$output" == match$'\t'* ]] || { echo "$output"; false; }
}
