#!/usr/bin/env bats
# Explicit orphan-journal discard: archive evidence, never replay vanished paths.
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

setup() {
  ROOT="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$ROOT"
  ROOT="$(CDPATH= cd "$ROOT" && pwd -P)"
  release_fixture_prototype_clone "$BATS_FILE_TMPDIR/prototype" "$ROOT"
  export HOME="$ROOT/user" TRELLIS_HOME="$ROOT/trellis"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TRELLIS_ATTACH_POSTJOB=off
  PROJECT="$ROOT/surviving project"
  GONE="$ROOT/vanished worktree"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" -c core.hooksPath=/dev/null init -q -b main
  printf '{"schema_version":1,"project_id":"orphan-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -qm seed
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.9.9 --harness claude "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  source "$ATTACH"
  set +u
  IDENTITY="$(local_registry_identity_for_root "$PROJECT")"
  CHECKOUT="$(printf '%s\n' "$IDENTITY" | jq -r .checkout_id)"
  MAIN_ID="$(printf '%s\n' "$IDENTITY" | jq -r .worktree_id)"
  GONE_ID="$(_attachment_hash_text "$GONE")"
  OWNER="$TRELLIS_HOME/state/attachments/$CHECKOUT/$MAIN_ID.json"
  GONE_OWNER="$TRELLIS_HOME/state/attachments/$CHECKOUT/$GONE_ID.json"
  COMMON="$(printf '%s\n' "$IDENTITY" | jq -r .git_common_dir)"
  EXCLUDE="$COMMON/info/exclude"
  MANAGED="$(git -C "$PROJECT" config --local --get core.hooksPath)"
  OWNER_SHA="$(_attachment_hash "$OWNER")"
  EXCLUDE_SHA="$(_attachment_hash "$EXCLUDE")"
  cp "$EXCLUDE" "$ROOT/exclude.before"
}

teardown() {
  # The file-scoped fixture owns these sealed payloads; Bats removes its temp tree.
  [ ! -d "${ROOT:-}" ] || chmod -R u+w "$ROOT"
}

seed_prepared() {
  local phase="${1:-14}" release="${2:-1.3.6}" number="${3:-1}"
  ID="$(printf '11111111-2222-3333-4444-%012d' "$number")"
  JOURNAL="$TRELLIS_HOME/state/attachment-journals/$ID.json"
  LOG="$TRELLIS_HOME/state/attachment-progress/$ID.log"
  jq --arg root "$GONE" --arg worktree "$GONE_ID" --arg id "$ID" --arg release "$release" --argjson phase "$phase" '
    .status = "prepared" | .project_root = $root | .worktree_root = $root
    | .worktree_id = $worktree | .attachment_id = $id | .release = $release
    | .artifacts = [range(0;150) | {path:("leaf-" + tostring),kind:"symlink",target:"old-runtime"}]
    | .renders = [] | .pre_existing = [] | .render_context = null
    | .phase = $phase | .applied = .artifacts[0:$phase] | .pending = null | .removal = null
  ' "$OWNER" > "$JOURNAL"
  chmod 600 "$JOURNAL"
  _attachment_journal_json_valid "$JOURNAL" || return 1
  seed_registry
}

seed_registry() {
  jq --arg checkout "$CHECKOUT" --arg wid "$GONE_ID" --arg root "$GONE" --arg id "$ID" '
    .projects["personal/orphan-fixture"].checkouts[$checkout].worktrees[$wid] = {root:$root,attachment_id:$id}
  ' "$TRELLIS_HOME/registry.json" > "$ROOT/registry.next"
  mv "$ROOT/registry.next" "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

seed_progress() {
  local stage="${1:-$GONE/.leaf-14.attachment-stage-$ID.fixture}"
  mkdir -p "$(dirname "$LOG")"
  jq '.journal_version = 2' "$JOURNAL" > "$ROOT/journal.next"
  mv "$ROOT/journal.next" "$JOURNAL"
  chmod 600 "$JOURNAL"
  printf '{"e":"begin","v":2,"attachment_id":"%s","phase":14}\n' "$ID" > "$LOG"
  jq -cn --arg path "$stage" '{e:"pending",index:14,parent_identity:"1:2",staging_path:$path}' >> "$LOG"
  printf '{"e":"staging_identity","identity":"1:3"}\n{"e":"applied","index":14}\n' >> "$LOG"
  chmod 600 "$LOG"
}

archive_for() {
  local entry
  for entry in "$TRELLIS_HOME/backups/discarded-journals-"*/"$1"; do
    [ ! -f "$entry" ] || printf '%s\n' "$entry"
  done
}

assert_shared_unchanged() {
  [ "$(_attachment_hash "$OWNER")" = "$OWNER_SHA" ]
  [ "$(_attachment_hash "$EXCLUDE")" = "$EXCLUDE_SHA" ]
  [ "$(git -C "$PROJECT" config --local --get-all core.hooksPath)" = "$MANAGED" ]
}

run_discard() {
  run "$ATTACH" recover --home "$TRELLIS_HOME" --discard-orphan-journal "$ID" "$PROJECT"
}

assert_refusal() {
  local before registry_before
  before="$(_attachment_hash "$JOURNAL")"
  registry_before="$(_attachment_hash "$TRELLIS_HOME/registry.json")"
  run_discard
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"orphan journal discard refused"* ]] || { echo "$output"; return 1; }
  [ "$(_attachment_hash "$JOURNAL")" = "$before" ]
  [ "$(_attachment_hash "$TRELLIS_HOME/registry.json")" = "$registry_before" ]
  [ -z "$(archive_for "${JOURNAL##*/}")" ]
}

@test "discard archives the four old prepared incidents at phases 102, 14, 121 and 126" {
  local incident phase release number=0 before archived
  for incident in 1.3.6:102 1.3.6:14 1.3.1:121 1.3.2:126; do
    number=$((number + 1))
    release="${incident%:*}"; phase="${incident#*:}"
    seed_prepared "$phase" "$release" "$number"
    before="$(_attachment_hash "$JOURNAL")"
    run_discard
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    archived="$(archive_for "$ID.json")"
    [ -n "$archived" ]
    [ "$(_attachment_hash "$archived")" = "$before" ]
    [ "$(_attachment_mode "$archived")" = 600 ]
    [ ! -e "$JOURNAL" ]
    jq -e --arg c "$CHECKOUT" --arg w "$GONE_ID" '.projects["personal/orphan-fixture"].checkouts[$c].worktrees[$w] | has("attachment_id") | not' "$TRELLIS_HOME/registry.json"
    [ ! -e "$GONE_OWNER" ]
    assert_shared_unchanged
  done
}

@test "discard archives a phase-218 detach journal whose original owner is already gone" {
  seed_prepared 14 1.3.2
  local old="$JOURNAL" before archived
  JOURNAL="$TRELLIS_HOME/state/attachment-journals/detach-$ID.json"
  jq '
    .status = "committed" | del(.phase,.applied,.pending,.removal)
    | .artifacts = [range(0;218) | {path:("leaf-" + tostring),kind:"symlink",target:"old-runtime"}]
    | . as $owner
    | {schema_version:1,status:"detaching",attachment_id:$owner.attachment_id,
       checkout_id:$owner.checkout_id,worktree_id:$owner.worktree_id,original_owner:$owner,
       next_owner:null,remove:$owner.artifacts,phase:218,removal:null,owner_committed:true,
       external:{phase:0,exclude_action:"restore",transfer:null,restore_hooks:true,
                 clear_registry:true,renders:[],render_phase:0,render_pending:null,registry_update:null}}
  ' "$old" > "$JOURNAL"
  chmod 600 "$JOURNAL"
  (cd "$(dirname "$old")" && rm "./${old##*/}")
  # Ordinary detach recovery still refuses the missing original root.
  run _attachment_detach_journal_valid "$JOURNAL"
  [ "$status" -ne 0 ]
  before="$(_attachment_hash "$JOURNAL")"
  run_discard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  archived="$(archive_for "detach-$ID.json")"
  [ "$(_attachment_hash "$archived")" = "$before" ]
  [ "$(_attachment_mode "$archived")" = 600 ]
  [ ! -e "$JOURNAL" ]
  assert_shared_unchanged
}

@test "discard preserves a v2 progress log and original journal bytes and modes" {
  seed_prepared
  seed_progress
  local before log_before archived archived_log
  before="$(_attachment_hash "$JOURNAL")"; log_before="$(_attachment_hash "$LOG")"
  run_discard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  archived="$(archive_for "$ID.json")"; archived_log="$(archive_for "$ID.log")"
  [ "$(_attachment_hash "$archived")" = "$before" ]
  [ "$(_attachment_hash "$archived_log")" = "$log_before" ]
  [ "$(_attachment_mode "$archived")" = 600 ]
  [ "$(_attachment_mode "$archived_log")" = 600 ]
  [ ! -e "$LOG" ]
  assert_shared_unchanged
}

@test "discard refuses live roots, foreign checkouts, owners and writes outside the vanished root" {
  local kind saved
  for kind in live foreign owner outside progress; do
    seed_prepared
    case "$kind" in
      live) mkdir -p "$GONE" ;;
      foreign)
        jq '.checkout_id = ("a" * 64)' "$JOURNAL" > "$ROOT/journal.next"
        mv "$ROOT/journal.next" "$JOURNAL"; chmod 600 "$JOURNAL" ;;
      owner) printf '{}\n' > "$GONE_OWNER"; chmod 600 "$GONE_OWNER" ;;
      outside)
        jq --arg p "$ROOT/outside" '.removal = {path:$p,nonce:("a" * 64)}' "$JOURNAL" > "$ROOT/journal.next"
        mv "$ROOT/journal.next" "$JOURNAL"; chmod 600 "$JOURNAL" ;;
      progress) seed_progress "$ROOT/outside-stage" ;;
    esac
    assert_refusal
    case "$kind" in
      live) rmdir "$GONE" ;;
      owner) (cd "$(dirname "$GONE_OWNER")" && rm "./${GONE_OWNER##*/}") ;;
      progress) (cd "$(dirname "$LOG")" && rm "./${LOG##*/}") ;;
    esac
  done
  assert_shared_unchanged
}

@test "discard refuses journal and owner symlinks without following or moving them" {
  seed_prepared
  mv "$JOURNAL" "$ROOT/saved-journal"
  ln -s "$ROOT/saved-journal" "$JOURNAL"
  assert_refusal
  [ -L "$JOURNAL" ]
  (cd "$(dirname "$JOURNAL")" && rm "./${JOURNAL##*/}")
  mv "$ROOT/saved-journal" "$JOURNAL"
  ln -s "$ROOT/nonexistent-owner" "$GONE_OWNER"
  assert_refusal
  [ -L "$GONE_OWNER" ]
}

@test "discard refuses shared exclude or dispatcher drift and names restoration of the recorded root" {
  seed_prepared
  printf '\n# --- Trellis local attachment exclude block ---\n' >> "$EXCLUDE"
  assert_refusal
  [[ "$output" == *"restore"*"$GONE"* ]] || [[ "$output" == *"restore"*"vanished"* ]]
  cp "$ROOT/exclude.before" "$EXCLUDE"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  assert_refusal
  git -C "$PROJECT" config --local core.hooksPath "$MANAGED"
  assert_shared_unchanged
}

@test "discard refuses a live transaction holder without clearing registry or journal" {
  seed_prepared
  _attachment_lock_acquire "$TRELLIS_HOME" "$CHECKOUT" "$GONE_ID" "$ID" || return 1
  assert_refusal
  _attachment_lock_release
}

@test "discard never overwrites an archive or follows a backups symlink" {
  seed_prepared
  local day="$(date -u +%Y-%m-%d)"
  mkdir -p "$TRELLIS_HOME/backups/discarded-journals-$day"
  printf 'retained archive\n' > "$TRELLIS_HOME/backups/discarded-journals-$day/$ID.json"
  local before="$(_attachment_hash "$JOURNAL")" registry_before="$(_attachment_hash "$TRELLIS_HOME/registry.json")"
  run_discard
  [ "$status" -ne 0 ]
  [ "$(_attachment_hash "$JOURNAL")" = "$before" ]
  [ "$(_attachment_hash "$TRELLIS_HOME/registry.json")" = "$registry_before" ]
  grep -Fx 'retained archive' "$TRELLIS_HOME/backups/discarded-journals-$day/$ID.json"
  (cd "$TRELLIS_HOME/backups/discarded-journals-$day" && rm "./$ID.json")
  rmdir "$TRELLIS_HOME/backups/discarded-journals-$day" "$TRELLIS_HOME/backups"
  mkdir "$ROOT/outside-backups"
  ln -s "$ROOT/outside-backups" "$TRELLIS_HOME/backups"
  assert_refusal
  [ -L "$TRELLIS_HOME/backups" ]
  [ -z "$(find "$ROOT/outside-backups" -mindepth 1 -print)" ]
}
