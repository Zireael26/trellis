#!/usr/bin/env bats
# The pre-QUIT supervisor fixture must actually execute without referencing an
# unregistered signal. Linux exposes an undefined signal as a cold-start exit.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/heavy-supervisor-legacy

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp" TRELLIS_HEAVY_TEST=1
  export TRELLIS_HEAVY_DIR="$BATS_TEST_TMPDIR/slots"
  unset TRELLIS_HEAVY_FD TRELLIS_HEAVY_SLOT TRELLIS_HEAVY_DIR_ID TRELLIS_HEAVY_POOL TRELLIS_HEAVY_CALLER_ENV
  unset TRELLIS_HEAVY_LIGHT_WARN TRELLIS_HEAVY_KILL_AFTER TRELLIS_HEAVY_TEST_PAUSE TRELLIS_HEAVY_TEST_TRACE
  unset TRELLIS_HEAVY_TEST_POLL TRELLIS_HEAVY_TEST_HEARTBEAT TRELLIS_HEAVY_TEST_FAIL TRELLIS_VERIFIED_PAYLOAD
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
  chmod 700 "$TRELLIS_HOME"
  printf '{"heavy_slots":2}\n' > "$TRELLIS_HOME/config.json"
  cp "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" "$BATS_TEST_TMPDIR/supervisor.pl"
  make_legacy_heavy_supervisor "$BATS_TEST_TMPDIR/supervisor.pl"
}

@test "legacy supervisor without QUIT starts cold without signal warnings" {
  run --separate-stderr /usr/bin/perl "$BATS_TEST_TMPDIR/supervisor.pl" \
    run heavy - 0 /bin/sh -c 'printf legacy-ran'
  [ "$status" -eq 0 ] || { echo "status=$status stderr=$stderr"; false; }
  [ "$output" = legacy-ran ] || { echo "unexpected output: $output"; false; }
  [ -z "$stderr" ] || { echo "unexpected supervisor warning: $stderr"; false; }
}
