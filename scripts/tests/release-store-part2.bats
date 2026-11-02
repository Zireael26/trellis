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

@test "Pi adoption permits missing new leaves and treats hooks-other as outside the hooks tree" {
  local version_a=1.10.2 version_b=1.10.3 version_c=1.10.4 repo manifest project non_pi payload_b payload_c
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
  non_pi="$SANDBOX/non-pi-forward"
  make_portable_project "$non_pi" non-pi-forward
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release "$version_a" --harness claude "$non_pi"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attachment_statuses 2

  # A retained hook inventory permits forward adoption with a new missing hook.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project pi-forward-leaves
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ -L "$project/.pi/hooks/dispatch.sh" ]
  [ ! -e "$project/.pi/hooks/added.sh" ]
  [ ! -L "$project/.pi/hooks/added.sh" ]
  # A manifest's Pi hooks do not constrain an attachment without Pi selected.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_b" --project non-pi-forward
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$non_pi/.trellis/runtime")" = "$payload_b" ]
  [ ! -e "$non_pi/.pi" ]
  [ ! -L "$non_pi/.pi" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$version_c" --project pi-forward-leaves
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_c" ]
  [ ! -e "$project/.pi/hooks" ]
  [ ! -L "$project/.pi/hooks" ]
  [ ! -e "$project/.pi/hooks-other/dispatch.sh" ]
  [ ! -L "$project/.pi/hooks-other/dispatch.sh" ]
  [ ! -e "$project/.pi/extensions/added.md" ]
  [ ! -L "$project/.pi/extensions/added.md" ]
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
