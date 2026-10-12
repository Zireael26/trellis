#!/usr/bin/env bats
# Spec 069 A3: `trellis worktree migrate` inventory and classifier (dry run).
#
# Hermetic: HOME, TRELLIS_HOME, the worktree root, the policy file, `gh` and
# `lsof` are sandboxed under BATS_TEST_TMPDIR; the operator's registry,
# worktrees and GitHub account are never read.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/worktree.sh"
load helpers/worktree-migrate

setup() {
  wm_fixture_setup
}

teardown() {
  wm_fixture_teardown
}

# ---------------------------------------------------------------------------
# A.3 inventory
# ---------------------------------------------------------------------------

@test "inventory lists a registered repo's linked worktrees and never its main checkout" {
  wm_repo "$HOME/projects/alpha"
  wm_register "$HOME/projects/alpha" alpha
  wm_wt "$HOME/projects/alpha" feat/one "$HOME/projects/alpha-wt/one"
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(rows | jq -s 'length')" -eq 1 ]
  row "$HOME/projects/alpha-wt/one" | jq -e '.project == "alpha" and .branch == "feat/one" and .repo == $repo' \
    --arg repo "$HOME/projects/alpha"
}

@test "inventory finds an unregistered repo through a .git file under known_parents" {
  wm_repo "$HOME/projects/beta"
  wm_wt "$HOME/projects/beta" topic "$HOME/projects/beta-worktrees/topic"
  wm_wt "$HOME/projects/beta" other "$HOME/elsewhere/other"
  migrate --json
  [ "$(rows | jq -s 'length')" -eq 0 ] || { echo "$output"; return 1; }
  wm_policy '{"worktrees":{"known_parents":["~/projects/beta-worktrees"]}}'
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # Both worktrees appear, including the one outside every scanned parent.
  [ "$(rows | jq -s 'length')" -eq 2 ]
  row "$HOME/elsewhere/other" | jq -e '.project == "_unregistered/beta"'
}

@test "inventory finds a repo whose worktree already sits under the central root" {
  wm_repo "$HOME/projects/gamma"
  wm_wt "$HOME/projects/gamma" topic "$WT_ROOT/_unregistered/gamma/topic"
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  row "$WT_ROOT/_unregistered/gamma/topic" | jq -e '.branch == "topic"'
}

@test "inventory reports an orphan directory whose gitdir is gone" {
  mkdir -p "$HOME/projects/parent/ghost"
  printf 'gitdir: %s\n' "$SANDBOX/gone/.git/worktrees/ghost" > "$HOME/projects/parent/ghost/.git"
  wm_policy '{"worktrees":{"known_parents":["~/projects/parent"]}}'
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  row "$HOME/projects/parent/ghost" | jq -e '.orphan == true and (.gitdir | endswith("/ghost"))'
}

@test "inventory flags a registered-but-missing worktree and attaches owner records" {
  wm_repo "$HOME/projects/alpha"
  wm_register "$HOME/projects/alpha" alpha
  wm_wt "$HOME/projects/alpha" gone "$HOME/projects/alpha-wt/gone"
  wm_wt "$HOME/projects/alpha" kept "$HOME/projects/alpha-wt/kept"
  rm -rf "$HOME/projects/alpha-wt/gone"
  wm_owner "$HOME/projects/alpha-wt/kept" 1.2.3
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  row "$HOME/projects/alpha-wt/gone" | jq -e '.missing == true'
  row "$HOME/projects/alpha-wt/kept" | jq -e '.missing == false and .release == "1.2.3" and .owner_count == 1'
}

@test "the default view is a table with totals" {
  wm_repo "$HOME/projects/alpha"
  wm_register "$HOME/projects/alpha" alpha
  wm_wt "$HOME/projects/alpha" feat/one "$HOME/projects/alpha-wt/one"
  migrate
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"ACTION"*"SIZE"*"PROJECT"*"BRANCH"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"$HOME/projects/alpha-wt/one"* ]]
  [[ "$output" == *"Totals: 1 worktree(s)"* ]] || { echo "$output"; return 1; }
}

@test "--only narrows the plan to one path" {
  wm_repo "$HOME/projects/alpha"
  wm_register "$HOME/projects/alpha" alpha
  wm_wt "$HOME/projects/alpha" a "$HOME/projects/alpha-wt/a"
  wm_wt "$HOME/projects/alpha" b "$HOME/projects/alpha-wt/b"
  migrate --json --only "$HOME/projects/alpha-wt/b"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(rows | jq -r '.path')" = "$HOME/projects/alpha-wt/b" ]
}

@test "migrate rejects an unknown flag with usage" {
  migrate --frobulate
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: trellis worktree migrate"* ]]
}

@test "inventory and owner records survive a tab and a newline in a worktree path" {
  wm_repo "$HOME/projects/alpha"
  wm_register "$HOME/projects/alpha" alpha
  odd="$HOME/projects/alpha-wt/tab	and
newline"
  wm_wt "$HOME/projects/alpha" odd "$odd"
  wm_owner "$odd" 1.2.3
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(rows | jq -s 'length')" -eq 1 ]
  rows | jq -e --arg p "$odd" '.path == $p and .owner_count == 1 and .release == "1.2.3" and .branch == "odd"'
}

@test "ignored entries beginning with a dash are inventoried with a ./ find prefix" {
  wm_repo "$HOME/projects/alpha"
  printf '\n-secrets/\n' >> "$HOME/projects/alpha/.gitignore"
  git -C "$HOME/projects/alpha" add .gitignore
  git -C "$HOME/projects/alpha" commit -q -m 'chore: ignore local secrets fixture'
  wm_register "$HOME/projects/alpha" alpha
  wt="$HOME/projects/alpha-wt/dash"
  wm_wt "$HOME/projects/alpha" dash "$wt"
  mkdir -p "$wt/-secrets"
  printf 'local only\n' > "$wt/-secrets/id"
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  row "$wt" | jq -e '.class == "preserve" and (.ignored_kept | index("-secrets/id"))'
}
