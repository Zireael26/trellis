#!/usr/bin/env bats
# The guard that makes the test runner's coverage self-enforcing.
#
# Both `scripts/run-tests.sh` (= PROCESS_GATE_TEST_CMD) and
# `.github/workflows/bats.yml` used to name their suites by hand. Both lists
# drifted to 20 of 57 suites, the 37 omissions were nearly the whole portable
# fleet surface, and one omitted suite sat red at the committed tip for days
# while the gate reported "Tests & coverage: pass". A hand-kept include list
# fails silently. These cases make the failure loud: a new `.bats` file is run,
# or it is named in `TEST_SUITE_EXCLUSIONS` with a reason, or this suite is red.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  # shellcheck source=../lib/test-suites.sh
  . "$REPO_ROOT/scripts/lib/test-suites.sh"
}

# The coverage guarantee comes from the glob in `test_suites_all`, not from an
# accounting pass: a suite is in the local set unless a record removes it, so a
# case that asks "is every suite accounted for" cannot go red for any input —
# a planted orphan suite is auto-globbed by construction. What IS falsifiable,
# and what the guarantee actually rests on, is that the two scopes drop exactly
# the suites their records name and nothing else. `all` is asserted here against
# a synthetic record; `ci` is asserted below against the live list.
@test "an all-scoped exclusion removes exactly its own suite from the local set" {
  local sample before after total
  sample="$(test_suites_all | head -n 1)"
  total="$(test_suites_all | grep -c .)"
  [ -n "$sample" ] || { echo 'no suites found under scripts/tests'; false; }

  before="$(test_suites_for local)"
  if ! printf '%s\n' "$before" | grep -Fxq -- "$sample"; then
    echo "$sample is not in the local set before any record names it"
    false
  fi

  TEST_SUITE_EXCLUSIONS+=("$sample|all|synthetic record, this test only")
  after="$(test_suites_for local)"
  if printf '%s\n' "$after" | grep -Fxq -- "$sample"; then
    echo "$sample survived an all-scoped exclusion"
    false
  fi
  [ "$(printf '%s\n' "$after" | grep -c .)" -eq "$((total - 1))" ] ||
    { echo 'an all-scoped exclusion removed more than the suite it names'; false; }
}

@test "every exclusion record is well formed and names a suite that exists" {
  local record suite scope reason bad=""
  for record in ${TEST_SUITE_EXCLUSIONS[@]+"${TEST_SUITE_EXCLUSIONS[@]}"}; do
    suite="${record%%|*}"
    scope="${record#*|}"; scope="${scope%%|*}"
    reason="${record#*|*|}"
    case "$scope" in
      all|ci) ;;
      *) bad="$bad [$record: scope must be all or ci]" ;;
    esac
    [ -n "$reason" ] && [ "$reason" != "$record" ] ||
      bad="$bad [$record: missing reason]"
    [ -f "$REPO_ROOT/scripts/tests/$suite.bats" ] ||
      bad="$bad [$record: no such suite]"
  done
  [ -z "$bad" ] || { echo "malformed exclusions:$bad"; false; }
}

@test "the CI suite set is the local set minus the ci-scoped exclusions" {
  local extra
  [ -n "$(test_suites_for local)" ] || { echo 'local suite set is empty'; false; }
  [ -n "$(test_suites_for ci)" ] || { echo 'ci suite set is empty'; false; }
  extra="$(comm -13 <(test_suites_for local) <(test_suites_for ci))"
  [ -z "$extra" ] || { echo "ci runs suites local does not: $extra"; false; }
}

# Comment lines are stripped first: both files explain the enumeration in prose
# and would otherwise match themselves.
suites_named_in_code() {
  grep -vE '^[[:space:]]*#' "$1" |
    grep -oE 'scripts/tests/[A-Za-z0-9._-]+\.bats' |
    sed 's#scripts/tests/##; s#\.bats$##' | LC_ALL=C sort -u | tr '\n' ' '
}

@test "every suite reaches a runner stage, and the CI shards partition them exactly" {
  local runner="$REPO_ROOT/scripts/run-tests.sh" whole sharded suite missing="" i
  whole="$(bash "$runner" --scope=ci --list | LC_ALL=C sort)"
  sharded="$(for i in 1 2 3 4; do bash "$runner" --scope=ci --list --shard="$i/4"; done | LC_ALL=C sort)"
  [ "$whole" = "$sharded" ] ||
    { echo 'the four CI shards do not partition the unsharded stage list'; false; }

  # A stage list that silently lost a suite would still partition cleanly, so
  # membership is checked against the enumeration too.
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    printf '%s\n' "$whole" | grep -Fxq -- "bats scripts/tests/$suite.bats" && continue
    [ "$suite" = "posix-bootstrap-prologue" ] || missing="$missing $suite"
  done < <(test_suites_for ci)
  [ -z "$missing" ] || { echo "suites absent from the CI stage list:$missing"; false; }
}

@test "run-tests.sh names no scripts/tests suite by hand except the quick-slice one" {
  local named
  named="$(suites_named_in_code "$REPO_ROOT/scripts/run-tests.sh")"
  [ "$named" = "posix-bootstrap-prologue " ] ||
    { echo "run-tests.sh hand-lists suites: $named"; false; }
}

@test "the bats workflow delegates to run-tests.sh instead of listing suites" {
  local workflow named
  workflow="$REPO_ROOT/.github/workflows/bats.yml"
  run grep -F 'scripts/run-tests.sh' "$workflow"
  [ "$status" -eq 0 ] || { echo 'bats.yml no longer calls scripts/run-tests.sh'; false; }
  named="$(suites_named_in_code "$workflow")"
  [ -z "$named" ] || { echo "bats.yml hand-lists suites: $named"; false; }
}
