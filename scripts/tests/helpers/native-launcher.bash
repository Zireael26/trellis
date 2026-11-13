# Test-only same-checkout build and literal companion pin. Never use the
# shipped scaffold or discover a candidate from the test project's PATH.
load helpers/native-cargo

native_launcher_binary() {
  local target="${CARGO_TARGET_DIR:-$BATS_FILE_TMPDIR/native-target}" cargo_bin
  cargo_bin="$(command -v cargo || true)"
  if [ -z "$cargo_bin" ] && [ -n "${CARGO_HOME:-}" ] && [ -x "$CARGO_HOME/bin/cargo" ]; then
    cargo_bin="$CARGO_HOME/bin/cargo"
  fi
  [ -n "$cargo_bin" ] || { echo 'native launcher tests require cargo or CARGO_HOME/bin/cargo' >&2; return 127; }
  (
    unset RUSTUP_TOOLCHAIN
    CARGO_TARGET_DIR="$target" CARGO_BUILD_JOBS=2 "$cargo_bin" build --locked --offline \
      --manifest-path "$REPO_ROOT/native/trellis-hooks/Cargo.toml"
  ) >&2 || return $?
  printf '%s/debug/trellis-hooks\n' "$target"
}

pin_native_launcher() {
  local binary="${1:-}" digest target entry
  if [ -z "$binary" ]; then
    native_cargo_require
    binary="$(native_launcher_binary)" || return $?
  fi
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) target=aarch64-apple-darwin ;;
    Linux/x86_64) target=x86_64-unknown-linux-musl ;;
    Linux/aarch64) target=aarch64-unknown-linux-musl ;;
    *) echo 'native launcher fixture requires a supported target' >&2; return 1 ;;
  esac
  digest="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$binary")"
  entry="$TRELLIS_HOME/bin/native/1.2.3/$target/$digest/trellis-hooks"
  mkdir -p "${entry%/*}"
  cp "$binary" "$entry"
  chmod 500 "$entry" "${entry%/*}"
  python3 -I - "$LAUNCHER" "$entry" "$digest" <<'PY'
import pathlib,sys
path=pathlib.Path(sys.argv[1]);text=path.read_text()
for key,value in [('entry',sys.argv[2]),('sha256',sys.argv[3]),('version','1.2.3')]:
    old="launcher_native_"+key+"=''"
    assert text.count(old)==1
    text=text.replace(old,"launcher_native_"+key+"='"+value+"'")
path.write_text(text)
PY
}

native_bounded() {
  python3 -I -c '
import os,signal,subprocess,sys
child=subprocess.Popen(sys.argv[1:],start_new_session=True,close_fds=False)
try:
    status=child.wait(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(child.pid,signal.SIGKILL)
    child.wait()
    print("native launcher test exceeded its 60-second bound",file=sys.stderr)
    status=124
sys.exit(status if status>=0 else 128-status)
' "$@"
}
