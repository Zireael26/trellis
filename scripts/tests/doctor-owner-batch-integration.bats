#!/usr/bin/env bats
# Differential doctor integration with two real attached worktrees. A private
# copy of the entry script adds logging/fault injection; the sealed release is
# not modified. Stdout, stderr and exit status are compared byte for byte;
# both paths use one reference time for the attachment-status age check.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
. "$REPO_ROOT/scripts/tests/helpers/release-fixture.bash"
. "$REPO_ROOT/scripts/tests/helpers/doctor-wait-postjobs.bash"

setup_file() {
  BASE="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/doctor-fleet"
  mkdir -p "$BASE/prototype" "$BASE/live"
  export BASE
  release_fixture_prototype_build "$BASE/prototype"
  release_fixture_prototype_clone "$BASE/prototype" "$BASE/live"
  # The shared bootstrap is intentionally minimal; give doctor a valid
  # management source so the healthy control has an actual zero exit class.
  printf '{"schema_version":2}\n' > "$BASE/live/bootstrap release source/trellis.config.json"
  export HOME="$BASE/live/user" TRELLIS_HOME="$BASE/live/trellis" TRELLIS_ATTACH_POSTJOB=off
  export PROJECT="$BASE/live/project" LINKED="$BASE/live/linked"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  printf '{"schema_version":1,"project_id":"doctor-batch"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm initial
  "$HOME/.local/bin/trellis" attach --fleet personal "$PROJECT" >/dev/null
  git -C "$PROJECT" worktree add -q -b linked "$LINKED"
  "$HOME/.local/bin/trellis" attach --fleet personal "$LINKED" >/dev/null
  doctor_wait_postjobs "$TRELLIS_HOME"
  local owner_dir relative
  owner_dir="$(dirname "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f | head -1)")"
  export MAIN_OWNER="$owner_dir/$(printf '%s' "$PROJECT" | shasum -a 256 | cut -d' ' -f1).json"
  export LINKED_OWNER="$owner_dir/$(printf '%s' "$LINKED" | shasum -a 256 | cut -d' ' -f1).json"
  [ -f "$MAIN_OWNER" ] && [ -f "$LINKED_OWNER" ]
  cp -p "$LINKED_OWNER" "$BASE/linked-owner.original"
  relative="$(jq -r '[.artifacts[] | select(.kind == "symlink" and .path != ".trellis/runtime")][0].path' "$LINKED_OWNER")"
  export ARTIFACT="$LINKED/$relative" ARTIFACT_TARGET
  ARTIFACT_TARGET="$(readlink "$ARTIFACT")"
  export ARTIFACT_TARGET
  mkdir -p "$BASE/code/scripts" "$TRELLIS_HOME/state/scratch"
  ln -s "$REPO_ROOT/scripts/lib" "$BASE/code/scripts/lib"
  ln -s "$REPO_ROOT/core-rules" "$BASE/code/core-rules"
  awk '
    {print}
    $0 == ". \"$SCRIPT_DIR/lib/pi-output-guard.sh\"" {print ". \"$DOCTOR_TEST_SHIM\""}
  ' "$REPO_ROOT/scripts/doctor.sh" > "$BASE/code/scripts/doctor.sh"
  # Same entry script and libraries, but without invoking the prepass at all.
  # Match exactly once so a changed call site cannot silently turn the
  # differential baseline back into a batch-status-10 run.
  awk '
    $0 == "      doctor_owner_artifacts_prepare \"$HOME_PATH\" \"$SNAPSHOT\" \"${doctor_owner_candidates[@]}\"" ||
    $0 == "      doctor_owner_artifacts_prepare \"$HOME_PATH\" \"$SNAPSHOT\" \"${doctor_owner_candidates[@]}\" 2>/dev/null" {
      print "      : # unbatched differential baseline"
      removed++
      next
    }
    { print }
    END { if (removed != 1) exit 1 }
  ' "$BASE/code/scripts/doctor.sh" > "$BASE/code/scripts/doctor-unbatched.sh"
  export DOCTOR_TEST_SHIM="$BASE/shim.bash"
  cat > "$DOCTOR_TEST_SHIM" <<'SHIM'
eval "$(declare -f attachment_owner_artifact_verdicts_readonly | sed '1s/attachment_owner_artifact_verdicts_readonly/_test_real_batch/')"
attachment_owner_artifact_verdicts_readonly() {
  printf 'batch %s\n' "$(( $# - 1 ))" >> "$TEST_EVENTS"
  case "$TEST_MODE" in
    scalar) return 10 ;;
    churn)
      local result rc
      result="$(_test_real_batch "$@")"; rc=$?
      : > "$HOME/.doctor-test-churn.$$" && rm "$HOME/.doctor-test-churn.$$" || return 10
      : > "$TEST_TMP_ANCESTOR/doctor-test-churn.$$" && rm "$TEST_TMP_ANCESTOR/doctor-test-churn.$$" || return 10
      printf 'churn HOME and temp ancestor\n' >> "$TEST_EVENTS"
      printf '%s\n' "$result"
      return "$rc" ;;
    race)
      local result rc
      result="$(_test_real_batch "$@")"; rc=$?
      if [ "$rc" -eq 0 ]; then
        cp -p "$LINKED_OWNER" "$LINKED_OWNER.next" && mv "$LINKED_OWNER.next" "$LINKED_OWNER"
        ln -sfn /nonexistent-test-target "$ARTIFACT"
      fi
      printf '%s\n' "$result"
      return "$rc" ;;
    *) _test_real_batch "$@" ;;
  esac
}
eval "$(declare -f _attachment_verify_owner_artifacts | sed '1s/_attachment_verify_owner_artifacts/_test_real_scalar/')"
_attachment_verify_owner_artifacts() {
  if [ "${FUNCNAME[1]}" = _hc_portable_verify_owner_artifacts ]; then
    printf 'scalar %s\n' "$1" >> "$TEST_EVENTS"
  fi
  _test_real_scalar "$@"
}
# Freeze only the classifier's clock, not doctor or filesystem timestamps.
# Otherwise sequential batch/scalar runs can straddle its warning threshold.
eval "$(declare -f attach_status_classify | sed '1s/attach_status_classify/_test_real_status_classify/')"
attach_status_classify() (
  date() {
    if [ "$#" -eq 1 ] && [ "$1" = +%s ]; then
      printf '%s\n' "$TEST_STATUS_NOW"
    else
      command date "$@"
    fi
  }
  _test_real_status_classify "$@"
)
SHIM
}

teardown_file() {
  chmod -R u+w "$BASE" 2>/dev/null || true
  rm -rf "$BASE"
}

setup() {
  export HOME="$BASE/live/user" TRELLIS_HOME="$BASE/live/trellis"
  export TEST_EVENTS="$BATS_TEST_TMPDIR/events" TEST_MODE=normal
  export TEST_STATUS_NOW="$(date +%s)"
  : > "$TEST_EVENTS"
}

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/status.original" ]; then
    cp -p "$BATS_TEST_TMPDIR/status.original" \
      "$TRELLIS_HOME/state/attachment-status/${MAIN_OWNER#"$TRELLIS_HOME/state/attachments/"}"
  fi
  chmod 700 "$TRELLIS_HOME/state/attachments" 2>/dev/null || :
  chmod 700 "${MAIN_OWNER%/*}" 2>/dev/null || :
  if [ -d "$BASE/journals.saved" ] && [ ! -e "$TRELLIS_HOME/state/attachment-journals" ]; then
    mv "$BASE/journals.saved" "$TRELLIS_HOME/state/attachment-journals"
  fi
  if [ -d "$LINKED.moved" ] && [ ! -e "$LINKED" ]; then mv "$LINKED.moved" "$LINKED"; fi
  if [ -d "$LINKED" ]; then ln -sfn "$ARTIFACT_TARGET" "$ARTIFACT"; fi
  if ! cmp -s "$LINKED_OWNER" "$BASE/linked-owner.original"; then
    cp -p "$BASE/linked-owner.original" "$LINKED_OWNER.next" && mv "$LINKED_OWNER.next" "$LINKED_OWNER"
  fi
}

run_doctor_file() {
  local label="$1" rc=0 doctor="$BASE/code/scripts/doctor.sh"
  shift
  if [ "$TEST_MODE" = scalar ]; then
    doctor="$BASE/code/scripts/doctor-unbatched.sh"
    : > "$TEST_EVENTS"
  fi
  env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    TEST_EVENTS="$TEST_EVENTS" TEST_MODE="$TEST_MODE" DOCTOR_TEST_SHIM="$DOCTOR_TEST_SHIM" \
    TEST_STATUS_NOW="$TEST_STATUS_NOW" LINKED_OWNER="$LINKED_OWNER" ARTIFACT="$ARTIFACT" \
    TEST_TMP_ANCESTOR="$BASE" TMPDIR="$TRELLIS_HOME/state/scratch" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$BASH" "$doctor" "$@" \
    > "$BATS_TEST_TMPDIR/$label.out" 2> "$BATS_TEST_TMPDIR/$label.err" || rc=$?
  printf '%s\n' "$rc" > "$BATS_TEST_TMPDIR/$label.rc"
  if [ "$TEST_MODE" = scalar ] && grep -q '^batch ' "$TEST_EVENTS"; then
    printf '%s\n' 'unbatched baseline unexpectedly called the batch' >&3
    return 1
  fi
}

compare_runs() {
  cmp "$BATS_TEST_TMPDIR/fast.out" "$BATS_TEST_TMPDIR/scalar.out" &&
    cmp "$BATS_TEST_TMPDIR/fast.err" "$BATS_TEST_TMPDIR/scalar.err" &&
    cmp "$BATS_TEST_TMPDIR/fast.rc" "$BATS_TEST_TMPDIR/scalar.rc" || {
      diff -u "$BATS_TEST_TMPDIR/scalar.out" "$BATS_TEST_TMPDIR/fast.out" || :
      diff -u "$BATS_TEST_TMPDIR/scalar.err" "$BATS_TEST_TMPDIR/fast.err" || :
      return 1
    }
}

@test "readonly API proves real owners on Python 3.9 without preparing state" {
  local before after expected
  /usr/bin/python3 -c 'import sys; assert sys.version_info[:2] == (3, 9)' 2>/dev/null || skip 'system Python 3.9 not available'
  mv "$TRELLIS_HOME/state/attachment-journals" "$BASE/journals.saved"
  before="$(find "$TRELLIS_HOME" -ls | LC_ALL=C sort)"
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/bash -c '. "$1/scripts/lib/attachment.sh"; attachment_owner_artifact_verdicts_readonly "$2" "$3" "$4"' \
    _ "$REPO_ROOT" "$TRELLIS_HOME" "$MAIN_OWNER" "$LINKED_OWNER"
  expected="$(printf '0\t%s\n0\t%s' "$MAIN_OWNER" "$LINKED_OWNER")"
  [ "$status" -eq 0 ] && [ "$output" = "$expected" ] || { echo "$output"; false; }
  after="$(find "$TRELLIS_HOME" -ls | LC_ALL=C sort)"
  if [ "$before" != "$after" ]; then
    printf '%s\n' "$before" > "$BATS_TEST_TMPDIR/state-before"
    printf '%s\n' "$after" > "$BATS_TEST_TMPDIR/state-after"
    diff -u "$BATS_TEST_TMPDIR/state-before" "$BATS_TEST_TMPDIR/state-after" >&3 || :
    return 1
  fi
  [ ! -e "$TRELLIS_HOME/state/attachment-journals" ]
}

@test "readonly API refuses unsafe permissions and duplicate paths without repairing state" {
  chmod 755 "$TRELLIS_HOME/state/attachments"
  run env TRELLIS_HOME="$TRELLIS_HOME" "$BASH" -c '. "$1/scripts/lib/attachment.sh"; attachment_owner_artifact_verdicts_readonly "$2" "$3"' \
    _ "$REPO_ROOT" "$TRELLIS_HOME" "$MAIN_OWNER"
  [ "$status" -eq 10 ]
  [ "$(stat -c %a "$TRELLIS_HOME/state/attachments" 2>/dev/null || stat -f %Lp "$TRELLIS_HOME/state/attachments")" = 755 ]
  chmod 700 "$TRELLIS_HOME/state/attachments"
  run env TRELLIS_HOME="$TRELLIS_HOME" "$BASH" -c '. "$1/scripts/lib/attachment.sh"; attachment_owner_artifact_verdicts_readonly "$2" "$3" "$3"' \
    _ "$REPO_ROOT" "$TRELLIS_HOME" "$MAIN_OWNER"
  [ "$status" -eq 10 ] && [ -z "$output" ]
}

@test "readonly API writes no bytecode when its library directory is writable" {
  local lib="$BATS_TEST_TMPDIR/writable-lib"
  cp -R "$REPO_ROOT/scripts/lib" "$lib"
  chmod -R u+w "$lib"
  rm -rf "$lib/__pycache__"
  run env TRELLIS_HOME="$TRELLIS_HOME" "$BASH" -c '. "$1/attachment.sh"; attachment_owner_artifact_verdicts_readonly "$2" "$3"' \
    _ "$lib" "$TRELLIS_HOME" "$MAIN_OWNER"
  [ "$status" -eq 0 ] && [ "$output" = "$(printf '0\t%s' "$MAIN_OWNER")" ] || { echo "$output"; false; }
  [ ! -e "$lib/__pycache__" ]
}

@test "healthy doctor certifies two owners with Python 3.9 and matches scalar output" {
  /usr/bin/python3 -c 'import sys; assert sys.version_info[:2] == (3, 9)' 2>/dev/null || skip 'system Python 3.9 not available'
  TEST_MODE=normal run_doctor_file fast
  [ "$(< "$BATS_TEST_TMPDIR/fast.rc")" = 0 ] || { grep '✗' "$BATS_TEST_TMPDIR/fast.out"; false; }
  grep -qx 'batch 2' "$TEST_EVENTS"
  ! grep -q '^scalar ' "$TEST_EVENTS" || { cat "$TEST_EVENTS"; false; }
  : > "$TEST_EVENTS"
  TEST_MODE=scalar run_doctor_file scalar
  ! grep -q '^batch ' "$TEST_EVENTS"
  grep -Fxq "scalar $MAIN_OWNER" "$TEST_EVENTS"
  grep -Fxq "scalar $LINKED_OWNER" "$TEST_EVENTS"
  compare_runs
}

@test "unsearchable owner directory keeps the unbatched stderr and exit status" {
  local owner_dir="${MAIN_OWNER%/*}"
  chmod 000 "$owner_dir"
  if (cd "$owner_dir" 2>/dev/null); then
    chmod 700 "$owner_dir"
    skip 'current user can search a mode-000 directory'
  fi
  TEST_MODE=normal run_doctor_file fast
  TEST_MODE=scalar run_doctor_file scalar
  chmod 700 "$owner_dir"
  [ "$(< "$BATS_TEST_TMPDIR/scalar.rc")" = 4 ]
  [ -s "$BATS_TEST_TMPDIR/scalar.err" ]
  compare_runs
}

@test "unrelated HOME and temp-ancestor churn during the batch retains real verdicts" {
  # The Trellis home is a child of this private account HOME for this test.
  HOME="$BASE/live"; export HOME
  TEST_MODE=churn run_doctor_file fast
  grep -qx 'batch 2' "$TEST_EVENTS"
  grep -qx 'churn HOME and temp ancestor' "$TEST_EVENTS"
  ! grep -q '^scalar ' "$TEST_EVENTS" || { cat "$TEST_EVENTS"; false; }
  : > "$TEST_EVENTS"
  TEST_MODE=scalar run_doctor_file scalar
  compare_runs
}

@test "broken artifact still produces the scalar finding and identical report" {
  ln -sfn /nonexistent-test-target "$ARTIFACT"
  TEST_MODE=normal run_doctor_file fast
  grep -qx 'batch 2' "$TEST_EVENTS"
  grep -Fxq "scalar $LINKED_OWNER" "$TEST_EVENTS"
  grep -q 'a Trellis-owned artifact is missing, modified, or escapes' "$BATS_TEST_TMPDIR/fast.out"
  : > "$TEST_EVENTS"
  TEST_MODE=scalar run_doctor_file scalar
  compare_runs
}

@test "changed owner after the batch is rechecked and reported like scalar" {
  TEST_MODE=race run_doctor_file fast
  grep -qx 'batch 2' "$TEST_EVENTS"
  grep -Fxq "scalar $LINKED_OWNER" "$TEST_EVENTS"
  grep -q 'a Trellis-owned artifact is missing, modified, or escapes' "$BATS_TEST_TMPDIR/fast.out"
  : > "$TEST_EVENTS"
  TEST_MODE=scalar run_doctor_file scalar
  compare_runs
}

@test "empty and multi-document owner files do not make a healthy sibling disappear" {
  local form
  for form in empty multiple; do
    if [ "$form" = empty ]; then
      : > "$LINKED_OWNER"
    else
      cp "$BASE/linked-owner.original" "$LINKED_OWNER"
      printf '\n{}\n' >> "$LINKED_OWNER"
    fi
    : > "$TEST_EVENTS"
    TEST_MODE=normal run_doctor_file fast
    ! grep -q '^batch ' "$TEST_EVENTS"
    grep -Fxq "scalar $MAIN_OWNER" "$TEST_EVENTS"
    grep -q 'owner record is invalid' "$BATS_TEST_TMPDIR/fast.out"
    : > "$TEST_EVENTS"
    TEST_MODE=scalar run_doctor_file scalar
    compare_runs
  done
}

@test "a foreign worktree in an owner is refused before the artifact batch" {
  jq '.worktree_root = "/nonexistent-foreign-worktree"' "$LINKED_OWNER" > "$BASE/foreign-owner"
  cp "$BASE/foreign-owner" "$LINKED_OWNER"
  TEST_MODE=normal run_doctor_file fast
  grep -qx 'batch 1' "$TEST_EVENTS"
  grep -q 'owner record does not exactly match' "$BATS_TEST_TMPDIR/fast.out"
  : > "$TEST_EVENTS"
  TEST_MODE=scalar run_doctor_file scalar
  compare_runs
}

@test "an invalid owner schema is refused before the artifact batch" {
  jq '.schema_version = 2' "$LINKED_OWNER" > "$BASE/invalid-owner"
  cp "$BASE/invalid-owner" "$LINKED_OWNER"
  TEST_MODE=normal run_doctor_file fast
  grep -qx 'batch 1' "$TEST_EVENTS"
  grep -q 'owner record is invalid' "$BATS_TEST_TMPDIR/fast.out"
  : > "$TEST_EVENTS"
  TEST_MODE=scalar run_doctor_file scalar
  compare_runs
}

@test "an attachment ID mismatch is refused before the artifact batch" {
  jq '.attachment_id = "00000000-0000-4000-8000-000000000000"' "$LINKED_OWNER" > "$BASE/unbound-owner"
  cp "$BASE/unbound-owner" "$LINKED_OWNER"
  TEST_MODE=normal run_doctor_file fast
  grep -qx 'batch 1' "$TEST_EVENTS"
  grep -q 'owner record does not exactly match' "$BATS_TEST_TMPDIR/fast.out"
  : > "$TEST_EVENTS"
  TEST_MODE=scalar run_doctor_file scalar
  compare_runs
}

@test "pending status matches scalar on both sides of the age threshold" {
  local status="$TRELLIS_HOME/state/attachment-status/${MAIN_OWNER#"$TRELLIS_HOME/state/attachments/"}"
  local age expected
  [ -f "$status" ]
  cp -p "$status" "$BATS_TEST_TMPDIR/status.original"
  # A day-old reference proves that both doctors actually use the test clock.
  TEST_STATUS_NOW=$((TEST_STATUS_NOW - 86400))
  mv "$LINKED" "$LINKED.moved"
  for age in 840 960; do
    jq --argjson at "$((TEST_STATUS_NOW - age))" \
      '.state = "pending" | .updated_at = $at | .checks = [] | .failure = null' \
      "$BATS_TEST_TMPDIR/status.original" > "$BATS_TEST_TMPDIR/status.input"
    cp "$BATS_TEST_TMPDIR/status.input" "$status"
    if [ "$age" -eq 840 ]; then
      expected='  i attachment checks: pending; pre-push runs them inline until they finish'
    else
      expected='  ⚠ attachment checks: pending for 16 min; pre-push runs them inline; remedy: trellis doctor --fix'
    fi
    : > "$TEST_EVENTS"
    TEST_MODE=normal run_doctor_file fast
    grep -qx 'batch 1' "$TEST_EVENTS"
    grep -Fxq "$expected" "$BATS_TEST_TMPDIR/fast.out"
    cmp "$BATS_TEST_TMPDIR/status.input" "$status"
    TEST_MODE=scalar run_doctor_file scalar
    grep -Fxq "scalar $MAIN_OWNER" "$TEST_EVENTS"
    grep -Fxq "$expected" "$BATS_TEST_TMPDIR/scalar.out"
    cmp "$BATS_TEST_TMPDIR/status.input" "$status"
    compare_runs
  done
}

@test "a moved worktree and fix dry-run retain scalar behavior" {
  mv "$LINKED" "$LINKED.moved"
  TEST_MODE=normal run_doctor_file fast
  TEST_MODE=scalar run_doctor_file scalar
  compare_runs
  mv "$LINKED.moved" "$LINKED"
  git -C "$PROJECT" config --list --local > "$BATS_TEST_TMPDIR/project-config.before"
  git -C "$LINKED" config --list --local > "$BATS_TEST_TMPDIR/linked-config.before"
  : > "$TEST_EVENTS"
  TEST_MODE=normal run_doctor_file fix --fix --dry-run
  ! grep -q '^batch ' "$TEST_EVENTS"
  grep -q '^scalar ' "$TEST_EVENTS"
  git -C "$PROJECT" config --list --local > "$BATS_TEST_TMPDIR/project-config.after"
  git -C "$LINKED" config --list --local > "$BATS_TEST_TMPDIR/linked-config.after"
  cmp "$BATS_TEST_TMPDIR/project-config.before" "$BATS_TEST_TMPDIR/project-config.after"
  cmp "$BATS_TEST_TMPDIR/linked-config.before" "$BATS_TEST_TMPDIR/linked-config.after"
}
