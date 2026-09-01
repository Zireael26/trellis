#!/usr/bin/env bats
# Hermetic coverage for scripts/install-commit-hooks.sh. Explicit installations
# use destinations below $BATS_TEST_TMPDIR. Default-resolution cases build both
# the repository and linked worktree below scratch and refuse common-hook writes.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/install-commit-hooks.sh"

setup() {
  SOURCE_ROOT="$BATS_TEST_TMPDIR/extracted revision"
  mkdir -p "$SOURCE_ROOT"
}

seed_revision_source() {
  printf '%s\n' 'commit-msg from extracted revision' > "$SOURCE_ROOT/commit-msg"
  printf '%s\n' 'pre-commit from extracted revision' > "$SOURCE_ROOT/pre-commit"
  printf '%s\n' 'pre-push must never be installed' > "$SOURCE_ROOT/pre-push"
  printf '%s\n' 'unrelated extracted-revision file' > "$SOURCE_ROOT/README"
  chmod 640 "$SOURCE_ROOT/commit-msg" "$SOURCE_ROOT/pre-commit"
  chmod 755 "$SOURCE_ROOT/pre-push" "$SOURCE_ROOT/README"
}

seed_git_fixture() {
  GIT_FIXTURE="$BATS_TEST_TMPDIR/main checkout"
  LINKED_WORKTREE="$BATS_TEST_TMPDIR/linked worktree"
  mkdir -p "$GIT_FIXTURE/scripts"
  cp "$INSTALLER" "$GIT_FIXTURE/scripts/install-commit-hooks.sh"
  cp -R "$REPO_ROOT/.husky" "$GIT_FIXTURE/"
  chmod 755 "$GIT_FIXTURE/scripts/install-commit-hooks.sh" \
    "$GIT_FIXTURE/.husky/commit-msg" "$GIT_FIXTURE/.husky/pre-commit"

  (
    cd "$GIT_FIXTURE" || exit 1
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git init -q
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      git add scripts/install-commit-hooks.sh .husky
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_AUTHOR_NAME='installer fixture' \
      GIT_AUTHOR_EMAIL='installer-fixture@example.invalid' \
      GIT_COMMITTER_NAME='installer fixture' \
      GIT_COMMITTER_EMAIL='installer-fixture@example.invalid' \
      git commit -qm 'installer fixture'
  )
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -C "$GIT_FIXTURE" worktree add -q "$LINKED_WORKTREE" HEAD

  GIT_FIXTURE="$(CDPATH='' cd -- "$GIT_FIXTURE" && pwd -P)"
  LINKED_WORKTREE="$(CDPATH='' cd -- "$LINKED_WORKTREE" && pwd -P)"
}

make_failing_mkdir() {
  local fake_bin="$BATS_TEST_TMPDIR/failing mutation bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/mkdir" <<'SH'
#!/bin/sh
if [ ! -s "$TRELLIS_INSTALLER_ANNOUNCEMENT_LOG" ]; then
  printf '%s\n' 'announcement missing before mkdir' > "$TRELLIS_INSTALLER_MUTATION_LOG"
  exit 84
fi
printf '%s\n' 'mkdir' > "$TRELLIS_INSTALLER_MUTATION_LOG"
exit 83
SH
  chmod 755 "$fake_bin/mkdir"
  printf '%s\n' "$fake_bin"
}

file_mode() {
  local candidate
  candidate="$(stat -f '%Lp' "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c '%a' "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

make_git_probe() {
  local fake_bin="$BATS_TEST_TMPDIR/fake git bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$TRELLIS_INSTALLER_GIT_MARKER"
exit 97
SH
  chmod 755 "$fake_bin/git"
  printf '%s\n' "$fake_bin"
}

@test "explicit scratch install honors extracted source and installs only the two supported hooks" {
  local destination="$BATS_TEST_TMPDIR/installed hooks"
  local git_marker="$BATS_TEST_TMPDIR/git lookup marker"
  local fake_bin hook installed_names installed_path first_line

  seed_revision_source
  fake_bin="$(make_git_probe)"
  cd "$BATS_TEST_TMPDIR"

  run env \
    TRELLIS_HOOK_SOURCE_ROOT="$SOURCE_ROOT" \
    TRELLIS_INSTALLER_GIT_MARKER="$git_marker" \
    PATH="$fake_bin:/usr/bin:/bin" \
    /bin/bash "$INSTALLER" "$destination"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  first_line="${output%%$'\n'*}"
  [ "$first_line" = "install-commit-hooks: destination: $destination" ]
  [ -d "$destination" ]
  [ ! -e "$git_marker" ]

  installed_names="$(
    for installed_path in "$destination"/*; do
      [ -e "$installed_path" ] || continue
      printf '%s\n' "${installed_path##*/}"
    done | LC_ALL=C sort
  )"
  [ "$installed_names" = $'commit-msg\npre-commit' ]

  for hook in commit-msg pre-commit; do
    [ -f "$destination/$hook" ]
    [ -x "$destination/$hook" ]
    [ "$(file_mode "$destination/$hook")" = 755 ]
    cmp -s "$SOURCE_ROOT/$hook" "$destination/$hook" || {
      echo "$hook is not byte-identical to the selected source root"
      false
    }
  done

  [ -f "$SOURCE_ROOT/pre-push" ]
  [ ! -e "$destination/pre-push" ]
  [ ! -e "$destination/README" ]
}

@test "source validation completes before creating an explicit destination" {
  local incomplete_source="$BATS_TEST_TMPDIR/incomplete extracted revision"
  local destination_parent="$BATS_TEST_TMPDIR/destination parent"
  local destination="$destination_parent/hooks"
  local git_marker="$BATS_TEST_TMPDIR/invalid-source git lookup marker"
  local fake_bin

  mkdir -p "$incomplete_source"
  printf '%s\n' 'only commit-msg is present' > "$incomplete_source/commit-msg"
  chmod 640 "$incomplete_source/commit-msg"
  [ ! -e "$destination_parent" ]

  fake_bin="$(make_git_probe)"
  cd "$BATS_TEST_TMPDIR"
  run env \
    TRELLIS_HOOK_SOURCE_ROOT="$incomplete_source" \
    TRELLIS_INSTALLER_GIT_MARKER="$git_marker" \
    PATH="$fake_bin:/usr/bin:/bin" \
    /bin/bash "$INSTALLER" "$destination"

  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [ ! -e "$destination_parent" ]
  [ ! -e "$destination" ]
  [ ! -e "$destination/commit-msg" ]
  [ ! -e "$git_marker" ]
}

@test "zero-argument install refuses a linked worktree before writing hooks" {
  local destination worktree first_line

  seed_git_fixture
  destination="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -C "$LINKED_WORKTREE" rev-parse --git-path hooks)"
  worktree="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -C "$LINKED_WORKTREE" rev-parse --show-toplevel)"
  [ ! -e "$destination/commit-msg" ]
  [ ! -e "$destination/pre-commit" ]
  cd "$LINKED_WORKTREE"

  run env \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    TRELLIS_HOOK_SOURCE_ROOT="$LINKED_WORKTREE/.husky" \
    PATH="/usr/bin:/bin" \
    /bin/bash "$LINKED_WORKTREE/scripts/install-commit-hooks.sh"

  [ "$status" -ne 0 ] || { echo "$output"; false; }
  first_line="${output%%$'\n'*}"
  [ "$first_line" = "install-commit-hooks: destination: $destination" ]
  case "$output" in
    *"$destination"*) ;;
    *) echo "$output"; false ;;
  esac
  case "$output" in
    *"$worktree"*) ;;
    *) echo "$output"; false ;;
  esac
  case "$output" in
    *'rerun from the main checkout or pass an explicit destination'*) ;;
    *) echo "$output"; false ;;
  esac
  [ ! -e "$destination/commit-msg" ]
  [ ! -e "$destination/pre-commit" ]
  [ ! -e "$destination/pre-push" ]
}

@test "destination announcement precedes the first mutation attempt" {
  local destination="$BATS_TEST_TMPDIR/announced hooks"
  local announcement_log="$BATS_TEST_TMPDIR/installer announcement"
  local mutation_log="$BATS_TEST_TMPDIR/first mutation"
  local fake_bin

  seed_revision_source
  fake_bin="$(make_failing_mkdir)"
  cd "$BATS_TEST_TMPDIR"

  run env \
    TRELLIS_HOOK_SOURCE_ROOT="$SOURCE_ROOT" \
    TRELLIS_INSTALLER_ANNOUNCEMENT_LOG="$announcement_log" \
    TRELLIS_INSTALLER_MUTATION_LOG="$mutation_log" \
    PATH="$fake_bin:/usr/bin:/bin" \
    /bin/bash -c \
      'exec /bin/bash "$1" "$2" >"$3"' \
      installer-mutation "$INSTALLER" "$destination" "$announcement_log"

  [ "$status" -eq 83 ] || { echo "$output"; false; }
  [ "$(cat "$announcement_log")" = "install-commit-hooks: destination: $destination" ]
  [ "$(cat "$mutation_log")" = 'mkdir' ]
  [ ! -e "$destination/commit-msg" ]
  [ ! -e "$destination/pre-commit" ]
}

@test "explicit destination succeeds from a linked worktree without Git lookup" {
  local destination_relative='explicit hooks'
  local destination
  local git_marker="$BATS_TEST_TMPDIR/explicit linked git lookup marker"
  local fake_bin hook first_line installed_names installed_path

  seed_git_fixture
  printf '%s\n' 'pre-push must never be installed' > "$LINKED_WORKTREE/.husky/pre-push"
  destination="$LINKED_WORKTREE/$destination_relative"
  fake_bin="$(make_git_probe)"
  cd "$LINKED_WORKTREE"

  run env \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    TRELLIS_HOOK_SOURCE_ROOT="$LINKED_WORKTREE/.husky" \
    TRELLIS_INSTALLER_GIT_MARKER="$git_marker" \
    PATH="$fake_bin:/usr/bin:/bin" \
    /bin/bash "$LINKED_WORKTREE/scripts/install-commit-hooks.sh" "$destination_relative"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  first_line="${output%%$'\n'*}"
  [ "$first_line" = "install-commit-hooks: destination: $destination" ]
  [ ! -e "$git_marker" ]
  [ -d "$destination" ]

  installed_names="$(
    for installed_path in "$destination"/*; do
      [ -e "$installed_path" ] || continue
      printf '%s\n' "${installed_path##*/}"
    done | LC_ALL=C sort
  )"
  [ "$installed_names" = $'commit-msg\npre-commit' ]

  for hook in commit-msg pre-commit; do
    [ -f "$destination/$hook" ]
    [ -x "$destination/$hook" ]
    [ "$(file_mode "$destination/$hook")" = 755 ]
    cmp -s "$LINKED_WORKTREE/.husky/$hook" "$destination/$hook" || {
      echo "$hook is not byte-identical to the linked-worktree source"
      false
    }
  done
  [ -f "$LINKED_WORKTREE/.husky/pre-push" ]
  [ ! -e "$destination/pre-push" ]
}
