#!/usr/bin/env bats
# Every on-disk adoption marker must stop ordinary attachment.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-adoption.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  PROJECT="$SANDBOX/project" SENTINEL="$SANDBOX/reached-manifest"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME" "$PROJECT"
  git -C "$PROJECT" init -q
  source "$REPO_ROOT/scripts/attach-project.sh"
  identity="$(local_registry_identity_for_root "$PROJECT")"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  mkdir -p "$TRELLIS_HOME/state/release-adoptions"
  MARKER="$TRELLIS_HOME/state/release-adoptions/$checkout"
  # The manifest is read once before the adoption check and once afterwards.
  # Stop at the second read, proving the boundary was passed without publishing.
  local_registry_manifest_project_id() {
    if [ ! -e "$SANDBOX/manifest-seen" ]; then
      : > "$SANDBOX/manifest-seen"
      printf 'fixture\n'
    else
      : > "$SENTINEL"
      return 4
    fi
  }
}

run_attach() { run attach_cmd_attach --home "$TRELLIS_HOME" "$PROJECT"; }

@test "regular-file adoption marker stops attach" {
  printf 'pending\n' > "$MARKER"
  run_attach
  [ "$status" -eq 3 ] || { echo "regular marker bypassed: $output"; false; }
  [ ! -e "$SENTINEL" ]
}

@test "dangling-symlink adoption marker stops attach" {
  ln -s "$SANDBOX/missing" "$MARKER"
  run_attach
  [ "$status" -eq 3 ] || { echo "symlink marker bypassed: $output"; false; }
  [ ! -e "$SENTINEL" ]
}

@test "directory adoption marker still stops attach" {
  mkdir "$MARKER"
  run_attach
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ ! -e "$SENTINEL" ]
}

@test "no marker permits attach to reach its ordinary validation" {
  run_attach
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ -f "$SENTINEL" ]
}
