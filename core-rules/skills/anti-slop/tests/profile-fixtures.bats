#!/usr/bin/env bats
# Profiles self-test (spec 037 C4): every profile's fixture PAIR must discriminate
# in the lane that actually ships to a project with no native toolchain installed —
# the shared grep pattern set. red.<ext> yields >= 1 finding, green.<ext> yields 0.
#
# Nothing asserted this before, which is how a green fixture that was not green
# shipped: profiles/python/fixtures/green.py:38 tripped `py-unjustified-cast`
# because its `# SAFETY:` invariant wrapped over two comment lines and the
# suppression scan only looked one line back.
#
# The fixtures are scanned by CONTENT, never by path: `**/fixtures/**` is a
# carve-out glob, precisely so that a project which installs a profile does not
# get findings from the profile's own deliberate-slop payload. Handing these paths
# to audit-slop.sh would therefore report 0 for red and green alike — a self-test
# that passes for the wrong reason.

setup() {
  SKILL="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$(cd "$SKILL/../.." && pwd)/hooks/lib/slop-patterns.sh"
  [ -f "$LIB" ] || skip "pattern lib not found at $LIB"
  # shellcheck disable=SC1090
  . "$LIB"
}

# scan <profile-dir> <basename> <lang> -> finding count on stdout
scan() {
  local file="$SKILL/profiles/$1/fixtures/$2"
  [ -f "$file" ] || { echo "missing fixture: $file" >&2; return 1; }
  slop_scan_text "$3" < "$file" | grep -c . || true
}

@test "typescript profile: red fixture trips the pattern set, green fixture does not" {
  run scan typescript red.ts ts
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.ts produced no findings"; false; }
  run scan typescript green.ts ts
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.ts produced $output findings"; false; }
}

@test "python profile: red fixture trips the pattern set, green fixture does not" {
  run scan python red.py py
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.py produced no findings"; false; }
  run scan python green.py py
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.py produced $output findings"; false; }
}

@test "go profile (dormant): red fixture trips the pattern set, green fixture does not" {
  run scan go red.go go
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.go produced no findings"; false; }
  run scan go green.go go
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.go produced $output findings"; false; }
}

@test "rust profile (dormant): red fixture trips the pattern set, green fixture does not" {
  run scan rust red.rs rs
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.rs produced no findings"; false; }
  run scan rust green.rs rs
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.rs produced $output findings"; false; }
}

@test "java profile (live, pattern layer only): red fixture trips the pattern set, green fixture does not" {
  run scan java red.java java
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.java produced no findings"; false; }
  run scan java green.java java
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.java produced $output findings"; false; }
}

# A multi-line SAFETY invariant is the shape green.py:38 exposed. Asserting it
# directly means the fixture can be rewritten without losing the guarantee.
@test "a SAFETY invariant that wraps over several comment lines still suppresses" {
  run bash -c '
    . "'"$LIB"'"
    printf "%s\n" \
      "    # SAFETY: model_validate has already rejected any payload whose" \
      "    # shape does not match, so the narrowed type holds here." \
      "    return cast(Widget, payload)" | slop_scan_text py'
  [ "$status" -eq 1 ]
  [ -z "$output" ] || { echo "$output"; false; }
}

# The inversion: drop the marker and the same three lines must report, or the test
# above would pass against a scanner that suppresses everything.
@test "the same wrapped comment WITHOUT the marker still reports" {
  run bash -c '
    . "'"$LIB"'"
    printf "%s\n" \
      "    # model_validate has already rejected any payload whose" \
      "    # shape does not match, so the narrowed type holds here." \
      "    return cast(Widget, payload)" | slop_scan_text py'
  [ "$status" -eq 0 ]
  [[ "$output" == *"py-unjustified-cast"* ]] || { echo "$output"; false; }
}

# A comment block does not reach past a line of code: the escape hatch has to sit
# on the construct it justifies, not somewhere above it.
@test "a SAFETY comment separated from the cast by real code does NOT suppress" {
  run bash -c '
    . "'"$LIB"'"
    printf "%s\n" \
      "    # SAFETY: checked upstream." \
      "    payload = normalize(payload)" \
      "    return cast(Widget, payload)" | slop_scan_text py'
  [ "$status" -eq 0 ]
  [[ "$output" == *"py-unjustified-cast"* ]] || { echo "$output"; false; }
}

@test "the pattern lib self-check passes (red/green samples, shape probes, carve-outs)" {
  run bash "$LIB" --self-test
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *FAIL* ]] || { echo "$output"; false; }
}
