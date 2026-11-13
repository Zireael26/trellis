#!/usr/bin/env bats
# The sync-local locate cache is not a payload-use authorization.
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
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/sync-release-cache.XXXXXX")"
  SANDBOX="$(release_fixture_canonical_dir "$SANDBOX")"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/trellis"
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
  export CACHE_CALLS="$SANDBOX/calls" TAMPER_MARKER="$SANDBOX/marker"
  : > "$CACHE_CALLS"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

# Load the exact synchronizer functions without executing sync's CLI body.
cache_test_driver() {
  env CACHE_ACTION="$1" bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/release-store.sh"
    for function in sync_release_dir_identity sync_release_preverify sync_release_locate sync_verify_release_for_copy sync_reverify_repair_snapshot; do
      body="$(awk -v name="$function" '\''$0 == name "() {" {inside=1; next} inside && $0 == "}" {exit} inside {print}'\'' "$1/scripts/sync-hooks.sh")"
      eval "$function() { $body
}"
    done
    eval "$(declare -f release_store_locate | /usr/bin/sed "1s/release_store_locate/_test_original_locate/")"
    release_store_locate() { printf "locate\\n" >> "$CACHE_CALLS"; _test_original_locate "$@"; }
    HOME_PATH="$TRELLIS_HOME"; SYNC_TMPDIR="$TMPDIR"; SYNC_PROOF_STAT_OS="$(/usr/bin/uname -s)"; SYNC_RELEASE_CACHE=""
    if [ "$CACHE_ACTION" = override ]; then
      sync_release_preverify 9.9.9 || exit 42
      sync_release_locate 9.9.9 >/dev/null || exit 43
      sync_release_locate 9.9.9 >/dev/null || exit 44
      [ "$(wc -l < "$CACHE_CALLS" | tr -d " ")" = 3 ] || exit 45
      exit 0
    fi
    # The counter wraps the real verifier without changing its result; admit
    # this test seam explicitly. Production rejects changed helpers instead.
    _RELEASE_STORE_SYNC_CACHE_HELPERS_ORIGINAL="$(_release_store_sync_cache_helpers)"
    sync_release_preverify 9.9.9 || exit 10
    path="$(sync_release_locate 9.9.9)" || exit 11
    [ "$path" = "$TRELLIS_HOME/releases/9.9.9" ] || exit 12
    [ "$(wc -l < "$CACHE_CALLS" | tr -d " ")" = 1 ] || exit 13
    if [ "$CACHE_ACTION" = replaced ]; then
      mv "$path" "$path.saved" || exit 14
      if sync_verify_release_for_copy 9.9.9 >/dev/null 2>&1; then exit 34; else rc=$?; fi
      [ "$rc" -eq 5 ] || exit 35
      mkdir "$path" || exit 15
      sync_release_locate 9.9.9 >/dev/null 2>&1 && exit 16
      [ "$(wc -l < "$CACHE_CALLS" | tr -d " ")" = 2 ] || exit 17
      exit 0
    fi
    if [ "$CACHE_ACTION" = snapshot ] || [ "$CACHE_ACTION" = emitter ]; then
      record="$(release_store_snapshot_verified_release 9.9.9)" || exit 26
      ACTIVE_REPAIR_SNAPSHOT="${record%%$'\''\t'\''*}"
      ACTIVE_REPAIR_RELEASE_DIGEST="${record#*$'\''\t'\''}"
      ACTIVE_REPAIR_RELEASE_VERSION=9.9.9
      if [ "$CACHE_ACTION" = emitter ]; then
        sync_reverify_repair_snapshot >/dev/null 2>&1 || exit 36
        victim="$ACTIVE_REPAIR_SNAPSHOT/payload/scripts/attach-project.sh"
        chmod u+w "$victim" || exit 37
        printf "#!/bin/sh\\nprintf executed > \"%s\"\\n" "$TAMPER_MARKER" > "$victim" || exit 38
        chmod u-w "$victim" || exit 39
        if release_store_emit_verified_attachment_bundle "$ACTIVE_REPAIR_SNAPSHOT" "$ACTIVE_REPAIR_RELEASE_DIGEST" 9.9.9 > "$TMPDIR/emitter.out" 2>/dev/null; then
          exit 40
        else
          rc=$?
        fi
        [ "$rc" -eq 4 ] && [ ! -s "$TMPDIR/emitter.out" ] && [ ! -e "$TAMPER_MARKER" ] || exit 41
        exit 0
      fi
      victim="$ACTIVE_REPAIR_SNAPSHOT/payload/core-rules/CLAUDE.md"
      chmod u+w "$victim" || exit 27
      printf "tampered non-carrier\\n" >> "$victim" || exit 28
      chmod u-w "$victim" || exit 29
      if sync_reverify_repair_snapshot >/dev/null 2>&1; then exit 30; else rc=$?; fi
      [ "$rc" -eq 4 ] || exit 31
      exit 0
    fi
    victim="$path/payload/scripts/attach-project.sh"
    chmod u+w "$victim" || exit 18
    printf "#!/bin/sh\\nprintf executed > \"%s\"\\n" "$TAMPER_MARKER" > "$victim" || exit 19
    chmod u-w "$victim" || exit 20
    # Same path/inode still hits the inventory cache, but the actual use-time
    # snapshot must verify the copied manifest and refuse the poisoned bytes.
    sync_release_locate 9.9.9 >/dev/null || exit 21
    [ "$(wc -l < "$CACHE_CALLS" | tr -d " ")" = 1 ] || exit 22
    if sync_verify_release_for_copy 9.9.9 >/dev/null 2>&1; then exit 32; else rc=$?; fi
    [ "$rc" -eq 4 ] || exit 33
    if release_store_snapshot_verified_release 9.9.9 > "$TMPDIR/snapshot.out" 2> "$TMPDIR/snapshot.err"; then
      exit 23
    else
      rc=$?
    fi
    [ "$rc" -eq 4 ] || exit 24
    [ ! -s "$TMPDIR/snapshot.out" ] && [ ! -e "$TAMPER_MARKER" ] || exit 25
  ' _ "$REPO_ROOT"
}

@test "overridden release helpers disable the sync inventory cache" {
  run cache_test_driver override
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
}

@test "sync reuses a verified release only while its directory inode remains bound" {
  run cache_test_driver replaced
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
}

@test "a release modified after the sync prepass is refused before copy and by the snapshot" {
  run cache_test_driver tampered
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
}

@test "a cached snapshot with a tampered non-carrier is refused before bundle use" {
  run cache_test_driver snapshot
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
}

@test "a carrier changed after snapshot reverify is refused by bundle emission" {
  run cache_test_driver emitter
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
}
