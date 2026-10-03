#!/usr/bin/env bats
# Range derivation in the canonical pre-push: every pushed ref is judged by what
# the push adds, not by the branch's whole history. Both hook copies run.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ZERO=0000000000000000000000000000000000000000

setup() {
  REPO="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/repo"
  CAPTURE="$BATS_TEST_TMPDIR/runner.log"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email range@test.invalid
  git -C "$REPO" config user.name range-test
  mkdir -p "$REPO/.claude/skills/process-gate/scripts"
  cat > "$REPO/.claude/skills/process-gate/scripts/run-all.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PROCESS_GATE_CAPTURE"
exit 0
SH
  printf '/.claude/\n' > "$REPO/.git/info/exclude"
}

snap() {
  printf '%s\n' "$1" > "$REPO/$1.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}

# run_hook <hook> <stdin-lines> [env...]: runs the hook as git would, with the
# remote name as $1 and the ref lines on stdin.
run_hook() {
  local hook="$1" lines="$2"
  shift 2
  printf '%s\n' "$lines" > "$BATS_TEST_TMPDIR/refs"
  rm -f "$CAPTURE"
  run env PROCESS_GATE_CAPTURE="$CAPTURE" "$@" sh -c \
    'cd "$1" && sh "$2" origin https://example.invalid/repo.git < "$3"' \
    _ "$REPO" "$hook" "$BATS_TEST_TMPDIR/refs"
}

assert_args() {
  [ -f "$CAPTURE" ] || { printf 'runner never ran\n%s\n' "$output"; false; }
  [ "$(cat "$CAPTURE")" = "$1" ] || {
    printf 'expected: %s\nactual:   %s\n' "$1" "$(cat "$CAPTURE")"
    false
  }
}

for_each_hook() {
  local hook
  for hook in "$REPO_ROOT/core-rules/githooks/pre-push" "$REPO_ROOT/core-rules/husky/pre-push"; do
    "$@" "$hook"
  done
}

@test "a non-main branch update gates remote..local, not the branch history" {
  snap base >/dev/null
  git -C "$REPO" switch -qc feature
  old="$(snap old)"
  new="$(snap new)"
  check() {
    run_hook "$1" "refs/heads/feature $new refs/heads/feature $old"
    [ "$status" -eq 0 ]
    assert_args "--mode=push --range=$old..$new"
  }
  for_each_hook check
}

@test "a new branch gates from its merge-base with the remote's default branch" {
  # The default branch is neither main nor master, so it must be resolved
  # from refs/remotes/origin/HEAD rather than assumed.
  snap base >/dev/null
  git -C "$REPO" branch -m trunk
  fork="$(snap fork)"
  git -C "$REPO" update-ref refs/remotes/origin/trunk "$fork"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  snap trunk-later >/dev/null
  git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
  git -C "$REPO" switch -qc feature "$fork"
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature $ZERO"
    [ "$status" -eq 0 ]
    assert_args "--mode=push --range=$fork..$tip"
  }
  for_each_hook check
}

@test "a new branch falls back to origin/main when origin/HEAD is unset" {
  base="$(snap base)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature $ZERO"
    [ "$status" -eq 0 ]
    assert_args "--mode=push --range=$base..$tip"
  }
  for_each_hook check
}

@test "a new branch with no resolvable default branch derives no range" {
  snap base >/dev/null
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature $ZERO"
    [ "$status" -eq 0 ]
    assert_args "--mode=push"
  }
  for_each_hook check
}

@test "a remote tip missing locally derives no range (fail closed)" {
  snap base >/dev/null
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature 1111111111111111111111111111111111111111"
    [ "$status" -eq 0 ]
    assert_args "--mode=push"
  }
  for_each_hook check
}

@test "a main push is unchanged: blocked by policy, merge mode with remote..local when allowed" {
  old="$(snap base)"
  new="$(snap next)"
  check() {
    run_hook "$1" "refs/heads/main $new refs/heads/main $old"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Direct push to refs/heads/main blocked by Trellis policy"* ]]
    [ ! -f "$CAPTURE" ]

    run_hook "$1" "refs/heads/main $new refs/heads/main $old" TRELLIS_ALLOW_MAIN_PUSH=1
    [ "$status" -eq 0 ]
    assert_args "--mode=merge --range=$old..$new"
  }
  for_each_hook check
}

@test "a main-targeting ref's range wins over a branch pushed alongside it" {
  old="$(snap base)"
  new="$(snap next)"
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature $new
refs/heads/main $new refs/heads/main $old" TRELLIS_ALLOW_MAIN_PUSH=1
    [ "$status" -eq 0 ]
    assert_args "--mode=merge --range=$old..$new"
  }
  for_each_hook check
}

@test "two branches with different ranges fall back to run-all's default" {
  base="$(snap base)"
  git -C "$REPO" switch -qc one
  one="$(snap one)"
  git -C "$REPO" switch -qc two "$base"
  two="$(snap two)"
  check() {
    run_hook "$1" "refs/heads/one $one refs/heads/one $base
refs/heads/two $two refs/heads/two $base"
    [ "$status" -eq 0 ]
    assert_args "--mode=push"
    [[ "$output" == *"could not derive one range for every pushed ref"* ]]
  }
  for_each_hook check
}

@test "a deleted ref is skipped and does not widen the range" {
  old="$(snap base)"
  git -C "$REPO" switch -qc feature
  new="$(snap feature)"
  check() {
    run_hook "$1" "(delete) $ZERO refs/heads/gone $old
refs/heads/feature $new refs/heads/feature $old"
    [ "$status" -eq 0 ]
    assert_args "--mode=push --range=$old..$new"
  }
  for_each_hook check
}
