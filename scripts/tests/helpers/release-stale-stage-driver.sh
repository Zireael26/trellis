#!/bin/bash
# Exercise the real release transaction bodies, checkout lock and post-adopt
# stage sweep. The single TERM is injected by test-only external seams.
set -u
kind=$1
lock_mode=$2
root=$3
TEST_ROOT=$4
# shellcheck disable=SC1090
. "$root/scripts/lib/attachment.sh"

load_function() {
  local file=$1 name=$2 body
  body=$(awk -v name="$name" '$0 == name "() (" {p=1} p{print} p && /^\)$/{exit}' "$file")
  [ -n "$body" ] || { echo "function missing: $name" >&2; return 1; }
  eval "$body"
}
load_command_if_present() {
  local file=$1 name=$2 body
  body=$(awk -v name="$name" '$0 == name "() {" {p=1} p{print} p && /^}$/{exit}' "$file")
  [ -z "$body" ] || eval "$body"
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
signal_this_shell() { /bin/sh -c 'kill -TERM "$PPID"'; }
max_status() { if [ "$1" -gt "$2" ]; then printf %s "$1"; else printf %s "$2"; fi; }
release_err() { printf '%s\n' "$*" >&2; }

home="$TEST_ROOT/home"
project="$TEST_ROOT/project"
common="$project/.git"
mkdir -p "$home/state/locks" "$common" "$project/.claude"
chmod 700 "$home" "$home/state" "$home/state/locks" "$project" "$common" "$project/.claude"
checkout=$(_attachment_hash_text "$common") || exit 1
mkdir -p "$home/state/attachments/$checkout" "$home/state/git-hooks"
chmod 700 "$home/state/attachments" "$home/state/attachments/$checkout" "$home/state/git-hooks"
load_command_if_present "$root/scripts/release.sh" adoption_checkout_lock_wait
adoption_checkout_lock_wait "$home" "$checkout" "$common" || fail 'could not take the real checkout lock'

# Extract new helpers when present. On the original release code this stage is
# deliberately absent, so the old stage remains and the assertion is red.
for helper in release_entry_private_directory release_adoption_lock_valid release_adoption_reap_stale release_adoption_reap_completed_stages; do
  load_command_if_present "$root/scripts/release.sh" "$helper"
done

expected="$TEST_ROOT/expected" replacement="$TEST_ROOT/replacement"
printf 'old\n' > "$expected"; printf 'new\n' > "$replacement"
chmod 600 "$expected" "$replacement"
SIGNAL_PARTIAL=1
cat() {
  /bin/cat "$@" || return "$?"
  if [ "$SIGNAL_PARTIAL" -eq 1 ] && [ "${1:-}" = "$replacement" ]; then signal_this_shell; fi
}
release_store_rename_swap() {
  /bin/mv "$1" "$1.swap" && /bin/mv "$2" "$1" && /bin/mv "$1.swap" "$2"
}

case "$kind" in
  owner|render|shared)
    if [ "$kind" = owner ]; then
      destination="$home/state/attachments/$checkout/worktree.json"
    elif [ "$kind" = shared ]; then
      mkdir -m 700 "$common/info"
      destination="$common/info/exclude"
      [ "$lock_mode" != bad-shared ] || destination="$common/info/other"
    else
      destination="$project/.claude/settings.local.json"
    fi
    stage_parent=$(dirname "$destination"); stage_base=$(basename "$destination")
    printf 'old\n' > "$destination"; chmod 600 "$destination"
    if [ "$kind" = owner ]; then
      load_function "$root/scripts/release.sh" replace_owned_file || exit 1
      replace_owned_file "$destination" "$expected" "$replacement"; rc=$?
      prefix=".${stage_base}.release-adopt."
    else
      adoption_private_render_file_matches() { :; }
      adoption_render_live_matches() {
        local destination="$1" source="$2" identity="$3"
        [ -z "$identity" ] || _attachment_identity_matches "$destination" "$identity" file || return 1
        cmp -s "$destination" "$source"
      }
      load_function "$root/scripts/release.sh" adoption_publish_render || exit 1
      destination_id=$(_attachment_fs_identity "$destination") || exit 1
      plan=$(jq -cn --arg dest "$destination" --arg old "$expected" --arg new "$replacement" --arg id "$destination_id" \
        '{destination:$dest,source:$old,source_identity:"id",source_sha256:"old-hash",source_mode:"0600",path_identity:$id,candidate:$new,candidate_identity:"id",candidate_sha256:"new-hash",candidate_mode:"0600"}')
      adoption_publish_render "$plan" forward; rc=$?
      prefix=".${stage_base}.release-adopt-render."
    fi
    [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ] || fail "wrong partial TERM status: $rc"
    cmp -s "$destination" "$expected" || fail 'partial transaction changed live bytes'
    ;;
  hooks)
    destination="$home/state/git-hooks/$checkout"
    stage_parent=$(dirname "$destination"); stage_base=$(basename "$destination")
    mkdir -m 700 "$destination"
    printf 'old\n' > "$destination/release-payload"
    hook_payload_matches() { [ -d "$1" ] && printf '%s\n' "$2" | cmp -s - "$1/release-payload"; }
    _attachment_hooks_read_sidecar() { printf '%s' fixture; }
    _attachment_hooks_release_manifest_sha256() { printf '%s' manifest; }
    _attachment_hooks_post_checkout_dispatcher_body() { printf '%s' '#!/bin/sh'; }
    _attachment_hooks_pre_push_dispatcher_body() { printf '%s' '#!/bin/sh'; }
    _attachment_hooks_expected_passthrough_names() { :; }
    write_hook_state_file() {
      printf '%s\n' "$2" > "$1" && chmod "$3" "$1" || return 4
      if [ "$SIGNAL_PARTIAL" -eq 1 ]; then signal_this_shell; fi
    }
    load_function "$root/scripts/release.sh" replace_hook_payload || exit 1
    replace_hook_payload "$destination" old new "$common"; rc=$?
    [ "$rc" -eq "$TRELLIS_EX_STATE" ] || fail "wrong partial hook TERM status: $rc"
    [ "$(<"$destination/release-payload")" = old ] || fail 'partial hook transaction changed live bytes'
    prefix=".${stage_base}.release-adopt."
    ;;
  *) fail "unknown kind $kind" ;;
esac

shopt -s nullglob
stages=("$stage_parent/$prefix"??????)
[ "${#stages[@]}" -eq 1 ] || fail 'interrupted stage not found'
stale=${stages[0]}
touch -t 200001010000 "$stale"
odd="$stage_parent/${prefix}bad-AA"
if [ "$kind" = hooks ]; then
  young=$(mktemp -d "$stage_parent/${prefix}XXXXXX") || exit 1
  mid=$(mktemp -d "$stage_parent/${prefix}XXXXXX") || exit 1
  eligible=$(mktemp -d "$stage_parent/${prefix}XXXXXX") || exit 1
  at23=$(mktemp -d "$stage_parent/${prefix}XXXXXX") || exit 1
  at25=$(mktemp -d "$stage_parent/${prefix}XXXXXX") || exit 1
  chmod 700 "$young" "$mid" "$eligible" "$at23" "$at25"
  unknown=$(mktemp -d "$stage_parent/${prefix}XXXXXX") || exit 1
  chmod 700 "$unknown"; printf keep > "$unknown/unexpected"; chmod 600 "$unknown/unexpected"
  mkdir -m 700 "$odd"
  linked_child=$(mktemp -d "$stage_parent/${prefix}XXXXXX") || exit 1
  chmod 700 "$linked_child"
  ln -s "$TEST_ROOT/nonexistent" "$linked_child/post-checkout"
  touch -t 200001010000 "$unknown" "$odd" "$linked_child"
else
  young=$(mktemp "$stage_parent/${prefix}XXXXXX") || exit 1
  mid=$(mktemp "$stage_parent/${prefix}XXXXXX") || exit 1
  eligible=$(mktemp "$stage_parent/${prefix}XXXXXX") || exit 1
  at23=$(mktemp "$stage_parent/${prefix}XXXXXX") || exit 1
  at25=$(mktemp "$stage_parent/${prefix}XXXXXX") || exit 1
  unknown="$stage_parent/${prefix}bad"
  printf keep > "$unknown"; printf keep > "$odd"
  hard_target="$TEST_ROOT/hard-target"; printf 'hard target\n' > "$hard_target"
  hard="$stage_parent/${prefix}hArD00"; ln "$hard_target" "$hard"
  writable=$(mktemp "$stage_parent/${prefix}XXXXXX") || exit 1
  chmod 620 "$writable"
  touch -t 200001010000 "$unknown" "$odd" "$hard" "$writable"
fi
outside="$TEST_ROOT/outside"; printf 'outside\n' > "$outside"
link="$stage_parent/${prefix}z9Y8x7"; ln -s "$outside" "$link"
python3 -I - "$mid" "$eligible" "$at23" "$at25" "$link" <<'PY'
import os, sys, time
mid, eligible, at23, at25, link = sys.argv[1:]
now = time.time()
os.utime(mid, (now - 12 * 3600, now - 12 * 3600))
os.utime(eligible, (now - 26 * 3600, now - 26 * 3600))
os.utime(at23, (now - 23 * 3600, now - 23 * 3600))
os.utime(at25, (now - 25 * 3600, now - 25 * 3600))
os.utime(link, (946684800, 946684800), follow_symlinks=False)
PY

SIGNAL_PARTIAL=0
case "$kind" in
  owner) replace_owned_file "$destination" "$expected" "$replacement" || fail 'owner retry failed' ;;
  render|shared) adoption_publish_render "$plan" forward || fail 'render retry failed' ;;
  hooks) replace_hook_payload "$destination" old new "$common" || fail 'hook retry failed' ;;
esac

# Mirror the coordinator's post-commit pass with a complete bound plan. The
# separate full-adoption Bats test verifies that the real coordinator calls it.
shared=''
case "$kind" in
  owner) owner="$destination"; render=''; managed=''; hooks=false ;;
  render) owner=''; render="$destination"; managed=''; hooks=false ;;
  shared) owner=''; render=''; managed=''; hooks=false; shared="$destination" ;;
  hooks) owner=''; render=''; managed="$destination"; hooks=true ;;
esac
plan_checkout="$checkout" plan_root="$project"
[ "$lock_mode" != wrong-checkout ] || plan_checkout=wrong
[ "$lock_mode" != missing-root ] || plan_root=''
[ "$lock_mode" != wrong-root ] || plan_root="$TEST_ROOT/not-project"
jq -cn --arg checkout "$plan_checkout" --arg common "$common" --arg project "$plan_root" --arg owner "$owner" --arg render "$render" --arg managed "$managed" --arg hooks "$hooks" \
  '{binding:{checkout_id:$checkout,worktree_id:"worktree",root:$project,git_common_dir:$common},owner:$owner,renders:(if $render == "" then [] else [{destination:$render}] end),managed:$managed,hooks:$hooks}' > "$TEST_ROOT/plans.jsonl"
if [ "$lock_mode" = no-lock ]; then
  _attachment_checkout_lock_release || fail 'could not release fixture lock'
elif [ "$lock_mode" = forged-lock ]; then
  lock_link="$_ATTACHMENT_CHECKOUT_LOCK_LINK"
  lock_target=$(readlink "$lock_link") || exit 1
  rm -f "${lock_link:?}" && ln -s forged-holder "$lock_link" || exit 1
elif [ "$lock_mode" = unsafe-parent ]; then
  chmod 777 "$stage_parent"
elif [ "$lock_mode" = foreign-holder ] || [ "$lock_mode" = forged-birth ]; then
  lock_owner="$_ATTACHMENT_CHECKOUT_LOCK_HOLDER/owner.json"
  cp "$lock_owner" "$TEST_ROOT/owner-original"
  if [ "$lock_mode" = foreign-holder ]; then
    kill -0 "$PPID" 2>/dev/null || fail 'foreign holder fixture is not alive'
    jq --argjson pid "$PPID" '.pid = $pid' "$lock_owner" > "$TEST_ROOT/owner-forged" || exit 1
  else
    jq '.process_birth = "forged-birth"' "$lock_owner" > "$TEST_ROOT/owner-forged" || exit 1
  fi
  /bin/cat "$TEST_ROOT/owner-forged" > "$lock_owner"
elif [ "$lock_mode" = reused-birth ]; then
  lock_owner="$_ATTACHMENT_CHECKOUT_LOCK_HOLDER/owner.json"
  cp "$lock_owner" "$TEST_ROOT/owner-original"
  saved_birth="$__release_adoption_birth"
  reused_birth="reused-pid-birth"
  __release_adoption_birth="$reused_birth"
  jq --arg birth "$reused_birth" '.process_birth = $birth' "$lock_owner" > "$TEST_ROOT/owner-forged" || exit 1
  /bin/cat "$TEST_ROOT/owner-forged" > "$lock_owner"
elif [ "$lock_mode" = acl-parent ] || [ "$lock_mode" = acl-stage ] || [ "$lock_mode" = acl-child ]; then
  case "$lock_mode" in acl-parent) acl_path="$stage_parent" ;; acl-stage) acl_path="$stale" ;; acl-child) acl_path="$stale/post-checkout" ;; esac
  if [ "$(/usr/bin/uname -s)" = Darwin ]; then
    chmod +a 'everyone allow read' "$acl_path" || fail 'could not create ACL fixture'
  else
    setfacl -m "u:$(id -u):r--,m::---" "$acl_path" || fail 'could not create ACL fixture'
  fi
fi
if declare -F release_adoption_reap_completed_stages >/dev/null; then
  release_adoption_reap_completed_stages "$TEST_ROOT/plans.jsonl" "$shared"
fi
if [ "$lock_mode" = locked ]; then
  [ ! -e "$stale" ] || fail 'stale interrupted stage survived successful retry'
  [ ! -e "$eligible" ] || fail 'stage older than 24 hours survived successful retry'
else
  [ -e "$stale" ] || fail 'stage removed without a safe bound lock and parent'
fi
[ -e "$young" ] || fail 'young stage removed'
[ -e "$mid" ] || fail 'stage younger than 24 hours removed'
[ -e "$at23" ] || fail 'stage 23 hours old removed'
if [ "$lock_mode" = locked ]; then
  [ ! -e "$at25" ] || fail 'stage 25 hours old survived successful retry'
elif [ "$lock_mode" = acl-parent ] || [ "$lock_mode" = acl-stage ] || [ "$lock_mode" = acl-child ]; then
  : # Only the ACL entry is pinned; the 25 h sibling without an ACL is legitimately reaped.
else
  [ -e "$at25" ] || fail 'stage 25 hours old removed without a safe bound lock and parent'
fi
[ -e "$unknown" ] && [ -e "$odd" ] || fail 'unknown stage removed'
if [ "$kind" = hooks ]; then
  [ "$(<"$unknown/unexpected")" = keep ] || fail 'unknown child changed'
  [ -L "$linked_child/post-checkout" ] || fail 'stage with symlink child changed'
else
  [ -e "$hard" ] && [ "$(<"$hard_target")" = 'hard target' ] || fail 'hardlinked stage changed'
  [ -e "$writable" ] || fail 'group-writable stage removed'
fi
[ -L "$link" ] && [ "$(<"$outside")" = outside ] || fail 'symlink followed or removed'
if [ "$lock_mode" = forged-lock ]; then
  rm -f "${lock_link:?}" && ln -s "$lock_target" "$lock_link" || exit 1
elif [ "$lock_mode" = unsafe-parent ]; then
  chmod 700 "$stage_parent"
elif [ "$lock_mode" = foreign-holder ] || [ "$lock_mode" = forged-birth ]; then
  /bin/cat "$TEST_ROOT/owner-original" > "$lock_owner"
elif [ "$lock_mode" = reused-birth ]; then
  /bin/cat "$TEST_ROOT/owner-original" > "$lock_owner"
  __release_adoption_birth="$saved_birth"
elif [ "$lock_mode" = acl-parent ] || [ "$lock_mode" = acl-stage ] || [ "$lock_mode" = acl-child ]; then
  if [ "$(/usr/bin/uname -s)" = Darwin ]; then chmod -N "$acl_path" || fail 'could not remove fixture ACL'
  else setfacl -b "$acl_path" || fail 'could not remove fixture ACL'; fi
fi
if [ "$lock_mode" != no-lock ]; then _attachment_checkout_lock_release || fail 'fixture lock cleanup failed'; fi
