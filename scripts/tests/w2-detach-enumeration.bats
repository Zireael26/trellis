#!/usr/bin/env bats
# Detach must not report success if its ownership or journal inventory is unknown.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-detach.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  PROJECT="$SANDBOX/project"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME" "$PROJECT"
  git -C "$PROJECT" init -q
  source "$REPO_ROOT/scripts/attach-project.sh"
  identity="$(local_registry_identity_for_root "$PROJECT")"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  OWNER_DIR="$TRELLIS_HOME/state/attachments/$checkout"
  JOURNALS="$TRELLIS_HOME/state/attachment-journals"
  mkdir -p "$OWNER_DIR" "$JOURNALS" "$PROJECT/.trellis" "$SANDBOX/runtime"
  ln -s "$SANDBOX/runtime" "$PROJECT/.trellis/runtime"
}

run_detach() {
  run attach_cmd_detach --home "$TRELLIS_HOME" "$PROJECT"
}

@test "detach refuses when owner directory listing fails" {
  printf '{}\n' > "$OWNER_DIR/$worktree.json"
  chmod 311 "$OWNER_DIR"
  run_detach
  rc="$status"
  chmod 700 "$OWNER_DIR"
  [ "$rc" -eq 4 ] || { echo "owner listing accepted: $output"; false; }
  [ -L "$PROJECT/.trellis/runtime" ]
  [ -f "$OWNER_DIR/$worktree.json" ]
}

@test "detach refuses a symlinked owner record" {
  printf '{}\n' > "$SANDBOX/owner.json"
  ln -s "$SANDBOX/owner.json" "$OWNER_DIR/$worktree.json"
  run_detach
  [ "$status" -eq 4 ] || { echo "symlinked owner ignored: $output"; false; }
  [ -L "$OWNER_DIR/$worktree.json" ]
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "detach refuses an unparseable pending journal" {
  printf '{truncated' > "$JOURNALS/detach-broken.json"
  run_detach
  [ "$status" -eq 4 ] || { echo "broken journal ignored: $output"; false; }
  [ -f "$JOURNALS/detach-broken.json" ]
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "pending journal scan refuses when listing fails" {
  # State preparation restores mode 700, so exercise an error after that step.
  ATTACHMENT_ACTION=detach
  chmod 311 "$JOURNALS"
  run attach_detach_pending_journals "$TRELLIS_HOME" "$identity" "$PROJECT" false
  rc="$status"
  chmod 700 "$JOURNALS"
  [ "$rc" -eq 4 ] || { echo "journal listing accepted: $output"; false; }
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "no owners and an unrelated well-formed journal remain already detached" {
  printf '%s\n' '{"status":"detaching","original_owner":{"checkout_id":"other","worktree_id":"other","worktree_root":"/other"}}' > "$JOURNALS/detach-other.json"
  run_detach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"already detached:"* ]] || false
  [ -f "$JOURNALS/detach-other.json" ]
}
