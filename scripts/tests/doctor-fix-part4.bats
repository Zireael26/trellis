#!/usr/bin/env bats
# Split from doctor-fix.bats: part 4 of 4.
load doctor-fix-common

@test "A4.4 (i): the restore helper unsets a null prior instead of writing an empty value" {
  local repo="$SANDBOX/restore-repo"
  git init -q "$repo"
  git -C "$repo" config --local core.hooksPath /managed/path
  run bash -c '. "$1/scripts/lib/health-checks.sh" && hc_hooks_path_restore "$2" "" false' _ "$REPO_ROOT" "$repo"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run git -C "$repo" config --local --get-all core.hooksPath
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # A prior value is restored exactly.
  run bash -c '. "$1/scripts/lib/health-checks.sh" && hc_hooks_path_restore "$2" ".husky/_" true' _ "$REPO_ROOT" "$repo"
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" config --local --get-all core.hooksPath)" = ".husky/_" ]
}

@test "A4.4 (c'): --adopt-husky on a husky 9 layout records .husky/_, shims every passthrough name, and repairs" {
  local name
  adopt_husky_fixture
  run_portable_doctor_fix --fix --adopt-husky
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"husky adopted in"*"12 passthrough shim(s) created"* ]] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath repaired in"*": .husky/_ -> "* ]] || { echo "$output"; false; }
  assert_adopted
  for name in $ADOPT_PASSTHROUGH; do
    [ "$(fixture_mode "$HF_MANAGED/$name")" = 700 ]
    cmp -s <(recorded_shim_body "$name") "$HF_MANAGED/$name" || { echo "shim $name differs from the recorded generator"; false; }
  done
  # No shim for a Trellis-owned name: those two stay the managed dispatchers.
  ! grep -q 'trellis-managed-passthrough' "$HF_MANAGED/pre-push"
  ! grep -q 'trellis-managed-passthrough' "$HF_MANAGED/post-checkout"
  [ "$(find "$HF_MANAGED" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq $((12 + 5)) ]
  # husky's pre-commit still runs through the managed dir.
  ( cd "$PORTABLE_PROJECT" && env HOME="$PORTABLE_ACCOUNT_HOME" "$HF_MANAGED/pre-commit" </dev/null )
  [ "$(cat "$SANDBOX/husky-pre-commit-ran")" = ran ]
}

@test "A4.4 (c's)(1): --adopt-husky refuses the enabled record and a linked record naming two releases" {
  local before config_before
  adopt_husky_fixture sibling
  jq -cS '.release = "1.2.4"' "$HF_SIBLING_OWNER" > "$SANDBOX/sibling.json"
  cat "$SANDBOX/sibling.json" > "$HF_SIBLING_OWNER"
  HF_SIBLING_SUM="$(shasum -a 256 < "$HF_SIBLING_OWNER")"
  before="$(adopt_snapshot)"; config_before="$(config_digest)"
  run_portable_doctor_fix --fix --adopt-husky
  assert_refused_unchanged "$config_before" 'trellis release adopt so every worktree of this checkout records one release'
  [[ "$output" == *"name more than one release"* ]] || { echo "$output"; false; }
  [ "$(adopt_snapshot)" = "$before" ]
}

@test "A4.4 (c's)(2): --adopt-husky refuses a missing recorded payload before any write" {
  local before config_before
  adopt_husky_fixture
  before="$(adopt_snapshot)"; config_before="$(config_digest)"
  # Renaming a directory needs write access to it as well as to its parent.
  chmod u+w "$PORTABLE_HOME/releases/1.2.3" "$PORTABLE_HOME/releases/1.2.3/payload"
  mv "$PORTABLE_HOME/releases/1.2.3/payload" "$SANDBOX/payload-aside"
  run_portable_doctor_fix --fix --adopt-husky
  assert_refused_unchanged "$config_before" 'trellis release install 1.2.3'
  [[ "$output" == *"the recorded release 1.2.3 payload is missing or its manifest does not verify"* ]] || { echo "$output"; false; }
  [ "$(adopt_snapshot)" = "$before" ]
}

@test "A4.4 (c's)(3): --adopt-husky refuses a passthrough-named file, symlink or directory in the managed dir" {
  local before config_before kind
  adopt_husky_fixture
  config_before="$(config_digest)"
  for kind in file symlink directory; do
    case "$kind" in
      file) printf 'foreign\n' > "$HF_MANAGED/pre-commit" ;;
      symlink) ln -s /dev/null "$HF_MANAGED/pre-commit" ;;
      directory) mkdir "$HF_MANAGED/pre-commit" ;;
    esac
    before="$(adopt_snapshot)"
    run_portable_doctor_fix --fix --adopt-husky
    assert_refused_unchanged "$config_before" 'inspect them; Trellis will not overwrite an entry it did not create'
    [[ "$output" == *"already holds passthrough-named entries: pre-commit"* ]] || { echo "$kind: $output"; false; }
    [ "$(adopt_snapshot)" = "$before" ] || { echo "$kind changed the set"; false; }
    mv "$HF_MANAGED/pre-commit" "$SANDBOX/aside-$kind"
  done
}

@test "A4.4 (c's)(4): --adopt-husky refuses when the active CLI release differs from the recorded one" {
  local before config_before
  adopt_husky_fixture
  # The seam: the machine config's active_cli_release selects the active CLI release.
  jq -c '.active_cli_release = "1.2.4"' "$PORTABLE_HOME/config.json" > "$SANDBOX/config.json"
  cat "$SANDBOX/config.json" > "$PORTABLE_HOME/config.json"
  before="$(adopt_snapshot)"; config_before="$(config_digest)"
  run_portable_doctor_fix --fix --adopt-husky
  assert_refused_unchanged "$config_before" 'trellis configure --release 1.2.3, or detach and attach'
  [[ "$output" == *"the active CLI release 1.2.4 differs from the recorded release 1.2.3"* ]] || { echo "$output"; false; }
  [ "$(adopt_snapshot)" = "$before" ]
}

@test "A4.4 (c''): a failure after the shims and records, before the sidecar, rolls the set back" {
  local before config_before
  adopt_husky_fixture
  before="$(adopt_snapshot)"; config_before="$(config_digest)"
  DOCTOR_FIX_FAULT_PHASE=adopt-husky-before-sidecar run_portable_doctor_fix --fix --adopt-husky
  assert_adopt_rolled_back "$before"
  assert_rolled_back_before_repair
  [ "$(config_digest)" = "$config_before" ]
}

@test "A4.4 (c''r): a failed R4.6 re-verification after adoption restores the config, then the set" {
  local before
  adopt_husky_fixture
  before="$(adopt_snapshot)"
  DOCTOR_FIX_FAULT_PHASE=hooks-path-reverify-fails run_portable_doctor_fix --fix --adopt-husky
  assert_adopt_rolled_back "$before"
  [[ "$output" == *"restored .husky/_"*"husky adoption rolled back"* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = ".husky/_" ]
}

@test "A4.4 (c''h): a hook name husky adds before the post-check fails it and rolls the set back" {
  local before config_before
  adopt_husky_fixture
  before="$(adopt_snapshot)"; config_before="$(config_digest)"
  DOCTOR_FIX_FAULT_PHASE=adopt-husky-new-hook run_portable_doctor_fix --fix --adopt-husky
  [ -x "$PORTABLE_PROJECT/.husky/_/sendemail-validate" ]
  assert_adopt_rolled_back "$before"
  assert_rolled_back_before_repair
  [ ! -e "$HF_MANAGED/sendemail-validate" ]
  [ "$(config_digest)" = "$config_before" ]
}

@test "A4.4 (c'''): --adopt-husky with a normally attached linked worktree writes only the enabled record and the sidecar" {
  adopt_husky_fixture sibling
  run_portable_doctor_fix --fix --adopt-husky
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"in the hooks-enabled owner record and the shared sidecar; 12 passthrough shim(s) created; 1 linked worktree record(s) unchanged"* ]] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath repaired in"* ]] || { echo "$output"; false; }
  assert_adopted
}

@test "A4.4 (c''''): as (c'''), a failure after the enabled record, before the sidecar, rolls back; the linked record never changes" {
  local before config_before
  adopt_husky_fixture sibling
  before="$(adopt_snapshot)"; config_before="$(config_digest)"
  DOCTOR_FIX_FAULT_PHASE=adopt-husky-before-sidecar run_portable_doctor_fix --fix --adopt-husky
  assert_adopt_rolled_back "$before"
  assert_rolled_back_before_repair
  [ "$(config_digest)" = "$config_before" ]
}

@test "A4.4 (c''''s): R4.6 refuses two hooks-enabled records, or none, naming the detach-all remedy" {
  local before config_before
  adopt_husky_fixture sibling
  # Two enabled records: attach never writes this, so fabricate the sibling's.
  jq -cS --argjson hooks "$(jq -c '.git_hooks' "$HF_OWNER")" '.git_hooks = $hooks' "$HF_SIBLING_OWNER" > "$SANDBOX/two.json"
  cat "$SANDBOX/two.json" > "$HF_SIBLING_OWNER"
  HF_SIBLING_SUM="$(shasum -a 256 < "$HF_SIBLING_OWNER")"
  before="$(adopt_snapshot)"; config_before="$(config_digest)"
  run_portable_doctor_fix --fix
  assert_refused_unchanged "$config_before" 'detach every worktree of the checkout, then attach the owning worktree first'
  [[ "$output" == *"more than one worktree of this checkout has Trellis git hooks enabled ("*"sibling-wt)"* ]] || { echo "$output"; false; }
  [ "$(adopt_snapshot)" = "$before" ]

  # No enabled record. Doctor repairs only through a hooks-enabled record, so
  # drive the R4.6 worktree preflight directly, as (i) drives the restore helper.
  jq -cS '.git_hooks = {"enabled":false}' "$HF_OWNER" > "$SANDBOX/none.json"
  cat "$SANDBOX/none.json" > "$HF_OWNER"
  jq -cS '.git_hooks = {"enabled":false}' "$HF_SIBLING_OWNER" > "$SANDBOX/none.json"
  cat "$SANDBOX/none.json" > "$HF_SIBLING_OWNER"
  run bash -c 'for lib in trellis-home release-store local-registry surface-plan attachment health-checks; do . "$1/scripts/lib/$lib.sh" || exit 9; done
    _hc_hooks_path_worktrees_ok "$2" "$3" "$4" "$5"' _ "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_PROJECT" "$PORTABLE_CHECKOUT_ID" "$HF_MANAGED"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"no worktree of this checkout has an owner record with Trellis git hooks enabled"*"remedy: detach every worktree of the checkout, then attach the owning worktree first"* ]] || { echo "$output"; false; }
  [ "$(config_digest)" = "$config_before" ]
}

@test "A4.4 (c''''s'): R4.6 refuses the one hooks-enabled record when it is not the exclude-owning worktree's" {
  local config_before
  adopt_husky_fixture sibling
  [ "$(jq -r '.exclude.managed_by_attachment' "$HF_SIBLING_OWNER")" = false ]
  # Move hooks-enabled to the linked worktree; the owning worktree is disabled.
  jq -cS --argjson hooks "$(jq -c '.git_hooks' "$HF_OWNER")" '.git_hooks = $hooks' "$HF_SIBLING_OWNER" > "$SANDBOX/moved.json"
  cat "$SANDBOX/moved.json" > "$HF_SIBLING_OWNER"
  jq -cS '.git_hooks = {"enabled":false}' "$HF_OWNER" > "$SANDBOX/moved.json"
  cat "$SANDBOX/moved.json" > "$HF_OWNER"
  config_before="$(config_digest)"
  run worktrees_ok
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"worktree $HF_SIBLING has Trellis git hooks enabled but its owner record is not bound to that worktree or does not own the shared exclude block"*"remedy: detach every worktree of the checkout, then attach the owning worktree first"* ]] || { echo "$output"; false; }
  [ "$(config_digest)" = "$config_before" ]
}

@test "A4.4: the R4.6 worktree preflight hashes worktree roots with sha256sum where shasum is unavailable" {
  local stub="$SANDBOX/sha-stub"
  hooks_fix_attach null
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 127\n' > "$stub/shasum"
  printf '#!/bin/sh\nexec "%s" -a 256 "$@"\n' "$(command -v shasum)" > "$stub/sha256sum"
  chmod +x "$stub/shasum" "$stub/sha256sum"
  PATH="$stub:$PATH" run worktrees_ok
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ]
}
