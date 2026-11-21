#!/usr/bin/env bats
# The native fixture environment copies writable Cargo state and only reads the
# installed toolchain. These synthetic inputs need neither Rust nor network.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
PREPARE="$BATS_TEST_DIRNAME/helpers/native-cargo-home.py"

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/native homes with spaces"
  export HOME="$FIXTURE/fenced home"
  export CARGO_HOME="$FIXTURE/operator cargo"
  export RUSTUP_HOME="$FIXTURE/operator rustup"
  unset CARGO_TARGET_DIR
  mkdir -p "$HOME" "$CARGO_HOME/registry/cache/index.crates.io-fixture" \
    "$CARGO_HOME/registry/index/index.crates.io-fixture/.cache/li/bc"
  printf 'fixture archive\n' > "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  printf 'fixture index\n' > "$CARGO_HOME/registry/index/index.crates.io-fixture/.cache/li/bc/libc"
  printf '{}\n' > "$CARGO_HOME/registry/index/index.crates.io-fixture/config.json"
  printf '[build]\nrustc = "/should/not/be/copied"\n' > "$CARGO_HOME/config.toml"
  checksum="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
    "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate")"
  cat > "$FIXTURE/Cargo.lock" <<EOF
version = 4
[[package]]
name = "libc"
version = "0.2.178"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "$checksum"
EOF
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) HOST_TRIPLE=aarch64-apple-darwin; FOREIGN_TRIPLE=x86_64-apple-darwin ;;
    Darwin:x86_64) HOST_TRIPLE=x86_64-apple-darwin; FOREIGN_TRIPLE=aarch64-apple-darwin ;;
    Linux:x86_64) HOST_TRIPLE=x86_64-unknown-linux-gnu; FOREIGN_TRIPLE=aarch64-unknown-linux-gnu ;;
    Linux:aarch64|Linux:arm64) HOST_TRIPLE=aarch64-unknown-linux-gnu; FOREIGN_TRIPLE=x86_64-unknown-linux-gnu ;;
    *) skip 'unsupported native fixture host' ;;
  esac
  TOOLCHAIN="$RUSTUP_HOME/toolchains/1.97.1-$HOST_TRIPLE"
  mkdir -p "$TOOLCHAIN/bin"
  cat > "$TOOLCHAIN/bin/cargo" <<'EOF'
#!/bin/sh
printf '%s\n' "cargo args: $*" "rustc: $RUSTC" "offline: $CARGO_NET_OFFLINE" "target: $CARGO_TARGET_DIR" "cwd: $PWD" "wrapper: ${RUSTC_WRAPPER-unset}"
EOF
  printf '#!/bin/sh\nprintf "rustc 1.97.1 (fixture)\\nhost: %%s\\nrelease: 1.97.1\\n" "%s"\n' "$HOST_TRIPLE" > "$TOOLCHAIN/bin/rustc"
  printf '#!/bin/sh\nexit 0\n' > "$TOOLCHAIN/bin/rustdoc"
  chmod +x "$TOOLCHAIN/bin/"*
  mkdir -p "$TOOLCHAIN/lib/rustlib/$HOST_TRIPLE/lib"
  printf 'manifest\n' > "$TOOLCHAIN/lib/rustlib/multirust-channel-manifest.toml"
  printf 'components\n' > "$TOOLCHAIN/lib/rustlib/components"
  printf 'driver\n' > "$TOOLCHAIN/lib/librustc_driver-fixture.so"
  printf 'stdlib\n' > "$TOOLCHAIN/lib/rustlib/$HOST_TRIPLE/lib/libcore-fixture.rlib"
  PRIVATE="$FIXTURE/private result"
}

prepare() {
  python3 -I "$PREPARE" "$PRIVATE" "$FIXTURE/Cargo.lock"
}

@test "fenced Cargo state copies the locked archive and sparse index without links or Cargo config" {
  run prepare
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  python3 -I - "$CARGO_HOME" "$PRIVATE/cargo" <<'PY'
from pathlib import Path
import os, sys
source, private = map(Path, sys.argv[1:])
for relative in ('registry/cache/index.crates.io-fixture/libc-0.2.178.crate',
                 'registry/index/index.crates.io-fixture/.cache/li/bc/libc',
                 'registry/index/index.crates.io-fixture/config.json'):
    original, copy = source / relative, private / relative
    assert not copy.is_symlink(), copy
    assert copy.read_bytes() == original.read_bytes()
    assert (copy.stat().st_dev, copy.stat().st_ino) != (original.stat().st_dev, original.stat().st_ino)
    copy.write_bytes(b'private modification')
    assert original.read_bytes() != copy.read_bytes()
assert not (private / 'config.toml').exists()
PY
}

@test "the private cargo command uses the pinned compiler and refuses other toolchain selectors" {
  run prepare
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env CARGO_HOME="$PRIVATE/cargo" RUSTUP_HOME="$PRIVATE/rustup" \
    CARGO_NET_OFFLINE=false RUSTC_WRAPPER="$CARGO_HOME/unsafe-wrapper" \
    "$PRIVATE/bin/cargo" +1.97.1 build --locked --offline
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'cargo args: build --locked --offline'* ]] || false
  [[ "$output" == *"rustc: $TOOLCHAIN/bin/rustc"* ]] || false
  [[ "$output" == *'offline: true'* && "$output" == *'wrapper: unset'* ]] || false
  run "$PRIVATE/bin/cargo" +stable test --offline
  [ "$status" -ne 0 ] || { echo 'an unpinned toolchain was accepted'; false; }
}

@test "the shared setup survives a later HOME fence and keeps its state private" {
  local project="$FIXTURE/project" file_tmp="$FIXTURE/bats file" helper="$BATS_TEST_DIRNAME/helpers/native-cargo.bash"
  mkdir -p "$project/scripts/tests/helpers" "$project/native/trellis-hooks" "$file_tmp"
  ln -s "$PREPARE" "$project/scripts/tests/helpers/native-cargo-home.py"
  cp "$FIXTURE/Cargo.lock" "$project/native/trellis-hooks/Cargo.lock"
  run env BATS_TEST_DIRNAME="$project/scripts/tests" BATS_FILE_TMPDIR="$file_tmp" \
    bash -c '
      . "$1"
      setup_file || exit $?
      HOME="$2/another fenced home"; export HOME
      native_cargo_require
      printf "cargo=%s\nrustup=%s\ntarget=%s\nauto=%s\n" "$CARGO_HOME" "$RUSTUP_HOME" "$CARGO_TARGET_DIR" "$RUSTUP_AUTO_INSTALL"
      cargo +1.97.1 test --offline
    ' bash "$helper" "$FIXTURE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"cargo=$file_tmp/native-cargo/cargo"* ]] || false
  [[ "$output" == *"rustup=$file_tmp/native-cargo/rustup"* ]] || false
  [[ "$output" == *"target=$file_tmp/native-cargo/target"* ]] || false
  [[ "$output" == *'auto=0'* && "$output" == *'cargo args: test --offline'* ]] || false
}

@test "missing offline inputs skip only the native requirement with a clear reason" {
  local project="$FIXTURE/project" file_tmp="$FIXTURE/bats file" helper="$BATS_TEST_DIRNAME/helpers/native-cargo.bash"
  mkdir -p "$project/scripts/tests/helpers" "$project/native/trellis-hooks" "$file_tmp"
  ln -s "$PREPARE" "$project/scripts/tests/helpers/native-cargo-home.py"
  cp "$FIXTURE/Cargo.lock" "$project/native/trellis-hooks/Cargo.lock"
  rm "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  run env BATS_TEST_DIRNAME="$project/scripts/tests" BATS_FILE_TMPDIR="$file_tmp" \
    bash -c '
      . "$1"
      skip() { printf "SKIP: %s\n" "$1"; exit 0; }
      setup_file || exit $?
      printf "non-native work ran\n"
      native_cargo_require
      printf "should not reach native work\n"
    ' bash "$helper"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'non-native work ran'* && "$output" == *'SKIP: native offline prerequisite unavailable:'* ]] || false
  [[ "$output" == *'libc-0.2.178.crate'* && "$output" != *'should not reach native work'* ]] || false
}

@test "a preseeded output symlink cannot overwrite the source Cargo home" {
  mkdir -p "$PRIVATE/bin"
  ln -s "$CARGO_HOME/config.toml" "$PRIVATE/bin/cargo"
  local before
  before="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CARGO_HOME/config.toml")"
  run prepare
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'destination must be new'* ]] || false
  [ "$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CARGO_HOME/config.toml")" = "$before" ] || false
}

@test "a missing offline crate is distinguished from a corrupt cached crate" {
  rm "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  run prepare
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'offline'* && "$output" == *'libc-0.2.178.crate'* ]] || false
  printf 'tampered\n' > "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  run prepare
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'checksum'* ]] || false
}

@test "a missing sparse-index entry is an offline prerequisite" {
  rm "$CARGO_HOME/registry/index/index.crates.io-fixture/.cache/li/bc/libc"
  run prepare
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'offline registry index'* && "$output" == *'libc'* ]] || false
}

@test "duplicate registries choose a complete checksum-verified cache" {
  cp -R "$CARGO_HOME/registry/cache/index.crates.io-fixture" "$CARGO_HOME/registry/cache/index.crates.io-second"
  cp -R "$CARGO_HOME/registry/index/index.crates.io-fixture" "$CARGO_HOME/registry/index/index.crates.io-second"
  printf 'tampered\n' > "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  run prepare
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PRIVATE/cargo/registry/cache/index.crates.io-second/libc-0.2.178.crate" ]
}

@test "a broken installed compiler fails instead of silently skipping" {
  printf '#!/bin/sh\nexit 42\n' > "$TOOLCHAIN/bin/rustc"
  run prepare
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'installed rustc failed'* ]] || false
}

@test "an executable foreign-host toolchain is not selected" {
  mv "$TOOLCHAIN" "$RUSTUP_HOME/toolchains/1.97.1-$FOREIGN_TRIPLE"
  run prepare
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'offline Rust toolchain 1.97.1 for this host'* ]] || false
}

@test "a missing pinned toolchain reports an offline prerequisite" {
  rm -rf "$RUSTUP_HOME/toolchains"
  run prepare
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'1.97.1'* && "$output" == *'offline'* ]] || false
}

@test "inherited targets are ignored and Cargo runs from the config-free root" {
  run prepare
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local target
  for target in "$CARGO_HOME/target" "$RUSTUP_HOME/target" ../../../.cargo; do
    run env CARGO_TARGET_DIR="$target" "$PRIVATE/bin/cargo" +1.97.1 build --locked --offline
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"target: $PRIVATE/target"* && "$output" == *'cwd: /'* ]] || false
  done
}

@test "standalone runner stages reuse private preparation without leaking its environment" {
  local project="$FIXTURE/project" fence="$FIXTURE/runner fence" helper="$BATS_TEST_DIRNAME/helpers/native-cargo.bash"
  mkdir -p "$project/scripts/tests/helpers" "$project/native/trellis-hooks" "$fence"
  ln -s "$PREPARE" "$project/scripts/tests/helpers/native-cargo-home.py"
  cp "$FIXTURE/Cargo.lock" "$project/native/trellis-hooks/Cargo.lock"
  run env ROOT="$project" TRELLIS_TEST_GIT_FENCE_ROOT="$fence" bash -c '
    . "$1"
    old_cargo=$CARGO_HOME; old_rustup=$RUSTUP_HOME
    native_cargo_run +1.97.1 test --locked --offline || exit $?
    native_cargo_run +1.97.1 test --locked --offline || exit $?
    [ "$CARGO_HOME" = "$old_cargo" ] && [ "$RUSTUP_HOME" = "$old_rustup" ] || exit 1
    printf "parent homes unchanged\n"
  ' bash "$helper"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c '^cargo args: test --locked --offline$')" -eq 2 ] || false
  [[ "$output" == *"target: $fence/native-cargo-stage/target"* && "$output" == *'parent homes unchanged'* ]] || false
}

@test "verdict identity binds the selected compiler and offline cache inputs" {
  local project="$FIXTURE/project"
  mkdir -p "$project/native/trellis-hooks"
  cp "$FIXTURE/Cargo.lock" "$project/native/trellis-hooks/Cargo.lock"
  run python3 -I -B - "$REPO_ROOT/scripts/lib/gate_verdict.py" "$project" "$CARGO_HOME" "$TOOLCHAIN" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('gate_verdict_fixture', sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
root, cargo, toolchain = map(Path, sys.argv[2:])
before = gate.native_cargo_identity(root)
for path in (toolchain / 'bin/cargo', toolchain / 'bin/rustc',
             cargo / 'registry/index/index.crates.io-fixture/.cache/li/bc/libc'):
    original = path.read_bytes()
    path.write_bytes(original + b'\n# changed\n')
    assert gate.native_cargo_identity(root) != before, path
    path.write_bytes(original)
archive = cargo / 'registry/cache/index.crates.io-fixture/libc-0.2.178.crate'
archive.write_bytes(b'tampered')
try:
    gate.native_cargo_identity(root)
except ValueError as error:
    assert 'checksum' in str(error)
else:
    raise AssertionError('corrupted archive allowed a reusable identity')
archive.unlink()
try:
    gate.native_cargo_identity(root)
except ValueError as error:
    assert 'offline' in str(error)
else:
    raise AssertionError('missing archive allowed a reusable identity')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a corrupted source archive blocks the standalone native stage" {
  local project="$FIXTURE/project" fence="$FIXTURE/runner fence" helper="$BATS_TEST_DIRNAME/helpers/native-cargo.bash"
  mkdir -p "$project/scripts/tests/helpers" "$project/native/trellis-hooks" "$fence"
  ln -s "$PREPARE" "$project/scripts/tests/helpers/native-cargo-home.py"
  cp "$FIXTURE/Cargo.lock" "$project/native/trellis-hooks/Cargo.lock"
  printf 'tampered\n' > "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  run env ROOT="$project" TRELLIS_TEST_GIT_FENCE_ROOT="$fence" bash -c '. "$1"; native_cargo_run +1.97.1 build --locked --offline' bash "$helper"
  [ "$status" -ne 0 ] || { echo 'corrupt archive allowed the stage'; false; }
  [[ "$output" == *'checksum mismatch'* && "$output" != *'cargo args:'* ]] || false
}

@test "partially populated fenced homes fall back without overriding explicit homes" {
  local account="$FIXTURE/account home"
  mkdir -p "$account" "$HOME/.cargo/registry/cache/index.crates.io-fixture" "$HOME/.cargo/registry/index" "$HOME/.rustup/toolchains/1.97.1-$HOST_TRIPLE/bin"
  printf 'unrelated crate\n' > "$HOME/.cargo/registry/cache/index.crates.io-fixture/unrelated-1.0.0.crate"
  mv "$CARGO_HOME" "$account/.cargo"
  mv "$RUSTUP_HOME" "$account/.rustup"
  unset CARGO_HOME RUSTUP_HOME
  run python3 -I -B - "$PREPARE" "$account" "$PRIVATE" "$FIXTURE/Cargo.lock" <<'PY'
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import os, sys
spec = importlib.util.spec_from_file_location('native_cargo_home', sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
helper.pwd.getpwuid = lambda uid: SimpleNamespace(pw_dir=sys.argv[2])
helper.prepare(Path(sys.argv[3]), Path(sys.argv[4]))
assert (Path(sys.argv[3]) / 'cargo/registry/cache/index.crates.io-fixture/libc-0.2.178.crate').is_file()
os.environ['CARGO_HOME'] = str(Path(sys.argv[2]) / 'empty-override')
assert helper.source_homes('CARGO_HOME', '.cargo', Path(sys.argv[2])) == [Path(os.environ['CARGO_HOME'])]
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "explicit source homes work even without a passwd entry" {
  run python3 -I -B - "$PREPARE" "$PRIVATE" "$FIXTURE/Cargo.lock" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('native_cargo_home', sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
def missing(uid):
    raise KeyError(uid)
helper.pwd.getpwuid = missing
helper.prepare(Path(sys.argv[2]), Path(sys.argv[3]))
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "default homes are taken from the caller before HOME is changed" {
  mkdir -p "$HOME"
  mv "$CARGO_HOME" "$HOME/.cargo"
  mv "$RUSTUP_HOME" "$HOME/.rustup"
  unset CARGO_HOME RUSTUP_HOME
  run prepare
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PRIVATE/cargo/registry/cache/index.crates.io-fixture/libc-0.2.178.crate" ]
}

setup_native_only_runner() {
  PROJECT="$FIXTURE/runner project"
  mkdir -p "$PROJECT"
  PROJECT="$(CDPATH='' cd "$PROJECT" && pwd -P)"
  local path
  for path in scripts/run-tests.sh scripts/lib/test-suites.sh scripts/lib/bats-jobs.sh \
    scripts/tests/stage-weights.tsv scripts/lib/trellis-python.sh scripts/lib/receipt_provenance.py \
    scripts/tests/helpers/git-fence/git scripts/tests/helpers/git-fence/mktemp \
    scripts/tests/helpers/native-cargo.bash scripts/tests/helpers/native-cargo-home.py \
    core-rules/skills/process-gate/scripts/lib/diff-base.sh; do
    mkdir -p "$PROJECT/${path%/*}"
    cp "$REPO_ROOT/$path" "$PROJECT/$path"
  done
  mkdir -p "$PROJECT/native/trellis-hooks"
  cp "$FIXTURE/Cargo.lock" "$PROJECT/native/trellis-hooks/Cargo.lock"
  printf '[package]\nname="fixture"\nversion="0.1.0"\n' > "$PROJECT/native/trellis-hooks/Cargo.toml"
  export CALL_RECORD="$FIXTURE/native-cargo-call" CALL_COUNT="$FIXTURE/native-cargo-count"
  export OUTSIDE_GIT="$FIXTURE/outside-git"
  export OUTSIDE_ERROR="$FIXTURE/outside-git-error"
  cat > "$TOOLCHAIN/bin/cargo" <<'EOF'
#!/bin/bash
set -u
[ "${CARGO_NET_OFFLINE:-}" = true ] && [ "${CARGO_BUILD_JOBS:-}" = 2 ] && [ "${RUST_TEST_THREADS:-}" = 1 ] || exit 71
[ -z "${GIT_DIR+x}${GIT_WORK_TREE+x}${TRELLIS_NATIVE_CARGO_ONLY+x}" ] || exit 72
case "$CARGO_HOME:$RUSTUP_HOME:$CARGO_TARGET_DIR" in
  "$TRELLIS_TEST_GIT_FENCE_ROOT"/*:"$TRELLIS_TEST_GIT_FENCE_ROOT"/*:"$TRELLIS_TEST_GIT_FENCE_ROOT"/*) ;;
  *) exit 73 ;;
esac
git init -q "$TRELLIS_TEST_GIT_FENCE_ROOT/allowed-repo" || exit 74
if git init -q "$OUTSIDE_GIT" 2>"$OUTSIDE_ERROR"; then exit 75; fi
grep -Fq 'test-git-fence: REFUSED:' "$OUTSIDE_ERROR" || exit 76
printf 'call\n' >> "$CALL_COUNT"
printf '%s\0' "$@" > "$CALL_RECORD"
printf 'test result: ok. 1 passed; 0 failed; 0 ignored\n'
exit "${FAKE_CARGO_RC:-0}"
EOF
  chmod 755 "$TOOLCHAIN/bin/cargo"
}

@test "native-only runs one complete Cargo test through the real helper and Git fence" {
  setup_native_only_runner
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification GIT_DIR="$FIXTURE/poison" GIT_WORK_TREE="$FIXTURE/poison" \
    TRELLIS_TEST_TSV="$FIXTURE/native-timing.tsv" bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only' _ "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'native-cargo-only'* && "$output" == *'narrowed'* ]] || { echo "$output"; false; }
  [ ! -e "$OUTSIDE_GIT" ] || { echo 'outside mutation escaped the fence'; false; }
  [ "$(wc -l < "$CALL_COUNT" | tr -d ' ')" -eq 1 ] || { echo 'Cargo invoked more than once'; false; }
  run python3 -I - "$CALL_RECORD" "$PROJECT/native/trellis-hooks/Cargo.toml" <<'PY'
from pathlib import Path
import sys
args = Path(sys.argv[1]).read_bytes().split(b'\0')
assert args == [b'test', b'--locked', b'--offline', b'--manifest-path', sys.argv[2].encode(), b''], args
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FIXTURE/native-timing.tsv" | tr -d ' ')" -eq 2 ] || false
}

@test "native-only fails closed on Cargo failure and unavailable or corrupt cache" {
  setup_native_only_runner
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification FAKE_CARGO_RC=19 \
    TRELLIS_TEST_TSV="$FIXTURE/failure-timing.tsv" bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only' _ "$PROJECT"
  [ "$status" -eq 1 ] && [[ "$output" == *'stage(s) failed'* ]] || { echo "$output"; false; }
  awk -F '\t' 'NR==2 {if ($4!=19) exit 1; found=1} END {if (!found) exit 1}' "$FIXTURE/failure-timing.tsv" || false
  [ "$(wc -l < "$CALL_COUNT" | tr -d ' ')" -eq 1 ] || false
  rm -f "$CALL_RECORD" "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only' _ "$PROJECT"
  [ "$status" -eq 1 ] && [[ "$output" == *'unavailable offline'* ]] || { echo "$output"; false; }
  [ ! -e "$CALL_RECORD" ] || false
  printf 'tampered\n' > "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only' _ "$PROJECT"
  [ "$status" -eq 1 ] && [[ "$output" == *'checksum mismatch'* ]] || { echo "$output"; false; }
  [ ! -e "$CALL_RECORD" ] || false
  printf 'fixture archive\n' > "$CARGO_HOME/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
  rm "$TOOLCHAIN/bin/rustc"
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only' _ "$PROJECT"
  [ "$status" -eq 1 ] && [[ "$output" == *'unavailable offline'* ]] || { echo "$output"; false; }
  [ ! -e "$CALL_RECORD" ] && [ "$(wc -l < "$CALL_COUNT" | tr -d ' ')" -eq 1 ] || false
}
