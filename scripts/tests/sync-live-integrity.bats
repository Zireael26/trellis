#!/usr/bin/env bats
# Real sync repair: a post-prepass release mutation must not reach execution.
REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
. "$REPO_ROOT/scripts/tests/helpers/release-fixture.bash"

setup_file() {
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/prototype"
  mkdir -p "$RELEASE_FIXTURE_PROTOTYPE"
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$RELEASE_FIXTURE_PROTOTYPE")"
  export RELEASE_FIXTURE_PROTOTYPE
  release_fixture_prototype_build "$RELEASE_FIXTURE_PROTOTYPE"
}

teardown_file() {
  chmod -R u+w "$RELEASE_FIXTURE_PROTOTYPE" 2>/dev/null || true
  rm -rf "$RELEASE_FIXTURE_PROTOTYPE"
}

setup() {
  export TRELLIS_ATTACH_POSTJOB=off
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/sync-live.XXXXXX")"
  SANDBOX="$(release_fixture_canonical_dir "$SANDBOX")"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/trellis"
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
  PROJECT="$SANDBOX/project"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  git -C "$PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"sync-live"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm fixture
  run "$HOME/.local/bin/trellis" attach --fleet personal "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -L "$PROJECT/.trellis/runtime" ] || return 1
  rm "$PROJECT/.trellis/runtime"
  mkdir "$SANDBOX/runner"
  cp -R "$REPO_ROOT/scripts" "$SANDBOX/runner/scripts"
  RUNNER="$SANDBOX/runner/scripts/sync-hooks.sh"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

@test "a clean release still repairs an attachment through the verified bundle" {
  run bash "$RUNNER" --home "$TRELLIS_HOME" --fleet personal --yes sync-live
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$PROJECT/.trellis/runtime" ] || false
}

@test "sync refuses an installed carrier changed immediately after prepass verification" {
  export TEST_TAMPER_TARGET="$TRELLIS_HOME/releases/9.9.9/payload/scripts/attach-project.sh"
  export TEST_TAMPER_TRIGGER="$SANDBOX/tamper-trigger" TEST_TAMPER_MARKER="$SANDBOX/executed-marker"
  cat >> "$SANDBOX/runner/scripts/lib/release-store.sh" <<'SH'
eval "_sync_test_original_locate() $(declare -f release_store_locate | /usr/bin/sed '1d')"
release_store_locate() {
  local rc
  if _sync_test_original_locate "$@"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ] && [ ! -e "$TEST_TAMPER_TRIGGER" ]; then
    chmod u+w "$TEST_TAMPER_TARGET" || return 90
    printf '#!/bin/sh\nprintf executed > "%s"\n' "$TEST_TAMPER_MARKER" > "$TEST_TAMPER_TARGET" || return 91
    chmod u-w "$TEST_TAMPER_TARGET" || return 92
    printf 'tampered\n' > "$TEST_TAMPER_TRIGGER"
  fi
  return "$rc"
}
SH
  run bash "$RUNNER" --home "$TRELLIS_HOME" --fleet personal --yes sync-live
  [ -f "$TEST_TAMPER_TRIGGER" ] || { echo "tamper seam did not run: $output"; false; }
  [ "$status" -eq 4 ] || { echo "status=$status: $output"; false; }
  [[ "$output" == *'active immutable repair bundle is unavailable (4)'* ]] || { echo "$output"; false; }
  [ ! -e "$TEST_TAMPER_MARKER" ] || false
  [ ! -e "$PROJECT/.trellis/runtime" ] || false
}
