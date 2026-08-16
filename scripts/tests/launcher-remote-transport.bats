#!/usr/bin/env bats
# `launcher_bootstrap_remote_transport_is_allowed` — the transport allowlist
# guarding the one place a release remote is dialled.
#
# Security-gate finding F2 (Medium): the remote was screened for control
# characters only, at all three layers. `http://` and `git://` are both
# unauthenticated and both on git's default protocol.allow list, so an on-path
# attacker could serve an annotated tag whose payload the installer then sealed
# read-only and executed on every subsequent invocation.
#
# The predicate is sourced out of the launcher body rather than exercised through
# a real fetch: a network dial is exactly what these tests must not perform.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  WORK="$(mktemp -d)"
  # Extract just the predicate. `sed` from the function header to its closing
  # brace keeps this independent of the launcher's env -i bootstrap.
  sed -n '/^launcher_bootstrap_remote_transport_is_allowed() {$/,/^}$/p' \
    "$REPO_ROOT/scripts/trellis-launcher.sh" > "$WORK/predicate.sh"
  [ -s "$WORK/predicate.sh" ]
  grep -Fq 'esac' "$WORK/predicate.sh"
  # shellcheck disable=SC1090
  . "$WORK/predicate.sh"
}

teardown() {
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}

allow() {
  launcher_bootstrap_remote_transport_is_allowed "$1" || {
    echo "expected ALLOW, got refuse: $1"; false
  }
}

refuse() {
  if launcher_bootstrap_remote_transport_is_allowed "$1"; then
    echo "expected REFUSE, got allow: $1"; false
  fi
}

@test "https remote is allowed" {
  allow "https://github.com/example/trellis.git"
}

@test "ssh remotes are allowed in both spellings" {
  allow "ssh://git@github.com/example/trellis.git"
  allow "git+ssh://git@github.com/example/trellis.git"
  allow "git@github.com:example/trellis.git"
}

@test "local remotes are allowed — the install flow and every fixture use them" {
  allow "/srv/mirrors/trellis.git"
  allow "file:///srv/mirrors/trellis.git"
}

@test "http is refused — unauthenticated and on git's default allow list" {
  refuse "http://internal-mirror.example/trellis.git"
}

@test "git protocol is refused for the same reason" {
  refuse "git://internal-mirror.example/trellis.git"
}

@test "ext:: and other command transports are refused" {
  refuse "ext::sh -c touch%20/tmp/PWNED"
  refuse "transport::address"
}

@test "other schemes are refused rather than falling through" {
  refuse "ftp://mirror.example/trellis.git"
  refuse "rsync://mirror.example/trellis.git"
}

@test "an empty or bare relative remote is refused" {
  refuse ""
  refuse "relative/path.git"
}

@test "the launcher wires the predicate in ahead of the fetch" {
  # A predicate nothing calls is not a control. Assert the guard sits between the
  # tag computation and the fetch, so no code path reaches `git fetch` without it.
  run awk '
    /^  tag="v\$version"$/ { seen_tag = 1 }
    seen_tag && /launcher_bootstrap_remote_transport_is_allowed/ { seen_guard = 1 }
    seen_tag && /launcher_bootstrap_git -C "\$repo" fetch/ {
      print (seen_guard ? "GUARDED" : "UNGUARDED"); exit
    }
  ' "$REPO_ROOT/scripts/trellis-launcher.sh"
  [ "$output" = "GUARDED" ]
}
