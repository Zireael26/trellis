#!/usr/bin/env bats
# Recovery validates only selected-checkout journals, without touching foreign evidence.
REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture

setup_file() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$BATS_FILE_TMPDIR/prototype"
  release_fixture_prototype_build "$(CDPATH= cd "$BATS_FILE_TMPDIR/prototype" && pwd -P)"
}

teardown_file() {
  [ ! -d "$BATS_FILE_TMPDIR/prototype" ] || chmod -R u+w "$BATS_FILE_TMPDIR/prototype"
}

make_project() {
  mkdir -p "$1"
  git -C "$1" -c core.hooksPath=/dev/null init -q -b main
  printf '{"schema_version":1,"project_id":"%s"}\n' "$2" > "$1/.trellis.json"
  git -C "$1" add .trellis.json
  git -C "$1" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -qm seed
}

setup() {
  ROOT="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$ROOT"
  ROOT="$(CDPATH= cd "$ROOT" && pwd -P)"
  release_fixture_prototype_clone "$BATS_FILE_TMPDIR/prototype" "$ROOT"
  export HOME="$ROOT/user" TRELLIS_HOME="$ROOT/trellis"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TRELLIS_ATTACH_POSTJOB=off
  WITNESS="$ROOT/other checkout"
  PROJECT="$ROOT/requested checkout"
  make_project "$WITNESS" witness-fixture
  make_project "$PROJECT" recover-scope
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.9.9 --harness claude "$WITNESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  source "$ATTACH"
  set +u
  IDENTITY="$(local_registry_identity_for_root "$PROJECT")"
  CHECKOUT="$(printf '%s\n' "$IDENTITY" | jq -r .checkout_id)"
  WORKTREE="$(printf '%s\n' "$IDENTITY" | jq -r .worktree_id)"
  COMMON="$(printf '%s\n' "$IDENTITY" | jq -r .git_common_dir)"
  WITNESS_IDENTITY="$(local_registry_identity_for_root "$WITNESS")"
  WITNESS_OWNER="$TRELLIS_HOME/state/attachments/$(printf '%s\n' "$WITNESS_IDENTITY" | jq -r .checkout_id)/$(printf '%s\n' "$WITNESS_IDENTITY" | jq -r .worktree_id).json"
  OWN_ID=22222222-2222-3333-4444-555555555555
  FOREIGN_ID=11111111-2222-3333-4444-555555555555
  JOURNAL_DIR="$TRELLIS_HOME/state/attachment-journals"
  OWN_JOURNAL="$JOURNAL_DIR/$OWN_ID.json"
  FOREIGN_JOURNAL="$JOURNAL_DIR/detach-$FOREIGN_ID.json"
  local_registry_register_worktree "$TRELLIS_HOME" personal recover-scope "$PROJECT" 9.9.9 '["claude"]' "$OWN_ID" '{}' >/dev/null
  jq --arg root "$PROJECT" --arg c "$CHECKOUT" --arg w "$WORKTREE" --arg common "$COMMON" --arg id "$OWN_ID" '
    .status = "prepared" | .project_id = "recover-scope"
    | .project_root = $root | .worktree_root = $root | .checkout_id = $c | .worktree_id = $w | .attachment_id = $id
    | .artifacts = [{path:"never-published",kind:"symlink",target:"old-runtime"}]
    | .renders = [] | .pre_existing = [] | .render_context = null
    | .git_hooks = {enabled:false}
    | .exclude.git_common_dir = $common | .exclude.path = ($common + "/info/exclude")
    | .exclude.managed_by_attachment = false
    | .phase = 0 | .applied = [] | .pending = null | .removal = null
  ' "$WITNESS_OWNER" > "$OWN_JOURNAL"
  chmod 600 "$OWN_JOURNAL"
  _attachment_journal_json_valid "$OWN_JOURNAL" || return 1
}

teardown() {
  [ ! -d "${ROOT:-}" ] || chmod -R u+w "$ROOT"
}

seed_foreign_detach() {
  local gone="$ROOT/vanished foreign worktree" gone_id
  gone_id="$(_attachment_hash_text "$gone")"
  jq --arg root "$gone" --arg wid "$gone_id" --arg id "$FOREIGN_ID" '
    .worktree_root = $root | .project_root = $root | .worktree_id = $wid | .attachment_id = $id
    | .artifacts = [range(0;218) | {path:("leaf-" + tostring),kind:"symlink",target:"old-runtime"}]
    | .renders = [] | .pre_existing = [] | .render_context = null
    | . as $owner
    | {schema_version:1,status:"detaching",attachment_id:$owner.attachment_id,
       checkout_id:$owner.checkout_id,worktree_id:$owner.worktree_id,original_owner:$owner,
       next_owner:null,remove:$owner.artifacts,phase:218,removal:null,owner_committed:true,
       external:{phase:0,exclude_action:"restore",transfer:null,restore_hooks:true,
                 clear_registry:true,renders:[],render_phase:0,render_pending:null,registry_update:null}}
  ' "$WITNESS_OWNER" > "$FOREIGN_JOURNAL"
  chmod 600 "$FOREIGN_JOURNAL"
  # Run outside Bats' inherited RETURN tracing: the validator owns a temporary
  # owner-data file and its local cleanup trap must not fire in nested calls.
  run bash -c '. "$1"; _attachment_detach_journal_data_valid "$2"' _ "$ATTACH" "$FOREIGN_JOURNAL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # It is a foreign missing-root journal, not a recoverable live-root transaction.
  run bash -c '. "$1"; _attachment_detach_journal_valid "$2"' _ "$ATTACH" "$FOREIGN_JOURNAL"
  [ "$status" -ne 0 ]
}

run_recover() {
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
}

assert_own_rolled_back() {
  [ ! -e "$OWN_JOURNAL" ]
  [ ! -e "$PROJECT/never-published" ]
  jq -e --arg c "$CHECKOUT" --arg w "$WORKTREE" '.projects["personal/recover-scope"].checkouts[$c].worktrees[$w] | has("attachment_id") | not' "$TRELLIS_HOME/registry.json"
}

detach_with_registry_contention() {
  run bash -c '
    . "$1"
    set +u
    if [ -n "$5" ]; then TRELLIS_LIBS_PRELOADED=1 . "$5"; fi
    original="$(declare -f attachment_detach_commit)"
    eval "${original/attachment_detach_commit/fixture_detach_commit}"
    trellis_home_registry_lock_acquire() { trellis_home_lock_acquire "$1" registry 0; }
    fixture_stage_registry_lock() {
      mkdir "$test_home/locks/registry.lock" && printf "%s\n" "$$" > "$test_home/locks/registry.lock/pid"
    }
    test_home="$2"; test_mode="$4"
    attachment_detach_commit() {
      if [ "$test_mode" = before ]; then fixture_stage_registry_lock || return 99; fi
      fixture_detach_commit "$@" || return "$?"
      if [ "$test_mode" = after ]; then fixture_stage_registry_lock || return 99; fi
    }
    attach_cmd_detach --home "$test_home" "$3"
  ' _ "$ATTACH" "$TRELLIS_HOME" "$WITNESS" "$1" "${DETACH_TEST_BASELINE_LIB:-}"
}

@test "full detach registry timeout keeps its exact owner and journal until a successful retry" {
  local attachment journal before registry_before
  attachment="$(jq -r .attachment_id "$WITNESS_OWNER")"
  journal="$JOURNAL_DIR/detach-$attachment.json"
  before="$(_attachment_hash "$WITNESS_OWNER")"
  registry_before="$(_attachment_hash "$TRELLIS_HOME/registry.json")"
  detach_with_registry_contention before
  [ "$status" -eq 5 ] || { echo "$output"; return 1; }
  [[ "$output" == *'timed out waiting for registry lock'* ]]
  [ -f "$WITNESS_OWNER" ] || { echo 'timeout removed owner'; return 1; }
  [ "$(_attachment_hash "$WITNESS_OWNER")" = "$before" ]
  [ "$(_attachment_hash "$TRELLIS_HOME/registry.json")" = "$registry_before" ]
  jq -e '.owner_committed == false and .phase == (.remove | length)' "$journal"
  (cd "$TRELLIS_HOME/locks/registry.lock" && rm ./pid)
  rmdir "$TRELLIS_HOME/locks/registry.lock"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$WITNESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$WITNESS_OWNER" ]
  [ ! -e "$journal" ]
  jq -e --arg id "$attachment" '[.projects[].checkouts[].worktrees[] | select(.attachment_id? == $id)] | length == 0' "$TRELLIS_HOME/registry.json"
}

@test "full detach finishes without reacquiring a busy registry after its exact clear is durable" {
  local attachment journal
  attachment="$(jq -r .attachment_id "$WITNESS_OWNER")"
  journal="$JOURNAL_DIR/detach-$attachment.json"
  detach_with_registry_contention after
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$WITNESS_OWNER" ]
  [ ! -e "$journal" ]
  [ -f "$TRELLIS_HOME/locks/registry.lock/pid" ]
  jq -e --arg id "$attachment" '[.projects[].checkouts[].worktrees[] | select(.attachment_id? == $id)] | length == 0' "$TRELLIS_HOME/registry.json"
}

@test "recovery control rolls back the selected checkout's phase-zero journal" {
  run_recover
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_own_rolled_back
}

@test "recover ignores a foreign phase-218 detach with a vanished root and preserves its evidence" {
  seed_foreign_detach
  local before owner_before
  before="$(_attachment_hash "$FOREIGN_JOURNAL")"
  owner_before="$(_attachment_hash "$WITNESS_OWNER")"
  run_recover
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_own_rolled_back
  [ "$(_attachment_hash "$FOREIGN_JOURNAL")" = "$before" ]
  [ "$(_attachment_hash "$WITNESS_OWNER")" = "$owner_before" ]
}

@test "recover skips invalid prepared data bound to a different checkout before full validation" {
  FOREIGN_JOURNAL="$JOURNAL_DIR/$FOREIGN_ID.json"
  jq --arg id "$FOREIGN_ID" '.status = "prepared" | .attachment_id = $id | .phase = 999 | .applied = [] | .pending = null | .removal = null' "$WITNESS_OWNER" > "$FOREIGN_JOURNAL"
  chmod 600 "$FOREIGN_JOURNAL"
  local before="$(_attachment_hash "$FOREIGN_JOURNAL")"
  run_recover
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_own_rolled_back
  [ "$(_attachment_hash "$FOREIGN_JOURNAL")" = "$before" ]
}

@test "recover with only a foreign missing-root journal reports no matching journal, not invalid state" {
  seed_foreign_detach
  (cd "$JOURNAL_DIR" && rm "./$OWN_ID.json")
  local before="$(_attachment_hash "$FOREIGN_JOURNAL")" registry_before="$(_attachment_hash "$TRELLIS_HOME/registry.json")"
  run_recover
  [ "$status" -eq 5 ] || { echo "$output"; return 1; }
  [[ "$output" == *'no matching attachment journal'* ]]
  [ "$(_attachment_hash "$FOREIGN_JOURNAL")" = "$before" ]
  [ "$(_attachment_hash "$TRELLIS_HOME/registry.json")" = "$registry_before" ]
}

@test "recover still refuses corrupt same-checkout journals before any rollback" {
  seed_foreign_detach
  jq --arg c "$CHECKOUT" --arg w "$WORKTREE" --arg root "$PROJECT" '
    .checkout_id = $c | .worktree_id = $w
    | .original_owner.checkout_id = $c | .original_owner.worktree_id = $w
    | .original_owner.project_root = $root | .original_owner.worktree_root = $root
    | .phase = 999
  ' "$FOREIGN_JOURNAL" > "$ROOT/next"
  mv "$ROOT/next" "$FOREIGN_JOURNAL"; chmod 600 "$FOREIGN_JOURNAL"
  local before="$(_attachment_hash "$OWN_JOURNAL")" registry_before="$(_attachment_hash "$TRELLIS_HOME/registry.json")"
  run_recover
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [[ "$output" == *'attachment journal is invalid'* ]]
  [ "$(_attachment_hash "$OWN_JOURNAL")" = "$before" ]
  [ "$(_attachment_hash "$TRELLIS_HOME/registry.json")" = "$registry_before" ]
}

@test "recover refuses inconsistent detach checkout bindings and unsafe symlinks instead of hiding them as foreign" {
  seed_foreign_detach
  jq --arg c "$CHECKOUT" '.original_owner.checkout_id = $c' "$FOREIGN_JOURNAL" > "$ROOT/next"
  mv "$ROOT/next" "$FOREIGN_JOURNAL"; chmod 600 "$FOREIGN_JOURNAL"
  local before="$(_attachment_hash "$OWN_JOURNAL")"
  run_recover
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [ "$(_attachment_hash "$OWN_JOURNAL")" = "$before" ]
  mv "$FOREIGN_JOURNAL" "$ROOT/foreign-save"
  ln -s "$ROOT/foreign-save" "$FOREIGN_JOURNAL"
  run_recover
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [[ "$output" == *'attachment journal entry is unsafe'* ]]
  [ -L "$FOREIGN_JOURNAL" ]
  [ "$(_attachment_hash "$OWN_JOURNAL")" = "$before" ]
}
