#!/usr/bin/env bats
# Owner-set probes use only a fake home; external host tools are stubbed.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-owners.XXXXXX")"; SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"; STUB_BIN="$SANDBOX/bin"
  OWNERS="$SANDBOX/owners"
  mkdir -p "$HOME" "$TRELLIS_HOME/state/attachments/checkout" "$STUB_BIN"
  chmod 700 "$HOME" "$TRELLIS_HOME" "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/attachments" "$TRELLIS_HOME/state/attachments/checkout"
  local tool
  for tool in git gh launchctl; do printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/$tool"; chmod 700 "$STUB_BIN/$tool"; done
  PATH="$STUB_BIN:$PATH"; export HOME TRELLIS_HOME PATH
  printf '{"worktree_root":"%s"}\n' "$SANDBOX/owned" > "$TRELLIS_HOME/state/attachments/checkout/owner.json"
  . "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh"
}
teardown() { [ -z "${SANDBOX:-}" ] || { chmod -R u+rwX "$SANDBOX"; rm -rf "${SANDBOX:?}"; }; }

@test "unsearchable trellis home is not an empty owner set" {
  [ "$(id -u)" -ne 0 ] || skip 'root can search mode-000 directories'
  mv "$TRELLIS_HOME/state" "$SANDBOX/state-aside"
  run dj_pi_owner_paths "$TRELLIS_HOME" "$OWNERS"
  [ "$status" -eq 0 ] && [ ! -s "$OWNERS" ] || { echo "$output"; false; }
  chmod 000 "$TRELLIS_HOME"
  run dj_pi_owner_paths "$TRELLIS_HOME" "$OWNERS"
  chmod 700 "$TRELLIS_HOME"
  [ "$status" -ne 0 ] || { echo 'unsearchable home falsely reported empty'; false; }
}

@test "unsearchable state is not an empty owner set; truly absent state is allowed" {
  [ "$(id -u)" -ne 0 ] || skip 'root can search mode-000 directories'
  run dj_pi_owner_paths "$TRELLIS_HOME" "$OWNERS"
  [ "$status" -eq 0 ]
  grep -Fxq "$SANDBOX/owned" "$OWNERS"

  chmod 000 "$TRELLIS_HOME/state"
  run dj_pi_owner_paths "$TRELLIS_HOME" "$OWNERS"
  [ "$status" -ne 0 ] || { echo 'unsearchable state falsely reported empty'; false; }
  chmod 700 "$TRELLIS_HOME/state"
  mv "$TRELLIS_HOME/state" "$SANDBOX/state-aside"
  run dj_pi_owner_paths "$TRELLIS_HOME" "$OWNERS"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -s "$OWNERS" ]
}
