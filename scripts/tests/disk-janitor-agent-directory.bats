#!/usr/bin/env bats
# Directory scan uses an isolated home and never invokes launchctl.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-agent-directory.XXXXXX")"; SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"; AGENTS="$HOME/Library/LaunchAgents"; STUB_BIN="$SANDBOX/bin"
  mkdir -p "$AGENTS" "$TRELLIS_HOME" "$STUB_BIN"
  chmod 700 "$HOME" "$TRELLIS_HOME" "$AGENTS"
  local tool
  for tool in git gh launchctl; do printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/$tool"; chmod 700 "$STUB_BIN/$tool"; done
  PATH="$STUB_BIN:$PATH"; export HOME TRELLIS_HOME PATH
  printf 'fixture\n' > "$AGENTS/org.trellis.disk-janitor-apply.plist"
  . "$REPO_ROOT/scripts/lib/health-checks.sh"
}
teardown() { [ -z "${SANDBOX:-}" ] || { chmod -R u+rwX "$SANDBOX"; rm -rf "${SANDBOX:?}"; }; }

@test "unreadable agent directory is an error, not no agents" {
  [ "$(id -u)" -ne 0 ] || skip 'root can read mode-300 directories'
  chmod 300 "$AGENTS"
  run dj_agent_scan "$AGENTS" "$HOME" "$TRELLIS_HOME"
  [[ "$output" == unreadable$'\t'* ]] || { echo "scan: $output"; false; }
  run hc_disk_janitor_agent_rows "$HOME" "$TRELLIS_HOME"
  [[ "$output" == $'1\t'*"cannot inspect"* ]] || { echo "doctor: $output"; false; }
  [[ "$output" != *'none installed'* ]] || { echo "$output"; false; }
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" /bin/bash -c '
    . "$1/scripts/install-disk-janitor-launchd.sh"
    PATH="$4:$PATH"; export PATH
    launch_agents_dir="$2"; user_home="$HOME"; trellis_home="$TRELLIS_HOME"; with_apply=false
    require_matching_janitor_agents
  ' _ "$REPO_ROOT" "$AGENTS" "$TRELLIS_HOME" "$STUB_BIN"
  [ "$status" -ne 0 ] && [[ "$output" == *"cannot inspect"* ]] || { echo "installer: $output"; false; }
  [[ "$output" != *'launchctl bootout'* ]] || { echo "$output"; false; }

  chmod 700 "$AGENTS"
  mv "$AGENTS/org.trellis.disk-janitor-apply.plist" "$SANDBOX/aside"
  run dj_agent_scan "$AGENTS" "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
  run hc_disk_janitor_agent_rows "$HOME" "$TRELLIS_HOME"
  [[ "$output" == *'disk-janitor agents: none installed'* ]] || { echo "$output"; false; }
}
