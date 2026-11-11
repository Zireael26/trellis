#!/usr/bin/env bats
# Managed checkout binding, hooks and runtime isolation.
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

@test "installed releases honor project selection and never switch implicitly" {
  install_adoption_releases
  project="$SANDBOX/project-selector"
  make_portable_project "$project" project-selector
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"adopt requires --project"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project project-selector
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}

# BEGIN LANE fx5
@test "successful locked adoption reaps only old private transaction stages" {
  install_adoption_releases
  project="$SANDBOX/stale-stage-project"
  make_portable_project "$project" stale-stage-project
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ -d "$managed" ] || { echo 'managed hook fixture missing' >&2; false; }
  owner_dir="$(dirname "$owner")"; owner_base="$(basename "$owner")"
  hook_dir="$(dirname "$managed")"; hook_base="$(basename "$managed")"
  old_owner="$owner_dir/.$owner_base.release-adopt.a1B2c3"
  young_owner="$owner_dir/.$owner_base.release-adopt.d4E5f6"
  other_owner="$owner_dir/.$owner_base.release-adopt.not-six"
  link_owner="$owner_dir/.$owner_base.release-adopt.g7H8i9"
  wrong_kind="$owner_dir/.$owner_base.release-adopt.j1K2l3"
  old_hook="$hook_dir/.$hook_base.release-adopt.m4N5o6"
  young_hook="$hook_dir/.$hook_base.release-adopt.p7Q8r9"
  unknown_hook="$hook_dir/.$hook_base.release-adopt.s1T2u3"
  printf old > "$old_owner"; printf young > "$young_owner"; printf other > "$other_owner"
  chmod 600 "$old_owner" "$young_owner" "$other_owner"
  printf 'outside\n' > "$SANDBOX/outside"
  ln -s "$SANDBOX/outside" "$link_owner"
  mkdir -m 700 "$wrong_kind" "$old_hook" "$young_hook" "$unknown_hook"
  printf partial > "$old_hook/post-checkout"; chmod 700 "$old_hook/post-checkout"
  printf keep > "$unknown_hook/unexpected"; chmod 600 "$unknown_hook/unexpected"
  touch -t 200001010000 "$old_owner" "$other_owner" "$wrong_kind" "$old_hook" "$unknown_hook"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project stale-stage-project
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$old_owner" ] || { echo 'old owner stage survived' >&2; false; }
  [ ! -e "$old_hook" ] || { echo 'old hook stage survived' >&2; false; }
  [ -f "$young_owner" ] && [ -d "$young_hook" ] || { echo 'young stage removed' >&2; false; }
  [ -f "$other_owner" ] && [ -d "$wrong_kind" ] || { echo 'non-matching stage removed' >&2; false; }
  [ -L "$link_owner" ] && [ "$(<"$SANDBOX/outside")" = outside ] || { echo 'stage symlink followed' >&2; false; }
  [ "$(<"$unknown_hook/unexpected")" = keep ] || { echo 'unknown stage content removed' >&2; false; }
}

@test "TERM during real hook staging is reaped by the next successful adoption" {
  install_adoption_releases
  project="$SANDBOX/term-stage-project"
  make_portable_project "$project" term-stage-project
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  hook_dir="$(dirname "$managed")"; hook_base="$(basename "$managed")"
  cp "$owner" "$SANDBOX/owner-before"
  hooks_before="$(hook_state_listing "$managed")"
  mkdir "$RELEASE_TEST_HOOK_BARRIER"
  : > "$RELEASE_TEST_HOOK_BARRIER/partial-write"
  log="$SANDBOX/term-stage-adopt.log"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project term-stage-project > "$log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$RELEASE_TEST_HOOK_BARRIER/partial-hook-write.ready" "$RELEASE_PROCESS_PID_A" "$log"
  transaction_pid="$(<"$RELEASE_TEST_HOOK_BARRIER/partial-hook-write.pid")"
  case "$transaction_pid" in ''|*[!0-9]*|0*) echo 'invalid transaction PID' >&2; return 1 ;; esac
  [ "$transaction_pid" != "$RELEASE_PROCESS_PID_A" ] || { echo 'expected the actual hook subshell' >&2; return 1; }
  kill -TERM "$transaction_pid"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  RELEASE_PROCESS_PID_A=''
  [ "$RELEASE_PROCESS_STATUS" -ne 0 ] || { echo 'interrupted adoption unexpectedly succeeded' >&2; return 1; }
  cmp -s "$owner" "$SANDBOX/owner-before" || { echo 'owner changed after interrupted stage' >&2; return 1; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ] || { echo 'runtime changed after interrupted stage' >&2; return 1; }
  [ "$(hook_state_listing "$managed")" = "$hooks_before" ] || { echo 'live hooks changed after interrupted stage' >&2; return 1; }
  shopt -s nullglob
  stages=("$hook_dir/.$hook_base.release-adopt."??????)
  [ "${#stages[@]}" -eq 1 ] || { echo "expected one interrupted stage, got ${#stages[@]}" >&2; return 1; }
  stage="${stages[0]}"
  [ -d "$stage" ] && [ ! -L "$stage" ] || return 1
  touch -t 200001010000 "$stage"
  young="$(mktemp -d "$hook_dir/.$hook_base.release-adopt.XXXXXX")"
  chmod 700 "$young"
  rm -rf "${RELEASE_TEST_HOOK_BARRIER:?}"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project term-stage-project
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$stage" ] || { echo 'old interrupted stage survived retry' >&2; return 1; }
  [ -d "$young" ] || { echo 'young stage was removed' >&2; return 1; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
}
# END LANE fx5

@test "managed adoption ignores hostile inherited Git environment" {
  install_adoption_releases
  project="$SANDBOX/git-env-project"
  make_portable_project "$project" git-env-project
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  hostile_git_dir="$SANDBOX/hostile-git-dir"
  hostile_config="$SANDBOX/hostile.gitconfig"
  mkdir "$hostile_git_dir"
  printf '[core]\n\thooksPath = /nonexistent/hostile-hooks\n\tfsmonitor = /nonexistent/hostile-fsmonitor\n' > "$hostile_config"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    GIT_DIR="$hostile_git_dir" \
    GIT_WORK_TREE="$SANDBOX/hostile-worktree" \
    GIT_CONFIG_GLOBAL="$hostile_config" \
    GIT_CONFIG_NOSYSTEM=0 \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project git-env-project
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}

@test "installed releases honor fleet selection across every selected worktree" {
  install_adoption_releases
  first="$SANDBOX/fleet-one"
  second="$SANDBOX/fleet-two"
  make_portable_project "$first" fleet-one
  make_portable_project "$second" fleet-two
  attach_portable_project "$first" personal "$ADOPTION_VERSION_A"
  attach_portable_project "$second" personal "$ADOPTION_VERSION_A"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$first/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(readlink "$second/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$first")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$second")" = "$ADOPTION_VERSION_B" ]
}

@test "installed releases honor all selection across fleets" {
  install_adoption_releases
  personal="$SANDBOX/all-personal"
  work="$SANDBOX/all-work"
  make_portable_project "$personal" all-personal
  make_portable_project "$work" all-work
  attach_portable_project "$personal" personal "$ADOPTION_VERSION_A"
  attach_portable_project "$work" work "$ADOPTION_VERSION_A"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$personal/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(readlink "$work/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$personal")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$work")" = "$ADOPTION_VERSION_B" ]
}

@test "managed adoption re-resolves current manifest identity under checkout lock before mutation" {
  install_adoption_releases
  project="$SANDBOX/identity-drift"
  make_portable_project "$project" identity-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  adopt_log="$SANDBOX/identity-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project identity-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  jq '.project_id = "other-project"' "$project/.trellis.json" > "$project/.trellis.json.next"
  mv "$project/.trellis.json.next" "$project/.trellis.json"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"current project manifest ID does not match"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}

@test "managed adoption rejects registry binding drift under checkout lock before mutation" {
  install_adoption_releases
  project="$SANDBOX/registry-drift"
  make_portable_project "$project" registry-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  registry="$TRELLIS_HOME_FIX/registry.json"
  project_key="personal/registry-drift"
  checkout="$(jq -r --arg project "$project_key" --arg root "$project" '
    .projects[$project].checkouts | to_entries[]
    | select([.value.worktrees[].root] | index($root))
    | .key
  ' "$registry")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  adopt_log="$SANDBOX/registry-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project registry-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  jq --arg project "$project_key" --arg checkout "$checkout" '
    .projects[$project].checkouts[$checkout].harnesses = ["claude"]
  ' "$registry" > "$registry.next"
  mv "$registry.next" "$registry"
  chmod 600 "$registry"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"selected registry row changed before release adoption"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
  jq -e --arg project "$project_key" --arg checkout "$checkout" '
    .projects[$project].checkouts[$checkout].harnesses == ["claude"]
  ' "$registry" >/dev/null
}

@test "managed adoption rejects attachment owner project identity drift under checkout lock before mutation" {
  install_adoption_releases
  project="$SANDBOX/owner-drift"
  make_portable_project "$project" owner-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  adopt_log="$SANDBOX/owner-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project owner-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  jq '.project_id = "other-project"' "$owner" > "$owner.next"
  chmod 600 "$owner.next"
  mv "$owner.next" "$owner"
  owner_drifted="$(cat "$owner")"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"attachment owner no longer exactly matches the selected registry row"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_drifted" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}

@test "managed adoption rejects a replacement .trellis namespace after lock-time verification" {
  install_adoption_releases
  project="$SANDBOX/namespace-drift"
  make_portable_project "$project" namespace-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  original_trellis="$SANDBOX/original-trellis"
  adopt_log="$SANDBOX/namespace-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project namespace-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  mv "$project/.trellis" "$original_trellis"
  mkdir "$project/.trellis"
  ln -s "$ADOPTION_PAYLOAD_A" "$project/.trellis/runtime"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"release adoption target drifted after plan validation"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}

@test "managed adoption rejects malformed, schema-invalid, untracked, and symlinked portable manifests before mutation" {
  install_adoption_releases
  project="$SANDBOX/manifest-boundary"
  make_portable_project "$project" manifest-boundary
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  printf '{not-json\n' > "$project/.trellis.json"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 4 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  printf '{"schema_version":1,"project_id":"manifest-boundary","unexpected":true}\n' > "$project/.trellis.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 4 ]
  [[ "$output" == *"project manifest failed schema-aware validation"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  printf '{"schema_version":1,"project_id":"manifest-boundary"}\n' > "$project/.trellis.json"
  git -C "$project" rm --cached -f -q .trellis.json
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 3 ]
  [[ "$output" == *"project manifest must be tracked"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]

  manifest="$SANDBOX/regular-manifest"
  printf '{"schema_version":1,"project_id":"manifest-boundary"}\n' > "$manifest"
  rm "$project/.trellis.json"
  ln -s "$manifest" "$project/.trellis.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 4 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
}

@test "hook release adoption exchanges the managed directory and restores it on interruption" {
  install_adoption_releases
  project="$SANDBOX/hook-interruption"
  make_portable_project "$project" hook-interruption
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ -d "$managed" ]
  [ ! -L "$managed" ]
  [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]
  managed_inode_before="$(directory_inode "$managed")"
  managed_state_before="$(hook_state_listing "$managed")"
  barrier="$RELEASE_TEST_HOOK_BARRIER"
  adopt_log="$SANDBOX/hook-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project hook-interruption > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/hook-swap-after-exchange.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  for _ in {1..50}; do
    [ -d "$managed" ]
    [ ! -L "$managed" ]
    [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]
    [ "$(cat "$managed/release-payload")" = "$ADOPTION_PAYLOAD_B" ]
    sleep 0.01
  done
  hook_swap_pid="$(cat "$barrier/hook-swap-after-exchange.pid")"
  kill -TERM "$hook_swap_pid"

  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 4 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [ -d "$managed" ]
  [ ! -L "$managed" ]
  [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]
  [ "$(directory_inode "$managed")" = "$managed_inode_before" ]
  [ "$(hook_state_listing "$managed")" = "$managed_state_before" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}

@test "adoption reports recorded operator-owned hook authority without repairing it" {
  install_adoption_releases
  project="$SANDBOX/hook-operator-owned"
  make_portable_project "$project" hook-operator-owned
  git -C "$project" config --local core.hooksPath .husky/_

  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  jq -e --arg managed "$managed" '
    .status == "committed"
    and .git_hooks.enabled == true
    and .git_hooks.managed_hooks_path == $managed
    and .git_hooks.previous_hooks_path == ".husky/_"
  ' "$owner" >/dev/null
  [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]

  git -C "$project" config --local core.hooksPath .husky/_
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project hook-operator-owned
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"hook authority: operator-owned; core.hooksPath was left unchanged"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/hook-operator-owned"* ]] || { echo "$output"; false; }
  [ "$(git -C "$project" config --local --get core.hooksPath)" = ".husky/_" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_B" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = ".husky/_" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
  [ "$(cat "$managed/release-payload")" = "$ADOPTION_PAYLOAD_B" ]
}

@test "an attached checkout keeps its runtime and policy markers when the source is dirtied, rebranched, and moved" {
  local repo payload project anchor_before links_before markers_before tracked_before
  local record_before version_before exclude_before moved

  repo="$(build_release_repo "1.7.0")"
  install_release "1.7.0" "$repo"
  payload="$RELEASE_DIR/payload"
  project="$SANDBOX/source-poisoning"
  make_portable_project "$project" source-poisoning
  attach_portable_project "$project" personal "1.7.0"

  anchor_before="$(readlink "$project/.trellis/runtime")"
  [ "$anchor_before" = "$payload" ]
  links_before="$(managed_link_map "$project")"
  markers_before="$(resolved_policy_markers "$project")"
  [ -n "$markers_before" ]
  tracked_before="$(git -C "$project" ls-files -s)"
  record_before="$(sha256_file "$RELEASE_DIR/release.json")"
  version_before="$(cat "$payload/core-rules/VERSION")"
  exclude_before="$(sha256_file "$project/.git/info/exclude")"
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.0" ]

  # Poison the mutable source three ways at once: a new branch, a committed
  # policy rewrite, and an uncommitted dirty edit on top of it.
  (
    cd "$repo" || exit 1
    git checkout -q -b poisoned-source
    printf '# poisoned policy\n' > core-rules/CLAUDE.md
    printf '9.9.9\n' > core-rules/VERSION
    git add core-rules/CLAUDE.md core-rules/VERSION
    git commit -q -m "poison the source checkout"
  )
  printf '# uncommitted poison\n' >> "$repo/core-rules/CLAUDE.md"
  moved="$SANDBOX/moved poisoned source"
  mv "$repo" "$moved"
  [ ! -e "$repo" ]

  [ "$(readlink "$project/.trellis/runtime")" = "$anchor_before" ]
  [ "$(managed_link_map "$project")" = "$links_before" ]
  [ "$(resolved_policy_markers "$project")" = "$markers_before" ]
  [ "$(cat "$payload/core-rules/VERSION")" = "$version_before" ]
  [ "$(sha256_file "$RELEASE_DIR/release.json")" = "$record_before" ]
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
  [ "$(sha256_file "$project/.git/info/exclude")" = "$exclude_before" ]
  [ -z "$(git -C "$project" status --porcelain)" ]

  # The poison never reached the resolved policy the harness reads.
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.0" ]
  case "$(cat "$project/.claude/rules/trellis.md")" in
    *poison*)
      printf 'poisoned source bytes reached the attached runtime\n'
      false
      ;;
  esac

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.7.0"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "installing a second release leaves an attached checkout on A until adoption swaps exactly one anchor" {
  local repo_a repo_b payload_a payload_b project owner
  local anchor_before links_before markers_before tracked_before owner_before exclude_before
  local links_after leaf_links_before leaf_links_after managed hook_payload_before

  repo_a="$(build_release_repo "1.7.1")"
  install_release "1.7.1" "$repo_a"
  payload_a="$RELEASE_DIR/payload"
  project="$SANDBOX/explicit-adoption"
  make_portable_project "$project" explicit-adoption
  attach_portable_project "$project" personal "1.7.1"
  owner="$(owner_for_root "$project")"

  anchor_before="$(readlink "$project/.trellis/runtime")"
  [ "$anchor_before" = "$payload_a" ]
  links_before="$(managed_link_map "$project")"
  leaf_links_before="$(printf '%s\n' "$links_before" | grep -v '^\.trellis/runtime ->')"
  [ -n "$leaf_links_before" ]
  markers_before="$(resolved_policy_markers "$project")"
  tracked_before="$(git -C "$project" ls-files -s)"
  owner_before="$(cat "$owner")"
  exclude_before="$(sha256_file "$project/.git/info/exclude")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  hook_payload_before="$(cat "$managed/release-payload")"
  [ "$hook_payload_before" = "$payload_a" ]

  # Installing B is a store operation, not an adoption.
  repo_b="$(build_release_repo "1.7.2")"
  install_release "1.7.2" "$repo_b"
  payload_b="$RELEASE_DIR/payload"
  [ -d "$payload_b" ]
  [ "$payload_a" != "$payload_b" ]

  [ "$(readlink "$project/.trellis/runtime")" = "$anchor_before" ]
  [ "$(managed_link_map "$project")" = "$links_before" ]
  [ "$(resolved_policy_markers "$project")" = "$markers_before" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "1.7.1" ]
  [ "$(cat "$managed/release-payload")" = "$hook_payload_before" ]
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.1" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "1.7.2" --project explicit-adoption
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Exactly one anchor moved: the leaf links keep both their targets AND their
  # inodes, so no harness surface was rewritten to reach release B.
  links_after="$(managed_link_map "$project")"
  leaf_links_after="$(printf '%s\n' "$links_after" | grep -v '^\.trellis/runtime ->')"
  [ "$leaf_links_after" = "$leaf_links_before" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$links_after" != "$links_before" ]

  # The single anchor move is what re-points every harness surface.
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.2" ]
  [ "$(resolved_policy_markers "$project")" != "$markers_before" ]
  [ "$(jq -r '.release' "$owner")" = "1.7.2" ]
  [ "$(registry_release_for_root "$project")" = "1.7.2" ]
  [ "$(cat "$managed/release-payload")" = "$payload_b" ]

  # Nothing tracked and no managed exclude line changed.
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
  [ "$(sha256_file "$project/.git/info/exclude")" = "$exclude_before" ]
  [ -z "$(git -C "$project" status --porcelain)" ]

  # Release A stays installed and verifiable, so adoption is reversible.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.7.1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "1.7.1" --project explicit-adoption
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(resolved_policy_markers "$project")" = "$markers_before" ]
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
}

# Shared scaffold sections below; existing tests above remain unchanged.
# BEGIN LANE A0
# END LANE A0

# BEGIN LANE A1
# END LANE A1

# BEGIN LANE A2
# END LANE A2

# BEGIN LANE A3
# END LANE A3

# BEGIN LANE A4
# END LANE A4

# BEGIN LANE B1
# END LANE B1

# BEGIN LANE B2
# END LANE B2

# BEGIN LANE B3
# END LANE B3

# BEGIN LANE B4
# END LANE B4

# BEGIN LANE B5
# END LANE B5

# BEGIN LANE B6
# END LANE B6

# BEGIN LANE B7
# END LANE B7

# BEGIN LANE B8
# END LANE B8

# BEGIN LANE B9
# END LANE B9

# BEGIN LANE B10
# END LANE B10

# BEGIN LANE B11
# END LANE B11

# BEGIN LANE C0
# END LANE C0

# BEGIN LANE C1
# END LANE C1

# BEGIN LANE C2
# END LANE C2

# BEGIN LANE C3
# END LANE C3

# BEGIN LANE C4
# END LANE C4

# BEGIN LANE serial-tail
# END LANE serial-tail
