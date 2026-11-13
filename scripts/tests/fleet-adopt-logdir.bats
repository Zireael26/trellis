#!/usr/bin/env bats
# fleet-adopt.sh must not default its logs to a predictable shared /tmp path.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/specs/074-fast-hooks/release-1.5.0/fleet-adopt.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/fleet-adopt.XXXXXX")"
  mkdir -m 700 "$SANDBOX/tmp"
  cat > "$SANDBOX/trellis" <<'FAKE'
#!/bin/sh
printf '%s\n' '{"rows":[]}'
FAKE
  chmod +x "$SANDBOX/trellis"
}

@test "default log dir is a fresh mktemp directory under TMPDIR, mode 0700" {
  run env TMPDIR="$SANDBOX/tmp" TRELLIS="$SANDBOX/trellis" /bin/bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  dir="$(printf '%s\n' "$output" | sed -n 's/.*snapshot in //p')"
  case "$dir" in "$SANDBOX/tmp/fleet-adopt-1.5.0-"*.??????) ;; *) echo "dir=$dir"; false ;; esac
  [ -d "$dir" ] || false
  mode="$(stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir")"
  [ "$mode" = 700 ] || { echo "mode=$mode"; false; }
}

@test "two runs in the same second get different log dirs" {
  run env TMPDIR="$SANDBOX/tmp" TRELLIS="$SANDBOX/trellis" /bin/bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ] || false
  run env TMPDIR="$SANDBOX/tmp" TRELLIS="$SANDBOX/trellis" /bin/bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ] || false
  [ "$(find "$SANDBOX/tmp" -mindepth 1 -maxdepth 1 -type d -name 'fleet-adopt-*' | wc -l | tr -d ' ')" -eq 2 ] || false
}

@test "an explicit --log-dir is still honoured" {
  run env TMPDIR="$SANDBOX/tmp" TRELLIS="$SANDBOX/trellis" /bin/bash "$SCRIPT" --dry-run --log-dir "$SANDBOX/logs"
  [ "$status" -eq 0 ] || false
  [ -s "$SANDBOX/logs/registry-before.json" ] || false
}
