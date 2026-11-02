#!/usr/bin/env bats
# Bulk selection and registry availability.
# Verbatim tests from release-store-original.txt (a2a8746e4).
load release-store-common

setup() {
  # Match the original per-case bootstrap; only part1 needs historical releases.
  export TRELLIS_ATTACH_POSTJOB=off
  GROUP_PLAN_CASE_LOCK_HELD=false
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  initialize_release_store_machine || return 1
  RELEASE_PROCESS_PID_A=""
  RELEASE_PROCESS_PID_B=""
  RELEASE_PROCESS_STATUS=""
}

@test "partial bulk adoption updates available targets and reports unavailable selectors" {
  install_adoption_releases
  project="$SANDBOX/partial-available"
  make_portable_project "$project" partial-available
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  record_unavailable_root personal partial-unavailable "$SANDBOX/missing-checkout"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable adoption target remains explicit: personal/partial-unavailable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/partial-available"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$(owner_for_root "$project")")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}

@test "eligible failures outrank unavailable rows - managed anchor preflight dominates unavailable" {
  install_adoption_releases
  project="$SANDBOX/eligible-outrank"
  make_portable_project "$project" eligible-outrank
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  # Make the eligible project's managed runtime state fail ownership/runtime
  # preflight without making its registry row unavailable. The unavailable
  # sibling remains report-only, so the eligible target's class 3 failure must
  # determine the command status. Corrupting the runtime anchor itself would
  # also fail preflight but would break the "runtime remains on A" invariant.
  [ -n "$managed" ]
  [ -f "$managed/release-payload" ]
  printf 'corrupted-payload\n' > "$managed/release-payload"
  chmod 600 "$managed/release-payload"
  record_unavailable_root personal unavailable-outrank "$SANDBOX/missing-unavailable-outrank"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/eligible-outrank"* ]] || { echo "$output"; false; }
  [[ "$output" == *"unavailable adoption target remains explicit: personal/unavailable-outrank"* ]] || { echo "$output"; false; }
  [ "$(grep -c "adopted:" <<<"$output")" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_A" ]
}

@test "bulk adoption commits a healthy target while an eligible sibling fails" {
  local failed healthy failed_owner failed_owner_before failed_managed healthy_owner
  install_adoption_releases

  # The failing project sorts first, proving a class-3 row does not suppress a
  # later eligible success. The final-state assertions also forbid batch-wide
  # rollback after the healthy row commits.
  failed="$SANDBOX/bulk-a-failed"
  make_portable_project "$failed" bulk-a-failed
  attach_portable_project "$failed" personal "$ADOPTION_VERSION_A"
  failed_owner="$(owner_for_root "$failed")"
  failed_owner_before="$(cat "$failed_owner")"
  failed_managed="$(jq -r '.git_hooks.managed_hooks_path' "$failed_owner")"
  [ -n "$failed_managed" ]
  [ -f "$failed_managed/release-payload" ]
  printf 'corrupted-payload\n' > "$failed_managed/release-payload"
  chmod 600 "$failed_managed/release-payload"

  healthy="$SANDBOX/bulk-z-healthy"
  make_portable_project "$healthy" bulk-z-healthy
  attach_portable_project "$healthy" personal "$ADOPTION_VERSION_A"
  healthy_owner="$(owner_for_root "$healthy")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --all

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/bulk-a-failed"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/bulk-z-healthy"* ]] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/bulk-a-failed"*"adopted: personal/bulk-z-healthy"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"adopted: personal/bulk-a-failed"* ]] || { echo "$output"; false; }

  [ "$(readlink "$healthy/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$healthy")" = "$ADOPTION_VERSION_B" ]
  [ "$(jq -r '.release' "$healthy_owner")" = "$ADOPTION_VERSION_B" ]

  [ "$(readlink "$failed/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(registry_release_for_root "$failed")" = "$ADOPTION_VERSION_A" ]
  [ "$(cat "$failed_owner")" = "$failed_owner_before" ]
}

@test "project-scoped unavailable rows stay report-only beside an eligible worktree" {
  local healthy failed managed owner owner_before
  install_adoption_releases

  healthy="$SANDBOX/project-mixed-healthy"
  make_portable_project "$healthy" project-mixed-healthy
  attach_portable_project "$healthy" personal "$ADOPTION_VERSION_A"
  record_unavailable_root personal project-mixed-healthy "$SANDBOX/missing-project-mixed-healthy"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project project-mixed-healthy

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"unavailable adoption target remains explicit: personal/project-mixed-healthy"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/project-mixed-healthy"* ]] || { echo "$output"; false; }
  [ "$(readlink "$healthy/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]

  failed="$SANDBOX/project-mixed-failed"
  make_portable_project "$failed" project-mixed-failed
  attach_portable_project "$failed" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$failed")"
  owner_before="$(cat "$owner")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  printf 'corrupted-payload\n' > "$managed/release-payload"
  chmod 600 "$managed/release-payload"
  record_unavailable_root personal project-mixed-failed "$SANDBOX/missing-project-mixed-failed"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project project-mixed-failed

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"unavailable adoption target remains explicit: personal/project-mixed-failed"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/project-mixed-failed"* ]] ||
    { echo "$output"; false; }
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(readlink "$failed/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
}

@test "a broken sibling row is refused while a healthy target adopts without rollback churn" {
  install_adoption_releases
  project="$SANDBOX/broken-sibling-healthy"
  make_portable_project "$project" broken-sibling-healthy
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  sibling="$(add_broken_registry_sibling personal broken-sibling "$ADOPTION_VERSION_A")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal

  # Highest exit class: the broken row is a per-row state error, reported and
  # skipped, never adopted onto.
  [ "$status" -eq 4 ]
  [[ "$output" == *"adoption target failed local registry identity validation: personal/broken-sibling"* ]] || { echo "$output"; false; }
  [ "$(registry_release_for_root "$sibling")" = "$ADOPTION_VERSION_A" ]
  [ ! -e "$sibling/.trellis/runtime" ]

  # The healthy target committed and was never touched-then-restored. `adopted:`
  # is emitted only after update_group_registry succeeded; every rollback path
  # runs before that line and restores the anchor, the owner journal, and the
  # recorded release to version A. All three are on B.
  [[ "$output" == *"adopted: personal/broken-sibling-healthy"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_B" ]
  [ "$(jq -r '.status' "$owner")" = "committed" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}

@test "bulk adoption skips a checkout inventory row instead of failing a healthy registry" {
  install_adoption_releases
  project="$SANDBOX/bulk-checkout-healthy"
  make_portable_project "$project" bulk-checkout-healthy
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  empty="$(add_empty_worktrees_checkout personal bulk-empty-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]

  # A bulk selector sweeps the whole machine or the whole fleet. Handing the
  # inventory row to the explicit-target loop made `adopt --all` fail class 5 on
  # a registry with nothing wrong with it — one empty-worktrees checkout was
  # enough to block every adoption on the machine.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'skipping checkout inventory row with no registered worktree: personal/bulk-empty-checkout' <<<"$output"
  grep -qF 'adopted: personal/bulk-checkout-healthy' <<<"$output"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ ! -e "$empty/.trellis/runtime" ]

  # Explicitly naming the checkout-only project stays an honest refusal: there
  # is no worktree to adopt onto.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project bulk-empty-checkout
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'unavailable adoption target remains explicit: personal/bulk-empty-checkout' <<<"$output"
}

@test "a bulk selection of nothing but checkout inventory rows adopts nothing and exits 5" {
  install_adoption_releases
  empty="$(add_empty_worktrees_checkout personal only-empty-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]

  # Skipping the inventory row is right; reporting SUCCESS for a run that
  # adopted nothing is not. The skip branch sets no status and the empty-groups
  # fallback (`${rc:-...}`) could never fire because `rc` is always set, so this
  # exited 0 over a selection with no adoptable target in it.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'skipping checkout inventory row with no registered worktree: personal/only-empty-checkout' <<<"$output"
  grep -qF 'no adoptable registered worktree matched the requested adoption selector' <<<"$output"
  [ "$(grep -cF 'adopted:' <<<"$output")" -eq 0 ]
  [ ! -e "$empty/.trellis/runtime" ]

  # Same verdict through the fleet selector, which shares the skip branch.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --fleet personal
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'no adoptable registered worktree matched the requested adoption selector' <<<"$output"
}

@test "a bulk unavailable checkout inventory row is reported without failing a healthy target" {
  install_adoption_releases
  project="$SANDBOX/bulk-checkout-guarded"
  make_portable_project "$project" bulk-checkout-guarded
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  empty="$(add_empty_worktrees_checkout personal bulk-unavailable-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]
  # Present and correctly hashed, but not traversable: the row classifies
  # class-5 `unavailable`, exactly like the worktree case.
  chmod 600 "$empty"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  chmod 700 "$empty"

  # Bulk unavailable rows are reported but do not contribute class 5; the
  # healthy target still adopts and the run succeeds.
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'unavailable checkout inventory row swept by the adoption selector: personal/bulk-unavailable-checkout' <<<"$output"
  # Per-row continuation: the healthy target still adopts.
  grep -qF 'adopted: personal/bulk-checkout-guarded' <<<"$output"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
}

@test "adoption waits out a brief checkout-lock holder and names a lasting one" {
  install_adoption_releases
  project="$SANDBOX/lock-held-healthy"
  make_portable_project "$project" lock-held-healthy
  TRELLIS_ATTACH_POSTJOB=off attach_portable_project "$project" personal "$ADOPTION_VERSION_A"

  # The detached post-attach job takes the checkout lock for brief steps right
  # after every attach. An adopt landing in that window exited 3 with no
  # message, failing a healthy target. The holder lives until adopt has met
  # the held lock, then goes away the way the job does.
  sleep 300 &
  holder=$!
  stage_checkout_lock_holder "$project" "$holder"
  mkdir "$RELEASE_TEST_ADOPTION_BARRIER"
  : > "$RELEASE_TEST_ADOPTION_BARRIER/after-plan-validation.release"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all > "$SANDBOX/adopt.log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$RELEASE_TEST_ADOPTION_BARRIER/checkout-lock-busy.ready" \
    "$RELEASE_PROCESS_PID_A" "$SANDBOX/adopt.log"
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  rm -rf "$RELEASE_TEST_ADOPTION_BARRIER"
  [ "$RELEASE_PROCESS_STATUS" -eq 0 ] || { cat "$SANDBOX/adopt.log"; false; }
  grep -qF 'adopted: personal/lock-held-healthy' "$SANDBOX/adopt.log"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]

  # The wait is bounded (300 s; the fixture shortens it to 2 s): a holder that
  # outlives it is refused by name, and the target keeps its release.
  sleep 30 &
  holder=$!
  stage_checkout_lock_holder "$project" "$holder"
  mkdir "$RELEASE_TEST_ADOPTION_BARRIER"
  : > "$RELEASE_TEST_ADOPTION_BARRIER/after-plan-validation.release"
  : > "$RELEASE_TEST_ADOPTION_BARRIER/short-lock-wait"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_A" --all
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -rf "$RELEASE_TEST_ADOPTION_BARRIER"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'another Trellis operation still holds the checkout lock' <<<"$output"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
}

@test "a project-scoped adoption still reports a drifted row outside the selection" {
  install_adoption_releases
  project="$SANDBOX/scoped-adopt-healthy"
  make_portable_project "$project" scoped-adopt-healthy
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  sibling="$(add_broken_registry_sibling personal scoped-adopt-broken "$ADOPTION_VERSION_A")"

  # The adoption selector decides what is ADOPTED, never what counts toward the
  # exit class: a scoped adopt over a healthy project used to succeed with
  # exit 0 over a registry it had just listed as corrupt.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project scoped-adopt-healthy
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'registry row outside the adoption selector failed local registry identity validation: personal/scoped-adopt-broken' <<<"$output"
  # Selection still limits PROCESSING: the healthy target adopted, the drifted
  # row was never touched.
  grep -qF 'adopted: personal/scoped-adopt-healthy' <<<"$output"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$sibling")" = "$ADOPTION_VERSION_A" ]
}

@test "an unreadable registered root stays a class-5 unavailable row without failing healthy bulk adoption" {
  install_adoption_releases
  healthy="$SANDBOX/class5-healthy"
  blocked="$SANDBOX/class5-blocked"
  make_portable_project "$healthy" class5-healthy
  make_portable_project "$blocked" class5-blocked
  attach_portable_project "$healthy" personal "$ADOPTION_VERSION_A"
  attach_portable_project "$blocked" personal "$ADOPTION_VERSION_A"
  # Present and correctly hashed, but not traversable: canonicalizing the root
  # fails with the environment class (5). That must classify the row unavailable
  # — the class-5 word in the availability vocabulary — and never collapse into
  # identity_error, which is the class-4 word for registry corruption.
  chmod 600 "$blocked"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal
  chmod 700 "$blocked"

  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable adoption target remains explicit: personal/class5-blocked"* ]] || { echo "$output"; false; }
  [[ "$output" != *"identity validation: personal/class5-blocked"* ]] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/class5-healthy"* ]] || { echo "$output"; false; }
  [ "$(readlink "$healthy/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$healthy")" = "$ADOPTION_VERSION_B" ]
}

@test "a detached or excluded checkout inventory row is reported, not silently skipped" {
  install_adoption_releases
  empty="$(add_empty_worktrees_checkout personal status-empty-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]
  registry="$TRELLIS_HOME_FIX/registry.json"

  # DETACHED. The row is reachable and correctly hashed, so its availability is
  # `available` and only its STATUS disqualifies it. The worktree branch refuses
  # exactly this triple — availability, status, exclusion — but the checkout
  # branch tested `status = unavailable` alone, so a detached empty checkout
  # swept by `--all` was announced as a benign skip carrying no class at all.
  jq '.projects["personal/status-empty-checkout"].status = "detached"' \
    "$registry" > "$registry.next"
  mv -f "$registry.next" "$registry"
  chmod 600 "$registry"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'unavailable checkout inventory row swept by the adoption selector: personal/status-empty-checkout' <<<"$output"
  [ "$(grep -cF 'skipping checkout inventory row' <<<"$output")" -eq 0 ]

  # EXCLUDED, active again: the other half of the same predicate, and the other
  # word the old guard could not see.
  jq '.projects["personal/status-empty-checkout"] |= (.status = "active" | .metadata.legacy.blacklisted = true)' \
    "$registry" > "$registry.next"
  mv -f "$registry.next" "$registry"
  chmod 600 "$registry"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'unavailable checkout inventory row swept by the adoption selector: personal/status-empty-checkout' <<<"$output"
  [ "$(grep -cF 'skipping checkout inventory row' <<<"$output")" -eq 0 ]
  [ ! -e "$empty/.trellis/runtime" ]
}
