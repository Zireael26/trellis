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
  chmod 700 "$HOME" "$TRELLIS_HOME"
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
  # it fail as an unauthenticated gh does; STUB_GH_LOG records each call. The
  # real gh is never reached.
  cat > "$SANDBOX/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
[ -z "${STUB_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$STUB_GH_LOG"
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

# sync_stub RC [SECONDS] — `trellis worktree sync` sleeps, records that it
# finished, prints a line (which must never reach the hook's stdout) and exits RC.
sync_stub() {
  cat > "$SANDBOX/bin/trellis" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$\$" > "$SANDBOX/trellis-pid"
printf '%s\\n' "\$*" >> "$SANDBOX/trellis-calls"
sleep ${2:-0}
printf 'sync output\\n'
printf '%s\\n' "\$*" >> "$SANDBOX/trellis-done"
exit $1
EOF
  chmod 755 "$SANDBOX/bin/trellis"
}

@test "T48: a registered repo prints the path only after trellis worktree sync finished in the foreground" {
  register_repo
  sync_stub 0 1
  run_create feat1
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$ROOT/myproj/cc-feat1" ]
  # Already finished when the hook returned: no wait, no detached job.
  [ "$(cat "$SANDBOX/trellis-done")" = "worktree sync $ROOT/myproj/cc-feat1" ]
  [ "$(cat "$SANDBOX/trellis-calls")" = "worktree sync $ROOT/myproj/cc-feat1" ]
  grep -Fxq 'sync output' "$TRELLIS_HOME/state/worktree-hooks/myproj_cc-feat1.sync.log"
  [ ! -e "$TRELLIS_HOME/state/worktree-hooks/myproj_cc-feat1.sync.pid" ]
}

@test "T48: a failed attach exits nonzero with no path, keeps the worktree, and a same-name retry repairs or fails again" {
  register_repo
  local path="$ROOT/myproj/cc-feat1"
  sync_stub 5
  run_create feat1
  [ "$status" -eq 5 ] || { echo "status $status stderr: $stderr"; false; }
  [ -z "$output" ]
  [[ "$stderr" == *"$path is not ready"* ]]
  # Recovery evidence: the populated tree, its branch and the log stay.
  [ "$(cat "$path/sub/file.txt")" = nested ]
  [ "$(git -C "$path" symbolic-ref --short HEAD)" = worktree-feat1 ]
  grep -Fxq 'worktree sync exit 5' "$TRELLIS_HOME/state/worktree-hooks/myproj_cc-feat1.sync.log"
  # A retry with the attach still failing returns no path, never unverified reuse.
  run_create feat1
  [ "$status" -ne 0 ] && [ -z "$output" ] || { echo "status $status output $output"; false; }
  # Once sync succeeds the same name is repaired and returned.
  sync_stub 0
  run_create feat1
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$path" ]
  [ "$(grep -c "worktree sync $path" "$SANDBOX/trellis-calls")" -eq 3 ]
}

@test "T48: a create killed during the attach leaves no path, and the retry reattaches before stdout" {
  register_repo
  local path="$ROOT/myproj/cc-feat1" out="$SANDBOX/killed.out" pid tries=0
  sync_stub 0 30
  "$CREATE_HOOK" > "$out" 2>/dev/null <<< "$(create_input feat1)" &
  pid=$!
  until [ -s "$SANDBOX/trellis-calls" ] || [ "$tries" -ge 100 ]; do sleep 0.1; tries=$((tries + 1)); done
  [ -s "$SANDBOX/trellis-calls" ]
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null || true
  # The hook's foreground sync outlives it; stop exactly that stub.
  pkill -KILL -P "$(cat "$SANDBOX/trellis-pid")" 2>/dev/null || true
  kill -KILL "$(cat "$SANDBOX/trellis-pid")" 2>/dev/null || true
  [ ! -s "$out" ]
  [ -d "$path" ]
  sync_stub 0
  run_create feat1
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$path" ]
  [ "$(tail -n 1 "$SANDBOX/trellis-done")" = "worktree sync $path" ]
}

@test "A7.1: an unregistered repo goes to _unregistered/<basename> and starts no sync" {
  run_create feat1

  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$ROOT/_unregistered/myrepo/cc-feat1" ]
  [ "$(git -C "$output" symbolic-ref --short HEAD)" = worktree-feat1 ]
  sleep 1
  [ ! -e "$SANDBOX/trellis-calls" ]
}

@test "A7.1: an empty or malformed registry cannot route a worktree as unregistered" {
  local registry
  for registry in '' '  ' '{"projects":"oops"}' '{"projects":{}}{"projects":{}}'; do
    printf '%s' "$registry" > "$TRELLIS_HOME/registry.json"
    run_create feat1
    [ "$status" -ne 0 ] || { echo "accepted registry: $registry"; false; }
    [ -z "$output" ]
    [ ! -e "$ROOT/_unregistered/myrepo/cc-feat1" ]
  done
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
  printf 'tracked work\n' > "$first/README.md"

  run_create feat1
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [ "$output" = "$first" ]
  [ "$(cat "$first/wip.txt")" = work ]
  [ "$(cat "$first/README.md")" = 'tracked work' ]
}

@test "A7.1: retry refuses an unpopulated no-checkout worktree without discarding data" {
  local path="$ROOT/_unregistered/myrepo/cc-feat1"
  mkdir -p "${path%/*}"
  git -C "$REPO" worktree add -q --no-checkout -b worktree-feat1 "$path"
  # Even if a Git inspection materialized an empty index, reuse is unsafe.
  git -C "$path" status --porcelain >/dev/null
  printf 'keep\n' > "$path/wip.txt"
  run_create feat1
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(cat "$path/wip.txt")" = keep ]
  [[ "$stderr" == *"unpopulated"* ]]
}

@test "A7.1: interrupted population is remembered even when Git already wrote the index" {
  export REAL_GIT="$(command -v git)"
  cat > "$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "${FAIL_POPULATE:-}" = 1 ]; then
  case "$*" in
    *' reset --hard '*) "$REAL_GIT" "$@"; exit 1 ;;
  esac
fi
exec "$REAL_GIT" "$@"
STUB
  chmod 755 "$SANDBOX/bin/git"
  export FAIL_POPULATE=1
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  unset FAIL_POPULATE
  local path="$ROOT/_unregistered/myrepo/cc-feat1"
  [ -n "$(git -C "$path" ls-files)" ]
  printf 'keep\n' > "$path/wip.txt"
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"population"* ]]
  [ "$(cat "$path/wip.txt")" = keep ]
}

@test "A7.1: failed worktree add clears its marker and permits a later retry" {
  local path="$ROOT/_unregistered/myrepo/cc-feat1" marker
  marker="$TRELLIS_HOME/state/worktree-hooks/populate-$(printf '%s' "$path" | git hash-object --stdin)"
  git -C "$REPO" checkout -qb worktree-feat1
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  [ ! -e "$path" ]
  [ ! -e "$marker" ]
  git -C "$REPO" checkout -q main
  run_create feat1
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$output" = "$path" ]
  [ -f "$path/README.md" ]
}

@test "A7.1: removing an interrupted worktree permits recreation despite its stale marker" {
  export REAL_GIT="$(command -v git)"
  cat > "$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "${FAIL_POPULATE:-}" = 1 ]; then
  case "$*" in *' reset --hard '*) "$REAL_GIT" "$@"; exit 1 ;; esac
fi
exec "$REAL_GIT" "$@"
STUB
  chmod 755 "$SANDBOX/bin/git"
  export FAIL_POPULATE=1
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  unset FAIL_POPULATE
  local path="$ROOT/_unregistered/myrepo/cc-feat1" marker
  marker="$TRELLIS_HOME/state/worktree-hooks/populate-$(printf '%s' "$path" | git hash-object --stdin)"
  [ -d "$marker" ]
  git -C "$REPO" worktree remove "$path"
  [ ! -e "$path" ]
  run_create feat1
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$output" = "$path" ]
  [ -f "$path/README.md" ]
  [ ! -e "$marker" ]
}

@test "A7.1: a failed add that created a worktree preserves the marker and user work" {
  export REAL_GIT="$(command -v git)"
  cat > "$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "${FAIL_AFTER_ADD:-}" = 1 ]; then
  case "$*" in *' worktree add '*) "$REAL_GIT" "$@"; exit 1 ;; esac
fi
exec "$REAL_GIT" "$@"
STUB
  chmod 755 "$SANDBOX/bin/git"
  export FAIL_AFTER_ADD=1
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  unset FAIL_AFTER_ADD
  local path="$ROOT/_unregistered/myrepo/cc-feat1" marker
  marker="$TRELLIS_HOME/state/worktree-hooks/populate-$(printf '%s' "$path" | git hash-object --stdin)"
  [ -d "$path" ] && [ -d "$marker" ]
  printf 'user work\n' > "$path/wip.txt"
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  [ "$(cat "$path/wip.txt")" = 'user work' ]
  [ -d "$marker" ]
}

@test "A7.1: stale marker cleanup preserves unexpected marker content" {
  local path="$ROOT/_unregistered/myrepo/cc-feat1" marker
  marker="$TRELLIS_HOME/state/worktree-hooks/populate-$(printf '%s' "$path" | git hash-object --stdin)"
  mkdir -p "$marker"
  printf 'do not remove\n' > "$marker/note"
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  [ "$(cat "$marker/note")" = 'do not remove' ]
  [ ! -e "$path" ]
}

@test "A7.1: stale marker cleanup refuses symlinks" {
  local path="$ROOT/_unregistered/myrepo/cc-feat1" marker
  marker="$TRELLIS_HOME/state/worktree-hooks/populate-$(printf '%s' "$path" | git hash-object --stdin)"
  mkdir -p "${marker%/*}" "$SANDBOX/external"
  printf 'keep\n' > "$SANDBOX/external/note"
  ln -s "$SANDBOX/external" "$marker"
  run bash "$CREATE_HOOK" <<< "$(create_input feat1)"
  [ "$status" -ne 0 ]
  [ -L "$marker" ]
  [ "$(cat "$SANDBOX/external/note")" = keep ]
  [ ! -e "$path" ]
}

@test "A7.1: a concurrent create cannot clear an active population marker" {
  export REAL_GIT="$(command -v git)"
  export HOLD_STARTED="$SANDBOX/add-started" HOLD_RELEASE="$SANDBOX/add-release" HOLD_SECOND="$SANDBOX/add-second" HOLD_WORKTREE_ADD=1
  cat > "$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "${HOLD_WORKTREE_ADD:-}" = 1 ]; then
  case "$*" in
    *' worktree add '*)
      if [ -e "$HOLD_STARTED" ]; then
        printf 'second add\n' > "$HOLD_SECOND"
        exit 79
      fi
      printf 'started\n' > "$HOLD_STARTED"
      while [ ! -e "$HOLD_RELEASE" ]; do sleep 0.1; done
      ;;
  esac
fi
exec "$REAL_GIT" "$@"
STUB
  chmod 755 "$SANDBOX/bin/git"
  local path="$ROOT/_unregistered/myrepo/cc-feat1" marker input first_pid second_rc second_output first_rc marker_held
  marker="$TRELLIS_HOME/state/worktree-hooks/populate-$(printf '%s' "$path" | git hash-object --stdin)"
  input="$(create_input feat1)"
  bash "$CREATE_HOOK" <<< "$input" > "$SANDBOX/first.out" 2> "$SANDBOX/first.err" &
  first_pid=$!
  if ! wait_for "$HOLD_STARTED"; then
    touch "$HOLD_RELEASE"
    wait "$first_pid" || true
    return 1
  fi
  run bash "$CREATE_HOOK" <<< "$input"
  second_rc="$status"; second_output="$output"
  marker_held=no; [ ! -d "$marker" ] || marker_held=yes
  touch "$HOLD_RELEASE"
  first_rc=0; wait "$first_pid" || first_rc=$?
  unset HOLD_WORKTREE_ADD
  [ "$second_rc" -ne 0 ]
  [[ "$second_output" == *"creation already in progress"* ]]
  [ "$marker_held" = yes ]
  [ ! -e "$HOLD_SECOND" ]
  [ "$first_rc" -eq 0 ] || { echo "first create failed"; false; }
  [ -f "$path/README.md" ]
}

@test "A7.1: an in-flight add retains its creation lock if the hook is killed" {
  export REAL_GIT="$(command -v git)"
  export HOLD_STARTED="$SANDBOX/killed-started" HOLD_RELEASE="$SANDBOX/killed-release" HOLD_DONE="$SANDBOX/killed-done" HOLD_WORKTREE_ADD=1
  export HOLD_EXIT="$SANDBOX/killed-exit" HOLD_EXITED="$SANDBOX/killed-exited"
  cat > "$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "${HOLD_WORKTREE_ADD:-}" = 1 ]; then
  case "$*" in
    *' worktree add '*)
      printf 'started\n' > "$HOLD_STARTED"
      while [ ! -e "$HOLD_RELEASE" ]; do sleep 0.1; done
      "$REAL_GIT" "$@"
      rc=$?
      # Prove the final create runs after the lock is released even while
      # this stub is still alive, rather than racing its eventual exit.
      exec 9>&-
      printf 'done\n' > "$HOLD_DONE"
      while [ ! -e "$HOLD_EXIT" ]; do sleep 0.1; done
      printf 'exiting\n' > "$HOLD_EXITED"
      exit "$rc"
      ;;
  esac
fi
exec "$REAL_GIT" "$@"
STUB
  chmod 755 "$SANDBOX/bin/git"
  local path="$ROOT/_unregistered/myrepo/cc-feat1" marker input first_pid second_rc second_output done_rc=0 exit_rc=0 final_rc=0 final_output=''
  marker="$TRELLIS_HOME/state/worktree-hooks/populate-$(printf '%s' "$path" | git hash-object --stdin)"
  input="$(create_input feat1)"
  # Portable wall-clock bound: kill the entire test-owned process group so a
  # mutant waiting in its git stub cannot wedge the Bats suite or leak a child.
  run_bounded_create() {
    run perl -e '
      use POSIX ();
      my $pid = fork();
      defined($pid) or exit 125;
      if ($pid == 0) {
        POSIX::setsid() >= 0 or POSIX::_exit(125);
        exec @ARGV or POSIX::_exit(126);
      }
      $SIG{ALRM} = sub {
        kill "KILL", -$pid;
        kill "KILL", $pid;
        waitpid($pid, 0);
        exit 124;
      };
      alarm 8;
      waitpid($pid, 0) == $pid or exit 125;
      my $st = $?;
      alarm 0;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' bash "$CREATE_HOOK" <<< "$input"
  }
  bash "$CREATE_HOOK" <<< "$input" > "$SANDBOX/killed.out" 2> "$SANDBOX/killed.err" &
  first_pid=$!
  if ! wait_for "$HOLD_STARTED"; then
    touch "$HOLD_RELEASE" "$HOLD_EXIT"
    wait "$first_pid" || true
    return 1
  fi
  kill -KILL "$first_pid"
  wait "$first_pid" 2>/dev/null || true
  run_bounded_create
  second_rc="$status"; second_output="$output"
  touch "$HOLD_RELEASE"
  wait_for "$HOLD_DONE" || done_rc=$?
  unset HOLD_WORKTREE_ADD
  if [ "$done_rc" -eq 0 ]; then
    run_bounded_create
    final_rc="$status"; final_output="$output"
  fi
  # Release and observe the stub before asserting, even on a timeout.
  touch "$HOLD_EXIT"
  wait_for "$HOLD_EXITED" || exit_rc=$?
  [ "$done_rc" -eq 0 ] && [ "$exit_rc" -eq 0 ]
  [ "$second_rc" -ne 124 ] || { echo 'second create timed out'; false; }
  [ "$second_rc" -ne 0 ]
  [[ "$second_output" == *"creation already in progress"* ]]
  [ -d "$path" ] && [ -d "$marker" ]
  [ "$final_rc" -ne 124 ] || { echo 'final create timed out'; false; }
  [ "$final_rc" -ne 0 ]
  [[ "$final_output" == *"interrupted population marker"* ]]
}

@test "A7.1: retrying a populated registered worktree reruns sync before stdout" {
  register_repo
  local path="$ROOT/myproj/cc-feat1"
  mkdir -p "${path%/*}"
  git -C "$REPO" worktree add -q --no-checkout -b worktree-feat1 "$path"
  git -C "$path" reset --hard -q
  run_create feat1
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$output" = "$path" ]
  grep -Fxq "worktree sync $path" "$SANDBOX/trellis-calls"
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

@test "T48: with trellis off PATH a registered create fails with no path and keeps the worktree" {
  register_repo
  # Only the tools the hook needs, so no real `trellis` launcher is reachable.
  local tool src
  mkdir -p "$SANDBOX/no-trellis"
  for tool in bash sh env git jq perl sed tr date dirname readlink mkdir rmdir chmod cat tee cut grep nohup mktemp rm wc; do
    src="$(command -v "$tool")" && ln -s "$src" "$SANDBOX/no-trellis/$tool"
  done
  PATH="$SANDBOX/no-trellis" run_create feat1

  [ "$status" -ne 0 ] || { echo "stderr: $stderr"; false; }
  [ -z "$output" ]
  [ -d "$ROOT/myproj/cc-feat1" ]
  grep -q 'trellis is not on PATH' "$TRELLIS_HOME/state/worktree-hooks/myproj_cc-feat1.sync.log"
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

path_missing() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
branch_missing() { ! branch_exists "$1"; }
log_has() { grep -qF -- "$2" "$1" 2>/dev/null; }

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

@test "A7.2: nested ignored environment and database files block removal even under dist" {
  printf 'dist/\n' > "$REPO/.gitignore"
  printf '{}\n' > "$REPO/package.json"
  git -C "$REPO" add .gitignore package.json
  git -C "$REPO" commit -q -m ignore
  git -C "$REPO" push -q origin main
  make_cc feat1
  mkdir -p "$WT/dist/nested"
  printf 'private\n' > "$WT/dist/nested/.env.local"
  printf 'data\n' > "$WT/dist/nested/prod.db"
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ "$(cat "$WT/dist/nested/.env.local")" = private ]
  [ "$(cat "$WT/dist/nested/prod.db")" = data ]
  [[ "$stderr" == *"dist/nested/.env.local"* ]]
  [[ "$stderr" == *"dist/nested/prod.db"* ]]
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

@test "A7.2: an inaccessible worktree is kept rather than reported already gone" {
  mkdir -p "$SANDBOX/inaccessible/wt"
  printf 'work\n' > "$SANDBOX/inaccessible/wt/note"
  chmod 000 "$SANDBOX/inaccessible"
  run_remove "$SANDBOX/inaccessible/wt"
  chmod 700 "$SANDBOX/inaccessible"

  [ "$status" -ne 0 ]
  [ "$(cat "$SANDBOX/inaccessible/wt/note")" = work ]
  [[ "$stderr" == *"cannot"* ]]
}

@test "A7.2: a path that is already gone is a no-op success" {
  run_remove "$SANDBOX/never-existed"

  [ "$status" -eq 0 ]
}

@test "A7.2: owner lookup errors cannot be mistaken for an unattached worktree" {
  make_cc feat1
  owner_record "$WT"
  cd "$SANDBOX"
  export TRELLIS_HOME=relative
  run_remove "$WT"

  [ "$status" -ne 0 ]
  [ -d "$WT" ]
  [[ "$stderr" == *"owner"* ]]
  [ ! -e "$SANDBOX/trellis-calls" ]
}

@test "A7.2: malformed or noncommitted owner records keep the worktree" {
  make_cc feat1
  owner_record "$WT"
  local owner
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  for contents in 'not json' '{"status":"preparing","artifacts":[]}'; do
    printf '%s\n' "$contents" > "$owner"
    run_remove "$WT"
    [ "$status" -ne 0 ]
    [ -d "$WT" ]
    [[ "$stderr" == *"owner"* ]]
  done
}

@test "T49: an attached worktree is detached and removed before the hook exits 0" {
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

  # T49: exit 0 only once detach, removal and the branch proof are done.
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  [[ "$stderr" != *"continue in the background"* ]]
  path_missing "$WT"
  [ "$(cat "$SANDBOX/trellis-calls")" = "detach $WT" ]
  branch_missing worktree-feat1
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
  local log="$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
  grep -qF "kept $WT: ignored, not regenerable: .env.local" "$log"
  [[ "$stderr" != *"continue in the background"* ]]
  [ ! -e "$SANDBOX/trellis-calls" ]
}

@test "T49: a detach that fails exits 1, leaves the worktree and says why" {
  printf '.trellis-leaf\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  ln -s /payload/leaf "$WT/.trellis-leaf"
  owner_record "$WT" .trellis-leaf
  printf '#!/usr/bin/env bash\necho "detach refused" >&2\nexit 3\n' > "$SANDBOX/bin/trellis"
  export DJ_MERGED_OVERRIDE=merged
  run_remove "$WT"

  # T49: a failed detach is an explicit kept failure, never success.
  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  [[ "$stderr" == *"kept $WT: trellis detach failed"* ]]
  [[ "$stderr" == *"detach refused"* ]]
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
  # T34b: a missing gh is a labelled degraded check, never silent.
  [[ "$stderr" == *"degraded: PR merge check unavailable (gh not found"* ]] || { echo "stderr: $stderr"; false; }
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

@test "T49: after a pending sync finishes, ignored files the early check deferred still block (exit 1)" {
  printf '.env.local\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  printf 'SECRET=1\n' > "$WT/.env.local"
  fake_sync "$WT" 1
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$WT"

  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  [[ "$stderr" == *"ignored, not regenerable: .env.local"* ]]
  [[ "$stderr" != *"continue in the background"* ]]
  [ "$(cat "$WT/.env.local")" = "SECRET=1" ]
}

@test "T49: a sync that outlives the bounded wait is a nonzero kept-pending return" {
  make_cc feat1
  fake_sync "$WT" 5
  export DJ_MERGED_OVERRIDE=unmerged TRELLIS_WORKTREE_SYNC_WAIT_S=1
  run_remove "$WT"

  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  local log="$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
  grep -q "kept $WT: its create-time trellis worktree sync is still running after 1s" "$log"
  [[ "$stderr" != *"continue in the background"* ]]
  [ -d "$WT" ]
}

@test "T49: a pending sync that finishes inside the wait is followed by a foreground removal" {
  make_cc feat1
  fake_sync "$WT" 1
  export DJ_MERGED_OVERRIDE=unmerged TRELLIS_WORKTREE_SYNC_WAIT_S=20
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "status $status stderr: $stderr"; false; }
  path_missing "$WT"
  branch_exists worktree-feat1
}

@test "T49: the default sync wait stays under Claude's 120 s WorktreeRemove timeout" {
  local default
  default="$(sed -n 's/.*TRELLIS_WORKTREE_SYNC_WAIT_S:-\([0-9][0-9]*\)}.*/\1/p' "$REMOVE_HOOK")"
  [ -n "$default" ] && [ "$default" -le 90 ] || { echo "default wait: '$default'"; false; }
  grep -q '"WorktreeRemove"' "$HOOKS_DIR/../templates/claude-user-settings.json"
  jq -e '[.hooks.WorktreeRemove[].hooks[].timeout] | all(. >= 120)' \
    "$HOOKS_DIR/../templates/claude-user-settings.json" >/dev/null
}

@test "T49: an edit raced in during the detach keeps the worktree and the edit" {
  printf '.trellis-leaf\n.env.local\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  ln -s /payload/leaf "$WT/.trellis-leaf"
  owner_record "$WT" .trellis-leaf
  # The detach races a tracked edit and an ignored secret into the tree.
  cat > "$SANDBOX/bin/trellis" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/trellis-calls"
[ "\$1" = detach ] && { rm -f "\$2/.trellis-leaf"; printf 'raced\n' >> "\$2/README.md"; printf 'S=1\n' > "\$2/.env.local"; }
exit 0
STUB
  export DJ_MERGED_OVERRIDE=merged STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"

  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  [ "$(cat "$SANDBOX/trellis-calls")" = "detach $WT" ]
  [[ "$stderr" == *"README.md"* ]] && [[ "$stderr" == *".env.local"* ]] || { echo "$stderr"; false; }
  [ "$(tail -n 1 "$WT/README.md")" = raced ]
  [ "$(cat "$WT/.env.local")" = S=1 ]
  branch_exists worktree-feat1
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

@test "T49: the post-sync re-check passes the owned list: non-regenerable *.db blocks removal while owned files do not" {
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

  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  local log="$TRELLIS_HOME/state/worktree-hooks/_unregistered_myrepo_cc-feat1.remove.log"
  grep -q 'ignored, not regenerable: local.db' "$log"
  if grep -q 'ignored, not regenerable: .trellis-leaf' "$log"; then false; fi
  [ -d "$WT" ]
  [ "$(cat "$WT/local.db")" = "db-data" ]
}


@test "sweep-fx1: owned directory name does not exempt unowned descendant" {
  local wt="$BATS_TEST_TMPDIR/wt-is-owned"
  rm -rf "$wt"
  mkdir -p "$wt/scratch"
  printf 'secret' > "$wt/scratch/.env"
  # Extract is_owned from the hook for unit testing.
  sed -n '/^is_owned/,/^}/p' "$HOOKS_DIR/trellis-worktree-remove.sh" > "$BATS_TEST_TMPDIR/is_owned.sh"
  # shellcheck disable=SC1090
  . "$BATS_TEST_TMPDIR/is_owned.sh"
  # Owned dir with unowned .env inside must NOT be owned (blocker).
  run is_owned "$wt" "scratch" "scratch"
  [ "$status" -ne 0 ]
  # Exact file match still owned.
  printf 'hi' > "$wt/file.txt"
  run is_owned "$wt" "file.txt" "file.txt"
  [ "$status" -eq 0 ]
  # Empty owned dir still owned.
  mkdir -p "$wt/emptydir"
  run is_owned "$wt" "emptydir" "emptydir"
  [ "$status" -eq 0 ]
  rm -rf "$wt"
}

@test "sweep-fx1-L10: owned .claude with only Trellis state does not block" {
  local wt="$BATS_TEST_TMPDIR/wt-l10"
  rm -rf "$wt"
  mkdir -p "$wt/.claude/.reread-state"
  printf 'x' > "$wt/.claude/.review-done-abc123"
  printf 'x' > "$wt/.claude/.reread-state/y"
  sed -n '/^is_owned/,/^}/p' "$HOOKS_DIR/trellis-worktree-remove.sh" > "$BATS_TEST_TMPDIR/is_owned-l10.sh"
  # shellcheck disable=SC1090
  . "$BATS_TEST_TMPDIR/is_owned-l10.sh"
  run is_owned "$wt" ".claude" ".claude"
  [ "$status" -eq 0 ]
  rm -rf "$wt"
}

@test "sweep-fx1-R2-L5: only Trellis-written session files and Codex review markers are exempt" {
  local wt="$BATS_TEST_TMPDIR/wt-r2-l5"
  rm -rf "$wt"
  mkdir -p "$wt/.claude" "$wt/.codex"
  printf '4\n' > "$wt/.claude/session-autonomy"
  printf 'x\n' > "$wt/.claude/session-surgical"
  printf 'x' > "$wt/.codex/.review-done-abc123"
  sed -n '/^is_owned/,/^}/p' "$HOOKS_DIR/trellis-worktree-remove.sh" > "$BATS_TEST_TMPDIR/is_owned-r2-l5.sh"
  # shellcheck disable=SC1090
  . "$BATS_TEST_TMPDIR/is_owned-r2-l5.sh"
  run is_owned "$wt" ".claude" ".claude"
  [ "$status" -eq 0 ]
  run is_owned "$wt" ".codex" ".codex"
  [ "$status" -eq 0 ]
  # A user's own session-* file is not Trellis state.
  printf 'notes\n' > "$wt/.claude/session-notes.md"
  run is_owned "$wt" ".claude" ".claude"
  [ "$status" -eq 1 ]
  rm -rf "$wt"
}

@test "T49 qp-H1: a commit made during the detach invalidates the merge proof: tree and branch kept" {
  printf '.trellis-leaf\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  ln -s /payload/leaf "$WT/.trellis-leaf"
  owner_record "$WT" .trellis-leaf
  export DJ_MERGED_OVERRIDE=merged STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  # Unlike the raced-edit case, the raced commit leaves a clean tree.
  cat > "$SANDBOX/bin/trellis" <<STUB
#!/usr/bin/env bash
if [ "\$1" = detach ]; then
  rm -f "\$2/.trellis-leaf"
  printf 'raced-commit\\n' >> "\$2/README.md"
  git -C "\$2" add README.md
  git -C "\$2" commit -qm raced-after-merge-proof
fi
exit 0
STUB
  run_remove "$WT"

  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  [ -d "$WT" ]
  branch_exists worktree-feat1
  [ "$(git -C "$REPO" log -1 --format=%s worktree-feat1)" = raced-after-merge-proof ]
  [[ "$stderr" == *"no merged PR covers HEAD"* ]] || { echo "$stderr"; false; }
}

@test "T49 qp-H1: branch deletion is bound to the proven commit" {
  make_cc feat1
  export DJ_MERGED_OVERRIDE=merged STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  # git worktree remove is the last step before the branch delete: move the
  # branch there, as a concurrent writer could, and the delete must refuse.
  local real_git
  real_git="$(command -v git)"
  cat > "$SANDBOX/bin/git" <<STUB
#!/usr/bin/env bash
if [ "\$3" = worktree ] && [ "\$4" = remove ]; then
  "$real_git" "\$@" || exit \$?
  "$real_git" -C "$REPO" branch -f worktree-feat1 "\$("$real_git" -C "$REPO" commit-tree -p "$STUB_GH_HEAD" -m moved "$STUB_GH_HEAD^{tree}")"
  exit 0
fi
exec "$real_git" "\$@"
STUB
  chmod 755 "$SANDBOX/bin/git"
  run_remove "$WT"
  rm -f "$SANDBOX/bin/git"

  path_missing "$WT"
  branch_exists worktree-feat1
  [ "$(git -C "$REPO" log -1 --format=%s worktree-feat1)" = moved ]
}

@test "T49 qp-H2: a failed ownership walk never classifies a directory as owned" {
  local wt="$BATS_TEST_TMPDIR/wt-find-fail"
  mkdir -p "$wt/.claude"
  printf 'irreplaceable\n' > "$wt/.claude/user-notes"
  sed -n '/^is_owned/,/^}/p' "$HOOKS_DIR/trellis-worktree-remove.sh" > "$BATS_TEST_TMPDIR/is_owned-find.sh"
  # shellcheck disable=SC1090
  . "$BATS_TEST_TMPDIR/is_owned-find.sh"
  printf '#!/bin/sh\necho "find: simulated inspection I/O error" >&2\nexit 1\n' > "$SANDBOX/bin/find"
  chmod 755 "$SANDBOX/bin/find"
  run is_owned "$wt" .claude ".claude/trellis.md"
  [ "$status" -ne 0 ]
  # A partial walk that fails after printing an owned path is still a failure.
  printf '#!/bin/sh\nprintf "%%s/.claude/trellis.md\\0" "%s"\nexit 1\n' "$wt" > "$SANDBOX/bin/find"
  run is_owned "$wt" .claude ".claude/trellis.md"
  [ "$status" -ne 0 ]
  rm -f "$SANDBOX/bin/find"
  # Control: the same owned leaf alone, walked successfully, is owned.
  rm -f "$wt/.claude/user-notes"
  : > "$wt/.claude/trellis.md"
  run is_owned "$wt" .claude ".claude/trellis.md"
  [ "$status" -eq 0 ]
}

@test "T49 qp-H2: an ignored user file survives a failed ownership walk" {
  printf '.claude/\n' >> "$REPO/.git/info/exclude"
  make_cc feat1
  mkdir -p "$WT/.claude"
  printf 'irreplaceable\n' > "$WT/.claude/user-notes"
  ln -s /payload/leaf "$WT/.claude/trellis.md"
  owner_record "$WT" .claude/trellis.md
  cat > "$SANDBOX/bin/trellis" <<'STUB'
#!/usr/bin/env bash
[ "$1" != detach ] || rm -f "$2/.claude/trellis.md"
exit 0
STUB
  export DJ_MERGED_OVERRIDE=merged STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  printf '#!/bin/sh\necho "find: simulated inspection I/O error" >&2\nexit 1\n' > "$SANDBOX/bin/find"
  chmod 755 "$SANDBOX/bin/find"
  run_remove "$WT"
  rm -f "$SANDBOX/bin/find"

  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  [ "$(cat "$WT/.claude/user-notes")" = irreplaceable ]
}

@test "T49 qp-H4: removal waits on a current foreground create sync and keeps the tree" {
  register_repo
  local path="$ROOT/myproj/cc-feat1" create_pid create_rc=0
  cat > "$SANDBOX/bin/trellis" <<STUB
#!/usr/bin/env bash
printf 'started\\n' > "$SANDBOX/sync-started"
while [ ! -e "$SANDBOX/release-sync" ]; do sleep 0.05; done
exit 0
STUB
  "$CREATE_HOOK" > "$SANDBOX/create.out" 2> "$SANDBOX/create.err" <<< "$(create_input feat1)" &
  create_pid=$!
  wait_for "$SANDBOX/sync-started"
  export TRELLIS_WORKTREE_SYNC_WAIT_S=1
  run_remove "$path"
  local remove_status="$status" remove_err="$stderr"
  touch "$SANDBOX/release-sync"
  wait "$create_pid" || create_rc=$?

  [ "$remove_status" -eq 1 ] || { echo "status $remove_status stderr: $remove_err"; false; }
  [[ "$remove_err" == *"create for this worktree is still in progress"* ]] || { echo "$remove_err"; false; }
  [ -d "$path" ]
  [ "$create_rc" -eq 0 ]
  [ "$(cat "$SANDBOX/create.out")" = "$path" ]
  # Once the create has finished, the same removal goes through.
  unset TRELLIS_WORKTREE_SYNC_WAIT_S
  export DJ_MERGED_OVERRIDE=unmerged
  run_remove "$path"
  [ "$status" -eq 0 ] || { echo "status $status stderr: $stderr"; false; }
  path_missing "$path"
}

@test "T49 qp-H4: a create that starts during a removal is refused, not interleaved" {
  make_cc feat1
  export DJ_MERGED_OVERRIDE=unmerged
  # Hold the removal inside its transaction (git status), then race a create.
  local real_git remove_pid remove_rc=0
  real_git="$(command -v git)"
  cat > "$SANDBOX/bin/git" <<STUB
#!/usr/bin/env bash
if [ "\$3" = status ] && [ ! -e "$SANDBOX/held" ]; then
  : > "$SANDBOX/held"
  printf 'held\\n' > "$SANDBOX/remove-held"
  while [ ! -e "$SANDBOX/release-remove" ]; do sleep 0.05; done
fi
exec "$real_git" "\$@"
STUB
  chmod 755 "$SANDBOX/bin/git"
  "$REMOVE_HOOK" > /dev/null 2> "$SANDBOX/remove.err" <<< "$(remove_input "$WT")" &
  remove_pid=$!
  wait_for "$SANDBOX/remove-held"
  run_create feat1
  local create_status="$status" create_out="$output" create_err="$stderr"
  touch "$SANDBOX/release-remove"
  wait "$remove_pid" || remove_rc=$?
  rm -f "$SANDBOX/bin/git"

  [ "$create_status" -ne 0 ] || { echo "create returned $create_out"; false; }
  [ -z "$create_out" ]
  [[ "$create_err" == *"creation already in progress"* ]] || { echo "$create_err"; false; }
  [ "$remove_rc" -eq 0 ] || { cat "$SANDBOX/remove.err"; false; }
  path_missing "$WT"
}

@test "lean-wt-remove: one gh query proves the merge of an unpushed worktree branch, and it still deletes only a proven branch" {
  make_cc feat1
  commit_in "$WT" local-only
  export STUB_GH_LOG="$SANDBOX/gh-calls" STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"

  [ "$status" -eq 0 ] || { echo "status $status stderr: $stderr"; false; }
  path_missing "$WT"
  branch_missing worktree-feat1
  # The hook's proof and finish's reuse of it: exactly one network call.
  [ "$(grep -c 'pr list' "$STUB_GH_LOG")" -eq 1 ] || { cat "$STUB_GH_LOG"; false; }
  [[ "$(cat "$STUB_GH_LOG")" == *"--head worktree-feat1 --state merged --json headRefOid"* ]] || { cat "$STUB_GH_LOG"; false; }
}

@test "lean-wt-remove: with no merged PR, or a failing gh, the single query proves nothing and the unpushed worktree is kept" {
  make_cc feat1
  commit_in "$WT" local-only
  export STUB_GH_LOG="$SANDBOX/gh-calls"
  run_remove "$WT"
  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  [ -d "$WT" ]
  branch_exists worktree-feat1
  [[ "$stderr" == *"no merged PR covers HEAD"* ]] || { echo "$stderr"; false; }

  export STUB_GH_FAIL=1 STUB_GH_HEAD
  STUB_GH_HEAD="$(git -C "$WT" rev-parse HEAD)"
  run_remove "$WT"
  [ "$status" -eq 1 ] || { echo "status $status stderr: $stderr"; false; }
  [ -d "$WT" ]
  branch_exists worktree-feat1
}
