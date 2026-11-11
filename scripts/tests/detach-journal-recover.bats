#!/usr/bin/env bats
# A detach SIGKILLed at any step leaves a journal that `trellis recover` (or a
# fresh `trellis detach`) finishes, ending exactly where a clean detach ends.
# The phase-8 cases reproduce the 1.4.1 field journal: status detaching,
# phase 8, owner_committed false, a removal claim whose leaf is already gone.

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
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

recover_and_assert_detached() {
  run --separate-stderr "$ATTACH" "$1" --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$1 after kill at $2: status $status, stderr: $stderr"; false; }
  assert_detached || { echo "$1 after kill at $2 left attachment state"; false; }
}

@test "recover finishes a detach killed at every step of the phase-8 removal" {
  local point journal removal
  for point in intent q_mkdir q_claim q_rm q_rmdir clear; do
    detach_journal_setup
    kill_detach_at "$point" 9
    journal="$(detach_journal_path)"
    jq -e '.status == "detaching" and .phase == 8 and .owner_committed == false and .next_owner == null' "$journal" >/dev/null ||
      { echo "kill at $point: $(jq -c '{phase,owner_committed,removal}' "$journal")"; false; }
    if [ "$point" = q_rmdir ]; then
      # The field journal's shape: the claim is journaled, its leaf and its
      # quarantine directory are both already gone.
      removal="$(jq -r '.removal.path' "$journal")"
      [ "$removal" = "$PROJECT/$(jq -r '.remove[8].path' "$journal")" ]
      [ ! -e "$removal" ]
      [ ! -L "$removal" ]
      [ -z "$(find "$PROJECT" -name '.trellis-attachment-remove-*' -print)" ]
    fi
    recover_and_assert_detached recover "$point"
  done
}

@test "recover finishes a detach killed between phase 7 and phase 8" {
  kill_detach_at phase 8
  jq -e '.phase == 8 and .removal == null and .owner_committed == false' "$(detach_journal_path)" >/dev/null
  recover_and_assert_detached recover phase
}

@test "a fresh detach finishes a phase-8 journal instead of refusing it" {
  local point
  for point in q_rmdir q_claim; do
    detach_journal_setup
    kill_detach_at "$point" 9
    recover_and_assert_detached detach "$point"
  done
}

@test "recover finishes a detach killed at the first and last removal and at the owner commit" {
  local spec point nth total
  kill_detach_at q_claim 1
  jq -e '.phase == 0 and .removal != null' "$(detach_journal_path)" >/dev/null
  total="$(jq '.remove | length' "$(detach_journal_path)")"
  recover_and_assert_detached recover "q_claim 1"
  for spec in "q_rmdir $total" "owner_rm 1" "owner_committed 1"; do
    detach_journal_setup
    point="${spec% *}"; nth="${spec#* }"
    kill_detach_at "$point" "$nth"
    recover_and_assert_detached recover "$spec"
  done
}

@test "recover finishes a detach killed at selected render begin claim and finish steps" {
  local spec point nth
  for spec in "attachment_detach_render_begin 1" "attachment_detach_render_claim 1" \
    "attachment_detach_render_finish 1" "attachment_detach_render_begin 2" "attachment_detach_render_finish 2"; do
    detach_journal_setup
    point="${spec% *}"; nth="${spec#* }"
    kill_detach_at "$point" "$nth"
    jq -e '.owner_committed == true and .external.phase == 1' "$(detach_journal_path)" >/dev/null
    recover_and_assert_detached recover "$spec"
  done
}

@test "recover finishes a detach killed after each external phase" {
  local phase
  for phase in 1 2 3 4 5; do
    detach_journal_setup
    kill_detach_at attachment_detach_mark_external_phase "$phase"
    jq -e --argjson phase "$phase" '.external.phase == $phase' "$(detach_journal_path)" >/dev/null
    recover_and_assert_detached recover "external phase $phase"
  done
}
