#!/usr/bin/env bats
# Regression coverage for the canonical suite's Git mutation boundary.
#
# This file never invokes the host Git binary. FAKE_GIT only records argv and
# answers the fence's read-only common-dir/per-worktree-git-dir probes; a
# delegated config/worktree/init command is observable without mutating a repo.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
FENCE="$REPO_ROOT/scripts/tests/helpers/git-fence/git"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  OUTSIDE_ROOT="$BATS_TEST_TMPDIR/operator-repo"
  FAKE_GIT="$BATS_TEST_TMPDIR/fake-git"
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  mkdir -p "$FIXTURE_ROOT" "$OUTSIDE_ROOT"
  : > "$GIT_LOG"

  cat > "$FAKE_GIT" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FENCE_GIT_LOG"
case " $* " in
  *" rev-parse --path-format=absolute --git-common-dir "*)
    [ "${FENCE_FAKE_NO_COMMON:-0}" = "1" ] && exit 128
    printf '%s\n' "$FENCE_FAKE_COMMON_DIR"
    ;;
  *" rev-parse --path-format=absolute --absolute-git-dir "*)
    printf '%s\n' "$FENCE_FAKE_COMMON_DIR"
    ;;
esac
exit 0
SH
  chmod 755 "$FAKE_GIT"
}

run_fence() {
  run env \
    TRELLIS_TEST_GIT_FENCE_ROOT="$FIXTURE_ROOT" \
    TRELLIS_TEST_REAL_GIT="$FAKE_GIT" \
    FENCE_GIT_LOG="$GIT_LOG" \
    FENCE_FAKE_COMMON_DIR="$FENCE_FAKE_COMMON_DIR" \
    FENCE_FAKE_NO_COMMON="${FENCE_FAKE_NO_COMMON:-0}" \
    GIT_DIR="${FENCE_INHERITED_GIT_DIR:-}" \
    "$FENCE" "$@"
}

@test "config write routed to a common dir outside the fixture is refused" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" config user.name Fixture

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"outside test root"* ]] || { echo "$output"; false; }
  # The inherited outside route is rejected before even an identity probe.
  [ ! -s "$GIT_LOG" ]
  ! grep -F ' config user.name Fixture' "$GIT_LOG"

  # An explicit file destination cannot hide an outside CLI repository route.
  FENCE_INHERITED_GIT_DIR=""
  run_fence --git-dir="$OUTSIDE_ROOT/shared.git" -C "$FIXTURE_ROOT/repo" \
    config --file "$FIXTURE_ROOT/local.config" user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"routed Git directory"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]

  # Object-store writers are mutations even though they do not move refs.
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"
  run_fence -C "$FIXTURE_ROOT/repo" hash-object -w --stdin
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  run_fence -C "$FIXTURE_ROOT/repo" write-tree
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
}

@test "worktree remove routed to a common dir outside the fixture is refused" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" worktree remove "$OUTSIDE_ROOT/live-worktree"

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"git worktree remove"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  ! grep -F ' worktree remove ' "$GIT_LOG"
}

@test "clean pathspec named -n cannot disguise an outside destructive clean" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" clean -fd -- -n

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"git clean"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  ! grep -F ' clean -fd -- -n' "$GIT_LOG"
}

@test "clean long option containing n is not mistaken for dry-run" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" clean -fd --exclude=node_modules

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"git clean"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  ! grep -F ' clean -fd --exclude=node_modules' "$GIT_LOG"
}

@test "bare init redirected outside by inherited GIT_DIR is refused before Git runs" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  # The CLI destination is inside the fixture. The inherited route is the bug:
  # old behavior ignored this safe-looking path and reinitialized shared.git.
  run_fence init --bare "$FIXTURE_ROOT/origin.git"

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"routed Git directory"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
}

@test "mutation with a fenced common dir or unresolved fenced destination reaches only the fake backend" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"

  run_fence -C "$FIXTURE_ROOT/repo" config user.name Fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 4 ]
  grep -F -- "-C $FIXTURE_ROOT/repo config user.name Fixture" "$GIT_LOG" >/dev/null

  # A just-created fixture may not have a common dir yet. The canonical -C
  # destination is inside the fence, so this is safe rather than unprovable.
  : > "$GIT_LOG"
  FENCE_FAKE_NO_COMMON=1
  run_fence -C "$FIXTURE_ROOT/repo" config user.email fixture@trellis.invalid

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 2 ]
  grep -F -- "-C $FIXTURE_ROOT/repo config user.email fixture@trellis.invalid" "$GIT_LOG" >/dev/null

  # archive and hash-object without -w do not mutate repository state.
  : > "$GIT_LOG"
  FENCE_FAKE_NO_COMMON=0
  run_fence -C "$FIXTURE_ROOT/repo" archive HEAD
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT/repo" hash-object --stdin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 2 ]

  # hash-object -w and write-tree write objects, so they require repository
  # identity proof even though neither updates refs, config, or the worktree.
  : > "$GIT_LOG"
  run_fence -C "$FIXTURE_ROOT/repo" hash-object -w --stdin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT/repo" write-tree
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 8 ]
}
