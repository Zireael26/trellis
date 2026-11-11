#!/usr/bin/env bats
# D3 accounting uses an injected reap-tmp result; no deletion is performed.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-release.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"; STUB_BIN="$SANDBOX/bin"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$STUB_BIN"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  local tool
  for tool in git gh launchctl; do printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/$tool"; chmod 700 "$STUB_BIN/$tool"; done
  PATH="$STUB_BIN:$PATH"; export HOME TRELLIS_HOME PATH
  . "$REPO_ROOT/scripts/lib/disk-janitor-host.sh"
  scope_enabled() { return 0; }
  confirm_category() { return 0; }
  release_store_reap_tmp() { printf '%s\n' "$FAKE_REAP_OUTPUT"; return "$FAKE_REAP_RC"; }
  RELEASE_STAGING_DELETE_COUNT=2
  RELEASE_STAGING_DELETE_BYTES=100
  RELEASE_STAGING_RECLAIMED_BYTES=0
  RELEASE_STAGING_RECLAIMED_KNOWN=1
  EXIT_STATUS=0
}

teardown() { [ -z "${SANDBOX:-}" ] || rm -rf "${SANDBOX:?}"; }

run_release_fixture() {
  dj_host_release_apply
  printf 'STATE exit=%s known=%s bytes=%s\n' "$EXIT_STATUS" "$RELEASE_STAGING_RECLAIMED_KNOWN" "$RELEASE_STAGING_RECLAIMED_BYTES"
}

@test "reap-tmp refusal fails and never claims planned bytes were reclaimed" {
  FAKE_REAP_OUTPUT='trellis release: releases directory is unsafe'
  FAKE_REAP_RC=4
  run run_release_fixture
  [[ "$output" == *'STATE exit=1 known=0 bytes=0'* ]] || { echo "$output"; false; }
  [[ "$output" == *'reap-tmp failed (exit 4)'* ]] || { echo "$output"; false; }
}

@test "reap-tmp counts only reported removed bytes including partial refusal" {
  FAKE_REAP_OUTPUT=$'reap-tmp: removed dir .tmp.fixture age=2s owner=dead bytes=37\nreap-tmp: total entries=2 bytes=100 removed=1 removed_bytes=37 refused=1 failed=0'
  FAKE_REAP_RC=4
  run run_release_fixture
  [[ "$output" == *'STATE exit=1 known=1 bytes=37'* ]] || { echo "$output"; false; }
  FAKE_REAP_OUTPUT=$'reap-tmp: removed dir .tmp.fixture age=2s owner=dead bytes=37\nreap-tmp: total entries=1 bytes=37 removed=1 removed_bytes=37 refused=0 failed=0'
  FAKE_REAP_RC=0
  run run_release_fixture
  [[ "$output" == *'STATE exit=0 known=1 bytes=37'* ]] || { echo "$output"; false; }
}
