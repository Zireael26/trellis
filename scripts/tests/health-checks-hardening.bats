#!/usr/bin/env bats
# Hardening probes for scripts/lib/health-checks.sh: interpreter isolation and
# fail-open behaviour that a read-only diagnostic must not hide.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/health-checks.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/health-checks.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

@test "the verified surface-plan bundle isolates its python stdin program" {
  local body
  body="$(sed -n '/^hc_portable_emit_verified_surface_plan_bundle()/,/^}/p' "$LIB")"
  [ -n "$body" ] || { echo "function not found"; false; }
  printf '%s\n' "$body" | grep -Fq '"$python_bin" -I -' ||
    { echo "bundle interpreter is not isolated"; false; }
}

@test "a non-functional python3 is reported as a skip, never a healthy worktree" {
  local main="$SANDBOX/main" canon="$SANDBOX/canon" wt="$SANDBOX/linked"
  local bin="$SANDBOX/bin"
  mkdir -p "$main" "$canon" "$bin" "$main/.claude"
  git -C "$main" init -q -b main
  git -C "$main" config user.email t@example.invalid
  git -C "$main" config user.name t
  git -C "$main" commit -q --allow-empty -m seed
  printf 'rules\n' > "$canon/CLAUDE.md"
  ln -s "$canon/CLAUDE.md" "$main/.claude/CLAUDE.md"
  git -C "$main" worktree add -q -b feat/linked "$wt"
  printf '#!/bin/sh\nexit 69\n' > "$bin/python3"
  chmod 755 "$bin/python3"

  run env PATH="$bin:$PATH" bash -c '
    . "$1"
    hc_worktree_inheritance "$2" "$3"
  ' _ "$LIB" "$main" "$canon"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"all linked worktrees carry"* ]] || { echo "$output"; false; }
  [[ "$output" == *"skipped"* ]] || { echo "$output"; false; }
}
