#!/usr/bin/env bats
# `trellis recover --discard-superseded-journal UUID PATH` archives a committed
# full-detach journal whose worktree was attached again before the journal
# finished (a 1.4.1 field case). Recovery refuses before touching the new
# hooks, and the registry would reject the old ID. The journal is archived with
# nothing else changed; preconditions are refused by name with the journal kept.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/release-fixture
load helpers/detach-journal
bats_require_minimum_version 1.5.0

NEW_ID=00000000-0000-4000-8000-000000000001

setup_file() {
  detach_journal_setup_file
}

teardown_file() {
  detach_journal_teardown_file
}

setup() {
  detach_journal_setup
}

teardown() {
  [ -z "${HOLDER:-}" ] || kill "$HOLDER" 2>/dev/null || true
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

rewrite_json() {
  local path="$1"
  shift
  jq "$@" "$path" > "$path.next" && chmod 600 "$path.next" && mv "$path.next" "$path"
}

# The worktree attached again: a new owner record and registry binding.
supersede() {
  JOURNAL="$(detach_journal_path)"
  OLD_ID="$(jq -r '.attachment_id' "$JOURNAL")"
  OWNER="$TRELLIS_HOME/state/attachments/$(jq -r '.checkout_id' "$JOURNAL")/$(jq -r '.worktree_id' "$JOURNAL").json"
  jq -cS --arg id "$NEW_ID" '.original_owner | .attachment_id = $id' "$JOURNAL" > "$OWNER"
  chmod 600 "$OWNER"
  rewrite_json "$TRELLIS_HOME/registry.json" --arg c "$(jq -r '.checkout_id' "$JOURNAL")" --arg w "$(jq -r '.worktree_id' "$JOURNAL")" \
    --arg id "$NEW_ID" '(.projects[].checkouts[$c].worktrees[$w] | select(. != null)) |= (.attachment_id = $id)'
}

run_discard() {
  REFUSAL_STATE="$(capture_refusal_state)" || return 1
  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" --discard-superseded-journal "$1" "$PROJECT"
}

assert_refused() {
  local reason="$1"
  [ "$status" -eq 3 ] || { echo "status $status, stdout: $output, stderr: $stderr"; false; }
  [ "$stderr" = "trellis attach: superseded journal discard refused: $reason; journal kept at $(printf '%q' "$JOURNAL")" ] ||
    { echo "stderr: $stderr"; false; }
  [ "$(detach_journal_sha256 "$JOURNAL")" = "$JOURNAL_SHA" ]
  [ ! -e "$TRELLIS_HOME/backups" ]
  [ "$(capture_refusal_state)" = "$REFUSAL_STATE" ] || { echo 'refusal changed owner, registry, progress or worktree lock'; false; }
}

capture_refusal_state() {
  local checkout worktree
  checkout="$(jq -r '.checkout_id' "$JOURNAL")"
  worktree="$(jq -r '.worktree_id' "$JOURNAL")"
  snapshot_surfaces "$TRELLIS_HOME/state/attachments" "$TRELLIS_HOME/registry.json" \
    "$TRELLIS_HOME/state/attachment-progress" "$TRELLIS_HOME/state/locks/attachment-$checkout-$worktree.lock"
}

snapshot_surfaces() {
  python3 -I - "$@" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
rows = []
def visit(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        rows.append((str(path), None, 'missing', ''))
        return
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        rows.append((str(path), mode, 'link', os.readlink(path)))
    elif stat.S_ISDIR(info.st_mode):
        rows.append((str(path), mode, 'dir', ''))
        for child in sorted(path.iterdir()): visit(child)
    elif stat.S_ISREG(info.st_mode):
        rows.append((str(path), mode, 'file', hashlib.sha256(path.read_bytes()).hexdigest()))
    else:
        raise AssertionError('unexpected fixture entry: ' + str(path))
for argument in sys.argv[1:]: visit(Path(argument))
print(json.dumps(rows))
PY
}

file_mode() {
  local mode
  mode="$(stat -f %Lp "$1" 2>/dev/null)" || mode=""
  case "$mode" in ''|*[!0-7]*) mode="" ;; esac
  [ -n "$mode" ] || mode="$(stat -c %a "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$mode"
}

@test "a superseded committed detach journal is archived and nothing else changes" {
  local archived before_owner before_registry before_exclude before_hooks before_surfaces pristine managed rel checkout worktree link
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  before_owner="$(detach_journal_sha256 "$OWNER")"
  before_registry="$(detach_journal_sha256 "$TRELLIS_HOME/registry.json")"
  before_exclude="$(detach_journal_sha256 "$PROJECT/.git/info/exclude")"
  before_hooks="$(git -C "$PROJECT" config --local --get-all core.hooksPath || true)"
  # Recreate actual harness leaves from the pristine attached fixture: the
  # superseding owner represents a new attachment, not an empty worktree.
  pristine="$(dirname "$SANDBOX")/pristine/project with spaces"
  for rel in .claude .agents .codex .trellis; do
    mkdir -p "$PROJECT/$rel"
    cp -Rp "$pristine/$rel/." "$PROJECT/$rel/"
  done
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  [ -f "$PROJECT/.claude/settings.local.json" ]
  [ -L "$PROJECT/.agents/skills/a.md" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ -f "$managed/post-checkout" ]
  before_surfaces="$(snapshot_surfaces "$PROJECT/.claude" "$PROJECT/.agents" "$PROJECT/.codex" "$PROJECT/.trellis" "$managed")"
  checkout="$(jq -r '.checkout_id' "$JOURNAL")"
  worktree="$(jq -r '.worktree_id' "$JOURNAL")"
  link="$TRELLIS_HOME/state/locks/attachment-$checkout-$worktree.lock"

  run_discard "$OLD_ID"
  [ "$status" -eq 0 ] || { echo "status $status, stderr: $stderr"; false; }
  archived="$TRELLIS_HOME/backups/discarded-journals-$(date -u +%Y-%m-%d)/${JOURNAL##*/}"
  [ "$output" = "archived superseded journal: $archived" ]
  [ ! -e "$JOURNAL" ]
  [ "$(detach_journal_sha256 "$archived")" = "$JOURNAL_SHA" ]
  [ "$(file_mode "$archived")" = 600 ]
  [ "$(detach_journal_sha256 "$OWNER")" = "$before_owner" ]
  [ "$(detach_journal_sha256 "$TRELLIS_HOME/registry.json")" = "$before_registry" ]
  [ "$(detach_journal_sha256 "$PROJECT/.git/info/exclude")" = "$before_exclude" ]
  [ "$(git -C "$PROJECT" config --local --get-all core.hooksPath || true)" = "$before_hooks" ]
  [ "$(snapshot_surfaces "$PROJECT/.claude" "$PROJECT/.agents" "$PROJECT/.codex" "$PROJECT/.trellis" "$managed")" = "$before_surfaces" ]
  [ "$(find "$TRELLIS_HOME/backups" -mindepth 1 -print | wc -l | tr -d ' ')" -eq 2 ]
  [ ! -e "$link" ]
  [ ! -L "$link" ]
  [ -z "$(find "$TRELLIS_HOME/state/locks" -maxdepth 1 -name ".attachment-$checkout-$worktree.holder-*" -print)" ]

  # Plain recovery now has nothing to do.
  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 5 ]
}

@test "a superseded discard needs a different, registry-bound owner and no live lock" {
  local worktree link
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"

  mv "$OWNER" "$SANDBOX/owner.aside"
  run_discard "$OLD_ID"
  assert_refused 'the worktree has no valid owner record'

  jq -cS '.original_owner' "$JOURNAL" > "$OWNER"
  chmod 600 "$OWNER"
  run_discard "$OLD_ID"
  assert_refused 'the owner record is still this attachment; use normal trellis recover'

  jq -cS --arg id "$NEW_ID" --arg w "$(printf '%064d' 0)" '.original_owner | .attachment_id = $id | .worktree_id = $w' "$JOURNAL" > "$OWNER"
  chmod 600 "$OWNER"
  run_discard "$OLD_ID"
  assert_refused "the owner record does not bind to $(printf '%q' "$PROJECT")"

  mv "$SANDBOX/owner.aside" "$OWNER"
  cp -p "$TRELLIS_HOME/registry.json" "$SANDBOX/registry.aside"
  rewrite_json "$TRELLIS_HOME/registry.json" --arg old "$OLD_ID" '(.. | objects | select(.attachment_id? == "'"$NEW_ID"'")) |= (.attachment_id = $old)'
  run_discard "$OLD_ID"
  assert_refused "the registry does not bind this worktree to its owner $NEW_ID"

  cp -p "$SANDBOX/registry.aside" "$TRELLIS_HOME/registry.json"
  rewrite_json "$TRELLIS_HOME/registry.json" --arg old "$OLD_ID" --arg root "$SANDBOX/elsewhere" \
    '.projects[].checkouts[].worktrees["'"$(printf '%064d' 0)"'"] = {root:$root,attachment_id:$old}'
  run_discard "$OLD_ID"
  assert_refused "the registry still binds attachment $OLD_ID"

  cp -p "$SANDBOX/registry.aside" "$TRELLIS_HOME/registry.json"
  mkdir -p "$TRELLIS_HOME/state/attachment-progress"
  : > "$TRELLIS_HOME/state/attachment-progress/$OLD_ID.log"
  run_discard "$OLD_ID"
  assert_refused 'a progress log exists; use normal trellis recover'

  rm "$TRELLIS_HOME/state/attachment-progress/$OLD_ID.log"
  worktree="$(jq -r '.worktree_id' "$JOURNAL")"
  link="$TRELLIS_HOME/state/locks/attachment-$(jq -r '.checkout_id' "$JOURNAL")-$worktree.lock"
  [ ! -e "$link" ] || { rm -rf "$TRELLIS_HOME/state/locks/$(readlink "$link")"; rm "$link"; }
  HOLDER="$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')"
  holder_dir="$(mktemp -d "$TRELLIS_HOME/state/locks/.attachment-$(jq -r '.checkout_id' "$JOURNAL")-$worktree.holder-$NEW_ID.$HOLDER.XXXXXX")"
  chmod 700 "$holder_dir"
  jq -cn --arg c "$(jq -r '.checkout_id' "$JOURNAL")" --arg w "$worktree" --arg a "$NEW_ID" --argjson p "$HOLDER" \
    --arg b "$(bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/attachment.sh"; _attachment_process_birth "$2"' _ "$REPO_ROOT" "$HOLDER")" \
    '{checkout_id:$c,worktree_id:$w,attachment_id:$a,pid:$p,process_birth:$b}' > "$holder_dir/owner.json"
  chmod 600 "$holder_dir/owner.json"
  ln -s "$(basename "$holder_dir")" "$link"
  local holder_sha
  holder_sha="$(detach_journal_sha256 "$holder_dir/owner.json")"
  run_discard "$OLD_ID"
  assert_refused 'a worktree attachment lock is live or unsafe'
  [ -L "$link" ]
  [ "$(readlink "$link")" = "$(basename "$holder_dir")" ]
  [ -d "$holder_dir" ]
  [ "$(detach_journal_sha256 "$holder_dir/owner.json")" = "$holder_sha" ]
}

@test "discard reclaims a validated dead worktree lock" {
  local checkout worktree link holder archived
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  checkout="$(jq -r '.checkout_id' "$JOURNAL")"
  worktree="$(jq -r '.worktree_id' "$JOURNAL")"
  link="$TRELLIS_HOME/state/locks/attachment-$checkout-$worktree.lock"
  # The killed detach leaves a genuine, validated dead holder for the old ID.
  [ -L "$link" ] || { echo 'killed detach left no worktree lock'; false; }
  holder="$TRELLIS_HOME/state/locks/$(readlink "$link")"
  jq -e --arg id "$OLD_ID" '.attachment_id == $id' "$holder/owner.json"
  run_discard "$OLD_ID"
  [ "$status" -eq 0 ] || { echo "status $status, stderr: $stderr"; false; }
  archived="$TRELLIS_HOME/backups/discarded-journals-$(date -u +%Y-%m-%d)/${JOURNAL##*/}"
  [ "$(detach_journal_sha256 "$archived")" = "$JOURNAL_SHA" ]
  [ ! -e "$link" ]
  [ ! -L "$link" ]
  [ ! -e "$holder" ]
}

@test "a different checkout cannot discard another checkout's valid journal" {
  local original="$PROJECT" other="$SANDBOX/other-checkout"
  git clone -q "$original" "$other"
  run --separate-stderr env TRELLIS_ATTACH_POSTJOB=off "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$other"
  [ "$status" -eq 0 ] || { echo "other attach: $status $stderr"; false; }
  PROJECT="$other"
  kill_detach_at attachment_detach_mark_external_phase 3
  JOURNAL="$(detach_journal_path)"
  OLD_ID="$(jq -r '.attachment_id' "$JOURNAL")"
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  PROJECT="$original"
  run_discard "$OLD_ID"
  assert_refused "journal does not bind to $(printf '%q' "$PROJECT")"
}

@test "discard rejects incomplete owner metadata" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  rewrite_json "$OWNER" '{checkout_id,worktree_id,worktree_root,attachment_id}'
  local before="$(detach_journal_sha256 "$OWNER")"
  run_discard "$OLD_ID"
  assert_refused 'the worktree has no valid owner record'
  [ "$(detach_journal_sha256 "$OWNER")" = "$before" ]
}

@test "discard rejects a symlinked owner record" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  mv "$OWNER" "$SANDBOX/actual-owner"
  ln -s "$SANDBOX/actual-owner" "$OWNER"
  run_discard "$OLD_ID"
  assert_refused 'the worktree has no valid owner record'
  [ -L "$OWNER" ]
  [ "$(readlink "$OWNER")" = "$SANDBOX/actual-owner" ]
}

@test "discard requires the owner checkout binding" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  rewrite_json "$OWNER" '.checkout_id = ("0" * 64)'
  run_discard "$OLD_ID"
  assert_refused "the owner record does not bind to $(printf '%q' "$PROJECT")"
}

@test "discard requires the owner root binding" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  rewrite_json "$OWNER" --arg other "$SANDBOX/other-root" '.worktree_root = $other'
  run_discard "$OLD_ID"
  assert_refused "the owner record does not bind to $(printf '%q' "$PROJECT")"
}

@test "discard rejects a symlinked journal" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  mv "$JOURNAL" "$SANDBOX/actual-journal"
  ln -s "$SANDBOX/actual-journal" "$JOURNAL"
  run_discard "$OLD_ID"
  assert_refused 'no detach journal uses this attachment ID'
  [ -L "$JOURNAL" ]
  [ "$(readlink "$JOURNAL")" = "$SANDBOX/actual-journal" ]
}

# Isolate the explicit journal-binding filter from the preceding structural
# validator, which normally rejects these one-field identity inconsistencies.
run_binding_check() {
  REFUSAL_STATE="$(capture_refusal_state)" || return 1
  run --separate-stderr bash -c '. "$1"; _attachment_detach_journal_valid() { return 0; }; identity="$(local_registry_identity_for_root "$4")"; attach_superseded_journal_check "$2" "$identity" "$4" "$3"' _ \
    "$ATTACH" "$TRELLIS_HOME" "$JOURNAL" "$PROJECT"
}

@test "discard binds the journal checkout field" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  rewrite_json "$JOURNAL" '.original_owner.checkout_id = ("0" * 64)'
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  run_binding_check
  assert_refused "journal does not bind to $(printf '%q' "$PROJECT")"
}

@test "discard binds the journal root field" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  rewrite_json "$JOURNAL" --arg other "$SANDBOX/other-root" '.original_owner.worktree_root = $other'
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  run_binding_check
  assert_refused "journal does not bind to $(printf '%q' "$PROJECT")"
}

@test "discard names a missing detach journal" {
  local before
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  before="$(detach_journal_sha256 "$JOURNAL")"
  mv "$JOURNAL" "$SANDBOX/saved-journal"
  run --separate-stderr "$ATTACH" recover --home "$TRELLIS_HOME" --discard-superseded-journal "$OLD_ID" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "$stderr" = "trellis attach: superseded journal discard refused: no detach journal uses this attachment ID; journal kept at $(printf '%q' "$JOURNAL")" ] || { echo "stderr: $stderr"; false; }
  [ ! -e "$JOURNAL" ]
  [ ! -L "$JOURNAL" ]
  [ "$(detach_journal_sha256 "$SANDBOX/saved-journal")" = "$before" ]
  [ ! -e "$TRELLIS_HOME/backups" ]
}

@test "discard rejects a structurally invalid detach journal" {
  kill_detach_at attachment_detach_mark_external_phase 3
  supersede
  rewrite_json "$JOURNAL" 'del(.external)'
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  run_discard "$OLD_ID"
  assert_refused 'invalid detach journal'
}

@test "an uncommitted detach journal is never discarded as superseded" {
  kill_detach_at q_rmdir 9
  JOURNAL="$(detach_journal_path)"
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  run_discard "$(jq -r '.attachment_id' "$JOURNAL")"
  assert_refused 'its owner commit has not happened; use normal trellis recover'
}

@test "a partial-harness detach journal is never discarded as superseded" {
  kill_detach_at owner_committed 1 --harness codex
  JOURNAL="$(detach_journal_path)"
  jq -e '.owner_committed == true and .next_owner != null' "$JOURNAL"
  JOURNAL_SHA="$(detach_journal_sha256 "$JOURNAL")"
  run_discard "$(jq -r '.attachment_id' "$JOURNAL")"
  assert_refused 'a partial-harness journal requires normal recovery'
}
