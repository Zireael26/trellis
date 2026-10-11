#!/usr/bin/env bats
# Journal v2 (1.3.12): the commit phase publishes every artifact from one
# process and appends each transition to a progress log instead of rewriting
# the journal. These cases kill that process at every durable step and recover,
# and cross the last pre-v2 release with this one in both directions.
#
# The kill comes from the crash-test seam: a copy of the commit program whose
# no-op `checkpoint` line is substituted here. The product has no switch for it.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
# The last commit before journal v2 (the 1.3.11 journal and commit loop).
PRE_V2_COMMIT=bdc21b05
SEAM='    return None  # crash-test seam'
KILL_SEAM='    checkpoint.calls = getattr(checkpoint, "calls", 0) + 1
    if checkpoint.calls == int(os.environ["A3_KILL_AT"]): os.kill(os.getpid(), signal.SIGKILL)'

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

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

# Every artifact kind and publish route: a parent, a sourced file inside it, an
# inline file with a mode, an in-place replacement, a symlink and an empty
# directory.
make_plan() {
  local root=${1:-$PROJECT} output=${2:-$PLAN} checkout worktree inline inline_sha before before_sha
  checkout=$(sha256_text "$(canonical_dir "$root/.git")")
  worktree=$(sha256_text "$root")
  inline=$(printf '{"rendered":true}\n' | base64 | tr -d '\n')
  inline_sha=$(printf '{"rendered":true}\n' | shasum -a 256 | cut -d ' ' -f 1)
  before=$(base64 < "$root/replaced.md" | tr -d '\n')
  before_sha=$(sha256_file "$root/replaced.md")
  jq -n \
    --arg checkout_id "$checkout" --arg worktree_id "$worktree" --arg attachment_id "$ATTACHMENT_ID" \
    --arg root "$root" --arg source "$SOURCE_FILE" --arg sha256 "$(sha256_file "$SOURCE_FILE")" \
    --arg inline "$inline" --arg inline_sha "$inline_sha" --arg before "$before" --arg before_sha "$before_sha" \
    '{
      schema_version: 1, status: "prepared", fleet: "fleet-a", project_id: "project-a",
      checkout_id: $checkout_id, worktree_id: $worktree_id, attachment_id: $attachment_id,
      project_root: $root, worktree_root: $root, release: "1.2.3",
      artifacts: [
        {path: "tools", kind: "parent"},
        {path: "tools/attached.txt", kind: "file", source: $source, sha256: $sha256},
        {path: "rendered.json", kind: "file", content_base64: $inline, sha256: $inline_sha, mode: "0640"},
        {path: "replaced.md", kind: "file", content_base64: $inline, sha256: $inline_sha, mode: "0644",
         replace: {before_base64: $before, before_mode: "0644", before_sha256: $before_sha}},
        {path: "tools/link.md", kind: "symlink", target: "attached.txt"},
        {path: "empty", kind: "directory"}
      ]
    }' > "$output"
  chmod 600 "$output"
}

make_project() {
  local root=$1
  mkdir -p "$root"
  git init -q "$root"
  printf 'project bytes\n' > "$root/replaced.md"
  chmod 644 "$root/replaced.md"
}

snapshot() {
  (
    cd "$1" || exit 1
    find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r entry; do
      if [ -L "$entry" ]; then
        printf '%s link %s\n' "$entry" "$(readlink "$entry")"
      elif [ -d "$entry" ]; then
        printf '%s dir %s\n' "$entry" "$(mode_of "$entry")"
      else
        printf '%s file %s %s\n' "$entry" "$(mode_of "$entry")" "$(sha256_file "$entry")"
      fi
    done
  )
}

killing_program() {
  local program patched
  program=$(_attachment_commit_program) || return 1
  patched=${program/"$SEAM"/"$KILL_SEAM"}
  # A substitution that matched nothing would make every case below vacuous.
  [ "$patched" != "$program" ] || return 1
  printf '%s\n' "$patched"
}

# The whole transaction dies: the publisher is killed and no shell survives to
# roll back, exactly as after a SIGKILL of attach.
killed_commit() {
  local step=$1
  _attachment_ensure_private_dir "$TRELLIS_HOME/state/attachment-progress" || return 1
  _attachment_ensure_private_dir "$ROOT/holder" || return 1
  A3_KILL_AT=$step python3 -I -c "$KILLING" "$JOURNAL" "$LOG" "" "$ROOT/holder" "$BASHPID"
}

have_pre_v2() {
  git -C "$REPO_ROOT" cat-file -e "$PRE_V2_COMMIT^{commit}" 2>/dev/null || return 1
  if [ ! -d "$ROOT/pre-v2" ]; then
    mkdir "$ROOT/pre-v2"
    git -C "$REPO_ROOT" archive "$PRE_V2_COMMIT" scripts/lib | tar -x -C "$ROOT/pre-v2" || return 1
  fi
  PRE_V2_LIB="$ROOT/pre-v2/scripts/lib"
}

# One public attachment entry point, run by the pre-v2 release.
pre_v2() {
  env -u TRELLIS_LIBS_PRELOADED /bin/bash --noprofile --norc -c '
    lib=$1
    shift
    source "$lib/attachment.sh" || exit 90
    "$@"
  ' pre-v2 "$PRE_V2_LIB" "$@"
}

setup() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/attachment-journal-v2.XXXXXX")
  ROOT=$(canonical_dir "$ROOT")
  TRELLIS_HOME="$ROOT/home"
  PROJECT="$ROOT/project"
  SOURCE_FILE="$ROOT/source/payload.txt"
  PLAN="$ROOT/plan.json"
  ATTACHMENT_ID="11111111-2222-3333-4444-555555555555"
  mkdir -p "$TRELLIS_HOME" "$ROOT/source"
  printf 'attachment payload\n' > "$SOURCE_FILE"
  make_project "$PROJECT"
  CHECKOUT_ID=$(sha256_text "$(canonical_dir "$PROJECT/.git")")
  WORKTREE_ID=$(sha256_text "$PROJECT")
  JOURNAL="$TRELLIS_HOME/state/attachment-journals/$ATTACHMENT_ID.json"
  LOG="$TRELLIS_HOME/state/attachment-progress/$ATTACHMENT_ID.log"
  OWNER="$TRELLIS_HOME/state/attachments/$CHECKOUT_ID/$WORKTREE_ID.json"
  source "$BATS_TEST_DIRNAME/../lib/attachment.sh"
  make_plan
}

teardown() {
  rm -rf "$ROOT"
}

@test "commit writes the journal once and logs per-artifact progress" {
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  KILLING=$(killing_program)
  journal_writes="$ROOT/journal-writes"
  : > "$journal_writes"
  eval "$(declare -f _attachment_write_json | sed '1s/_attachment_write_json/_counted_write_json/')"
  _attachment_write_json() {
    case "$1" in */attachment-journals/*) printf '%s\n' "$1" >> "$journal_writes" ;; esac
    _counted_write_json "$@"
  }

  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ -f "$OWNER" ]
  [ ! -e "$JOURNAL" ]
  [ ! -e "$LOG" ]
  [ ! -s "$journal_writes" ]

  # Mid-commit, the journal still holds its prepared phase and the log carries
  # the transitions: begin, then six pending/applied pairs among the rest.
  rm "$OWNER"
  rm -r "$PROJECT"
  make_project "$PROJECT"
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  status=0
  killed_commit 40 || status=$?
  [ "$status" -eq 137 ]
  jq -e '.journal_version == 2 and .phase == 0 and .applied == [] and .pending == null' "$JOURNAL"
  [ "$(mode_of "$LOG")" = 600 ]
  [ "$(head -n 1 "$LOG" | jq -r '.e')" = begin ]
  [ "$(grep -c '"e":"applied"' "$LOG")" -ge 3 ]
}

@test "a transaction killed at every durable step recovers to the pre-attach tree" {
  KILLING=$(killing_program)
  before=$(snapshot "$PROJECT")
  step=1
  while :; do
    attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
    status=0
    killed_commit "$step" || status=$?
    [ "$status" -ne 0 ] || break
    [ "$status" -eq 137 ] || { echo "step $step: publisher exited $status"; return 1; }
    run attachment_recover "$TRELLIS_HOME" "$JOURNAL"
    [ "$status" -eq 0 ] || { echo "step $step: recover exited $status: $output"; return 1; }
    [ ! -e "$JOURNAL" ] && [ ! -e "$LOG" ] || { echo "step $step: journal or log left"; return 1; }
    [ "$(snapshot "$PROJECT")" = "$before" ] || { echo "step $step:"; diff <(printf '%s\n' "$before") <(snapshot "$PROJECT"); return 1; }
    [ -z "$(find "$PROJECT" -name '.*attachment-stage-*' -o -name '.trellis-attachment-remove-*')" ] || return 1
    step=$((step + 1))
  done
  # Six artifacts cross far more than this many steps; fewer means the seam
  # stopped being reached.
  [ "$step" -gt 40 ]

  # The unkilled run published everything without an owner: recovery rolls it back.
  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"
  [ "$status" -eq 0 ]
  [ "$(snapshot "$PROJECT")" = "$before" ]
}

@test "a publisher killed at every third durable step is rolled back by its own commit" {
  KILLING=$(killing_program)
  _attachment_commit_program() { printf '%s\n' "$KILLING"; }
  before=$(snapshot "$PROJECT")
  step=1
  while :; do
    attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
    status=0
    A3_KILL_AT=$step attachment_commit "$TRELLIS_HOME" "$JOURNAL" || status=$?
    [ "$status" -ne 0 ] || break
    [ ! -e "$JOURNAL" ] && [ ! -e "$LOG" ] && [ ! -e "$OWNER" ] || { echo "step $step: state left"; return 1; }
    [ "$(snapshot "$PROJECT")" = "$before" ] || { echo "step $step:"; diff <(printf '%s\n' "$before") <(snapshot "$PROJECT"); return 1; }
    step=$((step + 3))
  done
  [ "$step" -gt 40 ]
  [ -f "$OWNER" ]
  run attachment_verify_detach "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
}

@test "a stale log beside an already folded journal is dropped, not replayed" {
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  KILLING=$(killing_program)
  status=0
  killed_commit 30 || status=$?
  [ "$status" -eq 137 ]
  folded=$(jq -c 'del(.journal_version)' "$JOURNAL")
  printf '%s\n' "$folded" > "$JOURNAL"
  before=$(snapshot "$PROJECT")

  run attachment_rollback "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
  [ ! -e "$JOURNAL" ]
  # The prepared prefix was empty, so nothing the log recorded is removed.
  [ "$(snapshot "$PROJECT")" = "$before" ]
}

@test "a corrupt progress log is refused and leaves the journal untouched" {
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  KILLING=$(killing_program)
  status=0
  killed_commit 20 || status=$?
  [ "$status" -eq 137 ]
  printf '{"e":"applied","index":5}\n' >> "$LOG"
  journal_sha=$(sha256_file "$JOURNAL")

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 4 ]
  [ "$(sha256_file "$JOURNAL")" = "$journal_sha" ]
  [ -f "$LOG" ]
}

@test "a torn final progress line is the step before it, and recovers" {
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  KILLING=$(killing_program)
  before=$(snapshot "$PROJECT")
  status=0
  killed_commit 25 || status=$?
  [ "$status" -eq 137 ]
  printf '{"e":"pending","ind' >> "$LOG"

  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 0 ]
  [ "$(snapshot "$PROJECT")" = "$before" ]
}

@test "the pre-v2 release refuses a v2 journal at every third step without touching it" {
  have_pre_v2 || skip "the pre-v2 release ($PRE_V2_COMMIT) is not in this clone's history"
  KILLING=$(killing_program)
  before=$(snapshot "$PROJECT")
  step=1
  while :; do
    attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
    status=0
    killed_commit "$step" || status=$?
    [ "$status" -ne 0 ] || break
    journal_sha=$(sha256_file "$JOURNAL")
    log_sha=$(sha256_file "$LOG" 2>/dev/null || printf none)
    tree=$(snapshot "$PROJECT")

    run pre_v2 attachment_recover "$TRELLIS_HOME" "$JOURNAL"

    [ "$status" -ne 0 ] || { echo "step $step: the pre-v2 release recovered a v2 journal"; return 1; }
    [ "$(sha256_file "$JOURNAL")" = "$journal_sha" ] || return 1
    [ "$(sha256_file "$LOG" 2>/dev/null || printf none)" = "$log_sha" ] || return 1
    [ "$(snapshot "$PROJECT")" = "$tree" ] || return 1

    run attachment_recover "$TRELLIS_HOME" "$JOURNAL"
    [ "$status" -eq 0 ] || { echo "step $step: recover exited $status"; return 1; }
    [ "$(snapshot "$PROJECT")" = "$before" ] || return 1
    step=$((step + 3))
  done
  [ "$step" -gt 40 ]
}

@test "a v1 journal from a killed pre-v2 commit recovers under this release" {
  have_pre_v2 || skip "the pre-v2 release ($PRE_V2_COMMIT) is not in this clone's history"
  before=$(snapshot "$PROJECT")
  write=1
  while :; do
    pre_v2 attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
    rm -f "$ROOT/writes"
    status=0
    perl -e 'setpgrp(0, 0); exec @ARGV' env -u TRELLIS_LIBS_PRELOADED /bin/bash --noprofile --norc -c '
      source "$1/attachment.sh" || exit 90
      KILL_AT=$3 COUNTER=$4
      eval "$(declare -f _attachment_write_json | sed "1s/_attachment_write_json/_pre_v2_write_json/")"
      _attachment_write_json() {
        _pre_v2_write_json "$@" || return
        case "$1" in */attachment-journals/*) ;; *) return 0 ;; esac
        printf x >> "$COUNTER"
        [ "$(wc -c < "$COUNTER")" -lt "$KILL_AT" ] || kill -KILL -- "-$$"
      }
      attachment_commit "$2" "$5"
    ' pre-v2 "$PRE_V2_LIB" "$TRELLIS_HOME" "$write" "$ROOT/writes" "$JOURNAL" || status=$?
    [ "$status" -ne 0 ] || break
    [ "$status" -eq 137 ] || { echo "write $write: pre-v2 commit exited $status"; return 1; }
    jq -e 'has("journal_version") | not' "$JOURNAL"

    run attachment_recover "$TRELLIS_HOME" "$JOURNAL"

    [ "$status" -eq 0 ] || { echo "write $write: recover exited $status: $output"; return 1; }
    [ ! -e "$JOURNAL" ] || return 1
    [ "$(snapshot "$PROJECT")" = "$before" ] || { echo "write $write:"; diff <(printf '%s\n' "$before") <(snapshot "$PROJECT"); return 1; }
    write=$((write + 1))
  done
  [ "$write" -gt 20 ]
  run attachment_verify_detach "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
}

@test "both releases publish the same tree and owner record for one plan" {
  have_pre_v2 || skip "the pre-v2 release ($PRE_V2_COMMIT) is not in this clone's history"
  other="$ROOT/other"
  make_project "$other"
  make_plan "$other" "$ROOT/plan-other.json"
  other_checkout=$(sha256_text "$(canonical_dir "$other/.git")")
  other_worktree=$(sha256_text "$other")

  pre_v2 attachment_prepare "$TRELLIS_HOME" "$ROOT/plan-other.json" "$JOURNAL"
  pre_v2 attachment_commit "$TRELLIS_HOME" "$JOURNAL"
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$(snapshot "$PROJECT")" = "$(snapshot "$other")" ]
  normalize() {
    jq -cS 'del(.checkout_id, .worktree_id, .project_root, .worktree_root)' "$1"
  }
  [ "$(normalize "$OWNER")" = "$(normalize "$TRELLIS_HOME/state/attachments/$other_checkout/$other_worktree.json")" ]

  # Each release detach-verifies the other's owner record.
  run attachment_verify_detach "$TRELLIS_HOME" "$TRELLIS_HOME/state/attachments/$other_checkout/$other_worktree.json"
  [ "$status" -eq 0 ]
  run pre_v2 attachment_verify_detach "$TRELLIS_HOME" "$OWNER"
  [ "$status" -eq 0 ]
}

# A copy of the commit program with the crash-test seam replaced by $1.
seamed_program() {
  local program patched
  program=$(_attachment_commit_program) || return 1
  patched=${program/"$SEAM"/"$1"}
  [ "$patched" != "$program" ] || return 1
  printf '%s\n' "$patched"
}

@test "recovery waits for a publisher that outlives its killed lock owner" {
  # The publisher logs the last artifact's pending record, then pauses before
  # creating its stage until the test lets it go.
  PAUSING=$(seamed_program '    if label == "pending":
        checkpoint.calls = getattr(checkpoint, "calls", 0) + 1
        if checkpoint.calls == 6:
            with open(os.environ["A3_PAUSED"], "w") as handle:
                handle.write("%d\n" % os.getpid())
            while not os.path.exists(os.environ["A3_GO"]):
                time.sleep(0.05)
    return None')
  PAUSING=${PAUSING/"import sys"/"import sys
import time"}
  _attachment_commit_program() { printf '%s\n' "$PAUSING"; }
  export A3_PAUSED="$ROOT/paused" A3_GO="$ROOT/go"
  before=$(snapshot "$PROJECT")
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  attachment_commit "$TRELLIS_HOME" "$JOURNAL" > "$ROOT/commit.out" 2>&1 3>&- &
  for _ in $(seq 1 600); do [ -s "$A3_PAUSED" ] && break; sleep 0.05; done
  [ -s "$A3_PAUSED" ]
  publisher=$(cat "$A3_PAUSED")
  link="$TRELLIS_HOME/state/locks/attachment-$CHECKOUT_ID-$WORKTREE_ID.lock"
  owner_pid=$(jq -r '.pid' "$TRELLIS_HOME/state/locks/$(readlink "$link")/owner.json")
  [ "$owner_pid" != "$publisher" ]
  kill -KILL "$owner_pid"
  while kill -0 "$owner_pid" 2>/dev/null; do sleep 0.05; done
  journal_sha=$(sha256_file "$JOURNAL")
  log_sha=$(sha256_file "$LOG")

  # The lock owner is dead but its publisher is not: recovery must not fold
  # and roll back under it.
  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"
  recover_status=$status

  touch "$A3_GO"
  for _ in $(seq 1 600); do kill -0 "$publisher" 2>/dev/null || break; sleep 0.05; done
  ! kill -0 "$publisher" 2>/dev/null
  wait || true
  [ "$recover_status" -eq 3 ] || { echo "recover under a live publisher exited $recover_status: $output"; return 1; }
  [ "$(sha256_file "$JOURNAL")" = "$journal_sha" ]
  [ "$(sha256_file "$LOG")" = "$log_sha" ]

  # Once the publisher has stopped, recovery owns the worktree and leaves no
  # stage behind.
  run attachment_recover "$TRELLIS_HOME" "$JOURNAL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$JOURNAL" ] && [ ! -e "$LOG" ]
  [ "$(snapshot "$PROJECT")" = "$before" ] || { diff <(printf '%s\n' "$before") <(snapshot "$PROJECT"); return 1; }
  [ -z "$(find "$PROJECT" -name '.*attachment-stage-*' -o -name '.trellis-attachment-remove-*')" ]
  [ ! -e "$link" ] && [ ! -L "$link" ]
}

@test "a directory raced into the destination is refused, not replaced" {
  # A project writer creates the empty directory's destination right after
  # the publisher's absence check and before the stage is renamed onto it.
  RACING=$(seamed_program '    if label == "staging_identity":
        checkpoint.calls = getattr(checkpoint, "calls", 0) + 1
        if checkpoint.calls == 6:
            checked = globals()["exists"]
            def racing(path):
                result = checked(path)
                if path == "./empty" and not result and not checked(os.environ["A3_RACE_DIR"]):
                    os.mkdir(os.environ["A3_RACE_DIR"], 0o755)
                    with open(os.environ["A3_RACE_INODE"], "w") as handle:
                        handle.write("%d\n" % os.lstat(os.environ["A3_RACE_DIR"]).st_ino)
                return result
            globals()["exists"] = racing
    return None')
  _attachment_commit_program() { printf '%s\n' "$RACING"; }
  export A3_RACE_DIR="$PROJECT/empty" A3_RACE_INODE="$ROOT/race-inode"

  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -eq 3 ] || { echo "commit exited $status: $output"; return 1; }
  [ -s "$A3_RACE_INODE" ]
  # The writer's directory is still there, and is still the writer's.
  [ -d "$PROJECT/empty" ] && [ ! -L "$PROJECT/empty" ]
  [ "$(stat -f %i "$PROJECT/empty" 2>/dev/null || stat -c %i "$PROJECT/empty")" = "$(cat "$A3_RACE_INODE")" ]
  [ ! -e "$JOURNAL" ] && [ ! -e "$LOG" ] && [ ! -e "$OWNER" ]
  [ -z "$(find "$PROJECT" -name '.*attachment-stage-*' -o -name '.trellis-attachment-remove-*')" ]
}

@test "a publisher whose lock owner is already gone stops before any write" {
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  before=$(snapshot "$PROJECT")
  journal_sha=$(sha256_file "$JOURNAL")
  _attachment_ensure_private_dir "$TRELLIS_HOME/state/attachment-progress"
  _attachment_ensure_private_dir "$ROOT/holder"

  # Recorded owner pid 1 is never our parent: the shell that took the lock is gone.
  run python3 -I -c "$(_attachment_commit_program)" "$JOURNAL" "$LOG" "" "$ROOT/holder" 1

  # The dedicated orphan refusal, not a crash.
  [ "$status" -eq 76 ] || { echo "publisher exited $status: $output"; return 1; }
  [[ "$output" == *"the transaction lock owner is gone"* ]] || { echo "$output"; return 1; }
  [ "$(sha256_file "$JOURNAL")" = "$journal_sha" ]
  [ ! -e "$LOG" ]
  [ "$(snapshot "$PROJECT")" = "$before" ]
}

@test "a publisher orphaned before it starts publishing never adopts its new parent" {
  # The publisher pauses right after taking its flock, before it reads the
  # journal, while the test kills the shell that owns the lock.
  local hold='        hold_transaction_lock(holder, int(owner_pid))'
  ORPHANING=$(_attachment_commit_program)
  [[ "$ORPHANING" == *"$hold"* ]]
  ORPHANING=${ORPHANING/"$hold"/"$hold
        with open(os.environ[\"A3_PAUSED\"], \"w\") as handle:
            handle.write(\"%d\\n\" % os.getpid())
        while not os.path.exists(os.environ[\"A3_GO\"]):
            time.sleep(0.05)"}
  ORPHANING=${ORPHANING/"import sys"/"import sys
import time"}
  _attachment_commit_program() { printf '%s\n' "$ORPHANING"; }
  export A3_PAUSED="$ROOT/paused" A3_GO="$ROOT/go"
  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  before=$(snapshot "$PROJECT")
  journal_sha=$(sha256_file "$JOURNAL")
  attachment_commit "$TRELLIS_HOME" "$JOURNAL" > "$ROOT/commit.out" 2>&1 3>&- &
  for _ in $(seq 1 600); do [ -s "$A3_PAUSED" ] && break; sleep 0.05; done
  [ -s "$A3_PAUSED" ] || { cat "$ROOT/commit.out"; return 1; }
  publisher=$(cat "$A3_PAUSED")
  link="$TRELLIS_HOME/state/locks/attachment-$CHECKOUT_ID-$WORKTREE_ID.lock"
  owner_pid=$(jq -r '.pid' "$TRELLIS_HOME/state/locks/$(readlink "$link")/owner.json")
  kill -KILL "$owner_pid"
  while kill -0 "$owner_pid" 2>/dev/null; do sleep 0.05; done

  touch "$A3_GO"
  for _ in $(seq 1 600); do kill -0 "$publisher" 2>/dev/null || break; sleep 0.05; done
  ! kill -0 "$publisher" 2>/dev/null
  wait || true

  # No write at all: no v2 mark, no progress record, no stage or artifact.
  [ "$(sha256_file "$JOURNAL")" = "$journal_sha" ] || { jq -c '{journal_version, phase}' "$JOURNAL"; return 1; }
  [ ! -e "$LOG" ] || { echo "progress records: $(wc -l < "$LOG")"; return 1; }
  [ "$(snapshot "$PROJECT")" = "$before" ] || { diff <(printf '%s\n' "$before") <(snapshot "$PROJECT"); return 1; }
  grep -q "the transaction lock owner is gone" "$ROOT/commit.out" || { cat "$ROOT/commit.out"; return 1; }
}

# Swap the first fresh entry named $1* in the publisher's pinned directory for
# a symlink to $A3_OUTSIDE, right after the step labelled $2 creates it.
swapping_program() {
  seamed_program "    if label == \"$2\" and not getattr(checkpoint, \"swapped\", False):
        checkpoint.swapped = True
        name = [entry for entry in os.listdir(\".\") if entry.startswith(\"$1\")][0]
        os.rmdir(name)
        os.symlink(os.environ[\"A3_OUTSIDE\"], name)
    return None"
}

@test "a stage directory swapped for a symlink is not chmodded through it" {
  SWAPPING=$(swapping_program .tools.attachment-stage- stage-created)
  _attachment_commit_program() { printf '%s\n' "$SWAPPING"; }
  export A3_OUTSIDE="$ROOT/outside"
  mkdir "$A3_OUTSIDE"
  chmod 755 "$A3_OUTSIDE"

  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -ne 0 ]
  [ "$(mode_of "$A3_OUTSIDE")" = 755 ]
  [ -z "$(ls -A "$A3_OUTSIDE")" ]
  [ ! -e "$OWNER" ]
}

@test "a quarantine swapped for a symlink does not move the stage through it" {
  SWAPPING=$(swapping_program .trellis-attachment-remove- quarantine-created)
  _attachment_commit_program() { printf '%s\n' "$SWAPPING"; }
  export A3_OUTSIDE="$ROOT/outside"
  mkdir "$A3_OUTSIDE"
  chmod 755 "$A3_OUTSIDE"

  attachment_prepare "$TRELLIS_HOME" "$PLAN" "$JOURNAL"
  run attachment_commit "$TRELLIS_HOME" "$JOURNAL"

  [ "$status" -ne 0 ]
  [ "$(mode_of "$A3_OUTSIDE")" = 755 ]
  [ -z "$(ls -A "$A3_OUTSIDE")" ] || { ls -la "$A3_OUTSIDE"; return 1; }
  [ ! -e "$OWNER" ]
}
