#!/usr/bin/env bats
# On 1.4.1 an interrupted detach could not be finished: `trellis recover` and
# `trellis detach` both exited 3 with no output while another Trellis process
# held the checkout lock, and recover printed none of the library refusals
# because it never named its action. Every case here starts from a real
# SIGKILLed detach and asserts the step is finished, or refused by name with
# the journal kept.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/release-fixture
load helpers/detach-journal
bats_require_minimum_version 1.5.0

setup_file() {
  detach_journal_setup_file
}

teardown_file() {
  detach_journal_teardown_file
}

setup() {
  detach_journal_setup
  COMMON="$(release_fixture_canonical_dir "$PROJECT/.git")"
  CHECKOUT="$(printf '%s' "$COMMON" | shasum -a 256 | cut -d ' ' -f 1)"
}

teardown() {
  [ -z "${HOLDER:-}" ] || kill "$HOLDER" 2>/dev/null || true
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

# A live lock holder that is not this shell's child, so it is reaped the moment
# it is killed and a reclaim sees it dead rather than as a zombie.
start_holder() {
  HOLDER="$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')"
  export HOLDER
  kill -0 "$HOLDER"
}

# The SIGKILLed detach left its own dead checkout lock; a validated reclaim
# drops it before the live holder is staged.
stage_checkout_lock() {
  bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/attachment.sh"
    attachment_checkout_lock_reclaim "$2" "$3" "$4" && _attachment_test_stage_checkout_lock "$2" "$3" "$4" "$5"' _ \
    "$REPO_ROOT" "$TRELLIS_HOME" "$CHECKOUT" "$COMMON" "$HOLDER"
}

# Run detach or recover in-process so a test can stand in for one function.
run_sourced() {
  local stub="$1"
  shift
  run --separate-stderr bash -c '. "$1"; shift; eval "$1"; shift; main "$@"' _ "$ATTACH" "$stub" \
    "$@" --home "$TRELLIS_HOME" "$PROJECT"
}

journal_sha() {
  detach_journal_sha256 "$(detach_journal_path)"
}

@test "recover and detach wait out a checkout-lock holder instead of exiting 3 silently" {
  local command
  for command in recover detach; do
    detach_journal_setup
    kill_detach_at q_rmdir 9
    start_holder
    stage_checkout_lock
    # Record that a real live holder was observed before releasing it. Merely
    # reaching a successful detach would also pass if it stole the lock.
    export WAIT_MARKER="$SANDBOX/waited"
    run_sourced 'sleep() { kill -0 "$HOLDER" || return 1; printf waited > "$WAIT_MARKER"; kill "$HOLDER"; command sleep "$@"; }' "$command"
    [ "$status" -eq 0 ] || { echo "$command: status $status, stderr: $stderr"; false; }
    [ "$(< "$WAIT_MARKER")" = waited ]
    assert_detached
  done
}

@test "a lasting checkout-lock holder is named and the journal is kept" {
  local command before
  for command in recover detach; do
    detach_journal_setup
    kill_detach_at q_rmdir 9
    before="$(journal_sha)"
    start_holder
    stage_checkout_lock
    export WAIT_COUNT="$SANDBOX/wait-count"
    # Exercise the real 3600-retry wait and exhaustion branch, without 900 s
    # of sleeping or 3601 expensive JSON validations. Validate the live lock
    # once, then use a deterministic holder-backed reclaim for the loop.
    run_sourced '
      attachment_checkout_lock_reclaim "$TRELLIS_HOME" "'"$CHECKOUT"'" "'"$COMMON"'"; [ "$?" -eq 3 ] || exit 90
      attachment_checkout_lock_reclaim() { kill -0 "$HOLDER" || return 90; return 3; }
      sleep() { printf x >> "$WAIT_COUNT"; }
    ' "$command"
    [ "$(wc -c < "$WAIT_COUNT" | tr -d " ")" -eq 3600 ]
    [ "$status" -eq 3 ] || { echo "$command: status $status, stderr: $stderr"; false; }
    [ "$stderr" = "trellis attach: another Trellis operation still holds the checkout lock for $COMMON; retry when it finishes" ] ||
      { echo "$command stderr: $stderr"; false; }
    [ "$(journal_sha)" = "$before" ]
    kill "$HOLDER" 2>/dev/null || true
    HOLDER=
  done
}

@test "a held or unreadable worktree attachment lock is named" {
  local journal attachment worktree link birth holder_dir
  kill_detach_at q_rmdir 9
  journal="$(detach_journal_path)"
  attachment="$(jq -r '.attachment_id' "$journal")"
  worktree="$(jq -r '.worktree_id' "$journal")"
  link="$TRELLIS_HOME/state/locks/attachment-$CHECKOUT-$worktree.lock"
  # Drop the dead lock the SIGKILLed detach left, then stage a live holder.
  rm -rf "$TRELLIS_HOME/state/locks/$(readlink "$link")"
  rm "$link"
  start_holder
  birth="$(bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/attachment.sh"; _attachment_process_birth "$2"' _ "$REPO_ROOT" "$HOLDER")"
  holder_dir="$(mktemp -d "$TRELLIS_HOME/state/locks/.attachment-$CHECKOUT-$worktree.holder-$attachment.$HOLDER.XXXXXX")"
  chmod 700 "$holder_dir"
  jq -cn --arg c "$CHECKOUT" --arg w "$worktree" --arg a "$attachment" --arg b "$birth" --argjson p "$HOLDER" \
    '{checkout_id:$c,worktree_id:$w,attachment_id:$a,pid:$p,process_birth:$b}' > "$holder_dir/owner.json"
  chmod 600 "$holder_dir/owner.json"
  ln -s "$(basename "$holder_dir")" "$link"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis recover: refused (attachment-lock-held): $link; Trellis process $HOLDER holds this worktree's attachment lock; retry when it exits" ] ||
    { echo "stderr: $stderr"; false; }

  rm "$link"
  ln -s not-a-trellis-holder "$link"
  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 4 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis recover: refused (attachment-lock-unreadable): $link; it is not a well-formed Trellis lock; inspect it, and remove it only when no Trellis process is running" ] ||
    { echo "stderr: $stderr"; false; }
  [ -f "$journal" ]
}

@test "recover names a leaf that changed after the interruption and leaves it in place" {
  local journal leaf
  kill_detach_at q_rmdir 9
  journal="$(detach_journal_path)"
  leaf="$PROJECT/$(jq -r '.remove[9].path' "$journal")"
  [ -L "$leaf" ]
  rm "$leaf"
  ln -s "$SANDBOX/user-owned-target" "$leaf"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis recover: refused (artifact-changed): $leaf" ] || { echo "stderr: $stderr"; false; }
  [ "$(readlink "$leaf")" = "$SANDBOX/user-owned-target" ]
  [ -f "$journal" ]
}

@test "a render edited during an interrupted detach is named and kept" {
  local journal path
  kill_detach_at attachment_detach_render_begin 1
  journal="$(detach_journal_path)"
  path="$PROJECT/$(jq -r '.external.render_pending.render.path' "$journal")"
  jq '. + {"user-edit": true}' "$path" > "$path.next"
  chmod 600 "$path.next"
  mv "$path.next" "$path"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis recover: refused (render-conflict): $path; it or its directory no longer matches detach journal $journal; restore the bytes Trellis rendered (journal external.renders[].after_base64), then rerun trellis recover" ] ||
    { echo "stderr: $stderr"; false; }
  jq -e '."user-edit" == true' "$path"
  [ -f "$journal" ]
}

@test "a render deleted before its turn is named as missing" {
  local journal path
  kill_detach_at owner_committed 1
  journal="$(detach_journal_path)"
  jq -e '.external.render_phase == 0 and .external.render_pending == null and .external.renders[0].before_exists == false' "$journal"
  path="$PROJECT/$(jq -r '.external.renders[0].path' "$journal")"
  rm "$path"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis recover: refused (render-missing): $path" ] || { echo "stderr: $stderr"; false; }
  [ -f "$journal" ]
}

@test "a second core.hooksPath value is named before hooks are restored" {
  kill_detach_at attachment_detach_mark_external_phase 3
  git -C "$PROJECT" config --local --add core.hooksPath "$SANDBOX/other hooks"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis attach: refusing detach: core.hooksPath has more than one value in $(printf '%q' "$PROJECT"); keep one with git config --local core.hooksPath, then rerun" ] ||
    { echo "stderr: $stderr"; false; }
  [ -f "$(detach_journal_path)" ]
}

@test "a foreign file in the managed hooks directory is named" {
  local journal managed
  kill_detach_at attachment_detach_mark_external_phase 3
  journal="$(detach_journal_path)"
  managed="$(jq -r '.original_owner.git_hooks.managed_hooks_path' "$journal")"
  printf 'user hook\n' > "$managed/user-hook"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  # Restoring core.hooksPath warns first; the refusal is the last line.
  [[ "${stderr_lines[${#stderr_lines[@]}-1]}" == "trellis attach: refusing to remove managed hooks: "* ]] ||
    { echo "stderr: $stderr"; false; }
  [ -f "$managed/user-hook" ]
  [ -f "$journal" ]
}

@test "a duplicated managed exclude block is named during recover" {
  local exclude block_hash
  kill_detach_at attachment_detach_mark_external_phase 2
  block_hash="$(jq -r '.original_owner.exclude.managed_block_sha256' "$(detach_journal_path)")"
  [[ "$block_hash" =~ ^[0-9a-f]{64}$ ]]
  exclude="$PROJECT/.git/info/exclude"
  sed -n '/^# --- Trellis local attachment exclude block ---$/,/^# --- end Trellis local attachment exclude block ---$/p' "$exclude" > "$SANDBOX/block"
  cat "$SANDBOX/block" >> "$exclude"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis attach: managed exclude block is tampered or duplicated during recover for $(printf '%q' "$exclude"); restore the single block Trellis wrote (sha256 $block_hash), then rerun trellis recover" ] ||
    { echo "stderr: $stderr"; false; }
  [ -f "$(detach_journal_path)" ]
}

@test "recorded exclude block bytes must match the journal hash" {
  local journal exclude before journal_before
  kill_detach_at attachment_detach_mark_external_phase 2
  journal="$(detach_journal_path)"
  exclude="$PROJECT/.git/info/exclude"
  before="$(detach_journal_sha256 "$exclude")"
  jq '.original_owner.exclude.managed_block_base64 = ("tampered block\n" | @base64)' "$journal" > "$journal.next"
  chmod 600 "$journal.next"
  mv "$journal.next" "$journal"
  journal_before="$(detach_journal_sha256 "$journal")"
  # Known 1.4.2 gap, deferred to 1.4.3: this hash mismatch exits 4 without
  # a diagnostic. Check status and preservation, not the absence of a message.
  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 4 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$(detach_journal_sha256 "$exclude")" = "$before" ]
  [ "$(detach_journal_sha256 "$journal")" = "$journal_before" ]
}

@test "a journal step its recorded phase does not allow is named" {
  local journal
  kill_detach_at attachment_detach_mark_external_phase 3
  journal="$(detach_journal_path)"
  run --separate-stderr bash -c '. "$1"; ATTACHMENT_ACTION=detach; attachment_detach_finalize "$2" "$3"' _ \
    "$ATTACH" "$TRELLIS_HOME" "$journal"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis detach: refused (journal-phase-conflict): $journal; its recorded owner commit or phase does not allow this step; keep the journal and run trellis doctor" ] ||
    { echo "stderr: $stderr"; false; }
  [ -f "$journal" ]
}

# The 1.4.1 field case: a committed detach journal whose worktree was
# attached again before the journal finished. Finishing it would tear down the
# new attachment's hooks; the registry also rejects the old ID. Recover refuses.
@test "recover names a committed detach journal whose worktree was attached again" {
  local journal owner
  kill_detach_at attachment_detach_mark_external_phase 3
  journal="$(detach_journal_path)"
  owner="$TRELLIS_HOME/state/attachments/$(jq -r '.checkout_id' "$journal")/$(jq -r '.worktree_id' "$journal").json"
  [ ! -e "$owner" ]
  jq -cS '.original_owner | .attachment_id = "00000000-0000-4000-8000-000000000001"' "$journal" > "$owner"
  chmod 600 "$owner"

  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis recover: refused (owner-changed): $owner" ] || { echo "stderr: $stderr"; false; }
  [ -f "$journal" ]
  [ -f "$owner" ]
}
