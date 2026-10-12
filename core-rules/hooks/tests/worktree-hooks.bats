#!/usr/bin/env bats
# spec 069 A7: the user-global Claude Code WorktreeCreate / WorktreeRemove hooks.
#
# Each case feeds the hook the JSON Claude Code sends
# (https://code.claude.com/docs/en/hooks#worktreecreate-input) and checks
# stdout, the created paths, the branch and the exit code. Everything lives
# under a sandbox: HOME, TRELLIS_HOME, the git global config and a stub
# `trellis` on PATH that records its argv instead of attaching.

load helpers

CREATE_HOOK="$HOOKS_DIR/trellis-worktree-create.sh"

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-worktree-hooks.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$SANDBOX/bin"
  unset TRELLIS_WORKTREE_ROOT TRELLIS_CONFIG_PATH DJ_MERGED_OVERRIDE DJ_PUSHED_OVERRIDE \
    STUB_GH_HEAD STUB_GH_FAIL TRELLIS_WORKTREE_SYNC_WAIT_S TRELLIS_ATTACH_CALLER_PATH
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  git config --global user.email "ci-bats@trellis.test"
  git config --global user.name "Trellis CI"
  git config --global init.defaultBranch main

  # The stub records each call and its working directory, one line per call.
  cat > "$SANDBOX/bin/trellis" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/trellis-calls"
EOF
  chmod 755 "$SANDBOX/bin/trellis"
  # The gh stub answers `pr list --head B --state merged`: one merged PR whose
  # head is $STUB_GH_HEAD when that is set, none otherwise; STUB_GH_FAIL makes
  # it fail as an unauthenticated gh does. The real gh is never reached.
  cat > "$SANDBOX/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
[ -z "${STUB_GH_FAIL:-}" ] || { echo "gh: not logged in" >&2; exit 4; }
case "$*" in
  *"--json number"*) if [ -n "${STUB_GH_HEAD:-}" ]; then echo '[{"number":7}]'; else echo '[]'; fi ;;
  *"--json headRefOid"*) [ -z "${STUB_GH_HEAD:-}" ] || echo "$STUB_GH_HEAD" ;;
esac
GHSTUB
  chmod 755 "$SANDBOX/bin/gh"
  export PATH="$SANDBOX/bin:$PATH"

  REMOTE="$SANDBOX/remote.git"
  REPO="$SANDBOX/src/myrepo"
  git init -q --bare "$REMOTE"
  mkdir -p "$REPO/sub"
  git -C "$REPO" init -q
  printf 'readme\n' > "$REPO/README.md"
  printf 'nested\n' > "$REPO/sub/file.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push -q origin main
  git -C "$REPO" remote set-head origin main
  # A post-checkout hook that leaves a marker: the create hook must not run it.
  cat > "$REPO/.git/hooks/post-checkout" <<EOF
#!/bin/sh
touch "$SANDBOX/post-checkout-ran"
EOF
  chmod 755 "$REPO/.git/hooks/post-checkout"
  ROOT="$HOME/projects/worktrees"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

register_repo() {
  jq -n --arg common "$REPO/.git" '{
    projects: [{project_id: "myproj", checkouts: [{git_common_dir: $common}]}]
  }' > "$TRELLIS_HOME/registry.json"
}

create_input() {
  jq -cn --arg name "$1" --arg cwd "${2:-$REPO}" '{
    session_id: "abc123",
    transcript_path: "/tmp/transcript.jsonl",
    cwd: $cwd,
    hook_event_name: "WorktreeCreate",
    name: $name
  }'
}

run_create() {
  run_with_stderr "$CREATE_HOOK" "$(create_input "$@")"
}

# wait_for FILE — the detached sync is asynchronous; give it five seconds.
wait_for() {
  local tries=0
  while [ ! -s "$1" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -s "$1" ]
}

@test "A7.1: the fixture's post-checkout hook fires on a plain worktree add" {
  # Guard: without this, "no post-checkout ran" below would be vacuous.
  git -C "$REPO" worktree add -q "$SANDBOX/plain" -b plain >/dev/null 2>&1
  [ -e "$SANDBOX/post-checkout-ran" ]
}

@test "A7.1: a registered repo gets <root>/<project>/cc-<name> on worktree-<name>, stdout is only the path" {
  register_repo
  run_create feat1

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$ROOT/myproj/cc-feat1" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
  [ "$(git -C "$output" symbolic-ref --short HEAD)" = worktree-feat1 ]
  [ "$(git -C "$output" rev-parse --show-toplevel)" = "$output" ]
  [ "$(cat "$output/sub/file.txt")" = nested ]
  [ -z "$(git -C "$output" status --porcelain)" ]
  [ ! -e "$SANDBOX/post-checkout-ran" ]
}

@test "A7.1: a registered repo starts trellis worktree sync detached and logs under TRELLIS_HOME" {
  register_repo
  run_create feat1
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }

  wait_for "$SANDBOX/trellis-calls"
  [ "$(cat "$SANDBOX/trellis-calls")" = "worktree sync $ROOT/myproj/cc-feat1" ]
  [ -d "$TRELLIS_HOME/state/worktree-hooks" ]
  [ -f "$TRELLIS_HOME/state/worktree-hooks/myproj_cc-feat1.sync.log" ]
  [ -f "$TRELLIS_HOME/state/worktree-hooks/myproj_cc-feat1.sync.pid" ]
}

@test "A7.1: an unregistered repo goes to _unregistered/<basename> and starts no sync" {
  run_create feat1

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$ROOT/_unregistered/myrepo/cc-feat1" ]
  [ "$(git -C "$output" symbolic-ref --short HEAD)" = worktree-feat1 ]
  sleep 1
  [ ! -e "$SANDBOX/trellis-calls" ]
}

@test "A7.1: a new branch starts at origin/HEAD, not at an unpushed local commit" {
  printf 'local\n' > "$REPO/local.txt"
  git -C "$REPO" add local.txt
  git -C "$REPO" commit -q -m local
  run_create feat1

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$(git -C "$output" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ]
  [ ! -e "$output/local.txt" ]
  # No upstream is configured, so a bare `git push` cannot target main.
  run git -C "$output" rev-parse --abbrev-ref '@{u}'
  [ "$status" -ne 0 ]
}

@test "A7.1: a repo without origin/HEAD branches from HEAD" {
  git -C "$REPO" remote remove origin
  printf 'local\n' > "$REPO/local.txt"
  git -C "$REPO" add local.txt
  git -C "$REPO" commit -q -m local
  run_create feat1

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$(git -C "$output" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "A7.1: an existing worktree-<name> branch is reused at its own tip" {
  git -C "$REPO" branch worktree-feat1
  printf 'later\n' > "$REPO/later.txt"
  git -C "$REPO" add later.txt
  git -C "$REPO" commit -q -m later
  git -C "$REPO" push -q origin main
  run_create feat1

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$(git -C "$output" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse worktree-feat1)" ]
  [ ! -e "$output/later.txt" ]
}

@test "A7.1: the same name again returns the existing worktree" {
  run_create feat1
  [ "$status" -eq 0 ]
  first="$output"
  printf 'work\n' > "$first/wip.txt"

  run_create feat1
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$first" ]
  [ "$(cat "$first/wip.txt")" = work ]
}

@test "A7.1: a cwd in a subdirectory resolves the repository" {
  run_create feat1 "$REPO/sub"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$ROOT/_unregistered/myrepo/cc-feat1" ]
}

@test "A7.1: a cwd outside any repository fails with nothing on stdout" {
  mkdir -p "$SANDBOX/plain-dir"
  run_create feat1 "$SANDBOX/plain-dir"

  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ROOT" ]
}

@test "A7.1: an occupied target fails and leaves the occupant alone" {
  mkdir -p "$ROOT/_unregistered/myrepo/cc-feat1"
  printf 'mine\n' > "$ROOT/_unregistered/myrepo/cc-feat1/note"
  run_create feat1

  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(cat "$ROOT/_unregistered/myrepo/cc-feat1/note")" = mine ]
  run git -C "$REPO" show-ref --verify --quiet refs/heads/worktree-feat1
  [ "$status" -ne 0 ]
}

@test "A7.1: a name that is not a valid branch component fails" {
  run_create 'bad..name'

  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ROOT" ]
}

@test "A7.1: a worktree root inside a git repository is refused" {
  export TRELLIS_WORKTREE_ROOT="$REPO/nested-root"
  run_create feat1

  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$REPO/nested-root" ]
}

@test "A7.1: the hook resolves its libraries through a home symlink" {
  mkdir -p "$HOME/.claude/hooks"
  ln -s "$CREATE_HOOK" "$HOME/.claude/hooks/trellis-worktree-create.sh"
  run_with_stderr "$HOME/.claude/hooks/trellis-worktree-create.sh" "$(create_input feat1)"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$ROOT/_unregistered/myrepo/cc-feat1" ]
}

@test "A7.1: with trellis off PATH the worktree is still created and the skipped sync is logged" {
  register_repo
  # Only the tools the hook needs, so no real `trellis` launcher is reachable.
  local tool src
  mkdir -p "$SANDBOX/no-trellis"
  for tool in bash sh env git jq sed tr date dirname readlink mkdir chmod cat tee cut grep nohup mktemp rm wc; do
    src="$(command -v "$tool")" && ln -s "$src" "$SANDBOX/no-trellis/$tool"
  done
  PATH="$SANDBOX/no-trellis" run_create feat1

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$ROOT/myproj/cc-feat1" ]
  grep -q 'trellis worktree sync' "$TRELLIS_HOME/state/worktree-hooks/myproj_cc-feat1.sync.log"
  [[ "$stderr" == *"trellis is not on PATH"* ]]
}

# --- WorktreeRemove ---------------------------------------------------------

REMOVE_HOOK="$HOOKS_DIR/trellis-worktree-remove.sh"

remove_input() {
  jq -cn --arg path "$1" '{
    session_id: "abc123",
    transcript_path: "/tmp/transcript.jsonl",
    cwd: $path,
    hook_event_name: "WorktreeRemove",
    worktree_path: $path
  }'
}

run_remove() {
  run_with_stderr "$REMOVE_HOOK" "$(remove_input "$1")"
}

# make_cc NAME — a cc-<name> worktree through the create hook (unregistered).
make_cc() {
  run_create "$1"
  [ "$status" -eq 0 ] || { echo "create failed: $stderr"; return 1; }
  WT="$output"
}

commit_in() {
  printf '%s\n' "$2" > "$1/$2.txt"
  git -C "$1" add "$2.txt"
  git -C "$1" commit -q -m "$2"
}

branch_exists() {
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$1"
}

# owner_record WT PATH... — a committed Trellis owner record for WT that owns
# the given relative paths, where local_registry_identity_for_root puts it.
owner_record() {
  local wt="$1" common checkout_id worktree_id dir
  shift
  common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
  common="$(CDPATH='' cd "$common" && pwd -P)"
  checkout_id="$(printf '%s' "$common" | shasum -a 256 | cut -d ' ' -f 1)"
  worktree_id="$(printf '%s' "$wt" | shasum -a 256 | cut -d ' ' -f 1)"
  dir="$TRELLIS_HOME/state/attachments/$checkout_id"
  mkdir -p "$dir"
  jq -n --arg root "$wt" --args '{status: "committed", worktree_root: $root,
    artifacts: [$ARGS.positional[] | {kind: "symlink", path: ., target: "/payload"}]}' "$@" \
    > "$dir/$worktree_id.json"
}

@test "A7.2: a tracked modification is refused and the worktree is kept" {
  make_cc feat1
  printf 'changed\n' > "$WT/README.md"
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  [ "$(cat "$WT/README.md")" = changed ]
  [[ "$stderr" == *"uncommitted or untracked"* ]]
  branch_exists worktree-feat1
}

@test "A7.2: an untracked file is refused and the worktree is kept" {
  make_cc feat1
  printf 'new\n' > "$WT/new.txt"
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ "$(cat "$WT/new.txt")" = new ]
  [[ "$stderr" == *"new.txt"* ]]
}

@test "A7.2: an ignored file outside the regenerable set is refused" {
  printf '.env.local\nnode_modules/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -q -m ignore
  git -C "$REPO" push -q origin main
  make_cc feat1
  printf 'SECRET=1\n' > "$WT/.env.local"
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ "$(cat "$WT/.env.local")" = "SECRET=1" ]
  [[ "$stderr" == *".env.local"* ]]
}

@test "A7.2: an ignored regenerable directory does not block removal" {
  printf 'node_modules/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -q -m ignore
  git -C "$REPO" push -q origin main
  make_cc feat1
  mkdir -p "$WT/node_modules/pkg"
  printf '{}\n' > "$WT/node_modules/pkg/package.json"
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ ! -e "$WT" ]
}

@test "A7.2: an unpushed commit on an unmerged branch is refused" {
  make_cc feat1
  commit_in "$WT" work
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  [[ "$stderr" == *"not on any remote"* ]]
  branch_exists worktree-feat1
}

@test "A7.2: unmerged and unverified are both treated as not merged" {
  make_cc feat1
  commit_in "$WT" work
  export DJ_MERGED_OVERRIDE=unverified
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
}

@test "A7.2: clean and merged: the worktree is removed and its branch deleted" {
  make_cc feat1
  # A squash merge leaves the branch's own commit off every remote ref.
  commit_in "$WT" work
  export STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ ! -e "$WT" ]
  if branch_exists worktree-feat1; then echo "branch survived"; false; fi
  [ -z "$(git -C "$REPO" worktree list --porcelain | grep -F "$WT")" ]
  grep -q "deleted branch worktree-feat1 at $STUB_GH_HEAD" \
    "$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
}

@test "A7.2: clean and unmerged with no unique commits: removed, branch kept" {
  make_cc feat1
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ ! -e "$WT" ]
  branch_exists worktree-feat1
}

@test "A7.2: clean and unmerged with every commit pushed: removed, branch kept" {
  make_cc feat1
  commit_in "$WT" work
  git -C "$WT" push -q origin worktree-feat1
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ ! -e "$WT" ]
  branch_exists worktree-feat1
}

@test "A7.2: a merged branch that is not worktree-* is never deleted" {
  make_cc feat1
  git -C "$WT" checkout -q -b feature/other
  export STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ ! -e "$WT" ]
  branch_exists feature/other
}

@test "A7.2: a locked worktree is refused" {
  make_cc feat1
  git -C "$REPO" worktree lock --reason busy "$WT"
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  [[ "$stderr" == *"it is locked (busy)"* ]]
}

@test "A7.2: the main checkout is refused" {
  export DJ_MERGED_OVERRIDE=merged
  run_remove "$REPO"

  [ "$status" -ne 0 ]
  [ -f "$REPO/README.md" ]
}

@test "A7.2: a path that is already gone is a no-op success" {
  run_remove "$SANDBOX/never-existed"

  [ "$status" -eq 0 ]
}

@test "A7.2: an attached worktree is detached through trellis before git removes it" {
  printf '.trellis-leaf\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  ln -s /payload/leaf "$WT/.trellis-leaf"
  owner_record "$WT" .trellis-leaf
  # The stub detach removes the owned leaf, as a real detach would.
  cat > "$SANDBOX/bin/trellis" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/trellis-calls"
[ "\$1" = detach ] && rm -f "\$2/.trellis-leaf"
exit 0
STUB
  export STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  local tries=0
  while [ -e "$WT" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
  [ ! -e "$WT" ]
  [ "$(cat "$SANDBOX/trellis-calls")" = "detach $WT" ]
  tries=0
  while branch_exists worktree-feat1 && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
  if branch_exists worktree-feat1; then echo "branch survived"; false; fi
}

@test "A7.2: an attached worktree with an unowned ignored file is refused before detach" {
  printf '.trellis-leaf\n.env.local\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  ln -s /payload/leaf "$WT/.trellis-leaf"
  printf 'SECRET=1\n' > "$WT/.env.local"
  owner_record "$WT" .trellis-leaf
  export DJ_MERGED_OVERRIDE=merged
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  [[ "$stderr" == *".env.local"* ]]
  [[ "$stderr" != *".trellis-leaf"* ]]
  sleep 1
  [ ! -e "$SANDBOX/trellis-calls" ]
}

@test "A7.2: a detach that fails leaves the worktree and logs why" {
  printf '.trellis-leaf\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  ln -s /payload/leaf "$WT/.trellis-leaf"
  owner_record "$WT" .trellis-leaf
  printf '#!/usr/bin/env bash\necho "detach refused" >&2\nexit 3\n' > "$SANDBOX/bin/trellis"
  export DJ_MERGED_OVERRIDE=merged
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  local log="$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
  local tries=0
  while ! grep -q 'kept' "$log" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
  grep -q 'detach refused' "$log"
  grep -q 'kept' "$log"
  [ -d "$WT" ]
  branch_exists worktree-feat1
}

# --- merge proof, sync wait and fail-closed cases -----------------------------

@test "A7.2: a merged PR does not cover a commit made after its head: kept, branch intact" {
  make_cc feat1
  commit_in "$WT" work1
  export STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  commit_in "$WT" work2
  local tip
  tip="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  [ "$(git -C "$REPO" rev-parse worktree-feat1)" = "$tip" ]
  [[ "$stderr" == *"not on any remote"* ]]
}

@test "A7.2: gh absent means unknown merge state: a unique commit keeps the worktree" {
  make_cc feat1
  commit_in "$WT" work
  local tool src
  mkdir -p "$SANDBOX/no-gh"
  for tool in bash sh env git jq sed tr date dirname readlink mkdir chmod cat tee cut grep \
    nohup mktemp rm wc find head shasum perl kill sleep ps awk; do
    src="$(command -v "$tool")" && ln -s "$src" "$SANDBOX/no-gh/$tool"
  done
  PATH="$SANDBOX/no-gh" run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  branch_exists worktree-feat1
}

@test "A7.2: stripped PATH resolves gh via TRELLIS_ATTACH_CALLER_PATH when proving merge" {
  make_cc feat1
  commit_in "$WT" work
  export STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"

  local tool src
  mkdir -p "$SANDBOX/stripped-path"
  for tool in bash sh env git jq sed tr date dirname readlink mkdir chmod cat tee cut grep \
    nohup mktemp rm wc find head shasum perl kill sleep ps awk; do
    src="$(command -v "$tool")" && ln -s "$src" "$SANDBOX/stripped-path/$tool"
  done

  PATH="$SANDBOX/stripped-path" TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/bin" run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ ! -e "$WT" ]
  if branch_exists worktree-feat1; then echo "branch survived"; false; fi
}

@test "A7.2: stripped PATH with unauthenticated gh on TRELLIS_ATTACH_CALLER_PATH keeps worktree" {
  make_cc feat1
  commit_in "$WT" work
  export STUB_GH_HEAD STUB_GH_FAIL=1
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"

  local tool src
  mkdir -p "$SANDBOX/stripped-path"
  for tool in bash sh env git jq sed tr date dirname readlink mkdir chmod cat tee cut grep \
    nohup mktemp rm wc find head shasum perl kill sleep ps awk; do
    src="$(command -v "$tool")" && ln -s "$src" "$SANDBOX/stripped-path/$tool"
  done

  PATH="$SANDBOX/stripped-path" TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/bin" run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  branch_exists worktree-feat1
}

@test "A7.2: an unauthenticated gh means unknown merge state: a unique commit keeps the worktree" {
  make_cc feat1
  commit_in "$WT" work
  export STUB_GH_FAIL=1
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  branch_exists worktree-feat1
}

# fake_sync WT SECONDS — a live process whose argv names `worktree sync WT`,
# recorded where the create hook records its sync pid.
fake_sync() {
  local dir="$TRELLIS_HOME/state/worktree-hooks"
  mkdir -p "$dir"
  # The trailing `:` keeps bash from exec'ing sleep, so ps shows this argv.
  bash -c 'sleep "$1"; :' "trellis worktree sync $1" "$2" &
  printf '%s\n' "$!" > "$dir/_unregistered_myrepo_cc-feat1.sync.pid"
}

@test "A7.2: the background step re-checks ignored files the pending-sync path deferred" {
  printf '.env.local\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  printf 'SECRET=1\n' > "$WT/.env.local"
  fake_sync "$WT" 1
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  local log="$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
  local tries=0
  while ! grep -q 'kept' "$log" 2>/dev/null && [ "$tries" -lt 80 ]; do sleep 0.1; tries=$((tries + 1)); done
  grep -q 'ignored, not regenerable: .env.local' "$log"
  [ "$(cat "$WT/.env.local")" = "SECRET=1" ]
}

@test "A7.2: a sync that outlives the bounded wait keeps the worktree with a reason" {
  make_cc feat1
  fake_sync "$WT" 5
  export DJ_MERGED_OVERRIDE=unmerged TRELLIS_WORKTREE_SYNC_WAIT_S=1
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  local log="$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
  local tries=0
  while ! grep -q 'kept' "$log" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
  grep -q 'still running' "$log"
  [ -d "$WT" ]
}

@test "A7.2: a recorded pid reused by an unrelated process is not a pending sync" {
  make_cc feat1
  mkdir -p "$TRELLIS_HOME/state/worktree-hooks"
  sleep 30 &
  local other=$!
  printf '%s\n' "$other" > "$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.sync.pid"
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"
  kill "$other" 2>/dev/null || true

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  # Removed in the foreground: no background step waited on the unrelated pid.
  [ ! -e "$WT" ]
}

@test "A7.2: the background step re-check passes the owned list: non-regenerable *.db blocks removal while owned files do not" {
  printf '.trellis-leaf\nlocal.db\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  ln -s /payload/leaf "$WT/.trellis-leaf"
  owner_record "$WT" .trellis-leaf
  fake_sync "$WT" 1
  printf 'db-data\n' > "$WT/local.db"
  cat > "$SANDBOX/bin/trellis" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/trellis-calls"
exit 0
STUB
  export DJ_MERGED_OVERRIDE=merged
  export STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  local log="$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
  local tries=0
  while ! grep -q 'kept' "$log" 2>/dev/null && [ "$tries" -lt 80 ]; do sleep 0.1; tries=$((tries + 1)); done
  grep -q 'ignored, not regenerable: local.db' "$log"
  if grep -q 'ignored, not regenerable: .trellis-leaf' "$log"; then false; fi
  [ -d "$WT" ]
  [ "$(cat "$WT/local.db")" = "db-data" ]
}

