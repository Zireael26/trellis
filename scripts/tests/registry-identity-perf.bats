#!/usr/bin/env bats
# Deterministic process budgets, not load-sensitive wall-clock assertions.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/local-registry.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/identity-perf.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$SANDBOX/root with space"
}

teardown() { rm -rf "$SANDBOX"; }

@test "identity classifier decodes each JSON record once and still detects drift" {
  run env LIB="$LIB" ROOT="$SANDBOX/root with space" LOG="$SANDBOX/jq.log" bash -c '
    . "$LIB"
    identity="$(jq -cn --arg root "$ROOT" "{root:\$root, checkout_root:\$root, git_common_dir:(\$root+\"/.git\"), checkout_id:\"cid\", worktree_id:\"wid\"}")"
    row="$(printf "%s\n" "$identity" | jq -c ". + {kind:\"worktree\"}")"
    local_registry_identity_for_root() { printf "%s\n" "$identity"; }
    local_registry_sha256() {
      if [ "$1" = "$ROOT/.git" ]; then printf "cid\n"; else printf "wid\n"; fi
    }
    jq() { printf "jq\n" >> "$LOG"; command jq "$@"; }
    local_registry_classify_identity_row "$row" > "$LOG.verdict"
    [ "$(command jq -r .state "$LOG.verdict")" = verified ] || exit 90
    calls=$(wc -l < "$LOG")
    printf "jq calls=%s\n" "$calls"
    [ "$calls" -le 4 ] || exit 91
    identity="$(printf "%s\n" "$identity" | command jq -c ".checkout_id = \"drift\"")"
    local_registry_classify_identity_row "$row" > "$LOG.verdict"
    [ "$(command jq -r .class "$LOG.verdict")" = 4 ] || exit 92
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "one live identity uses at most three Git processes without losing canonical paths" {
  root="$SANDBOX/root with space"
  git -C "$root" init -q
  run env LIB="$LIB" ROOT="$root" LOG="$SANDBOX/git.log" bash -c '
    . "$LIB"
    git() { printf "git\n" >> "$LOG"; command git "$@"; }
    local_registry_identity_for_root "$ROOT" > "$LOG.identity" || exit "$?"
    [ "$(jq -r .root "$LOG.identity")" = "$ROOT" ] || exit 90
    [ "$(jq -r .git_common_dir "$LOG.identity")" = "$ROOT/.git" ] || exit 91
    calls=$(wc -l < "$LOG")
    printf "git calls=%s\n" "$calls"
    [ "$calls" -le 3 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "identity hashing uses a native SHA-256 tool without Perl startup" {
  native="$(command -v openssl)" || skip 'openssl unavailable'
  mkdir "$SANDBOX/bin"
  ln -s "$native" "$SANDBOX/bin/openssl"
  ln -s "$(command -v awk)" "$SANDBOX/bin/awk"
  ln -s "$(command -v grep)" "$SANDBOX/bin/grep"
  ln -s "$(command -v dirname)" "$SANDBOX/bin/dirname"
  run env PATH="$SANDBOX/bin" /bin/bash -c '
    . "$1"
    local_registry_require_hash_command || exit "$?"
    local_registry_sha256 abc
  ' _ "$LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]
}
