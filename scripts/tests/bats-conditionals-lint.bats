#!/usr/bin/env bats
# Bash 3.2 errexit ignores a false [[ ]], so a bare one inside a Bats test or
# helper cannot fail it on stock macOS (decisions-log 2026-11-10, "Bash 3.2
# assertions"). scripts/lint-bats-conditionals.py refuses new ones; this suite
# runs it over the tree and pins what it does and does not flag.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME/../.." rev-parse --show-toplevel)"
LINT="$REPO_ROOT/scripts/lint-bats-conditionals.py"
# Fixture files, not heredocs: Bats preprocessing rewrites every `@test` line
# in a suite, heredoc bodies included.
FIXTURES="$REPO_ROOT/scripts/tests/fixtures/bats-conditionals"

setup() {
  WORK="$BATS_TEST_TMPDIR/lint"
  mkdir -p "$WORK"
}

@test "the tree has no bare [[ ]] statement in Bats tests or test helpers" {
  run python3 -I "$LINT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "a bare mid-test [[ ]] is flagged, with its file and line" {
  run --separate-stderr python3 -I "$LINT" "$FIXTURES/bare.bats"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output" "$stderr"; false; }
  [ "${lines[0]}" = "$FIXTURES/bare.bats:3:[[ \"\$output\" == *x* ]]" ] || { printf '%s\n' "$output"; false; }
  [ "${lines[1]}" = "$FIXTURES/bare.bats:7:[[ -n \"\$1\" ]]   # trailing comment" ] || { printf '%s\n' "$output"; false; }
  [ "${#lines[@]}" -eq 2 ] || { printf '%s\n' "$output"; false; }
  [[ "$stderr" == "2 bare [[ ]] statement(s) inside Bats tests or helpers"* ]] || { printf '%s\n' "$stderr"; false; }
}

@test "guarded, conditional, continued, quoted and heredoc [[ ]] are not flagged" {
  run python3 -I "$LINT" "$FIXTURES/clean.bats"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  # Not vacuous: the same file with its first guard removed is flagged.
  sed '2s/ || false$//' "$FIXTURES/clean.bats" > "$WORK/unguarded.bats"
  run python3 -I "$LINT" "$WORK/unguarded.bats"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"unguarded.bats:2:"* ]] || { printf '%s\n' "$output"; false; }
}

@test "--fix appends || false before any comment and leaves the file lint-clean" {
  printf '%s\n' '@test "t" {' '  [[ -n "$x" ]]  # why' '  [[ a == a ]]' '}' > "$WORK/fix.bats"
  run python3 -I "$LINT" "$WORK/fix.bats"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  run python3 -I "$LINT" --fix "$WORK/fix.bats"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(sed -n 2p "$WORK/fix.bats")" = '  [[ -n "$x" ]] || false # why' ] || { cat "$WORK/fix.bats"; false; }
  [ "$(sed -n 3p "$WORK/fix.bats")" = '  [[ a == a ]] || false' ] || { cat "$WORK/fix.bats"; false; }
  run python3 -I "$LINT" "$WORK/fix.bats"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "on /bin/bash 3.2 a bare false [[ ]] mid-test passes and || false fails it" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  case "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" in
    3.*|4.0) ;;
    *) skip "/bin/bash is 4.1 or later: [[ ]] is errexit-visible there" ;;
  esac
  mkdir -p "$WORK/bash32"
  ln -s /bin/bash "$WORK/bash32/bash"
  printf '%s\n' '@test "inert" {' '  [[ a == b ]]' '  true' '}' > "$WORK/inert.bats"
  printf '%s\n' '@test "live" {' '  [[ a == b ]] || false' '  true' '}' > "$WORK/live.bats"
  run env PATH="$WORK/bash32:$PATH" bats "$WORK/inert.bats"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run env PATH="$WORK/bash32:$PATH" bats "$WORK/live.bats"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
}
