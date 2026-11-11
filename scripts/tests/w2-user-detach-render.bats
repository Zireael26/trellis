#!/usr/bin/env bats
# Transient journal reads cannot silently skip external render publication.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/attachment.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-user-detach.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  mkdir -p "$TRELLIS_HOME/attachments" "$TRELLIS_HOME/state/user-attachment-journals"
  OWNER="$TRELLIS_HOME/attachments/user.json" JOURNAL="$TRELLIS_HOME/state/user-attachment-journals/detach.json"
  printf '%s\n' '{"id":"fixture"}' > "$OWNER"
  printf '%s\n' '{"original_owner":{"id":"fixture"},"owner_committed":false,"removal":null,"phase":0,"remove":[],"external":{"phase":1,"render_phase":0,"renders":[{}],"render_pending":null},"operation":"detach"}' > "$JOURNAL"
}

commit_with_fault() {
  local query="$1"
  run bash -c '
    . "$1"
    FAIL_QUERY="$4"
    jq() { for arg in "$@"; do [ "$arg" != "$FAIL_QUERY" ] || return 5; done; command jq "$@"; }
    _attachment_user_detach_journal_valid() { return 0; }
    _attachment_user_runtime_binding_matches() { return 0; }
    _attachment_user_owner_json_valid() { return 0; }
    _attachment_user_owner_path() { printf "%s/attachments/user.json\n" "$1"; }
    _attachment_user_detach_render_begin() { jq '\''.external.render_pending = {}'\'' "$1" > "$1.next" && mv "$1.next" "$1"; }
    _attachment_user_detach_render_stage() { return 0; }
    _attachment_user_detach_render_publish() { jq '\''.external.render_phase += 1 | .external.render_pending = null'\'' "$1" > "$1.next" && mv "$1.next" "$1" && : > "$home/render-published"; }
    _attachment_user_detach_cleanup_parents() { return 0; }
    _attachment_user_detach_journal_update() { return 0; }
    _attachment_user_detach_commit_locked "$2" "$3"
  ' _ "$LIB" "$TRELLIS_HOME" "$JOURNAL" "$query"
}

@test "render-phase read failure keeps owner and recovery journal" {
  commit_with_fault '.external.render_phase'
  [ "$status" -ne 0 ] || { echo "render phase failure reported success: $output"; false; }
  [ -f "$OWNER" ] && [ -f "$JOURNAL" ]
}

@test "render-count read failure keeps owner and recovery journal" {
  commit_with_fault '.external.renders | length'
  [ "$status" -ne 0 ] || { echo "render count failure reported success: $output"; false; }
  [ -f "$OWNER" ] && [ -f "$JOURNAL" ]
}

@test "a readable pending render is published before detach completes" {
  commit_with_fault '__no_fault__'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/render-published" ]
  [ ! -e "$OWNER" ] && [ ! -e "$JOURNAL" ]
}

@test "completed detach with no renders still succeeds" {
  jq '.external.renders = []' "$JOURNAL" > "$SANDBOX/next"
  mv "$SANDBOX/next" "$JOURNAL"
  commit_with_fault '__no_fault__'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$OWNER" ] && [ ! -e "$JOURNAL" ]
}
