#!/usr/bin/env bats
# Split from doctor-fix.bats: part 3 of 4.
load doctor-fix-common

@test "portable doctor rejects native-surface drift but relinks through surrounding exclude drift" {
  build_portable_doctor_fix_home
  attach_portable_doctor_project
  rm "$PORTABLE_PROJECT/.trellis/runtime"
  printf '\n# user exclude drift\n' >> "$PORTABLE_PROJECT/.git/info/exclude"
  jq --arg checkout "$PORTABLE_CHECKOUT_ID" --arg worktree "$PORTABLE_WORKTREE_ID" \
    '.projects["personal/portable-fixture"].checkouts[$checkout].harnesses = ["codex"]' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  # The registry harness selection is an input to the native-surface plan the
  # owner exclude block is derived from, so shrinking that selection changes the
  # EXPECTED block and the excludes check reports a plan mismatch. It therefore
  # never reaches the "surrounding user bytes changed" wording, which compares
  # the on-disk file against an expected block it has already rejected. This
  # assertion asked for that later wording and was inert (a bare mid-test
  # `[[ … ]]` does not fail a bats test on this host), so it never reported that
  # it was checking for a message this fixture cannot produce. Exclude-byte
  # drift is asserted on its own below, where it is actually reachable.
  [ "$status" -eq 3 ]
  [[ "$output" == *"managed excludes: owner block does not match the exact immutable native surface plan"* ]] || { echo "$output"; false; }
  [[ "$output" == *"native surfaces: registry harness selection does not exactly match"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis relink"* ]] || { echo "$output"; false; }

  # Restore the attached harness selection so the immutable block matches
  # again. The appended user bytes are advisory, so they must not withhold the
  # otherwise-safe runtime relink.
  jq --arg checkout "$PORTABLE_CHECKOUT_ID" \
    '.projects["personal/portable-fixture"].checkouts[$checkout].harnesses = ["claude", "codex"]' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"managed excludes: exact immutable native-surface block matches; surrounding user bytes drifted at $PORTABLE_PROJECT/.git/info/exclude"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[auto] trellis relink"* ]] || { echo "$output"; false; }
}

@test "portable doctor reports identity drift and still enumerates a later row" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  drift_root="$SANDBOX/a-drift"
  visible_root="$SANDBOX/z-visible"
  build_portable_fixture_project "$drift_root" a-drift
  build_portable_fixture_project "$visible_root" z-visible
  drift_identity="$(portable_identity_for_root "$drift_root")"
  visible_identity="$(portable_identity_for_root "$visible_root")"
  drift_checkout="$(printf '%s\n' "$drift_identity" | jq -r '.checkout_id')"
  drift_common="$(printf '%s\n' "$drift_identity" | jq -r '.git_common_dir')"
  visible_checkout="$(printf '%s\n' "$visible_identity" | jq -r '.checkout_id')"
  visible_worktree="$(printf '%s\n' "$visible_identity" | jq -r '.worktree_id')"
  visible_common="$(printf '%s\n' "$visible_identity" | jq -r '.git_common_dir')"
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/a-drift":{"fleet":"personal","project_id":"a-drift","status":"active","metadata":{},"checkouts":{"$drift_checkout":{"root":"$drift_root","git_common_dir":"$drift_common","release":"1.2.3","harnesses":["claude"],"worktrees":{"0000000000000000000000000000000000000000000000000000000000000000":{"root":"$drift_root"}}}}},"personal/z-visible":{"fleet":"personal","project_id":"z-visible","status":"active","metadata":{},"checkouts":{"$visible_checkout":{"root":"$visible_root","git_common_dir":"$visible_common","release":"1.2.3","harnesses":["claude"],"worktrees":{"$visible_worktree":{"root":"$visible_root"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"
  jq '.projects["personal/a-drift"].checkouts |= with_entries(.value.release = "9.9.9")' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 5 ]
  [[ "$output" == *"a-drift (worktree)"* ]] || { echo "$output"; false; }
  # The detail text comes from local_registry (`worktree ID does not match
  # recorded root`); the wording this assertion asked for was never emitted by
  # any code path. It was inert, so the mismatch went unreported.
  [[ "$output" == *"identity drift: worktree ID does not match recorded root"* ]] || { echo "$output"; false; }
  [[ "$output" == *"immutable release: 9.9.9 is unavailable"* ]] || { echo "$output"; false; }
  [[ "${output#*a-drift (worktree)}" == *"z-visible (worktree)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[auto] trellis attach"*"$visible_root"* ]] || { echo "$output"; false; }
}

@test "A4.4 (a): recorded previous .husky/_ is repaired and still chains to .husky/pre-push" {
  hooks_fix_attach husky
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$HF_OWNER")" = ".husky/_" ]
  husky_prepare
  run_portable_doctor_fix --fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath repaired in"*": .husky/_ -> "* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = "$HF_MANAGED" ]
  [ "$(cat "$HF_MANAGED/previous-hooks-path")" = ".husky/_" ]
  # The managed pre-push still runs the project's husky pre-push first.
  ( cd "$PORTABLE_PROJECT" && env HOME="$PORTABLE_ACCOUNT_HOME" "$HF_MANAGED/pre-push" origin /dev/null </dev/null ) || true
  [ "$(cat "$SANDBOX/husky-pre-push-ran")" = chained ]
}

@test "A4.4 (b): previous null with only husky's _/ runner is repaired" {
  hooks_fix_attach null
  husky_prepare
  assert_repaired_null_previous
}

@test "A4.4 (b'): previous null with no .husky/ directory at all is repaired" {
  hooks_fix_attach null
  git -C "$PORTABLE_PROJECT" config --local core.hooksPath .husky/_
  [ ! -e "$PORTABLE_PROJECT/.husky" ]
  assert_repaired_null_previous
}

@test "A4.4 (b''): a dispatcher invalidated after the write restores .husky/_ and leaves the record untouched" {
  local record_before
  hooks_fix_attach null
  husky_prepare
  record_before="$(shasum -a 256 "$HF_OWNER")"
  DOCTOR_FIX_FAULT_PHASE=hooks-path-invalidate-dispatcher run_portable_doctor_fix --fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the managed dispatcher no longer verifies"*"restored .husky/_"* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = ".husky/_" ]
  [ "$(shasum -a 256 "$HF_OWNER")" = "$record_before" ]
  [ "$(jq -r '.git_hooks | has("previous_hooks_path") and .previous_hooks_path == null' "$HF_OWNER")" = true ]
}

@test "A4.4 (c): previous null with .husky/pre-commit present is refused, naming --adopt-husky" {
  local before
  hooks_fix_attach null
  husky_prepare
  printf '#!/bin/sh\nexit 0\n' > "$PORTABLE_PROJECT/.husky/pre-commit"
  chmod +x "$PORTABLE_PROJECT/.husky/pre-commit"
  before="$(config_digest)"
  run_portable_doctor_fix --fix
  assert_refused_unchanged "$before" 'trellis doctor --fix --adopt-husky'
}

@test "A4.4 (d): a value Trellis did not record, /custom, is refused" {
  local before
  hooks_fix_attach null
  git -C "$PORTABLE_PROJECT" config --local core.hooksPath /custom
  before="$(config_digest)"
  run_portable_doctor_fix --fix
  assert_refused_unchanged "$before" 'inspect it with git -C'
  [[ "$output" == *"config --show-origin --get-all core.hooksPath"*"will not overwrite a value it did not record"* ]] || { echo "$output"; false; }
}

@test "A4.4 (e): plain doctor reports the drift and changes nothing" {
  local before
  hooks_fix_attach null
  husky_prepare
  before="$(config_digest)"
  run_portable_doctor_fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"run trellis doctor --fix"* ]] || { echo "$output"; false; }
  [[ "$output" != *"core.hooksPath repair"* ]] || { echo "$output"; false; }
  [ "$(config_digest)" = "$before" ]
}

@test "A4.4 (f): a second value appearing after the write is reported, not restored" {
  hooks_fix_attach null
  husky_prepare
  DOCTOR_FIX_FAULT_PHASE=hooks-path-second-value run_portable_doctor_fix --fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath changed during the repair"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$HF_MANAGED"*"/trellis-fault/second-value"*"nothing was restored"* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" -eq 2 ]
}

@test "A4.4 (f'): a dispatcher invalidated before the re-verify, value still ours, restores .husky/_" {
  hooks_fix_attach husky
  husky_prepare
  DOCTOR_FIX_FAULT_PHASE=hooks-path-invalidate-dispatcher run_portable_doctor_fix --fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"restored .husky/_"* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = ".husky/_" ]
}

@test "A4.4 (f''): a value unset between the write and the re-read is reported as <unset>" {
  hooks_fix_attach null
  husky_prepare
  DOCTOR_FIX_FAULT_PHASE=hooks-path-unset run_portable_doctor_fix --fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath changed during the repair"*"observed values: <unset>; nothing was restored"* ]] || { echo "$output"; false; }
  run git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath
  [ "$status" -eq 1 ]
}

@test "A4.4 (d'): a trailing empty value after .husky/_ is more than one value and is refused" {
  local before
  hooks_fix_attach null
  husky_prepare
  git -C "$PORTABLE_PROJECT" config --local --add core.hooksPath ""
  before="$(config_digest)"
  run_portable_doctor_fix --fix
  assert_refused_unchanged "$before" 'inspect it with git -C'
  [[ "$output" == *"not exactly one value equal to .husky/_"* ]] || { echo "$output"; false; }
}

@test "A4.4 (h): an unattached sibling no longer blocks the repair; it is named for sync and stays unattached" {
  local sibling wid
  hooks_fix_attach null
  sibling="$SANDBOX/sibling wt"
  git -C "$PORTABLE_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b sibling "$sibling"
  sibling="$(cd "$sibling" && pwd -P)"
  husky_prepare
  wid="$(printf '%s' "$sibling" | shasum -a 256 | awk '{print $1}')"
  run_portable_doctor_fix --fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath repaired in"*": .husky/_ -> "* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = "$HF_MANAGED" ]
  [[ "$output" == *"trellis worktree sync $(printf '%q' "$sibling")"* ]] || { echo "$output"; false; }
  [ ! -e "$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$wid.json" ] || { echo "$output"; false; }
  # The sibling stays gated: its shared dispatcher refuses the push until it is synced.
  run bash -c 'cd "$1" && env HOME="$2" "$3" origin /dev/null </dev/null' _ "$sibling" "$PORTABLE_ACCOUNT_HOME" "$HF_MANAGED/pre-push"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"not attached"* ]] || { echo "$output"; false; }
}

@test "A4.4 (h'): a sibling owner symlink, even dangling, is refused as present and invalid, not as absent" {
  local before sibling wid
  hooks_fix_attach null
  sibling="$SANDBOX/sibling-link"
  git -C "$PORTABLE_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b sibling-link "$sibling"
  sibling="$(cd "$sibling" && pwd -P)"
  husky_prepare
  before="$(config_digest)"
  wid="$(printf '%s' "$sibling" | shasum -a 256 | awk '{print $1}')"
  ln -s "$SANDBOX/no-such-owner.json" "$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$wid.json"
  run_portable_doctor_fix --fix
  assert_refused_unchanged "$before" 'detach every worktree of the checkout, then attach the owning worktree first'
  [[ "$output" == *"worktree $sibling has an owner record that is a symlink or not a regular file"* ]] || { echo "$output"; false; }
}

@test "A4.4 (g): a sibling worktree with hooks disabled is refused by name" {
  local before sibling wid
  hooks_fix_attach null
  sibling="$SANDBOX/sibling-wt"
  git -C "$PORTABLE_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b sibling "$sibling"
  sibling="$(cd "$sibling" && pwd -P)"
  husky_prepare
  before="$(config_digest)"

  # (g) sibling attached with hooks disabled
  wid="$(printf '%s' "$sibling" | shasum -a 256 | awk '{print $1}')"
  jq '.git_hooks.enabled = false' "$HF_OWNER" > "$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$wid.json"
  chmod 600 "$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$wid.json"
  run_portable_doctor_fix --fix
  assert_refused_unchanged "$before" "detach every worktree of the checkout, then attach the owning worktree first"
  [[ "$output" == *"worktree $sibling has an owner record that is neither hooks-enabled nor a valid record with Trellis git hooks disabled"* ]] || { echo "$output"; false; }
}
