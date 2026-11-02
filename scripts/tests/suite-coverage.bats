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
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/suite-coverage.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
  # shellcheck source=../lib/test-suites.sh
  . "$REPO_ROOT/scripts/lib/test-suites.sh"
}

teardown() {
  rm -rf "$SANDBOX"
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

@test "native launchd agent ownership runs locally but is excluded from Linux CI" {
  [ "$(test_suites_exclusion_scope disk-janitor-agents)" = ci ]
  run test_suites_for ci
  [ "$status" -eq 0 ]
  ! grep -Fxq disk-janitor-agents <<< "$output"
  run test_suites_for local
  [ "$status" -eq 0 ]
  grep -Fxq disk-janitor-agents <<< "$output"
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

@test "core hook and skill files each reach exactly one stage in local and CI" {
  local expected actual scope
  expected="$(python3 -I - "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
patterns = ('core-rules/hooks/tests/*.bats', 'core-rules/codex/hooks/tests/*.bats',
            'core-rules/skills/*/tests/*.bats')
for path in sorted(path for pattern in patterns for path in root.glob(pattern)):
    print('bats ' + path.relative_to(root).as_posix())
PY
)"
  [ -n "$expected" ]
  for scope in local ci; do
    run bash "$REPO_ROOT/scripts/run-tests.sh" "--scope=$scope" --list
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    actual="$(printf '%s\n' "$output" | grep '^bats core-rules/' | LC_ALL=C sort)"
    [ "$actual" = "$expected" ] || { echo "$scope dropped or doubled a core suite: $actual"; false; }
    run grep -Ex 'skill gates|hooks \(claude \+ codex\)' <<< "$output"
    [ "$status" -eq 1 ]
  done
}

core_inventory_fixture() {
  local path
  INVENTORY_REPO="$SANDBOX/repo"
  mkdir -p "$INVENTORY_REPO/scripts"
  for path in core-rules/codex/hooks/tests/sample.bats core-rules/hooks/tests/sample.bats \
    core-rules/skills/example/tests/sample.bats; do
    mkdir -p "$INVENTORY_REPO/${path%/*}"
    printf '@test "sample" {\n  true\n}\n' > "$INVENTORY_REPO/$path"
  done
  git -C "$INVENTORY_REPO" init -q
  git -C "$INVENTORY_REPO" config user.name Fixture
  git -C "$INVENTORY_REPO" config user.email fixture@trellis.invalid
  git -C "$INVENTORY_REPO" config commit.gpgsign false
  printf '#!/usr/bin/env bash\nprintf "hooks (claude + codex)\\nskill gates\\n"\n' > "$INVENTORY_REPO/scripts/run-tests.sh"
  git -C "$INVENTORY_REPO" add .
  git -C "$INVENTORY_REPO" commit -qm 'test: grouped core stages'
  INVENTORY_BASE="$(git -C "$INVENTORY_REPO" rev-parse HEAD)"
  printf '#!/usr/bin/env bash\n' > "$INVENTORY_REPO/scripts/run-tests.sh"
  for path in core-rules/codex/hooks/tests/sample.bats core-rules/hooks/tests/sample.bats \
    core-rules/skills/example/tests/sample.bats; do
    printf "printf 'bats %s\\\\n'\n" "$path" >> "$INVENTORY_REPO/scripts/run-tests.sh"
  done
  cp "$INVENTORY_REPO/scripts/run-tests.sh" "$SANDBOX/per-file-runner"
}

check_core_inventory() {
  local stages
  git -C "$INVENTORY_REPO" add .
  git -C "$INVENTORY_REPO" commit -qm 'test: per-file core stages'
  INVENTORY_HEAD="$(git -C "$INVENTORY_REPO" rev-parse HEAD)"
  stages="$(bash "$INVENTORY_REPO/scripts/run-tests.sh" --scope=local --list)" || return 1
  {
    printf 'ordinal\tstage\telapsed_seconds\texit\n'
    printf '%s\n' "$stages" | awk '{ printf "%s\t%s\t1\t0\n", NR, $0 }'
  } > "$SANDBOX/aggregate.tsv"
  run bash -c 'cd "$1" && bash "$2/scripts/check-gate-inventory.sh" "$3" "$4" "$5"' \
    fixture "$INVENTORY_REPO" "$REPO_ROOT" "$INVENTORY_BASE" "$INVENTORY_HEAD" "$SANDBOX/aggregate.tsv"
}

@test "immutable inventory accepts the exact per-file core split without a doctor split" {
  core_inventory_fixture
  check_core_inventory
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "inventory: PASS "* ]]
}

@test "immutable inventory rejects dropped or doubled hook and skill files even with complete head evidence" {
  local group mutation
  core_inventory_fixture
  for group in hooks skills; do
    for mutation in dropped doubled; do
      cp "$SANDBOX/per-file-runner" "$INVENTORY_REPO/scripts/run-tests.sh"
      python3 -I - "$INVENTORY_REPO/scripts/run-tests.sh" "$group" "$mutation" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
index = next(i for i, line in enumerate(lines) if '/'+sys.argv[2]+'/' in line)
if sys.argv[3] == 'dropped':
    del lines[index]
else:
    lines.insert(index, lines[index])
path.write_text(''.join(lines))
PY
      check_core_inventory
      [ "$status" -eq 1 ] || { echo "$group $mutation incorrectly passed: $output"; false; }
      [[ "$output" == *"head inventory changed"* || "$output" == *"duplicate canonical inventory"* ]]
    done
  done
}

@test "immutable inventory keeps existing doctor assertions protected during a core-only split" {
  core_inventory_fixture
  mkdir -p "$INVENTORY_REPO/scripts/tests"
  printf '@test "doctor" {\n  true\n}\n' > "$INVENTORY_REPO/scripts/tests/doctor-fix-part1.bats"
  git -C "$INVENTORY_REPO" add scripts/tests/doctor-fix-part1.bats
  git -C "$INVENTORY_REPO" commit -qm 'test: existing doctor part'
  INVENTORY_BASE="$(git -C "$INVENTORY_REPO" rev-parse HEAD)"
  printf '@test "doctor" {\n  false\n}\n' > "$INVENTORY_REPO/scripts/tests/doctor-fix-part1.bats"
  check_core_inventory
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"doctor-fix files changed without a doctor split"* ]]
}

@test "release-store parts and their equivalence guard are scheduled locally and in CI" {
  local scope suite i suites weights="$REPO_ROOT/scripts/tests/stage-weights.tsv"
  for scope in local ci; do
    suites="$(test_suites_for "$scope")"
    run grep -Fx release-store <<< "$suites"
    [ "$status" -eq 1 ]
    for i in 1 2 3 4 5 split; do
      suite="release-store-part$i"
      [ "$i" != split ] || suite=release-store-split
      printf '%s\n' "$suites" | grep -Fxq "$suite"
      awk -F '\t' -v name="bats scripts/tests/$suite.bats" '
        $1 == name && $2 ~ /^[0-9]+$/ && $2 > 0 { found++ }
        END { exit (found != 1) }' "$weights"
    done
  done
  # Splitting stages must not change the original inner --jobs policy.
  grep -Fq '|pi-attachment|release-store-part*|setup-runbooks|' "$REPO_ROOT/scripts/run-tests.sh"
}

@test "run-tests.sh names no scripts/tests suite by hand except the quick-slice one" {
  local named
  named="$(suites_named_in_code "$REPO_ROOT/scripts/run-tests.sh")"
  # release-store-part1 is named only to build its historical-release cache on
  # the shard that runs it (T25); it is not a hand-listed stage.
  [ "$named" = "posix-bootstrap-prologue release-store-part1 " ] ||
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
