#!/usr/bin/env bats
# Doctor's multi-owner pass must actually certify owners, and every doubt must
# reach the old scalar diagnostic. The harness uses real filesystem tokens.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
HARNESS="$BATS_TEST_DIRNAME/helpers/doctor-owner-batch-harness.bash"

check_case() {
  local scenario="$1" hits="$2" fallbacks="$3" batches="${4:-1}"
  local work="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$work"
  run env -u DOCTOR_TEST_TMP_CHURN_DIR "$BASH" "$HARNESS" "$REPO_ROOT" "$scenario" "$work"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c '^batch hit ' || :)" -eq "$hits" ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c '^fallback .*status=23 diagnostic=scalar diagnostic' || :)" -eq "$fallbacks" ] || { echo "$output"; return 1; }
  [[ "$output" == *"batch calls=$batches scalar calls=$fallbacks"* ]] || { echo "$output"; return 1; }
}

@test "owner chain tokens preserve HOME bytes, include root, and refuse coarse user ancestors" {
  run "$BASH" "$BATS_TEST_DIRNAME/helpers/doctor-owner-token-compat.bash" "$REPO_ROOT" "$BATS_TEST_TMPDIR"
  if [ "$status" -eq 77 ]; then skip "$output"; fi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'ACL, masked ACL and malformed listings refused'* ]]
  [[ "$output" == *'home token matches pre-change format'* ]]
  [[ "$output" == *'root token proves the complete ancestor chain'* ]]
  [[ "$output" == *'coarse user-owned ancestor refused'* ]]
  [[ "$output" == *'coarse root-owned ancestor accepted for non-root user'* ]]
  [[ "$output" == *'coarse group-writable root-owned node refused'* ]]
  [[ "$output" == *'unavailable ACL probe refused'* ]]
}

@test "doctor uses both certified batch verdicts instead of scalar checks" {
  check_case healthy 2 0
}

@test "batch scratch reaches both helpers without changing caller TMPDIR or its export state" {
  local scenario
  for scenario in scratch_exported scratch_unexported scratch_unset; do
    run env -u DOCTOR_TEST_TMP_CHURN_DIR "$BASH" "$HARNESS" "$REPO_ROOT" "$scenario" "$BATS_TEST_TMPDIR/$scenario"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
    [[ "$output" == *'scratch environment restored'* ]] || { echo "$output"; false; }
    [ "$(printf '%s\n' "$output" | grep -c '^batch hit ' || :)" -eq 2 ] || { echo "$output"; false; }
    [[ "$output" == *'batch calls=1 scalar calls=0'* ]] || { echo "$output"; false; }
  done
}

@test "a nonzero owner verdict falls back only for that owner" {
  check_case mixed 1 1
}

@test "batch status 10 discards even a complete positive stream and falls back for every owner" {
  check_case status10 0 2
}

@test "a truncated verdict stream cannot certify any owner" {
  check_case partial 0 2
}

@test "an extra verdict cannot certify any owner" {
  check_case extra 0 2
}

@test "an extra blank verdict cannot certify any owner" {
  check_case blank 0 2
}

@test "an unterminated verdict cannot certify any owner" {
  check_case unterminated 0 2
}

@test "reordered verdicts cannot certify any owner" {
  check_case reordered 0 2
}

@test "an invalid verdict cannot certify any owner" {
  check_case malformed 0 2
}

@test "a changed owner during the pass falls back for that owner" {
  check_case batch_changed 1 1
}

@test "swapping and restoring an ancestor during the batch is the documented residual" {
  check_case ancestor_swap 2 0
}

@test "HOME-like and temporary-root ancestor churn during the batch keeps both verdicts" {
  check_case ancestor_churn 2 0
}

@test "an unrelated sibling creation above home does not discard healthy verdicts" {
  check_case unrelated_use 2 0
}

@test "a replaced ancestor at use time falls back for both owners" {
  check_case ancestor_replace 0 2
}

@test "a symlinked ancestor at use time falls back for both owners" {
  check_case ancestor_symlink 0 2
}

@test "an ancestor gaining group write at use time falls back for both owners" {
  check_case ancestor_mode 0 2
}

@test "an owner naming a foreign worktree never reaches the artifact batch" {
  check_case foreign 1 1
}

@test "an owner with a mismatched project root never reaches the batch" {
  check_case project_root 1 1
}

@test "an owner with a mismatched fleet never reaches the batch" {
  check_case wrong_fleet 1 1
}

@test "an owner with a mismatched project ID never reaches the batch" {
  check_case wrong_project 1 1
}

@test "an owner with a mismatched attachment ID never reaches the batch" {
  check_case wrong_attachment 1 1
}

@test "an owner with a mismatched release never reaches the batch" {
  check_case wrong_release 1 1
}

@test "an uncommitted owner never reaches the batch" {
  check_case wrong_status 1 1
}

@test "an owner rejected by the schema never reaches the batch" {
  check_case wrong_schema 1 1
}

@test "an owner with unsafe mode never reaches the batch" {
  check_case wrong_mode 1 1
}

@test "same-size same-mtime owner rewrite after the batch falls back" {
  check_case use_changed 1 1
}

@test "read-only batch does not create an unrelated missing locks directory" {
  check_case missing_state 2 0
  [[ "$output" == *'locks absent'* ]]
}

@test "unsafe attachment state permissions force the scalar path without chmod" {
  check_case unsafe_state 0 2 0
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/fixture/parent/home/state/attachments" 2>/dev/null || stat -f %Lp "$BATS_TEST_TMPDIR/fixture/parent/home/state/attachments")" = 755 ]
}
