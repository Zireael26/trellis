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

# Source the runner in an isolated child so its fixed system uname can be
# mocked as a shell function. No exported variable can alter production host
# detection or its correspondence to the verdict's platform key.
host_run() {
  export MOCK_OS="$1"
  shift
  run bash -c '
    function /usr/bin/uname { printf "%s\n" "$MOCK_OS"; }
    function /bin/uname { printf "%s\n" "$MOCK_OS"; }
    cd "$1" || exit 1
    shift
    . scripts/run-tests.sh "$@"
  ' _ "$FIX" "$@"
}

platform_suite_fixtures() {
  local suite
  for suite in disk-janitor-agents install-disk-janitor-launchd test-health-launchd; do
    printf '@test "fixture" { true; }\n' > "$FIX/scripts/tests/$suite.bats"
  done
}

@test "local non-Darwin inventory reuses every CI host exclusion" {
  local suite
  platform_suite_fixtures
  host_run Linux --scope=local --list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'run-tests:'* ]] || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -Fxq 'bats scripts/tests/sample.bats'
  for suite in disk-janitor-agents install-disk-janitor-launchd test-health-launchd; do
    ! printf '%s\n' "$output" | grep -Fxq "bats scripts/tests/$suite.bats" || { echo "$output"; false; }
  done
  host_run Linux --scope=local --plan
  [ "$status" -eq 0 ] && [[ "$output" != *'run-tests:'* ]] || { echo "$output"; false; }
  for suite in disk-janitor-agents install-disk-janitor-launchd test-health-launchd; do
    [[ "$output" != *"bats scripts/tests/$suite.bats"* ]] || { echo "$output"; false; }
  done
}

@test "Darwin local retains host suites while CI still excludes them" {
  local suite
  platform_suite_fixtures
  host_run Darwin --scope=local --list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for suite in disk-janitor-agents install-disk-janitor-launchd test-health-launchd; do
    printf '%s\n' "$output" | grep -Fxq "bats scripts/tests/$suite.bats" || { echo "$output"; false; }
  done
  host_run Darwin --scope=ci --list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for suite in disk-janitor-agents install-disk-janitor-launchd test-health-launchd; do
    ! printf '%s\n' "$output" | grep -Fxq "bats scripts/tests/$suite.bats" || { echo "$output"; false; }
  done
}

@test "local non-Darwin labels excluded stages with the shared reasons" {
  platform_suite_fixtures
  host_run Linux --scope=local --native-stages=always --shard=99/99
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"skipped stage 'bats scripts/tests/disk-janitor-agents.bats': macOS launchd agent ownership"* ]] || { echo "$output"; false; }
  [[ "$output" == *"skipped stage 'bats scripts/tests/install-disk-janitor-launchd.bats': macOS launchd installer"* ]] || { echo "$output"; false; }
  [[ "$output" == *"skipped stage 'bats scripts/tests/test-health-launchd.bats': Darwin-only host runner"* ]] || { echo "$output"; false; }
  host_run Linux --scope=local --test-file=scripts/tests/sample.bats --shard=99/99
  [ "$status" -eq 0 ] && [[ "$output" != *"skipped stage 'bats scripts/tests/"* ]] || { echo "$output"; false; }
}

@test "excluded explicit selection fails closed rather than issuing a narrowed pass" {
  platform_suite_fixtures
  host_run Linux --scope=local --test-file=scripts/tests/test-health-launchd.bats --list
  [ "$status" -eq 64 ] || { echo "$output"; false; }
  [[ "$output" == *'selected test excluded in local:'*'Darwin-only host runner'* ]] || { echo "$output"; false; }
  host_run Linux --scope=local --test-file=scripts/tests/sample.bats --test-file=scripts/tests/test-health-launchd.bats --list
  [ "$status" -eq 64 ] && [[ "$output" != *'bats scripts/tests/sample.bats'* ]] || { echo "$output"; false; }
  host_run Darwin --scope=local --test-file=scripts/tests/test-health-launchd.bats --list
  [ "$status" -eq 0 ] && [[ "$output" == *'bats scripts/tests/test-health-launchd.bats'* ]] || { echo "$output"; false; }
  host_run Darwin --scope=ci --test-file=scripts/tests/test-health-launchd.bats --list
  [ "$status" -eq 64 ] && [[ "$output" == *'selected test excluded in ci:'* ]] || { echo "$output"; false; }
}

core_suite_fixtures() {
  mkdir -p "$FIX/core-rules/hooks/tests" "$FIX/core-rules/codex/hooks/tests"
  printf '@test "fixture" { true; }\n' > "$FIX/core-rules/hooks/tests/guard-supervise.bats"
  printf '@test "other" { true; }\n' > "$FIX/core-rules/hooks/tests/other.bats"
  printf '@test "codex" { true; }\n' > "$FIX/core-rules/codex/hooks/tests/context.bats"
}

@test "selected core hook suites support exact and mixed inventories" {
  core_suite_fixtures
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --test-file=core-rules/hooks/tests/guard-supervise.bats --list' _ "$FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -Fxq 'bats core-rules/hooks/tests/guard-supervise.bats' || { echo "$output"; false; }
  [[ "$output" != *'bats core-rules/hooks/tests/other.bats'* && "$output" != *'bats core-rules/codex/hooks/tests/context.bats'* && "$output" != *'bats scripts/tests/sample.bats'* ]] || { echo "$output"; false; }
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --test-file=core-rules/hooks/tests/guard-supervise.bats --test-file=core-rules/codex/hooks/tests/context.bats --test-file=scripts/tests/sample.bats --plan' _ "$FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'bats core-rules/hooks/tests/guard-supervise.bats'* && "$output" == *'bats core-rules/codex/hooks/tests/context.bats'* && "$output" == *'bats scripts/tests/sample.bats'* ]] || { echo "$output"; false; }
  [[ "$output" != *'bats core-rules/hooks/tests/other.bats'* && "$output" != *'run-tests:'* ]] || { echo "$output"; false; }
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --test-file=core-rules/hooks/tests/guard-supervise.bats --test-file=core-rules/hooks/tests/guard-supervise.bats --list' _ "$FIX"
  [ "$status" -eq 0 ] && [ "$(printf '%s\n' "$output" | grep -Fc 'bats core-rules/hooks/tests/guard-supervise.bats')" -eq 1 ] || { echo "$output"; false; }
}

@test "core hook selection rejects unsafe or unavailable paths" {
  core_suite_fixtures
  ln -s guard-supervise.bats "$FIX/core-rules/hooks/tests/link.bats"
  local path
  for path in core-rules/hooks/tests/link.bats core-rules/hooks/tests/../tests/guard-supervise.bats \
    core-rules/hooks/tests/missing.bats core-rules/skills/example/tests/guard.bats; do
    run bash -c 'cd "$1" && bash scripts/run-tests.sh "--test-file=$2" --list' _ "$FIX" "$path"
    [ "$status" -eq 64 ] && [[ "$output" == *'invalid selected test:'* ]] || { echo "$output"; false; }
  done
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --quick --test-file=core-rules/hooks/tests/guard-supervise.bats --list' _ "$FIX"
  [ "$status" -eq 64 ] || { echo "$output"; false; }
  mkdir -p "$SANDBOX/external"
  printf '@test "outside" { true; }\n' > "$SANDBOX/external/escape.bats"
  for path in scripts/tests core-rules/hooks/tests core-rules/codex/hooks/tests; do
    mv "$FIX/$path" "$FIX/$path.saved"
    ln -s "$SANDBOX/external" "$FIX/$path"
    run bash -c 'cd "$1" && bash scripts/run-tests.sh "--test-file=$2/escape.bats" --list' _ "$FIX" "$path"
    [ "$status" -eq 64 ] && [[ "$output" == *'invalid selected test:'* ]] || { echo "$output"; false; }
    rm "$FIX/$path"
    mv "$FIX/$path.saved" "$FIX/$path"
  done
}

@test "selected suites fail closed on enumeration errors or omissions" {
  core_suite_fixtures
  mkdir -p "$SANDBOX/no-sort"
  printf '#!/bin/bash\nexit 73\n' > "$SANDBOX/no-sort/sort"
  chmod 755 "$SANDBOX/no-sort/sort"
  run env PATH="$SANDBOX/no-sort:$PATH" bash -c 'cd "$1" && bash scripts/run-tests.sh --test-file=core-rules/hooks/tests/guard-supervise.bats --list' _ "$FIX"
  [ "$status" -ne 0 ] && [[ "$output" == *'could not enumerate core hook suites'* ]] || { echo "$output"; false; }
  printf '\ntest_suites_core() { return 0; }\n' >> "$FIX/scripts/lib/test-suites.sh"
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --test-file=core-rules/hooks/tests/guard-supervise.bats --list' _ "$FIX"
  [ "$status" -ne 0 ] && [[ "$output" == *'selected test registered 0 times:'* ]] || { echo "$output"; false; }
}

@test "selected core hook suite executes inside the Git fence with HC scrubbed" {
  local shard
  core_suite_fixtures
  mkdir -p "$SANDBOX/fakebin" "$SANDBOX/outside"
  printf '%s\n' '#!/bin/bash' \
    '[ "$1" = core-rules/hooks/tests/guard-supervise.bats ] || exit 10' \
    '[ -n "${TRELLIS_TEST_GIT_FENCE_ROOT:-}" ] || exit 11' \
    '[ -z "${HC_SCOPE+x}${HC_TERMINAL_ID+x}${HC_TERMINAL_SOCKET+x}${TRELLIS_NATIVE_CARGO_ONLY+x}" ] || exit 12' \
    'git init -q "$TRELLIS_TEST_GIT_FENCE_ROOT/allowed" || exit 13' \
    'if git init -q "$OUTSIDE_GIT" 2>/dev/null; then exit 14; fi' \
    'printf "selected-core-fenced\\n"' > "$SANDBOX/fakebin/bats"
  chmod 755 "$SANDBOX/fakebin/bats"
  export PATH="$SANDBOX/fakebin:$PATH" OUTSIDE_GIT="$SANDBOX/outside/repo"
  export HC_SCOPE=fixture HC_TERMINAL_ID=fixture HC_TERMINAL_SOCKET=fixture
  export TRELLIS_NATIVE_CARGO_ONLY=qualification
  shard="$(cd "$FIX" && bash scripts/run-tests.sh --test-file=core-rules/hooks/tests/guard-supervise.bats --shard=1/99 --plan | awk -F '\t' '$2 == "bats core-rules/hooks/tests/guard-supervise.bats" {print $1}')"
  [ -n "$shard" ] || { echo 'selected stage absent from plan'; false; }
  run bash -c 'cd "$1" && bash scripts/run-tests.sh --test-file=core-rules/hooks/tests/guard-supervise.bats "--shard=$2/99"' _ "$FIX" "$shard"
  [ "$status" -eq 0 ] && [[ "$output" == *'selected-core-fenced'* ]] || { echo "$output"; false; }
  [ ! -e "$OUTSIDE_GIT" ] || { echo 'fence allowed outside Git mutation'; false; }
}

@test "native-only inventory is singular, opt-in and side-effect free" {
  local marker="$SANDBOX/native-only-receipt"
  run env -u TRELLIS_NATIVE_CARGO_ONLY bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only --list' _ "$FIX"
  [ "$status" -eq 64 ] && [[ "$output" == *'TRELLIS_NATIVE_CARGO_ONLY=qualification'* ]] || { echo "$output"; false; }
  run env TRELLIS_NATIVE_CARGO_ONLY=wrong bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only --list' _ "$FIX"
  [ "$status" -eq 64 ] || { echo "$output"; false; }
  printf 'keep\n' > "$marker"
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification TRELLIS_TEST_TSV="$marker" TRELLIS_TEST_PROVENANCE_RECEIPT="$marker" \
    bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only --list' _ "$FIX"
  [ "$status" -eq 0 ] && [ "$output" = 'cargo test native/trellis-hooks (native-only)' ] || { echo "$output"; false; }
  [ "$(< "$marker")" = keep ] && [ ! -e "$marker.provenance.jsonl" ] || false
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification TRELLIS_TEST_TSV="$marker" TRELLIS_TEST_PROVENANCE_RECEIPT="$marker" \
    bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only --plan' _ "$FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | awk -F '\t' 'NR==1 {if ($1!="shard" || $2!="stage" || $3!="weight") exit 1}
    NR==2 {if ($1!=1 || $2!="cargo test native/trellis-hooks (native-only)") exit 1}
    NR==3 {if ($1!="total" || $2!=1) exit 1}' || { echo "$output"; false; }
  [ "$(< "$marker")" = keep ] && [ ! -e "$marker.provenance.jsonl" ] || false
}

@test "native-only rejects every incompatible explicit override in either order" {
  local option
  for option in --quick --scope=local --scope=ci --shard=1/1 --base=HEAD --native-stages=auto \
    --native-stages=always --test-file=scripts/tests/sample.bats; do
    run env TRELLIS_NATIVE_CARGO_ONLY=qualification bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only "$2" --list' _ "$FIX" "$option"
    [ "$status" -eq 64 ] || { echo "$option: $output"; false; }
    run env TRELLIS_NATIVE_CARGO_ONLY=qualification bash -c 'cd "$1" && bash scripts/run-tests.sh "$2" --native-cargo-only --list' _ "$FIX" "$option"
    [ "$status" -eq 64 ] || { echo "$option: $output"; false; }
  done
  run env TRELLIS_NATIVE_CARGO_ONLY=qualification bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only --list --plan' _ "$FIX"
  [ "$status" -eq 64 ] || { echo "$output"; false; }
}

@test "native-only refuses the parent gate scope interface" {
  local name value receipt="$SANDBOX/unexpected-receipt" timing="$SANDBOX/unexpected-timing"
  for name in PG_TESTS_BASE PG_TESTS_HEAD PG_TESTS_RECEIPT_FILE PG_PUSH_TEST_SCOPE; do
    for value in '' "$receipt"; do
      run env TRELLIS_NATIVE_CARGO_ONLY=qualification "$name=$value" TRELLIS_TEST_TSV="$timing" \
        bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only --list' _ "$FIX"
      [ "$status" -eq 64 ] || { echo "$name=$value: $output"; false; }
      run env TRELLIS_NATIVE_CARGO_ONLY=qualification "$name=$value" TRELLIS_TEST_TSV="$timing" \
        bash -c 'cd "$1" && bash scripts/run-tests.sh --native-cargo-only' _ "$FIX"
      [ "$status" -eq 64 ] || { echo "$name=$value: $output"; false; }
      [ ! -e "$receipt" ] && [ ! -e "$timing" ] && [ ! -e "$timing.provenance.jsonl" ] || false
    done
  done
}
