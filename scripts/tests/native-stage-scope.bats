#!/usr/bin/env bats
# T41 scope (owner 2026-11-10): the cargo (native) stages run only when a change
# touches a native build input, so unrelated changes are not slower. The input
# set is native/trellis-hooks/** except target/, plus the "inputs" keys of
# core-rules/native/artifacts.json (the build's own list). An unknown base runs
# the stages, and a skip is always a labelled line, never a silent pass.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/native-stage-scope.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset TRELLIS_SLOW_TESTS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
  git config --global user.name Fixture
  git config --global user.email fixture@trellis.invalid
  git config --global commit.gpgsign false
  git config --global init.defaultBranch main

  # A runnable copy of the runner with the real enumerator, resolver and input
  # map, and a one-target native crate. No remote: the resolver's default is main.
  FIX="$SANDBOX/repo"
  local path
  for path in scripts/run-tests.sh scripts/lib/test-suites.sh scripts/lib/bats-jobs.sh \
    scripts/tests/stage-weights.tsv core-rules/native/artifacts.json \
    scripts/lib/trellis-python.sh scripts/lib/receipt_provenance.py \
    scripts/tests/helpers/git-fence/git scripts/tests/helpers/git-fence/mktemp \
    core-rules/skills/process-gate/scripts/lib/diff-base.sh \
    core-rules/hooks/lib/deps.sh; do
    mkdir -p "$FIX/${path%/*}"
    cp "$REPO_ROOT/$path" "$FIX/$path"
  done
  mkdir -p "$FIX/native/trellis-hooks/src" "$FIX/native/trellis-hooks/tests" "$FIX/docs"
  printf 'pub fn f() {}\n' > "$FIX/native/trellis-hooks/src/lib.rs"
  printf '#[test]\nfn t() {}\n' > "$FIX/native/trellis-hooks/tests/contract.rs"
  printf 'target/\n' > "$FIX/native/trellis-hooks/.gitignore"
  printf '# docs\n' > "$FIX/docs/guide.md"
  printf '@test "sample" { true; }\n' > "$FIX/scripts/tests/sample.bats"
  git -C "$FIX" init -q
  git -C "$FIX" add -A
  git -C "$FIX" commit -qm base
  BASE="$(git -C "$FIX" rev-parse HEAD)"
  git -C "$FIX" checkout -qb feature
}

teardown() {
  rm -rf "$SANDBOX"
}

commit_change() {
  git -C "$FIX" add -A
  git -C "$FIX" commit -qm change
}

# The registered stages come from --list, which prints nothing else. The labels
# come from a real run on a shard no stage lands on, so nothing executes.
list_stages() {
  LABELS="$(cd "$FIX" && bash scripts/run-tests.sh "$@" --shard=99/99 2>/dev/null)" || true
  run bash -c 'cd "$1" && shift && bash scripts/run-tests.sh "$@" --list' _ "$FIX" "$@"
}

assert_skipped() {
  [ "$status" -eq 0 ] || { echo "$output"; echo "$LABELS"; false; }
  ! printf '%s\n' "$output" | grep -q '^cargo ' || { echo "cargo stage registered: $output"; false; }
  [[ "$LABELS" == *"native cargo stages: skip (no native build input changed"* ]] ||
    { echo "no skip label: $LABELS"; false; }
  # One labelled line per skipped stage, naming the stage.
  [[ "$LABELS" == *"skipped stage 'cargo test native/trellis-hooks/tests/contract.rs': no native build input changed"* ]] ||
    { echo "$LABELS"; false; }
  [[ "$LABELS" == *"skipped stage 'cargo unit-tests native/trellis-hooks (lib + bins)': no native build input changed"* ]] ||
    { echo "$LABELS"; false; }
}

assert_ran() {
  local why="$1"
  [ "$status" -eq 0 ] || { echo "$output"; echo "$LABELS"; false; }
  printf '%s\n' "$output" | grep -Fxq 'cargo test native/trellis-hooks/tests/contract.rs' ||
    { echo "integration stage missing: $output"; false; }
  printf '%s\n' "$output" | grep -Fxq 'cargo unit-tests native/trellis-hooks (lib + bins)' ||
    { echo "unit-test stage missing: $output"; false; }
  [[ "$LABELS" == *"native cargo stages: run ($why"* ]] || { echo "wrong run label: $LABELS"; false; }
  [[ "$LABELS" != *"skipped stage"* ]] || { echo "$LABELS"; false; }
}

@test "a docs-only change skips the cargo stages with a labelled line per stage" {
  printf 'more\n' >> "$FIX/docs/guide.md"
  commit_change
  list_stages --scope=ci --base="$BASE"
  assert_skipped
  # The Pi and bats stages are not scoped.
  printf '%s\n' "$output" | grep -Fxq 'bats scripts/tests/sample.bats' || { echo "$output"; false; }
}

@test "a change under native/trellis-hooks runs the cargo stages" {
  printf 'pub fn g() {}\n' >> "$FIX/native/trellis-hooks/src/lib.rs"
  commit_change
  list_stages --scope=ci --base="$BASE"
  assert_ran 'native build input changed: native/trellis-hooks/src/lib.rs'
}

@test "a native test-file change runs the cargo stages" {
  printf '#[test]\nfn u() {}\n' >> "$FIX/native/trellis-hooks/tests/contract.rs"
  commit_change
  list_stages --scope=ci --base="$BASE"
  assert_ran 'native build input changed: native/trellis-hooks/tests/contract.rs'
}

@test "an A2 explicit input outside native/ runs the cargo stages" {
  printf '# touched\n' >> "$FIX/core-rules/hooks/lib/deps.sh"
  commit_change
  list_stages --scope=ci --base="$BASE"
  assert_ran 'native build input changed: core-rules/hooks/lib/deps.sh'
}

@test "the A2 list is read from artifacts.json, not a copy in the runner" {
  # Drop deps.sh from the input map: the same edit no longer counts.
  jq 'del(.inputs["core-rules/hooks/lib/deps.sh"])' "$FIX/core-rules/native/artifacts.json" \
    > "$SANDBOX/artifacts.json"
  cp "$SANDBOX/artifacts.json" "$FIX/core-rules/native/artifacts.json"
  git -C "$FIX" commit -qam 'fixture: drop deps.sh from the input map'
  BASE="$(git -C "$FIX" rev-parse HEAD)"
  printf '# touched\n' >> "$FIX/core-rules/hooks/lib/deps.sh"
  commit_change
  list_stages --scope=ci --base="$BASE"
  assert_skipped
}

@test "uncommitted and untracked native changes count; target/ does not" {
  mkdir -p "$FIX/native/trellis-hooks/target/debug"
  printf 'x\n' > "$FIX/native/trellis-hooks/target/debug/out"
  list_stages --scope=ci --base="$BASE"
  assert_skipped

  printf 'pub fn h() {}\n' > "$FIX/native/trellis-hooks/src/new.rs"
  list_stages --scope=ci --base="$BASE"
  assert_ran 'native build input changed: native/trellis-hooks/src/new.rs'

  rm "$FIX/native/trellis-hooks/src/new.rs"
  printf 'pub fn g() {}\n' >> "$FIX/native/trellis-hooks/src/lib.rs"
  list_stages --scope=ci --base="$BASE"
  assert_ran 'native build input changed: native/trellis-hooks/src/lib.rs'
}

@test "a deleted native input runs the cargo stages" {
  git -C "$FIX" rm -q core-rules/hooks/lib/deps.sh
  commit_change
  list_stages --scope=ci --base="$BASE"
  assert_ran 'native build input changed: core-rules/hooks/lib/deps.sh'
}

@test "the local scope resolves its base with the shared diff-base resolver" {
  printf 'more\n' >> "$FIX/docs/guide.md"
  commit_change
  list_stages --scope=local
  assert_skipped
  [[ "$LABELS" == *"since $(printf '%s' "$BASE" | cut -c1-12), base default"* ]] ||
    { echo "base not from diff-base default: $LABELS"; false; }

  printf 'pub fn g() {}\n' >> "$FIX/native/trellis-hooks/src/lib.rs"
  commit_change
  list_stages --scope=local
  assert_ran 'native build input changed: native/trellis-hooks/src/lib.rs'
}

@test "an unknown base runs the cargo stages, fail closed and labelled" {
  printf 'more\n' >> "$FIX/docs/guide.md"
  commit_change

  # CI scope without a range base.
  list_stages --scope=ci
  assert_ran 'no range base given for scope ci; fail closed'

  # A base that does not resolve.
  list_stages --scope=ci --base=0123456789abcdef0123456789abcdef01234567
  assert_ran 'diff base unknown: refused'
  [[ "$LABELS" == *'fail closed'* ]] || { echo "$LABELS"; false; }

  # Local scope where the resolver finds no base (detached, no main, no remote).
  git -C "$FIX" checkout -q --detach
  git -C "$FIX" branch -qD main
  git -C "$FIX" branch -qD feature
  list_stages --scope=local
  assert_ran 'diff base unknown:'
}

@test "an unreadable input map runs the cargo stages, fail closed" {
  printf 'more\n' >> "$FIX/docs/guide.md"
  printf 'not json\n' > "$FIX/core-rules/native/artifacts.json"
  commit_change
  list_stages --scope=ci --base="$BASE"
  assert_ran 'native input set unreadable'
}

@test "--native-stages=always and the slow tier register the stages regardless" {
  printf 'more\n' >> "$FIX/docs/guide.md"
  commit_change
  list_stages --scope=ci --base="$BASE" --native-stages=always
  assert_ran '--native-stages=always'
  TRELLIS_SLOW_TESTS=1 list_stages --scope=ci --base="$BASE"
  assert_ran 'TRELLIS_SLOW_TESTS=1'
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --native-stages=sometimes --list' _ "$FIX"
  [ "$status" -eq 64 ] || { echo "$output"; false; }
}

@test "--list stays a pure inventory when stages are skipped" {
  printf 'more\n' >> "$FIX/docs/guide.md"
  commit_change
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --scope=ci --base="$2" --list 2>&1' _ "$FIX" "$BASE"
  [ "$status" -eq 0 ]
  [[ "$output" != *'run-tests:'* ]] || { echo "$output"; false; }
}

@test "a skip leaves every shard's stages a partition of the unsharded list" {
  local whole sharded i
  printf 'more\n' >> "$FIX/docs/guide.md"
  commit_change
  whole="$(cd "$FIX" && bash scripts/run-tests.sh --scope=ci --base="$BASE" --list 2>/dev/null | LC_ALL=C sort)"
  sharded="$(cd "$FIX" && for i in 1 2 3 4; do
    bash scripts/run-tests.sh --scope=ci --base="$BASE" --list --shard="$i/4" 2>/dev/null
  done | LC_ALL=C sort)"
  [ -n "$whole" ] && [ "$whole" = "$sharded" ] || { echo "$whole"; echo ---; echo "$sharded"; false; }
}

@test "the bats workflow gates the toolchain and passes the range base through the shared decision" {
  local workflow="$REPO_ROOT/.github/workflows/bats.yml"
  grep -Fq 'test_suites_native_decision ci' "$workflow"
  grep -Fq "if: steps.native.outputs.run != 'skip'" "$workflow"
  grep -Fq '"--base=$RANGE_BASE"' "$workflow"
  grep -Fq 'github.event.pull_request.base.sha || github.event.before' "$workflow"
}
