#!/usr/bin/env bats

SOURCE_ROOT="$(CDPATH= cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
FIXTURE_ROOT="$BATS_TEST_DIRNAME/fixtures/decisions-log"

run_validator() {
  local validator="${CHECK_DECISIONS_LOG:-$SOURCE_ROOT/scripts/check-decisions-log.sh}"
  run bash "$validator" "$@"
}

assert_output_contains() {
  local expected="$1"
  case "$output" in
    *"$expected"*) ;;
    *)
      printf 'expected output to contain:\n%s\nactual output:\n%s\n' "$expected" "$output" >&2
      return 1
      ;;
  esac
}

assert_output_excludes() {
  local unexpected="$1"
  case "$output" in
    *"$unexpected"*)
      printf 'expected output not to contain:\n%s\nactual output:\n%s\n' "$unexpected" "$output" >&2
      return 1
      ;;
    *) ;;
  esac
}

assert_trailing_summary() {
  local expected="$1"
  local last_index=$(( ${#lines[@]} - 1 ))
  if [ "${lines[$last_index]}" != "$expected" ]; then
    printf 'expected trailing summary:\n%s\nactual last line:\n%s\n' \
      "$expected" "${lines[$last_index]}" >&2
    return 1
  fi
}

@test "the pilot-alternatives (captured PRE-fix snapshot, 2026-08-30) rejects 52 candidates with zero valid entries" {
  local fixture="$FIXTURE_ROOT/pilot-alternatives-captured-pre-fix-2026-08-30.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains "$fixture: candidates=52 valid=0 kinds_ok=true surfaced=0/0 verdict=FAIL"
  assert_output_contains 'line 2: Alternatives: (expected "Alternatives considered:")'
  assert_output_contains 'line 6: Alternatives: (expected "Alternatives considered:")'
  assert_output_contains "...and 47 more"
  assert_output_excludes "line 7:"
  assert_trailing_summary "$fixture: candidates=52 valid=0 kinds_ok=true surfaced=0/0 verdict=FAIL"
}

@test "missing-leading-bullet remains a candidate and fails validation" {
  local fixture="$FIXTURE_ROOT/missing-leading-bullet.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains "$fixture: candidates=1 valid=0 kinds_ok=true surfaced=0/0"
  assert_output_contains 'line 1: missing leading "- "'
  assert_output_contains "annotations must use a # heading, HTML comment, or fenced block"
}

@test "alternatives-label requires exact Alternatives considered label" {
  local fixture="$FIXTURE_ROOT/alternatives-labels.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains "$fixture: candidates=2 valid=1 kinds_ok=true surfaced=0/0"
  assert_output_contains 'line 1: Alternatives: (expected "Alternatives considered:")'
  assert_output_excludes "line 2:"
}

@test "timestamp-space refutation counts 40 content lines and rejects all 40" {
  local fixture="$FIXTURE_ROOT/zero-conforming-timestamp-space.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains "line 2: timestamp not ISO-8601 Z"
  assert_output_contains "...and 35 more"
  assert_trailing_summary "$fixture: candidates=40 valid=0 kinds_ok=true surfaced=0/0 verdict=FAIL"
}

@test "indented-bullet refutation counts 40 content lines and rejects all 40" {
  local fixture="$FIXTURE_ROOT/zero-conforming-indented-bullet.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains 'line 2: missing leading "- "'
  assert_output_contains "...and 35 more"
  assert_trailing_summary "$fixture: candidates=40 valid=0 kinds_ok=true surfaced=0/0 verdict=FAIL"
}

@test "asterisk-bullet refutation counts 40 content lines and rejects all 40" {
  local fixture="$FIXTURE_ROOT/zero-conforming-asterisk-bullet.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains 'line 2: missing leading "- "'
  assert_output_contains "...and 35 more"
  assert_trailing_summary "$fixture: candidates=40 valid=0 kinds_ok=true surfaced=0/0 verdict=FAIL"
}

@test "Markdown headings comments and fenced examples stay outside the denominator" {
  local fixture="$FIXTURE_ROOT/markdown-scaffolding.log"

  run_validator "$fixture"

  [ "$status" -eq 0 ]
  assert_trailing_summary "$fixture: candidates=1 valid=1 kinds_ok=true surfaced=0/0 verdict=PASS"
}

@test "unlisted-kind reports audit-remediation and exact line 3" {
  local fixture="$FIXTURE_ROOT/unlisted-kind.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains "$fixture: candidates=1 valid=0 kinds_ok=false surfaced=0/0"
  assert_output_contains "line 3: unlisted kind [audit-remediation]"
}

@test "unlisted-kind-in-conforming-file rejects 75 candidates with 74 valid and names line 39" {
  local fixture="$FIXTURE_ROOT/unlisted-kind-in-conforming-file.log"

  run_validator "$fixture"

  [ "$status" -ne 0 ]
  assert_output_contains "line 39: unlisted kind [audit-remediation]"
  assert_trailing_summary "$fixture: candidates=75 valid=74 kinds_ok=false surfaced=0/0 verdict=FAIL"
}

@test "surfaced-some accepts the optional marker on only some architectural entries" {
  local fixture="$FIXTURE_ROOT/surfaced-some.log"

  run_validator "$fixture"

  [ "$status" -eq 0 ]
  assert_output_contains "$fixture: candidates=2 valid=2 kinds_ok=true surfaced=1/2"
  assert_output_excludes "SUSPICIOUS"
}

@test "surfaced-all passes and emits SUSPICIOUS" {
  local fixture="$FIXTURE_ROOT/surfaced-all.log"

  run_validator "$fixture"

  [ "$status" -eq 0 ]
  assert_output_contains "$fixture: candidates=2 valid=2 kinds_ok=true surfaced=2/2"
  assert_output_contains "SUSPICIOUS: all architectural entries carry SURFACED INLINE"
}

@test "surfaced-none accepts architectural entries without the marker" {
  local fixture="$FIXTURE_ROOT/surfaced-none.log"

  run_validator "$fixture"

  [ "$status" -eq 0 ]
  assert_output_contains "$fixture: candidates=2 valid=2 kinds_ok=true surfaced=0/2"
  assert_output_excludes "SUSPICIOUS"
}

@test "clean-file accepts the canonical grammar" {
  local fixture="$FIXTURE_ROOT/clean.log"

  run_validator "$fixture"

  [ "$status" -eq 0 ]
  assert_output_contains "$fixture: candidates=1 valid=1 kinds_ok=true surfaced=0/0"
  assert_output_excludes "candidate does not match ENTRY"
  assert_output_excludes "unlisted kind"
  assert_output_excludes "SUSPICIOUS"
  assert_trailing_summary "$fixture: candidates=1 valid=1 kinds_ok=true surfaced=0/0 verdict=PASS"
}

@test "empty-file passes with a note" {
  local fixture="$FIXTURE_ROOT/empty.log"

  run_validator "$fixture"

  [ "$status" -eq 0 ]
  assert_output_contains "$fixture: candidates=0 valid=0 kinds_ok=true surfaced=0/0"
  assert_output_contains "note: file empty"
  assert_output_contains "no decision entries found in file $fixture"
  assert_output_contains "does not and cannot check whether a decisions block was rendered in a session reply"
  assert_trailing_summary "$fixture: candidates=0 valid=0 kinds_ok=true surfaced=0/0 verdict=PASS"
}

@test "missing-file passes with a note" {
  local fixture="$FIXTURE_ROOT/missing.log"
  [ ! -e "$fixture" ]

  run_validator "$fixture"

  [ "$status" -eq 0 ]
  assert_output_contains "$fixture: candidates=0 valid=0 kinds_ok=true surfaced=0/0"
  assert_output_contains "note: file missing"
  assert_output_contains "no decision entries found in file $fixture"
  assert_output_contains "does not and cannot check whether a decisions block was rendered in a session reply"
  assert_trailing_summary "$fixture: candidates=0 valid=0 kinds_ok=true surfaced=0/0 verdict=PASS"
}

@test "json-contract parses with human-equivalent counts and findings" {
  local pilot="$FIXTURE_ROOT/pilot-alternatives-captured-pre-fix-2026-08-30.log"
  local unlisted="$FIXTURE_ROOT/unlisted-kind.log"
  local surfaced="$FIXTURE_ROOT/surfaced-all.log"
  local missing="$FIXTURE_ROOT/missing.log"

  run_validator --json "$pilot" "$unlisted" "$surfaced" "$missing"

  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | jq -e \
    --arg pilot "$pilot" \
    --arg unlisted "$unlisted" \
    --arg surfaced "$surfaced" \
    --arg missing "$missing" '
      (.files | length) == 4
      and all(.files[]; .scope == "file")
      and .ok == false
      and any(.files[];
        .path == $pilot
        and .candidates == 52
        and .valid == 0
        and .kinds_ok == true
        and .surfaced == 0
        and .architectural == 0
        and .verdict == "FAIL"
        and (.findings | length) == 52
        and (.findings | index("line 2: Alternatives: (expected \"Alternatives considered:\")")) != null
        and (.findings | index("line 53: Alternatives: (expected \"Alternatives considered:\")")) != null)
      and any(.files[];
        .path == $unlisted
        and .candidates == 1
        and .valid == 0
        and .kinds_ok == false
        and .surfaced == 0
        and .architectural == 0
        and (.findings | length) == 1
        and (.findings | index("line 3: unlisted kind [audit-remediation]")) != null)
      and any(.files[];
        .path == $surfaced
        and .candidates == 2
        and .valid == 2
        and .kinds_ok == true
        and .surfaced == 2
        and .architectural == 2
        and (.findings | index("SUSPICIOUS: all architectural entries carry SURFACED INLINE")) != null)
      and any(.files[];
        .path == $missing
        and .candidates == 0
        and .valid == 0
        and .kinds_ok == true
        and .surfaced == 0
        and .architectural == 0
        and any(.findings[]; startswith("note: file missing; no decision entries found in file "))
        and any(.findings[]; contains("does not and cannot check whether a decisions block was rendered in a session reply")))
    ' >/dev/null
}
