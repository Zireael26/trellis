# Shared native fixture preparation for Bats files and runner Cargo stages.
native_cargo_prepare() {
  local private="$1" helper="$2" lockfile="$3" result=0 diagnostic
  diagnostic="$(python3 -I "$helper" "$private" "$lockfile" 2>&1)" || result=$?
  case "$result" in
    0) TRELLIS_NATIVE_CARGO_UNAVAILABLE='' ;;
    2) TRELLIS_NATIVE_CARGO_UNAVAILABLE="$diagnostic"; private="$private-unavailable" ;;
    *) printf '%s\n' "$diagnostic" >&2; return "$result" ;;
  esac
  native_cargo_activate "$private"
}

native_cargo_activate() {
  local private="$1"
  unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER CARGO_BUILD_RUSTC_WRAPPER CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER
  # Even when prerequisites are absent, no fallback command may write to the
  # operator's Cargo/Rustup homes or ask rustup to download a toolchain.
  mkdir -p "$private/cargo" "$private/rustup" "$private/bin"
  CARGO_HOME="$private/cargo"
  RUSTUP_HOME="$private/rustup"
  # A fresh target is part of the fixture: inherited targets may contain
  # stale artifacts and are not an input to a reusable full-battery verdict.
  CARGO_TARGET_DIR="$private/target"
  CARGO_NET_OFFLINE=true
  CARGO_BUILD_JOBS=2
  RUST_TEST_THREADS=1
  RUSTUP_AUTO_INSTALL=0
  RUSTUP_DIST_SERVER="file://$private/no-network"
  RUSTUP_UPDATE_ROOT="$RUSTUP_DIST_SERVER"
  PATH="$private/bin:$PATH"
  export CARGO_HOME RUSTUP_HOME CARGO_TARGET_DIR CARGO_NET_OFFLINE CARGO_BUILD_JOBS
  export RUST_TEST_THREADS RUSTUP_AUTO_INSTALL RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT PATH
  export TRELLIS_NATIVE_CARGO_UNAVAILABLE
}

# A runner shard prepares its offline state once and reuses it for its Cargo
# stages, without exporting any of these values to other stages.
native_cargo_run() {
  local private="$TRELLIS_TEST_GIT_FENCE_ROOT/native-cargo-stage"
  if [ "${NATIVE_CARGO_STAGE_PREPARED:-0}" -eq 0 ]; then
    (
      native_cargo_prepare "$private" \
        "$ROOT/scripts/tests/helpers/native-cargo-home.py" \
        "$ROOT/native/trellis-hooks/Cargo.lock" || exit $?
      if [ -n "${TRELLIS_NATIVE_CARGO_UNAVAILABLE:-}" ]; then
        printf 'native cargo stage unavailable offline: %s\n' "$TRELLIS_NATIVE_CARGO_UNAVAILABLE" >&2
        exit 2
      fi
    ) || return $?
    NATIVE_CARGO_STAGE_PREPARED=1
  fi
  (
    native_cargo_activate "$private"
    "$private/bin/cargo" "$@"
  )
}

# Bats calls setup_file before the suite changes HOME, including direct
# qualification oracles that do not use scripts/run-tests.sh.
setup_file() {
  native_cargo_prepare "$BATS_FILE_TMPDIR/native-cargo" \
    "$BATS_TEST_DIRNAME/helpers/native-cargo-home.py" \
    "$BATS_TEST_DIRNAME/../../native/trellis-hooks/Cargo.lock"
}

# Call from the test process, not command substitution: Bats' skip exits the
# current shell. Non-native cases still run if offline prerequisites are absent.
native_cargo_require() {
  if [ -n "${TRELLIS_NATIVE_CARGO_UNAVAILABLE:-}" ]; then
    skip "native offline prerequisite unavailable: $TRELLIS_NATIVE_CARGO_UNAVAILABLE"
  fi
}
