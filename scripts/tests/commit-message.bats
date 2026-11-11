#!/usr/bin/env bats

ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  PROJECT="$BATS_TEST_TMPDIR/project"
  MESSAGE="$BATS_TEST_TMPDIR/message"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" config user.name Fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" commit --allow-empty -qm 'fix: target subject'
  TARGET="$(git -C "$PROJECT" rev-parse HEAD)"
}

check_all() {
  local expected="$1" checker
  for checker in "$ROOT/scripts/check-commit-message.sh" \
    "$ROOT/core-rules/githooks/commit-msg" "$ROOT/core-rules/husky/commit-msg"; do
    run bash -c 'cd "$1" && "$2" "$3"' fixture "$PROJECT" "$checker" "$MESSAGE"
    [ "$status" -eq "$expected" ] || { echo "$checker returned $status: $output"; false; }
  done
}

@test "Merge exemption requires the active merge and its generated message" {
  printf 'Merge arbitrary authored subject\n' > "$MESSAGE"
  check_all 1
  git -C "$PROJECT" switch -qc feature
  git -C "$PROJECT" commit --allow-empty -qm 'feat: feature'
  git -C "$PROJECT" switch -q main
  git -C "$PROJECT" merge --no-commit --no-ff feature >/dev/null
  cp "$PROJECT/.git/MERGE_MSG" "$MESSAGE"
  check_all 0
  printf 'Merge unrelated authored subject\n' > "$MESSAGE"
  check_all 1
}

@test "Revert exemption requires a standard header and verified context" {
  printf 'Revert "fix: target subject"\n' > "$MESSAGE"
  check_all 1
  printf 'Revert "fix: target subject"\n\nThis reverts commit %s.\n' "$TARGET" > "$MESSAGE"
  check_all 0
  printf 'Revert "fix: target subject"\n\nThis reverts commit deadbeef.\n' > "$MESSAGE"
  check_all 1
  printf '%s\n' "$TARGET" > "$PROJECT/.git/REVERT_HEAD"
  printf 'Revert "fix: target subject"\n' > "$MESSAGE"
  check_all 0
}

check_autosquash() {
  local prefix="$1"
  printf '%s missing target\n' "$prefix" > "$MESSAGE"
  check_all 1
  printf '%s fix: target subject\n' "$prefix" > "$MESSAGE"
  check_all 0
}

@test "fixup exemption requires an existing target subject" {
  check_autosquash 'fixup!'
}

@test "squash exemption requires an existing target subject" {
  check_autosquash 'squash!'
}

@test "amend exemption requires an existing target subject" {
  check_autosquash 'amend!'
}

@test "Applying exemption requires an active git am operation" {
  printf 'Applying patch subject\n' > "$MESSAGE"
  check_all 1
  mkdir -p "$PROJECT/.git/rebase-apply"
  printf '1\n' > "$PROJECT/.git/rebase-apply/applying"
  check_all 0
}

@test "real Git merge revert and autosquash commits work through each hook" {
  local checker repo hook_dir target subject index=0
  for checker in "$ROOT/scripts/check-commit-message.sh" \
    "$ROOT/core-rules/githooks/commit-msg" "$ROOT/core-rules/husky/commit-msg"; do
    index=$((index + 1))
    repo="$BATS_TEST_TMPDIR/integration-$index"
    hook_dir="$repo/hooks"
    mkdir -p "$hook_dir"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.name Fixture
    git -C "$repo" config user.email fixture@example.invalid
    cp "$checker" "$hook_dir/commit-msg"
    chmod +x "$hook_dir/commit-msg"
    git -C "$repo" config core.hooksPath "$hook_dir"
    git -C "$repo" commit --allow-empty -qm 'fix: base'
    git -C "$repo" switch -qc feature
    printf 'feature\n' > "$repo/feature.txt"
    git -C "$repo" add feature.txt
    git -C "$repo" commit -qm 'feat: feature'
    target="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" switch -q main
    run git -C "$repo" merge --no-ff -qm 'Merge feature: genuine merge' feature
    [ "$status" -eq 0 ] || { echo "$checker merge failed: $output"; false; }
    run git -C "$repo" revert --no-edit "$target"
    [ "$status" -eq 0 ] || { echo "$checker revert failed: $output"; false; }
    run git -C "$repo" commit --allow-empty --fixup "$target" -q
    [ "$status" -eq 0 ] || { echo "$checker fixup failed: $output"; false; }
    subject="$(git -C "$repo" log -1 --format=%s)"
    [ "$subject" = 'fixup! feat: feature' ] || { echo "$subject"; false; }
  done
}

@test "installed commitlint cannot bypass special-header context checks" {
  mkdir -p "$PROJECT/node_modules/.bin"
  printf '#!/bin/sh\nprintf invoked > "%s"\nexit 0\n' "$BATS_TEST_TMPDIR/commitlint-ran" > "$PROJECT/node_modules/.bin/commitlint"
  chmod +x "$PROJECT/node_modules/.bin/commitlint"
  printf 'Merge invented subject\n' > "$MESSAGE"
  check_all 1
  [ ! -e "$BATS_TEST_TMPDIR/commitlint-ran" ]
  printf 'fix: normal subject\n' > "$MESSAGE"
  check_all 0
  [ -e "$BATS_TEST_TMPDIR/commitlint-ran" ]
}

@test "ordinary conventional subjects still pass outside Git" {
  PROJECT="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$PROJECT"
  printf 'fix: a normal conventional subject\n' > "$MESSAGE"
  check_all 0
  printf 'Merge invented subject\n' > "$MESSAGE"
  check_all 1
}
