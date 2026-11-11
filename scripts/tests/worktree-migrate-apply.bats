#!/usr/bin/env bats
# Spec 069 A4, A5, B4: `trellis worktree migrate --apply` and `--revert`.
#
# Hermetic: HOME, TRELLIS_HOME, the worktree root, the policy file, `gh`,
# `lsof` and the origin remotes are sandboxed under BATS_TEST_TMPDIR.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/worktree.sh"
LIB="$REPO_ROOT/scripts/lib/worktree-migrate.sh"
APPLY_LIB="$REPO_ROOT/scripts/lib/worktree-migrate-apply.sh"
load helpers/worktree-migrate

wait_for_checkout_postjob() {
  local owner="$1" checkout_id worktree_id status lock attempt=0
  checkout_id="$(jq -r '.checkout_id' "$owner")"
  worktree_id="$(jq -r '.worktree_id' "$owner")"
  status="$TRELLIS_HOME/state/attachment-status/$checkout_id/$worktree_id.json"
  lock="$TRELLIS_HOME/state/locks/attachment-checkout-$checkout_id.lock"
  while [ "$attempt" -lt 600 ]; do
    if [ -f "$status" ] && [ "$(jq -r '.state' "$status")" = ok ] &&
       [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  printf 'attachment postjob did not finish: %s\n' "$status" >&2
  return 1
}

setup() {
  wm_fixture_setup
}

teardown() {
  wm_fixture_teardown
}

# ---------------------------------------------------------------------------
# A.5 engine
# ---------------------------------------------------------------------------

@test "journal IDs and owner fixtures hash correctly without shasum on PATH" {
  command -v sha256sum >/dev/null 2>&1 || skip "requires sha256sum"
  local bin="$SANDBOX/no-shasum"
  mkdir -p "$bin"
  for tool in sha256sum cut mkdir jq date; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  run env PATH="$bin" /bin/bash -c '
    set -euo pipefail
    . "$1"
    . "$2"
    ! command -v shasum >/dev/null 2>&1
    [ "$(wm_id "")" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]
    [ "$(wm_id abc)" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]
    wm_journal "$3/journal" move abc xyz done
    wm_journal "$3/journal" move def uvw failed "fixture failure"
    jq -se "map(.id) | unique | length == 2" "$3/journal"
    [ "$(wm_report_entry "$3/journal" abc)" = "done   move abc -> xyz" ]
    wm_owner abc 1.2.3
    jq -e '\''.worktree_root == "abc"'\'' "$TRELLIS_HOME/state/attachments/fixture-checkout/ba7816bf8f01cfea.json"
  ' _ "$APPLY_LIB" "$BATS_TEST_DIRNAME/helpers/worktree-migrate.bash" "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "journal append failure stops the current step and all later entries" {
  alpha
  local repo="$HOME/projects/alpha" common first second target1 target2
  first="$HOME/projects/alpha-wt/journal-first"
  second="$HOME/projects/alpha-wt/journal-second"
  target1="$SANDBOX/target-first"
  target2="$SANDBOX/target-second"
  wm_wt "$repo" journal-first "$first"
  wm_wt "$repo" journal-second "$second"
  common="$(git -C "$repo" rev-parse --absolute-git-dir)"
  mkdir "$SANDBOX/work"
  jq -nc --arg p "$first" --arg t "$target1" --arg c "$common" \
    '{path:$p,target:$t,common:$c,class:"move",moved_to:null,release:null,after:[],dehydrate:[]}' > "$SANDBOX/rows"
  jq -nc --arg p "$second" --arg t "$target2" --arg c "$common" \
    '{path:$p,target:$t,common:$c,class:"move",moved_to:null,release:null,after:[],dehydrate:[]}' >> "$SANDBOX/rows"
  run bash -c '
    . "$1"
    WM_TEST_SANDBOX="$2"
    wm_git() { printf "%s\n" "$*" >> "$WM_TEST_SANDBOX/git-calls"; command git "$@"; }
    wm_canonical_move_target() { printf "%s\n" "$1"; }
    wm_apply_entry() { wm_move_steps "$1" "$2" move "$3" start; }
    wm_deregister() { printf "unexpected deregister\n" >> "$WM_TEST_SANDBOX/deregister-called"; }
    wm_apply "$2/work" "$2/rows" "$2/no-such-directory/journal"
  ' _ "$LIB" "$SANDBOX"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  # The existing journal schema records completion, not write-ahead intent;
  # the first move may already have happened, but repair and entry two must not.
  [ -d "$first" ] || [ -d "$target1" ]
  [ -d "$second" ] && [ ! -e "$target2" ]
  [ ! -e "$SANDBOX/deregister-called" ]
  ! grep -q 'worktree repair' "$SANDBOX/git-calls"
  [ ! -e "$SANDBOX/no-such-directory/journal" ]
}

@test "preserve stops before moving if its journal append fails" {
  mkdir "$SANDBOX/work"
  run bash -c '
    . "$1"; . "$2"
    WM_TEST_SANDBOX="$3"
    wm_revalidate() { printf "%s\n" '\''{"path":"/fixture","branch":"work","head":"abc","preserve_branch":"work","push":false,"modified":0,"untracked":0,"ignored_kept":[]}'\''; }
    wm_move_steps() { printf moved > "$WM_TEST_SANDBOX/preserve-moved"; }
    wm_apply_preserve "$3/work" "$3/no-such-directory/journal" '\''{"path":"/fixture"}'\''
  ' _ "$APPLY_LIB" "$REPO_ROOT/scripts/lib/worktree-migrate-preserve.sh" "$SANDBOX"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/preserve-moved" ]
}

@test "apply without --yes on a non-terminal stdin changes nothing" {
  alpha
  wm_wt "$HOME/projects/alpha" gone "$HOME/projects/alpha-wt/gone"
  rm -rf "$HOME/projects/alpha-wt/gone"
  run bash -c 'bash "$1" migrate --apply < /dev/null' _ "$SCRIPT"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--yes"* ]]
  git -C "$HOME/projects/alpha" worktree list --porcelain | grep -q '^prunable'
  [ ! -d "$TRELLIS_HOME/state/worktree-migrate" ] || [ -z "$(ls "$TRELLIS_HOME/state/worktree-migrate")" ]
}

@test "apply prunes a missing entry first and journals it privately" {
  alpha
  wm_wt "$HOME/projects/alpha" gone "$HOME/projects/alpha-wt/gone"
  rm -rf "$HOME/projects/alpha-wt/gone"
  migrate --apply --yes --prune-recent
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! git -C "$HOME/projects/alpha" worktree list --porcelain | grep -q 'alpha-wt/gone'
  local mode
  mode="$(stat -f %Lp "$TRELLIS_HOME/state/worktree-migrate" 2>/dev/null)" || mode="$(stat -c %a "$TRELLIS_HOME/state/worktree-migrate")"
  [ "$mode" = 700 ]
  mode="$(stat -f %Lp "$(journal)" 2>/dev/null)" || mode="$(stat -c %a "$(journal)")"
  [ "$mode" = 600 ]
  jq -se --arg p "$HOME/projects/alpha-wt/gone" 'map(select(.old == $p)) | last | .action == "prune" and .step == "done"' "$(journal)"
  [[ "$output" == *"done   prune $HOME/projects/alpha-wt/gone"* ]] || { echo "$output"; return 1; }
}

@test "prune revalidation: a prunable set that grew since the plan prunes nothing" {
  alpha
  wm_wt "$HOME/projects/alpha" a "$HOME/projects/alpha-wt/a"
  wm_wt "$HOME/projects/alpha" b "$HOME/projects/alpha-wt/b"
  rm -rf "$HOME/projects/alpha-wt/a"
  common="$(cd "$HOME/projects/alpha/.git" && pwd -P)"
  # The plan saw only `a`; `b` went missing after planning.
  printf '%s\n' "$(jq -nc --arg c "$common" --arg p "$HOME/projects/alpha-wt/a" '{class:"prune", common:$c, path:$p}')" > "$SANDBOX/rows"
  rm -rf "$HOME/projects/alpha-wt/b"
  mkdir -p "$SANDBOX/work"
  : > "$SANDBOX/work/links.jsonl"
  run bash -c '. "$1/scripts/lib/hygiene-common.sh"; . "$1/scripts/lib/disk-janitor-lib.sh"; . "$2"
    WM_LOG="$3/work/log"; WM_PRUNE_RECENT=1; wm_apply_prune "$3/work" "$3/journal" "$3/rows" "$4"' _ "$REPO_ROOT" "$LIB" "$SANDBOX" "$common"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(git -C "$HOME/projects/alpha" worktree list --porcelain | grep -c '^prunable')" -eq 2 ]
  jq -e '.step == "failed" and (.error | test("changed since the plan"))' "$SANDBOX/journal"
}

@test "prune refuses an unlisted live admin that Git would also remove" {
  alpha
  local repo="$HOME/projects/alpha" missing="$HOME/projects/alpha-wt/missing"
  local live="$HOME/projects/alpha-wt/live" missing_admin live_admin
  wm_wt "$repo" missing "$missing"
  wm_wt "$repo" live "$live"
  missing_admin="$(git -C "$missing" rev-parse --absolute-git-dir)"
  live_admin="$(git -C "$live" rev-parse --absolute-git-dir)"
  printf 'staged operator data\n' > "$live/staged.txt"
  git -C "$live" add staged.txt
  rm -rf "${missing:?}"
  python3 -I -c 'import os,sys,time;t=time.time()-120*86400;[os.utime(p,(t,t)) for p in sys.argv[1:]]' \
    "$missing_admin" "$missing_admin/gitdir" "$missing_admin/index"
  rm -f "${live_admin:?}/gitdir"
  migrate --apply --yes --only "$missing"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'unplanned worktree admin'* ]] || { echo "$output"; false; }
  [ -d "$missing_admin" ] && [ -d "$live_admin" ] && [ -f "$live/staged.txt" ]

  # Once the live admin's backlink is repaired, the expired missing worktree
  # is the only Git dry-run removal and remains safe to prune.
  printf '%s/.git\n' "$live" > "$live_admin/gitdir"
  migrate --apply --yes --only "$missing"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$missing_admin" ] && [ -d "$live_admin" ]
  [ "$(git -C "$live" diff --cached --name-only)" = staged.txt ]
}

@test "prune revalidation refuses a corrupt owner record created after planning" {
  alpha
  local wt="$HOME/projects/alpha-wt/gone" common admin
  wm_wt "$HOME/projects/alpha" gone "$wt"
  admin="$(git -C "$wt" rev-parse --absolute-git-dir)"
  common="$(cd "$HOME/projects/alpha/.git" && pwd -P)"
  rm -rf "${wt:?}"
  jq -nc --arg c "$common" --arg p "$wt" '{class:"prune", common:$c, path:$p}' > "$SANDBOX/rows"
  mkdir -p "$TRELLIS_HOME/state/attachments/fixture-checkout" "$SANDBOX/work"
  printf '{"worktree_root":' > "$TRELLIS_HOME/state/attachments/fixture-checkout/corrupt.json"
  run bash -c '. "$1/scripts/lib/hygiene-common.sh"; . "$1/scripts/lib/disk-janitor-lib.sh"; . "$2"
    WM_LOG="$3/work/log"; WM_PRUNE_RECENT=1; wm_apply_prune "$3/work" "$3/journal" "$3/rows" "$4"' _ "$REPO_ROOT" "$LIB" "$SANDBOX" "$common"
  [ "$status" -ne 0 ] && [ -d "$admin" ] || { echo "$output"; false; }
}

@test "prune revalidation refuses a missing or corrupt backlink inventory" {
  alpha
  local wt="$HOME/projects/alpha-wt/gone" common admin
  wm_wt "$HOME/projects/alpha" gone "$wt"
  admin="$(git -C "$wt" rev-parse --absolute-git-dir)"
  common="$(cd "$HOME/projects/alpha/.git" && pwd -P)"
  rm -rf "${wt:?}"
  jq -nc --arg c "$common" --arg p "$wt" '{class:"prune", common:$c, path:$p}' > "$SANDBOX/rows"
  mkdir -p "$SANDBOX/work"
  for state in missing corrupt; do
    if [ "$state" = corrupt ]; then printf '{' > "$SANDBOX/work/links.jsonl"; fi
    run bash -c '. "$1/scripts/lib/hygiene-common.sh"; . "$1/scripts/lib/disk-janitor-lib.sh"; . "$2"
      WM_LOG="$3/work/log"; WM_PRUNE_RECENT=1; wm_apply_prune "$3/work" "$3/journal" "$3/rows" "$4"' _ "$REPO_ROOT" "$LIB" "$SANDBOX" "$common"
    [ "$status" -ne 0 ] && [ -d "$admin" ] || { echo "$output"; false; }
  done
}

@test "a live lock refuses a second apply; a dead holder's lock is taken over" {
  alpha
  mkdir -p "$TRELLIS_HOME/state/worktree-migrate/.lock"
  printf '%s\n' "$$" > "$TRELLIS_HOME/state/worktree-migrate/.lock/pid"
  migrate --apply --yes
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  bash -c 'exit 0' & dead=$!
  wait "$dead"
  printf '%s\n' "$dead" > "$TRELLIS_HOME/state/worktree-migrate/.lock/pid"
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$TRELLIS_HOME/state/worktree-migrate/.lock" ]
}

@test "attach and detach are never wrapped in a timeout, and detach is per worktree" {
  ! grep -nE '(timeout|alarm)[^#]*attach-project' "$REPO_ROOT"/scripts/lib/worktree-migrate*.sh
  ! grep -n -- '--all-worktrees' "$REPO_ROOT"/scripts/lib/worktree-migrate*.sh
  grep -q 'attach-project.sh" detach --home "$home" "$path"' "$APPLY_LIB"
}

# ---------------------------------------------------------------------------
# A.6 move (and B4: .venv is dehydrated, never carried or copied)
# ---------------------------------------------------------------------------

@test "move: lands at the convention path, carries node_modules, dehydrates .venv" {
  alpha
  wt="$HOME/projects/alpha-wt/x"
  wm_wt "$HOME/projects/alpha" feat/x "$wt"
  mkdir -p "$wt/.venv/bin" "$wt/node_modules/pkg"
  printf '#!%s/.venv/bin/python\n' "$wt" > "$wt/.venv/bin/tool"
  printf 'x\n' > "$wt/node_modules/pkg/index.js"
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  target="$WT_ROOT/alpha/feat-x"
  [ ! -e "$wt" ]
  [ "$(git -C "$target" symbolic-ref --short HEAD)" = feat/x ]
  git -C "$HOME/projects/alpha" worktree list --porcelain | grep -qx "worktree $target"
  [ -f "$target/node_modules/pkg/index.js" ]
  [ ! -e "$target/.venv" ]
  j="$(journal)"
  jq -se --arg p "$wt" '[.[] | select(.old == $p) | .step] == ["dehydrated", "moved", "repaired", "done"]' "$j"
  jq -se --arg p "$wt" 'map(select(.old == $p and .step == "dehydrated")) | .[0].dehydrated == [".venv"]' "$j"
  jq -se --arg p "$wt" 'map(select(.old == $p and .step == "done")) | .[0].after | index("uv sync (in .)")' "$j"
  # B4: no journal row names a copied .venv; nothing named .venv reached the target.
  ! grep -qi 'cop' "$j"
  [ -z "$(find "$target" -name .venv -print)" ]
}

@test "move: a failing entry is put back and held, the rest still move, exit 4" {
  alpha
  for n in 1 2 3; do wm_wt "$HOME/projects/alpha" "b$n" "$HOME/projects/alpha-wt/b$n"; done
  git_fail_move "$HOME/projects/alpha-wt/b2"
  migrate --apply --yes
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [ -d "$WT_ROOT/alpha/b1" ] && [ -d "$WT_ROOT/alpha/b3" ]
  [ -d "$HOME/projects/alpha-wt/b2" ] && [ ! -e "$WT_ROOT/alpha/b2" ]
  [ "$(git -C "$HOME/projects/alpha-wt/b2" symbolic-ref --short HEAD)" = b2 ]
  [[ "$output" == *"HELD   move $HOME/projects/alpha-wt/b2"*"injected move failure"* ]] || { echo "$output"; return 1; }
}

@test "move: a run killed after the move resumes from its journal" {
  alpha
  wm_wt "$HOME/projects/alpha" feat/r "$HOME/projects/alpha-wt/r"
  WM_FAULT_STEP=moved run bash "$SCRIPT" migrate --apply --yes
  [ "$status" -eq 99 ] || { echo "$output"; return 1; }
  j="$(journal)"
  [ "$(jq -sr 'last | .step' "$j")" = moved ]
  migrate --apply --yes --resume "$j"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  jq -se --arg p "$HOME/projects/alpha-wt/r" '[.[] | select(.old == $p) | .step] == ["moved", "repaired", "done"]' "$j"
  git -C "$WT_ROOT/alpha/feat-r" status --porcelain >/dev/null
}

@test "move: an attached worktree is detached, moved and re-attached at its release" {
  load helpers/t14-worktree
  local trellis_home="$TRELLIS_HOME"
  t14_setup_sandbox
  wm_machine_config
  t14_make_runtime_release
  t14_make_project "$HOME/projects/fixture"
  export TRELLIS_ATTACH_POSTJOB=off
  t14_attach
  git -C "$T14_PROJECT" worktree add -q -b feat/att "$HOME/projects/fixture-wt/att"
  old_owner="$(t14_owner_for_root "$HOME/projects/fixture-wt/att")"
  [ -f "$old_owner" ]
  wait_for_checkout_postjob "$old_owner"
  migrate --json
  row "$HOME/projects/fixture-wt/att" | jq -e '.class == "move" and .release == "1.2.3" and .group_release == "1.2.3"'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; t14_teardown_sandbox; return 1; }
  target="$WT_ROOT/fixture-project/feat-att"
  [ ! -e "$HOME/projects/fixture-wt/att" ]
  owner="$(t14_owner_for_root "$target")"
  jq -e '.status == "committed" and .release == "1.2.3"' "$owner"
  [ -L "$target/.trellis/runtime" ] && [ -e "$target/.trellis/runtime" ]
  ! t14_owner_for_root "$HOME/projects/fixture-wt/att"
  j="$(journal)"
  jq -se '[.[] | .step] == ["detached", "moved", "repaired", "attached", "deregistered", "done"]' "$j"
  # No registry row is left naming the emptied path (A6: zero registered-but-missing).
  ! jq -e --arg r "$HOME/projects/fixture-wt/att" 'any(.projects[].checkouts[].worktrees[]; .root == $r)' "$TRELLIS_HOME/registry.json"
  jq -e --arg r "$target" 'any(.projects[].checkouts[].worktrees[]; .root == $r)' "$TRELLIS_HOME/registry.json"
  jq -se 'map(select(.step == "detached")) | .[0].release == "1.2.3"' "$j"
  t14_teardown_sandbox
  TRELLIS_HOME="$trellis_home"
}

# ---------------------------------------------------------------------------
# A.7 remove, and A4: no dirty, untracked or non-regenerable ignored file is
# ever deleted
# ---------------------------------------------------------------------------

@test "remove: a merged, published, idle, regenerable-only worktree goes; its branch stays" {
  alpha
  merged_wt done
  mkdir -p "$HOME/projects/alpha-wt/done/node_modules/pkg"
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$HOME/projects/alpha-wt/done" ]
  ! git -C "$HOME/projects/alpha" worktree list --porcelain | grep -q 'alpha-wt/done'
  git -C "$HOME/projects/alpha" show-ref --verify --quiet refs/heads/done
  jq -se --arg p "$HOME/projects/alpha-wt/done" '[.[] | select(.old == $p) | .step] == ["removed", "done"]' "$(journal)"
}

@test "remove revalidates: a process that opened the tree after planning holds it" {
  alpha
  merged_wt done
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  # lsof sees nothing for the plan's snapshot and a cwd inside the tree for
  # apply's fresh one.
  cat > "$SANDBOX/bin/lsof" <<SH
#!/bin/sh
n=\$(cat "$SANDBOX/lsof.count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$SANDBOX/lsof.count"
printf 'p1\\nf0\\nn/dev/null\\n'
[ "\$n" -lt 2 ] || printf 'fcwd\\nn%s\\n' "$HOME/projects/alpha-wt/done"
SH
  chmod 755 "$SANDBOX/bin/lsof"
  migrate --apply --yes
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [ -d "$HOME/projects/alpha-wt/done" ]
  jq -se 'last | .step == "failed" and (.error | test("changed since the plan: was remove, now hold"))' "$(journal)"
}

# a4_files WT — sha256 of the A4 trio, wherever the worktree ended up.
a4_sums() {
  local base
  for base in "$@"; do
    if [ -f "$base/.env.local" ]; then
      wm_fixture_sha256 "$base/.env.local" "$base/data/app.sqlite" "$base/src/new_module.py" | cut -d ' ' -f 1
      return 0
    fi
  done
  return 1
}

@test "A4 checksums remain nonempty and detect changes without shasum on PATH" {
  command -v sha256sum >/dev/null 2>&1 || skip "requires sha256sum"
  local bin="$SANDBOX/no-shasum" wt="$SANDBOX/a4" before after hash
  mkdir -p "$bin" "$wt/data" "$wt/src"
  for tool in sha256sum cut; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  printf abc > "$wt/.env.local"
  printf abc > "$wt/data/app.sqlite"
  printf abc > "$wt/src/new_module.py"
  hash=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  before="$(PATH="$bin" a4_sums "$wt")"
  [ "$before" = "$(printf '%s\n%s\n%s\n' "$hash" "$hash" "$hash")" ]
  printf changed > "$wt/data/app.sqlite"
  after="$(PATH="$bin" a4_sums "$wt")"
  [ -n "$after" ] && [ "$before" != "$after" ]
}

@test "A4: .env.local, a SQLite file and untracked source survive apply byte-identical" {
  alpha
  wt="$HOME/projects/alpha-wt/a4"
  merged_wt a4
  mkdir -p "$wt/data" "$wt/src"
  printf 'TOKEN=secret\n' > "$wt/.env.local"
  printf 'SQLite format 3\0fixture' > "$wt/data/app.sqlite"
  printf 'def f():\n    return 1\n' > "$wt/src/new_module.py"
  before="$(a4_sums "$wt")"
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --json --only "$wt"
  row "$wt" | jq -e '.class == "preserve" or .class == "move" or .class == "hold"'
  migrate --apply --yes
  after="$(a4_sums "$wt" "$WT_ROOT/alpha/a4")"
  [ "$before" = "$after" ]
}

@test "A4 mutation: inverting the non-regenerable check deletes the files, so the guard is load-bearing" {
  alpha
  wt="$HOME/projects/alpha-wt/a4"
  merged_wt a4
  mkdir -p "$wt/data"
  printf 'TOKEN=secret\n' > "$wt/.env.local"
  printf 'SQLite format 3\0fixture' > "$wt/data/app.sqlite"
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  mutant="$SANDBOX/mutant"
  mkdir -p "$mutant"
  cp -R "$REPO_ROOT/scripts" "$mutant/scripts"
  grep -q '\[ "\$kept_count" -eq 0 \]' "$mutant/scripts/lib/worktree-migrate-classify.sh"
  sed -i.bak 's/\[ "\$kept_count" -eq 0 \]/[ "$kept_count" -ge 0 ]/' "$mutant/scripts/lib/worktree-migrate-classify.sh"
  # The real classifier keeps the files ...
  migrate --json --only "$wt"
  row "$wt" | jq -e '.class != "remove"'
  # ... the mutant removes the tree and loses both.
  run bash "$mutant/scripts/worktree.sh" migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$wt/.env.local" ] && [ ! -e "$wt/data/app.sqlite" ]
}

# ---------------------------------------------------------------------------
# A.8 revert
# ---------------------------------------------------------------------------

layout() {
  git -C "$HOME/projects/alpha" worktree list --porcelain | awk '/^worktree /{p=$2} /^branch /{print p, $2}' | sort
}

@test "revert: failure mid-run, resume, then revert ends in the original layout" {
  alpha
  for n in 1 2 3; do wm_wt "$HOME/projects/alpha" "b$n" "$HOME/projects/alpha-wt/b$n"; done
  merged_wt extra
  before="$(layout)"
  git_fail_move "$HOME/projects/alpha-wt/b2"
  migrate --apply --yes
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  j="$(journal)"
  git_restore
  migrate --apply --yes --resume "$j"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$WT_ROOT/alpha/b2" ]
  [ "$(layout)" != "$before" ]
  migrate --revert "$j" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(layout)" = "$before" ]
  for n in 1 2 3; do [ ! -e "$WT_ROOT/alpha/b$n" ]; done
}

@test "revert lists removals as not revertible" {
  alpha
  merged_wt done
  wm_wt "$HOME/projects/alpha" mv1 "$HOME/projects/alpha-wt/mv1"
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/ghbin"
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  migrate --revert "$(journal)" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"not revertible: removed $HOME/projects/alpha-wt/done"* ]] || { echo "$output"; return 1; }
  [ -d "$HOME/projects/alpha-wt/mv1" ]
}

@test "resume finishes an entry killed after its attached journal state" {
  load helpers/t14-worktree
  local trellis_home="$TRELLIS_HOME"
  t14_setup_sandbox
  wm_machine_config
  t14_make_runtime_release
  t14_make_project "$HOME/projects/fixture"
  export TRELLIS_ATTACH_POSTJOB=off
  t14_attach
  git -C "$T14_PROJECT" worktree add -q -b feat/attached-resume "$HOME/projects/fixture-wt/attached-resume"
  owner="$(t14_owner_for_root "$HOME/projects/fixture-wt/attached-resume")"
  [ -f "$owner" ]
  wait_for_checkout_postjob "$owner"
  WM_FAULT_STEP=attached run bash "$SCRIPT" migrate --apply --yes
  [ "$status" -eq 99 ] || { echo "$output"; t14_teardown_sandbox; return 1; }
  j="$(journal)"
  [ "$(jq -sr 'last | .step' "$j")" = attached ]
  migrate --apply --yes --resume "$j"
  [ "$status" -eq 0 ] || { echo "$output"; t14_teardown_sandbox; return 1; }
  jq -se '[.[] | .step] == ["detached", "moved", "repaired", "attached", "deregistered", "done"]' "$j"
  [ -d "$WT_ROOT/fixture-project/feat-attached-resume" ]
  t14_teardown_sandbox
  TRELLIS_HOME="$trellis_home"
}

@test "revert retains the source journal reinstall hints for dehydrated content" {
  alpha
  wt="$HOME/projects/alpha-wt/venv"
  wm_wt "$HOME/projects/alpha" feat/venv "$wt"
  mkdir -p "$wt/.venv/bin"
  printf 'python\n' > "$wt/.venv/bin/python"
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  j="$(journal)"
  jq -se --arg p "$wt" 'map(select(.old == $p and .step == "done")) | .[0].after == ["uv sync (in .)"]' "$j"
  migrate --revert "$j" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  revert_journal="$(ls "$TRELLIS_HOME"/state/worktree-migrate/*-revert-*.jsonl | tail -n 1)"
  jq -se --arg p "$WT_ROOT/alpha/feat-venv" 'map(select(.old == $p and .step == "done")) | .[0].after == ["uv sync (in .)"]' "$revert_journal"
  [ -d "$wt" ] && [ ! -e "$wt/.venv" ]
}

@test "move refuses a target parent that canonicalizes outside the worktree root" {
  alpha
  wt="$HOME/projects/alpha-wt/escaped"
  wm_wt "$HOME/projects/alpha" topic "$wt"
  mkdir -p "$SANDBOX/escaped" "$WT_ROOT"
  ln -s "$SANDBOX/escaped" "$WT_ROOT/alpha"
  # Plan holds the escape: the convention path resolves outside the root.
  migrate --json
  row "$wt" | jq -e '.class == "hold" and (.reasons | index("outside the sanctioned roots"))'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$wt" ] && [ ! -e "$SANDBOX/escaped/topic" ]
  # The apply-time guard stays load-bearing: it refuses the escape directly.
  run bash -c '. "$1/scripts/lib/hygiene-common.sh"; . "$1/scripts/lib/worktree-migrate-apply.sh"; wm_canonical_move_target "$2"' _ "$REPO_ROOT" "$WT_ROOT/alpha/topic"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}
# ---------------------------------------------------------------------------
# Review fixes
# ---------------------------------------------------------------------------

@test "P1-a: a worktree moved by hand is re-linked, never pruned out from under its work" {
  alpha
  wm_wt "$HOME/projects/alpha" handmoved "$HOME/projects/alpha-wt/orig"
  printf 'wip\n' > "$HOME/projects/alpha-wt/orig/wip.txt"
  mv "$HOME/projects/alpha-wt/orig" "$HOME/projects/alpha-wt/moved"
  wm_policy '{"worktrees":{"known_parents":["~/projects/alpha-wt"]}}'
  migrate --json
  row "$HOME/projects/alpha-wt/orig" | jq -e --arg m "$HOME/projects/alpha-wt/moved" \
    '.class == "hold" and (.reasons | any(test("moved by hand to " + $m)))'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$HOME/projects/alpha-wt/moved/wip.txt")" = wip ]
  git -C "$HOME/projects/alpha-wt/moved" status --porcelain | grep -q 'wip.txt'
  git -C "$HOME/projects/alpha" worktree list --porcelain | grep -qx "worktree $HOME/projects/alpha-wt/moved"
  ! git -C "$HOME/projects/alpha" worktree list --porcelain | grep -q '^prunable'
  jq -se 'map(select(.step == "relinked")) | length == 1' "$(journal)"
  # The next plan sees the worktree where it now is.
  migrate --json
  row "$HOME/projects/alpha-wt/moved" | jq -e '.class == "preserve"'
}

@test "apply --only still scopes the plan after a resume reports status 4" {
  alpha
  local unnamed="$HOME/projects/alpha-wt/unnamed" outer="$HOME/projects/alpha-wt/outer"
  local missing="$SANDBOX/nowhere-old" missing_new="$SANDBOX/nowhere-new"
  local journal="$SANDBOX/resume-failed.jsonl"
  wm_wt "$HOME/projects/alpha" unnamed "$unnamed"
  wm_wt "$HOME/projects/alpha" outer "$outer"
  jq -nc --arg old "$missing" --arg new "$missing_new" \
    '{id:"fixture-missing",action:"move",old:$old,new:$new,step:"moved"}' > "$journal"

  migrate --apply --yes --resume "$journal" --only "$missing"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ -d "$unnamed" ] || { echo "unnamed worktree was acted on"; false; }
  [ -d "$outer" ] || { echo "unnamed worktree was acted on"; false; }
}

@test "apply --resume honours --only instead of replaying other journal entries" {
  alpha
  local a="$HOME/projects/alpha-wt/a" b="$HOME/projects/alpha-wt/b" j
  wm_wt "$HOME/projects/alpha" a "$a"
  WM_FAULT_STEP=moved run bash "$SCRIPT" migrate --apply --yes
  [ "$status" -eq 99 ] || { echo "$output"; false; }
  j="$(journal)"
  wm_wt "$HOME/projects/alpha" b "$b"

  migrate --apply --yes --resume "$j" --only "$b"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -se --arg p "$a" '[.[] | select(.old == $p) | .step] == ["moved"]' "$j" ||
    { echo "resume replayed the unselected entry"; false; }
  [ -d "$WT_ROOT/alpha/b" ] || { echo "selected worktree did not move"; false; }
}
