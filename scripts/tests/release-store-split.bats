#!/usr/bin/env bats
# The split cannot drop, duplicate or edit any original assertion.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CHECK="$REPO_ROOT/scripts/tests/check-release-store-split.sh"

setup() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/scripts/tests"
  ORIGINAL="$TREE/scripts/tests/release-store-original.txt"
  PART="$TREE/scripts/tests/release-store-part1.bats"
  # Do not put literal @test headers in a heredoc in a Bats source: its
  # preprocessor rewrites them even there.
  printf '%s\n' '@test "a heredoc brace is part of the body" {' \
    '  cat <<JSON' '{"unchanged":true}' 'JSON' '  [ 1 -eq 1 ]' '}' \
    '@test "a second case" {' '  [ 2 -eq 2 ]' '}' > "$ORIGINAL"
  cp "$ORIGINAL" "$PART"
}

@test "release-store parts retain every original test name and body byte for byte" {
  run bash "$CHECK"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'OK: 86 release-store test names and bodies are byte-identical'* ]]
}

@test "release-store split check accepts an unchanged union and rejects a dropped case" {
  run bash "$CHECK" "$TREE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  head -n 6 "$ORIGINAL" > "$PART"
  run bash "$CHECK" "$TREE"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'dropped: a second case'* ]]
}

@test "release-store split check rejects the same case in two parts" {
  cp "$PART" "$TREE/scripts/tests/release-store-part2.bats"
  run bash "$CHECK" "$TREE"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'doubled: a second case'* ]]
}

@test "release-store split check rejects an edited body including heredoc bytes" {
  sed 's/"unchanged":true/"unchanged":false/' "$ORIGINAL" > "$PART"
  run bash "$CHECK" "$TREE"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'edited: a heredoc brace is part of the body'* ]]
}
