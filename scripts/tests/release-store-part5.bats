#!/usr/bin/env bats
# Immutable store installation, verification and publication races.
# Verbatim tests from release-store-original.txt (a2a8746e4).
load release-store-common

setup() {
  # Match the original per-case bootstrap; only part1 needs historical releases.
  export TRELLIS_ATTACH_POSTJOB=off
  GROUP_PLAN_CASE_LOCK_HELD=false
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  initialize_release_store_machine || return 1
  RELEASE_PROCESS_PID_A=""
  RELEASE_PROCESS_PID_B=""
  RELEASE_PROCESS_STATUS=""
}

@test "annotated tag install uses release.json plus immutable payload and adoption points to payload" {
  repo="$(build_release_repo "1.2.3-rc.1")"
  install_release "1.2.3-rc.1" "$repo"

  [ -f "$RELEASE_DIR/release.json" ]
  [ -d "$RELEASE_DIR/payload/core-rules" ]
  [ ! -e "$RELEASE_DIR/core-rules" ]
  commit="$(git -C "$repo" rev-parse "v1.2.3-rc.1^{commit}")"
  [ "$(jq -r '.version' "$RELEASE_DIR/release.json")" = "1.2.3-rc.1" ]
  [ "$(jq -r '.tag' "$RELEASE_DIR/release.json")" = "v1.2.3-rc.1" ]
  [ "$(jq -r '.commit' "$RELEASE_DIR/release.json")" = "$commit" ]
  [ "$(jq -r '.tree[] | select(.path == "core-rules/VERSION") | .oid' "$RELEASE_DIR/release.json")" = "$(git -C "$repo" rev-parse "$commit:core-rules/VERSION")" ]

  perms="$(LC_ALL=C ls -ld "$RELEASE_DIR/release.json" | awk '{print $1}')"
  [ "$(printf '%s' "$perms" | awk '{print substr($0,3,1) substr($0,6,1) substr($0,9,1)}')" = "---" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.3-rc.1"
  [ "$status" -eq 0 ]

  project="$SANDBOX/project with spaces"
  mkdir -p "$project/.trellis"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.2.3-rc.1" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$(cd "$RELEASE_DIR/payload" && pwd -P)" ]
}

@test "release rejects source execution outside the verified installed payload" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$SOURCE_RELEASE" list
  [ "$status" -eq 2 ]
  [[ "$output" == *"direct source execution is unsupported"* ]] || { echo "$output"; false; }
}

@test "version-derived paths reject malformed semver before touching the store" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "../1.2.3"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid semver version: ../1.2.3"* ]] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases/0.0.0" ]
  [ ! -e "$TRELLIS_HOME_FIX/1.2.3" ]
}

@test "install rejects a lightweight release tag" {
  repo="$(build_release_repo "1.2.4" lightweight)"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.2.4" --remote "$repo"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release ref is not an annotated tag: v1.2.4"* ]] || { echo "$output"; false; }
}

@test "install rejects tag and core-rules VERSION mismatch" {
  repo="$(build_release_repo "1.2.5" annotated "9.9.9")"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.2.5" --remote "$repo"
  [ "$status" -eq 4 ]
  [[ "$output" == *"core-rules/VERSION mismatch for v1.2.5: expected exact bytes for 1.2.5"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects extra root keys" {
  repo="$(build_release_repo "1.2.6")"
  install_release "1.2.6" "$repo"
  rewrite_release_json '. + {extra: true}'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.6"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects extra tree keys" {
  repo="$(build_release_repo "1.2.7")"
  install_release "1.2.7" "$repo"
  rewrite_release_json '.tree[0].extra = true'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.7"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects leading-zero semver and tag mismatch" {
  repo="$(build_release_repo "1.2.8")"
  install_release "1.2.8" "$repo"
  rewrite_release_json '.version = "01.2.8" | .tag = "v01.2.8"'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.8"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }

  chmod u+w "$SANDBOX" 2>/dev/null
  TRELLIS_HOME_FIX="$SANDBOX/trellis-home-tag"
  mkdir -p "$TRELLIS_HOME_FIX"
  provision_command_scratch "$TRELLIS_HOME_FIX"
  bootstrap_repo="$(build_release_repo "0.0.1" annotated "0.0.1" bootstrap-fixture)"
  TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    release-store-bootstrap "$RELEASE_STORE_LIB" "0.0.1" "$bootstrap_repo" || {
      echo 'could not install secondary test bootstrap release'
      false
    }
  RELEASE="$TRELLIS_HOME_FIX/releases/0.0.1/payload/scripts/release.sh"
  export TRELLIS_VERIFIED_PAYLOAD="$TRELLIS_HOME_FIX/releases/0.0.1/payload"
  export TRELLIS_VERIFIED_RELEASE_VERSION="0.0.1"
  repo="$(build_release_repo "1.2.9")"
  install_release "1.2.9" "$repo"
  rewrite_release_json '.tag = "v1.2.10"'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.9"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects unsafe relative paths" {
  repo="$(build_release_repo "1.3.0")"
  install_release "1.3.0" "$repo"
  rewrite_release_json '.tree[0].path = "../evil"'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "verify rejects changed payload content" {
  repo="$(build_release_repo "1.3.1")"
  install_release "1.3.1" "$repo"
  chmod u+w "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  printf '# tampered\n' > "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  chmod a-w "$RELEASE_DIR/payload/core-rules/CLAUDE.md"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"changed release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "verify rejects added payload content" {
  repo="$(build_release_repo "1.3.2")"
  install_release "1.3.2" "$repo"
  chmod u+w "$RELEASE_DIR/payload" "$RELEASE_DIR/payload/core-rules"
  printf 'extra\n' > "$RELEASE_DIR/payload/core-rules/extra.md"
  chmod a-w "$RELEASE_DIR/payload/core-rules/extra.md" "$RELEASE_DIR/payload/core-rules" "$RELEASE_DIR/payload"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.2"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release payload has missing or added paths"* ]] || { echo "$output"; false; }
}

@test "verify rejects unexpected release top-level siblings" {
  repo="$(build_release_repo "1.3.3")"
  install_release "1.3.3" "$repo"
  chmod u+w "$RELEASE_DIR"
  printf 'x\n' > "$RELEASE_DIR/extra"
  chmod a-w "$RELEASE_DIR/extra" "$RELEASE_DIR"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.3"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unexpected release top-level entry: extra"* ]] || { echo "$output"; false; }
}

@test "verify rejects writable release records and payload files" {
  repo="$(build_release_repo "1.3.4")"
  install_release "1.3.4" "$repo"
  chmod u+w "$RELEASE_DIR/release.json"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.4"
  [ "$status" -eq 4 ]
  [[ "$output" == *"writable release record: release.json"* ]] || { echo "$output"; false; }

  chmod a-w "$RELEASE_DIR/release.json"
  chmod u+w "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.4"
  [ "$status" -eq 4 ]
  [[ "$output" == *"writable release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "verify rejects release directory symlink store escape" {
  repo="$(build_release_repo "1.3.5")"
  install_release "1.3.5" "$repo"
  outside="$SANDBOX/outside"
  mkdir -p "$outside"
  chmod u+w "$RELEASE_DIR"
  mv "$RELEASE_DIR" "$outside/1.3.5"
  ln -s "$outside/1.3.5" "$RELEASE_DIR"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.5"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release directory is a symlink"* ]] || { echo "$output"; false; }
}

@test "adoption rejects relative traversal symlinked parent and non-symlink anchors" {
  repo="$(build_release_repo "1.3.6")"
  install_release "1.3.6" "$repo"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "project/.trellis/runtime"
  [ "$status" -eq 2 ]
  [[ "$output" == *"runtime anchor must be an absolute path ending in /.trellis/runtime without traversal"* ]] || { echo "$output"; false; }

  project="$SANDBOX/project"
  mkdir -p "$project/.trellis"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "$project/../project/.trellis/runtime"
  [ "$status" -eq 2 ]
  [[ "$output" == *"runtime anchor must be an absolute path ending in /.trellis/runtime without traversal"* ]] || { echo "$output"; false; }

  real_project="$SANDBOX/real-project"
  mkdir -p "$real_project/.trellis"
  ln -s "$real_project" "$SANDBOX/link-project"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "$SANDBOX/link-project/.trellis/runtime"
  [ "$status" -eq 3 ]
  [[ "$output" == *"runtime anchor parent contains a symlink component"* ]] || { echo "$output"; false; }

  touch "$project/.trellis/runtime"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 3 ]
  [[ "$output" == *"runtime anchor exists but is not a symlink"* ]] || { echo "$output"; false; }
}

@test "list and locate return only contained verified releases" {
  repo_a="$(build_release_repo "1.4.0")"
  install_release "1.4.0" "$repo_a"
  release_a="$RELEASE_DIR"
  repo_b="$(build_release_repo "1.4.1")"
  install_release "1.4.1" "$repo_b"
  release_b="$RELEASE_DIR"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" list
  [ "$status" -eq 0 ]
  [ "$output" = $'0.0.0\n1.4.0\n1.4.1' ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "1.4.0"
  [ "$status" -eq 0 ]
  [ "$output" = "$release_a" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "1.4.1"
  [ "$status" -eq 0 ]
  [ "$output" = "$release_b" ]

  outside="$SANDBOX/outside-release"
  mkdir -p "$outside"
  chmod u+w "$release_a"
  mv "$release_a" "$outside/1.4.0"
  ln -s "$outside/1.4.0" "$release_a"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "1.4.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release directory is a symlink"* ]] || { echo "$output"; false; }
}

@test "install requires VERSION bytes to equal one canonical version line" {
  for version in "1.4.2" "1.4.3" "1.4.4" "1.4.5"; do
    repo="$(build_release_repo "$version")"
    case "$version" in
      "1.4.2") printf '1.4.2' > "$repo/core-rules/VERSION" ;;
      "1.4.3") printf '1.4.3\n\n' > "$repo/core-rules/VERSION" ;;
      "1.4.4") printf '1.4.4\r\n' > "$repo/core-rules/VERSION" ;;
      "1.4.5") printf '1.4.5\npoison\n' > "$repo/core-rules/VERSION" ;;
    esac
    retag_release_repo "$repo" "$version"

    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "$version" --remote "$repo"
    [ "$status" -eq 4 ]
    [[ "$output" == *"core-rules/VERSION mismatch for v$version"* ]] || { echo "$output"; false; }
    [ ! -e "$TRELLIS_HOME_FIX/releases/$version" ]
    [ ! -e "$TRELLIS_HOME_FIX/releases/$version.lock" ]
  done
}

@test "version normalization rejects double tag prefixes without creating a store" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "vv1.4.3"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid semver version: vv1.4.3"* ]] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases/0.0.0" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/vv1.4.3" ]
}

@test "verify rejects missing payload files and executable mode drift" {
  missing_repo="$(build_release_repo "1.4.4")"
  install_release "1.4.4" "$missing_repo"
  chmod u+w "$RELEASE_DIR/payload" "$RELEASE_DIR/payload/docs"
  rm "$RELEASE_DIR/payload/docs/readme.md"
  chmod a-w "$RELEASE_DIR/payload/docs" "$RELEASE_DIR/payload"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.4"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release payload has missing or added paths"* ]] || { echo "$output"; false; }

  mode_repo="$(build_release_repo "1.4.5")"
  install_release "1.4.5" "$mode_repo"
  chmod u+x "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.5"
  [ "$status" -eq 4 ]
  [[ "$output" == *"wrong mode for core-rules/CLAUDE.md: expected 100644, found 100755"* ]] || { echo "$output"; false; }
}

@test "verify rejects unexpected empty directories and escaping payload symlinks" {
  directory_repo="$(build_release_repo "1.4.6")"
  install_release "1.4.6" "$directory_repo"
  chmod u+w "$RELEASE_DIR/payload"
  mkdir "$RELEASE_DIR/payload/untracked-empty"
  chmod a-w "$RELEASE_DIR/payload/untracked-empty" "$RELEASE_DIR/payload"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.6"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release payload has missing or added directories"* ]] || { echo "$output"; false; }

  link_repo="$(build_release_repo "1.4.7")"
  install_release "1.4.7" "$link_repo"
  chmod u+w "$RELEASE_DIR/payload"
  rm "$RELEASE_DIR/payload/AGENTS.md"
  ln -s "/etc/passwd" "$RELEASE_DIR/payload/AGENTS.md"
  chmod a-w "$RELEASE_DIR/payload"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.7"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unsafe release symlink target: AGENTS.md"* ]] || { echo "$output"; false; }
}

@test "unsafe archive symlinks fail before an immutable version is published" {
  repo="$(build_release_repo "1.4.8")"
  ln -s "/etc/passwd" "$repo/escape"
  retag_release_repo "$repo" "1.4.8"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.4.8" --remote "$repo"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unsafe release symlink target: escape"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.8" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.8.lock" ]
}

@test "existing versions remain immutable when their source tag is rewritten" {
  repo="$(build_release_repo "1.4.9")"
  install_release "1.4.9" "$repo"
  original_payload="$(cat "$RELEASE_DIR/payload/core-rules/CLAUDE.md")"

  printf '# poisoned source\n' > "$repo/core-rules/CLAUDE.md"
  retag_release_repo "$repo" "1.4.9"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.4.9" --remote "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"release already installed, refusing overwrite: 1.4.9"* ]] || { echo "$output"; false; }
  [ "$(cat "$RELEASE_DIR/payload/core-rules/CLAUDE.md")" = "$original_payload" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.9.lock" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.9"
  [ "$status" -eq 0 ]
}

@test "installed runtime remains isolated when the source is poisoned and moved" {
  repo="$(build_release_repo "1.4.10")"
  install_release "1.4.10" "$repo"
  release_dir="$RELEASE_DIR"
  project="$SANDBOX/project"
  mkdir -p "$project/.trellis"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.10" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  payload_hash="$(git hash-object "$release_dir/payload/core-rules/CLAUDE.md")"

  (
    cd "$repo" || exit 1
    git checkout -q -b poisoned-source
    printf '# poisoned source\n' > core-rules/CLAUDE.md
    git add core-rules/CLAUDE.md
    git commit -q -m "poison source checkout"
  )
  mv "$repo" "$SANDBOX/moved-source"

  [ "$(readlink "$project/.trellis/runtime")" = "$release_dir/payload" ]
  [ "$(git hash-object "$release_dir/payload/core-rules/CLAUDE.md")" = "$payload_hash" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.10"
  [ "$status" -eq 0 ]
}

@test "runtime anchor stays on A until explicit adoption switches it to B" {
  repo_a="$(build_release_repo "1.4.11")"
  install_release "1.4.11" "$repo_a"
  release_a="$RELEASE_DIR"
  repo_b="$(build_release_repo "1.4.12")"
  install_release "1.4.12" "$repo_b"
  release_b="$RELEASE_DIR"
  project="$SANDBOX/project"
  mkdir -p "$project/.trellis"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.11" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a/payload" ]
  [ -d "$release_b/payload" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a/payload" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.12" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$release_b/payload" ]
}

@test "unavailable install, verify, and compatibility-anchor paths return documented exit classes" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.4.13" --remote "$SANDBOX/unavailable-remote"
  [ "$status" -eq 5 ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.13" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.13.lock" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "9.9.9"
  [ "$status" -eq 5 ]

  repo="$(build_release_repo "1.4.14")"
  install_release "1.4.14" "$repo"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.14" --runtime-anchor "$SANDBOX/missing/.trellis/runtime"
  [ "$status" -eq 5 ]
}

@test "runtime record validator accepts the T2 fixture and rejects semantic identity corruption" {
  valid_record="$LOCAL_FLEET_FIXTURES/valid-release-record.json"
  runtime_validate_release_record "$valid_record"
  [ "$status" -eq 0 ]

  tag_mismatch="$SANDBOX/tag-mismatch.json"
  jq '.tag = "v1.0.0-rc.25"' "$valid_record" > "$tag_mismatch"
  runtime_validate_release_record "$tag_mismatch"
  [ "$status" -eq 1 ]

  duplicate_path="$SANDBOX/duplicate-path.json"
  jq '.tree += [(.tree[0] | .mode = "100755" | .oid = "ffffffffffffffffffffffffffffffffffffffff")]' \
    "$valid_record" > "$duplicate_path"
  runtime_validate_release_record "$duplicate_path"
  [ "$status" -eq 1 ]

  invalid_record="$LOCAL_FLEET_FIXTURES/invalid-release-corrupt-record.json"
  runtime_validate_release_record "$invalid_record"
  [ "$status" -eq 1 ]
  invalid_without_schema="$SANDBOX/invalid-release-without-schema.json"
  jq 'del(."$schema")' "$invalid_record" > "$invalid_without_schema"
  runtime_validate_release_record "$invalid_without_schema"
  [ "$status" -eq 1 ]
}

@test "install preserves a foreign version created after preflight" {
  repo="$(build_release_repo "1.5.0")"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  install_log="$SANDBOX/install.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" install "1.5.0" --remote "$repo" > "$install_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/install-before-publish.ready" "$RELEASE_PROCESS_PID_A" "$install_log"

  foreign_release="$TRELLIS_HOME_FIX/releases/1.5.0"
  mkdir "$foreign_release"
  foreign_inode="$(directory_inode "$foreign_release")"
  : > "$barrier/install-before-publish.release"

  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_A=""
  [ "$(directory_inode "$foreign_release")" = "$foreign_inode" ]
  [[ "$(cat "$install_log")" == *"release appeared during install, refusing overwrite: 1.5.0"* ]] || { cat "$install_log"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.5.0.lock" ]
}

@test "concurrent installs serialize with a class-3 loser" {
  repo="$(build_release_repo "1.5.4")"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  first_log="$SANDBOX/first-install.log"
  second_log="$SANDBOX/second-install.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" install "1.5.4" --remote "$repo" > "$first_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/install-before-publish.ready" "$RELEASE_PROCESS_PID_A" "$first_log"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" install "1.5.4" --remote "$repo" > "$second_log" 2>&1 &
  RELEASE_PROCESS_PID_B=$!
  wait_for_release_process "$RELEASE_PROCESS_PID_B"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_B=""
  [[ "$(cat "$second_log")" == *"release install is locked or already in progress: 1.5.4"* ]] || { cat "$second_log"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases/1.5.4.lock" ]

  : > "$barrier/install-before-publish.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 0 ] || { cat "$first_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [ -d "$TRELLIS_HOME_FIX/releases/1.5.4/payload" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.5.4.lock" ]
}

@test "runtime adoption preserves a foreign anchor created after preflight" {
  repo="$(build_release_repo "1.5.1")"
  install_release "1.5.1" "$repo"
  project="$SANDBOX/project"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  adopt_log="$SANDBOX/adopt.log"
  mkdir -p "$project/.trellis" "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "1.5.1" --runtime-anchor "$project/.trellis/runtime" > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/adopt-before-publish.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"

  printf 'project-owned runtime\n' > "$project/.trellis/runtime"
  : > "$barrier/adopt-before-publish.release"

  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_A=""
  [ ! -L "$project/.trellis/runtime" ]
  [ "$(cat "$project/.trellis/runtime")" = "project-owned runtime" ]
  [[ "$(cat "$adopt_log")" == *"runtime anchor appeared during adoption, refusing overwrite"* ]] || { cat "$adopt_log"; false; }
  [ ! -e "$project/.trellis/.runtime.lock" ]
}

@test "concurrent runtime adoptions serialize with a class-3 loser" {
  repo_a="$(build_release_repo "1.5.2")"
  install_release "1.5.2" "$repo_a"
  release_a="$RELEASE_DIR"
  repo_b="$(build_release_repo "1.5.3")"
  install_release "1.5.3" "$repo_b"
  project="$SANDBOX/project"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  first_log="$SANDBOX/first-adopt.log"
  second_log="$SANDBOX/second-adopt.log"
  mkdir -p "$project/.trellis" "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "1.5.2" --runtime-anchor "$project/.trellis/runtime" > "$first_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/adopt-before-publish.ready" "$RELEASE_PROCESS_PID_A" "$first_log"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "1.5.3" --runtime-anchor "$project/.trellis/runtime" > "$second_log" 2>&1 &
  RELEASE_PROCESS_PID_B=$!
  wait_for_release_process "$RELEASE_PROCESS_PID_B"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_B=""
  [[ "$(cat "$second_log")" == *"runtime anchor adoption is locked or already in progress"* ]] || { cat "$second_log"; false; }

  : > "$barrier/adopt-before-publish.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 0 ] || { cat "$first_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a/payload" ]
  [ ! -e "$project/.trellis/.runtime.lock" ]
}

@test "release barrier waits for a live release process past the old fixed cap" {
  # P1g (R39): under load a live release process can need longer than any fixed
  # cap to reach its barrier. Inversion: a 200-poll (20 s) cap fails this wait.
  sleep 600 &
  RELEASE_PROCESS_PID_A=$!
  local polls=0
  sleep() {
    polls=$((polls + 1))
    [ "$polls" -lt 300 ] || : > "$SANDBOX/late.ready"
  }
  run wait_for_release_barrier "$SANDBOX/late.ready" "$RELEASE_PROCESS_PID_A" "$SANDBOX/late.log"
  unset -f sleep
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  kill "$RELEASE_PROCESS_PID_A"
  wait "$RELEASE_PROCESS_PID_A" 2>/dev/null || true
  rm -f "$SANDBOX/late.ready"
  printf 'adopt refused\n' > "$SANDBOX/late.log"
  # An exited release process still fails at once, with its log in TAP.
  run wait_for_release_barrier "$SANDBOX/late.ready" "$RELEASE_PROCESS_PID_A" "$SANDBOX/late.log"
  RELEASE_PROCESS_PID_A=""
  [ "$status" -eq 1 ]
  [[ "$output" == *"release process exited before barrier"*"adopt refused"* ]]
}

@test "release barrier wait heartbeats with the release pid and elapsed seconds" {
  # P1g (R39 Q2 condition): the uncapped barrier wait must not hang silently.
  # Each stubbed poll costs 100 s of wall clock; the barrier opens at poll 5.
  sleep 600 &
  RELEASE_PROCESS_PID_A=$!
  local polls=0
  sleep() {
    polls=$((polls + 1))
    SECONDS=$((SECONDS + 100))
    [ "$polls" -lt 5 ] || : > "$SANDBOX/slow.ready"
  }
  run wait_for_release_barrier "$SANDBOX/slow.ready" "$RELEASE_PROCESS_PID_A" "$SANDBOX/slow.log"
  unset -f sleep
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" =~ "release pid $RELEASE_PROCESS_PID_A alive (elapsed "([0-9]+)"s)" ]] || { echo "$output"; false; }
  [ "${BASH_REMATCH[1]}" -ge 60 ]
}

@test "the snapshot copier refuses a foreign-version snapshot base at its own call site" {
  # THE GREEDY HOLE, reaching the copier. `.tmp.0.0.0.exec.9.exec.Ab3xY9` is
  # release 0.0.0.exec.9's snapshot; the copier resolves its SOURCE from
  # $version, so accepting this name under 0.0.0 makes the two halves of one
  # copy disagree about which release is being snapshotted.
  copy_snapshot 0.0.0 .tmp.0.0.0.exec.9.exec.Ab3xY9
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ "$(grep -cF 'release snapshot destination is unsafe: .tmp.0.0.0.exec.9.exec.Ab3xY9' <<<"$output")" -eq 1 ] ||
    { echo "$output"; false; }

  # An unrelated release's snapshot, refused by the same gate.
  copy_snapshot 0.0.0 .tmp.9.9.9.exec.Ab3xY9
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ "$(grep -cF 'release snapshot destination is unsafe: .tmp.9.9.9.exec.Ab3xY9' <<<"$output")" -eq 1 ] ||
    { echo "$output"; false; }

  # POSITIVE CONTROL, without which both refusals above would be satisfied by a
  # gate that rejects everything: a well-formed same-version name is past the
  # name gate and fails later, on the snapshot directory that does not exist —
  # a different fault, never this gate's class-2 refusal.
  copy_snapshot 0.0.0 .tmp.0.0.0.exec.Ab3xY9
  [ "$status" -ne 2 ] || { echo "$output"; false; }
  [ "$(grep -cF 'release snapshot destination is unsafe' <<<"$output")" -eq 0 ] ||
    { echo "$output"; false; }
}

@test "snapshot executor cleans its directory when post-creation owner capture fails" {
  local fake_bin="$SANDBOX/failing-ps-bin" leftover real_path real_python
  real_path="$PATH"
  real_python="$(command -v python3)"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ps" <<'EOF'
#!/bin/sh
# The executor has already created its private snapshot when it asks for the
# owner birth record. Failing this probe exercises that post-creation error
# handoff, rather than the ordinary successful payload-exit cleanup.
exit 77
EOF
  chmod 755 "$fake_bin/ps"
  # Darwin reads the birth token through libproc in a private python3 program
  # rather than through ps, so the ps stub alone would leave the probe healthy
  # and the case vacuous. Fail exactly that program -- identified by the
  # libproc flavour constant only it carries -- and pass every other python3
  # call in the snapshot path through to the real interpreter.
  {
    printf '#!/bin/sh\n'
    printf 'for arg in "$@"; do\n'
    printf '  case "$arg" in *PROC_PIDTBSDINFO*) exit 77 ;; esac\n'
    printf 'done\n'
    printf 'exec %q "$@"\n' "$real_python"
  } > "$fake_bin/python3"
  chmod 755 "$fake_bin/python3"

  PATH="$fake_bin:$real_path" run env \
    TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    PATH="$fake_bin:$real_path" \
    bash -c '. "$1"; release_store_snapshot_verified_release 0.0.0' \
    release-snapshot-owner-failure "$RELEASE_STORE_LIB"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not determine snapshot owner process birth"* ]] ||
    { echo "$output"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases" ]
  leftover="$(find "$TRELLIS_HOME_FIX/releases" -maxdepth 1 \
    \( -name '.tmp.*.exec.*' -o -name '.tmp.*.exec.*.owner.json' \) \
    -print 2>&1)"
  [ -z "$leftover" ] || { echo "post-creation snapshot leaked: $leftover"; false; }
}

@test "A3.4 the v1.3.6 store installs a packaged off-main tag with no excluded entries" {
  local v136="$SANDBOX/v1.3.6" src="$SANDBOX/packaged-source" remote="$SANDBOX/packaged-remote.git"
  local unfiltered="$SANDBOX/unfiltered-remote.git" home record
  payload_fixture_v136 "$v136" scripts/lib/release-store.sh scripts/lib/semver.sh
  payload_fixture_source "$src" 7.7.7
  payload_fixture_package "$src"
  payload_fixture_tag "$src" 7.7.7 "$PAYLOAD_FIXTURE_PAYLOAD"
  payload_fixture_remote "$src" "$remote" 7.7.7
  [ -z "$(payload_fixture_git --git-dir="$remote" rev-list main | grep -x "$PAYLOAD_FIXTURE_PAYLOAD")" ]
  [ -n "$(payload_fixture_git --git-dir="$remote" rev-list main | grep -x "$PAYLOAD_FIXTURE_RELEASE")" ]
  [ "$(payload_fixture_git --git-dir="$remote" rev-parse main)" != "$PAYLOAD_FIXTURE_RELEASE" ]

  home="$SANDBOX/v136-store-packaged"
  run env TRELLIS_HOME="$home" bash -c '. "$1"; release_store_install 7.7.7 "$2" ""' _ \
    "$v136/scripts/lib/release-store.sh" "$remote"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  record="$home/releases/7.7.7/release.json"
  [ "$(jq -r .commit "$record")" = "$PAYLOAD_FIXTURE_PAYLOAD" ]
  [ "$(payload_fixture_excluded_entries "$record")" -eq 0 ]
  jq -e '[.tree[].path] | index("core-rules/VERSION") and index("core-rules/hooks/x.sh")' "$record" >/dev/null
  [ ! -e "$home/releases/7.7.7/payload/specs" ]

  payload_fixture_unfiltered_remote "$src" "$unfiltered" 7.7.7
  home="$SANDBOX/v136-store-unfiltered"
  run env TRELLIS_HOME="$home" bash -c '. "$1"; release_store_install 7.7.7 "$2" ""' _ \
    "$v136/scripts/lib/release-store.sh" "$unfiltered"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  record="$home/releases/7.7.7/release.json"
  [ "$(jq -r .commit "$record")" = "$PAYLOAD_FIXTURE_RELEASE" ]
  [ "$(payload_fixture_excluded_entries "$record")" -eq 5 ]
}
