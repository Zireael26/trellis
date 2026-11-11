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
  local stage parent_identity
  stage=$1
  parent_identity=$(_attachment_fs_identity "$(dirname "$stage")") || return 1
  rewrite_json_0600 "$JOURNAL" --arg stage "$stage" --arg parent_identity "$parent_identity" \
    '.pending = {artifact: .artifacts[0], staging_path: $stage, staging_identity: null, destination_identity: null, parent_identity: $parent_identity}'
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

prepare_older_managed_hooks() {
  local managed payload release old_lib old_lib_tmp old_oid home_oid manifest
  local old_launcher launcher_oid stamp_oid
  local legacy_post legacy_pre
  managed="$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID"
  payload="$TRELLIS_HOME/releases/$RELEASE/payload"
  release="${payload%/payload}"
  old_lib="$payload/scripts/lib/attachment.sh"
  old_lib_tmp="${old_lib}.tmp"
  old_launcher="$payload/scripts/trellis-launcher.sh"
  mkdir -p "$(dirname "$old_lib")"
  cp "$BATS_TEST_DIRNAME/../lib/attachment.sh" "$old_lib" || return 1
  cp "$BATS_TEST_DIRNAME/../lib/trellis-home.sh" "${old_lib%/*}/trellis-home.sh" || return 1
  sed \
    -e '/^[[:space:]]*TRELLIS_ALLOW_MAIN_PUSH=.*$/d' \
    -e '/^[[:space:]]*SECURITY_GATE_SKIP=.*$/d' \
    -e '/^[[:space:]]*export TRELLIS_ALLOW_MAIN_PUSH SECURITY_GATE_SKIP$/d' \
    "$old_lib" > "$old_lib_tmp" || return 1
  mv "$old_lib_tmp" "$old_lib" || return 1
  chmod 755 "$old_lib" || return 1
  # Prove the ageing transformation is historical and not a silent no-op: the
  # current generator carries the bypass-marker passthrough, the aged one must
  # not. A no-op sed would leave a copy of the current payload here and make the
  # authentic-old half of this case vacuous.
  grep -q 'TRELLIS_ALLOW_MAIN_PUSH' "$BATS_TEST_DIRNAME/../lib/attachment.sh" || return 1
  ! grep -q 'TRELLIS_ALLOW_MAIN_PUSH' "$old_lib" || return 1
  # A payload generator resolves its command-scratch emitters through its OWN
  # payload: _attachment_launcher_source binds TRELLIS_VERIFIED_PAYLOAD to
  # <payload>/scripts/trellis-launcher.sh, from which
  # _attachment_command_scratch_emitters extracts the two
  # launcher_command_scratch_*_program definitions verbatim. An old payload that
  # declares the generator must therefore also ship the launcher it extracts
  # from; without it the emitters return 1 and the generator emits nothing.
  cp "$BATS_TEST_DIRNAME/../trellis-launcher.sh" "$old_launcher" || return 1
  chmod 755 "$old_launcher" || return 1
  # The same holds for the release stamp program the generator embeds.
  cp "$BATS_TEST_DIRNAME/../lib/release_stamp.py" "${old_lib%/*}/release_stamp.py" || return 1
  stamp_oid="$(git hash-object "${old_lib%/*}/release_stamp.py")" || return 1
  old_oid="$(git hash-object "$old_lib")" || return 1
  home_oid="$(git hash-object "${old_lib%/*}/trellis-home.sh")" || return 1
  launcher_oid="$(git hash-object "$old_launcher")" || return 1
  # One rewrite: the manifest hash below covers release.json, so all copied
  # payload files must be in it before the manifest is taken.
  rewrite_json_0600 "$release/release.json" --arg oid "$old_oid" --arg home "$home_oid" --arg launcher "$launcher_oid" \
    --arg stamp "$stamp_oid" \
    '.tree += [{path:"scripts/lib/attachment.sh",mode:"100755",oid:$oid},
               {path:"scripts/lib/trellis-home.sh",mode:"100755",oid:$home},
               {path:"scripts/trellis-launcher.sh",mode:"100755",oid:$launcher},
               {path:"scripts/lib/release_stamp.py",mode:"100644",oid:$stamp}]' || return 1
  manifest="$(_attachment_hooks_release_manifest_sha256 "$payload")" || return 1
  legacy_post="$(
    TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$payload" /bin/bash --noprofile --norc -c '
      source "${1%/*}/trellis-home.sh" || exit
      source "$1"
      _attachment_hooks_post_checkout_dispatcher_body "$2" "$3"
    ' legacy-dispatcher "$old_lib" "$payload" "$manifest"
  )" || return 1
  legacy_pre="$(
    TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$payload" /bin/bash --noprofile --norc -c '
      source "${1%/*}/trellis-home.sh" || exit
      source "$1"
      _attachment_hooks_pre_push_dispatcher_body "$2" "$3" "$4"
    ' legacy-dispatcher "$old_lib" "$payload" \
      'core-rules/githooks/pre-push' "$manifest"
  )" || return 1
  printf '%s\n' "$legacy_post" > "$managed/post-checkout" || return 1
  printf '%s\n' "$legacy_pre" > "$managed/pre-push" || return 1
  chmod 700 "$managed/post-checkout" "$managed/pre-push"
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

# shellcheck source=scripts/tests/helpers/hfs-volume.bash
. "$BATS_TEST_DIRNAME/helpers/hfs-volume.bash"

teardown() {
  rm -rf "$ROOT"
  hfs_volume_detach
}

# T39: HFS+ cannot hard-link a symlink (ENOTSUP); the commit publishes it by
# the exclusive, inode-keeping rename and the owner record still verifies.
@test "on a real HFS+ volume a symlink artifact attaches and its ownership verifies" {
  hfs_volume_attach
  local apfs_root="$ROOT" leaf='-leaf with spaces'
  TMPDIR="$HFS_MNT" setup
  rm -rf "$apfs_root"
  python3 -I -c 'import os,sys
os.symlink("t", sys.argv[1] + "/probe-stage")
try:
    os.link(sys.argv[1] + "/probe-stage", sys.argv[1] + "/probe-link", follow_symlinks=False)
except OSError as e:
    sys.exit(0 if e.errno == 45 else 1)
sys.exit("this volume can hard-link symlinks; the fallback is not exercised")' "$ROOT"
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" --arg leaf "$leaf" '
    .artifacts[0].path = $leaf
    | .artifacts += [{path:"parent with spaces",kind:"parent"},
                    {path:("parent with spaces/" + $leaf),kind:"symlink",target:$leaf}]'
  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cmp "$SOURCE_FILE" "$PROJECT/$leaf"
  _attachment_symlink_matches "$PROJECT/parent with spaces/$leaf" "$leaf"
  [ -z "$(find "$PROJECT" -name '.*attachment-stage-*')" ]
  run _attachment_verify_owner_artifacts "$OWNER"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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

@test "NUL artifact fields preserve spaces quotes backslashes and leading dashes through ownership" {
  local leaf='-leaf with '\''single'\'' "double" quotes\slash' record
  make_plan "$PLAN" file
  rewrite_json_0600 "$PLAN" --arg leaf "$leaf" '
    .artifacts[0].path = $leaf
    | .artifacts += [{path:"parent with spaces",kind:"parent"},
                    {path:("parent with spaces/" + $leaf),kind:"symlink",target:$leaf}]'
  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  [ "$status" -eq 0 ]
  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  [ "$status" -eq 0 ]
  cmp "$SOURCE_FILE" "$PROJECT/$leaf"
  _attachment_symlink_matches "$PROJECT/parent with spaces/$leaf" "$leaf"
  run _attachment_verify_owner_artifacts "$OWNER"
  [ "$status" -eq 0 ]
  run _attachment_verify_detach_owner_artifacts "$OWNER"
  [ "$status" -eq 0 ]
  record="$(jq -c . "$PLAN")"
  run _attachment_validate_destinations_absent "$record"
  [ "$status" -eq 3 ]
  printf 'drift\n' > "$PROJECT/$leaf"
  run _attachment_verify_owner_artifacts "$OWNER"
  [ "$status" -eq 3 ]
  run _attachment_verify_detach_owner_artifacts "$OWNER"
  [ "$status" -eq 3 ]
}

@test "NUL destination decoding keeps tabs embedded and trailing newlines in one path" {
  local leaf record
  for leaf in $'-tab\tleaf' $'-line\nleaf' $'-trailing\n'; do
    make_plan "$PLAN" file
    rewrite_json_0600 "$PLAN" --arg leaf "$leaf" '.artifacts[0].path = $leaf'
    record="$(jq -c . "$PLAN")"
    run _attachment_validate_destinations_absent "$record"
    [ "$status" -eq 0 ]
    printf 'collision\n' > "$PROJECT/$leaf"
    run _attachment_validate_destinations_absent "$record"
    [ "$status" -eq 3 ]
    rm -- "$PROJECT/$leaf"
    # Decoding does not widen the public plan schema's control-byte policy.
    run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
    [ "$status" -eq 4 ]
    [ ! -e "$JOURNAL" ]
  done
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

@test "item8 r3: attachment and doctor reject managed hooksPath plus a trailing empty value" {
  prepare_plan all
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  prepare_managed_hooks
  source "$BATS_TEST_DIRNAME/../lib/health-checks.sh"
  local managed="$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID"

  # Pin normal single-value behavior at every reader caller before adding drift.
  run _attachment_hooks_current_path "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = "$managed" ]
  run _attachment_hooks_authority "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
  [ "$output" = managed ]
  run attachment_verify "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
  run hc_portable_hooks_path "$TRELLIS_HOME" "$PROJECT" "$CHECKOUT_ID" "$OWNER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"core.hooksPath matches the Trellis managed dispatcher"* ]] || { echo "$output"; false; }

  git -C "$PROJECT" config --local --add core.hooksPath ''
  [ "$(git -C "$PROJECT" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" -eq 2 ]
  run _attachment_hooks_current_path "$PROJECT"
  [ "$status" -eq 3 ]
  run _attachment_hooks_authority "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 3 ]
  run attachment_verify "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 3 ]
  run hc_portable_hooks_path "$TRELLIS_HOME" "$PROJECT" "$CHECKOUT_ID" "$OWNER"
  [ "$status" -eq 1 ]
  [[ "$output" != *"core.hooksPath matches the Trellis managed dispatcher"* ]] || { echo "$output"; false; }
  [[ "$output" == *"multiple local core.hooksPath values in "*"; the Trellis managed dispatcher is $managed — restore with: git config --replace-all core.hooksPath $managed"* ]] || { echo "$output"; false; }
}

@test "verification accepts authentic dispatchers from an older payload and rejects tampered bytes" {
  local current_post current_pre older_post older_pre
  RELEASE="1.2.2"
  prepare_plan all
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  prepare_managed_hooks
  current_post=$(cat "$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID/post-checkout")
  current_pre=$(cat "$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID/pre-push")
  prepare_older_managed_hooks
  older_post=$(cat "$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID/post-checkout")
  older_pre=$(cat "$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID/pre-push")

  [ "$older_post" != "$current_post" ]
  [ "$older_pre" != "$current_pre" ]
  # Authentic OLD, not merely different bytes: the aged payload generator really
  # produced a complete dispatcher, and it is the historical shape (no
  # bypass-marker passthrough) while the current generator emits one.
  printf '%s\n' "$older_post" | grep -qx '# trellis-managed-dispatcher-body'
  printf '%s\n' "$older_pre" | grep -qx '# trellis-managed-dispatcher-body'
  # Counted, not `! grep`: bash errexit never fires on a `!`-inverted command,
  # so a negated grep here would assert nothing.
  [ "$(printf '%s\n' "$current_post" | grep -c 'TRELLIS_ALLOW_MAIN_PUSH')" -gt 0 ]
  [ "$(printf '%s\n' "$older_post" | grep -c 'TRELLIS_ALLOW_MAIN_PUSH')" -eq 0 ]
  [ "$(printf '%s\n' "$older_pre" | grep -c 'TRELLIS_ALLOW_MAIN_PUSH')" -eq 0 ]
  run attachment_verify "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]

  printf '%s\n' '# tampered dispatcher' >> "$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID/post-checkout"
  run attachment_verify "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 3 ]
}
@test "exclude verification accepts foreign bytes but refuses managed-block tampering" {
  local common="$ROOT/common" before="$ROOT/exclude-before" after="$ROOT/exclude-after"
  local block="$ROOT/managed-block" exclude foreign_before foreign_after state with_foreign
  mkdir -p "$common/info"
  source "$BATS_TEST_DIRNAME/../lib/trellis-home.sh"
  TRELLIS_LIBS_PRELOADED=1
  source "$BATS_TEST_DIRNAME/../attach-project.sh"

  cat > "$block" <<'EOF'
# --- Trellis local attachment exclude block ---
/.trellis/runtime
# --- end Trellis local attachment exclude block ---
EOF
  printf '%s\n' '# pre-existing user ignore' > "$before"
  cat "$before" "$block" > "$after"
  exclude="$common/info/exclude"
  foreign_before="$ROOT/foreign-exclude-before"
  foreign_after="$ROOT/foreign-exclude-after"
  printf 'foreign prefix embeds %s in arbitrary bytes\n' "$ATTACH_EXCLUDE_BEGIN" > "$foreign_before"
  printf 'foreign suffix embeds %s in arbitrary bytes\n' "$ATTACH_EXCLUDE_END" > "$foreign_after"
  cat "$before" "$foreign_before" "$block" "$foreign_after" > "$exclude"
  with_foreign="$ROOT/exclude-with-foreign"
  cp "$exclude" "$with_foreign"

  state="$(attach_exclude_state "$common" "$before" "$after" true true true "$block")"
  [ -n "$state" ]
  cat "$block" >> "$exclude"
  run attach_exclude_verify_state "$state"
  [ "$status" -eq 3 ]
  cp "$with_foreign" "$exclude"
  run attach_exclude_verify_state "$state"
  [ "$status" -eq 0 ]
  cmp -s "$with_foreign" "$exclude"
  grep -Fq 'foreign prefix embeds' "$exclude"
  grep -Fq 'foreign suffix embeds' "$exclude"

  sed 's|^/\.trellis/runtime$|/.trellis/runtime-tampered|' "$exclude" > "$exclude.tmp"
  mv "$exclude.tmp" "$exclude"
  run attach_exclude_verify_state "$state"
  [ "$status" -eq 3 ]
  grep -Fq 'foreign prefix embeds' "$exclude"
  grep -Fq 'foreign suffix embeds' "$exclude"
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

@test "Darwin user destination safety rejects case-insensitive TRELLIS_HOME aliases" {
  user_home="$ROOT/user-home"
  trellis_home="$user_home/.trellis"
  mkdir -p "$trellis_home"
  uname() { printf 'Darwin\n'; }

  run _attachment_user_destination_safe "$user_home" "$trellis_home" "$user_home/.TRELLIS/runtime"

  [ "$status" -eq 4 ]
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

@test "project metadata including resolved toolchain PATH round-trips through journal and owner" {
  local toolchain_path
  make_plan "$PLAN" file
  toolchain_path="$(_attachment_toolchain_path_resolve "$ROOT")"
  rewrite_json_0600 "$PLAN" --argjson toolchain_path "$toolchain_path" \
    '.surface = "project" | .toolchain_path = $toolchain_path'

  run attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.surface' "$JOURNAL")" = project ]
  [ "$(jq -r '.toolchain_path | join(":")' "$JOURNAL")" = "$ROOT" ]

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.surface' "$OWNER")" = project ]
  [ "$(jq -r '.toolchain_path | join(":")' "$OWNER")" = "$ROOT" ]
  run attachment_verify "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
}

@test "recovery upgrades a legacy pending record without parent identity under lock" {
  prepare_plan file
  stage=$(pending_stage_path)
  stage_pending_file "$stage"
  rewrite_json_0600 "$JOURNAL" 'del(.pending.parent_identity)'

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$stage" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$JOURNAL" ]
}

@test "recovery reclaims an unrecorded staged directory before rolling back its prefix" {
  prepare_plan all
  cp "$SOURCE_FILE" "$PROJECT/attached.txt"
  ln -s target.txt "$PROJECT/link.txt"
  stage=$(_attachment_stage_path "$PROJECT" "empty" "$ATTACHMENT_ID")
  mkdir "$stage"
  parent_identity=$(_attachment_fs_identity "$PROJECT")
  rewrite_json_0600 "$JOURNAL" --arg stage "$stage" --arg parent_identity "$parent_identity" '
    .phase = 2
    | .applied = .artifacts[0:2]
    | .pending = {
        artifact:.artifacts[2],staging_path:$stage,staging_identity:null,
        destination_identity:null,parent_identity:$parent_identity
      }
  '

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$stage" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$PROJECT/link.txt" ]
  [ ! -e "$JOURNAL" ]
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

# Inversion: the pending artifact carries ~1.3 MB of content_base64. Passed as
# `jq --argjson pending`, exec fails E2BIG on macOS; the failed substitution
# reads as "no journaled stage removal" and recovery only reaches the same end
# state by a later path, printing `Argument list too long` on the way.
@test "recovery finishes a journaled stage removal for a pending artifact over ARG_MAX" {
  content="$ROOT/large-content.txt"
  head -c 1000000 /dev/zero | tr '\0' x > "$content"
  base64 < "$content" | tr -d '\n' > "$ROOT/large-content.b64"
  jq -n \
    --arg fleet "$FLEET" --arg project_id "$PROJECT_ID" \
    --arg checkout_id "$CHECKOUT_ID" --arg worktree_id "$WORKTREE_ID" \
    --arg attachment_id "$ATTACHMENT_ID" --arg root "$PROJECT" --arg release "$RELEASE" \
    --arg sha256 "$(sha256_file "$content")" --rawfile content "$ROOT/large-content.b64" \
    '{schema_version:1,status:"prepared",fleet:$fleet,project_id:$project_id,
      checkout_id:$checkout_id,worktree_id:$worktree_id,attachment_id:$attachment_id,
      project_root:$root,worktree_root:$root,release:$release,
      artifacts:[{path:"attached.txt",kind:"file",content_base64:$content,sha256:$sha256,mode:"0644"}]}' > "$PLAN"
  chmod 600 "$PLAN"
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  [ "$(jq -c '.pending' "$JOURNAL" | wc -c)" -lt 1048576 ]
  stage=$(pending_stage_path)
  stage_pending_file "$stage"
  [ "$(jq -c '.pending' "$JOURNAL" | wc -c)" -gt 1048576 ]
  cp "$content" "$stage"
  record_stage_identity "$stage"
  _attachment_set_removal_intent "$JOURNAL" "$stage"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'Argument list too long'* ]] || { echo "$output"; false; }
  [ ! -e "$stage" ]
  [ ! -e "$PROJECT/attached.txt" ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$OWNER" ]
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

@test "lean-wt-remove: the claim layout derives its token afresh, never from an inherited memo" {
  prepare_plan file
  cp "$SOURCE_FILE" "$PROJECT/attached.txt"
  set_applied_prefix 1
  _attachment_set_removal_intent "$JOURNAL" "$PROJECT/attached.txt"
  _attachment_journal_claim_layout "$JOURNAL" "$PROJECT/attached.txt"
  local expected=$_ATTACHMENT_QUARANTINE nonce
  nonce=$(jq -r '.removal.nonce' "$JOURNAL")
  # A planted memo for this exact input survives neither a fresh source nor
  # an exported environment.
  run env _ATTACHMENT_CLAIM_TOKEN_INPUT="$nonce:$PROJECT/attached.txt" \
    _ATTACHMENT_CLAIM_TOKEN=0000000000000000000000000000000000000000000000000000000000000000 \
    bash -c '. "$1" && _attachment_journal_claim_layout "$2" "$3" && printf "%s\n" "$_ATTACHMENT_QUARANTINE"' _ \
    "$BATS_TEST_DIRNAME/../lib/attachment.sh" "$JOURNAL" "$PROJECT/attached.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  # In-process reuse is keyed by the exact input: another path is hashed anew.
  _attachment_claim_layout "$PROJECT/other.txt" "$nonce"
  [ "$_ATTACHMENT_QUARANTINE" = "$PROJECT/.trellis-attachment-remove-$(printf '%s' "$nonce:$PROJECT/other.txt" | shasum -a 256 | cut -d ' ' -f 1)" ]
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

# Two acquirers both pass the "link absent" check, then reach `ln` one after
# the other: the first publishes its holder link, the second must refuse busy.
# Without no-dereference, the second `ln` follows the first link into the
# holder directory, creates its entry there and reports success.
lock_rendezvous() {
  local kind=$1 work
  work="$(mktemp -d "$BATS_TEST_TMPDIR/rendezvous.XXXXXX")"
  work="$(canonical_dir "$work")"
  env T="$work" KIND="$kind" LIB="$BATS_TEST_DIRNAME/../lib/attachment.sh" bash </dev/null <<'SH'
. "$LIB"
home="$T/home"; common="$T/common"; mkdir "$home" "$common"; chmod 700 "$home"
_attachment_prepare_state "$home" || exit 1
checkout=$(_attachment_hash_text "$common")
worktree=$(_attachment_hash_text "$T/worktree")
case "$KIND" in
  checkout) link=$(_attachment_checkout_lock_path "$home" "$checkout") ;;
  transaction) link=$(_attachment_lock_path "$home" "$checkout" "$worktree") ;;
  user) link=$(_attachment_user_lock_path "$home") ;;
esac
worker() (
  role=$1
  ln() {
    : > "$T/ready-$role"
    until [ -f "$T/go-$role" ]; do sleep 0.02; done
    command ln "$@"
  }
  case "$KIND" in
    checkout) _attachment_checkout_lock_acquire "$home" "$checkout" "$common"; rc=$?
      holder=${_ATTACHMENT_CHECKOUT_LOCK_HOLDER:-} ;;
    transaction) _attachment_lock_acquire "$home" "$checkout" "$worktree" "00000000-0000-4000-8000-00000000000$2"; rc=$?
      holder=${_ATTACHMENT_LOCK_HOLDER:-} ;;
    user) _attachment_user_lock_acquire "$home" "00000000-0000-4000-8000-00000000000$2"; rc=$?
      holder=${_ATTACHMENT_USER_LOCK_HOLDER:-} ;;
  esac
  printf '%s %s\n' "$rc" "$holder" > "$T/result-$role"
  until [ -f "$T/stop" ]; do sleep 0.05; done
)
wait_for() { local n=0; until [ -f "$1" ] || [ "$n" -ge 500 ]; do sleep 0.02; n=$((n + 1)); done; [ -f "$1" ]; }
worker A 1 & a=$!
worker B 2 & b=$!
trap ': > "$T/stop"; wait "$a" "$b" 2>/dev/null' EXIT
wait_for "$T/ready-A" && wait_for "$T/ready-B" || { echo 'rendezvous failed'; exit 1; }
: > "$T/go-A"; wait_for "$T/result-A" || exit 1
: > "$T/go-B"; wait_for "$T/result-B" || exit 1
read -r rc_a holder_a < "$T/result-A"
read -r rc_b holder_b < "$T/result-B"
printf 'A=%s B=%s\n' "$rc_a" "$rc_b"
printf 'target=%s holderA=%s\n' "$(readlink "$link")" "$(basename "$holder_a")"
printf 'entries=%s\n' "$(ls -A "$holder_a" | tr '\n' ' ')"
SH
}

assert_one_lock_winner() {
  run lock_rendezvous "$1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = 'A=0 B=3' ] || { echo "$output"; return 1; }
  [[ "${lines[1]}" =~ ^target=(.+)\ holderA=(.+)$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] ||
    { echo "$output"; return 1; }
  [ "${lines[2]}" = 'entries=owner.json ' ] || { echo "$output"; return 1; }
}

@test "checkout lock: acquirers that meet at ln get one winner and a busy refusal" {
  assert_one_lock_winner checkout
}

@test "transaction lock: acquirers that meet at ln get one winner and a busy refusal" {
  assert_one_lock_winner transaction
}

@test "user lock: acquirers that meet at ln get one winner and a busy refusal" {
  assert_one_lock_winner user
}

@test "fork-free dirname basename and control-byte helpers match the real tools on an edge corpus" {
  local shell seen=''
  for shell in /bin/bash "$(command -v bash)"; do
    [ -x "$shell" ] || continue
    case " $seen " in *" $shell "*) continue ;; esac
    seen="$seen $shell"
    run "$shell" "$BATS_TEST_DIRNAME/helpers/builtin-differential.bash" "$BATS_TEST_DIRNAME/../.."
    [ "$status" -eq 0 ]
    [[ "$output" == *": 0 mismatches" ]]
  done
  [ -n "$seen" ]
}

t56_native_render_fixture() {
  local repo="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)" digest target=aarch64-apple-darwin
  export HOME="$BATS_TEST_TMPDIR/context user 'quoted;value"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/context-trellis"
  T56_PAYLOAD="$BATS_TEST_TMPDIR/render-payload"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME" "$T56_PAYLOAD/core-rules/templates"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  cp -R "$repo/core-rules/native" "$T56_PAYLOAD/core-rules/native"
  digest="$(jq -r --arg target "$target" '.assets[$target].sha256' "$T56_PAYLOAD/core-rules/native/artifacts.json")"
  T56_COMPANION="$TRELLIS_HOME/bin/native/1.5.0/$target/$digest/trellis-hooks"
  mkdir -p "${T56_COMPANION%/*}"
  cp "$T56_PAYLOAD/core-rules/native/$target/trellis-hooks" "$T56_COMPANION"
  chmod 500 "$T56_COMPANION"
  python3 -I - "$repo/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis" "$T56_COMPANION" "$digest" <<'PY'
from pathlib import Path
import sys
source,dest,entry,digest=sys.argv[1:]
s=Path(source).read_text(); q=lambda x:"'"+x.replace("'", "'\\''")+"'"
for k,v in (('launcher_native_entry',entry),('launcher_native_sha256',digest),('launcher_native_version','1.5.0')):
    s=s.replace(k+"=''\n",k+'='+q(v)+'\n')
p=Path(dest); p.write_text(s); p.chmod(0o755)
PY
  T56_CONTEXT="$(attachment_contextual_render_context "$TRELLIS_HOME")"
}

@test "T56 legacy provider matches captured pre-native renders and declares only T67" {
  local repo="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)" provider capture template version source context
  provider="$repo/core-rules/legacy-hooks"
  capture="$(jq -r '.capture_commit' "$provider/manifest.json")"
  mkdir -p "$BATS_TEST_TMPDIR/reference"
  git -C "$repo" show "$capture:scripts/lib/attachment.sh" > "$BATS_TEST_TMPDIR/reference/attachment.sh"
  t56_native_render_fixture
  context="$T56_CONTEXT"
  for template in claude-settings.local.json codex-hooks.local.json claude-user-settings.json; do
    source="$BATS_TEST_TMPDIR/reference/$template"
    git -C "$repo" show "$capture:core-rules/templates/$template" > "$source"
    cmp -s "$source" "$provider/$template"
    for version in 2.1.295 2.1.294; do
      bash -c '. "$1"; version=$6; attachment_claude_code_version() { printf "%s\n" "$version"; }; attachment_contextual_template_select "$2" "$3" "$4" "$5"' \
        _ "$repo/scripts/lib/attachment.sh" "$provider/$template" "core-rules/templates/$template" "$context" "$PROJECT" "$version" > "$BATS_TEST_TMPDIR/provider-render"
      bash -c '. "$1"; TRELLIS_LIBS_PRELOADED=1; . "$2"; version=$6; attachment_claude_code_version() { printf "%s\n" "$version"; }; attachment_contextual_template_render "$3" "$4" "$5"' \
        _ "$repo/scripts/lib/attachment.sh" "$BATS_TEST_TMPDIR/reference/attachment.sh" "$source" "core-rules/templates/$template" "$context" "$version" > "$BATS_TEST_TMPDIR/reference-render"
      cmp -s "$BATS_TEST_TMPDIR/reference-render" "$BATS_TEST_TMPDIR/provider-render"
    done
  done
  python3 -I - "$repo" "$provider" <<'PY'
import hashlib,json,pathlib,subprocess,sys
repo,base=map(pathlib.Path,sys.argv[1:]); d=json.loads((base/'declared-deltas.json').read_text())
read=lambda ref,name:subprocess.check_output(['git','-C',str(repo),'show',ref+':core-rules/templates/'+name])
compact=lambda x:json.dumps(x,sort_keys=True,separators=(',',':')).encode()
assert len(d['deltas'])==1 and d['deltas'][0]['id']=='T67'
x=d['deltas'][0]; old=json.loads(read(d['base_commit'],x['file'])); new=json.loads((base/x['file']).read_bytes())
a=old['hooks']['UserPromptExpansion']; b=new['hooks']['UserPromptExpansion']
assert hashlib.sha256(compact(a)).hexdigest()==x['before_sha256']
assert hashlib.sha256(compact(b)).hexdigest()==x['after_sha256']
assert b[0]['hooks'][0]['timeout']==30 and b[0]['hooks'][0]['onFailure']=='block'
assert 'guard-supervise.pl' in b[0]['hooks'][0]['args'][-4]
old['hooks']['UserPromptExpansion']=b
assert old==new, 'undeclared semantic delta from 1.4.1'
for name in ('codex-hooks.local.json','claude-user-settings.json'):
    assert read(d['base_commit'],name)==(base/name).read_bytes(), 'undeclared legacy byte delta'
PY
}

@test "T56 native architecture miss selects the complete pinned legacy surface" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin candidate rendering fixture'
  t56_native_render_fixture
  local repo="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)" source
  cp -R "$repo/core-rules/legacy-hooks" "$T56_PAYLOAD/core-rules/legacy-hooks"
  source="$T56_PAYLOAD/core-rules/templates/claude-settings.local.json"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"__TRELLIS_LAUNCHER__","args":["hook","event","claude","PreToolUse"],"timeout":30,"onFailure":"block"}]}]}}' > "$source"
  jq '.assets = {}' "$T56_PAYLOAD/core-rules/native/artifacts.json" > "$BATS_TEST_TMPDIR/no-target"
  cp "$BATS_TEST_TMPDIR/no-target" "$T56_PAYLOAD/core-rules/native/artifacts.json"
  attachment_claude_on_failure_supported() { return 0; }
  attachment_contextual_template_select "$source" core-rules/templates/claude-settings.local.json "$T56_CONTEXT" "$PROJECT" > "$BATS_TEST_TMPDIR/fallback" 2> "$BATS_TEST_TMPDIR/fallback-label"
  attachment_contextual_template_render_impl "$T56_PAYLOAD/core-rules/legacy-hooks/claude-settings.local.json" core-rules/templates/claude-settings.local.json "$T56_CONTEXT" "$PROJECT" > "$BATS_TEST_TMPDIR/legacy-reference"
  # T34: the complete pinned legacy hook surface; every other key comes from
  # the current template (here: none), as on the native route.
  jq -e --slurpfile ref "$BATS_TEST_TMPDIR/legacy-reference" '.hooks == $ref[0].hooks and (keys == ["hooks"])' \
    "$BATS_TEST_TMPDIR/fallback" >/dev/null
  jq '.note = "kept"' "$source" > "$source.next" && mv "$source.next" "$source"
  attachment_contextual_template_select "$source" core-rules/templates/claude-settings.local.json "$T56_CONTEXT" "$PROJECT" > "$BATS_TEST_TMPDIR/fallback-keyed" 2>/dev/null
  jq -e --slurpfile ref "$BATS_TEST_TMPDIR/legacy-reference" '.hooks == $ref[0].hooks and .note == "kept"' \
    "$BATS_TEST_TMPDIR/fallback-keyed" >/dev/null
  grep -F 'legacy fallback: native selection miss 10' "$BATS_TEST_TMPDIR/fallback-label"
  jq -e 'has("hooks") and (.hooks | has("Stop") and has("UserPromptExpansion") and has("PostToolUse"))' "$BATS_TEST_TMPDIR/fallback" >/dev/null
}

@test "T56 contextual native renders every event and all three surfaces with exact argv" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin candidate rendering fixture'
  t56_native_render_fixture
  attachment_claude_on_failure_supported() { return 0; }
  local template source harness result
  for template in claude-settings.local.json codex-hooks.local.json claude-user-settings.json; do
    harness=claude; [ "$template" != codex-hooks.local.json ] || harness=codex
    source="$T56_PAYLOAD/core-rules/templates/$template"
    jq -n --arg harness "$harness" '{hooks:(["PreToolUse","PostToolUse","UserPromptSubmit","SessionStart","Stop","PreCompact"] | map(. as $event | {key:$event,value:[{hooks:[({type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event",$harness,$event],timeout:30} + (if $harness == "claude" then {onFailure:"block"} else {} end))]}]}) | from_entries)}' > "$source"
    run attachment_contextual_template_render "$source" "core-rules/templates/$template" "$T56_CONTEXT" "$PROJECT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    result="$BATS_TEST_TMPDIR/$template.rendered"; printf '%s\n' "$output" > "$result"
    if [ "$harness" = claude ]; then
      # R1 PATH ruling: PostToolUse and Stop are the shell form forwarding the
      # caller PATH as data; every other Claude event is the R1 exec form.
      jq -e --arg companion "$T56_COMPANION" --arg root "$(if [ "$template" = claude-user-settings.json ]; then printf '%s' "$HOME"; else printf '%s' "$PROJECT"; fi)" '
        # I-A3 Q: always single-quoted, an embedded quote as '"'"'\'"'"''"'"'.
        def q: "'"'"'" + gsub("'"'"'"; "'"'"'\\'"'"''"'"'") + "'"'"'";
        all(.hooks | to_entries[] | .key as $event | .value[] | .hooks[] | {e: $event, h: .};
          .e as $e
          | if $e == "PostToolUse" or $e == "Stop" then
            (.h | has("args") | not) and .h.onFailure == "block"
            and (.h.command | startswith("/usr/bin/env -i HOME=") and contains(" \"TRELLIS_CALLER_PATH=$PATH\" ")
              and endswith(($companion | q) + " event-client claude " + $e + " " + ($root | q)))
          else
            .h.command == "/usr/bin/env" and .h.args[4] == $companion and .h.args[5] == "event-client" and .h.args[8] == $root and .h.onFailure == "block"
          end)' "$result" >/dev/null
    else
      jq -e 'all(.hooks[][] | .hooks[]; (has("args") | not) and (has("onFailure") | not) and (.command | startswith("HOME=")))' "$result" >/dev/null
    fi
  done
}

@test "T56 contextual native refuses drifted own companion bytes and misplaced markers" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin candidate rendering fixture'
  t56_native_render_fixture
  attachment_claude_on_failure_supported() { return 0; }
  local source="$T56_PAYLOAD/core-rules/templates/claude-settings.local.json"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"__TRELLIS_LAUNCHER__","args":["hook","event","claude","PreToolUse"],"timeout":30,"onFailure":"block"}]}]}}' > "$source"
  chmod u+w "$T56_COMPANION"
  printf 'changed companion' >> "$T56_COMPANION"
  chmod 500 "$T56_COMPANION"
  run attachment_contextual_template_render "$source" core-rules/templates/claude-settings.local.json "$T56_CONTEXT" "$PROJECT"
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"__TRELLIS_HOME__","hooks":[{"type":"command","command":"echo __TRELLIS_HOME__"}]}]}}' > "$source"
  run attachment_contextual_template_render "$source" core-rules/templates/claude-settings.local.json "$T56_CONTEXT" "$PROJECT"
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
}

@test "B1 review M3 renderer resolves trusted source and launcher directory roots once" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'Darwin candidate rendering fixture'
  t56_native_render_fixture
  local alias="$BATS_TEST_TMPDIR/render-alias" source
  mv "$HOME/.local/bin" "$BATS_TEST_TMPDIR/actual-launchers"
  ln -s "$BATS_TEST_TMPDIR/actual-launchers" "$HOME/.local/bin"
  T56_CONTEXT="$(attachment_contextual_render_context "$TRELLIS_HOME")"
  ln -s "$T56_PAYLOAD" "$alias"
  source="$alias/core-rules/templates/claude-settings.local.json"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"__TRELLIS_LAUNCHER__","args":["hook","event","claude","PreToolUse"],"timeout":30,"onFailure":"block"}]}]}}' > "$source"
  run attachment_contextual_template_render "$source" core-rules/templates/claude-settings.local.json "$T56_CONTEXT" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "B1 M-A1 merge-base replaces adopted prefixes and records only residuals for changed values" {
  local base="$BATS_TEST_TMPDIR/adopted-base.json" original="$BATS_TEST_TMPDIR/adopted-original.json" template="$BATS_TEST_TMPDIR/adopted-next.json" keys result
  printf '%s\n' '{"managed":"old","project":true,"hooks":{"WorktreeCreate":[{"hooks":[{"command":"kept-hook"},{"command":"project-R"}]}]}}' > "$base"
  printf '%s\n' '{"managed":"old","hooks":{"WorktreeCreate":[{"hooks":[{"command":"kept-hook"}]}]}}' > "$original"
  printf '%s\n' '{"managed":"new","hooks":{"WorktreeCreate":[{"hooks":[{"command":"kept-hook"},{"command":"added-hook"}]}]}}' > "$template"
  keys='[{"path":["managed"],"value":"old"},{"path":["hooks","WorktreeCreate"],"value":[{"hooks":[{"command":"kept-hook"}]}]}]'
  run settings_owned_json merge-base "$base" "$keys" "$template" "$original" '[]'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  result="$output"
  printf '%s\n' "$result" | jq -e '.after.managed=="new" and [.after.hooks.WorktreeCreate[].hooks[].command]==["kept-hook","added-hook","project-R"] and (.before | has("managed") | not) and [.before.hooks.WorktreeCreate[].hooks[].command]==["project-R"]' >/dev/null
  printf '%s\n' "$result" | jq '.before' > "$BATS_TEST_TMPDIR/residual-before.json"
  printf '%s\n' "$result" | jq '.after' > "$BATS_TEST_TMPDIR/adopted-after.json"
  keys="$(printf '%s\n' "$result" | jq -c '.owned_keys')"
  run settings_owned_json inverse "$BATS_TEST_TMPDIR/adopted-after.json" "$keys" '' "$BATS_TEST_TMPDIR/residual-before.json" '[]'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | jq -e '.project==true and (has("managed") | not) and [.hooks.WorktreeCreate[].hooks[].command]==["project-R"]' >/dev/null
}

@test "B1 review L3 ownership drift and subtraction share type-strict numeric comparison" {
  local base="$BATS_TEST_TMPDIR/typed.json" template="$BATS_TEST_TMPDIR/typed-template.json" keys
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"command":"owned","timeout":30.0}]}]}}' > "$base"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"command":"new","timeout":30}]}]}}' > "$template"
  keys='[{"path":["hooks","Stop"],"value":[{"hooks":[{"command":"owned","timeout":30}]}]}]'
  run attach_detach_json_keys_detail "$base" "$keys"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | jq -e '.[0].state == "changed"' >/dev/null
  run settings_owned_json merge "$base" "$keys" "$template"
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
}

@test "T56 owned-only merge preserves appended project hooks through inverse" {
  local base="$BATS_TEST_TMPDIR/base.json" template="$BATS_TEST_TMPDIR/template.json" keys result
  printf '%s\n' '{"project":true,"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"old-guard"},{"type":"command","command":"project-hook"}]},{"hooks":[{"type":"command","command":"project-block"}]}]}}' > "$base"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"new-guard"}]}]}}' > "$template"
  keys='[{"path":["hooks","PreToolUse"],"value":[{"matcher":"Bash","hooks":[{"type":"command","command":"old-guard"}]}]}]'
  run settings_owned_json merge "$base" "$keys" "$template"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  result="$output"
  printf '%s\n' "$result" | jq -e '.after.project == true and [.after.hooks.PreToolUse[].hooks[].command] == ["new-guard","project-hook","project-block"]' >/dev/null
  printf '%s\n' "$result" | jq '.after' > "$BATS_TEST_TMPDIR/merged.json"
  keys="$(printf '%s\n' "$result" | jq -c '.owned_keys')"
  run settings_owned_json inverse "$BATS_TEST_TMPDIR/merged.json" "$keys"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | jq -e '.project == true and [.hooks.PreToolUse[].hooks[].command] == ["project-hook","project-block"]' >/dev/null
}

@test "T56 local and user inverse helpers preserve appended project event members" {
  local file="$PROJECT/t56-settings.json" keys render user_result local_result repo
  repo="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  keys='[{"path":["hooks","PreToolUse"],"value":[{"hooks":[{"command":"owned-guard"}]}]}]'
  printf '%s\n' '{"project":true,"hooks":{"PreToolUse":[{"hooks":[{"command":"owned-guard"},{"command":"project-hook"}]}]}}' > "$file"
  chmod 600 "$file"
  render="$(jq -cn --arg destination "$file" --argjson keys "$keys" '{destination:$destination,owned_keys:$keys,created_paths:[["hooks"]],before_exists:false,before_mode:null,before_base64:"",before_sha256:"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",after_sha256:("0"*64),after_mode:"0600",mode:"0600"}')"
  user_result="$(_attachment_user_inverse_render_result "$render")"
  printf '%s\n' "$user_result" | jq -e '.result_base64 | @base64d | fromjson | .project == true and [.hooks.PreToolUse[].hooks[].command] == ["project-hook"]' >/dev/null
  local_result="$(TRELLIS_LIBS_PRELOADED=1; source "$repo/scripts/attach-project.sh"; attach_detach_inverse_render_json "$PROJECT" "$(printf '%s\n' "$render" | jq '.path="t56-settings.json" | del(.destination)')")"
  printf '%s\n' "$local_result" | jq -e '.result_base64 | @base64d | fromjson | .project == true and [.hooks.PreToolUse[].hooks[].command] == ["project-hook"]' >/dev/null
}

@test "T56 owned-only merge refuses positional drift and new project-key collisions" {
  local base="$BATS_TEST_TMPDIR/base.json" template="$BATS_TEST_TMPDIR/template.json" keys
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"command":"project-hook"},{"command":"old-guard"}]}]}}' > "$base"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"command":"new-guard"}]}]}}' > "$template"
  keys='[{"path":["hooks","PreToolUse"],"value":[{"hooks":[{"command":"old-guard"}]}]}]'
  run settings_owned_json merge "$base" "$keys" "$template"
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  printf '%s\n' '{"project":true}' > "$base"
  printf '%s\n' '{"project":false}' > "$template"
  run settings_owned_json merge "$base" '[]' "$template"
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
}

@test "render context check decodes exactly one fully valid JSON value" {
  local user_home="$ROOT/user" context quoted_user quoted_home quoted_launcher
  mkdir -p "$user_home/.local/bin"
  printf '#!/bin/sh\n' > "$user_home/.local/bin/trellis"
  chmod 755 "$user_home/.local/bin/trellis"
  quoted_user=$(attachment_contextual_posix_shell_quote "$user_home")
  quoted_home=$(attachment_contextual_posix_shell_quote "$TRELLIS_HOME")
  quoted_launcher=$(attachment_contextual_posix_shell_quote "$user_home/.local/bin/trellis")
  context=$(jq -cn --arg u "$user_home" --arg h "$TRELLIS_HOME" --arg l "$user_home/.local/bin/trellis" \
    --arg us "$quoted_user" --arg hs "$quoted_home" --arg ls "$quoted_launcher" \
    '{schema_version: 1, user_home: $u, trellis_home: $h, launcher: $l,
      user_home_shell: $us, trellis_home_shell: $hs, launcher_shell: $ls}')

  run attachment_contextual_render_context_validate "$context" "$TRELLIS_HOME"
  [ "$status" -eq 0 ]
  run attachment_contextual_render_context_validate "$context $context" "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  run attachment_contextual_render_context_validate "$context"$'\n''null' "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  run attachment_contextual_render_context_validate "$(printf '%s' "$context" | jq -c '.user_home_shell += "\n"')" "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  run attachment_contextual_render_context_validate "$(printf '%s' "$context" | jq -c '.extra = 1')" "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  run attachment_contextual_render_context_validate '' "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  run attachment_contextual_render_context_validate "$context" "$user_home"
  [ "$status" -eq 4 ]
}

@test "NUL field reader takes exactly one field per variable and strips trailing newlines" {
  local first second
  trellis_read_nul_fields first second < <(printf 'a\n\n\0b c\0')
  [ "$first" = a ]
  [ "$second" = 'b c' ]
  run trellis_read_nul_fields first second < <(printf 'a\0')
  [ "$status" -ne 0 ]
  run trellis_read_nul_fields first second < <(printf 'a\0b\0c\0')
  [ "$status" -ne 0 ]
  run trellis_read_nul_fields first second < <(printf 'a\0b\0tail')
  [ "$status" -ne 0 ]
  run trellis_read_nul_fields first second < <(printf 'a\0b')
  [ "$status" -ne 0 ]
}

# Exact permission bits, special bits included: BSD `%p` ends in the four
# octal permission digits; GNU `%a` prints them without leading zeros.
exact_mode_of() {
  local candidate
  candidate="$(stat -f %p "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -n "$candidate" ]; then
    candidate="${candidate#"${candidate%????}"}"
    candidate="${candidate#0}"
  else
    candidate="$(stat -c %a "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

# Nanosecond ctime, probed BSD first in a separate capture as mode_of does.
ctime_of() {
  local candidate
  candidate="$(stat -f %Fc "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-9.]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %z "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

# Seed MODE on a fresh directory owned by our own group (BSD drops setgid for
# a group we are not in), and prove the seed took so no case passes vacuously.
seed_private_dir_mode() {
  mkdir -p "$1"
  chgrp "$(id -g)" "$1"
  chmod "$2" "$1"
  [ "$(exact_mode_of "$1")" = "${2#0}" ] || { echo "seed $2 did not take on $1: $(exact_mode_of "$1")"; return 1; }
}

@test "private-dir preparers correct 0755 and special-bit directories to exactly 0700" {
  local mode home dir generic
  for mode in 0755 1700 2700 4700 6700 7700; do
    home="$ROOT/prep-home-$mode" dir="$ROOT/prep-dir-$mode" generic="$ROOT/prep-generic-$mode"
    seed_private_dir_mode "$home" "$mode"
    seed_private_dir_mode "$home/state" "$mode"
    seed_private_dir_mode "$dir" "$mode"
    seed_private_dir_mode "$generic" "$mode"
    _attachment_prepare_state "$home" || { echo "prepare_state refused from $mode"; false; }
    _attachment_ensure_private_dir "$dir" || { echo "ensure_private_dir refused from $mode"; false; }
    trellis_home_prepare_private_dir "$generic" "test directory" || { echo "prepare_private_dir refused from $mode"; false; }
    [ "$(exact_mode_of "$home")" = 700 ] || { echo "home from $mode: $(exact_mode_of "$home")"; false; }
    [ "$(exact_mode_of "$home/state")" = 700 ] || { echo "state from $mode: $(exact_mode_of "$home/state")"; false; }
    [ "$(exact_mode_of "$home/state/locks")" = 700 ]
    [ "$(exact_mode_of "$dir")" = 700 ] || { echo "dir from $mode: $(exact_mode_of "$dir")"; false; }
    [ "$(exact_mode_of "$generic")" = 700 ] || { echo "generic from $mode: $(exact_mode_of "$generic")"; false; }
  done
}

@test "private-dir preparers chmod when the exact-mode probe fails, even under errexit" {
  local work="$ROOT/probe" fn
  mkdir -p "$work"
  for fn in _attachment_prepare_state _attachment_ensure_private_dir trellis_home_prepare_private_dir; do
    seed_private_dir_mode "$work/once-$fn" 0700
    seed_private_dir_mode "$work/always-$fn" 0755
  done
  run env T="$work" LIB="$BATS_TEST_DIRNAME/../lib/attachment.sh" /bin/bash -e -c '
    . "$LIB"
    chmod() { printf "%s\n" "$*" >> "$T/chmod.log"; command chmod "$@"; }
    # once: the first probe of each path fails, later ones are real.
    # always: every probe fails, so the post-chmod verify cannot pass.
    find() {
      local marker
      case "$1" in
        "$T"/always-*) return 42 ;;
      esac
      marker="$T/probed-$(printf "%s" "$1" | cksum | cut -d " " -f 1)"
      if [ ! -e "$marker" ]; then : > "$marker"; return 42; fi
      command find "$@"
    }
    for fn in _attachment_prepare_state _attachment_ensure_private_dir trellis_home_prepare_private_dir; do
      : > "$T/chmod.log"
      "$fn" "$T/once-$fn" "test directory"
      grep -qxF "00700 $T/once-$fn" "$T/chmod.log" || { echo "$fn skipped the chmod after a failed probe"; exit 1; }
      echo "once $fn ok"
      : > "$T/chmod.log"
      if "$fn" "$T/always-$fn" "test directory"; then
        echo "$fn accepted a mode it could not verify"; exit 1
      fi
      grep -qxF "00700 $T/always-$fn" "$T/chmod.log" || { echo "$fn skipped the chmod after a failed probe"; exit 1; }
      echo "always $fn refused"
    done
    echo REACHED_END
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *REACHED_END* ]] || { echo "$output"; false; }
  for fn in _attachment_prepare_state _attachment_ensure_private_dir trellis_home_prepare_private_dir; do
    [ "$(exact_mode_of "$work/once-$fn")" = 700 ]
    [ "$(exact_mode_of "$work/always-$fn")" = 700 ]
  done
}

@test "private-dir preparers leave an exact 0700 directory's ctime alone" {
  # A same-mode GNU chmod moves ctime (BSD chmod skips the call); the show-config
  # registry drift token binds TRELLIS_HOME's ctime, so a no-op chmod by a
  # concurrent attach postjob read as a registry change.
  local home="$ROOT/still-home" dir="$ROOT/still-dir" generic="$ROOT/still-generic"
  local home_before dir_before generic_before
  mkdir -p "$home" "$dir" "$generic"
  _attachment_prepare_state "$home"
  chmod 700 "$home" "$dir" "$generic"
  home_before="$(ctime_of "$home")"
  dir_before="$(ctime_of "$dir")"
  generic_before="$(ctime_of "$generic")"
  [ -n "$home_before" ] && [ -n "$dir_before" ] && [ -n "$generic_before" ]
  # Let a coarse timestamp clock tick, so a chmod could not hide in the same tick.
  sleep 0.1
  _attachment_prepare_state "$home"
  _attachment_ensure_private_dir "$dir"
  trellis_home_prepare_private_dir "$generic" "test directory"
  [ "$(ctime_of "$home")" = "$home_before" ]
  [ "$(ctime_of "$dir")" = "$dir_before" ]
  [ "$(ctime_of "$generic")" = "$generic_before" ]
}

@test "private-dir preparers run no chmod on an exact 0700 directory" {
  # Tool independent: BSD chmod skips a same-mode call, so the ctime check
  # above only bites with GNU chmod; counting the calls bites everywhere,
  # whichever find or chmod flavour PATH resolves.
  local work="$ROOT/nochmod"
  mkdir -p "$work"
  run env T="$work" LIB="$BATS_TEST_DIRNAME/../lib/attachment.sh" /bin/bash -e -c '
    . "$LIB"
    mkdir "$T/home" "$T/dir" "$T/generic"
    _attachment_prepare_state "$T/home"
    command chmod 00700 "$T/home" "$T/dir" "$T/generic"
    chmod() { printf "%s\n" "$*" >> "$T/chmod.log"; command chmod "$@"; }
    : > "$T/chmod.log"
    _attachment_prepare_state "$T/home"
    _attachment_ensure_private_dir "$T/dir"
    trellis_home_prepare_private_dir "$T/generic" "test directory"
    if [ -s "$T/chmod.log" ]; then echo "unexpected chmod:"; cat "$T/chmod.log"; exit 1; fi
    echo REACHED_END
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *REACHED_END* ]] || { echo "$output"; false; }
}

@test "generated dispatcher quotes bypass-marker values against word splitting" {
  prepare_managed_hooks
  local body="$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID/pre-push"
  grep -Fq 'TRELLIS_ALLOW_MAIN_PUSH="${TRELLIS_ALLOW_MAIN_PUSH-}"' "$body" ||
    { echo "ALLOW_MAIN_PUSH is not quoted"; false; }
  grep -Fq 'SECURITY_GATE_SKIP="${SECURITY_GATE_SKIP-}"' "$body" ||
    { echo "SECURITY_GATE_SKIP is not quoted"; false; }
  ! grep -Fq 'TRELLIS_ALLOW_MAIN_PUSH=${TRELLIS_ALLOW_MAIN_PUSH-}' "$body" ||
    { echo "ALLOW_MAIN_PUSH is word-split"; false; }
  ! grep -Fq 'SECURITY_GATE_SKIP=${SECURITY_GATE_SKIP-}' "$body" ||
    { echo "SECURITY_GATE_SKIP is word-split"; false; }
}

@test "the recovery remedy preserves the bytes it says it preserved" {
  local journal="$ROOT/recovery-journal.json" destination="$ROOT/recovery-dest"
  local artifact repair
  printf '{"release":"1.2.3"}\n' > "$journal"
  artifact="$(jq -nc '{kind:"file",replace:{before_base64:"T1JJR0lOQUw=",before_mode:"0644"}}')"
  printf 'USER EDITS ONLY COPY\n' > "$destination"

  run _attachment_user_rollback_replace_conflict \
    "$TRELLIS_HOME" "$journal" attach "$destination" "$artifact" "1:2"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  repair="$(printf '%s\n' "$output" | sed -n 's/^trellis: user attachment recovery remedy: //p')"
  [ -n "$repair" ] || { echo "no remedy printed"; false; }

  run bash -c "$repair"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$destination")" = "ORIGINAL" ] || { echo "snapshot not restored"; false; }
  # The operator's edited bytes survive somewhere beside the destination.
  grep -Rl 'USER EDITS ONLY COPY' "$ROOT" | grep -v -F -x "$destination" | grep -q . ||
    { echo "edited bytes were destroyed"; false; }
}
