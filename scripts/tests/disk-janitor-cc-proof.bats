#!/usr/bin/env bats
# Read-only A7 verdict tests: fake HOME and stubbed launchctl/git/gh on PATH.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-cc-proof.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"
  TRELLIS_HOME="$SANDBOX/trellis"
  STUB_BIN="$SANDBOX/bin"
  PR_RESPONSE="$SANDBOX/pr.json"
  MAIN="$SANDBOX/repo"
  CC="$SANDBOX/cc-foo"
  local fenced_git
  fenced_git="$(command -v git)"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$STUB_BIN"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  printf '#!/bin/bash\ncase "$*" in *" config --local --remove-section "*) [ "${FIXTURE_FAIL_CONFIG:-0}" = 1 ] && { echo "fixture config failure" >&2; exit 2; };; esac\nexec %q "$@"\n' "$fenced_git" > "$STUB_BIN/git"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/launchctl"
  printf '#!/bin/sh\nexec /bin/cat "$PR_RESPONSE"\n' > "$STUB_BIN/gh"
  chmod 700 "$STUB_BIN/git" "$STUB_BIN/gh" "$STUB_BIN/launchctl"
  PATH="$STUB_BIN:$PATH"
  export HOME TRELLIS_HOME PR_RESPONSE PATH
  git init -q -b main "$MAIN"
  git -C "$MAIN" config user.name fixture
  git -C "$MAIN" config user.email fixture@example.invalid
  printf 'base\n' > "$MAIN/tracked"
  git -C "$MAIN" add tracked
  git -C "$MAIN" commit -qm base
  git -C "$MAIN" worktree add -q -b worktree-cc-foo "$CC"
  BASE="$(git -C "$CC" rev-parse HEAD)"
  . "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh"
  . "$REPO_ROOT/scripts/lib/hygiene-common.sh"
  . "$REPO_ROOT/scripts/lib/disk-janitor-dehydrate.sh"
  # Keep time, liveness and owner probes deterministic and read-only.
  cfg_num() { echo 1; }
  hy_last_git_activity() { echo 1; }
  dj_cache_is_stale() { return 0; }
  dj_worktree_in_use() { return 1; }
  dj_pi_owner_paths() { : > "$2"; }
  dj_pi_path_owned() { return 1; }
  NOW_EPOCH=2000000000
  LSOF_SNAPSHOT_TMP="$SANDBOX/lsof"
  SAFE_ONLY=1
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "${SANDBOX:?}"
}

merged_pr() {
  jq -n --arg head "$1" '[{number:1,state:"MERGED",headRefOid:$head}]' > "$PR_RESPONSE"
}

verdict() {
  run _dw_cc_verdict "$CC" worktree-cc-foo "$MAIN" 0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "merged PR proves only its own head, not two later local commits or branch reuse" {
  merged_pr "$BASE"
  verdict
  [[ "$output" == sweep$'\t'* ]] || { echo "$output"; false; }

  printf 'one\n' >> "$CC/tracked"
  git -C "$CC" commit -qam one
  printf 'two\n' >> "$CC/tracked"
  git -C "$CC" commit -qam two
  verdict
  [[ "$output" == hold$'\t'*"2 unique commit(s)"* ]] || { echo "$output"; false; }

  jq -n --arg old "$BASE" --arg current "$(git -C "$CC" rev-parse HEAD)" \
    '[{number:2,state:"OPEN",headRefOid:$current},{number:1,state:"MERGED",headRefOid:$old}]' > "$PR_RESPONSE"
  SAFE_ONLY=0
  verdict
  [[ "$output" == hold$'\t'*"2 unique commit(s)"* ]] || { echo "$output"; false; }
  # Reuse stays a hold even when the newer PR also says merged.
  jq 'map(if .number == 2 then .state = "MERGED" else . end)' "$PR_RESPONSE" > "$SANDBOX/merged-reuse.json"
  mv "$SANDBOX/merged-reuse.json" "$PR_RESPONSE"
  verdict
  [[ "$output" == hold$'\t'*"2 unique commit(s)"* ]] || { echo "$output"; false; }
}

@test "ancestor of merged PR head can sweep; missing head and hidden local files cannot" {
  local future
  printf 'future\n' >> "$CC/tracked"
  git -C "$CC" commit -qam future
  future="$(git -C "$CC" rev-parse HEAD)"
  git -C "$MAIN" worktree add -q -b worktree-cc-ancestor "$SANDBOX/cc-ancestor" "$BASE"
  merged_pr "$future"
  run _dw_cc_verdict "$SANDBOX/cc-ancestor" worktree-cc-ancestor "$MAIN" 0
  [[ "$output" == sweep$'\t'* ]] || { echo "$output"; false; }

  merged_pr 1111111111111111111111111111111111111111
  verdict
  [[ "$output" == hold$'\t'* ]] || { echo "$output"; false; }

  merged_pr "$future"
  git -C "$MAIN" config status.showUntrackedFiles no
  printf 'local data\n' > "$CC/notes.txt"
  verdict
  [[ "$output" == hold$'\t'*"tracked or untracked changes"* ]] || { echo "$output"; false; }
}

@test "conditional branch deletion preserves an advanced or checked-out ref" {
  local future
  git -C "$MAIN" branch safe-branch "$BASE"
  git -C "$MAIN" config --local branch.safe-branch.description fixture
  printf 'future\n' >> "$CC/tracked"
  git -C "$CC" commit -qam future
  future="$(git -C "$CC" rev-parse HEAD)"
  git -C "$MAIN" update-ref refs/heads/safe-branch "$future" "$BASE"

  run _dw_cc_delete_merged_branch "$MAIN" safe-branch "$BASE"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"changed or could not be deleted"* ]] || { echo "$output"; false; }
  [ "$(git -C "$MAIN" rev-parse refs/heads/safe-branch)" = "$future" ]
  [ "$(git -C "$MAIN" config --local --get branch.safe-branch.description)" = fixture ]

  run _dw_cc_delete_merged_branch "$MAIN" worktree-cc-foo "$future"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"is checked out in a worktree"* ]] || { echo "$output"; false; }
  [ "$(git -C "$MAIN" rev-parse refs/heads/worktree-cc-foo)" = "$future" ]
}

@test "conditional branch deletion removes the matching ref and its config" {
  git -C "$MAIN" branch safe-branch "$BASE"
  git -C "$MAIN" config --local branch.safe-branch.description fixture
  run _dw_cc_delete_merged_branch "$MAIN" safe-branch "$BASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! git -C "$MAIN" show-ref --verify --quiet refs/heads/safe-branch
  ! git -C "$MAIN" config --local --get branch.safe-branch.description

  # An absent config section is also normal.
  git -C "$MAIN" branch no-config "$BASE"
  run _dw_cc_delete_merged_branch "$MAIN" no-config "$BASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "conditional deletion removes a symbolic branch without following its target" {
  git -C "$MAIN" branch target "$BASE"
  git -C "$MAIN" symbolic-ref refs/heads/alias refs/heads/target
  run _dw_cc_delete_merged_branch "$MAIN" alias "$BASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  git -C "$MAIN" show-ref --verify --quiet refs/heads/target || { echo 'symbolic target was deleted'; false; }
  ! git -C "$MAIN" symbolic-ref -q refs/heads/alias
}

@test "branch config errors are reported without restoring the deleted ref" {
  git -C "$MAIN" branch safe-branch "$BASE"
  git -C "$MAIN" config --local branch.safe-branch.description fixture
  FIXTURE_FAIL_CONFIG=1 run _dw_cc_delete_merged_branch "$MAIN" safe-branch "$BASE"
  [[ "$output" == *"fixture config failure"* ]] || { echo "$output"; false; }
  ! git -C "$MAIN" show-ref --verify --quiet refs/heads/safe-branch
}

@test "unmerged worktree with no unique commits is eligible only without safe-only and keeps its branch" {
  printf '[]\n' > "$PR_RESPONSE"
  SAFE_ONLY=0
  verdict
  [[ "$output" == sweep$'\t'0$'\t'*"no unique commits"* ]] || { echo "$output"; false; }
  SAFE_ONLY=1
  verdict
  [[ "$output" == hold$'\t'* ]] || { echo "$output"; false; }
}
