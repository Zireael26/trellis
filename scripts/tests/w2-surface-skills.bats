#!/usr/bin/env bats
# Expanded user skill destinations must obey cross-harness exposure rules.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
PLANNER="$REPO_ROOT/scripts/lib/surface-plan.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-surface.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  PAYLOAD="$SANDBOX/payload"
  MANIFEST="$PAYLOAD/core-rules/inheritance-manifest.json"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  mkdir -p "$PAYLOAD/core-rules/user/foo" "$PAYLOAD/core-rules/project"
  printf 'skill\n' > "$PAYLOAD/core-rules/user/foo/SKILL.md"
  jq -n '{schema_version:2,harnesses:{
    claude:{links:[],render:[]}, codex:{links:[],render:[]}, pi:{links:[],render:[]},
    shared_agents:{links:[{source_children:"core-rules/project",destination_dir:".agents/skills",entry_type:"directory",exclude_dirs:[]}],render:[]},
    user:{links:[{source_children:"core-rules/user",destination_dir:".agents/skills",entry_type:"directory",destination_home:true}],render:[]}
  }}' > "$MANIFEST"
}

change_manifest() {
  jq "$1" "$MANIFEST" > "$MANIFEST.next"
  mv "$MANIFEST.next" "$MANIFEST"
}

@test "user source children cannot duplicate a direct solo skill" {
  change_manifest '.harnesses.user.links += [{source:"core-rules/user/foo",destination:".pi/agent/skills/foo",destination_home:true}]'
  run bash "$PLANNER" --payload "$PAYLOAD" --harness user
  [ "$status" -eq 4 ] || { echo "duplicate accepted: $output"; false; }
}

@test "user source children cannot be shadowed by a project expansion" {
  mkdir -p "$PAYLOAD/core-rules/project/foo"
  run bash "$PLANNER" --payload "$PAYLOAD" --harness pi
  [ "$status" -eq 4 ] || { echo "shadow accepted: $output"; false; }
  change_manifest '.harnesses.shared_agents.links[0].exclude_dirs = ["foo"]'
  run bash "$PLANNER" --payload "$PAYLOAD" --harness pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "user render cannot duplicate an expanded shared skill" {
  change_manifest '.harnesses.user.render += [{template:"core-rules/user/foo/SKILL.md",destination:".pi/agent/skills/foo/SKILL.md",destination_home:true,merge:"replace",mode:"0600",required:true}]'
  run bash "$PLANNER" --payload "$PAYLOAD" --harness user
  [ "$status" -eq 4 ] || { echo "duplicate render accepted: $output"; false; }
}

@test "project render cannot shadow an expanded user skill" {
  change_manifest '.harnesses.pi.render += [{template:"core-rules/user/foo/SKILL.md",destination:".agents/skills/foo/SKILL.md",merge:"replace",mode:"0600",required:true}]'
  run bash "$PLANNER" --payload "$PAYLOAD" --harness pi
  [ "$status" -eq 4 ] || { echo "shadowing render accepted: $output"; false; }
}

@test "different names in shared and solo roots remain allowed" {
  change_manifest '.harnesses.user.links += [{source:"core-rules/user/foo",destination:".pi/agent/skills/bar",destination_home:true}]'
  run bash "$PLANNER" --payload "$PAYLOAD" --harness user
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "absent optional renders are not treated as exposed skills" {
  change_manifest '.harnesses.user.render += [{template:"core-rules/missing.md",destination:".pi/agent/skills/foo/SKILL.md",destination_home:true,merge:"replace",mode:"0600",required:false}]'
  run bash "$PLANNER" --payload "$PAYLOAD" --harness user
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e '.optional_missing | length == 1' >/dev/null
}

@test "legacy manifests without excludes retain the project shadow exemption" {
  mkdir -p "$PAYLOAD/core-rules/project/foo"
  change_manifest 'del(.harnesses.shared_agents.links[0].exclude_dirs)'
  run bash "$PLANNER" --payload "$PAYLOAD" --harness pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
