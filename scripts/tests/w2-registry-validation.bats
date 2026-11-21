#!/usr/bin/env bats
# Registry validation boundaries: global ownership and one manifest document.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-registry.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
}

@test "registry validator enforces every global ownership invariant" {
  local registry="$SANDBOX/registry.json" base="$SANDBOX/base.json" kind
  jq -n '
    def checkout($root; $common): {root:$root, git_common_dir:$common, harnesses:[], worktrees:{}};
    {schema_version:1, projects:{
      "fleet/one": {fleet:"fleet", project_id:"one", status:"active", metadata:{},
        checkouts:{(("a" * 64)): checkout("/one"; "/one/.git")}},
      "fleet/two": {fleet:"fleet", project_id:"two", status:"active", metadata:{},
        checkouts:{(("b" * 64)): checkout("/two"; "/two/.git")}}
    }}' > "$base"
  run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ "$REGISTRY_LIB" "$base"
  [ "$status" -eq 0 ]

  for kind in checkout_id common root unavailable_duplicate unavailable_active ignore_overlap; do
    jq --arg kind "$kind" '
      if $kind == "checkout_id" then
        .projects["fleet/two"].checkouts |= with_entries(.key = ("a" * 64))
      elif $kind == "common" then
        .projects["fleet/two"].checkouts[].git_common_dir = "/one/.git"
      elif $kind == "root" then
        .projects["fleet/two"].checkouts[].worktrees[(("c" * 64))] = {root:"/one"}
      elif $kind == "unavailable_duplicate" then
        .projects["fleet/one"].unavailable_roots = ["/offline"] |
        .projects["fleet/two"].unavailable_roots = ["/offline"]
      elif $kind == "unavailable_active" then
        .projects["fleet/two"].unavailable_roots = ["/one"]
      else .discovery_ignores = {fleet:[{path:"/one/child", reason:"fixture"}]} end
    ' "$base" > "$registry"
    run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ "$REGISTRY_LIB" "$registry"
    [ "$status" -ne 0 ] || { echo "accepted conflicting invariant: $kind"; false; }
  done

  # Repeating the root inside its own checkout is legitimate.
  jq '.projects["fleet/one"].checkouts[].worktrees[(("d" * 64))] = {root:"/one"}' "$base" > "$registry"
  run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ "$REGISTRY_LIB" "$registry"
  [ "$status" -eq 0 ]
}

@test "registry validator cannot hide an invalid document behind a valid one" {
  local registry="$SANDBOX/multiple.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"unexpected":true}' '{"schema_version":1,"projects":{}}' > "$registry"
  run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ "$REGISTRY_LIB" "$registry"
  [ "$status" -ne 0 ] || { echo 'multiple registry documents were accepted'; false; }
  printf '%s\n' '{"schema_version":1,"projects":{}}' > "$registry"
  run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ "$REGISTRY_LIB" "$registry"
  [ "$status" -eq 0 ]
}

@test "manifest validator refuses multiple JSON documents and multiline project IDs" {
  local manifest="$SANDBOX/manifest.json"
  printf '%s\n' '{"schema_version":1,"project_id":"ok-one","gate":{"env_passthrough":["GITHUB_PAT"]},"bogus":1}' '{"schema_version":1,"project_id":"ok-two"}' > "$manifest"
  run bash -c '. "$1"; local_registry_manifest_project_id "$2"' _ "$REGISTRY_LIB" "$manifest"
  [ "$status" -ne 0 ] || { echo "accepted multiple documents: $output"; false; }

  printf '%s\n' '{"schema_version":1,"project_id":"ok-one"}' '{"schema_version":1,"project_id":"ok-two"}' > "$manifest"
  run bash -c '. "$1"; local_registry_manifest_project_id "$2"' _ "$REGISTRY_LIB" "$manifest"
  [ "$status" -ne 0 ]
  run bash -c '. "$1"; local_registry_require_project_id "$2"' _ "$REGISTRY_LIB" $'ok-one\nok-two'
  [ "$status" -ne 0 ]

  printf '%s\n' '{"schema_version":1,"project_id":"valid-one","gate":{"env_passthrough":["CI"]}}' > "$manifest"
  run bash -c '. "$1"; local_registry_manifest_project_id "$2"' _ "$REGISTRY_LIB" "$manifest"
  [ "$status" -eq 0 ] && [ "$output" = valid-one ]
}

@test "manifest validator accepts a boolean gate.verdict_reuse and refuses any other type" {
  local manifest="$SANDBOX/manifest.json" value
  for value in true false; do
    printf '{"schema_version":1,"project_id":"reuse-%s","gate":{"verdict_reuse":%s,"docs_only_tests":%s,"env_passthrough":["CI"]}}\n' "$value" "$value" "$value" > "$manifest"
    run bash -c '. "$1"; local_registry_manifest_project_id "$2"' _ "$REGISTRY_LIB" "$manifest"
    [ "$status" -eq 0 ] && [ "$output" = "reuse-$value" ] || { echo "refused verdict_reuse=$value: $output"; false; }
  done
  for value in '"false"' 0 null '{}'; do
    printf '{"schema_version":1,"project_id":"reuse-bad","gate":{"verdict_reuse":%s}}\n' "$value" > "$manifest"
    run bash -c '. "$1"; local_registry_manifest_project_id "$2"' _ "$REGISTRY_LIB" "$manifest"
    [ "$status" -ne 0 ] || { echo "accepted verdict_reuse=$value"; false; }
    printf '{"schema_version":1,"project_id":"docs-bad","gate":{"docs_only_tests":%s}}\n' "$value" > "$manifest"
    run bash -c '. "$1"; local_registry_manifest_project_id "$2"' _ "$REGISTRY_LIB" "$manifest"
    [ "$status" -ne 0 ] || { echo "accepted docs_only_tests=$value"; false; }
  done
}

# The harness union has two readers: the registry schema on disk, and the
# preload fallback a bundled verified command needs because a bundle has no
# payload pathname. If they can disagree, one of them eventually will — that is
# exactly how `antigravity`/`opencode` reached the schema while two inline
# predicates still admitted only claude/codex/pi.
@test "the preloaded harness union fallback equals the registry schema enum" {
  local expected
  expected="$(jq -c '."$defs".harness.enum' "$REPO_ROOT/scripts/lib/trellis.registry.schema.json")"

  run bash -c '. "$1"; local_registry_harness_union' _ "$REGISTRY_LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$expected" ] || { echo "schema reader: $output"; false; }

  run bash -c '. "$1" || exit 1; TRELLIS_LIBS_PRELOADED=1; . "$2" || exit 1; local_registry_harness_union' \
    _ "$REPO_ROOT/scripts/lib/trellis-home.sh" "$REGISTRY_LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$expected" ] || { echo "preload fallback: $output"; false; }
}

@test "registry normalizer and schema validator admit canonical antigravity and opencode selectors while rejecting aliases and user scope" {
  local registry="$SANDBOX/compat-registry.json"

  run bash -c '. "$1"; local_registry_normalize_harnesses "[\"opencode\",\"claude\",\"antigravity\",\"pi\",\"codex\",\"opencode\"]"' _ "$REGISTRY_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = '["antigravity","claude","codex","opencode","pi"]' ]

  run bash -c '. "$1"; local_registry_normalize_harnesses "[\"antigravity\"]"' _ "$REGISTRY_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = '["antigravity"]' ]

  run bash -c '. "$1"; local_registry_normalize_harnesses "[\"opencode\"]"' _ "$REGISTRY_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = '["opencode"]' ]

  for bad in '["agy"]' '["user"]' '["antigravity","agy"]' '["unknown"]'; do
    run bash -c '. "$1"; local_registry_normalize_harnesses "$2"' _ "$REGISTRY_LIB" "$bad"
    [ "$status" -eq 2 ] || { echo "accepted $bad: status=$status output=$output"; false; }
  done

  jq -n '{
    schema_version: 1,
    projects: {
      "fleet/one": {
        fleet: "fleet",
        project_id: "one",
        status: "active",
        metadata: {},
        checkouts: {
          (("a" * 64)): {
            root: "/one",
            git_common_dir: "/one/.git",
            harnesses: ["antigravity", "opencode"],
            worktrees: {}
          }
        }
      }
    }
  }' > "$registry"
  run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ "$REGISTRY_LIB" "$registry"
  [ "$status" -eq 0 ]

  jq '.projects["fleet/one"].checkouts[].harnesses = ["agy"]' "$registry" > "$registry.bad"
  run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ "$REGISTRY_LIB" "$registry.bad"
  [ "$status" -ne 0 ]
}
