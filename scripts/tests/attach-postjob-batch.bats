#!/usr/bin/env bats
# T69: batch repeated per-boundary reads without weakening postjob verdicts.

setup() {
  REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  ROOT="$BATS_TEST_TMPDIR/batch"
  HOME_DIR="$ROOT/home"
  OWNER="$ROOT/owner.json"
  STATUS="$HOME_DIR/state/attachment-status/checkout/worktree.json"
  JQ_CALLS="$ROOT/jq-calls"
  JQ_BIN="$(command -v jq)"
  mkdir -p "${STATUS%/*}"
  chmod 700 "$HOME_DIR" "$HOME_DIR/state" "$HOME_DIR/state/attachment-status" "${STATUS%/*}"
  : > "$JQ_CALLS"
  # shellcheck source=../lib/attach-postjob.sh
  source "$REPO_ROOT/scripts/lib/attach-postjob.sh"
}

# Controlled mode/hash stand-ins let the reference and production classifiers
# observe the same bytes and deterministic clock on both BSD and GNU hosts.
_attachment_mode() {
  local value
  value="$(stat -f %Lp "$1" 2>/dev/null)" || value=""
  case "$value" in ''|*[!0-7]*) value="$(stat -c %a "$1")" || return 1 ;; esac
  printf '%s\n' "$value"
}
_attachment_hash() {
  local value
  value="$(shasum -a 256 "$1")" || return 1
  printf '%s\n' "${value%% *}"
}
date() { printf '1800000000\n'; }

# Executable copy of the classifier as frozen by the T14 amendment (schema 2,
# bound to attachment, release, root and owner digest): compare even malformed
# and multi-document inputs, not only the happy-path fields used by pre-push.
reference_status_classify() {
  local home="$1" owner="$2" path record state attachment sha at check remedy now release root bound
  path="$(attach_status_path "$home" "$3" "$4")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'missing\t0\t\t\n'
    return 0
  fi
  now="$(date +%s)"
  if [ -L "$path" ] || [ ! -f "$path" ] || [ "$(_attachment_mode "$path")" != 600 ] ||
     ! record="$(jq -r '
       select(.schema_version == 2
         and (.state | IN("pending","running","ok","failed","blocked-by-journal"))
         and (.attachment_id | type == "string") and (.owner_sha256 | type == "string")
         and (.release | type == "string") and (.worktree_root | type == "string")
         and (.checkout_id | type == "string") and (.worktree_id | type == "string")
         and (.updated_at | type == "number"))
       | [.state, .attachment_id, .owner_sha256, (.updated_at | floor | tostring),
          .release, .worktree_root, .checkout_id, .worktree_id,
          (.failure.check? // ""), (.failure.remedy? // "")]
       | map(gsub("[[:cntrl:]]"; " ")) | @tsv' "$path" 2>/dev/null)" || [ -z "$record" ]; then
    printf 'stale\t0\t\t\n'
    return 0
  fi
  # Tab is IFS whitespace, so runs of tabs collapse: the fields that may be
  # empty (the failure check and remedy) stay last.
  IFS=$'\t' read -r state attachment sha at release root checkout_id worktree_id check remedy <<EOF
$record
EOF
  # One owner read binds the attachment, release and root; the digest binds
  # every other owner field.
  bound="$(jq -r '[.attachment_id, .release, .worktree_root] | map(tostring) | @tsv' "$owner" 2>/dev/null)" || bound=""
  if [ "$attachment"$'\t'"$release"$'\t'"$root" != "$bound" ] ||
     [ "$checkout_id" != "$3" ] || [ "$worktree_id" != "$4" ] ||
     [ "$sha" != "$(_attachment_hash "$owner" 2>/dev/null)" ]; then
    state=stale
  fi
  printf '%s\t%s\t%s\t%s\n' "$state" "$((now - at))" "$check" "$remedy"
}

write_owner() {
  printf '{"attachment_id":"%s","release":"1.2.3","worktree_root":"/w","data":"%s"}\n' "$1" "${2:-original}" > "$OWNER"
  chmod 600 "$OWNER"
}
write_status() {
  local state="$1" attachment="$2" sha="$3" failure="${4:-null}"
  "$JQ_BIN" -n --arg state "$state" --arg attachment "$attachment" --arg sha "$sha" \
    --argjson failure "$failure" \
    '{schema_version:2,state:$state,checkout_id:"checkout",worktree_id:"worktree",attachment_id:$attachment,
      owner_sha256:$sha,release:"1.2.3",worktree_root:"/w",updated_at:1799999900.5,failure:$failure}' > "$STATUS"
  chmod 600 "$STATUS"
}
assert_reference() {
  local actual expected
  expected="$(reference_status_classify "$HOME_DIR" "$OWNER" checkout worktree)"
  actual="$(attach_status_classify "$HOME_DIR" "$OWNER" checkout worktree)"
  [ "$actual" = "$expected" ] || { printf 'reference <%s> actual <%s>\n' "$expected" "$actual"; return 1; }
}

# Evaluate only the emitted function under test; unrelated dispatcher startup is
# deliberately not mocked into the assertion.
emitted_function() {
  local generated="$1" name="$2"
  printf '%s\n' "$generated" | awk -v start="$name() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && $0 == "}" { exit }
  '
}

@test "T69 release anchor keeps its checks without dirname processes" {
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  local release="$HOME_DIR/releases/1.2.3" payload="$HOME_DIR/releases/1.2.3/payload" generated fn
  mkdir -p "$payload"
  : > "$release/release.json"
  generated="$(_attachment_hooks_dispatcher_common_body "$payload" core-rules/githooks/pre-push abc)"
  fn="$(emitted_function "$generated" trellis_verify_release_anchor)"
  [ -n "$fn" ]
  eval "$fn"
  managed_home="$HOME_DIR" expected_payload="$payload" expected_release_manifest_sha256=abc
  trellis_canonical_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(CDPATH= cd "$1" && pwd -P)" = "$1" ]; }
  trellis_readonly() { :; }
  trellis_hash_file() { printf 'abc\n'; }
  trellis_release_manifest_valid() { [ "$1" = "$release/release.json" ] && [ "$2" = 1.2.3 ]; }
  dirname() { echo 'unexpected dirname' >&2; return 1; }
  run trellis_verify_release_anchor "$payload"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  expected_release_manifest_sha256=wrong
  run trellis_verify_release_anchor "$payload"
  [ "$status" -ne 0 ] || { echo 'wrong manifest digest accepted'; return 1; }
  expected_release_manifest_sha256=abc
  trellis_readonly() { [ "$1" != "$release/release.json" ]; }
  run trellis_verify_release_anchor "$payload"
  [ "$status" -ne 0 ] || { echo 'writable manifest accepted'; return 1; }
  trellis_readonly() { :; }
  : > "$release/extra"
  run trellis_verify_release_anchor "$payload"
  [ "$status" -ne 0 ] || { echo 'extra release entry accepted'; return 1; }
}

@test "T69 managed payload keeps ancestor and leaf checks without dirname processes" {
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  local payload="$HOME_DIR/releases/1.2.3/payload" generated fn source
  for source in core-rules/githooks/pre-push core-rules/husky/pre-push scripts/lib/attach-postjob.sh scripts/seed-inheritance-symlinks.sh; do
    mkdir -p "$payload/${source%/*}"
    printf '#!/bin/sh\n' > "$payload/$source"
    chmod 700 "$payload/$source"
  done
  generated="$(_attachment_hooks_dispatcher_common_body "$payload" core-rules/githooks/pre-push abc)"
  fn="$(emitted_function "$generated" trellis_managed_payload_file)"
  [ -n "$fn" ]
  eval "$fn"
  managed_home="$HOME_DIR" expected_payload="$payload"
  trellis_verify_release() { :; }
  trellis_verify_release_executed() { :; }
  dirname() { echo 'unexpected dirname' >&2; return 1; }
  for source in core-rules/githooks/pre-push core-rules/husky/pre-push scripts/lib/attach-postjob.sh scripts/seed-inheritance-symlinks.sh; do
    run trellis_managed_payload_file "$payload" "$source"
    [ "$status" -eq 0 ] && [ "$output" = "$payload/$source" ] || { echo "$source: $output"; return 1; }
  done
  run trellis_managed_payload_file "$payload" scripts/lib/unknown.sh
  [ "$status" -ne 0 ] || { echo 'unapproved payload accepted'; return 1; }
  chmod 600 "$payload/core-rules/githooks/pre-push"
  run trellis_managed_payload_file "$payload" core-rules/githooks/pre-push
  [ "$status" -ne 0 ] || { echo 'nonexecutable carrier accepted'; return 1; }
  chmod 700 "$payload/core-rules/githooks/pre-push"
  mv "$payload/core-rules/githooks" "$payload/core-rules/real-githooks"
  ln -s real-githooks "$payload/core-rules/githooks"
  run trellis_managed_payload_file "$payload" core-rules/githooks/pre-push
  [ "$status" -ne 0 ] || { echo 'symlinked ancestor accepted'; return 1; }
}

@test "T69 postjob identity is read once and preserves a backslash in the root" {
  local root="$ROOT/project\\quoted" checkout worktree TEST_IDENTITY
  checkout="$(printf 'a%.0s' {1..64})"
  worktree="$(printf 'b%.0s' {1..64})"
  TEST_IDENTITY="$("$JQ_BIN" -n --arg root "$root" --arg checkout "$checkout" --arg worktree "$worktree" \
    '{root:$root,checkout_id:$checkout,worktree_id:$worktree}')"
  export TEST_IDENTITY OWNER JQ_BIN JQ_CALLS ROOT
  : > "$OWNER"
  jq() { printf 'jq\n' >> "$JQ_CALLS"; "$JQ_BIN" "$@"; }
  local_registry_identity_for_root() { printf '%s\n' "$TEST_IDENTITY"; }
  _attachment_ownership_path() {
    printf '%s\n%s\n' "$2" "$3" > "$ROOT/identity-seen"
    printf '%s\n' "$OWNER"
  }
  attach_postjob_journal_pending() { printf '%s\n%s\n' "$2" "$3" > "$ROOT/journal-seen"; return 1; }
  attach_status_classify() { printf 'ok\t0\t\t\n'; }
  run attach_postjob_prepush "$HOME_DIR" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(< "$ROOT/identity-seen")" = "$(printf '%s\n%s' "$checkout" "$worktree")" ]
  [ "$(< "$ROOT/journal-seen")" = "$(printf '%s\n%s' "$checkout" "$root")" ]
  [ "$(wc -l < "$JQ_CALLS" | tr -d ' ')" = 1 ] || { echo 'identity needs one jq projection'; return 1; }
}

@test "T69 failed identity projection refuses before looking up an owner" {
  : > "$OWNER"
  local_registry_identity_for_root() { printf '{"checkout_id":"a","worktree_id":"b","root":"/x"}\n'; }
  jq() { return 1; }
  _attachment_ownership_path() { printf 'reached\n' > "$ROOT/unexpected-owner-lookup"; printf '%s\n' "$OWNER"; }
  attach_postjob_journal_pending() { return 1; }
  attach_status_classify() { printf 'ok\t0\t\t\n'; }
  run attach_postjob_prepush "$HOME_DIR" /x
  [ "$status" -ne 0 ] || { echo 'failed identity projection authorized a push'; return 1; }
  [ ! -e "$ROOT/unexpected-owner-lookup" ] || { echo 'owner lookup ran after projection failure'; return 1; }
}

@test "T69 valid status keeps the canonical owner-bound verdict" {
  local id=12345678-1234-4123-8123-123456789abc sha result
  write_owner "$id"
  sha="$(_attachment_hash "$OWNER")"
  write_status ok "$id" "$sha"
  result="$(attach_status_classify "$HOME_DIR" "$OWNER" checkout worktree)"
  [ "$result" = $'ok\t100\t\t' ] || { echo "unexpected verdict: $result"; return 1; }
}

@test "T69 status agrees with the original classifier on normal and malformed records" {
  local id=12345678-1234-4123-8123-123456789abc sha state
  write_owner "$id"
  sha="$(_attachment_hash "$OWNER")"
  for state in ok pending running failed blocked-by-journal; do
    write_status "$state" "$id" "$sha" '{"check":"owner-artifacts","remedy":"use doctor"}'
    assert_reference || return 1
  done
  write_status ok 00000000-0000-4000-8000-000000000000 "$sha"; assert_reference
  write_status ok "$id" badhash; assert_reference
  write_status unknown "$id" "$sha"; assert_reference
  write_status failed "$id" "$sha" '{"check":"bad\tcheck","remedy":"line\nnext"}'; assert_reference
  write_status ok "$id" "$sha"
  printf '%s\n' '{"schema_version":2,"state":"ok"}' >> "$STATUS"; assert_reference
  printf '%s\n' '{invalid' > "$STATUS"; assert_reference
  write_status ok "$id" "$sha"
  chmod 644 "$STATUS"; assert_reference
  chmod 600 "$STATUS"
  printf '%s\n' '{"attachment_id":null}' > "$OWNER"; assert_reference
  printf '%s\n' '{invalid' > "$OWNER"; assert_reference
  printf '%s\n' '{"attachment_id":"first"}' '{"attachment_id":"second"}' > "$OWNER"; assert_reference
  "$JQ_BIN" -n --arg id 'non-uuid\name' '{attachment_id:$id,release:"1.2.3",worktree_root:"/w"}' > "$OWNER"
  sha="$(_attachment_hash "$OWNER")"
  write_status ok 'non-uuid\name' "$sha"; assert_reference
  "$JQ_BIN" -n --arg id "$id" --arg long "$(printf 'x%.0s' {1..65537})" \
    '{attachment_id:$id,release:"1.2.3",worktree_root:"/w",data:$long}' > "$OWNER"
  sha="$(_attachment_hash "$OWNER")"; write_status ok "$id" "$sha"; assert_reference
  printf '\000' >> "$OWNER"; assert_reference
}

@test "T69 status is stale when owner changes between projection and digest" {
  local id=12345678-1234-4123-8123-123456789abc sha
  write_owner "$id"
  sha="$(_attachment_hash "$OWNER")"
  write_status ok "$id" "$sha"
  printf '{"attachment_id":"%s","release":"1.2.3","worktree_root":"/w","data":"changed"}\n' "$id" > "$ROOT/owner-new.json"
  _attachment_hash() {
    local value
    cp "$ROOT/owner-new.json" "$OWNER" || return 1
    value="$(shasum -a 256 "$1")" || return 1
    printf '%s\n' "${value%% *}"
  }
  run attach_status_classify "$HOME_DIR" "$OWNER" checkout worktree
  [ "$status" -eq 0 ]
  cmp "$ROOT/owner-new.json" "$OWNER" || { echo 'owner change did not occur'; return 1; }
  [[ "$output" == $'stale\t'* ]] || { echo "changed owner was authorized: $output"; return 1; }
}
