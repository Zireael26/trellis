#!/usr/bin/env bats
# Range derivation in the canonical pre-push: every pushed ref is judged by what
# the push adds, not by the branch's whole history. Both hook copies run.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ZERO=0000000000000000000000000000000000000000

setup() {
  unset PG_PUSH_TEST_SCOPE
  REPO="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/repo"
  CAPTURE="$BATS_TEST_TMPDIR/runner.log"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email range@test.invalid
  git -C "$REPO" config user.name range-test
  mkdir -p "$REPO/.claude/skills/process-gate/scripts/lib" || return 1
  cp "$REPO_ROOT/core-rules/skills/process-gate/scripts/lib/diff-base.sh" \
    "$REPO/.claude/skills/process-gate/scripts/lib/" || return 1
  cat > "$REPO/.claude/skills/process-gate/scripts/run-all.sh" <<'SH'
#!/usr/bin/env bash
# Append: a tag-only push gates each tag range in turn, so every invocation
# must be recorded. run_hook removes the file before each run, so single-call
# scenarios still assert exact single-line equality below. The hook refuses a
# passing rc without exactly one Overall line in one verdict block.
printf '%s\n' "$*" >> "$PROCESS_GATE_CAPTURE"
printf '%s\n' "${PG_PUSH_TEST_SCOPE:-unset}" >> "$PROCESS_GATE_CAPTURE.scope"
printf '## process-gate verdict (mode=push)\n\nOverall: MERGEABLE\n'
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
  rm -f "$CAPTURE" "$CAPTURE.scope"
  run env PROCESS_GATE_CAPTURE="$CAPTURE" "$@" sh -c \
    'cd "$1" && sh "$2" origin https://example.invalid/repo.git < "$3"' \
    _ "$REPO" "$hook" "$BATS_TEST_TMPDIR/refs"
}

assert_args() {
  [ -f "$CAPTURE" ] || { printf 'runner never ran\n%s\n' "$output"; false; }
  local expected="$1"
  if grep -q ' refs/tags/' "$BATS_TEST_TMPDIR/refs"; then
    expected="${expected//--mode=push/--mode=push --tag-push}"
  fi
  [ "$(cat "$CAPTURE")" = "$expected" ] || {
    printf 'expected: %s\nactual:   %s\n' "$expected" "$(cat "$CAPTURE")"
    false
  }
}

for_each_hook() {
  local hook
  for hook in "$REPO_ROOT/core-rules/githooks/pre-push" "$REPO_ROOT/core-rules/husky/pre-push"; do
    "$@" "$hook" || return 1
  done
}

@test "a non-main branch update gates remote..local, not the branch history" {
  snap base >/dev/null
  git -C "$REPO" switch -qc feature
  old="$(snap old)"
  new="$(snap new)"
  check() {
    run_hook "$1" "refs/heads/feature $new refs/heads/feature $old" PG_PUSH_TEST_SCOPE=full
    [ "$status" -eq 0 ]
    assert_args "--mode=push --range=$old..$new"
    [ "$(tail -n 1 "$CAPTURE.scope")" = branch ]
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

@test "a new branch with no resolvable remote default refuses with the remote-default message" {
  snap base >/dev/null
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature $ZERO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"remote default does not resolve"* ]] || { echo "$output"; false; }
    [[ "$output" == *"git remote set-head"* ]] || { echo "$output"; false; }
    [ ! -f "$CAPTURE" ]
  }
  for_each_hook check
}

@test "a branch update whose remote tip is missing locally refuses before run-all (R33)" {
  snap base >/dev/null
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature 1111111111111111111111111111111111111111"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"cannot derive the range for refs/heads/feature: its remote tip is not local; fetch first"* ]] || { echo "$output"; return 1; }
    [ ! -f "$CAPTURE" ] || { echo "run-all ran: $(cat "$CAPTURE")"; return 1; }
  }
  for_each_hook check
}

@test "a notes ref update with a tag is refused before any runner; a notes delete passes (R34)" {
  new="$(snap base)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$new"
  check() {
    run_hook "$1" "refs/notes/x $new refs/notes/x $ZERO
refs/tags/v9.9.9 $new refs/tags/v9.9.9 $ZERO"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"unsupported ref refs/notes/x: push branches or tags only"* ]] || { echo "$output"; return 1; }
    [ ! -f "$CAPTURE" ] || { echo "run-all ran: $(cat "$CAPTURE")"; return 1; }
    run_hook "$1" "(delete) $ZERO refs/notes/x $new"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -f "$CAPTURE" ] || { echo "run-all ran: $(cat "$CAPTURE")"; return 1; }
  }
  for_each_hook check
}

@test "a new branch with no merge-base with the remote default refuses before any runner" {
  git -C "$REPO" update-ref refs/remotes/origin/main "$(snap base)"
  git -C "$REPO" switch -q --orphan stray
  tip="$(snap stray)"
  check() {
    run_hook "$1" "refs/heads/stray $tip refs/heads/stray $ZERO"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"cannot derive the range for refs/heads/stray: no merge-base with the remote default"* ]] || { echo "$output"; return 1; }
    [ ! -f "$CAPTURE" ] || { echo "run-all ran: $(cat "$CAPTURE")"; return 1; }
  }
  for_each_hook check
}

@test "a deletes-only push gates nothing and never runs run-all on a default range" {
  old="$(snap base)"
  check() {
    run_hook "$1" "(delete) $ZERO refs/heads/gone $old"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"no new commits to gate (deletes only)."* ]] || { echo "$output"; return 1; }
    [ ! -f "$CAPTURE" ] || { echo "run-all ran: $(cat "$CAPTURE")"; return 1; }
  }
  for_each_hook check
}

@test "R36: empty stdin (no ref lines) runs run-all on push defaults, as main does" {
  snap base >/dev/null
  check() { rm -f "$CAPTURE"; run env PROCESS_GATE_CAPTURE="$CAPTURE" sh -c 'cd "$1" && sh "$2" origin x </dev/null' _ "$REPO" "$1"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }; assert_args "--mode=push"; }
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

    run_hook "$1" "refs/heads/main $new refs/heads/main $old" TRELLIS_ALLOW_MAIN_PUSH=1 PG_PUSH_TEST_SCOPE=full
    [ "$status" -eq 0 ]
    assert_args "--mode=merge --range=$old..$new --target=main"
    [ "$(tail -n 1 "$CAPTURE.scope")" = unset ]
  }
  for_each_hook check
}

# R38 replaces "main's range wins": the feature's own commits went ungated.
@test "R38: a main push beside a branch or master with a different range refuses before run-all" {
  old="$(snap base)"
  new="$(snap next)"
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature $new
refs/heads/main $new refs/heads/main $old" TRELLIS_ALLOW_MAIN_PUSH=1
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"derive different ranges"*"Push branches one at a time"* ]] || { echo "$output"; return 1; }
    [ ! -f "$CAPTURE" ] || { echo "run-all ran: $(cat "$CAPTURE")"; return 1; }
    run_hook "$1" "refs/heads/main $new refs/heads/main $old
refs/heads/master $tip refs/heads/master $new" TRELLIS_ALLOW_MAIN_PUSH=1
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [ ! -f "$CAPTURE" ] || { echo "run-all ran: $(cat "$CAPTURE")"; return 1; }
  }
  for_each_hook check
}

@test "R38: a main push beside a branch on the same range gates it once in merge mode" {
  old="$(snap base)"
  new="$(snap next)"
  check() {
    run_hook "$1" "refs/heads/feature $new refs/heads/feature $old
refs/heads/main $new refs/heads/main $old" TRELLIS_ALLOW_MAIN_PUSH=1
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    assert_args "--mode=merge --range=$old..$new --target=main"
  }
  for_each_hook check
}

@test "two branch updates with different ranges refuse with the branches message" {
  base="$(snap base)"
  git -C "$REPO" switch -qc one
  one="$(snap one)"
  git -C "$REPO" switch -qc two "$base"
  two="$(snap two)"
  check() {
    run_hook "$1" "refs/heads/one $one refs/heads/one $base
refs/heads/two $two refs/heads/two $base"
    [ "$status" -eq 1 ]
    [[ "$output" == *"two or more branch updates derive different ranges"* ]] || { echo "$output"; false; }
    [[ "$output" == *"Push branches one at a time"* ]] || { echo "$output"; false; }
    [ ! -f "$CAPTURE" ]
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

@test "a tag on the pushed branch tip needs only the branch gate" {
  base="$(snap base)"
  git -C "$REPO" switch -qc feature
  tip="$(snap feature)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  git -C "$REPO" tag v1.2.3 "$tip"
  check() {
    run_hook "$1" "refs/tags/v1.2.3 $tip refs/tags/v1.2.3 $ZERO
refs/heads/feature $tip refs/heads/feature $base" PG_PUSH_TEST_SCOPE=branch
    [ "$status" -eq 0 ] || return 1
    assert_args "--mode=push --range=$base..$tip" || return 1
    [ "$(cat "$CAPTURE.scope")" = full ]
  }
  for_each_hook check || return 1
}

@test "a merged annotated tag-only push still gates its derived range" {
  base="$(snap base)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  tagsha="$(snap tagged)"
  git -C "$REPO" tag -am merged v9.9.9 "$tagsha"
  git -C "$REPO" update-ref refs/remotes/origin/main "$tagsha"
  tagobject="$(git -C "$REPO" rev-parse v9.9.9)"
  check() {
    run_hook "$1" "refs/tags/v9.9.9 $tagobject refs/tags/v9.9.9 $ZERO" PG_PUSH_TEST_SCOPE=branch
    [ "$status" -eq 0 ] || return 1
    assert_args "--mode=push --range=$tagsha..$tagobject" || return 1
    [ "$(cat "$CAPTURE.scope")" = full ]
  }
  for_each_hook check || return 1
}

@test "two off-main tags gate each range in turn" {
  base="$(snap base)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  t1="$(snap tagone)"
  t2="$(snap tagtwo)"
  git -C "$REPO" tag v1.0.0 "$t1"
  git -C "$REPO" tag v2.0.0 "$t2"
  check() {
    run_hook "$1" "refs/tags/v1.0.0 $t1 refs/tags/v1.0.0 $ZERO
refs/tags/v2.0.0 $t2 refs/tags/v2.0.0 $ZERO"
    [ "$status" -eq 0 ] || return 1
    # The stub appends every invocation in push order: both tag ranges must
    # have been gated. Gating only the final tag (one line), a single union
    # range, or a bare push all fail this equality.
    [ "$(cat "$CAPTURE")" = "--mode=push --tag-push --range=$base..$t1
--mode=push --tag-push --range=$base..$t2" ] || {
      printf 'expected two gated ranges, got:\n%s\n' "$(cat "$CAPTURE")"
      return 1
    }
  }
  for_each_hook check || return 1
}

@test "a payload tag-only push gates exactly parent..tag, even off main" {
  parent="$(snap parent)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$parent"
  git -C "$REPO" switch -qc payload
  payload="$(snap payload)"
  git -C "$REPO" tag -am payload v7.7.7 "$payload"
  tagobject="$(git -C "$REPO" rev-parse v7.7.7)"
  check() {
    run_hook "$1" "refs/tags/v7.7.7 $tagobject refs/tags/v7.7.7 $ZERO"
    [ "$status" -eq 0 ] || return 1
    assert_args "--mode=push --range=$parent..$tagobject" || return 1
    [ "$(git -C "$REPO" rev-list "$parent..$tagobject")" = "$payload" ] || return 1
  }
  for_each_hook check || return 1
}

@test "a tag outside the pushed branch is gated alongside the branch" {
  base="$(snap base)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  tagsha="$(snap unmerged)"
  git -C "$REPO" switch -qc feature "$base"
  tip="$(snap feature)"
  check() {
    run_hook "$1" "refs/tags/outside $tagsha refs/tags/outside $ZERO
refs/heads/feature $tip refs/heads/feature $base"
    [ "$status" -eq 0 ] || return 1
    assert_args "--mode=push --range=$base..$tip
--mode=push --range=$base..$tagsha" || return 1
  }
  for_each_hook check || return 1
}

@test "a merged tag-only push with an underivable range refuses before run-all" {
  tip="$(snap merged)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$tip"
  check() {
    run_hook "$1" "refs/tags/merged $tip refs/tags/merged $ZERO
refs/tags/underivable $tip refs/tags/underivable 1111111111111111111111111111111111111111"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"underivable"*"range cannot be derived"* ]] || return 1
    [ ! -f "$CAPTURE" ] || return 1
  }
  for_each_hook check || return 1
}

@test "an underivable tag alongside a branch refuses before either gate" {
  base="$(snap base)"
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  tip="$(snap tip)"
  check() {
    run_hook "$1" "refs/heads/feature $tip refs/heads/feature $base
refs/tags/underivable $tip refs/tags/underivable 1111111111111111111111111111111111111111"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"underivable"*"range cannot be derived"* ]] || return 1
    [ ! -f "$CAPTURE" ] || return 1
  }
  for_each_hook check || return 1
}

@test "a new tag with no resolvable remote default refuses without a checkout scan" {
  tip="$(snap tip)"
  check() {
    run_hook "$1" "refs/tags/no-default $tip refs/tags/no-default $ZERO"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"range cannot be derived"*"git remote set-head"* ]] || return 1
    [ ! -f "$CAPTURE" ] || return 1
  }
  for_each_hook check || return 1
}
