#!/usr/bin/env bats

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

# BSD-only `stat -f %Lp` made every mode assertion in this suite fail on GNU
# coreutils, where -f is --file-system. Probe the BSD form and fall back to the
# GNU form in a SEPARATE capture — chaining them in one substitution would
# concatenate GNU's filesystem block with the mode.
mode_of() {
  local candidate
  candidate="$(stat -f %Lp "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %a "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

sha256_file() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

sha256_text() {
  printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
}

rewrite_json_0600() {
  local path replacement
  path=$1
  shift
  replacement="${path}.rewrite.$$"
  jq "$@" "$path" > "$replacement" || return 1
  chmod 600 "$replacement" || return 1
  mv "$replacement" "$path" || return 1
  chmod 600 "$path"
}

stage_pending_file() {
  local stage
  stage=$1
  rewrite_json_0600 "$JOURNAL" --arg stage "$stage" \
    '.pending = {artifact: .artifacts[0], staging_path: $stage, staging_identity: null, destination_identity: null}'
}

record_stage_identity() {
  local stage identity
  stage=$1
  identity=$(_attachment_fs_identity "$stage") || return 1
  rewrite_json_0600 "$JOURNAL" --arg identity "$identity" '.pending.staging_identity = $identity'
}

set_applied_prefix() {
  local phase
  phase=$1
  rewrite_json_0600 "$JOURNAL" --argjson phase "$phase" \
    '.phase = $phase | .applied = .artifacts[0:$phase] | .pending = null'
}

pending_stage_path() {
  printf '%s/.attached.txt.attachment-stage-%s.test' "$PROJECT" "$ATTACHMENT_ID"
}

stage_transaction_lock() {
  local pid holder
  pid=$1
  holder=${2:-$ATTACHMENT_ID}
  _attachment_test_stage_lock "$TRELLIS_HOME" "$CHECKOUT_ID" "$WORKTREE_ID" "$holder" "$pid"
}

transaction_lock_path() {
  _attachment_lock_path "$TRELLIS_HOME" "$CHECKOUT_ID" "$WORKTREE_ID"
}

wait_for_transaction_lock() {
  local path attempt
  path=$(transaction_lock_path)
  attempt=0
  while [ "$attempt" -lt 200 ]; do
    [ -L "$path" ] && return 0
    sleep 0.01
    attempt=$((attempt + 1))
  done
  return 1
}

transaction_lock_pid() {
  local target
  target=$(readlink "$(transaction_lock_path)") || return 1
  jq -r '.pid' "$TRELLIS_HOME/state/locks/$target/owner.json"
}

make_plan() {
  local output kinds attachment hash
  output=${1:-$PLAN}
  kinds=${2:-file}
  attachment=${3:-$ATTACHMENT_ID}
  hash=$(sha256_file "$SOURCE_FILE") || return 1

  case "$kinds" in
    file)
      jq -n \
        --arg fleet "$FLEET" \
        --arg project_id "$PROJECT_ID" \
        --arg checkout_id "$CHECKOUT_ID" \
        --arg worktree_id "$WORKTREE_ID" \
        --arg attachment_id "$attachment" \
        --arg project_root "$PROJECT" \
        --arg worktree_root "$PROJECT" \
        --arg release "$RELEASE" \
        --arg source "$SOURCE_FILE" \
        --arg sha256 "$hash" \
        '{
          schema_version: 1,
          status: "prepared",
          fleet: $fleet,
          project_id: $project_id,
          checkout_id: $checkout_id,
          worktree_id: $worktree_id,
          attachment_id: $attachment_id,
          project_root: $project_root,
          worktree_root: $worktree_root,
          release: $release,
          artifacts: [
            {path: "attached.txt", kind: "file", source: $source, sha256: $sha256}
          ]
        }' > "$output"
      ;;
    all)
      jq -n \
        --arg fleet "$FLEET" \
        --arg project_id "$PROJECT_ID" \
        --arg checkout_id "$CHECKOUT_ID" \
        --arg worktree_id "$WORKTREE_ID" \
        --arg attachment_id "$attachment" \
        --arg project_root "$PROJECT" \
        --arg worktree_root "$PROJECT" \
        --arg release "$RELEASE" \
        --arg source "$SOURCE_FILE" \
        --arg sha256 "$hash" \
        --arg managed "$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID" \
        '{
          schema_version: 1,
          status: "prepared",
          fleet: $fleet,
          project_id: $project_id,
          checkout_id: $checkout_id,
          worktree_id: $worktree_id,
          attachment_id: $attachment_id,
          project_root: $project_root,
          worktree_root: $worktree_root,
          release: $release,
          exclude_block_hash: $sha256,
          git_hooks: {
            enabled: true,
            managed_hooks_path: $managed,
            previous_hooks_path: null,
            pre_push_source: "core-rules/githooks/pre-push"
          },
          artifacts: [
            {path: "attached.txt", kind: "file", source: $source, sha256: $sha256},
            {path: "link.txt", kind: "symlink", target: "target.txt"},
            {path: "empty", kind: "directory"}
          ]
        }' > "$output"
      ;;
    *)
      return 1
      ;;
  esac

  chmod 600 "$output"
}

prepare_plan() {
  local kinds
  kinds=${1:-file}
  make_plan "$PLAN" "$kinds" || return 1
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
}

prepare_managed_hooks() {
  local managed payload release carrier carrier_oid manifest
  managed="$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID"
  payload="$TRELLIS_HOME/releases/$RELEASE/payload"
  release="${payload%/payload}"
  carrier="$payload/core-rules/githooks/pre-push"
  mkdir -p "$managed" "$(dirname "$carrier")"
  chmod 700 "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/git-hooks" "$managed"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$carrier"
  carrier_oid="$(git hash-object "$carrier")"
  jq -n --arg release "$RELEASE" --arg oid "$carrier_oid" \
    '{schema_version:1,version:$release,tag:("v" + $release),commit:"0000000000000000000000000000000000000000",remote:"fixture",tree:[{path:"core-rules/githooks/pre-push",mode:"100755",oid:$oid}]}' > "$release/release.json"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$payload")" || return 1
  printf '%s\n' "$(_attachment_hooks_post_checkout_dispatcher_body "$payload" "$manifest")" > "$managed/post-checkout"
  printf '%s\n' "$(_attachment_hooks_pre_push_dispatcher_body "$payload" 'core-rules/githooks/pre-push' "$manifest")" > "$managed/pre-push"
  printf '\n' > "$managed/previous-hooks-path"
  printf '%s\n' "$payload" > "$managed/release-payload"
  printf '%s\n' 'core-rules/githooks/pre-push' > "$managed/pre-push-source"
  chmod 700 "$managed/post-checkout" "$managed/pre-push"
  chmod 600 "$managed/previous-hooks-path" "$managed/release-payload" "$managed/pre-push-source"
  chmod 700 "$carrier"
  git -C "$PROJECT" config --local core.hooksPath "$managed"
}

setup() {
  TEMP_ROOT=${TMPDIR:-/tmp}
  ROOT=$(mktemp -d "${TEMP_ROOT%/}/attachment-test.XXXXXX")
  ROOT=$(canonical_dir "$ROOT")
  TRELLIS_HOME="$ROOT/home"
  PROJECT="$ROOT/project"
  SOURCE_ROOT="$ROOT/source"
  SOURCE_FILE="$SOURCE_ROOT/payload.txt"
  PLAN="$ROOT/plan.json"
  PLAN_TWO="$ROOT/plan-two.json"
  FLEET="fleet-a"
  PROJECT_ID="project-a"
  ATTACHMENT_ID="11111111-2222-3333-4444-555555555555"
  ATTACHMENT_TWO="66666666-7777-8888-9999-aaaaaaaaaaaa"
  RELEASE="1.2.3"

  mkdir -p "$TRELLIS_HOME" "$PROJECT" "$SOURCE_ROOT"
  git init -q "$PROJECT"
  CHECKOUT_ID=$(sha256_text "$(canonical_dir "$PROJECT/.git")")
  WORKTREE_ID=$(sha256_text "$PROJECT")
  JOURNAL="$TRELLIS_HOME/state/attachment-journals/$ATTACHMENT_ID.json"
  JOURNAL_TWO="$TRELLIS_HOME/state/attachment-journals/$ATTACHMENT_TWO.json"
  OWNER="$TRELLIS_HOME/state/attachments/$CHECKOUT_ID/$WORKTREE_ID.json"

  printf 'attachment payload\n' > "$SOURCE_FILE"
  source "$BATS_TEST_DIRNAME/../lib/attachment.sh"
}

teardown() {
  rm -rf "$ROOT"
}

@test "Bash 3.2-compatible fixtures prepare a canonical 0600 journal without project writes" {
  make_plan "$PLAN" file

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ -f "$JOURNAL" ]
  [ "$(mode_of "$JOURNAL")" = 600 ]
  [ ! -e "$PROJECT/attached.txt" ]
  jq -e \
    --arg source "$SOURCE_FILE" \
    '.status == "prepared" and .phase == 0 and .applied == [] and .pending == null and .artifacts[0].source == $source' \
    "$JOURNAL"
}

@test "filesystem identities are stable and distinguish sibling objects" {
  touch "$ROOT/identity-a" "$ROOT/identity-b"
  identity_a=$(_attachment_fs_identity "$ROOT/identity-a")
  identity_b=$(_attachment_fs_identity "$ROOT/identity-b")

  [ "$identity_a" = "$(_attachment_fs_identity "$ROOT/identity-a")" ]
  [ "$identity_a" != "$identity_b" ]
  [[ "$identity_a" =~ ^[0-9]+:[0-9]+$ ]] || { echo "$identity_a"; false; }
  [[ "$identity_b" =~ ^[0-9]+:[0-9]+$ ]] || { echo "$identity_b"; false; }
}

@test "commit publishes and verifies file symlink and empty-directory artifacts" {

  prepare_plan all

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ -f "$PROJECT/attached.txt" ]
  [ "$(cat "$PROJECT/attached.txt")" = "attachment payload" ]
  [ -L "$PROJECT/link.txt" ]
  [ "$(readlink "$PROJECT/link.txt")" = "target.txt" ]
  [ -d "$PROJECT/empty" ]
  [ -z "$(find "$PROJECT/empty" -mindepth 1 -print -quit)" ]
  [ -f "$OWNER" ]
  [ "$(mode_of "$OWNER")" = 600 ]
  [ "$(mode_of "$TRELLIS_HOME")" = 700 ]
  [ "$(mode_of "$TRELLIS_HOME/state")" = 700 ]
  [ ! -e "$JOURNAL" ]
  jq -e '.status == "committed" and (.artifacts[0] | has("source") | not) and .artifacts[0].sha256 != null and .artifacts[1].target == "target.txt" and .git_hooks.enabled == true' "$OWNER"
  prepare_managed_hooks

  run attachment_verify "$TRELLIS_HOME" "$OWNER"

  [ "$status" -eq 0 ]
}

@test "exact committed replay writes a full-prefix journal and re-verifies before commit" {
  prepare_plan all
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ -f "$JOURNAL" ]
  [ "$(mode_of "$JOURNAL")" = 600 ]
  jq -e '.status == "prepared" and .phase == (.artifacts | length) and .applied == .artifacts and .pending == null' "$JOURNAL"

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$JOURNAL" ]
  # The `all` plan declares git_hooks.enabled, so verify also checks the managed
  # dispatcher state — stage it exactly as the neighbouring commit test does.
  prepare_managed_hooks
  run attachment_verify "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
}

@test "prepare rejects a destination collision before writing a journal or another artifact" {
  make_plan "$PLAN" all
  touch "$PROJECT/link.txt"

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$PROJECT/empty" ]
}

@test "prepare rejects a missing source before a journal exists" {
  make_plan "$PLAN" file
  rm "$SOURCE_FILE"

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]
}

@test "commit rejects a source changed after prepare without publishing it" {
  prepare_plan file
  printf 'changed after prepare\n' > "$SOURCE_FILE"

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$OWNER" ]
}

@test "prepare rejects trailing equal casefold and ancestor artifact aliases before writes" {
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" '.artifacts[0].path = "attached.txt/"'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ ! -e "$JOURNAL" ]

  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" '.artifacts = [(.artifacts[0] | .path = "same"), (.artifacts[0] | .path = "same")]'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ ! -e "$JOURNAL" ]

  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" '.artifacts = [(.artifacts[0] | .path = "Hook"), (.artifacts[0] | .path = "hook")]'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ ! -e "$JOURNAL" ]

  make_plan "$PLAN" all
  rewrite_json_0600 "$PLAN" '.artifacts = [(.artifacts[2] | .path = "tree"), (.artifacts[0] | .path = "tree/child")]'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$PROJECT/tree" ]
}

@test "prepare rejects symlink components in HOME roots and file sources" {
  ln -s "$TRELLIS_HOME" "$ROOT/home-link"
  make_plan "$PLAN" file

  run attachment_prepare "$ROOT/home-link" "$PLAN" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ ! -e "$JOURNAL" ]

  ln -s "$PROJECT" "$ROOT/project-link"
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" --arg root "$ROOT/project-link" '.project_root = $root | .worktree_root = $root'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ ! -e "$JOURNAL" ]

  ln -s "$SOURCE_ROOT" "$ROOT/source-link"
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" --arg source "$ROOT/source-link/payload.txt" '.artifacts[0].source = $source'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ ! -e "$JOURNAL" ]
}

@test "prepare rejects a noncanonical absolute root path" {
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" --arg root "$PROJECT/." '.project_root = $root'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ ! -e "$JOURNAL" ]
}

@test "state entry points reject a wrong HOME and noncanonical state paths" {
  prepare_plan file
  mkdir "$ROOT/other-home"

  run attachment_commit "$ROOT/other-home" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ -f "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]

  cp "$JOURNAL" "$ROOT/foreign-journal.json"
  chmod 600 "$ROOT/foreign-journal.json"

  run attachment_commit "$TRELLIS_HOME" "$ROOT/foreign-journal.json"

  [ "$status" -eq 4 ]
  [ -f "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]

  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  cp "$OWNER" "$ROOT/foreign-owner.json"
  chmod 600 "$ROOT/foreign-owner.json"

  run attachment_verify "$TRELLIS_HOME" "$ROOT/foreign-owner.json"

  [ "$status" -eq 4 ]
}

@test "journal and ownership mode drift are rejected" {
  prepare_plan file
  chmod 644 "$JOURNAL"

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]

  chmod 600 "$JOURNAL"
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  chmod 644 "$OWNER"

  run attachment_verify "$TRELLIS_HOME" "$OWNER"

  [ "$status" -eq 3 ]
}

@test "verify rejects a missing committed file artifact" {
  prepare_plan file
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  rm "$PROJECT/attached.txt"

  run attachment_verify "$TRELLIS_HOME" "$OWNER"

  [ "$status" -eq 3 ]
}

@test "verify rejects a drifted committed file artifact" {
  prepare_plan file
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  printf 'drifted payload\n' > "$PROJECT/attached.txt"

  run attachment_verify "$TRELLIS_HOME" "$OWNER"

  [ "$status" -eq 3 ]
}

@test "verify rejects a type-changed committed artifact" {
  prepare_plan file
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  rm "$PROJECT/attached.txt"
  mkdir "$PROJECT/attached.txt"

  run attachment_verify "$TRELLIS_HOME" "$OWNER"

  [ "$status" -eq 3 ]
}

@test "committed replay rejects a missing artifact instead of accepting ownership JSON alone" {
  prepare_plan file
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  rm "$PROJECT/attached.txt"

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ ! -e "$JOURNAL" ]
}

@test "commit rejects an out-of-order applied prefix without publishing" {
  prepare_plan all
  rewrite_json_0600 "$JOURNAL" '.phase = 2 | .applied = [.artifacts[1], .artifacts[0]] | .pending = null'

  [ "$(mode_of "$JOURNAL")" = 600 ]
  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ -f "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$PROJECT/link.txt" ]
  [ ! -e "$PROJECT/empty" ]
}

@test "rollback rejects an applied count that does not equal phase" {
  prepare_plan all
  rewrite_json_0600 "$JOURNAL" '.phase = 2 | .applied = [.artifacts[0]] | .pending = null'

  [ "$(mode_of "$JOURNAL")" = 600 ]
  run attachment_rollback "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ -f "$JOURNAL" ]
}

@test "rollback removes an exact reverse prefix across all artifact kinds" {
  prepare_plan all
  set_applied_prefix 3
  cp "$SOURCE_FILE" "$PROJECT/attached.txt"
  ln -s target.txt "$PROJECT/link.txt"
  mkdir "$PROJECT/empty"

  run attachment_rollback "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$PROJECT/link.txt" ]
  [ ! -e "$PROJECT/empty" ]
  [ ! -e "$JOURNAL" ]
}

@test "rollback treats a missing exact applied artifact as an idempotent no-op" {
  prepare_plan file
  set_applied_prefix 1

  run attachment_rollback "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$JOURNAL" ]
}

@test "rollback refuses a type-changed applied artifact and leaves the journal" {
  prepare_plan file
  set_applied_prefix 1
  mkdir "$PROJECT/attached.txt"

  run attachment_rollback "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -d "$PROJECT/attached.txt" ]
  [ -f "$JOURNAL" ]
}

@test "rollback refuses a populated owned directory without recursive deletion" {
  prepare_plan all
  set_applied_prefix 3
  cp "$SOURCE_FILE" "$PROJECT/attached.txt"
  ln -s target.txt "$PROJECT/link.txt"
  mkdir "$PROJECT/empty"
  printf 'foreign\n' > "$PROJECT/empty/foreign.txt"

  run attachment_rollback "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$PROJECT/empty/foreign.txt" ]
  [ -f "$PROJECT/attached.txt" ]
  [ -L "$PROJECT/link.txt" ]
  [ -f "$JOURNAL" ]
}

@test "recovery rolls back pending intent before staging begins" {
  prepare_plan file
  stage=$(pending_stage_path)
  stage_pending_file "$stage"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$stage" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$OWNER" ]
}

@test "recovery rolls back a staged pending file" {
  prepare_plan file
  stage=$(pending_stage_path)
  stage_pending_file "$stage"
  cp "$SOURCE_FILE" "$stage"
  record_stage_identity "$stage"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$stage" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$JOURNAL" ]
}

@test "recovery rolls back a published pending file" {
  prepare_plan file
  stage=$(pending_stage_path)
  stage_pending_file "$stage"
  cp "$SOURCE_FILE" "$stage"
  record_stage_identity "$stage"
  ln -P -- "$stage" "$PROJECT/attached.txt"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$stage" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$JOURNAL" ]
}

@test "ordinary injected phases roll back incomplete transactions" {
  phase=1
  while [ "$phase" -le 3 ]; do
    prepare_plan all

    ATTACHMENT_FAULT_PHASE="$phase" run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

    [ "$status" -eq 5 ]
    [ ! -e "$PROJECT/attached.txt" ]
    [ ! -e "$PROJECT/link.txt" ]
    [ ! -e "$PROJECT/empty" ]
    [ ! -e "$JOURNAL" ]
    [ ! -e "$OWNER" ]
    phase=$((phase + 1))
  done
}

@test "recovery finalizes an owner-published stale journal without removing artifacts" {
  prepare_plan file

  ATTACHMENT_FAULT_PHASE=owner-published run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 5 ]
  [ -f "$OWNER" ]
  [ -f "$PROJECT/attached.txt" ]
  [ -f "$JOURNAL" ]

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ -f "$OWNER" ]
  [ -f "$PROJECT/attached.txt" ]
  [ ! -e "$JOURNAL" ]
  run attachment_verify "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
}

@test "two attachment IDs targeting one worktree do not clobber the first owner or artifact" {
  make_plan "$PLAN" file "$ATTACHMENT_ID"
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  make_plan "$PLAN_TWO" file "$ATTACHMENT_TWO"
  attachment_prepare "$TRELLIS_HOME" "$PLAN_TWO" "$JOURNAL_TWO"
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL_TWO"

  [ "$status" -eq 3 ]
  [ "$(sha256_file "$PROJECT/attached.txt")" = "$(sha256_file "$SOURCE_FILE")" ]
  [ "$(jq -r '.attachment_id' "$OWNER")" = "$ATTACHMENT_ID" ]
  [ -f "$JOURNAL_TWO" ]
}

@test "a live matching worktree lock returns busy without publication" {
  prepare_plan file
  stage_transaction_lock "$$"

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]
}

@test "recovery reclaims a matching dead worktree lock" {
  prepare_plan file
  stage_transaction_lock 999999

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]
}

@test "recovery refuses a dead foreign worktree lock" {
  prepare_plan file
  stage_transaction_lock 999999 "$ATTACHMENT_TWO"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$JOURNAL" ]
}

@test "recovery reclaims the lock left by a killed real transaction process" {
  prepare_plan file
  ATTACHMENT_TEST_HOLD_LOCK=2 attachment_commit "$TRELLIS_HOME" "$JOURNAL" &
  background_pid=$!
  wait_for_transaction_lock
  transaction_pid=$(transaction_lock_pid)

  kill -KILL "$transaction_pid"
  wait "$background_pid" || true

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$(transaction_lock_path)" ]
  [ ! -L "$(transaction_lock_path)" ]
}

@test "a terminating signal releases the lock and stops publication" {
  prepare_plan file
  ATTACHMENT_TEST_HOLD_LOCK=2 attachment_commit "$TRELLIS_HOME" "$JOURNAL" &
  background_pid=$!
  wait_for_transaction_lock
  transaction_pid=$(transaction_lock_pid)

  kill -TERM "$transaction_pid"
  transaction_status=0
  wait "$background_pid" || transaction_status=$?

  [ "$transaction_status" -eq 5 ]
  [ ! -e "$(transaction_lock_path)" ]
  [ ! -L "$(transaction_lock_path)" ]
  [ ! -e "$PROJECT/attached.txt" ]

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ -f "$PROJECT/attached.txt" ]
}

@test "rollback preflights every applied parent before removing any artifact" {
  mkdir "$PROJECT/parent" "$ROOT/external"
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" \
    '.artifacts = [(.artifacts[0] | .path = "parent/attached.txt"), (.artifacts[0] | .path = "safe.txt")]'
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  cp "$SOURCE_FILE" "$PROJECT/parent/attached.txt"
  cp "$SOURCE_FILE" "$PROJECT/safe.txt"
  set_applied_prefix 2
  rm "$PROJECT/parent/attached.txt"
  rmdir "$PROJECT/parent"
  ln -s "$ROOT/external" "$PROJECT/parent"

  run attachment_rollback "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$PROJECT/safe.txt" ]
  [ ! -e "$ROOT/external/attached.txt" ]
  [ -f "$JOURNAL" ]
}

@test "public entry points reserve exit two for bad arguments" {
  run attachment_prepare "$TRELLIS_HOME"
  [ "$status" -eq 2 ]

  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" '.release = "not-semver"'
  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  [ "$status" -eq 4 ]
}

@test "pinned removal cannot follow a parent replaced after exact verification" {
  mkdir "$PROJECT/parent" "$ROOT/external"
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" '.artifacts[0].path = "parent/attached.txt"'
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  cp "$SOURCE_FILE" "$PROJECT/parent/attached.txt"
  cp "$SOURCE_FILE" "$ROOT/external/attached.txt"
  artifact=$(jq -c '.artifacts[0]' "$JOURNAL")
  _attachment_path_exact() {
    mv "$PROJECT/parent" "$PROJECT/pinned-parent"
    ln -s "$ROOT/external" "$PROJECT/parent"
    return 0
  }

  run _attachment_remove_pinned "$JOURNAL" "$PROJECT/parent/attached.txt" "$artifact" "" 0 1

  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/pinned-parent/attached.txt" ]
  [ -f "$ROOT/external/attached.txt" ]
}

@test "an existing journal for a different plan is an identity conflict" {
  prepare_plan file
  rewrite_json_0600 "$PLAN" '.release = "1.2.4"'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$JOURNAL" ]
  [ "$(jq -r '.release' "$JOURNAL")" = "1.2.3" ]
}

@test "stage creation cannot follow a replaced parent outside the worktree" {
  mkdir "$PROJECT/parent" "$ROOT/external"
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" '.artifacts[0].path = "parent/attached.txt"'
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  artifact=$(jq -c '.artifacts[0]' "$JOURNAL")
  stage=$(_attachment_stage_path "$PROJECT" "parent/attached.txt" "$ATTACHMENT_ID")
  stage_pending_file "$stage"
  rmdir "$PROJECT/parent"
  ln -s "$ROOT/external" "$PROJECT/parent"

  run _attachment_create_file_stage "$JOURNAL" "$artifact" "$stage"

  [ "$status" -eq 3 ]
  [ ! -e "$stage" ]
  [ ! -e "$ROOT/external/$(basename "$stage")" ]
}

@test "recovery resumes an authenticated claimed removal after a crash" {
  prepare_plan file
  cp "$SOURCE_FILE" "$PROJECT/attached.txt"
  set_applied_prefix 1
  _attachment_set_removal_intent "$JOURNAL" "$PROJECT/attached.txt"
  _attachment_journal_claim_layout "$JOURNAL" "$PROJECT/attached.txt"
  mkdir "$_ATTACHMENT_QUARANTINE"
  chmod 700 "$_ATTACHMENT_QUARANTINE"
  mv "$PROJECT/attached.txt" "$_ATTACHMENT_CLAIM_PATH"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$_ATTACHMENT_QUARANTINE" ]
  [ ! -e "$JOURNAL" ]
}

@test "recovery resumes an authenticated empty removal after a crash" {
  prepare_plan file
  cp "$SOURCE_FILE" "$PROJECT/attached.txt"
  set_applied_prefix 1
  _attachment_set_removal_intent "$JOURNAL" "$PROJECT/attached.txt"
  _attachment_journal_claim_layout "$JOURNAL" "$PROJECT/attached.txt"
  mkdir "$_ATTACHMENT_QUARANTINE"
  chmod 700 "$_ATTACHMENT_QUARANTINE"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$_ATTACHMENT_QUARANTINE" ]
  [ ! -e "$JOURNAL" ]
}

@test "recovery rejects an unjournaled removal quarantine collision" {
  prepare_plan file
  set_applied_prefix 1
  quarantine="$PROJECT/.trellis-attachment-remove-forged"
  mkdir "$quarantine"
  cp "$SOURCE_FILE" "$quarantine/artifact"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ]
  [ -f "$quarantine/artifact" ]
  [ -f "$JOURNAL" ]
  [ "$(jq -r '.removal == null' "$JOURNAL")" = true ]
}

@test "commit replay rolls back an active authenticated removal" {
  prepare_plan file
  cp "$SOURCE_FILE" "$PROJECT/attached.txt"
  set_applied_prefix 1
  _attachment_set_removal_intent "$JOURNAL" "$PROJECT/attached.txt"
  _attachment_journal_claim_layout "$JOURNAL" "$PROJECT/attached.txt"
  quarantine=$_ATTACHMENT_QUARANTINE
  mkdir "$quarantine"
  chmod 700 "$quarantine"
  mv "$PROJECT/attached.txt" "$_ATTACHMENT_CLAIM_PATH"

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 5 ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$quarantine" ]
  [ ! -e "$OWNER" ]
  [ ! -e "$JOURNAL" ]
}

@test "ownership verification cannot follow a parent swapped after its final safety check" {
  mkdir "$PROJECT/parent" "$ROOT/external"
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" '.artifacts[0].path = "parent/attached.txt"'
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  cp "$SOURCE_FILE" "$ROOT/external/attached.txt"
  parent_safe_calls=0
  _attachment_parent_safe() {
    parent_safe_calls=$((parent_safe_calls + 1))
    if [ "$parent_safe_calls" -eq 2 ]; then
      mv "$PROJECT/parent" "$PROJECT/original-parent"
      ln -s "$ROOT/external" "$PROJECT/parent"
    fi
    return 0
  }

  run attachment_verify "$TRELLIS_HOME" "$OWNER"

  [ "$status" -eq 3 ]
  [ -f "$PROJECT/original-parent/attached.txt" ]
  [ -f "$ROOT/external/attached.txt" ]
}
