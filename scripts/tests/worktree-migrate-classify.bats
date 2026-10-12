#!/usr/bin/env bats
# Spec 069 A3: the `trellis worktree migrate` classifier, one fixture per rule.
#
# Hermetic: HOME, TRELLIS_HOME, the worktree root, the policy file, `gh`,
# `lsof` and the origin remotes are sandboxed under BATS_TEST_TMPDIR; the
# operator's registry, worktrees and GitHub account are never read.

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
# A.4 classifier: one fixture per rule
# ---------------------------------------------------------------------------

@test "prune: registered but missing and unlocked; a locked or owned one holds" {
  alpha
  wm_repo "$HOME/projects/beta"
  wm_register "$HOME/projects/beta" beta
  wm_wt "$HOME/projects/alpha" gone "$HOME/projects/alpha-wt/gone"
  wm_wt "$HOME/projects/beta" locked "$HOME/projects/beta-wt/locked"
  wm_wt "$HOME/projects/beta" owned "$HOME/projects/beta-wt/owned"
  git -C "$HOME/projects/beta" worktree lock "$HOME/projects/beta-wt/locked"
  wm_owner "$HOME/projects/beta-wt/owned" 1.2.3
  rm -rf "$HOME/projects/alpha-wt/gone" "$HOME/projects/beta-wt/locked" "$HOME/projects/beta-wt/owned"
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  row "$HOME/projects/alpha-wt/gone" | jq -e '.class == "prune"'
  row "$HOME/projects/beta-wt/locked" | jq -e '.class == "hold" and (.reasons | index("locked"))'
  row "$HOME/projects/beta-wt/owned" | jq -e '.class == "hold" and (.reasons[0] | test("owner record names the missing path"))'
}

@test "prune is per repository: one held missing entry holds its siblings" {
  alpha
  wm_wt "$HOME/projects/alpha" a "$HOME/projects/alpha-wt/a"
  wm_wt "$HOME/projects/alpha" b "$HOME/projects/alpha-wt/b"
  wm_owner "$HOME/projects/alpha-wt/b" 1.2.3
  rm -rf "$HOME/projects/alpha-wt/a" "$HOME/projects/alpha-wt/b"
  migrate --json
  row "$HOME/projects/alpha-wt/a" | jq -e '.class == "hold" and (.reasons | any(test("per repository")))'
}

@test "move: a clean worktree outside the sanctioned roots targets the convention path" {
  alpha
  wm_wt "$HOME/projects/alpha" feat/x "$HOME/projects/alpha-wt/x"
  migrate --json
  row "$HOME/projects/alpha-wt/x" | jq -e --arg t "$WT_ROOT/alpha/feat-x" \
    '.class == "move" and .target == $t and (.reasons | index("outside the sanctioned roots"))'
}

@test "keep: a worktree already under the central root stays" {
  alpha
  wm_wt "$HOME/projects/alpha" feat/x "$WT_ROOT/alpha/feat-x"
  migrate --json
  row "$WT_ROOT/alpha/feat-x" | jq -e '.class == "keep"'
}

@test "move: the legacy pi roots are drained, not kept" {
  alpha
  wm_wt "$HOME/projects/alpha" pi-agent-1 "$HOME/.pi-worktrees/pi-agent-1"
  wm_wt "$HOME/projects/alpha" pi-agent-2 "$TRELLIS_HOME/pi-worktrees/pi-agent-2"
  migrate --json
  row "$HOME/.pi-worktrees/pi-agent-1" | jq -e '.class == "move"'
  row "$TRELLIS_HOME/pi-worktrees/pi-agent-2" | jq -e '.class == "move"'
}

# A merged, pushed, idle, clean worktree with only regenerable ignored content.
merged_fixture() {
  alpha
  wm_wt "$HOME/projects/alpha" done "$HOME/projects/alpha-wt/done"
  git -C "$HOME/projects/alpha-wt/done" commit -q --allow-empty -m work
  git -C "$HOME/projects/alpha-wt/done" push -q -u origin done
  mkdir -p "$HOME/projects/alpha-wt/done/node_modules/pkg"
  printf 'x\n' > "$HOME/projects/alpha-wt/done/node_modules/pkg/index.js"
  wm_merged done "$(git -C "$HOME/projects/alpha-wt/done" rev-parse HEAD)"
  wm_age "$HOME/projects/alpha-wt/done" 2
}

@test "remove: merged PR (gh via the caller PATH), head on origin, idle, regenerable-only" {
  merged_fixture
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "remove" and .merged == "merged" and .regenerable == ["node_modules"]'
}

@test "gh absent from the control PATH and no caller PATH: merge unverified, never remove" {
  merged_fixture
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "move" and .merged == "unverified"
    and (.reasons | index("merge unverified (gh unavailable)"))'
}

@test "remove needs a day of git idleness" {
  merged_fixture
  wm_age "$HOME/projects/alpha-wt/done" 0
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "move" and (.reasons | index("merged but active within a day"))'
}

@test "remove needs the merged head: an unpushed commit after the merge moves instead" {
  merged_fixture
  git -C "$HOME/projects/alpha-wt/done" commit -q --allow-empty -m after-merge
  wm_age "$HOME/projects/alpha-wt/done" 2
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "move" and (.reasons | index("merged, but the local head is neither the merged PR head nor on the default branch"))'
}

@test "remove accepts a squash merge whose remote branch is gone when the PR head is the local head" {
  merged_fixture
  git -C "$HOME/projects/alpha" push -q origin --delete done
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "remove"'
}

@test "a gone remote branch without a merged PR is never remove" {
  merged_fixture
  : > "$WM_GH_MERGED"
  git -C "$HOME/projects/alpha" push -q origin --delete done
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "move" and .merged == "unmerged"'
}

@test "preserve: uncommitted, untracked and non-regenerable ignored work, kept on its branch" {
  alpha
  wt="$HOME/projects/alpha-wt/wip"
  wm_wt "$HOME/projects/alpha" feat/wip "$wt"
  printf 'changed\n' >> "$wt/seed.txt"
  printf 'new\n' > "$wt/new.py"
  printf 'SECRET=1\n' > "$wt/.env.local"
  printf 'db\n' > "$wt/app.db"
  mkdir -p "$wt/.venv/bin"
  migrate --json
  row "$wt" | jq -e '.class == "preserve" and .modified == 1 and .untracked == 1
    and (.ignored_kept | sort) == [".env.local", "app.db"] and .regenerable == [".venv"]
    and .preserve_branch == "feat/wip" and .push == false
    and .dehydrate == [".venv"] and (.after | index("uv sync (in .)"))'
}

@test "preserve on a detached head or the default branch uses preserve/<dir>" {
  alpha
  git -C "$HOME/projects/alpha" worktree add -q --detach "$HOME/projects/alpha-wt/det" main
  printf 'x\n' > "$HOME/projects/alpha-wt/det/untracked.txt"
  git -C "$HOME/projects/alpha" checkout -q -b side
  git -C "$HOME/projects/alpha" worktree add -q "$HOME/projects/alpha-wt/onmain" main
  printf 'x\n' > "$HOME/projects/alpha-wt/onmain/untracked.txt"
  migrate --json
  row "$HOME/projects/alpha-wt/det" | jq -e '.class == "preserve" and .preserve_branch == "preserve/det"'
  row "$HOME/projects/alpha-wt/onmain" | jq -e '.class == "preserve" and .preserve_branch == "preserve/onmain"'
}

@test "preserve pushes only to an origin owner listed in worktrees.push_owners" {
  alpha
  wm_repo "$HOME/projects/partner-console" "$SANDBOX/remotes/PartnerOrg/partner-console.git"
  wm_wt "$HOME/projects/alpha" mine "$HOME/projects/alpha-wt/mine"
  wm_wt "$HOME/projects/partner-console" partner "$HOME/projects/cb-wt/partner"
  printf 'x\n' > "$HOME/projects/alpha-wt/mine/u.txt"
  printf 'x\n' > "$HOME/projects/cb-wt/partner/u.txt"
  wm_policy '{"worktrees":{"known_parents":["~/projects/cb-wt"],"push_owners":["zireael26"]}}'
  migrate --json
  row "$HOME/projects/alpha-wt/mine" | jq -e '.class == "preserve" and .push == true'
  row "$HOME/projects/cb-wt/partner" | jq -e '.class == "preserve" and .push == false
    and (.reasons | index("origin owner not in worktrees.push_owners: the preserve commit stays local"))'
}

@test "hold: locked, live handle, foreign roots, ambiguous owner, bad index, taken target" {
  alpha
  wm_wt "$HOME/projects/alpha" locked "$HOME/projects/alpha-wt/locked"
  git -C "$HOME/projects/alpha" worktree lock "$HOME/projects/alpha-wt/locked"
  wm_wt "$HOME/projects/alpha" live "$HOME/projects/alpha-wt/live"
  wm_lsof_hold "$HOME/projects/alpha-wt/live/src"
  wm_wt "$HOME/projects/alpha" cur "$HOME/.cursor/worktrees/alpha/cur"
  wm_wt "$HOME/projects/alpha" cdx "$HOME/.codex/worktrees/abcd/alpha"
  wm_wt "$HOME/projects/alpha" twice "$HOME/projects/alpha-wt/twice"
  wm_owner "$HOME/projects/alpha-wt/twice" 1.2.3
  cp "$TRELLIS_HOME"/state/attachments/fixture-checkout/*.json "$TRELLIS_HOME/state/attachments/fixture-checkout/dup.json"
  wm_wt "$HOME/projects/alpha" broken "$HOME/projects/alpha-wt/broken"
  printf 'garbage' > "$(git -C "$HOME/projects/alpha-wt/broken" rev-parse --absolute-git-dir)/index"
  wm_wt "$HOME/projects/alpha" taken "$HOME/projects/alpha-wt/taken"
  mkdir -p "$WT_ROOT/alpha/taken"
  migrate --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  row "$HOME/projects/alpha-wt/locked" | jq -e '.class == "hold" and (.reasons | index("locked"))'
  row "$HOME/projects/alpha-wt/live" | jq -e '.class == "hold" and (.reasons | any(test("live process")))'
  row "$HOME/.cursor/worktrees/alpha/cur" | jq -e '.class == "hold" and (.reasons | any(test("Cursor")))'
  row "$HOME/.codex/worktrees/abcd/alpha" | jq -e '.class == "hold" and (.reasons | any(test("Codex")))'
  row "$HOME/projects/alpha-wt/twice" | jq -e '.class == "hold" and (.reasons | any(test("ambiguous owner record")))'
  row "$HOME/projects/alpha-wt/broken" | jq -e '.class == "hold" and (.reasons | any(test("command error")))'
  row "$HOME/projects/alpha-wt/taken" | jq -e '.class == "hold" and (.reasons | any(test("is taken by another branch")))'
}

@test "hold: an lsof failure holds every live entry (fail closed)" {
  alpha
  wm_wt "$HOME/projects/alpha" x "$HOME/projects/alpha-wt/x"
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/lsof"
  migrate --json
  row "$HOME/projects/alpha-wt/x" | jq -e '.class == "hold" and (.reasons | any(test("lsof")))'
}

@test "hold: a stale detach journal for an attached worktree, and an unreadable registry" {
  alpha
  wm_wt "$HOME/projects/alpha" att "$HOME/projects/alpha-wt/att"
  wm_owner "$HOME/projects/alpha-wt/att" 1.2.3
  mkdir -p "$TRELLIS_HOME/state/attachment-journals"
  printf '{}\n' > "$TRELLIS_HOME/state/attachment-journals/detach-stale.json"
  migrate --json
  row "$HOME/projects/alpha-wt/att" | jq -e '.class == "hold" and (.reasons | any(test("stale detach journal")))'
  printf 'not json' > "$TRELLIS_HOME/registry.json"
  wm_repo "$HOME/projects/gamma"
  wm_wt "$HOME/projects/gamma" g "$HOME/projects/gamma-wt/g"
  wm_policy '{"worktrees":{"known_parents":["~/projects/gamma-wt"]}}'
  migrate --json
  row "$HOME/projects/gamma-wt/g" | jq -e '.class == "hold" and (.reasons | index("local registry is unreadable"))'
}

@test "an orphan directory is held with a repair hint" {
  mkdir -p "$HOME/projects/parent/ghost"
  printf 'gitdir: %s\n' "$SANDBOX/gone/.git/worktrees/ghost" > "$HOME/projects/parent/ghost/.git"
  wm_policy '{"worktrees":{"known_parents":["~/projects/parent"]}}'
  migrate --json
  row "$HOME/projects/parent/ghost" | jq -e '.class == "hold" and (.reasons[0] | test("git worktree repair"))'
}

@test "Trellis-rendered artifacts named by the owner record are not work to preserve" {
  alpha
  wt="$HOME/projects/alpha-wt/att"
  wm_wt "$HOME/projects/alpha" att "$wt"
  mkdir -p "$wt/.claude"
  printf '{}\n' > "$wt/.claude/settings.local.json"
  printf '.claude/settings.local.json\n' >> "$HOME/projects/alpha/.git/info/exclude"
  wm_owner "$wt" 1.2.3 '[{"kind":"file","path":".claude/settings.local.json"}]'
  migrate --json
  row "$wt" | jq -e '.class == "move" and .ignored_kept == []'
  # The same file without the owner record is the operator's: preserve it.
  rm -rf "$TRELLIS_HOME/state/attachments"
  migrate --json
  row "$wt" | jq -e '.class == "preserve" and .ignored_kept == [".claude/settings.local.json"]'
}

@test "a locked missing entry does not block pruning its siblings" {
  alpha
  wm_wt "$HOME/projects/alpha" a "$HOME/projects/alpha-wt/a"
  wm_wt "$HOME/projects/alpha" l "$HOME/projects/alpha-wt/l"
  git -C "$HOME/projects/alpha" worktree lock "$HOME/projects/alpha-wt/l"
  rm -rf "$HOME/projects/alpha-wt/a" "$HOME/projects/alpha-wt/l"
  migrate --json
  row "$HOME/projects/alpha-wt/a" | jq -e '.class == "prune"'
  row "$HOME/projects/alpha-wt/l" | jq -e '.class == "hold" and (.reasons | index("locked"))'
}

@test "nothing below a regenerable directory is treated as kept work" {
  alpha
  wt="$HOME/projects/alpha-wt/nm"
  wm_wt "$HOME/projects/alpha" nm "$wt"
  mkdir -p "$wt/node_modules/pkg/data"
  printf 'x\n' > "$wt/node_modules/pkg/data/blob.db"
  migrate --json
  row "$wt" | jq -e '.class == "move" and .ignored_kept == [] and .regenerable == ["node_modules"]'
}

@test "P1-b: an initialised submodule or an embedded repository holds the worktree" {
  alpha
  wm_repo "$SANDBOX/sublib" "$SANDBOX/remotes/Zireael26/sublib.git"
  git -C "$HOME/projects/alpha" -c protocol.file.allow=always submodule add -q "$SANDBOX/remotes/Zireael26/sublib.git" sublib
  git -C "$HOME/projects/alpha" commit -q -m "add submodule"
  wm_wt "$HOME/projects/alpha" sm "$HOME/projects/alpha-wt/sm"
  git -C "$HOME/projects/alpha-wt/sm" -c protocol.file.allow=always submodule update -q --init
  wm_wt "$HOME/projects/alpha" emb "$HOME/projects/alpha-wt/emb"
  git init -q "$HOME/projects/alpha-wt/emb/vendor/lib"
  migrate --json
  row "$HOME/projects/alpha-wt/sm" | jq -e '.class == "hold" and (.reasons | any(test("nested git repository or submodule at sublib")))'
  row "$HOME/projects/alpha-wt/emb" | jq -e '.class == "hold" and (.reasons | any(test("nested git repository or submodule at vendor/lib")))'
}

@test "P2: post-merge commits pushed to the branch are not covered by the merged PR: move" {
  merged_fixture
  git -C "$HOME/projects/alpha-wt/done" commit -q --allow-empty -m after-merge
  git -C "$HOME/projects/alpha-wt/done" push -q origin done
  wm_age "$HOME/projects/alpha-wt/done" 2
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "move" and (.reasons | index("merged, but the local head is neither the merged PR head nor on the default branch"))'
}

@test "P2: a head already contained in origin's default branch is removable" {
  merged_fixture
  # The PR head recorded by gh is some other commit; the work itself landed on main.
  : > "$WM_GH_MERGED"
  wm_merged done 0000000000000000000000000000000000000000
  git -C "$HOME/projects/alpha" push -q origin "$(git -C "$HOME/projects/alpha-wt/done" rev-parse HEAD):refs/heads/main"
  git -C "$HOME/projects/alpha" fetch -q origin
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json
  row "$HOME/projects/alpha-wt/done" | jq -e '.class == "remove"'
}

@test "P2: an owner record naming a missing path holds every sibling in the checkout" {
  alpha
  wm_wt "$HOME/projects/alpha" gone "$HOME/projects/alpha-wt/gone"
  wm_wt "$HOME/projects/alpha" live "$HOME/projects/alpha-wt/live"
  wm_owner "$HOME/projects/alpha-wt/gone" 1.2.3
  mv "$HOME/projects/alpha-wt/gone" "$SANDBOX/deleted-elsewhere"
  wm_repo "$HOME/projects/beta"
  wm_register "$HOME/projects/beta" beta
  wm_wt "$HOME/projects/beta" other "$HOME/projects/beta-wt/other"
  migrate --json
  row "$HOME/projects/alpha-wt/live" | jq -e '.class == "hold"
    and (.reasons | any(test("attach refuses this checkout until the owner record for .*/alpha-wt/gone is archived")))'
  row "$HOME/projects/beta-wt/other" | jq -e '.class == "move"'
}

@test "P2: two worktrees bound for one convention path both hold" {
  alpha
  wm_wt "$HOME/projects/alpha" a/b "$HOME/projects/alpha-wt/ab-slash"
  wm_wt "$HOME/projects/alpha" a-b "$HOME/projects/alpha-wt/ab-dash"
  migrate --json
  for p in ab-slash ab-dash; do
    row "$HOME/projects/alpha-wt/$p" | jq -e --arg t "$WT_ROOT/alpha/a-b" '.class == "hold"
      and (.reasons | index("convention path " + $t + " is also the target of another worktree"))'
  done
}
