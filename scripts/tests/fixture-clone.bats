#!/usr/bin/env bats
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/fixture-clone

setup() {
  SOURCE="$BATS_TEST_TMPDIR/source tree"
  mkdir -p "$SOURCE/sealed" "$BATS_TEST_TMPDIR/bin"
  printf 'original\n' > "$SOURCE/sealed/file"
  chmod 444 "$SOURCE/sealed/file"
  chmod 555 "$SOURCE/sealed"
  ln -s sealed/file "$SOURCE/link"
  REAL_CP="$(command -v cp)"
  export REAL_CP
}

teardown() {
  find "$BATS_TEST_TMPDIR" -type d -exec chmod u+w {} +
}

assert_independent_copy() {
  python3 -I - "$SOURCE" "$BATS_TEST_TMPDIR/copy" <<'PY'
import os
import stat
import sys
from pathlib import Path
source, copy = map(Path, sys.argv[1:])
for relative in ('sealed', 'sealed/file'):
    a, b = (root / relative for root in (source, copy))
    assert stat.S_IMODE(a.stat().st_mode) == stat.S_IMODE(b.stat().st_mode)
    assert (a.stat().st_dev, a.stat().st_ino) != (b.stat().st_dev, b.stat().st_ino)
assert os.readlink(copy / 'link') == 'sealed/file'
os.chmod(copy / 'sealed/file', 0o644)
(copy / 'sealed/file').write_text('changed\n')
assert (source / 'sealed/file').read_text() == 'original\n'
assert stat.S_IMODE((source / 'sealed/file').stat().st_mode) == 0o444
assert not (copy / 'partial').exists()
PY
}

force_copy_method() {
  export COPY_METHOD="$1" COPY_LOG="$BATS_TEST_TMPDIR/copy.log"
  cat > "$BATS_TEST_TMPDIR/bin/cp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$COPY_LOG"
case "$1:$COPY_METHOD" in
  -cRp:clone) exec "$REAL_CP" -Rp "$2" "$3" ;;
  -Rp:reflink)
    if [ "$2" = --reflink=auto ]; then exec "$REAL_CP" -Rp "$3" "$4"; fi ;;
  -Rp:plain)
    if [ "$2" != --reflink=auto ]; then exec "$REAL_CP" -Rp "$2" "$3"; fi ;;
esac
# Simulate a filesystem rejecting the fast path after a partial copy.
for destination; do :; done
mkdir -p "$destination"
printf 'partial\n' > "$destination/partial"
chmod 555 "$destination"
exit 1
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/cp"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "fixture clone preserves modes and symlinks without sharing writable inodes" {
  fixture_clone "$SOURCE" "$BATS_TEST_TMPDIR/copy"
  assert_independent_copy
}

@test "fixture clone uses the APFS clone path when supported" {
  force_copy_method clone
  fixture_clone "$SOURCE" "$BATS_TEST_TMPDIR/copy"
  [ "$(wc -l < "$COPY_LOG" | tr -d ' ')" -eq 1 ]
  [ "$(< "$COPY_LOG")" = -cRp ]
  assert_independent_copy
}

@test "fixture clone falls back to reflink after a partial clone failure" {
  force_copy_method reflink
  fixture_clone "$SOURCE" "$BATS_TEST_TMPDIR/copy"
  [ "$(wc -l < "$COPY_LOG" | tr -d ' ')" -eq 2 ]
  assert_independent_copy
}

@test "fixture clone falls back to plain copy after both accelerators fail" {
  force_copy_method plain
  fixture_clone "$SOURCE" "$BATS_TEST_TMPDIR/copy"
  [ "$(wc -l < "$COPY_LOG" | tr -d ' ')" -eq 3 ]
  assert_independent_copy
}

@test "fixture clone refuses an existing destination rather than merging fixtures" {
  mkdir "$BATS_TEST_TMPDIR/copy"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/copy/keep"
  run fixture_clone "$SOURCE" "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 1 ]
  [ "$(< "$BATS_TEST_TMPDIR/copy/keep")" = keep ]
  [ ! -e "$BATS_TEST_TMPDIR/copy/sealed" ]
}
