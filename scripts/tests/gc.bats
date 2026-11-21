#!/usr/bin/env bats
# Focused coverage for `trellis gc`: mark-and-sweep reachability, dry-run default,
# read-only tree deletion under --apply, dead-PID .tmp.*, and stale (>7d) native-stop-bundles.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
TRELLIS_CLI="$REPO_ROOT/scripts/trellis"
GC_SCRIPT="$REPO_ROOT/scripts/gc.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/gc.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

seed_release() {
  local ver="$1"
  mkdir -p "$TRELLIS_HOME/releases/$ver/payload"
  printf '{"version":"%s"}\n' "$ver" > "$TRELLIS_HOME/releases/$ver/release.json"
  printf 'payload-%s\n' "$ver" > "$TRELLIS_HOME/releases/$ver/payload/sentinel.txt"
  chmod 0444 "$TRELLIS_HOME/releases/$ver/release.json" "$TRELLIS_HOME/releases/$ver/payload/sentinel.txt"
  chmod 0555 "$TRELLIS_HOME/releases/$ver/payload" "$TRELLIS_HOME/releases/$ver"

  mkdir -p "$TRELLIS_HOME/bin/native/$ver/aarch64-apple-darwin/deadbeef"
  printf '#!/bin/sh\nexit 0\n' > "$TRELLIS_HOME/bin/native/$ver/aarch64-apple-darwin/deadbeef/trellis-hooks"
  chmod 0500 "$TRELLIS_HOME/bin/native/$ver/aarch64-apple-darwin/deadbeef/trellis-hooks"
  chmod 0500 "$TRELLIS_HOME/bin/native/$ver/aarch64-apple-darwin/deadbeef" "$TRELLIS_HOME/bin/native/$ver/aarch64-apple-darwin" "$TRELLIS_HOME/bin/native/$ver"
}

seed_config() {
  local active="$1"
  cat > "$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$SANDBOX/src",
  "release_remote": "https://example.invalid/trellis.git",
  "active_cli_release": "$active",
  "default_fleet": "personal",
  "fleets": {
    "personal": {
      "discovery_roots": ["$SANDBOX/projects"]
    }
  }
}
EOF
  chmod 0600 "$TRELLIS_HOME/config.json"
}

@test "trellis gc defaults to dry-run, preserves active/owner/journal releases, and removes unreachable read-only trees on --apply" {
  seed_config "1.5.3"
  seed_release "1.5.0"
  seed_release "1.5.1"
  seed_release "1.5.2"
  seed_release "1.5.3"
  seed_release "1.4.9"

  mkdir -p -m 700 "$TRELLIS_HOME/state/attachments/$(printf 'a%.0s' {1..64})"
  cat > "$TRELLIS_HOME/state/attachments/$(printf 'a%.0s' {1..64})/$(printf 'b%.0s' {1..64}).json" <<EOF
{"schema_version":2,"status":"committed","release":"1.5.1","harnesses":["antigravity"],"artifacts":[]}
EOF
  chmod 0600 "$TRELLIS_HOME/state/attachments/$(printf 'a%.0s' {1..64})/$(printf 'b%.0s' {1..64}).json"

  mkdir -p -m 700 "$TRELLIS_HOME/state/attachment-journals"
  cat > "$TRELLIS_HOME/state/attachment-journals/pending.json" <<EOF
{"schema_version":2,"journal_version":2,"release":"1.5.2"}
EOF
  chmod 0600 "$TRELLIS_HOME/state/attachment-journals/pending.json"

  mkdir -p -m 700 "$TRELLIS_HOME/state/release-adoptions/job-1"
  cat > "$TRELLIS_HOME/state/release-adoptions/job-1/plans.jsonl" <<EOF
{"old_version":"1.5.1","new_version":"1.4.9"}
EOF

  # Dead-PID and live-PID .tmp.* staging directories
  mkdir -p -m 700 "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01"
  printf 'staged\n' > "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01/file"
  chmod 0400 "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01/file"
  chmod 0500 "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01"
  printf '{"schema_version":1,"pid":99999999,"process_birth":"1970-01-01"}\n' > "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01.owner.json"

  mkdir -p -m 700 "$TRELLIS_HOME/releases/.tmp.1.5.3.exec.live01"
  printf '{"schema_version":1,"pid":%s}\n' "$$" > "$TRELLIS_HOME/releases/.tmp.1.5.3.exec.live01.owner.json"

  # Stale (>7d) vs fresh native-stop-bundles
  mkdir -p -m 700 "$TRELLIS_HOME/state/native-stop-bundles/stale-bundle" "$TRELLIS_HOME/state/native-stop-bundles/fresh-bundle"
  printf 'bundle\n' > "$TRELLIS_HOME/state/native-stop-bundles/stale-bundle/meta.json"
  chmod 0400 "$TRELLIS_HOME/state/native-stop-bundles/stale-bundle/meta.json"
  chmod 0500 "$TRELLIS_HOME/state/native-stop-bundles/stale-bundle"
  python3 -c 'import os, sys, time; t = time.time() - (8 * 86400); os.utime(sys.argv[1], (t, t))' \
    "$TRELLIS_HOME/state/native-stop-bundles/stale-bundle"

  # Dry-run via `trellis gc` leaves everything intact
  run bash "$TRELLIS_CLI" gc
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gc: would-remove release $TRELLIS_HOME/releases/1.5.0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gc: would-remove native-binary $TRELLIS_HOME/bin/native/1.5.0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gc: would-remove tmp-staging $TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gc: would-remove native-stop-bundle $TRELLIS_HOME/state/native-stop-bundles/stale-bundle"* ]] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME/releases/1.5.0" ]
  [ -d "$TRELLIS_HOME/bin/native/1.5.0" ]
  [ -d "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01" ]
  [ -d "$TRELLIS_HOME/state/native-stop-bundles/stale-bundle" ]

  # Apply deletes unreachable / dead / stale items and preserves all reachable / live / fresh items
  run bash "$TRELLIS_CLI" gc --apply --home "$TRELLIS_HOME"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME/releases/1.5.0" ]
  [ ! -e "$TRELLIS_HOME/bin/native/1.5.0" ]
  [ ! -e "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01" ]
  [ ! -e "$TRELLIS_HOME/releases/.tmp.1.5.0.exec.dead01.owner.json" ]
  [ ! -e "$TRELLIS_HOME/state/native-stop-bundles/stale-bundle" ]

  [ -d "$TRELLIS_HOME/releases/1.5.3" ]
  [ -d "$TRELLIS_HOME/bin/native/1.5.3" ]
  [ -d "$TRELLIS_HOME/releases/1.5.1" ]
  [ -d "$TRELLIS_HOME/bin/native/1.5.1" ]
  [ -d "$TRELLIS_HOME/releases/1.5.2" ]
  [ -d "$TRELLIS_HOME/bin/native/1.5.2" ]
  [ -d "$TRELLIS_HOME/releases/1.4.9" ]
  [ -d "$TRELLIS_HOME/bin/native/1.4.9" ]
  [ -d "$TRELLIS_HOME/releases/.tmp.1.5.3.exec.live01" ]
  [ -d "$TRELLIS_HOME/state/native-stop-bundles/fresh-bundle" ]
}

@test "trellis gc fails closed on corrupt owner or journal state without deleting releases" {
  seed_config "1.5.3"
  seed_release "1.5.0"
  seed_release "1.5.3"

  mkdir -p -m 700 "$TRELLIS_HOME/state/attachments/$(printf 'c%.0s' {1..64})"
  printf '{corrupt-json\n' > "$TRELLIS_HOME/state/attachments/$(printf 'c%.0s' {1..64})/$(printf 'd%.0s' {1..64}).json"
  chmod 0600 "$TRELLIS_HOME/state/attachments/$(printf 'c%.0s' {1..64})/$(printf 'd%.0s' {1..64}).json"

  run bash "$GC_SCRIPT" --apply --home "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  [ -d "$TRELLIS_HOME/releases/1.5.0" ]
  [ -d "$TRELLIS_HOME/bin/native/1.5.0" ]
}

@test "trellis gc validates owner schema, protects registry worktree pins, and ignores non-PID semver digits in .tmp.*" {
  seed_config "1.5.3"
  seed_release "1.5.0"
  seed_release "1.5.3"

  # Fresh .tmp.1.5.3.abcdef must NOT treat semver patch '3' as a dead PID
  mkdir -p -m 700 "$TRELLIS_HOME/releases/.tmp.1.5.3.abcdef"
  # Explicit dead pid token IS reaped
  mkdir -p -m 700 "$TRELLIS_HOME/releases/.tmp.1.5.3.pid-99999999"

  # Registered worktree pinning 1.5.0 via .trellis.json keeps 1.5.0 reachable
  local wt="$SANDBOX/projects/pinned-app"
  mkdir -p "$wt"
  printf '{"schema_version":1,"project_id":"pinned-app","trellis_version":"1.5.0"}\n' > "$wt/.trellis.json"
  cat > "$TRELLIS_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/pinned-app":{"status":"active","checkouts":{"co1":{"worktrees":{"wt1":{"root":"$wt"}}}}}}}
EOF
  chmod 0600 "$TRELLIS_HOME/registry.json"

  run bash "$GC_SCRIPT" --apply --home "$TRELLIS_HOME"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME/releases/1.5.0" ]
  [ -d "$TRELLIS_HOME/releases/.tmp.1.5.3.abcdef" ]
  [ ! -e "$TRELLIS_HOME/releases/.tmp.1.5.3.pid-99999999" ]

  # Valid JSON but schema-invalid owner record (missing string release) fails closed (exit 4)
  mkdir -p -m 700 "$TRELLIS_HOME/state/attachments/$(printf 'e%.0s' {1..64})"
  printf '{"schema_version":2,"release":123}\n' > "$TRELLIS_HOME/state/attachments/$(printf 'e%.0s' {1..64})/$(printf 'f%.0s' {1..64}).json"
  chmod 0600 "$TRELLIS_HOME/state/attachments/$(printf 'e%.0s' {1..64})/$(printf 'f%.0s' {1..64}).json"

  run bash "$GC_SCRIPT" --apply --home "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
}
