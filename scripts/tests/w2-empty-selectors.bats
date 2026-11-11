#!/usr/bin/env bats
# Explicitly empty project selectors must never widen a fleet operation.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-selectors.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  jq -n --arg root "$SANDBOX" '{schema_version:1,source_root:$root,release_remote:$root,active_cli_release:"1.0.0",default_fleet:"personal",fleets:{personal:{discovery_roots:[$root]}}}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  bash -c '. "$1"; local_registry_record_unavailable_root "$TRELLIS_HOME" personal example "$2/missing" "{}"' _ "$REPO_ROOT/scripts/lib/local-registry.sh" "$SANDBOX"
  before="$(shasum -a 256 "$TRELLIS_HOME/registry.json")"
}

@test "rollout rejects empty --project values before selecting a fleet" {
  run "$REPO_ROOT/scripts/rollout-hooks.sh" --yes --project ''
  [ "$status" -eq 2 ] || { echo "empty selector widened rollout: $output"; false; }
  run "$REPO_ROOT/scripts/rollout-hooks.sh" --yes --project=
  [ "$status" -eq 2 ] || { echo "empty equals selector widened rollout: $output"; false; }
  [ "$(shasum -a 256 "$TRELLIS_HOME/registry.json")" = "$before" ]
}

@test "Claude and Codex sync reject empty positional selectors" {
  local script
  for script in sync-hooks.sh sync-codex-hooks.sh; do
    run "$REPO_ROOT/scripts/$script" --yes ''
    [ "$status" -eq 2 ] || { echo "empty selector widened $script: $output"; false; }
    run "$REPO_ROOT/scripts/$script" --yes -- ''
    [ "$status" -eq 2 ] || { echo "empty -- selector widened $script: $output"; false; }
  done
  [ "$(shasum -a 256 "$TRELLIS_HOME/registry.json")" = "$before" ]
}

@test "valid project selectors and unscoped dry-runs keep their existing meaning" {
  local script
  run "$REPO_ROOT/scripts/rollout-hooks.sh" --check --project absent
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  for script in sync-hooks.sh sync-codex-hooks.sh; do
    run "$REPO_ROOT/scripts/$script" --dry-run absent
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    run "$REPO_ROOT/scripts/$script" --dry-run
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'Targets: 1'* ]] || { echo "$output"; false; }
  done
  [ "$(shasum -a 256 "$TRELLIS_HOME/registry.json")" = "$before" ]
}
