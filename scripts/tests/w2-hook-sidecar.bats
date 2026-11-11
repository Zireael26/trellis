#!/usr/bin/env bats
# Generated Git-hook shims must not skip hooks when their sidecar is damaged.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-hook-sidecar.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  PROJECT="$SANDBOX/project"
  MANAGED="$SANDBOX/managed"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME" "$PROJECT" "$MANAGED"
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  _attachment_hooks_passthrough_shim_body pre-commit > "$MANAGED/pre-commit"
  chmod 700 "$MANAGED/pre-commit"
}

run_shim() {
  run bash -c 'cd "$1" && exec "$2"' _ "$PROJECT" "$MANAGED/pre-commit"
}

@test "missing sidecar refuses the Git operation" {
  run_shim
  [ "$status" -ne 0 ] || { echo 'missing sidecar skipped the hook'; false; }
}

@test "symlinked sidecar refuses the Git operation" {
  printf '.previous\n' > "$SANDBOX/sidecar"
  ln -s "$SANDBOX/sidecar" "$MANAGED/previous-hooks-path"
  run_shim
  [ "$status" -ne 0 ] || { echo 'symlinked sidecar skipped the hook'; false; }
}

@test "unreadable sidecar refuses the Git operation" {
  printf '.previous\n' > "$MANAGED/previous-hooks-path"
  chmod 000 "$MANAGED/previous-hooks-path"
  run_shim
  rc="$status"
  chmod 600 "$MANAGED/previous-hooks-path"
  [ "$rc" -ne 0 ] || { echo 'unreadable sidecar skipped the hook'; false; }
}

@test "multiline and zero-length sidecars refuse the Git operation" {
  printf '.previous\n.other\n' > "$MANAGED/previous-hooks-path"
  run_shim
  [ "$status" -ne 0 ] || { echo 'multiline sidecar skipped the hook'; false; }
  : > "$MANAGED/previous-hooks-path"
  run_shim
  [ "$status" -ne 0 ] || { echo 'zero-length sidecar skipped the hook'; false; }
}

@test "empty recorded path is allowed and a present previous hook still runs" {
  printf '\n' > "$MANAGED/previous-hooks-path"
  run_shim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mkdir "$PROJECT/.previous"
  printf '#!/bin/sh\nexit 7\n' > "$PROJECT/.previous/pre-commit"
  chmod 700 "$PROJECT/.previous/pre-commit"
  printf '.previous\n' > "$MANAGED/previous-hooks-path"
  run_shim
  [ "$status" -eq 7 ] || { echo "previous hook status was $status: $output"; false; }
}
