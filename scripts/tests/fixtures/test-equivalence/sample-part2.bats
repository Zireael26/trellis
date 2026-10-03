#!/usr/bin/env bats
# Fixture for scripts/tests/test-equivalence.bats: part 2 of a correct 2-way
# split of sample.bats. File-level items are copied byte-identical.

load equiv-helper
export EQUIV_FIXTURE_MODE=original

setup_file() {
  export EQUIV_FILE_MARK="$BATS_FILE_TMPDIR/mark"
  : > "$EQUIV_FILE_MARK"
}

teardown_file() {
  rm -f "$EQUIV_FILE_MARK"
}

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
}

teardown() {
  rm -rf "$WORK"
}

write_json() {
  cat > "$1" <<'JSON'
{
  "alpha": 1
}
JSON
}

@test "delta uses the helper" {
  [ "$(equiv_helper_greet)" = "hello" ]
}

@test "echo — a non-ASCII name" {
  [ -f "$EQUIV_FILE_MARK" ]
}

@test "foxtrot reads the top-level export" {
  [ "$EQUIV_FIXTURE_MODE" = "original" ]
}
