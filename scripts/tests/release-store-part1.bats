#!/usr/bin/env bats
# Historical group-plan baseline and lease-serialized adoption.
# Verbatim tests from release-store-original.txt (a2a8746e4).
load release-store-common
load helpers/fixture-clone
load helpers/historical-releases

setup_file() {
  GROUP_PLAN_RELEASE_CACHE="$(cd "$BATS_FILE_TMPDIR" && pwd -P)/group-plan-releases"
  export GROUP_PLAN_RELEASE_CACHE
  historical_releases_copy_or_build "$GROUP_PLAN_RELEASE_CACHE" || return 1
  # Keep one real, fully adopted 1.3.6 -> 1.3.7/8/9 baseline. Its pathname is
  # stable so copying it back never rebases owner IDs, Git worktree bindings,
  # contextual render hashes, hooks or historical restoration snapshots.
  (
    SANDBOX="$GROUP_PLAN_RELEASE_CACHE/machine"
    mkdir -p "$SANDBOX" || return 1
    initialize_release_store_machine || return 1
    group_plan_build_group history || return 1
    group_plan_assert_no_journal || return 1
    fixture_clone "$SANDBOX" "$GROUP_PLAN_RELEASE_CACHE/baseline" || return 1
    find "$SANDBOX" -depth -type d -exec chmod u+w {} \; || return 1
    rm -rf "$SANDBOX"
  )
}

teardown_file() {
  [ -d "${GROUP_PLAN_RELEASE_CACHE:-}" ] || return 0
  find "$GROUP_PLAN_RELEASE_CACHE" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
  rm -rf "$GROUP_PLAN_RELEASE_CACHE"
}

setup() {
  # Fixture attaches must not leave a detached post-attach job behind: it
  # re-asserts a husky-reset core.hooksPath and takes the checkout lock while
  # the case stages operator state and adopts. run-tests.sh sets this too; the
  # suite must not depend on its runner. attach-postjob.bats covers the job.
  export TRELLIS_ATTACH_POSTJOB=off
  GROUP_PLAN_CASE_LOCK_HELD=false
  case "$BATS_TEST_DESCRIPTION" in
    'group plan ('*)
      # File-local cases may be scheduled in parallel by Bats. Lease the fixed
      # working pathname until teardown; the baseline itself is never mutated.
      # R10 holder-liveness wait (see helpers/group-plan.bash): no try cap
      # while the holder is alive; fail fast on stale/malformed, never break.
      group_plan_case_lease_acquire || return 1
      SANDBOX="$GROUP_PLAN_RELEASE_CACHE/machine"
      fixture_clone "$GROUP_PLAN_RELEASE_CACHE/baseline" "$SANDBOX" || return 1
      release_store_machine_paths
      ;;
    *)
      SANDBOX="$(mktemp -d)"
      SANDBOX="$(cd "$SANDBOX" && pwd -P)"
      initialize_release_store_machine
      ;;
  esac
  RELEASE_PROCESS_PID_A=""
  RELEASE_PROCESS_PID_B=""
  RELEASE_PROCESS_STATUS=""
}


@test "group plan (u): historical adoption reconciles all owners and fresh checkout add succeeds" {
  group_plan_setup_group history
  cp "$GROUP_PLAN_OWNER" "$SANDBOX/original.owner"
  group_plan_adopt
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  export TRELLIS_WORKTREE_ROOT="$SANDBOX/work trees"
  GROUP_PLAN_NEW="$TRELLIS_WORKTREE_ROOT/group-plan/gp-new"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c 'cd "$1" && bash "$2" add gp-new' _ \
    "$GROUP_PLAN_MAIN" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local owner harness leaf managed hash before
  owner="$(owner_for_root "$GROUP_PLAN_NEW")"
  hash="$(jq -r '.exclude_block_hash' "$owner")"
  for owner in "$TRELLIS_HOME_FIX"/state/attachments/*/*.json; do
    jq -e --arg hash "$hash" '.release == "1.3.10" and .exclude_block_hash == $hash
      and .exclude.managed_block_sha256 == $hash and .status == "committed"' "$owner"
    [ "$(readlink "$(jq -r '.worktree_root' "$owner")/.trellis/runtime")" = "$TRELLIS_HOME_FIX/releases/1.3.10/payload" ]
    [ "$(registry_release_for_root "$(jq -r '.worktree_root' "$owner")")" = 1.3.10 ]
  done
  jq -e --slurpfile old "$SANDBOX/original.owner" '
    .exclude.before_base64 == $old[0].exclude.before_base64
    and .exclude.before_sha256 == $old[0].exclude.before_sha256
    and .exclude.managed_by_attachment == $old[0].exclude.managed_by_attachment' "$GROUP_PLAN_OWNER"
  for harness in claude codex; do
    for leaf in hooks/hookspath-guard.sh hooks/lib/hookspath-check.sh; do
      [ -L "$GROUP_PLAN_NEW/.$harness/$leaf" ]
      [ -e "$GROUP_PLAN_NEW/.$harness/$leaf" ]
      grep -Fx "/.$harness/$leaf" "$GROUP_PLAN_EXCLUDE"
    done
  done
  # Pi runs the payload hooks in place, so a fresh checkout gets no .pi/hooks.
  [ ! -e "$GROUP_PLAN_NEW/.pi/hooks" ]
  [ ! -e "$GROUP_PLAN_MAIN/.pi/hooks" ]
  ! grep -F '/.pi/hooks/' "$GROUP_PLAN_EXCLUDE"
  [ "$(tail -c 31 "$GROUP_PLAN_EXCLUDE")" = '# external tail without newline' ]
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$GROUP_PLAN_OWNER")"
  [ "$(git -C "$GROUP_PLAN_NEW" config --local --get-all core.hooksPath)" = "$managed" ]
  [ "$(git -C "$GROUP_PLAN_NEW" config --get core.hooksPath)" = "$managed" ]
  [ "$(git -C "$GROUP_PLAN_NEW" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '[.projects[].checkouts[].harnesses] | all(. == ["claude","codex","pi"])' "$TRELLIS_HOME_FIX/registry.json"
  [ -z "$(git -C "$GROUP_PLAN_NEW" status --porcelain)" ]
  [ -z "$(git -C "$GROUP_PLAN_MAIN" status --porcelain)" ]
  [ -z "$(git -C "$GROUP_PLAN_SIBLING" status --porcelain)" ]
  before="$(group_plan_state)"
  group_plan_sync "$GROUP_PLAN_NEW"
  [ "$status" -eq 0 ]
  [ ! -s "$SANDBOX/sync.err" ]
  [ "$(group_plan_state)" = "$before" ]
  group_plan_assert_no_journal
}

@test "group plan (t): stale existing-tree sync and quiet seeding name exclude cause on stderr" {
  group_plan_setup_group
  payload_fixture_git -C "$GROUP_PLAN_MAIN" worktree add --detach "$GROUP_PLAN_NEW"
  local before stderr mode
  before="$(group_plan_state)"
  for mode in sync quiet; do
    if [ "$mode" = sync ]; then group_plan_sync "$GROUP_PLAN_NEW"; else
      run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c 'exec bash "$1" --target "$2" --quiet 2>"$3"' _ \
        "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$GROUP_PLAN_NEW" "$SANDBOX/sync.err"
    fi
    [ "$status" -eq 3 ]
    [ -s "$SANDBOX/sync.err" ]
    stderr="$(cat "$SANDBOX/sync.err")"
    [[ "$stderr" == *'stale owned exclude plan'*'info/exclude'*'checkout '*"$GROUP_PLAN_NEW"*'release 1.3.9'*'recorded '*'live '*'desired '*'hookspath-guard.sh'*'remedy:'* ]]
    [ "$(group_plan_state)" = "$before" ]
    [ ! -e "$GROUP_PLAN_NEW/.trellis/runtime" ]
    ! owner_for_root "$GROUP_PLAN_NEW"
    [ -z "$(registry_release_for_root "$GROUP_PLAN_NEW")" ]
    group_plan_assert_no_journal
  done
}

@test "group plan (t): invalid donor and owned-artifact sync refusals are distinct" {
  group_plan_setup_group
  payload_fixture_git -C "$GROUP_PLAN_MAIN" worktree add --detach "$GROUP_PLAN_NEW"
  rm "$GROUP_PLAN_MAIN/.claude/rules/trellis.md" "$GROUP_PLAN_SIBLING/.claude/rules/trellis.md"
  local before
  before="$(group_plan_state)"
  group_plan_sync "$GROUP_PLAN_NEW"
  [ "$status" -eq 4 ]
  grep -F 'invalid donor ownership' "$SANDBOX/sync.err"
  grep -F 'state/attachments/' "$SANDBOX/sync.err"
  grep -F 'remedy:' "$SANDBOX/sync.err"
  group_plan_sync "$GROUP_PLAN_MAIN"
  [ "$status" -eq 3 ]
  grep -F 'owned-artifact refusal' "$SANDBOX/sync.err"
  grep -F '.claude/rules/trellis.md' "$SANDBOX/sync.err"
  [ "$(group_plan_state)" = "$before" ]
  group_plan_assert_no_journal
}

@test "group plan (u): stale pre-add refuses before branch or tree and no-checkout stays deferred" {
  group_plan_setup_group
  local before
  before="$(group_plan_state)"
  export TRELLIS_WORKTREE_ROOT="$SANDBOX/work trees"
  GROUP_PLAN_NEW="$TRELLIS_WORKTREE_ROOT/group-plan/gp-blocked"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c 'cd "$1" && bash "$2" add gp-blocked' _ \
    "$GROUP_PLAN_MAIN" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 3 ]
  [[ "$output" == *'stale owned exclude plan'*'remedy:'* ]]
  [ ! -e "$GROUP_PLAN_NEW" ]
  ! git -C "$GROUP_PLAN_MAIN" show-ref --verify refs/heads/gp-blocked
  [ "$(group_plan_state)" = "$before" ]
  GROUP_PLAN_NEW="$TRELLIS_WORKTREE_ROOT/group-plan/gp-deferred"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c 'cd "$1" && bash "$2" add --no-checkout gp-deferred' _ \
    "$GROUP_PLAN_MAIN" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ]
  [ -d "$GROUP_PLAN_NEW" ]
  [ ! -e "$GROUP_PLAN_NEW/.trellis/runtime" ]
  group_plan_assert_no_journal
}

@test "group plan (u): same-version stale recorded bytes still reconcile" {
  group_plan_setup_group
  group_plan_adopt
  [ "$status" -eq 0 ]
  # Reproduce old recorded bytes at the already-selected version (unchanged manifests).
  python3 - "$TRELLIS_HOME_FIX" "$SANDBOX/stale.exclude" "$GROUP_PLAN_EXCLUDE" <<'PY'
import base64, hashlib, json, pathlib, sys
home, stale, live = map(pathlib.Path, sys.argv[1:])
data = stale.read_bytes()
start = data.index(b'# --- Trellis local attachment exclude block ---\n')
end = data.index(b'# --- end Trellis local attachment exclude block ---\n') + len(b'# --- end Trellis local attachment exclude block ---\n')
block = data[start:end]
for path in (home / 'state/attachments').glob('*/*.json'):
    owner = json.loads(path.read_text())
    owner['exclude'].update(managed_block_base64=base64.b64encode(block).decode(),
                           managed_block_sha256=hashlib.sha256(block).hexdigest())
    owner['exclude_block_hash'] = hashlib.sha256(block).hexdigest()
    path.write_text(json.dumps(owner))
live.write_bytes(data)
PY
  group_plan_adopt
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx '/.codex/hooks/hookspath-guard.sh' "$GROUP_PLAN_EXCLUDE"
  group_plan_assert_no_journal
}

@test "group plan (u): duplicate tamper disagreement negation and divergent deferrals refuse without publication" {
  group_plan_setup_group
  local kind before
  cp "$GROUP_PLAN_EXCLUDE" "$SANDBOX/exclude.good"
  cp "$GROUP_PLAN_OWNER" "$SANDBOX/owner.good"
  for kind in duplicate tamper disagreement negation divergent; do
    case "$kind" in
      duplicate) cat "$SANDBOX/exclude.good" >> "$GROUP_PLAN_EXCLUDE" ;;
      tamper) python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes().replace(b"/.trellis/runtime",b"/.trellis/tampered"))' "$GROUP_PLAN_EXCLUDE" ;;
      disagreement) jq '.exclude.managed_block_sha256 = ("a" * 64) | .exclude_block_hash = ("a" * 64)' "$SANDBOX/owner.good" > "$GROUP_PLAN_OWNER" ;;
      negation) printf '!.codex/hooks/hookspath-guard.sh\n' > "$GROUP_PLAN_MAIN/.gitignore"; git -C "$GROUP_PLAN_MAIN" add .gitignore ;;
      divergent) rm "$GROUP_PLAN_SIBLING/.claude/primers/INDEX.md" ;;
    esac
    before="$(group_plan_state)"
    group_plan_adopt
    [ "$status" -eq 3 ] || { echo "$kind: $output"; false; }
    [ -n "$output" ]
    [ "$(group_plan_state)" = "$before" ]
    cmp "$SANDBOX/stale.exclude" "$GROUP_PLAN_EXCLUDE" || [ "$kind" = duplicate ] || [ "$kind" = tamper ]
    cp "$SANDBOX/exclude.good" "$GROUP_PLAN_EXCLUDE"
    cp "$SANDBOX/owner.good" "$GROUP_PLAN_OWNER"
    git -C "$GROUP_PLAN_MAIN" reset -q -- .gitignore
    rm -f "$GROUP_PLAN_MAIN/.gitignore"
    git -C "$GROUP_PLAN_SIBLING" restore .claude/primers/INDEX.md
    group_plan_assert_no_journal
  done
}

@test "group plan (u): exclude CAS race preserves competing external bytes without publication" {
  group_plan_setup_group
  mkdir "$RELEASE_TEST_ADOPTION_BARRIER"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.3.10 --project group-plan > "$SANDBOX/adopt.log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$RELEASE_TEST_ADOPTION_BARRIER/after-plan-validation.ready" \
    "$RELEASE_PROCESS_PID_A" "$SANDBOX/adopt.log"
  printf '\n# concurrent external bytes\n' >> "$GROUP_PLAN_EXCLUDE"
  local before
  before="$(group_plan_state)"
  : > "$RELEASE_TEST_ADOPTION_BARRIER/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$SANDBOX/adopt.log"; false; }
  grep -Fx '# concurrent external bytes' "$GROUP_PLAN_EXCLUDE"
  ! grep -F 'adopted:' "$SANDBOX/adopt.log"
  [ "$(group_plan_state)" = "$before" ]
  group_plan_assert_no_journal
}

@test "group plan (u): signal rollback and crash recovery preserve group exclude hashes" {
  group_plan_setup_group
  local signal before
  mkdir "$RELEASE_TEST_ADOPTION_BARRIER"
  printf '%s\n' "$GROUP_PLAN_EXCLUDE" > "$RELEASE_TEST_ADOPTION_BARRIER/exclude.target"
  : > "$RELEASE_TEST_ADOPTION_BARRIER/after-plan-validation.release"
  before="$(group_plan_state)"
  for signal in TERM OWNER-TERM KILL; do
    if [ "$signal" = OWNER-TERM ]; then
      mv "$RELEASE_TEST_ADOPTION_BARRIER/exclude.target" "$RELEASE_TEST_ADOPTION_BARRIER/owner.target"
    fi
    env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.3.10 --project group-plan > "$SANDBOX/adopt.log" 2>&1 &
    RELEASE_PROCESS_PID_A=$!
    local phase=exclude-after-publish
    [ "$signal" = TERM ] || phase=owner-after-publish
    wait_for_release_barrier "$RELEASE_TEST_ADOPTION_BARRIER/$phase.ready" \
      "$RELEASE_PROCESS_PID_A" "$SANDBOX/adopt.log"
    local kill_signal="$signal"
    [ "$signal" != OWNER-TERM ] || kill_signal=TERM
    kill -"$kill_signal" "$(cat "$RELEASE_TEST_ADOPTION_BARRIER/$phase.pid")"
    wait_for_release_process "$RELEASE_PROCESS_PID_A"
    [ "$RELEASE_PROCESS_STATUS" -ne 0 ]
    rm -f "$RELEASE_TEST_ADOPTION_BARRIER/$phase.ready"
    if [ "$signal" != KILL ]; then
      [ "$(group_plan_state)" = "$before" ]
      group_plan_assert_no_journal
    else
      : > "$RELEASE_TEST_ADOPTION_BARRIER/owner-after-publish.release"
      group_plan_adopt
      [ "$status" -eq 0 ] || { echo "$output"; false; }
      grep -Fx '/.codex/hooks/hookspath-guard.sh' "$GROUP_PLAN_EXCLUDE"
      group_plan_assert_no_journal
    fi
  done
}
