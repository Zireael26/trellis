#!/usr/bin/env bats
# 1.5.1 native detach: a detach commit's removal loop (preflight, removal
# intent, quarantine claim, exact check, remove, clear, phase) runs in one
# Python process, and a checkout's owners are verified in one pass. The durable
# states are the v1 detach journal's, so a crash at any step recovers, by this
# release or by 1.5.0, which only has the shell protocol; and every refusal is
# the one 1.5.0 printed.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/release-fixture
load helpers/detach-journal
bats_require_minimum_version 1.5.0

# 1.5.0 (main at the start of 1.5.1): the shell-only detach protocol.
BASE_REV=cf8be187a
STEPS="intent q_mkdir q_claim q_rm q_rmdir clear phase"

setup_file() {
  detach_journal_setup_file
}

teardown_file() {
  detach_journal_teardown_file
}

setup() {
  detach_journal_setup
  NEW_ATTACH="$REPO_ROOT/scripts/attach-project.sh"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

# The 1.5.0 scripts, once per file, outside the sandbox the cases restore.
have_base() {
  local base
  base="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/base-$BASE_REV"
  git -C "$REPO_ROOT" cat-file -e "$BASE_REV^{commit}" 2>/dev/null || return 1
  if [ ! -d "$base" ]; then
    mkdir -p "$base.tmp" || return 1
    git -C "$REPO_ROOT" archive "$BASE_REV" scripts | tar -x -C "$base.tmp" || return 1
    mv "$base.tmp" "$base" || return 1
  fi
  BASE_ATTACH="$base/scripts/attach-project.sh"
}

recover_with() {
  run --separate-stderr "$1" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "recover by $1 after $2: status $status, stderr: $stderr"; false; }
  assert_detached || { echo "recover by $1 after $2 left attachment state"; false; }
}

# The journal a killed native commit leaves is a valid v1 detach journal.
assert_v1_journal() {
  local journal
  journal="$(detach_journal_path)"
  [ "$(stat -c %a "$journal" 2>/dev/null || stat -f %Lp "$journal")" = 600 ]
  jq -e '
    .schema_version == 1 and .status == "detaching" and .owner_committed == false
    and (has("journal_version") | not)
    and (.removal == null or ((.removal | keys) == ["nonce","path"] and (.removal.nonce | test("^[a-f0-9]{64}$"))))
  ' "$journal" >/dev/null || { jq -c '{schema_version,status,phase,owner_committed,removal}' "$journal"; false; }
  bash -c '. "$1"; _attachment_detach_journal_valid "$2"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$journal"
}

# The shell loop's seven kill points per artifact are all still there. Clear
# and phase now name the same durable write (owner ruling 2026-11-11, option
# A), so a removal is six journal and filesystem steps.
@test "the native commit keeps the seven kill points per artifact of the shell loop" {
  local total
  kill_detach_at phase 1
  total="$(jq '.remove | length' "$(detach_journal_path)")"
  [ "$total" -ge 3 ]
  # A kill past the last step finds nothing to kill at: 7 steps per artifact.
  detach_journal_setup
  kill_detach_at any "$((7 * total))"
  jq -e --argjson total "$total" '.phase == $total and .removal == null and .owner_committed == false' "$(detach_journal_path)" >/dev/null
  # Then the owner commit (spec 075 T4b: native): the owner record removed,
  # owner_committed journaled, then finish mark 1.
  detach_journal_setup
  kill_detach_at any "$((7 * total + 1))"
  jq -e '.owner_committed == false and .phase == (.remove | length)' "$(detach_journal_path)" >/dev/null
  [ -z "$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json')" ]
  detach_journal_setup
  kill_detach_at any "$((7 * total + 2))"
  jq -e '.owner_committed == true and .external.phase == 0' "$(detach_journal_path)" >/dev/null
  detach_journal_setup
  kill_detach_at any "$((7 * total + 3))"
  jq -e '.owner_committed == true and .external.phase == 1 and .external.render_phase == 0' "$(detach_journal_path)" >/dev/null
}

RENDER_STEPS="attachment_detach_render_stage attachment_detach_render_claim attachment_detach_render_publish
  attachment_detach_render_cleanup attachment_detach_render_finish attachment_detach_mark_external_phase"

# Every durable step of finish phases 1 and 2 (mark 1, each render's stage,
# claim, publish, cleanup and finish with their claims, mark 2), one kill each.
@test "a detach killed at every durable step of its native render restore recovers" {
  local total first nth steps=0
  kill_detach_at phase 1
  total="$(jq '.remove | length' "$(detach_journal_path)")"
  # After the owner commit's two steps (spec 075 T4b).
  first=$((7 * total + 3))
  nth=$first
  while :; do
    detach_journal_setup
    kill_detach_at any "$nth" 2>/dev/null || true
    [ "$KILL_STATUS" -ne 0 ] || break
    [ "$KILL_STATUS" -eq 137 ] && [ "$KILL_HITS" -eq "$nth" ] || { echo "kill at step $nth: status $KILL_STATUS"; false; }
    jq -e '.owner_committed == true and .external.phase >= 1 and .external.phase <= 5' "$(detach_journal_path)" >/dev/null ||
      { echo "step $nth: $(jq -c '{owner_committed,external:(.external|{phase,render_phase})}' "$(detach_journal_path)")"; false; }
    recover_with "$NEW_ATTACH" "render step $nth"
    steps=$((steps + 1))
    nth=$((nth + 1))
    [ "$steps" -lt 120 ] || { echo 'no end to the render steps'; false; }
  done
  # Mark 1, at least two renders of several steps each, mark 2.
  [ "$steps" -ge 12 ] || { echo "only $steps render steps"; false; }
  assert_detached
}

@test "1.5.0 recovers a journal the native render restore left at every render kill point" {
  local point nth
  have_base || skip "1.5.0 ($BASE_REV) is not in this clone"
  for point in $RENDER_STEPS; do
    for nth in 1 2; do
      detach_journal_setup
      kill_detach_at "$point" "$nth"
      recover_with "$BASE_ATTACH" "native $point #$nth"
    done
  done
}

@test "the native render restore recovers a journal 1.5.0 left at every render kill point" {
  local point nth
  have_base || skip "1.5.0 ($BASE_REV) is not in this clone"
  for point in $RENDER_STEPS; do
    for nth in 1 2; do
      detach_journal_setup
      ATTACH="$BASE_ATTACH" kill_detach_at "$point" "$nth"
      recover_with "$NEW_ATTACH" "1.5.0 $point #$nth"
    done
  done
}

@test "a native commit killed at every kind of step of its first and last removal recovers" {
  local point total nth
  kill_detach_at phase 1
  total="$(jq '.remove | length' "$(detach_journal_path)")"
  for nth in 1 "$total"; do
    for point in $STEPS; do
      detach_journal_setup
      kill_detach_at "$point" "$nth"
      assert_v1_journal
      recover_with "$NEW_ATTACH" "$point #$nth"
    done
  done
}

@test "1.5.0 recovers a journal the native commit left at every kind of step" {
  local point nth
  have_base || skip "1.5.0 ($BASE_REV) is not in this clone"
  for nth in 1 2; do
    for point in $STEPS; do
      detach_journal_setup
      kill_detach_at "$point" "$nth"
      recover_with "$BASE_ATTACH" "native $point #$nth"
    done
  done
}

# 1.5.0 journaled the first clear and phase 1 separately. Killed between them,
# the journal says phase 0 with no removal while the first leaf is gone, and
# the phase-0 preflight refuses that leaf forever. 1.5.1 never leaves that
# state (owner ruling 2026-11-11, option A); a journal 1.5.0 left in it needs
# the manual step written in the 1.5.1 detach report, exercised here.
@test "a kill at the first clear recovers; the 1.5.0 journal stuck there recovers after the manual step" {
  local journal first tmp
  kill_detach_at clear 1
  journal="$(detach_journal_path)"
  jq -e '.phase == 1 and .removal == null and .owner_committed == false' "$journal" >/dev/null
  recover_with "$NEW_ATTACH" "native clear #1"
  if have_base; then
    detach_journal_setup
    kill_detach_at clear 1
    recover_with "$BASE_ATTACH" "native clear #1"

    detach_journal_setup
    ATTACH="$BASE_ATTACH" kill_detach_at clear 1
    journal="$(detach_journal_path)"
    first="$PROJECT/$(jq -r '.remove[0].path' "$journal")"
    jq -e '.phase == 0 and .removal == null and .owner_committed == false' "$journal" >/dev/null
    [ ! -e "$first" ] && [ ! -L "$first" ]
    run --separate-stderr "$BASE_ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 3 ]
    [ "$stderr" = "trellis recover: refused (artifact-changed): $first" ]
    run --separate-stderr "$NEW_ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 3 ]
    [ "$stderr" = "trellis recover: refused (artifact-changed): $first" ]
    # The manual step: the first leaf is gone and no quarantine is left in
    # its parent, so journal phase 1, private and atomic, as 1.5.0 would have.
    [ -z "$(find "$(dirname "$first")" -maxdepth 1 -name '.trellis-attachment-remove-*' -print)" ]
    tmp="$(mktemp "$journal.tmp.XXXXXX")"
    chmod 600 "$tmp"
    jq -cS '.phase = 1' "$journal" > "$tmp"
    mv -f "$tmp" "$journal"
    recover_with "$NEW_ATTACH" "1.5.0 clear #1 after the manual step"
  fi
}

@test "the native commit recovers a journal 1.5.0 left at every kind of step" {
  local point
  have_base || skip "1.5.0 ($BASE_REV) is not in this clone"
  for point in $STEPS; do
    detach_journal_setup
    ATTACH="$BASE_ATTACH" kill_detach_at "$point" 2
    recover_with "$NEW_ATTACH" "1.5.0 $point #2"
  done
}

@test "the native commit stops before its next write once the lock-holding shell is gone" {
  local journal before
  # At the first claim, the program SIGKILLs the shell that holds the
  # worktree lock and carries on: its next write must not happen.
  run --separate-stderr python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' bash -c '
    . "$1"; shift
    eval "$(declare -f _attachment_detach_program | sed "1s/^_attachment_detach_program /__orig_program /")"
    _attachment_detach_program() {
      __orig_program | python3 -c "
import sys
text = sys.stdin.read()
seam = \"    return None  # crash-test seam\"
if text.count(seam) != 1:
    sys.exit(1)
sys.stdout.write(text.replace(seam, \"    if label == \\\"q_claim\\\": os.kill(os.getppid(), signal.SIGKILL); import time; time.sleep(1)\"))
"
    }
    main "$@"
  ' orphan "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  # The killed lock holder fails the commit; the program, now orphaned, exits
  # at its next write instead of making it.
  [ "$status" -ne 0 ]
  sleep 2
  journal="$(detach_journal_path)"
  # Intent journaled, leaf claimed, nothing after: no removal, no clear.
  jq -e '.phase == 0 and .removal != null' "$journal" >/dev/null
  [ -n "$(find "$PROJECT" -path '*/.trellis-attachment-remove-*/artifact' -print)" ]
  before="$(detach_journal_sha256 "$journal")"
  sleep 1
  [ "$(detach_journal_sha256 "$journal")" = "$before" ]
  recover_with "$NEW_ATTACH" orphaned
}

# --- one-pass owner verification -------------------------------------------

attach_siblings() {
  local index root
  for ((index = 1; index <= $1; index++)); do
    root="$SANDBOX/sibling $index"
    git -C "$PROJECT" worktree add -q -b "sibling-$index" "$root" || return 1
    TRELLIS_ATTACH_POSTJOB=off "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$root" >/dev/null || return 1
  done
}

owner_files() {
  find "$TRELLIS_HOME/state/attachments" -mindepth 2 -maxdepth 2 -name '*.json' -print | LC_ALL=C sort
}

owner_of() {
  local owner
  while IFS= read -r owner; do
    [ "$(jq -r '.worktree_root' "$owner")" != "$1" ] || printf '%s\n' "$owner"
  done < <(owner_files)
}

batch() {
  local -a files=()
  local owner
  while IFS= read -r owner; do files+=("$owner"); done < <(owner_files)
  bash -c '. "$1"; shift; attachment_detach_owners_batch "$@"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "${files[@]}"
}

serial() {
  bash -c '
    . "$1"; home=$2; owners="[]"
    while IFS= read -r owner; do
      attachment_verify_detach "$home" "$owner" || exit $?
      record=$(jq -cS . "$owner") || exit 4
      owners=$(trellis_jq -cn --argjson current "$owners" --arg path "$owner" --argjson record "$record" "\$current + [{path:\$path,record:\$record}]") || exit 4
    done
    printf "%s\n" "$owners"
  ' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" < <(owner_files)
}

@test "the one-pass owner check prints exactly what the per-owner checks print" {
  local fast slow
  attach_siblings 3
  [ "$(owner_files | wc -l | tr -d ' ')" -eq 4 ]
  fast="$(batch)"
  slow="$(serial)"
  [ -n "$fast" ]
  [ "$fast" = "$slow" ]
}

# A tampered sibling fails the one-pass check (status 10), and the detach of
# another worktree refuses exactly as 1.5.0 refused it.
detach_refusal_matches_base() {
  local tamper="$1" new_status new_stderr
  run batch
  [ "$status" -eq 10 ] || { echo "$tamper: batch status $status"; false; }
  [ -z "$output" ]
  run --separate-stderr "$NEW_ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  new_status=$status new_stderr=$stderr
  [ "$new_status" -ne 0 ] || { echo "$tamper: detach passed"; false; }
  [ -n "$(owner_of "$PROJECT")" ] || { echo "$tamper: refused detach removed the owner"; false; }
  if have_base; then
    run --separate-stderr "$BASE_ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq "$new_status" ] && [ "$stderr" = "$new_stderr" ] ||
      { printf '%s:\n new %s %s\n base %s %s\n' "$tamper" "$new_status" "$new_stderr" "$status" "$stderr"; false; }
  fi
}

two_documents() {
  cat "$1" "$1" > "$1.next" && chmod 600 "$1.next" && mv "$1.next" "$1"
}

@test "every check of the one-pass owner verification falls back to the refusal 1.5.0 names" {
  local pristine sibling owner leaf link tamper first second
  attach_siblings 2
  sibling="$SANDBOX/sibling 2"
  pristine="$SANDBOX.siblings"
  rm -rf "$pristine"
  cp -Rp "$SANDBOX" "$pristine"
  for tamper in mode schema location root file symlink missing empty blank two empty-two two-empty invalid-names; do
    chmod -R u+w "$SANDBOX"; rm -rf "$SANDBOX"; cp -Rp "$pristine" "$SANDBOX"
    owner="$(owner_of "$sibling")"
    case "$tamper" in
      mode) chmod 644 "$owner" ;;
      schema) jq -c '. + {unexpected: true}' "$owner" > "$owner.next" && chmod 600 "$owner.next" && mv "$owner.next" "$owner" ;;
      location) mv "$owner" "$(dirname "$owner")/$(printf '0%.0s' {1..64}).json" ;;
      root) mv "$sibling" "$SANDBOX/moved sibling" && ln -s "$SANDBOX/moved sibling" "$sibling" ;;
      file)
        leaf="$(jq -r '[.artifacts[] | select(.kind == "file") | .path] | sort | .[0]' "$owner")"
        [ "$leaf" != null ]
        chmod u+w "$sibling/$leaf"; printf 'drift\n' >> "$sibling/$leaf" ;;
      symlink)
        link="$(jq -r '[.artifacts[] | select(.kind == "symlink") | .path] | sort | .[0]' "$owner")"
        ln -sfn "$SANDBOX/elsewhere" "$sibling/$link" ;;
      missing)
        # Not .trellis/runtime: a withdrawn runtime anchor is accepted.
        link="$(jq -r '[.artifacts[] | select(.kind == "symlink" and .path != ".trellis/runtime") | .path] | sort | .[-1]' "$owner")"
        rm "$sibling/$link" ;;
      # A file of no JSON document, or of two: jq's inputs yield no record or
      # two for it, so the pass must name exactly the requested files.
      empty) : > "$owner" ;;
      blank) printf ' \n\t\n' > "$owner" ;;
      two) two_documents "$owner" ;;
      # An empty owner and a two-document one: as many documents as files,
      # so only the requested paths, in order, tell them apart. Both orders.
      empty-two|two-empty)
        first="$(printf '%s\n' "$(owner_of "$SANDBOX/sibling 1")" "$(owner_of "$sibling")" | LC_ALL=C sort | head -1)"
        second="$(printf '%s\n' "$(owner_of "$SANDBOX/sibling 1")" "$(owner_of "$sibling")" | LC_ALL=C sort | tail -1)"
        [ "$first" != "$second" ]
        if [ "$tamper" = empty-two ]; then : > "$first"; two_documents "$second"; else two_documents "$first"; : > "$second"; fi ;;
      # Two owner names that are not UTF-8 decode to the same string in jq
      # (U+FFFD): an empty one beside one of two documents must not pass as
      # two checked owners (Sol r152-perf-2 M1-R).
      invalid-names)
        # APFS refuses such names (EILSEQ); Linux file systems take them.
        first="$(dirname "$owner")/"$'\xff'".json"
        second="$(dirname "$owner")/"$'\xfe'".json"
        if ! { : > "$first"; } 2>/dev/null; then
          echo "# invalid-names: this file system refuses non-UTF-8 names; case not run here" >&3
          continue
        fi
        cat "$owner" "$owner" > "$second"
        chmod 600 "$first" "$second" ;;
    esac
    detach_refusal_matches_base "$tamper"
  done
  chmod -R u+w "$pristine"; rm -rf "$pristine"
}

# Every owner path the batch takes is <checkout id>/<worktree id>.json and
# requested once; a repeated path (whose documents would match the repeated
# list) or another name misses the batch, and the per-owner path decides
# (Sol r152-perf-2 M1-R, the shared _attachment_paths_json).
@test "the one-pass owner batch misses a repeated or non-canonical owner path" {
  local -a files=()
  local owner other
  attach_siblings 1
  while IFS= read -r owner; do files+=("$owner"); done < <(owner_files)
  [ "${#files[@]}" -eq 2 ]
  run bash -c '. "$1"; shift; attachment_detach_owners_batch "$@"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "${files[@]}"
  [ "$status" -eq 0 ] || { echo "healthy batch: $status $output"; false; }
  run bash -c '. "$1"; shift; attachment_detach_owners_batch "$@"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "${files[0]}" "${files[1]}" "${files[0]}"
  [ "$status" -eq 10 ] || { echo "repeated path: $status $output"; false; }
  [ -z "$output" ]
  other="$(dirname "${files[1]}")/owner-copy.json"
  cp -p "${files[1]}" "$other"
  run bash -c '. "$1"; shift; attachment_detach_owners_batch "$@"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "${files[0]}" "$other"
  [ "$status" -eq 10 ] || { echo "non-canonical name: $status $output"; false; }
  [ -z "$output" ]
  # Paths are compared NUL-framed: a newline inside a repeated path cannot
  # make the two read as distinct lines.
  other="$BATS_TEST_TMPDIR/a"$'\n'"b/$(printf '%064d' 0)/$(printf '%064d' 1).json"
  run bash -c '. "$1"; _attachment_paths_json "$2" "$2"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$other"
  [ "$status" -eq 10 ] || { echo "repeated path with a newline: $status $output"; false; }
}

# The owner checks cost one pass, not one round per sibling: the external
# processes a detach starts do not grow with the number of siblings.
count_detach_processes() {
  local shim="$SANDBOX/shim" log="$SANDBOX/shim.log" tool real
  mkdir -p "$shim"
  : > "$log"
  for tool in jq git python3 shasum; do
    real="$(command -v "$tool")"
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> %q\nexec %q "$@"\n' "$tool" "$log" "$real" > "$shim/$tool"
    chmod 755 "$shim/$tool"
  done
  PATH="$shim:$PATH" run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wc -l < "$log" | tr -d ' '
}

@test "the processes a detach starts do not grow with its siblings" {
  local pristine one four
  pristine="$SANDBOX.scale"
  rm -rf "$pristine"
  cp -Rp "$SANDBOX" "$pristine"
  attach_siblings 1
  one="$(count_detach_processes)"
  chmod -R u+w "$SANDBOX"; rm -rf "$SANDBOX"; cp -Rp "$pristine" "$SANDBOX"
  attach_siblings 4
  four="$(count_detach_processes)"
  echo "processes: one sibling $one, four siblings $four"
  # Each extra sibling may cost the batch's one parallel git lookup.
  [ "$four" -le $((one + 3)) ]
  chmod -R u+w "$pristine"; rm -rf "$pristine"
}

# 1.5.0 refused forever a render claim killed between creating its journaled
# quarantine and moving the leaf into it (render-conflict). 1.5.1 finishes
# that claim, as the commit's pinned removal always did.
@test "a render claim killed after its quarantine was created recovers, also from 1.5.0" {
  local total
  kill_detach_at phase 1
  total="$(jq '.remove | length' "$(detach_journal_path)")"
  detach_journal_setup
  kill_detach_at q_mkdir "$((total + 1))"
  jq -e '.owner_committed == true and .removal != null and .external.render_pending != null' "$(detach_journal_path)" >/dev/null
  [ -n "$(find "$PROJECT" -name '.trellis-attachment-remove-*' -type d -empty -print)" ]
  recover_with "$NEW_ATTACH" "native q_mkdir #$((total + 1))"
  if have_base; then
    detach_journal_setup
    ATTACH="$BASE_ATTACH" kill_detach_at q_mkdir "$((total + 1))"
    run --separate-stderr "$BASE_ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"refused (render-conflict)"* ]] || false
    recover_with "$NEW_ATTACH" "1.5.0 q_mkdir #$((total + 1))"
  fi
}

@test "the shell pinned claim finishes a claim whose quarantine is empty" {
  local journal="$SANDBOX/claim-journal.json" leaf="$SANDBOX/claim parent/leaf" artifact identity
  mkdir -p "$SANDBOX/claim parent"
  printf 'leaf bytes\n' > "$leaf"
  chmod 644 "$leaf"
  printf '{"removal":null}\n' > "$journal"
  chmod 600 "$journal"
  run bash -c '
    . "$1"; journal=$2 leaf=$3
    artifact=$(jq -cn --arg sha "$(_attachment_hash "$leaf")" "{path:\"leaf\",kind:\"file\",sha256:\$sha,mode:\"0644\"}")
    identity=$(_attachment_fs_identity "$leaf")
    _attachment_set_removal_intent "$journal" "$leaf" || exit 91
    _attachment_journal_claim_layout "$journal" "$leaf" || exit 92
    mkdir -m 700 "$_ATTACHMENT_QUARANTINE" || exit 93
    _attachment_claim_pinned "$journal" "$leaf" "$artifact" "$identity" || exit $?
    _attachment_journal_claim_layout "$journal" "$leaf" || exit 94
    [ "$_ATTACHMENT_CLAIM_STATE" = claimed ] || exit 95
    [ ! -e "$leaf" ] || exit 96
  ' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$journal" "$leaf"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; false; }
}

# Renders merged into files the project already had restore through a staged
# result (stage, claim, publish, cleanup of the claim and of the stage). The
# same every-step crash run, on a project whose settings files predate attach.
restore_sandbox_from() {
  chmod -R u+w "$SANDBOX" 2>/dev/null
  rm -rf "$SANDBOX"
  cp -Rp "$1" "$SANDBOX"
}

# As assert_detached, with the project's own settings files back in place.
assert_merged_detached() {
  local leftovers
  [ -z "$(ls -A "$JOURNALS")" ] || return 1
  [ -z "$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' 2>/dev/null)" ] || return 1
  cmp -s "$SANDBOX/claude.before" "$PROJECT/.claude/settings.local.json" || { echo 'claude settings not restored' >&2; return 1; }
  cmp -s "$SANDBOX/codex.before" "$PROJECT/.codex/hooks.json" || { echo 'codex hooks not restored' >&2; return 1; }
  [ "$(stat -c %a "$PROJECT/.claude/settings.local.json" 2>/dev/null || stat -f %Lp "$PROJECT/.claude/settings.local.json")" = 600 ] || return 1
  leftovers="$(find "$PROJECT/.agents" "$PROJECT/.claude" "$PROJECT/.codex" \( -type f -o -type l \) \
    ! -path "$PROJECT/.claude/settings.local.json" ! -path "$PROJECT/.codex/hooks.json" -print 2>/dev/null)"
  [ -z "$leftovers" ] || { printf 'leaves remain:\n%s\n' "$leftovers" >&2; return 1; }
  [ -z "$(find "$PROJECT" -name '.trellis-attachment-remove-*' -print)" ] || return 1
  [ -z "$(find "$PROJECT" -name '*.attachment-stage-*' -print)" ] || { echo 'stage remains' >&2; return 1; }
  [ "$(detach_journal_sha256 "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ] || return 1
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "a detach killed at every durable step of a merged render restore recovers to the pre-attach bytes" {
  local pristine="$SANDBOX.merged" nth steps=0 first
  run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mkdir -p "$PROJECT/.claude" "$PROJECT/.codex"
  printf '{"project_key":"claude keeps this"}\n' > "$PROJECT/.claude/settings.local.json"
  printf '{"project_key":"codex keeps this"}\n' > "$PROJECT/.codex/hooks.json"
  chmod 600 "$PROJECT/.claude/settings.local.json" "$PROJECT/.codex/hooks.json"
  printf '.claude/settings.local.json\n.codex/hooks.json\n' >> "$PROJECT/.git/info/exclude"
  EXCLUDE_HASH="$(detach_journal_sha256 "$PROJECT/.git/info/exclude")"
  cp "$PROJECT/.claude/settings.local.json" "$SANDBOX/claude.before"
  cp "$PROJECT/.codex/hooks.json" "$SANDBOX/codex.before"
  run env TRELLIS_ATTACH_POSTJOB=off "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  rm -rf "$pristine"
  cp -Rp "$SANDBOX" "$pristine"
  kill_detach_at phase 1
  first=$((7 * $(jq '.remove | length' "$(detach_journal_path)") + 1))
  restore_sandbox_from "$pristine"
  kill_detach_at attachment_detach_render_stage 1
  jq -e '.external.render_pending.result_exists == true and (.external.render_pending.staging_path | type == "string")' "$(detach_journal_path)" >/dev/null
  nth=$first
  while :; do
    restore_sandbox_from "$pristine"
    kill_detach_at any "$nth" 2>/dev/null || true
    [ "$KILL_STATUS" -ne 0 ] || break
    [ "$KILL_STATUS" -eq 137 ] && [ "$KILL_HITS" -eq "$nth" ] || { echo "kill at step $nth: status $KILL_STATUS"; false; }
    run --separate-stderr "$NEW_ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 0 ] || { echo "recover after merged render step $nth: status $status, stderr: $stderr"; false; }
    assert_merged_detached || { echo "merged render step $nth left attachment state"; false; }
    steps=$((steps + 1))
    nth=$((nth + 1))
    [ "$steps" -lt 160 ] || { echo 'no end to the render steps'; false; }
  done
  [ "$steps" -ge 30 ] || { echo "only $steps render steps"; false; }

  # A stage 1.5.0 journaled before writing it (its identity recorded, its bytes
  # short): refused, then finished by the manual step in docs/UPGRADING.md.
  local journal stage tmp
  restore_sandbox_from "$pristine"
  kill_detach_at attachment_detach_render_stage 1
  journal="$(detach_journal_path)"
  stage="$(jq -r '.external.render_pending.staging_path' "$journal")"
  [ "$(stat -c '%d:%i' "$stage" 2>/dev/null || stat -f '%d:%i' "$stage")" = "$(jq -r '.external.render_pending.staging_identity' "$journal")" ]
  : > "$stage"
  run --separate-stderr "$NEW_ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"refused (render-conflict): $PROJECT/.claude/settings.local.json"* ]] || false
  rm -- "$stage"
  tmp="$(mktemp "$journal.tmp.XXXXXX")"
  chmod 600 "$tmp"
  jq -cS '.external.render_pending.staging_identity = null' "$journal" > "$tmp"
  mv -f "$tmp" "$journal"
  run --separate-stderr "$NEW_ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "after the manual step: $stderr"; false; }
  assert_merged_detached
  chmod -R u+w "$pristine"; rm -rf "$pristine"
}

# 1.5.0 also refused forever a render cleanup killed after removing the
# claimed file and its quarantine, before journaling the clear. 1.5.1 sees
# that only the clear is left.
@test "a render cleanup killed before its clear recovers, also from 1.5.0" {
  local total
  kill_detach_at phase 1
  total="$(jq '.remove | length' "$(detach_journal_path)")"
  detach_journal_setup
  kill_detach_at q_rmdir "$((total + 1))"
  jq -e '.owner_committed == true and .removal != null and .external.render_pending != null' "$(detach_journal_path)" >/dev/null
  [ -z "$(find "$PROJECT" -name '.trellis-attachment-remove-*' -print)" ]
  recover_with "$NEW_ATTACH" "native q_rmdir #$((total + 1))"
  if have_base; then
    detach_journal_setup
    ATTACH="$BASE_ATTACH" kill_detach_at q_rmdir "$((total + 1))"
    run --separate-stderr "$BASE_ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -ne 0 ]
    recover_with "$NEW_ATTACH" "1.5.0 q_rmdir #$((total + 1))"
  fi
}
