#!/usr/bin/env bats
# shellcheck shell=bats
# Spec 067 T10/T11. Real Git fixtures; no attach, doctor or gate invocation.
# The execution fixture stubs ONLY the dispatcher's common body/reconciliation;
# its entire post-checkout body, including the recorder, comes from the generator.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
FEATURE="$REPO_ROOT/core-rules/skills/spec/scripts/new-feature.sh"
WORKTREE="$REPO_ROOT/scripts/worktree.sh"
DB="$REPO_ROOT/core-rules/skills/process-gate/scripts/lib/diff-base.sh"

setup() {
  ROOT="$BATS_TEST_TMPDIR/creation"
  mkdir -p "$ROOT/repo" "$ROOT/hooks"
  ROOT="$(CDPATH='' cd "$ROOT" && pwd -P)"
  REPO="$ROOT/repo"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  export TRELLIS_HOME="$ROOT/trellis-home" TRELLIS_WORKTREE_ROOT="$ROOT/worktrees"
  WT="$TRELLIS_WORKTREE_ROOT/_unregistered/repo/feature-b"
  git init -qb main "$REPO"
  git -C "$REPO" config user.name test
  git -C "$REPO" config user.email test@example.invalid
  git -C "$REPO" config commit.gpgsign false
  printf 'tracked\n' > "$REPO/tracked.txt"
  git -C "$REPO" add tracked.txt
  git -C "$REPO" commit -qm m0
  M0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/a
  git -C "$REPO" commit --allow-empty -qm a1
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  # Library is linted separately; do not import its Bash dialect into Bats.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  cd "$REPO" || return 1
}

install_recorder() {
  (
    _attachment_hooks_dispatcher_common_body() {
      printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
        'project_root="$PWD"; managed_dir="$PWD"' \
        'trellis_enter_command_scratch() { :; }' \
        'trellis_read_sidecar() { printf "stub\n"; }' \
        'trellis_prior_hook() { return 0; }' \
        'trellis_managed_payload_file() { printf "/dev/null\n"; }' \
        'trellis_run_control_payload() { return 0; }'
    }
    _attachment_hooks_post_checkout_dispatcher_body_in_process > "$ROOT/hooks/post-checkout"
  ) || return 1
  chmod 700 "$ROOT/hooks/post-checkout"
  git config --local core.hooksPath "$ROOT/hooks"
}

assert_record() {
  [ "$(git config --local --get "branch.$1.trellisParent")" = "$2" ]
  [ "$(git config --local --get "branch.$1.trellisBase")" = "$3" ]
  [ "$(git config --local --get "branch.$1.trellisSource")" = "$4" ]
}

@test "checkout -b records the start tip and the resolver uses recorded metadata" {
  install_recorder
  run git checkout -b feature/b feature/a
  [ "$status" -eq 0 ]
  assert_record feature/b feature/a "$ATIP" post-checkout
  git commit --allow-empty -qm b1
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_BASE_SHA=$ATIP"* ]]
  [[ "$output" == *"DB_SOURCE=recorded"* ]]
}

@test "worktree add records A despite null previous head and uses common config" {
  install_recorder
  git config extensions.worktreeConfig true
  run git worktree add -b feature/b "$ROOT/linked worktree" feature/a
  [ "$status" -eq 0 ]
  assert_record feature/b feature/a "$ATIP" post-checkout
  [ "$(git -C "$ROOT/linked worktree" config --local --get branch.feature/b.trellisBase)" = "$ATIP" ]
}

@test "dispatcher never overwrites an existing creation record" {
  install_recorder
  git config branch.feature/b.trellisParent main
  git config branch.feature/b.trellisBase "$M0"
  git config branch.feature/b.trellisSource manual
  run git checkout -b feature/b feature/a
  [ "$status" -eq 0 ]
  assert_record feature/b main "$M0" manual
}

@test "checkout -b X other from a third branch never uses previous head" {
  git checkout -qb third main
  git commit --allow-empty -qm third
  THIRD="$(git rev-parse HEAD)"
  install_recorder
  run git checkout -b feature/x feature/a
  [ "$status" -eq 0 ]
  assert_record feature/x feature/a "$ATIP" post-checkout
  [ "$(git config branch.feature/x.trellisBase)" != "$THIRD" ]
}

@test "Created from HEAD resolves the exact HEAD checkout source" {
  # A similar earlier target must not match feature/b's checkout event.
  git checkout -qb feature/b-extra main
  git checkout -q feature/a
  install_recorder
  run git checkout -b feature/b
  [ "$status" -eq 0 ]
  assert_record feature/b feature/a "$ATIP" post-checkout
}

@test "a single-entry creation reflog takes the callback new-head SHA" {
  git branch feature/b feature/a
  # Deliberately divergent but valid entry SHA isolates the fresh-record rule.
  python3 - "$REPO/.git/logs/refs/heads/feature/b" "$ATIP" "$M0" <<'PYFIX'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace(sys.argv[2], sys.argv[3], 1))
PYFIX
  install_recorder
  run git checkout feature/b
  [ "$status" -eq 0 ]
  assert_record feature/b feature/a "$ATIP" post-checkout
}

@test "late recording uses creation entry rather than the latest checkout SHA" {
  git checkout -qb feature/b feature/a
  git commit --allow-empty -qm b1
  BTIP="$(git rev-parse HEAD)"
  git checkout -q main
  install_recorder
  run git checkout feature/b
  [ "$status" -eq 0 ]
  assert_record feature/b feature/a "$ATIP" post-checkout
  [ "$(git config branch.feature/b.trellisBase)" != "$BTIP" ]
}

@test "file checkout never records a branch creation base" {
  git checkout -qb feature/b feature/a
  install_recorder
  run git checkout HEAD -- tracked.txt
  [ "$status" -eq 0 ]
  run git config --local --get branch.feature/b.trellisParent
  [ "$status" -eq 1 ]
}

@test "config write failure warns without failing checkout" {
  install_recorder
  : > "$REPO/.git/config.lock"
  run git checkout -b feature/b feature/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"trellis post-checkout: warning: could not record branch creation base"* ]]
  [ "$(git symbolic-ref --short HEAD)" = feature/b ]
  run git config --local --get branch.feature/b.trellisParent
  [ "$status" -eq 1 ]
}

@test "failed source write does not publish a parent record" {
  # The only shell stub is git config's second write; all reads use real Git.
  install_recorder
  python3 - "$ROOT/hooks/post-checkout" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('set -u\n', '''set -u
git() {
  case "$*" in *' config --local branch.feature/b.trellisSource post-checkout') return 1 ;; esac
  command git "$@"
}
''', 1)
p.write_text(s)
PY
  run git checkout -b feature/b feature/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: could not record branch creation base"* ]]
  run git config --local --get branch.feature/b.trellisParent
  [ "$status" -eq 1 ]
}

@test "regenerated dispatcher verifies and has a stable adopt delivery marker" {
  # Real common body and real versioned-byte verifier, no execution/lifecycle op.
  HOME_FIXTURE="$ROOT/managed-home"
  PAYLOAD="$HOME_FIXTURE/releases/1.2.3/payload"
  MANAGED="$HOME_FIXTURE/state/git-hooks/fixture"
  SOURCE="core-rules/githooks/pre-push"
  mkdir -p "$PAYLOAD/core-rules/githooks" "$MANAGED"
  printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/$SOURCE"
  OID="$(git hash-object "$PAYLOAD/$SOURCE")"
  jq -n --arg oid "$OID" --arg source "$SOURCE" \
    '{schema_version:1,version:"1.2.3",tag:"v1.2.3",commit:"0000000000000000000000000000000000000000",remote:"fixture",tree:[{path:$source,mode:"100755",oid:$oid}]}' \
    > "${PAYLOAD%/payload}/release.json"
  MANIFEST="$(_attachment_hooks_release_manifest_sha256 "$PAYLOAD")"
  POST="$(_attachment_hooks_post_checkout_dispatcher_body "$PAYLOAD" "$MANIFEST")"
  PRE="$(_attachment_hooks_pre_push_dispatcher_body "$PAYLOAD" "$SOURCE" "$MANIFEST")"
  printf '%s\n' "$POST" > "$MANAGED/post-checkout"
  printf '%s\n' "$PRE" > "$MANAGED/pre-push"
  printf '\n' > "$MANAGED/previous-hooks-path"
  printf '%s\n' "$PAYLOAD" > "$MANAGED/release-payload"
  printf '%s\n' "$SOURCE" > "$MANAGED/pre-push-source"
  chmod 700 "$HOME_FIXTURE/state/git-hooks" "$MANAGED" "$MANAGED/post-checkout" "$MANAGED/pre-push"
  chmod 600 "$MANAGED/previous-hooks-path" "$MANAGED/release-payload" "$MANAGED/pre-push-source"
  OWNER="$(jq -nc --arg managed "$MANAGED" --arg source "$SOURCE" \
    '{checkout_id:"fixture",release:"1.2.3",git_hooks:{managed_hooks_path:$managed,previous_hooks_path:null,pre_push_source:$source}}')"
  run _attachment_hooks_state_owned_matches_data "$HOME_FIXTURE" "$OWNER" false
  [ "$status" -eq 0 ]
  run grep -c 'trellis-diff-base-creation-recorder-v1' "$MANAGED/post-checkout"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  # A missing recorder is not accepted merely because the rest of the hook matches.
  python3 - "$MANAGED/post-checkout" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('# trellis-diff-base-creation-recorder-v1', '# removed-recorder'))
PY
  run _attachment_hooks_state_owned_matches_data "$HOME_FIXTURE" "$OWNER" false
  [ "$status" -eq 3 ]
}

@test "wrapper --no-checkout -b records the literal parent without a dispatcher" {
  run bash "$WORKTREE" add --no-checkout feature/b feature/a
  [ "$status" -eq 0 ]
  assert_record feature/b feature/a "$ATIP" worktree
  [ -d "$WT" ] && [ ! -e "$WT/tracked.txt" ]
}

@test "wrapper default HEAD parent is captured before worktree creation" {
  git checkout -q feature/a
  run bash "$WORKTREE" add --no-checkout feature/b
  [ "$status" -eq 0 ]
  assert_record feature/b feature/a "$ATIP" worktree
}

@test "wrapper never overwrites an existing record" {
  git config branch.feature/b.trellisParent main
  git config branch.feature/b.trellisBase "$M0"
  git config branch.feature/b.trellisSource manual
  run bash "$WORKTREE" add --no-checkout feature/b feature/a
  [ "$status" -eq 0 ]
  assert_record feature/b main "$M0" manual
}

@test "new-feature --from creates and records an explicitly stacked branch" {
  run bash "$FEATURE" stacked --from feature/a
  [ "$status" -eq 0 ]
  [ "$(git symbolic-ref --short HEAD)" = feature/stacked ]
  [ "$(git rev-parse HEAD)" = "$ATIP" ]
  assert_record feature/stacked feature/a "$ATIP" new-feature
  [ -f "$REPO/specs/001-stacked/spec.md" ]
}

@test "new-feature --from bypasses only the default branch guard" {
  git checkout -qb third main
  git commit --allow-empty -qm third
  run bash "$FEATURE" stacked --from=feature/a
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$ATIP" ]
  assert_record feature/stacked feature/a "$ATIP" new-feature
}

@test "new-feature without --from still refuses off main" {
  git checkout -q feature/a
  run bash "$FEATURE" refused
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected main/master"* ]]
  [ "$(git symbolic-ref --short HEAD)" = feature/a ]
  [ ! -e "$REPO/specs/001-refused" ]
}

@test "new-feature default creation records main" {
  run bash "$FEATURE" unstacked
  [ "$status" -eq 0 ]
  assert_record feature/unstacked main "$M0" new-feature
}

@test "new-feature --from preserves a pre-existing record" {
  git config branch.feature/stacked.trellisParent main
  git config branch.feature/stacked.trellisBase "$M0"
  git config branch.feature/stacked.trellisSource manual
  run bash "$FEATURE" stacked --from feature/a
  [ "$status" -eq 0 ]
  assert_record feature/stacked main "$M0" manual
}

@test "new-feature rejects --from without a parent or with --no-branch" {
  run bash "$FEATURE" missing --from
  [ "$status" -eq 2 ]
  [[ "$output" == *"--from requires a parent ref"* ]]
  run bash "$FEATURE" conflicting --from feature/a --no-branch
  [ "$status" -eq 2 ]
  [[ "$output" == *"--from cannot be combined with --no-branch"* ]]
  [ "$(git symbolic-ref --short HEAD)" = main ]
}
