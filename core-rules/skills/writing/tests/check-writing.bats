#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-writing.sh"
FIXTURES="$BATS_TEST_DIRNAME/../scripts/fixtures"

@test "red blog exits 1" {
  run "$SCRIPT" --blog "$FIXTURES/red-blog.md"
  [ "$status" -eq 1 ]
}

@test "red blog names dash offense" {
  run "$SCRIPT" --blog "$FIXTURES/red-blog.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dash:"* ]]
}

@test "red blog names slop vocab offense" {
  run "$SCRIPT" --blog "$FIXTURES/red-blog.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"slop vocab:"* ]]
}

@test "red blog names bold lead-in offense" {
  run "$SCRIPT" --blog "$FIXTURES/red-blog.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bold lead-in bullet"* ]]
}

@test "red blog names antithesis offense" {
  run "$SCRIPT" --blog "$FIXTURES/red-blog.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"antithesis pattern"* ]]
}

@test "green blog exits 0" {
  run "$SCRIPT" --blog "$FIXTURES/green-blog.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "blog: checked "* ]]
}

@test "red thread exits 1 and names count length and link offenses" {
  run "$SCRIPT" --thread "$FIXTURES/red-thread.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"thread count:"* ]]
  [[ "$output" == *"thread length:"* ]]
  [[ "$output" == *"thread link:"* ]]
}

@test "green thread exits 0" {
  run "$SCRIPT" --thread "$FIXTURES/green-thread.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "thread: checked 5 blocks; 0 offenses" ]]
}

@test "fenced em dash is not counted" {
  run "$SCRIPT" --blog "$FIXTURES/green-blog.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"dash:"* ]]
}

@test "missing file exits 2" {
  run "$SCRIPT" --blog "$FIXTURES/missing.md"
  [ "$status" -eq 2 ]
  [[ "$output" == usage:* ]]
}

@test "red blog names extended slop terms (journey / comprehensive / landscape)" {
  run "$SCRIPT" --blog "$FIXTURES/red-blog.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"journey"* ]]
  [[ "$output" == *"comprehensive"* ]]
  [[ "$output" == *"landscape"* ]]
  [[ "$output" == *"navigate-the"* ]]
}

@test "period-separated antithesis form is counted" {
  tmp="$(mktemp)"
  {
    echo "The gate is not a formality. It is the contract."
    echo "The loop is not automation. It is a liability."
    echo "The spec is not paperwork. This is the design."
    echo "The review is not a rubber stamp. That is the point."
  } > "$tmp"
  run "$SCRIPT" --blog "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"antithesis pattern"* ]]
}
