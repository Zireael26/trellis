#!/usr/bin/env bats
# Only a demonstrably absent checkout may be deregistered without --force.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
REGISTRY="$REPO_ROOT/scripts/registry.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-deregister.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME" "$SANDBOX/volume"
  PROJECT="$SANDBOX/volume/project"
  git init -q "$PROJECT"
  jq -n --arg root "$SANDBOX" '{schema_version:1,source_root:$root,release_remote:$root,active_cli_release:"1.0.0",default_fleet:"personal",fleets:{personal:{discovery_roots:[$root]}}}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal sample "$2" "" "[]" "" "{}"' _ "$REPO_ROOT/scripts/lib/local-registry.sh" "$PROJECT" >/dev/null
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
}

@test "inaccessible live checkout cannot be deregistered without force" {
  chmod 000 "$SANDBOX/volume"
  run "$REGISTRY" deregister --fleet personal --worktree-root "$PROJECT"
  rc="$status"
  chmod 700 "$SANDBOX/volume"
  [ "$rc" -ne 0 ] || { echo "inaccessible checkout deregistered: $output"; false; }
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
  [ -d "$PROJECT/.git" ]
}

@test "demonstrably absent checkout is still removable without force" {
  mv "$PROJECT" "$SANDBOX/moved-project"
  run "$REGISTRY" deregister --fleet personal --worktree-root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.projects == {}' "$TRELLIS_HOME/registry.json" >/dev/null
}

@test "accessible live checkout remains refused without force" {
  run "$REGISTRY" deregister --fleet personal --worktree-root "$PROJECT"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
}
