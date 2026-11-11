#!/usr/bin/env bats
# A9 safety predicate, with fake homes and stubbed launchctl/git/gh.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-host-clean.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"
  TRELLIS_HOME="$SANDBOX/trellis"
  REPO="$SANDBOX/repo"
  STUB_BIN="$SANDBOX/bin"
  local fenced_git
  fenced_git="$(command -v git)"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$STUB_BIN"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  printf '#!/bin/bash\nexec %q "$@"\n' "$fenced_git" > "$STUB_BIN/git"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/gh"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/launchctl"
  chmod 700 "$STUB_BIN/git" "$STUB_BIN/gh" "$STUB_BIN/launchctl"
  PATH="$STUB_BIN:$PATH"; export HOME TRELLIS_HOME PATH
  git init -q -b main "$REPO"
  git -C "$REPO" config user.name fixture
  git -C "$REPO" config user.email fixture@example.invalid
  printf '.env.local\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -qm fixture
  . "$REPO_ROOT/scripts/lib/disk-janitor-host.sh"
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "${SANDBOX:?}"
}

@test "pi worktree dirty check holds ignored data but allows an empty tree" {
  run dj_host_worktree_dirty "$REPO"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  printf 'local credentials\n' > "$REPO/.env.local"
  run dj_host_worktree_dirty "$REPO"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$REPO/.env.local" ]
}
