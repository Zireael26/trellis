#!/usr/bin/env bats
# scripts/tests/test-equivalence.sh is the R1 evidence for verbatim suite splits
# (spec 057 §4 R1, amendment A1 F1). The fixture is a six-test original and a
# correct two-way split of it. Each red case makes one change to the split and
# asserts the exact set of FAIL rows, so a case can only pass by failing for the
# reason it names.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
TOOL="$REPO_ROOT/scripts/tests/test-equivalence.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/test-equivalence"
P1="t/sample-part1.bats"
P2="t/sample-part2.bats"

setup() {
  BASE="$BATS_TEST_TMPDIR/base"
  SPLIT="$BATS_TEST_TMPDIR/split"
  mkdir -p "$BASE/t" "$SPLIT/t"
  cp "$FIXTURE/sample.bats" "$FIXTURE/equiv-helper.bash" "$BASE/t/"
  cp "$FIXTURE/sample-part1.bats" "$FIXTURE/sample-part2.bats" \
    "$FIXTURE/equiv-helper.bash" "$SPLIT/t/"
}

run_diff() {
  run "$TOOL" diff --base "$BASE" --split "$SPLIT" "$@" t/sample.bats
}

# rewrite FILE SED-SCRIPT: in-place edit that behaves the same on BSD and GNU.
rewrite() {
  sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}

# block FILE HEADER-REGEX: print the block whose first line matches, through
# its column-0 closing brace.
block() {
  awk -v re="$2" '$0 ~ re { on = 1 } on { print } on && /^}/ { exit }' "$1"
}

drop_block() {
  awk -v re="$2" '$0 ~ re { on = 1 } !on { print } on && /^}/ { on = 0 }' "$1" > "$1.new" &&
    mv "$1.new" "$1"
}

# swap_blocks FILE RE1 RE2: exchange two blocks, RE1's first in the file. Like
# block and drop_block it ends a block at the first column-0 brace, so it is only
# used on blocks without a heredoc or quoted brace.
swap_blocks() {
  awk -v r1="$2" -v r2="$3" '
    { l[NR] = $0 }
    $0 ~ r1 && !s1 { s1 = NR; o = 1 }
    $0 ~ r2 && !s2 { s2 = NR; o = 2 }
    o && /^}/ { if (o == 1) e1 = NR; else e2 = NR; o = 0 }
    END {
      for (i = 1; i < s1; i++) print l[i]
      for (i = s2; i <= e2; i++) print l[i]
      for (i = e1 + 1; i < s2; i++) print l[i]
      for (i = s1; i <= e1; i++) print l[i]
      for (i = e2 + 1; i <= NR; i++) print l[i]
    }' "$1" > "$1.new" && mv "$1.new" "$1"
}

# expect_fails EXPECTED: the FAIL rows' part, kind, name and detail, exactly.
expect_fails() {
  local actual
  actual="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "FAIL" { print $3 "\t" $4 "\t" $5 "\t" $6 }')"
  if [ "$actual" != "$1" ]; then
    printf 'expected FAIL rows:\n%s\nactual FAIL rows:\n%s\nfull output:\n%s\n' "$1" "$actual" "$output"
    return 1
  fi
}

@test "a correct two-way split with byte-identical file-level items is green" {
  run_diff
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  expect_fails ""
  printf '%s\n' "$output" | grep -qxF "$(printf 'OK\tt/sample.bats\t-\tsummary\t-\t6 tests, 2 part(s), bats --count 6')"
}

@test "emit hashes every item kind, is stable, and matches bats --count" {
  run "$TOOL" emit --tree "$BASE" t/sample.bats
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  local first="$output" kinds
  kinds="$(printf '%s\n' "$first" | awk -F '\t' 'NR > 2 { n[$3]++ } END { for (k in n) print k "=" n[k] }' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$kinds" = "count=1 function=1 helper=1 lifecycle=4 test=6 toplevel=2 " ] || { echo "$kinds"; false; }
  printf '%s\n' "$first" | grep -qxF "$(printf 't/sample.bats\tt/sample.bats\tcount\t-\tbats --count\t6')"
  printf '%s\n' "$first" | awk -F '\t' '$3 == "lifecycle" { print $5 }' | tr '\n' ' ' |
    grep -qxF 'setup setup_file teardown teardown_file '
  printf '%s\n' "$first" | awk -F '\t' '$3 == "test" { print $4 ":" $5 }' | sed -n 5p |
    grep -qxF '5:echo — a non-ASCII name'
  run "$TOOL" emit --tree "$BASE" t/sample.bats
  [ "$output" = "$first" ]
}

@test "git refs and an explicit map give the same green verdict" {
  local repo="$BATS_TEST_TMPDIR/repo" base_sha
  mkdir -p "$repo"
  cp -R "$BASE/t" "$repo/t"
  git -C "$repo" init -q
  git -C "$repo" config user.email equiv@test.invalid
  git -C "$repo" config user.name equiv-test
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" rm -q t/sample.bats
  cp "$SPLIT/t/sample-part1.bats" "$SPLIT/t/sample-part2.bats" "$repo/t/"
  git -C "$repo" add -A
  git -C "$repo" commit -qm split
  printf '# F2 map\nt/sample.bats -> %s %s\n' "$P1" "$P2" > "$BATS_TEST_TMPDIR/map"
  cd "$repo"
  run "$TOOL" diff --base "$base_sha" --split HEAD --map "$BATS_TEST_TMPDIR/map" \
    --emit-dir "$BATS_TEST_TMPDIR/receipt"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(cat "$BATS_TEST_TMPDIR/receipt/report.tsv")" = "$output" ]
  [ "$(awk -F '\t' '$3 == "test"' "$BATS_TEST_TMPDIR/receipt/split.tsv" | wc -l | tr -d ' ')" -eq 6 ]
  printf '%s\n' "$output" | sed -n 1p | grep -qxF "# test-equivalence diff base=$base_sha split=$(git rev-parse HEAD)"
}

@test "red: a renamed test" {
  rewrite "$SPLIT/$P1" 's/^@test "bravo keeps/@test "bravo still keeps/'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\ttest\tbravo still keeps a heredoc brace\tnot in the original (added or renamed)\n-\ttest\tbravo keeps a heredoc brace\tdropped: in the original, in no part' "$P1")"
}

@test "red: an edited test body" {
  rewrite "$SPLIT/$P2" 's/= "hello" ]/= "hi" ]/'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\ttest\tdelta uses the helper\tbody differs from the original' "$P2")"
}

@test "red: an edited helper file" {
  rewrite "$SPLIT/t/equiv-helper.bash" "s/printf 'hello/printf 'hullo/"
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\thelper\tt/equiv-helper.bash\tdiffers from the original\n%s\thelper\tt/equiv-helper.bash\tdiffers from the original' "$P1" "$P2")"
}

@test "red: a dropped test" {
  drop_block "$SPLIT/$P2" '^@test "foxtrot'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf -- '-\ttest\tfoxtrot reads the top-level export\tdropped: in the original, in no part\n-\tcount\tbats --count\tparts sum to 5, original has 6')"
}

@test "red: a reordered test" {
  swap_blocks "$SPLIT/$P2" '^@test "delta' '^@test "echo'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\torder\techo — a non-ASCII name\tposition 4 of the concatenated parts; the original has delta uses the helper there' "$P2")"
}

@test "red: parts listed out of order" {
  printf 't/sample.bats -> %s %s\n' "$P2" "$P1" > "$BATS_TEST_TMPDIR/map"
  run "$TOOL" diff --base "$BASE" --split "$SPLIT" --map "$BATS_TEST_TMPDIR/map"
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\torder\tdelta uses the helper\tposition 1 of the concatenated parts; the original has alpha writes json there' "$P2")"
}

@test "red: setup_file edited in one part" {
  rewrite "$SPLIT/$P2" 's#/mark"$#/mark2"#'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\tlifecycle\tsetup_file\tdiffers from the original' "$P2")"
  printf '%s\n' "$output" | grep -q "^NOT-OK$(printf '\t')t/sample.bats"
}

@test "red: a part that omits the original's setup_file" {
  drop_block "$SPLIT/$P1" '^setup_file\(\)'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\tlifecycle\tsetup_file\tmissing from this part' "$P1")"
}

@test "red: teardown_file edited in one part" {
  rewrite "$SPLIT/$P1" 's/rm -f "\$EQUIV_FILE_MARK"/rm -rf "$EQUIV_FILE_MARK"/'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\tlifecycle\tteardown_file\tdiffers from the original' "$P1")"
}

@test "red: an edited top-level statement" {
  rewrite "$SPLIT/$P1" 's/^export EQUIV_FIXTURE_MODE=original$/export EQUIV_FIXTURE_MODE=split/'
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\ttoplevel\texport EQUIV_FIXTURE_MODE=split\tstatement 2 differs; the original has: export EQUIV_FIXTURE_MODE=original' "$P1")"
}

@test "red: one name in two parts" {
  { printf '\n'; block "$SPLIT/$P2" '^@test "delta'; } >> "$SPLIT/$P1"
  run_diff
  [ "$status" -eq 1 ]
  expect_fails "$(printf '%s\ttest\tdelta uses the helper\tname also appears in %s (a name may live in one part only)\n-\tcount\tbats --count\tparts sum to 7, original has 6' "$P2" "$P1")"
}

@test "a reviewed setup_file change passes and is reported as REVIEWED" {
  rewrite "$SPLIT/$P2" 's#/mark"$#/mark2"#'
  printf 't/sample.bats\t%s\tlifecycle\tsetup_file\topenai\trenamed the mark file\tno test reads the mark path\n' "$P2" \
    > "$BATS_TEST_TMPDIR/review"
  run_diff --review "$BATS_TEST_TMPDIR/review"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | awk -F '\t' '$1 == "REVIEWED" && $3 == "t/sample-part2.bats" && $5 == "setup_file"' | grep -q .
}

@test "red: a review entry that matches no difference" {
  printf 't/sample.bats\t*\tfunction\twrite_json\topenai\tnothing\tnothing\n' > "$BATS_TEST_TMPDIR/review"
  run_diff --review "$BATS_TEST_TMPDIR/review"
  [ "$status" -eq 1 ]
  expect_fails "$(printf '*\tfunction\twrite_json\treview entry (line 1) matches no difference')"
}

@test "a review entry cannot waive a test body" {
  rewrite "$SPLIT/$P2" 's/= "hello" ]/= "hi" ]/'
  printf 't/sample.bats\t%s\ttest\tdelta uses the helper\topenai\tx\ty\n' "$P2" > "$BATS_TEST_TMPDIR/review"
  run_diff --review "$BATS_TEST_TMPDIR/review"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be reviewed"* ]]
}

@test "the naming convention refuses a gap and a surviving original" {
  mv "$SPLIT/$P2" "$SPLIT/t/sample-part3.bats"
  run_diff
  [ "$status" -eq 2 ]
  [[ "$output" == *"t/sample-part2.bats is missing"* ]]
  mv "$SPLIT/t/sample-part3.bats" "$SPLIT/$P2"
  cp "$BASE/t/sample.bats" "$SPLIT/t/sample.bats"
  run_diff
  [ "$status" -eq 2 ]
  [[ "$output" == *"has both t/sample.bats and its -partN files"* ]]
}

@test "an unsplit file maps to itself" {
  run "$TOOL" diff --base "$BASE" --split "$BASE" t/sample.bats
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | grep -qxF "$(printf 'OK\tt/sample.bats\t-\tsummary\t-\t6 tests, 1 part(s), bats --count 6')"
}

@test "a block the parser cannot close is refused, not guessed" {
  printf '@test "zulu never closes" {\n  cat <<EOF\n  true\n' >> "$SPLIT/$P2"
  run_diff
  [ "$status" -eq 2 ]
  [[ "$output" == *"unterminated"* ]]
}
