#!/usr/bin/env bats
# Released shim compatibility through the real attachment and upgrade routes.
load release-store-common

setup() {
  export TRELLIS_ATTACH_POSTJOB=off RELEASE_FIXTURE_UPGRADE=true
  GROUP_PLAN_CASE_LOCK_HELD=false
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  initialize_release_store_machine
}

write_base_shims() {
  local name
  for name in $hook_names; do
    bash -c '
      . "$1/scripts/lib/attachment.sh"
      . "$1/scripts/tests/fixtures/released-hook-shims/v142-generator.sh"
      _attachment_hooks_passthrough_shim_body "$2"
    ' _ "$REPO_ROOT" "$name" > "$managed/$name" || return 1
    chmod 700 "$managed/$name" || return 1
  done
}

assert_current_shims() {
  local name
  for name in $hook_names; do
    bash -c '
      . "$1/scripts/lib/attachment.sh"
      body=$(_attachment_hooks_passthrough_shim_body "$3") || exit 1
      _attachment_hooks_file_matches "$2/$3" "$body" 700
    ' _ "$REPO_ROOT" "$managed" "$name" || { echo "not upgraded: $name"; return 1; }
  done
}

assert_strict() {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    . "$1/scripts/attach-project.sh"
    _attachment_hooks_state_owned_matches_data "$2" "$(< "$3")"
  ' _ "$REPO_ROOT" "$TRELLIS_HOME_FIX" "$owner"
  [ "$status" -eq 0 ] || { echo "strict verification: $output"; false; }
}

@test "attach and relink do not create a previous hooks directory when none was configured" {
  repo="$(build_release_repo 1.6.0)"
  install_release 1.6.0 "$repo"
  project="$SANDBOX/no-previous-hooks"
  make_portable_project "$project" no-previous-hooks
  [ ! -e "$project/.husky" ] && [ ! -e "$project/.githooks" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release 1.6.0 "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(owner_for_root "$project")"
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = null ]
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ -f "$managed/previous-hooks-path" ]
  [ "$(wc -l < "$managed/previous-hooks-path" | tr -d '[:space:]')" -eq 1 ]
  [ -z "$(< "$managed/previous-hooks-path")" ]
  [ ! -e "$project/.husky" ] && [ ! -e "$project/.githooks" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" relink --home "$TRELLIS_HOME_FIX" "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = null ]
  [ -z "$(< "$managed/previous-hooks-path")" ]
  [ ! -e "$project/.husky" ] && [ ! -e "$project/.githooks" ]

  # A configured empty directory is operator-owned, not one Trellis created.
  project="$SANDBOX/empty-previous-hooks"
  make_portable_project "$project" empty-previous-hooks
  mkdir "$project/.custom-hooks"
  git -C "$project" config --local core.hooksPath .custom-hooks
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release 1.6.0 "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(owner_for_root "$project")"
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = .custom-hooks ]
  [ -d "$project/.custom-hooks" ] && [ -z "$(ls -A "$project/.custom-hooks")" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" relink --home "$TRELLIS_HOME_FIX" "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$project/.custom-hooks" ] && [ -z "$(ls -A "$project/.custom-hooks")" ]
}

@test "base husky, custom hooksPath and all husky 9 shims verify, relink, upgrade and detach" {
  ADOPTION_VERSION_A=1.6.0
  repo="$(build_release_repo "$ADOPTION_VERSION_A")"
  install_release "$ADOPTION_VERSION_A" "$repo"
  jq -n --arg source "$SANDBOX/repo-0.0.0" --arg root "$SANDBOX" '{
    schema_version:1, source_root:$source, release_remote:"fixture://bootstrap",
    active_cli_release:"0.0.0", default_fleet:"personal",
    fleets:{personal:{discovery_roots:[$root]}}}' > "$TRELLIS_HOME_FIX/config.json"
  chmod 600 "$TRELLIS_HOME_FIX/config.json"

  for layout in husky custom husky9; do
    project="$SANDBOX/project-$layout"
    project_id="project-$layout"
    make_portable_project "$project" "$project_id"
    hook_names='pre-commit commit-msg'
    case "$layout" in
      husky) prior=.husky; ADOPTION_VERSION_B=1.6.1 ;;
      custom) prior=.custom-hooks; ADOPTION_VERSION_B=1.6.2 ;;
      husky9)
        prior=.husky/_
        ADOPTION_VERSION_B=1.6.3
        hook_names='applypatch-msg commit-msg post-applypatch post-commit post-merge post-rewrite pre-applypatch pre-auto-gc pre-commit pre-merge-commit pre-rebase prepare-commit-msg'
        ;;
    esac
    mkdir -p "$project/$prior"
    for name in $hook_names; do
      printf '#!/bin/sh\nexit 0\n' > "$project/$prior/$name"
      chmod 700 "$project/$prior/$name"
    done
    git -C "$project" config --local core.hooksPath "$prior"
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
      attach --home "$TRELLIS_HOME_FIX" --fleet personal --release "$ADOPTION_VERSION_A" "$project"
    [ "$status" -eq 0 ] || { echo "$layout attach exit $status: $output"; false; }
    owner="$(owner_for_root "$project")"
    managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"

    write_base_shims
    assert_strict
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" relink --home "$TRELLIS_HOME_FIX" "$project"
    [ "$status" -eq 0 ] || { echo "$layout relink: $output"; false; }
    assert_current_shims

    write_base_shims
    assert_strict
    repo="$(build_release_repo "$ADOPTION_VERSION_B")"
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$OPERATOR_HOME/.local/bin/trellis" \
      upgrade "$ADOPTION_VERSION_B" --remote "$SANDBOX/repo-$ADOPTION_VERSION_B" --project "$project_id"
    [ "$status" -eq 0 ] || { echo "$layout upgrade: $output"; false; }
    assert_current_shims
    [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_B" ]

    write_base_shims
    assert_strict
    printf '# altered\n' >> "$managed/pre-commit"
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" detach --home "$TRELLIS_HOME_FIX" "$project"
    [ "$status" -ne 0 ] || { echo 'modified shim was detached'; false; }
    grep -Fx '# altered' "$managed/pre-commit"
    write_base_shims
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" detach --home "$TRELLIS_HOME_FIX" "$project"
    [ "$status" -eq 0 ] || { echo "$layout detach: $output"; false; }
    [ ! -e "$managed" ]
    [ "$(git -C "$project" config --local core.hooksPath)" = "$prior" ]
  done
}
