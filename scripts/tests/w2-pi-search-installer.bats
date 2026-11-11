#!/usr/bin/env bats
# Installer rollback and blocked-build checks must distinguish I/O errors.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/install-pi-web-search.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-pi-search.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  SRC="$SANDBOX/source.ts" BLOCKED="$SANDBOX/blocked.sha256"
  printf 'fixture search extension\n' > "$SRC"
  shasum -a 256 "$SRC" > "$BLOCKED"
}

@test "unreadable blocked-build list refuses installation" {
  chmod 000 "$BLOCKED"
  run env TWS_BLOCKED_LIST="$BLOCKED" "$INSTALLER" install "$SRC"
  rc="$status"
  chmod 600 "$BLOCKED"
  [ "$rc" -ne 0 ] || { echo "unreadable block list allowed install: $output"; false; }
  [ ! -e "$HOME/.pi/agent/extensions/trellis-web-search.ts" ]
}

@test "remove refuses an inaccessible extension directory" {
  mkdir -p "$HOME/.pi/agent/extensions"
  printf 'live\n' > "$HOME/.pi/agent/extensions/trellis-web-search.ts"
  chmod 000 "$HOME/.pi/agent"
  run "$INSTALLER" remove
  rc="$status"
  chmod 700 "$HOME/.pi/agent"
  [ "$rc" -ne 0 ] || { echo "uninspectable extension reported removed: $output"; false; }
  [ -f "$HOME/.pi/agent/extensions/trellis-web-search.ts" ]
}

@test "readable unblocked install and ordinary removal remain allowed" {
  printf '# none blocked\n' > "$BLOCKED"
  run env TWS_BLOCKED_LIST="$BLOCKED" "$INSTALLER" install "$SRC"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$HOME/.pi/agent/extensions/trellis-web-search.ts" ]
  run "$INSTALLER" remove
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$HOME/.pi/agent/extensions/trellis-web-search.ts" ]
}

@test "remove on an absent extensions directory remains idempotent" {
  run "$INSTALLER" remove
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
