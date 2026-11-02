#!/usr/bin/env bats
# Tests for scripts/pi-spill-watchdog.sh (Spec 069 C4 / DS.3).
# Watchdog runs every 60 s via launchd, finds pi-bash-*.log files over 2 GiB
# in pi roots at maxdepth 1, and truncates them to 0 with `truncate -s 0`,
# never unlinking.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
WATCHDOG="$REPO_ROOT/scripts/pi-spill-watchdog.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/pi-watchdog.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  MOCK_ROOT1="$SANDBOX/root1"
  MOCK_ROOT2="$SANDBOX/root2"
  mkdir -p "$MOCK_ROOT1" "$MOCK_ROOT2"
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

file_size() {
  local value
  value="$(stat -f '%z' "$1" 2>/dev/null)" || value="$(stat -c '%s' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$value"
}

file_inode() {
  local value
  value="$(stat -f '%i' "$1" 2>/dev/null)" || value="$(stat -c '%i' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$value"
}

@test "GNU stat: failed BSD probe stdout cannot hide an oversized log" {
  stat --version >/dev/null 2>&1 || skip "requires GNU stat"
  local target="$MOCK_ROOT1/pi-bash-gnu-stat.log" probe inode
  truncate -s 2147483649 "$target"
  # Reproduce GNU stat's failure mode, including the stdout it leaves behind.
  if probe="$(stat -f '%z' "$target" 2>/dev/null)"; then
    echo "expected the BSD stat probe to fail"; return 1
  fi
  [ -n "$probe" ]
  [ "$(file_size "$target")" = 2147483649 ]
  inode="$(stat -c '%i' "$target")"
  [ "$(file_inode "$target")" = "$inode" ]

  run "$WATCHDOG" --root "$MOCK_ROOT1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"truncated $target (2147483649 bytes,"* ]]
  [ "$(stat -c '%s' "$target")" = 0 ]
  [ "$(stat -c '%i' "$target")" = "$inode" ]
}

@test "truncates pi-bash-*.log over 2 GiB to 0 and preserves inode" {
  local target="$MOCK_ROOT1/pi-bash-1234.log"
  local normal="$MOCK_ROOT1/pi-bash-normal.log"
  local non_pi="$MOCK_ROOT1/other-large.log"
  local initial_inode

  # 2 GiB + 1 B = 2147483649 bytes (sparse)
  truncate -s 2147483649 "$target"
  initial_inode="$(file_inode "$target")"

  # Normal file <= 2 GiB (1 KiB)
  truncate -s 1024 "$normal"

  # Non-matching file > 2 GiB
  truncate -s 2147483649 "$non_pi"

  run "$WATCHDOG" --root "$MOCK_ROOT1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"truncated $target"* ]] || { echo "$output"; false; }
  [[ "$output" == *"2147483649 bytes"* ]] || { echo "$output"; false; }

  # Target must be 0 bytes and keep its original inode (never unlinked)
  [ -f "$target" ]
  [ "$(file_size "$target")" -eq 0 ]
  [ "$(file_inode "$target")" = "$initial_inode" ]

  # Other files untouched
  [ "$(file_size "$normal")" -eq 1024 ]
  [ "$(file_size "$non_pi")" -eq 2147483649 ]
}

@test "maxdepth 1: nested files in subdirectories are never truncated" {
  local nested_dir="$MOCK_ROOT1/subdir"
  local nested_file="$nested_dir/pi-bash-nested.log"
  mkdir -p "$nested_dir"
  truncate -s 2147483649 "$nested_file"

  run "$WATCHDOG" --root "$MOCK_ROOT1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"nested"* ]] || { echo "$output"; false; }
  [ "$(file_size "$nested_file")" -eq 2147483649 ]
}

@test "--dry-run reports would truncate but leaves file size unchanged" {
  local target="$MOCK_ROOT1/pi-bash-overcap.log"
  truncate -s 2147483649 "$target"

  run "$WATCHDOG" --dry-run --root "$MOCK_ROOT1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[dry-run] would truncate $target"* ]] || { echo "$output"; false; }
  [ "$(file_size "$target")" -eq 2147483649 ]
}

@test "checks multiple roots when specified" {
  local f1="$MOCK_ROOT1/pi-bash-r1.log"
  local f2="$MOCK_ROOT2/pi-bash-r2.log"
  truncate -s 2147483649 "$f1"
  truncate -s 2147483649 "$f2"

  run "$WATCHDOG" --root "$MOCK_ROOT1" --root "$MOCK_ROOT2"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"truncated $f1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"truncated $f2"* ]] || { echo "$output"; false; }
  [ "$(file_size "$f1")" -eq 0 ]
  [ "$(file_size "$f2")" -eq 0 ]
}

@test "scans default roots when no --root is provided" {
  local mock_home="$SANDBOX/home"
  local mock_tmp="$SANDBOX/tmp"
  mkdir -p "$mock_home/projects/worktrees/_pi" "$mock_home/.pi-worktrees" "$mock_tmp/pi" "$mock_home/.trellis/pi-worktrees"
  local f_projpi="$mock_home/projects/worktrees/_pi/pi-bash-projpi.log"
  local f_pw="$mock_home/.pi-worktrees/pi-bash-pw.log"
  local f_tmp="$mock_tmp/pi-bash-tmp.log"
  local f_tmppi="$mock_tmp/pi/pi-bash-tmppi.log"
  local f_tpw="$mock_home/.trellis/pi-worktrees/pi-bash-tpw.log"

  truncate -s 2147483649 "$f_projpi"
  truncate -s 2147483649 "$f_pw"
  truncate -s 2147483649 "$f_tmp"
  truncate -s 2147483649 "$f_tmppi"
  truncate -s 2147483649 "$f_tpw"

  run env HOME="$mock_home" TMPDIR="$mock_tmp" "$WATCHDOG"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_size "$f_projpi")" -eq 0 ]
  [ "$(file_size "$f_pw")" -eq 0 ]
  [ "$(file_size "$f_tmp")" -eq 0 ]
  [ "$(file_size "$f_tmppi")" -eq 0 ]
  [ "$(file_size "$f_tpw")" -eq 0 ]
}

@test "resolves per-user temp root with getconf DARWIN_USER_TEMP_DIR and drops launcher per-run scratch TMPDIR" {
  local mock_home="$SANDBOX/home"
  local mock_darwin_temp="$SANDBOX/darwin-user-temp"
  local mock_launcher_scratch="$mock_home/.trellis/state/scratch/.cmd.1a2b3c4d"
  local stub_bin="$SANDBOX/stub-bin"

  mkdir -p "$mock_home/.pi-worktrees" "$mock_darwin_temp/pi" "$mock_launcher_scratch" "$stub_bin"
  local f_darwin="$mock_darwin_temp/pi-bash-darwin.log"
  local f_darwin_pi="$mock_darwin_temp/pi/pi-bash-darwinpi.log"
  local f_scratch="$mock_launcher_scratch/pi-bash-scratch.log"

  truncate -s 2147483649 "$f_darwin"
  truncate -s 2147483649 "$f_darwin_pi"
  truncate -s 2147483649 "$f_scratch"

  # Create fake getconf on PATH
  cat > "$stub_bin/getconf" <<EOF
#!/bin/sh
if [ "\$1" = "DARWIN_USER_TEMP_DIR" ]; then
  printf '%s/\n' "$mock_darwin_temp"
  exit 0
fi
exit 1
EOF
  chmod +x "$stub_bin/getconf"

  # Run watchdog with fake getconf and launcher scratch in TMPDIR
  run env HOME="$mock_home" TMPDIR="$mock_launcher_scratch" PATH="$stub_bin:$PATH" "$WATCHDOG"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_size "$f_darwin")" -eq 0 ]
  [ "$(file_size "$f_darwin_pi")" -eq 0 ]
  # The launcher scratch directory must NOT have been scanned/truncated
  [ "$(file_size "$f_scratch")" -eq 2147483649 ]
}

@test "symlinked pi-bash-*.log is never truncated and target file is untouched" {
  local target_real="$SANDBOX/real-target.log"
  local symlinked_log="$MOCK_ROOT1/pi-bash-symlinked.log"

  truncate -s 2147483649 "$target_real"
  ln -s "$target_real" "$symlinked_log"

  run "$WATCHDOG" --root "$MOCK_ROOT1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The symlinked log must not be truncated
  [ -L "$symlinked_log" ]
  [ "$(file_size "$target_real")" -eq 2147483649 ]
}

@test "symlinked root directory is skipped and files inside are never truncated" {
  local real_root="$SANDBOX/real-root-dir"
  local symlink_root="$SANDBOX/symlink-root"
  mkdir -p "$real_root"
  local log_file="$real_root/pi-bash-in-symlink-root.log"
  truncate -s 2147483649 "$log_file"

  ln -s "$real_root" "$symlink_root"

  run "$WATCHDOG" --root "$symlink_root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The file inside the symlinked root must NOT be truncated
  [ "$(file_size "$log_file")" -eq 2147483649 ]
}

@test "runs cleanly when TMPDIR is unset" {
  local mock_home="$SANDBOX/home-no-tmp"
  mkdir -p "$mock_home/projects/worktrees/_pi"
  local f_projpi="$mock_home/projects/worktrees/_pi/pi-bash-unset.log"
  truncate -s 2147483649 "$f_projpi"

  run env -u TMPDIR HOME="$mock_home" "$WATCHDOG"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_size "$f_projpi")" -eq 0 ]
}

@test "runs cleanly when TMPDIR is / and never scans root or /pi" {
  local mock_home="$SANDBOX/home-root-tmp"
  mkdir -p "$mock_home/projects/worktrees/_pi"
  local f_projpi="$mock_home/projects/worktrees/_pi/pi-bash-roottmp.log"
  truncate -s 2147483649 "$f_projpi"

  run env TMPDIR="/" HOME="$mock_home" "$WATCHDOG"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_size "$f_projpi")" -eq 0 ]
}


