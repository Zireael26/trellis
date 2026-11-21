#!/usr/bin/env bats
# Rendered JSON and Pi/owned-leaf retirement.
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

@test "adoption preserves current hooks when target hook generation fails" {
  assert_malformed_hook_adoption_preserves_current_release failure
}

@test "adoption preserves current hooks when target hook generation succeeds empty" {
  assert_malformed_hook_adoption_preserves_current_release empty
}

@test "explicit-json adoption preserves unrelated destination keys" {
  local version_a=1.6.2 version_b=1.6.3 repo project destination owner mode
  local payload_a payload_b

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"
  payload_b="$RELEASE_DIR/payload"

  project="$SANDBOX/explicit-json-project"
  make_portable_project "$project" explicit-json-project
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  jq '.unrelated = "keep-me"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"
  owner="$(owner_for_root "$project")"

  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(jq -r '.release' "$owner")" = "$version_a" ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-project
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/explicit-json-project"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$(jq -r '.release' "$owner")" = "$version_b" ]
  [ "$(registry_release_for_root "$project")" = "$version_b" ]
  jq -e '.effortLevel == "medium" and .unrelated == "keep-me"' "$destination" >/dev/null
  case "$(uname -s)" in
    Darwin) mode="$(stat -f '%Lp' "$destination")" ;;
    *) mode="$(stat -c '%a' "$destination")" ;;
  esac
  [ "$mode" = 600 ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null
}

@test "explicit-json adoption re-renders missing and changed owned keys" {
  local version_a=1.6.4 version_b=1.6.5 repo project destination owner mode
  local payload_a payload_b

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"
  payload_b="$RELEASE_DIR/payload"

  project="$SANDBOX/explicit-json-rerender"
  make_portable_project "$project" explicit-json-rerender
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  jq 'del(.effortLevel) | .unrelated = "keep-me"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"
  owner="$(owner_for_root "$project")"

  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(jq -r '.release' "$owner")" = "$version_a" ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-rerender
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'re-rendered owned JSON key: .claude/settings.local.json ["effortLevel"] (missing)'* ]] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/explicit-json-rerender"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$(jq -r '.release' "$owner")" = "$version_b" ]
  [ "$(registry_release_for_root "$project")" = "$version_b" ]
  jq -e '.effortLevel == "medium" and .unrelated == "keep-me"' "$destination" >/dev/null
  case "$(uname -s)" in
    Darwin) mode="$(stat -f '%Lp' "$destination")" ;;
    *) mode="$(stat -c '%a' "$destination")" ;;
  esac
  [ "$mode" = 600 ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null

  project="$SANDBOX/explicit-json-changed"
  make_portable_project "$project" explicit-json-changed
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  jq '.effortLevel = "low" | .unrelated = "still-local"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-changed

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'re-rendered owned JSON key: .claude/settings.local.json ["effortLevel"] (changed)'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/explicit-json-changed"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$(registry_release_for_root "$project")" = "$version_b" ]
  jq -e '.effortLevel == "medium" and .unrelated == "still-local"' "$destination" >/dev/null
}

@test "explicit-json adoption re-renders missing and changed owned keys in a multi-owner checkout" {
  local version_a=1.6.4 version_b=1.6.5 repo project sibling root destination owner mode
  local payload_a payload_b main_owner sibling_owner

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"
  payload_b="$RELEASE_DIR/payload"

  project="$SANDBOX/explicit-json-group"
  sibling="$SANDBOX/explicit-json-sibling"
  make_portable_project "$project" explicit-json-group
  attach_portable_project "$project" personal "$version_a"
  payload_fixture_git -C "$project" worktree add --detach "$sibling"
  attach_portable_project "$sibling" personal "$version_a"
  main_owner="$(owner_for_root "$project")"
  sibling_owner="$(owner_for_root "$sibling")"
  # Two distinct owners in one checkout force the shared-exclude planner;
  # attach both before introducing repairable owned-key drift.
  [ "$main_owner" != "$sibling_owner" ]
  [ "$(dirname "$main_owner")" = "$(dirname "$sibling_owner")" ]
  for root in "$project" "$sibling"; do
    owner="$(owner_for_root "$root")"
    [ "$(readlink "$root/.trellis/runtime")" = "$payload_a" ]
    jq -e --arg version "$version_a" '.release == $version and .status == "committed"
      and any(.renders[]; .path == ".claude/settings.local.json"
        and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  done

  destination="$project/.claude/settings.local.json"
  jq 'del(.effortLevel) | .unrelated = "keep-main"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"
  destination="$sibling/.claude/settings.local.json"
  jq '.effortLevel = "low" | .unrelated = "keep-sibling"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"
  jq -e 'has("effortLevel") | not' "$project/.claude/settings.local.json" >/dev/null
  jq -e '.effortLevel == "low"' "$sibling/.claude/settings.local.json" >/dev/null

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-group
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'re-rendered owned JSON key: .claude/settings.local.json ["effortLevel"] (missing)'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'re-rendered owned JSON key: .claude/settings.local.json ["effortLevel"] (changed)'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/explicit-json-group"* ]] || { echo "$output"; false; }

  jq -e '.effortLevel == "medium" and .unrelated == "keep-main"' "$project/.claude/settings.local.json" >/dev/null
  jq -e '.effortLevel == "medium" and .unrelated == "keep-sibling"' "$sibling/.claude/settings.local.json" >/dev/null
  for root in "$project" "$sibling"; do
    owner="$(owner_for_root "$root")"
    destination="$root/.claude/settings.local.json"
    [ "$(readlink "$root/.trellis/runtime")" = "$payload_b" ]
    [ "$(registry_release_for_root "$root")" = "$version_b" ]
    jq -e --arg version "$version_b" '.release == $version and .status == "committed"
      and any(.renders[]; .path == ".claude/settings.local.json"
        and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))
      and any(.artifacts[]; .path == ".claude/settings.local.json"
        and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null
    case "$(uname -s)" in
      Darwin) mode="$(stat -f '%Lp' "$destination")" ;;
      *) mode="$(stat -c '%a' "$destination")" ;;
    esac
    [ "$mode" = 600 ]
  done
  [ "$(jq -r '.exclude_block_hash' "$main_owner")" = "$(jq -r '.exclude_block_hash' "$sibling_owner")" ]
  group_plan_assert_no_journal
}

@test "group adoption retires an owned leaf the new release dropped and restores it on interruption" {
  local version_a=1.9.4 version_b=1.9.5 repo project sibling root owner payload_a barrier adopt_log hook_swap_pid
  local -a owners_before=()
  repo="$(build_retiring_release_repo "$version_a")"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_release_repo "$version_b")"
  install_release "$version_b" "$repo"
  project="$SANDBOX/retiring-group"
  sibling="$SANDBOX/retiring-sibling"
  make_portable_project "$project" retiring-group
  attach_portable_project "$project" personal "$version_a"
  payload_fixture_git -C "$project" worktree add --detach "$sibling"
  attach_portable_project "$sibling" personal "$version_a"
  wait_for_attachment_statuses 2
  for root in "$project" "$sibling"; do
    [ "$(readlink "$root/.codex/hooks/retired.md")" = ../../.trellis/runtime/core-rules/retired.md ]
    owners_before+=("$(cat "$(owner_for_root "$root")")")
  done

  # An interrupted adopt puts every retired link back with its recorded target.
  barrier="$RELEASE_TEST_HOOK_BARRIER"
  adopt_log="$SANDBOX/retiring-adopt.log"
  mkdir "$barrier"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$version_b" --project retiring-group > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/hook-swap-after-exchange.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  [ ! -e "$project/.codex/hooks/retired.md" ]
  [ ! -L "$project/.codex/hooks/retired.md" ]
  hook_swap_pid="$(cat "$barrier/hook-swap-after-exchange.pid")"
  kill -TERM "$hook_swap_pid"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -ne 0 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  rm -rf "$barrier"
  for root in "$project" "$sibling"; do
    [ "$(readlink "$root/.codex/hooks/retired.md")" = ../../.trellis/runtime/core-rules/retired.md ]
    [ "$(readlink "$root/.trellis/runtime")" = "$payload_a" ]
  done
  [ "$(cat "$(owner_for_root "$project")")" = "${owners_before[0]}" ]
  [ "$(cat "$(owner_for_root "$sibling")")" = "${owners_before[1]}" ]
  group_plan_assert_no_journal

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project retiring-group
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for root in "$project" "$sibling"; do
    owner="$(owner_for_root "$root")"
    [ ! -e "$root/.codex/hooks/retired.md" ]
    [ ! -L "$root/.codex/hooks/retired.md" ]
    jq -e --arg version "$version_b" '.release == $version
      and all(.artifacts[]; .path != ".codex/hooks/retired.md")
      and any(.artifacts[]; .path == ".agents/rules/trellis.md")' "$owner" >/dev/null
    [ -z "$(git -C "$root" status --porcelain)" ] || { git -C "$root" status --porcelain; false; }
  done
  ! grep -Fx '/.codex/hooks/retired.md' "$project/.git/info/exclude"
  group_plan_assert_no_journal
}

@test "Pi old to new to old adoption refuses before mutation and names exact checkout recovery" {
  local version_a=1.10.0 version_b=1.10.1 repo project sibling root owner payload_b index
  local detach_expected attach_expected
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  payload_b="$RELEASE_DIR/payload"
  project="$SANDBOX/pi reverse main"
  sibling="$SANDBOX/pi reverse sibling"
  make_portable_project "$project" pi-reverse
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release "$version_a" \
    --harness claude --harness pi "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  payload_fixture_git -C "$project" worktree add --detach "$sibling"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release "$version_a" \
    --harness claude --harness pi "$sibling"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attachment_statuses 2
  for root in "$project" "$sibling"; do
    [ -L "$root/.pi/hooks/dispatch.sh" ]
    [ -L "$root/.pi/hooks/lib/task-context.sh" ]
  done

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --fleet personal --project pi-reverse
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  index=0
  for root in "$project" "$sibling"; do
    index=$((index + 1))
    owner="$(owner_for_root "$root")"
    [ "$(readlink "$root/.trellis/runtime")" = "$payload_b" ]
    [ "$(registry_release_for_root "$root")" = "$version_b" ]
    [ ! -e "$root/.pi/hooks" ]
    [ ! -L "$root/.pi/hooks" ]
    jq -e 'all(.artifacts[];
      .kind != "symlink" or (.path | . != ".pi/hooks" and (startswith(".pi/hooks/") | not)))' \
      "$owner" >/dev/null
    cp "$owner" "$SANDBOX/pi-reverse-owner.$index.before"
  done
  cp "$project/.git/info/exclude" "$SANDBOX/pi-reverse-exclude.before"
  cp "$TRELLIS_HOME_FIX/registry.json" "$SANDBOX/pi-reverse-registry.before"
  group_plan_assert_no_journal

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_a" --fleet personal --project pi-reverse
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"cannot adopt $version_a for checkout $project:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"adopted:"* ]] || { echo "$output"; false; }
  printf -v detach_expected 'trellis detach --home %q --all-worktrees %q' "$TRELLIS_HOME_FIX" "$project"
  [[ "$output" == *"$detach_expected"* ]] || { echo "$output"; false; }
  index=0
  for root in "$project" "$sibling"; do
    index=$((index + 1))
    printf -v attach_expected 'trellis attach --home %q --fleet personal --release %q --harness claude --harness pi %q' \
      "$TRELLIS_HOME_FIX" "$version_a" "$root"
    [[ "$output" == *"$attach_expected"* ]] || { echo "$output"; false; }
    cmp "$SANDBOX/pi-reverse-owner.$index.before" "$(owner_for_root "$root")"
    [ "$(readlink "$root/.trellis/runtime")" = "$payload_b" ]
    [ "$(registry_release_for_root "$root")" = "$version_b" ]
    [ ! -e "$root/.pi/hooks" ]
    [ ! -L "$root/.pi/hooks" ]
  done
  cmp "$SANDBOX/pi-reverse-exclude.before" "$project/.git/info/exclude"
  cmp "$SANDBOX/pi-reverse-registry.before" "$TRELLIS_HOME_FIX/registry.json"
  group_plan_assert_no_journal
}

@test "Pi adoption links new leaves and treats hooks-other as outside the hooks tree" {
  local version_a=1.10.2 version_b=1.10.3 version_c=1.10.4 repo manifest project non_pi payload_b payload_c owner leaf
  local target=../../.trellis/runtime/core-rules/CLAUDE.md
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" legacy)"
  manifest="$repo/core-rules/inheritance-manifest.json"
  jq '.harnesses.pi.links += [{source:"core-rules/CLAUDE.md",destination:".pi/hooks/added.sh"}]' \
    "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  retag_release_repo "$repo" "$version_b"
  install_release "$version_b" "$repo"
  payload_b="$RELEASE_DIR/payload"
  repo="$(build_pi_release_repo "$version_c" current)"
  manifest="$repo/core-rules/inheritance-manifest.json"
  jq '.harnesses.pi.links += [
    {source:"core-rules/CLAUDE.md",destination:".pi/hooks-other/dispatch.sh"},
    {source:"core-rules/CLAUDE.md",destination:".pi/extensions/added.md"}]' \
    "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  retag_release_repo "$repo" "$version_c"
  install_release "$version_c" "$repo"
  payload_c="$RELEASE_DIR/payload"

  project="$SANDBOX/pi-forward-leaves"
  make_portable_project "$project" pi-forward-leaves
  attach_pi_project "$project" "$version_a"
  owner="$(owner_for_root "$project")" || { echo 'Pi owner not found'; false; }
  non_pi="$SANDBOX/non-pi-forward"
  make_portable_project "$non_pi" non-pi-forward
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release "$version_a" --harness claude "$non_pi"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attachment_statuses 2

  # A retained hook inventory permits forward adoption; 1.5.1 links the new hook.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-forward-leaves
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ -L "$project/.pi/hooks/dispatch.sh" ]
  [ -L "$project/.pi/hooks/added.sh" ] || false
  [ "$(readlink "$project/.pi/hooks/added.sh")" = "$target" ] || { echo 'new Pi hook target differs'; false; }
  jq -e --arg target "$target" '
    [.artifacts[] | select(.path == ".pi/hooks/added.sh" and .kind == "symlink" and .target == $target)] | length == 1
  ' "$owner" >/dev/null || { echo 'new Pi hook is not owned at its exact target'; false; }
  # A manifest's Pi hooks do not constrain an attachment without Pi selected.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project non-pi-forward
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$non_pi/.trellis/runtime")" = "$payload_b" ]
  [ ! -e "$non_pi/.pi" ]
  [ ! -L "$non_pi/.pi" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_c" --project pi-forward-leaves
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_c" ]
  [ ! -e "$project/.pi/hooks" ] || false
  [ ! -L "$project/.pi/hooks" ] || false
  # The retired .pi/hooks tree does not swallow its prefix neighbour: the new
  # .pi/hooks-other leaf is linked like any other leaf the release adds.
  [ -L "$project/.pi/hooks-other/dispatch.sh" ] || false
  [ -L "$project/.pi/extensions/added.md" ] || false
  for leaf in .pi/hooks-other/dispatch.sh .pi/extensions/added.md; do
    [ "$(readlink "$project/$leaf")" = "$target" ] || { echo "Pi leaf target differs: $leaf"; false; }
    jq -e --arg path "$leaf" --arg target "$target" '
      [.artifacts[] | select(.path == $path and .kind == "symlink" and .target == $target)] | length == 1
    ' "$owner" >/dev/null || { echo "Pi leaf is not owned at its exact target: $leaf"; false; }
  done
  jq -e 'all(.artifacts[]; (.path | startswith(".pi/hooks/")) | not)' "$owner" >/dev/null ||
    { echo 'retired Pi hooks remain in the owner'; false; }
  # With no hook inventory left, the prefix neighbour still must not refuse.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_c" --project pi-forward-leaves
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_release_for_root "$project")" = "$version_c" ]
  [ "$(registry_release_for_root "$non_pi")" = "$version_b" ]
  group_plan_assert_no_journal
}

@test "group adoption removes the retired .pi/hooks tree and restores it on interruption" {
  local version_a=1.9.6 version_b=1.9.7 repo project sibling root owner payload_a barrier adopt_log hook_swap_pid
  local hooks_mode lib_mode
  local -a owners_before=()
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  project="$SANDBOX/pi-hooks-group"
  sibling="$SANDBOX/pi-hooks-sibling"
  make_portable_project "$project" pi-hooks-group
  attach_pi_project "$project" "$version_a"
  payload_fixture_git -C "$project" worktree add --detach "$sibling"
  attach_pi_project "$sibling" "$version_a"
  wait_for_attachment_statuses 2
  for root in "$project" "$sibling"; do
    [ -L "$root/.pi/hooks/dispatch.sh" ]
    [ -L "$root/.pi/hooks/lib/task-context.sh" ]
    chmod 0700 "$root/.pi/hooks"
    chmod 0750 "$root/.pi/hooks/lib"
    owners_before+=("$(cat "$(owner_for_root "$root")")")
  done

  barrier="$RELEASE_TEST_HOOK_BARRIER"
  adopt_log="$SANDBOX/pi-hooks-adopt.log"
  mkdir "$barrier"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$version_b" --project pi-hooks-group > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/hook-swap-after-exchange.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  [ ! -e "$project/.pi/hooks" ]
  [ ! -L "$project/.pi/hooks" ]
  hook_swap_pid="$(cat "$barrier/hook-swap-after-exchange.pid")"
  kill -TERM "$hook_swap_pid"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -ne 0 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  rm -rf "$barrier"
  for root in "$project" "$sibling"; do
    [ "$(readlink "$root/.pi/hooks/dispatch.sh")" = ../../.trellis/runtime/core-rules/CLAUDE.md ]
    [ "$(readlink "$root/.pi/hooks/lib/task-context.sh")" = ../../../.trellis/runtime/core-rules/CLAUDE.md ]
    hooks_mode="$(directory_mode "$root/.pi/hooks")"
    lib_mode="$(directory_mode "$root/.pi/hooks/lib")"
    [ "$hooks_mode" = 700 ]
    [ "$lib_mode" = 750 ]
    [ "$(readlink "$root/.trellis/runtime")" = "$payload_a" ]
  done
  [ "$(cat "$(owner_for_root "$project")")" = "${owners_before[0]}" ]
  [ "$(cat "$(owner_for_root "$sibling")")" = "${owners_before[1]}" ]
  group_plan_assert_no_journal

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-hooks-group
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for root in "$project" "$sibling"; do
    owner="$(owner_for_root "$root")"
    [ ! -e "$root/.pi/hooks" ]
    [ ! -L "$root/.pi/hooks" ]
    [ -L "$root/.pi/extensions/trellis.md" ]
    jq -e --arg version "$version_b" '.release == $version
      and all(.artifacts[]; .path | startswith(".pi/hooks") | not)' "$owner" >/dev/null
    [ -z "$(git -C "$root" status --porcelain)" ] || { git -C "$root" status --porcelain; false; }
  done
  ! grep -F '/.pi/hooks/' "$project/.git/info/exclude"
  group_plan_assert_no_journal
}

@test "single-owner adoption re-plans the exclude block when .pi/hooks retires" {
  local version_a=1.9.12 version_b=1.9.13 repo project owner exclude user_bytes stale_record restoration
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  project="$SANDBOX/pi-hooks-single"
  exclude="$project/.git/info/exclude"
  make_portable_project "$project" pi-hooks-single
  user_bytes=$'# project-authored\n/scratch/'
  printf '%s' "$user_bytes" > "$exclude"
  attach_pi_project "$project" "$version_a"
  wait_for_attachment_statuses 1
  [ "$(find "$TRELLIS_HOME_FIX/state/attachments" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ]
  grep -Fx '/.pi/hooks/dispatch.sh' "$exclude"
  printf '/external-cache/\n' >> "$exclude"
  strict_attachment_check "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(owner_for_root "$project")"
  stale_record="$(jq -c '{exclude,exclude_block_hash}' "$owner")"
  restoration="$(jq -cS '.exclude | {before_exists,before_sha256,before_base64}' "$owner")"
  cp "$exclude" "$SANDBOX/single-stale.exclude"
  show_attachment_config "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-hooks-single
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(owner_for_root "$project")"
  [ ! -e "$project/.pi/hooks" ]
  [ ! -L "$project/.pi/hooks" ]
  [ "$(grep -cF '/.pi/hooks' "$exclude")" = 0 ]
  grep -Fx '/.pi/extensions/trellis.md' "$exclude"
  [ "$(head -c "${#user_bytes}" "$exclude")" = "${user_bytes%$'\n'}" ]
  grep -Fx '/external-cache/' "$exclude"
  [ "$(jq -cS '.exclude | {before_exists,before_sha256,before_base64}' "$owner")" = "$restoration" ]
  strict_attachment_check "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e --arg version "$version_b" '.release == $version
    and (.exclude.after_base64 | @base64d | contains("/external-cache/") | not)
    and .exclude_block_hash == .exclude.managed_block_sha256
    and (.exclude.managed_block_base64 | @base64d | contains("/.pi/hooks") | not)' "$owner" >/dev/null
  show_attachment_config "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$(git -C "$project" status --porcelain)" ] || { git -C "$project" status --porcelain; false; }
  group_plan_assert_no_journal

  # A checkout a 1.3.18 CLI already left stale (new release, links retired, old
  # block) is repaired by adopting its pinned release again.
  jq --argjson stale "$stale_record" '. + $stale' "$owner" > "$owner.next"
  chmod 600 "$owner.next"
  mv "$owner.next" "$owner"
  cp "$SANDBOX/single-stale.exclude" "$exclude"
  strict_attachment_check "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"managed excludes: owner block does not match the exact immutable native surface plan"* ]] ||
    { echo "$output"; false; }
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-hooks-single
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -cF '/.pi/hooks' "$exclude")" = 0 ]
  grep -Fx '/external-cache/' "$exclude"
  strict_attachment_check "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  show_attachment_config "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  group_plan_assert_no_journal
}

@test "interrupted single-owner adoption restores the exclude block and owner record" {
  local version_a=1.9.14 version_b=1.9.15 repo project owner owner_before exclude barrier adopt_log hook_swap_pid
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  project="$SANDBOX/pi-hooks-single-interrupted"
  exclude="$project/.git/info/exclude"
  make_portable_project "$project" pi-hooks-single-interrupted
  attach_pi_project "$project" "$version_a"
  wait_for_attachment_statuses 1
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  printf '/external-interrupted/\n' >> "$exclude"
  strict_attachment_check "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cp "$exclude" "$SANDBOX/single-exclude.before"

  # The exclude CAS publishes before the hook swap, so this barrier proves the
  # rollback restores the published block, not just an untouched file.
  barrier="$RELEASE_TEST_HOOK_BARRIER"
  adopt_log="$SANDBOX/single-adopt.log"
  mkdir "$barrier"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$version_b" --project pi-hooks-single-interrupted > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/hook-swap-after-exchange.ready" "$RELEASE_PROCESS_PID_A" "$adopt_log"
  [ "$(grep -cF '/.pi/hooks' "$exclude")" = 0 ]
  hook_swap_pid="$(cat "$barrier/hook-swap-after-exchange.pid")"
  kill -TERM "$hook_swap_pid"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -ne 0 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  rm -rf "$barrier"
  cmp "$SANDBOX/single-exclude.before" "$exclude"
  [ "$(cat "$owner")" = "$owner_before" ]
  [ -L "$project/.pi/hooks/dispatch.sh" ]
  [ "$(registry_release_for_root "$project")" = "$version_a" ]
  group_plan_assert_no_journal
  strict_attachment_check "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-hooks-single-interrupted
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -cF '/.pi/hooks' "$exclude")" = 0 ]
  strict_attachment_check "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  group_plan_assert_no_journal
}

@test "group adoption preserves external excludes and recorded restoration snapshots" {
  local version_a=1.9.16 version_b=1.9.17 repo project sibling root owner
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  project="$SANDBOX/pi-external-group"
  sibling="$SANDBOX/pi-external-sibling"
  make_portable_project "$project" pi-external-group
  attach_pi_project "$project" "$version_a"
  payload_fixture_git -C "$project" worktree add --detach "$sibling"
  attach_pi_project "$sibling" "$version_a"
  wait_for_attachment_statuses 2
  for root in "$project" "$sibling"; do
    owner="$(owner_for_root "$root")"
    jq -cS '.exclude | {before_exists,before_sha256,before_base64}' "$owner" > "$root.before"
  done
  printf '/external-group/\n' >> "$project/.git/info/exclude"
  for root in "$project" "$sibling"; do
    strict_attachment_check "$root"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-external-group
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx '/external-group/' "$project/.git/info/exclude"
  [ "$(grep -cF '/.pi/hooks' "$project/.git/info/exclude")" = 0 ]
  for root in "$project" "$sibling"; do
    owner="$(owner_for_root "$root")"
    jq -cS '.exclude | {before_exists,before_sha256,before_base64}' "$owner" > "$root.after"
    cmp "$root.before" "$root.after"
    strict_attachment_check "$root"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    show_attachment_config "$root"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
  group_plan_assert_no_journal
}

@test "group re-adoption repairs an already-stale non-manager after-image without changing the block" {
  local version=1.9.20 repo project sibling root owner exclude block
  repo="$(build_pi_release_repo "$version" current)"
  install_release "$version" "$repo"
  project="$SANDBOX/pi-stale-group"
  sibling="$SANDBOX/pi-stale-sibling"
  make_portable_project "$project" pi-stale-group
  attach_pi_project "$project" "$version"
  payload_fixture_git -C "$project" worktree add --detach "$sibling"
  attach_pi_project "$sibling" "$version"
  wait_for_attachment_statuses 2
  exclude="$project/.git/info/exclude"
  for root in "$project" "$sibling"; do
    owner="$(owner_for_root "$root")"
    jq -cS '.exclude | {before_exists,before_sha256,before_base64}' "$owner" > "$root.before"
  done
  owner="$(owner_for_root "$sibling")"
  jq -e '.exclude.managed_by_attachment == false' "$owner" >/dev/null
  block="$(jq -r '.exclude.managed_block_sha256' "$owner")"
  # An old CLI recorded live bytes even when the release/block was unchanged.
  printf '/external-stale-row/\n' >> "$exclude"
  cp "$exclude" "$SANDBOX/stale-live.before"
  jq --rawfile live "$exclude" --arg hash "$(sha256_file "$exclude")" \
    '.exclude.after_base64 = ($live | @base64) | .exclude.after_sha256 = $hash' \
    "$owner" > "$SANDBOX/stale-owner.json"
  cp "$SANDBOX/stale-owner.json" "$owner"
  strict_attachment_check "$sibling"
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner after-image does not exactly derive"* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version" --project pi-stale-group
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cmp "$SANDBOX/stale-live.before" "$exclude"
  for root in "$sibling" "$project"; do
    owner="$(owner_for_root "$root")"
    jq -cS '.exclude | {before_exists,before_sha256,before_base64}' "$owner" > "$root.after"
    cmp "$root.before" "$root.after"
    jq -e --arg block "$block" '.exclude.managed_block_sha256 == $block' "$owner" >/dev/null
    strict_attachment_check "$root"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
  show_attachment_config "$sibling"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  group_plan_assert_no_journal
}

@test "single-owner adoption refuses a lone non-manager without mutation" {
  local version_a=1.9.18 version_b=1.9.19 repo project sibling manager owner exclude managed hooks_before root
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  project="$SANDBOX/pi-missing-manager"
  sibling="$SANDBOX/pi-lone-follower"
  make_portable_project "$project" pi-missing-manager
  attach_pi_project "$project" "$version_a"
  payload_fixture_git -C "$project" worktree add --detach "$sibling"
  attach_pi_project "$sibling" "$version_a"
  wait_for_attachment_statuses 2
  manager="$(owner_for_root "$project")"
  owner="$(owner_for_root "$sibling")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$manager")"
  jq -e '.exclude.managed_by_attachment == false' "$owner" >/dev/null
  mv "$manager" "$SANDBOX/manager.saved"
  jq --arg root "$project" '(.projects[].checkouts[].worktrees) |=
    with_entries(select(.value.root != $root))' "$TRELLIS_HOME_FIX/registry.json" > "$SANDBOX/registry.next"
  cp "$SANDBOX/registry.next" "$TRELLIS_HOME_FIX/registry.json"
  exclude="$project/.git/info/exclude"
  cp "$exclude" "$SANDBOX/exclude.before"
  cp "$owner" "$SANDBOX/owner.before"
  cp "$TRELLIS_HOME_FIX/registry.json" "$SANDBOX/registry.before"
  hooks_before="$(hook_state_listing "$managed")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-missing-manager
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"shared exclude requires exactly one manager"* ]] || { echo "$output"; false; }
  cmp "$SANDBOX/exclude.before" "$exclude"
  cmp "$SANDBOX/owner.before" "$owner"
  cmp "$SANDBOX/registry.before" "$TRELLIS_HOME_FIX/registry.json"
  [ "$(hook_state_listing "$managed")" = "$hooks_before" ]
  for root in "$project" "$sibling"; do
    [ "$(readlink "$root/.trellis/runtime")" = "$TRELLIS_HOME_FIX/releases/$version_a/payload" ]
    [ -L "$root/.pi/hooks/dispatch.sh" ]
    [ "$(git -C "$root" config --local --get core.hooksPath)" = "$managed" ]
  done
  [ ! -e "$manager" ]
  group_plan_assert_no_journal
}

@test "adoption retires owned .pi/hooks leaves but leaves a project file and names it" {
  local version_a=1.9.8 version_b=1.9.9 repo project owner
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  project="$SANDBOX/pi-hooks-authored"
  make_portable_project "$project" pi-hooks-authored
  attach_pi_project "$project" "$version_a"
  wait_for_attachment_statuses 1
  printf 'mine\n' > "$project/.pi/hooks/notes.txt"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-hooks-authored
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"left in place: $project/.pi/hooks holds files Trellis does not own"* ]] || { echo "$output"; false; }
  [ "$(cat "$project/.pi/hooks/notes.txt")" = mine ]
  [ ! -e "$project/.pi/hooks/dispatch.sh" ]
  [ ! -L "$project/.pi/hooks/dispatch.sh" ]
  [ ! -e "$project/.pi/hooks/lib/task-context.sh" ]
  [ ! -L "$project/.pi/hooks/lib/task-context.sh" ]
  owner="$(owner_for_root "$project")"
  # The directories stay, so their parent entries stay owned; the leaves do not.
  jq -e --arg version "$version_b" '.release == $version
    and any(.artifacts[]; .path == ".pi/hooks" and .kind == "parent")
    and all(.artifacts[]; ((.path | startswith(".pi/hooks")) | not) or .kind == "parent")' "$owner" >/dev/null
}

@test "adoption preserves pre-existing unowned .pi/hooks directories" {
  local version_a=1.9.10 version_b=1.9.11 repo project owner
  repo="$(build_pi_release_repo "$version_a" legacy)"
  install_release "$version_a" "$repo"
  repo="$(build_pi_release_repo "$version_b" current)"
  install_release "$version_b" "$repo"
  project="$SANDBOX/pi-hooks-pre-existing"
  make_portable_project "$project" pi-hooks-pre-existing
  mkdir -p "$project/.pi/hooks/lib"
  attach_pi_project "$project" "$version_a"
  wait_for_attachment_statuses 1
  owner="$(owner_for_root "$project")"
  jq -e 'all(.artifacts[]; .kind != "parent" or (.path != ".pi/hooks" and .path != ".pi/hooks/lib"))' \
    "$owner" >/dev/null
  [ -d "$project/.pi/hooks" ]
  [ ! -L "$project/.pi/hooks" ]
  [ -d "$project/.pi/hooks/lib" ]
  [ ! -L "$project/.pi/hooks/lib" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-hooks-pre-existing
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$project/.pi/hooks/dispatch.sh" ]
  [ ! -L "$project/.pi/hooks/dispatch.sh" ]
  [ ! -e "$project/.pi/hooks/lib/task-context.sh" ]
  [ ! -L "$project/.pi/hooks/lib/task-context.sh" ]
  [ -d "$project/.pi/hooks" ]
  [ ! -L "$project/.pi/hooks" ]
  [ -d "$project/.pi/hooks/lib" ]
  [ ! -L "$project/.pi/hooks/lib" ]
  [[ "$output" == *"left in place: $project/.pi/hooks holds files Trellis does not own"* ]] || { echo "$output"; false; }
  jq -e --arg version "$version_b" '.release == $version
    and all(.artifacts[]; (.path | startswith(".pi/hooks")) | not)' "$owner" >/dev/null
}

@test "explicit-json adoption names an absent render target and changes nothing" {
  local version_a=1.6.6 version_b=1.6.7 repo project destination owner owner_before
  local payload_a

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"

  project="$SANDBOX/explicit-json-absent"
  make_portable_project "$project" explicit-json-absent
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  rm "$destination"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-absent

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"explicit-json render target is absent: .claude/settings.local.json"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"adopted:"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$version_a" ]
  [ ! -e "$destination" ]
}

@test "explicit-json adoption names invalid JSON and changes nothing" {
  local version_a=1.6.8 version_b=1.6.9 repo project destination owner owner_before
  local payload_a invalid_before

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"

  project="$SANDBOX/explicit-json-invalid"
  make_portable_project "$project" explicit-json-invalid
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  printf '{"effortLevel":\n' > "$destination"
  chmod 600 "$destination"
  invalid_before="$(cat "$destination")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-invalid

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"explicit-json render target is invalid JSON: .claude/settings.local.json"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"adopted:"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$version_a" ]
  [ "$(cat "$destination")" = "$invalid_before" ]
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
b1_migration_release() {
  local version="$1" native="$2" repo harness template
  repo="$(build_release_repo "$version" untagged)" || return 1
  mkdir -p "$repo/core-rules/templates"
  cp -R "$REPO_ROOT/core-rules/legacy-hooks" "$repo/core-rules/legacy-hooks"
  for template in claude-settings.local.json codex-hooks.local.json claude-user-settings.json; do
    cp "$REPO_ROOT/core-rules/legacy-hooks/$template" "$repo/core-rules/templates/$template"
  done
  printf '{}\n' > "$repo/trellis.config.json"
  cp "$REPO_ROOT/scripts/trellis" "$REPO_ROOT/scripts/configure.sh" "$REPO_ROOT/scripts/upgrade.sh" "$repo/scripts/"
  jq -n '{schema_version:1,harnesses:{
    claude:{links:[{source:"core-rules/CLAUDE.md",destination:".claude/rules/trellis.md"}],render:[{template:"core-rules/templates/claude-settings.local.json",destination:".claude/settings.local.json",merge:"explicit-json",mode:"0600",required:true}]},
    codex:{links:[{source:"core-rules/CLAUDE.md",destination:".agents/rules/trellis.md"}],render:[{template:"core-rules/templates/codex-hooks.local.json",destination:".codex/hooks.json",merge:"explicit-json",mode:"0600",required:true}]},
    user:{links:[],render:[{template:"core-rules/templates/claude-user-settings.json",destination:".claude/settings.json",destination_home:true,merge:"explicit-json",mode:"0600",required:true}]}
  }}' > "$repo/core-rules/inheritance-manifest.json"
  if [ "$native" = true ]; then
    cp -R "$REPO_ROOT/core-rules/native" "$repo/core-rules/native"
    jq --arg version "$version" '.version=$version' "$repo/core-rules/native/artifacts.json" > "$repo/core-rules/native/artifacts.next"
    mv "$repo/core-rules/native/artifacts.next" "$repo/core-rules/native/artifacts.json"
    for template in claude-settings.local.json codex-hooks.local.json claude-user-settings.json; do
      harness=claude; [ "$template" != codex-hooks.local.json ] || harness=codex
      if [ "$template" = claude-user-settings.json ]; then
        events='["WorktreeCreate","WorktreeRemove"]'
      else
        events='["PreToolUse","PostToolUse","UserPromptSubmit","SessionStart","Stop"]'
        [ "$harness" != claude ] || events='["PreToolUse","PostToolUse","UserPromptSubmit","SessionStart","Stop","WorktreeCreate"]'
      fi
      jq -n --arg harness "$harness" --argjson events "$events" '{hooks:($events | map(. as $event | {key:$event,value:[{hooks:[({type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event",$harness,$event],timeout:30} + (if $harness == "claude" then {onFailure:"block"} else {} end))]}]}) | from_entries)} + (if $harness == "claude" then {env:{TRELLIS_RENDER_GENERATION:"native"}} else {} end)'  > "$repo/core-rules/templates/$template"
    done
  fi
  git -C "$repo" add -A
  git -C "$repo" commit -qm 'isolated candidate render arrays'
  git -C "$repo" tag -a "v$version" -m "fixture $version"
  printf '%s\n' "$repo"
}

b1_setup_migration() {
  local old new selected
  old="$(b1_migration_release 1.4.0 false)" || return 1
  new="$(b1_migration_release 1.5.0 true)" || return 1
  install_release 1.4.0 "$old"
  install_release 1.5.0 "$new"
  B1_ROOT="$SANDBOX/b1-owned-arrays"
  make_portable_project "$B1_ROOT" b1-owned-arrays
  attach_portable_project "$B1_ROOT" personal 1.4.0
  B1_OWNER="$(owner_for_root "$B1_ROOT")"
  for selected in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
    jq '.hooks.PreToolUse[0].hooks += [{type:"command",command:"project-owned-hook"}] | .project = {keep:true}' "$selected" > "$SANDBOX/appended"
    cp "$SANDBOX/appended" "$selected"
    chmod 600 "$selected"
  done
  B1_PAYLOAD="$TRELLIS_HOME_FIX/releases/1.5.0/payload"
  cp "$B1_OWNER" "$SANDBOX/b1-old-owner.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REPO_ROOT/scripts/configure.sh" \
    --source "$new" --home "$TRELLIS_HOME_FIX" --release 1.5.0 \
    --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "B1 T66 native adoption migrates both local arrays and fresh owner and memo bindings" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local selected render manifest source_hash memo
  for selected in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
    jq -e '.project.keep == true and (.hooks.PreToolUse[0].hooks | length) == 1 and (.hooks.PreToolUse[0].hooks[0].command | contains("/bin/native/")) and [.hooks.PreToolUse[1].hooks[].command] == ["project-owned-hook"] and (.hooks | has("UserPromptExpansion") | not)' "$selected" >/dev/null
  done
  jq -e '.release == "1.5.0" and all(.renders[]; (.owned_keys | length) > 0 and .after_sha256 != null)' "$B1_OWNER" >/dev/null
  while IFS= read -r render; do
    selected="$B1_ROOT/$(printf '%s\n' "$render" | jq -r '.path')"
    [ "$(printf '%s\n' "$render" | jq -r '.after_sha256')" = "$(shasum -a 256 "$selected" | awk '{print $1}')" ]
  done < <(jq -c '.renders[]' "$B1_OWNER")
  [ "$(readlink "$B1_ROOT/.trellis/runtime")" = "$B1_PAYLOAD" ]
  [ "$(registry_release_for_root "$B1_ROOT")" = 1.5.0 ]
  manifest="$(shasum -a 256 "$TRELLIS_HOME_FIX/releases/1.5.0/release.json" | awk '{print $1}')"
  source_hash="$(printf '%s' core-rules/githooks/pre-push | shasum -a 256 | awk '{print $1}')"
  memo="$TRELLIS_HOME_FIX/state/hook-digests/$manifest-$source_hash.json"
  jq -e --arg manifest "$manifest" --arg payload "$B1_PAYLOAD" '.manifest_sha256 == $manifest and .payload == $payload' "$memo" >/dev/null
  strict_attachment_check "$B1_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cp "$B1_OWNER" "$SANDBOX/b1-new-owner.json"
  cp "$SANDBOX/b1-old-owner.json" "$B1_OWNER"
  chmod 600 "$B1_OWNER"
  strict_attachment_check "$B1_ROOT"
  [ "$status" -ne 0 ] || { echo 'doctor/show-config strict row accepted a mixed generation'; return 1; }
  cp "$SANDBOX/b1-new-owner.json" "$B1_OWNER"
  chmod 600 "$B1_OWNER"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$HOME/.local/bin/trellis" detach --home "$TRELLIS_HOME_FIX" "$B1_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for selected in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
    jq -e '.project.keep == true and [.hooks.PreToolUse[].hooks[].command] == ["project-owned-hook"]' "$selected" >/dev/null
  done
}

b1_published_state() {
  python3 -I - "$TRELLIS_HOME_FIX" "$B1_ROOT" "$B1_OWNER" <<'PY'
import hashlib,json,os,pathlib,stat,sys
home,root,owner=map(pathlib.Path,sys.argv[1:]); record=json.loads(owner.read_text())
managed=pathlib.Path(record['git_hooks']['managed_hooks_path'])
paths=[owner,home/'registry.json',root/'.claude/settings.local.json',root/'.codex/hooks.json',root/'.git/info/exclude']
paths+=sorted(p for p in managed.iterdir() if p.is_file())
old_manifest=hashlib.sha256((home/'releases/1.4.0/release.json').read_bytes()).hexdigest()
paths+=sorted((home/'state/hook-digests').glob(old_manifest+'-*.json'))
data={str(p):(hashlib.sha256(p.read_bytes()).hexdigest(),stat.S_IMODE(p.stat().st_mode)) for p in paths}
print(json.dumps({'files':data,'anchor':os.readlink(root/'.trellis/runtime')},sort_keys=True))
PY
}

@test "B1 T66 migration refuses old owned positional drift and new key collisions" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  local selected="$B1_ROOT/.claude/settings.local.json" before
  cp "$selected" "$SANDBOX/b1-clean-settings"
  jq '.hooks.PreToolUse[0].hooks[0].command="changed-owned-position"' "$selected" > "$SANDBOX/b1-edited"
  cp "$SANDBOX/b1-edited" "$selected"
  chmod 600 "$selected"
  before="$(b1_published_state)"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [ "$(b1_published_state)" = "$before" ]
  cp "$SANDBOX/b1-clean-settings" "$selected"
  jq '.env.TRELLIS_RENDER_GENERATION="project-owned-value"' "$selected" > "$SANDBOX/b1-collision"
  cp "$SANDBOX/b1-collision" "$selected"
  chmod 600 "$selected"
  before="$(b1_published_state)"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [ "$(b1_published_state)" = "$before" ]
  cp "$SANDBOX/b1-clean-settings" "$selected"
  jq '.hooks.WorktreeCreate=[{hooks:[{type:"command",command:"project-new-event"}]}]' "$selected" > "$SANDBOX/b1-event-collision"
  cp "$SANDBOX/b1-event-collision" "$selected"
  chmod 600 "$selected"
  before="$(b1_published_state)"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *"project key collision"* ]] || { echo "$output"; return 1; }
  [ "$(b1_published_state)" = "$before" ]
}

@test "B1 T66 same-version native user rollout refreshes stale arrays then relink is inode-idempotent" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" attach --user --home "$TRELLIS_HOME_FIX" --release 1.4.0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local settings="$HOME/.claude/settings.json" user_owner="$TRELLIS_HOME_FIX/attachments/user.json" before owner_inode settings_inode
  jq '.hooks.WorktreeCreate[0].hooks += [{type:"command",command:"project-user-hook"}] | .project_user = true' "$settings" > "$SANDBOX/b1-user-appended"
  cp "$SANDBOX/b1-user-appended" "$settings"
  chmod 600 "$settings"
  before="$(shasum -a 256 "$settings")"
  # The non-native same-version branch remains the original no-write path.
  owner_inode="$(directory_inode "$user_owner")"
  settings_inode="$(directory_inode "$settings")"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" relink --user --home "$TRELLIS_HOME_FIX" --release 1.4.0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(shasum -a 256 "$settings")" = "$before" ]
  [ "$(directory_inode "$user_owner"):$(directory_inode "$settings")" = "$owner_inode:$settings_inode" ]
  # Model an old publisher's same-version metadata with legacy rendered arrays.
  jq '.release="1.5.0"' "$user_owner" > "$SANDBOX/b1-stale-native-user"
  cp "$SANDBOX/b1-stale-native-user" "$user_owner"
  chmod 600 "$user_owner"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$HOME/.local/bin/trellis" relink --user --home "$TRELLIS_HOME_FIX" --release 1.5.0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  jq -e '.project_user == true and (.hooks.WorktreeCreate[0].hooks[0].command | contains("/bin/native/")) and [.hooks.WorktreeCreate[1].hooks[].command] == ["project-user-hook"] and (has("workflowSizeGuideline") | not)' "$settings" >/dev/null
  before="$(shasum -a 256 "$settings" "$user_owner")"
  owner_inode="$(directory_inode "$user_owner")"
  settings_inode="$(directory_inode "$settings")"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$HOME/.local/bin/trellis" relink --user --home "$TRELLIS_HOME_FIX" --release 1.5.0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(shasum -a 256 "$settings" "$user_owner")" = "$before" ]
  [ "$(directory_inode "$user_owner"):$(directory_inode "$settings")" = "$owner_inode:$settings_inode" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$HOME/.local/bin/trellis" detach --user --home "$TRELLIS_HOME_FIX"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  jq -e '.project_user == true and [.hooks.WorktreeCreate[].hooks[].command] == ["project-user-hook"]' "$settings" >/dev/null
}

@test "B1 T66 native settings rollout uses the durable migration path for Claude and Codex" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  # Model a legacy one-command adoption: coherent new release bindings with
  # old owned arrays. The exact legacy first-hop command has its own oracle.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local owner settings path old_render
  owner="$B1_OWNER"
  for path in .claude/settings.local.json .codex/hooks.json; do
    old_render="$(jq -c --arg path "$path" '.renders[] | select(.path == $path)' "$SANDBOX/b1-old-owner.json")"
    settings="$B1_ROOT/$path"
    printf '%s\n' "$old_render" | jq -r '.after_base64 | @base64d' | jq '.hooks.PreToolUse[0].hooks += [{type:"command",command:"project-rollout-hook"}]' > "$settings"
  done
  jq --slurpfile old "$SANDBOX/b1-old-owner.json" '.renders=$old[0].renders | .artifacts |= map(.path as $path | [$old[0].artifacts[] | select(.path == $path and .kind == "file")] as $old_artifact | if ($old_artifact | length) == 1 then .sha256=$old_artifact[0].sha256 else . end)' "$owner" > "$SANDBOX/b1-old-shape-owner"
  cp "$SANDBOX/b1-old-shape-owner" "$owner"
  chmod 600 "$owner"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$HOME/.local/bin/trellis" release adopt 1.5.0 --fleet personal --project b1-owned-arrays
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for settings in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
    jq -e '(.hooks.PreToolUse[0].hooks[0].command | contains("/bin/native/")) and [.hooks.PreToolUse[1].hooks[].command] == ["project-rollout-hook"]' "$settings" >/dev/null
  done
  strict_attachment_check "$B1_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
@test "B1 T66 strict health rejects forged owned values preserved prefixes modes and created paths" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  strict_attachment_check "$B1_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local corruption settings="$B1_ROOT/.claude/settings.local.json"
  cp "$B1_OWNER" "$SANDBOX/b1-health-owner"
  cp "$settings" "$SANDBOX/b1-health-settings"
  for corruption in value prefix mode created hash; do
    cp "$SANDBOX/b1-health-owner" "$B1_OWNER"
    cp "$SANDBOX/b1-health-settings" "$settings"
    chmod 600 "$B1_OWNER" "$settings"
    python3 -I - "$B1_OWNER" "$settings" "$corruption" <<'PY'
import base64,hashlib,json,pathlib,sys
owner,settings=map(pathlib.Path,sys.argv[1:3]); mutation=sys.argv[3]
data=json.loads(owner.read_text()); path='.claude/settings.local.json'
r=next(r for r in data['renders'] if r['path']==path)
a=next(a for a in data['artifacts'] if a['path']==path)
def encode(v): return (json.dumps(v,sort_keys=True,indent=2)+'\n').encode()
if mutation=='value':
    # A coherent local forgery: live values, owner values, after snapshot and
    # artifact hash all agree, but not with the immutable source renderer.
    live=json.loads(settings.read_text()); live['hooks']['PreToolUse'][0]['hooks'][0]['command']='forged-allow'
    key=next(k for k in r['owned_keys'] if k['path']==['hooks','PreToolUse'])
    key['value'][0]['hooks'][0]['command']='forged-allow'
    raw=encode(live); settings.write_bytes(raw)
    r['after_base64']=base64.b64encode(raw).decode(); r['after_sha256']=a['sha256']=hashlib.sha256(raw).hexdigest()
elif mutation=='prefix':
    before=json.loads(base64.b64decode(r['before_base64']))
    assert before['hooks']['PreToolUse'][0]['hooks'][0]['command']=='project-owned-hook'
    before['hooks']['PreToolUse'][0]['hooks'][0]['command']='altered-preserved-hook'
    raw=encode(before); r['before_base64']=base64.b64encode(raw).decode(); r['before_sha256']=hashlib.sha256(raw).hexdigest()
elif mutation=='mode':
    settings.chmod(0o644); r['mode']=r['after_mode']=a['mode']='0644'
elif mutation=='created':
    r['created_paths']=[]
elif mutation=='hash':
    r['after_sha256']=a['sha256']='0'*64
owner.write_bytes(encode(data))
PY
    strict_attachment_check "$B1_ROOT"
    [ "$status" -ne 0 ] || { echo "strict health accepted $corruption forgery: $output"; return 1; }
  done
}
# Test-only barriers live in a normally committed, verified bootstrap payload,
# not in production fault switches and never in an installed immutable payload.
b1_crash_bootstrap() {
  local repo
  repo="$(build_release_repo 0.0.1 untagged 0.0.1 bootstrap-fixture)" || return 1
  printf 'b1_barrier=%q\n' "$SANDBOX/b1-crash" >> "$repo/scripts/lib/release-test-fixture.sh"
  python3 -I - "$repo/scripts/lib/release-test-fixture.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
p.write_text(p.read_text()+r'''
b1_pause() {
  [ -f "$b1_barrier/phase" ] || return 0
  [ "$(cat "$b1_barrier/phase")" = "$1" ] || return 0
  printf '%s\n' "$b1_group_pid" > "$b1_barrier/group.pid"
  printf '%s\n' "$(release_fixture_self_pid)" > "$b1_barrier/self.pid"
  release_fixture_wait "$b1_barrier" paused
}
eval "$(declare -f preflight_target | /usr/bin/sed '1s/^preflight_target /b1_original_preflight /')"
preflight_target() {
  b1_group_pid="$(release_fixture_self_pid)"
  b1_original_preflight "$@"
}
eval "$(declare -f adoption_publish_render | /usr/bin/sed '1s/^adoption_publish_render /b1_original_render /')"
adoption_publish_render() {
  b1_original_render "$@" || return "$?"
  [ "$2" = forward ] || return 0
  case "$(printf '%s\n' "$1" | jq -r '.destination')" in
    */.claude/settings.local.json) b1_pause claude ;;
    */.codex/hooks.json) b1_pause codex ;;
  esac
}
eval "$(declare -f release_store_adopt_runtime_anchor_pinned | /usr/bin/sed '1s/^release_store_adopt_runtime_anchor_pinned /b1_original_anchor /')"
release_store_adopt_runtime_anchor_pinned() {
  b1_original_anchor "$@" || return "$?"
  [ "$1" != 1.5.0 ] || b1_pause anchor
}
eval "$(declare -f replace_owned_file | /usr/bin/sed '1s/^replace_owned_file /b1_original_owner /')"
replace_owned_file() {
  b1_original_owner "$@" || return "$?"
  case "$1" in */state/attachments/*/*.json) b1_pause owner ;; esac
}
eval "$(declare -f release_store_rename_swap | /usr/bin/sed '1s/^release_store_rename_swap /b1_original_swap /')"
release_store_rename_swap() {
  b1_original_swap "$@" || return "$?"
  case "$2" in "$TRELLIS_HOME"/state/git-hooks/*) b1_pause hooks ;; esac
}
eval "$(declare -f _attachment_hooks_digest_memo_write | /usr/bin/sed '1s/^_attachment_hooks_digest_memo_write /b1_original_memo /')"
_attachment_hooks_digest_memo_write() {
  b1_original_memo "$@" || return "$?"
  b1_pause memo
}
eval "$(declare -f update_group_registry | /usr/bin/sed '1s/^update_group_registry /b1_original_registry /')"
update_group_registry() {
  b1_original_registry "$@" || return "$?"
  b1_pause registry
}
eval "$(declare -f recover_adoptions | /usr/bin/sed '1s/^recover_adoptions /b1_original_recover /')"
recover_adoptions() {
  b1_original_recover "$@" || return "$?"
  [ ! -f "$b1_barrier/recover-only" ] || exit 0
}
''')
PY
  git -C "$repo" add -A
  git -C "$repo" commit -qm 'isolated native publication crash barriers'
  git -C "$repo" tag -a v0.0.1 -m 'bootstrap crash fixture'
  install_release 0.0.1 "$repo"
  B1_CRASH_RELEASE="$RELEASE_DIR/payload/scripts/release.sh"
}

@test "B1 T66 singleton crash at every native publication boundary recovers selected generation atomically" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  b1_crash_bootstrap
  local phase before pid group self checkout
  before="$(b1_published_state)"
  checkout="$(jq -er '.checkout_id' "$B1_OWNER")"
  mkdir -m 700 "$SANDBOX/b1-crash"
  for phase in claude codex anchor owner hooks memo registry; do
    printf '%s\n' "$phase" > "$SANDBOX/b1-crash/phase"
    env TRELLIS_HOME="$TRELLIS_HOME_FIX" TRELLIS_VERIFIED_RELEASE_VERSION=0.0.1 \
      TRELLIS_VERIFIED_PAYLOAD="$TRELLIS_HOME_FIX/releases/0.0.1/payload" \
      bash "$B1_CRASH_RELEASE" adopt 1.5.0 --project b1-owned-arrays > "$SANDBOX/b1-$phase.log" 2>&1 &
    pid=$!; RELEASE_PROCESS_PID_A="$pid"
    wait_for_release_barrier "$SANDBOX/b1-crash/paused.ready" "$pid" "$SANDBOX/b1-$phase.log" || {
      echo "failed boundary $phase"; tail -120 "$SANDBOX/b1-$phase.log"; return 1;
    }
    [ -f "$TRELLIS_HOME_FIX/state/release-adoptions/$checkout/ready" ]
    group="$(cat "$SANDBOX/b1-crash/group.pid")"; self="$(cat "$SANDBOX/b1-crash/self.pid")"
    kill -KILL "$group"
    [ "$self" = "$group" ] || kill -KILL "$self"
    wait_for_release_process "$pid"
    [ "$RELEASE_PROCESS_STATUS" -ne 0 ]
    # Recovery is a real command through the verified bootstrap body, stopped
    # by a fixture wrapper only after normal recovery, before a new adoption.
    rm "${SANDBOX:?}/b1-crash/phase" "${SANDBOX:?}/b1-crash/paused.ready"
    : > "$SANDBOX/b1-crash/recover-only"
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" TRELLIS_VERIFIED_RELEASE_VERSION=0.0.1 \
      TRELLIS_VERIFIED_PAYLOAD="$TRELLIS_HOME_FIX/releases/0.0.1/payload" \
      bash "$B1_CRASH_RELEASE" adopt 1.5.0 --project b1-owned-arrays
    [ "$status" -eq 0 ] || { echo "$phase recovery: $output"; return 1; }
    if [ "$phase" = registry ]; then
      [ "$(registry_release_for_root "$B1_ROOT")" = 1.5.0 ]
      strict_attachment_check "$B1_ROOT"
      [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    else
      [ "$(b1_published_state)" = "$before" ] || { echo "$phase rollback changed selected bytes"; return 1; }
    fi
    [ ! -e "$TRELLIS_HOME_FIX/state/release-adoptions/$checkout" ]
    rm "${SANDBOX:?}/b1-crash/recover-only"
  done
}
@test "B1 T66 actual immutable 1.4.0 one-command upgrade retains legacy enforcement without a companion" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  local old="$SANDBOX/b1-historical-source" candidate="$SANDBOX/b1-full-candidate"
  local launcher="$HOME/.local/bin/trellis" project="$SANDBOX/b1-actual-old-project" path harness events
  mkdir -p "$old" "$candidate"
  git -C "$REPO_ROOT" archive v1.4.0 -- scripts core-rules trellis.config.json | tar -x -C "$old"
  git -C "$REPO_ROOT" archive HEAD -- scripts core-rules trellis.config.json | tar -x -C "$candidate"
  for path in "$old" "$candidate"; do
    git -C "$path" init -q -b main
    git -C "$path" config user.email release-adoption@example.invalid
    git -C "$path" config user.name 'Release Adoption'
  done
  git -C "$old" add -A
  git -C "$old" commit -qm 'immutable historical v1.4.0 source'
  git -C "$old" tag -a v1.4.0 -m 'historical v1.4.0 fixture'
  printf '1.5.0\n' > "$candidate/core-rules/VERSION"
  git -C "$REPO_ROOT" show v1.5.2:core-rules/inheritance-manifest.json > "$candidate/core-rules/inheritance-manifest.json"
  rm -f "$candidate/core-rules/CLAUDE.md"
  cp "$candidate/core-rules/AGENTS.md" "$candidate/core-rules/CLAUDE.md"
  # Production templates remain legacy until T34. This complete isolated
  # payload has native candidate arrays but retains every old guard worker.
  for path in claude-settings.local.json codex-hooks.local.json claude-user-settings.json; do
    harness=claude; [ "$path" != codex-hooks.local.json ] || harness=codex
    events='["PreToolUse","PostToolUse","UserPromptSubmit","SessionStart","Stop"]'
    [ "$path" != claude-user-settings.json ] || events='["WorktreeCreate","WorktreeRemove"]'
    jq -n --arg harness "$harness" --argjson events "$events" '{hooks:($events | map(. as $event | {key:$event,value:[{hooks:[({type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event",$harness,$event],timeout:30} + (if $harness == "claude" then {onFailure:"block"} else {} end))]}]}) | from_entries)}' > "$candidate/core-rules/templates/$path"
  done
  git -C "$candidate" add -f -A
  git -C "$candidate" commit -qm 'complete isolated native candidate payload'
  git -C "$candidate" tag -a v1.5.0 -m 'native candidate fixture'
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1/scripts/lib/release-store.sh"; release_store_install 1.4.0 "$1"' _ "$old"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cp "$old/scripts/trellis-launcher.sh" "$launcher"
  chmod 755 "$launcher"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$old/scripts/configure.sh" --source "$candidate" --release 1.4.0 --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  make_portable_project "$project" b1-actual-old-project
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$launcher" attach --home "$TRELLIS_HOME_FIX" --fleet personal --release 1.4.0 "$project"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cp "$launcher" "$SANDBOX/b1-actual-old-launcher"
  jq -S .hooks "$project/.claude/settings.local.json" > "$SANDBOX/b1-claude-legacy-hooks"
  jq -S .hooks "$project/.codex/hooks.json" > "$SANDBOX/b1-codex-legacy-hooks"
  mkdir -p "$SANDBOX/b1-hostile-bin"
  printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$SANDBOX/b1-planted-ran" > "$SANDBOX/b1-hostile-bin/trellis-hooks"
  chmod 755 "$SANDBOX/b1-hostile-bin/trellis-hooks"
  cp "$SANDBOX/b1-hostile-bin/trellis-hooks" "$project/trellis-hooks"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" PATH="$SANDBOX/b1-hostile-bin:$PATH" \
    "$launcher" upgrade 1.5.0 --remote "$candidate" --project b1-actual-old-project
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cmp -s "$launcher" "$SANDBOX/b1-actual-old-launcher"
  [ ! -e "$TRELLIS_HOME_FIX/bin/native" ]
  [ "$(registry_release_for_root "$project")" = 1.5.0 ]
  jq -S .hooks "$project/.claude/settings.local.json" > "$SANDBOX/b1-claude-after-hooks"
  jq -S .hooks "$project/.codex/hooks.json" > "$SANDBOX/b1-codex-after-hooks"
  cmp -s "$SANDBOX/b1-claude-legacy-hooks" "$SANDBOX/b1-claude-after-hooks"
  cmp -s "$SANDBOX/b1-codex-legacy-hooks" "$SANDBOX/b1-codex-after-hooks"
  for path in "$project/.claude/settings.local.json" "$project/.codex/hooks.json"; do
    jq -e '[.hooks.PreToolUse[].hooks[] | .command] | length > 0 and all(.[]; contains("/bin/native/") | not)' "$path" >/dev/null
    ! grep -F __TRELLIS_LAUNCHER__ "$path"
  done
  run python3 -I - "$project" <<'PY'
import json,os,pathlib,subprocess,sys
root=sys.argv[1]; settings=json.loads((pathlib.Path(root)/'.claude/settings.local.json').read_text())
hook=next(b for b in settings['hooks']['PreToolUse'] if b.get('matcher')=='Bash')['hooks'][0]
env=dict(os.environ,CLAUDE_PROJECT_DIR=root)
if 'args' in hook:
    argv=[s.replace('${CLAUDE_PROJECT_DIR}',root) for s in [hook['command']]+hook['args']]
else:
    argv=['/bin/bash','-c',hook['command']]
p=subprocess.run(argv,cwd=root,env=env,input=json.dumps({'tool_name':'Bash','tool_input':{'command':'rm -rf /'}}),text=True,capture_output=True)
print(p.stdout); print(p.stderr,file=sys.stderr)
assert p.returncode in (0,2), p.returncode
assert json.loads(p.stdout)['hookSpecificOutput']['permissionDecision']=='deny'
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$SANDBOX/b1-planted-ran" ]
  # Retained old-code downgrade with project-appended array members is not
  # qualified: the immutable old reader predates prefix ownership semantics.
}
@test "B1 review repeated real native upgrades preserve edited residuals and mixed-fleet health" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local sibling="$SANDBOX/b1-mixed-sibling" settings version repo residual=project-owned-hook
  make_portable_project "$sibling" b1-mixed-sibling
  attach_portable_project "$sibling" personal 1.5.0
  for version in 1.5.1 1.6.0-rc.2; do
    for settings in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
      jq --arg version "$version" --arg residual "$residual" '.unrelated_edit=$version | .hooks.PreToolUse = [.hooks.PreToolUse[0],{hooks:[{type:"command",command:$residual}]}]' "$settings" > "$SANDBOX/edited-generation"
      cp "$SANDBOX/edited-generation" "$settings"
      chmod 600 "$settings"
    done
    repo="$(b1_migration_release "$version" true)"
    # Real verified upgrade bundle, real installation/publication/adoption under
    # the config lock, not stubs. The untouched sibling stays on native1.5.0.
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$HOME/.local/bin/trellis" upgrade "$version" --remote "$repo" --project b1-owned-arrays
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -Fx "launcher_native_version='$version'" "$HOME/.local/bin/trellis"
    for settings in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
      jq -e --arg residual "$residual" --arg version "$version" '.unrelated_edit==$version and .project.keep==true and [.hooks.PreToolUse[1].hooks[].command]==[$residual]' "$settings" >/dev/null
    done
    strict_attachment_check "$B1_ROOT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    strict_attachment_check "$sibling"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(registry_release_for_root "$sibling")" = 1.5.0 ]
    residual=project-replacement-R2
  done
  for settings in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
    jq '.final_edit=true' "$settings" > "$SANDBOX/final-edited"
    cp "$SANDBOX/final-edited" "$settings"
  done
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$HOME/.local/bin/trellis" detach --home "$TRELLIS_HOME_FIX" "$B1_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for settings in "$B1_ROOT/.claude/settings.local.json" "$B1_ROOT/.codex/hooks.json"; do
    jq -e '.final_edit==true and [.hooks.PreToolUse[].hooks[].command]==["project-replacement-R2"]' "$settings" >/dev/null
  done
}

@test "B1 review SIGKILL after pair publication leaves old native policy render and strict health coherent" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local repo new_payload pid
  repo="$(b1_migration_release 1.5.1 true)"
  install_release 1.5.1 "$repo"
  new_payload="$RELEASE_DIR/payload"
  # Fixture coordinator pauses immediately after real configure has durably
  # published the pair, before any project adoption. SIGKILL cannot run a
  # rollback trap, reproducing the interrupted management-repin state.
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    bash "$1/scripts/configure.sh" --source "$2" --release 1.5.1 --launcher-template "$3/scripts/trellis-launcher.sh" || exit "$?"
    : > "$4"
    while :; do sleep 0.1; done
  ' _ "$REPO_ROOT" "$repo" "$new_payload" "$SANDBOX/pair-published.ready" > "$SANDBOX/pair-crash.log" 2>&1 &
  pid=$!; RELEASE_PROCESS_PID_A="$pid"
  wait_for_release_barrier "$SANDBOX/pair-published.ready" "$pid" "$SANDBOX/pair-crash.log"
  kill -KILL "$pid"
  wait_for_release_process "$pid"
  [ "$RELEASE_PROCESS_STATUS" -ne 0 ]
  grep -Fx "launcher_native_version='1.5.1'" "$HOME/.local/bin/trellis"
  [ "$(registry_release_for_root "$B1_ROOT")" = 1.5.0 ]
  strict_attachment_check "$B1_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
@test "B1 review M1 reconstruction disagreement names settings and recovery without publishing" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin native candidate fixture'
  b1_setup_migration
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 -I - "$B1_OWNER" <<'PY'
import base64,hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads(p.read_text());r=next(r for r in d['renders'] if r['path']=='.claude/settings.local.json')
before=json.loads(base64.b64decode(r['before_base64']));before['hooks']['PreToolUse'][0]['hooks'][0]['command']='inconsistent-snapshot-R'
raw=(json.dumps(before,sort_keys=True,indent=2)+'\n').encode();r['before_base64']=base64.b64encode(raw).decode();r['before_sha256']=hashlib.sha256(raw).hexdigest();p.write_text(json.dumps(d,sort_keys=True,indent=2)+'\n')
PY
  local before
  before="$(b1_published_state)"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.5.0 --project b1-owned-arrays
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [[ "$output" == *"native render before-image reconstruction disagrees at .claude/settings.local.json"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"preserve settings and owner evidence"* ]] || false
  [ "$(b1_published_state)" = "$before" ]
}
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
