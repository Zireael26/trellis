#!/usr/bin/env bats
# Fixture for scripts/tests/test-equivalence.bats: the original suite that
# sample-part1.bats and sample-part2.bats split verbatim. Not a registered suite.

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

@test "alpha writes json" {
  write_json "$WORK/a.json"
  [ -s "$WORK/a.json" ]
}

@test "bravo keeps a heredoc brace" {
  cat > "$WORK/b.txt" <<EOF
}
EOF
  [ "$(cat "$WORK/b.txt")" = "}" ]
}

@test "charlie spans a quoted brace" {
  local text='line one
}
line three'
  [ "$(printf '%s\n' "$text" | wc -l | tr -d ' ')" -eq 3 ]
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
