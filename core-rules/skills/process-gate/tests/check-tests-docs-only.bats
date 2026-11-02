#!/usr/bin/env bats
# Docs-only Tests path (C08, Sol's FOLD-GATE rule) for check-tests.sh.
#
# The heavy test battery is narrowed ONLY when every path changed by every
# commit in the range is a passive Markdown record that the base-side policy
# allows, that the policy does not deny, and that clears the built-in floor.
# Doubt runs the full battery. Each case builds a throwaway repo whose `main`
# carries the policy; the full battery is a command that drops a marker file,
# so "full" means the marker exists and "narrowed" means it does not.

setup() {
  unset PG_PUSH_TEST_SCOPE
  export TRELLIS_GATE_STATE_DIR="$BATS_TEST_TMPDIR/trellis-gate-state"
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-tests.sh"
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/proj.XXXXXX")"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR TRELLIS_ROOT
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  unset PROCESS_GATE_COVERAGE_CMD PROCESS_GATE_COVERAGE_FLOOR
  unset PROCESS_GATE_MUTATION_SPOTCHECK PROCESS_GATE_MUTATION_TIMEOUT
  export PROCESS_GATE_HEAVY_LAUNCHER="$BATS_TEST_TMPDIR/no-trellis-launcher"
  MARK="$BATS_TEST_TMPDIR/full-battery-ran"
  export PROCESS_GATE_TYPECHECK_CMD=":"
  export PROCESS_GATE_LINT_CMD=":"
  export PROCESS_GATE_TEST_CMD="touch '$MARK'"

  git init -q -b main "$PROJECT_DIR"
  gfx config user.name "Docs Fixture"
  gfx config user.email "docs@example.invalid"
  gfx config commit.gpgsign false
  write_policy .claude "$(trellis_policy)"
  put docs/adr/0001-first.md
  put CHANGELOG.md
  put specs/001-alpha/spec.md
  put tools/build.py 'print("build")'
  put core-rules/notes.md
  put research/ai-dev-trends/digests/LATEST.md
  commit "base"
}

gfx() { git -C "$PROJECT_DIR" "$@"; }

# put <path> [content] — write a regular file (parents created). The default
# content is unique per call, so re-putting an existing path is a change.
put() {
  mkdir -p "$PROJECT_DIR/$(dirname "$1")"
  printf '%s\n' "${2:-record $1 $RANDOM$RANDOM}" > "$PROJECT_DIR/$1"
}

commit() { gfx add -A && gfx commit -qm "$1"; }

# branch <name> — a fresh feature branch off main.
branch() { gfx checkout -q -B "$1" main; }

trellis_policy() {
  cat <<'EOF'
# Docs-only Tests policy (fixture copy of the Trellis example).
allow ^docs/adr/[A-Za-z0-9][A-Za-z0-9._-]*\.md$
allow ^specs/[0-9]{3}-[a-z0-9-]+/(spec|plan|tasks|clarify|decisions-log|DISPOSITIONS|ADR)\.md$
allow ^specs/[0-9]{3}-[a-z0-9-]+/evidence/([A-Za-z0-9][A-Za-z0-9._-]*/)*[A-Za-z0-9][A-Za-z0-9._-]*\.md$
allow ^research/ai-dev-trends/digests/([0-9]{4}-[0-9]{2}-[0-9]{2}|LATEST)\.md$
allow ^research/ai-dev-trends/reports/[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.md$
allow ^research/ai-dev-trends/adopt-ledger\.md$
allow ^CHANGELOG\.md$
deny ^docs/adr/0009-pinned\.md$
EOF
}

# write_policy <.claude|.agents> <body>
write_policy() {
  put "$1/skills/process-gate-local/docs-only-tests.policy" "$2"
}

# set_main_policy <body> — replace the policy on main (the protected base).
set_main_policy() {
  gfx checkout -q main
  write_policy .claude "$1"
  commit "policy"
}

run_gate() {
  rm -f "$MARK"
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range='${1:-main..HEAD}' 2>&1"
}

assert_full() {
  if [ ! -f "$MARK" ]; then
    echo "expected the full battery to run; output:"; echo "$output"; return 1
  fi
  if [[ "$output" == *"narrowed (docs-only"* ]]; then
    echo "full run still claimed narrowed: $output"; return 1
  fi
}

assert_narrowed() {
  local n="$1"
  if [ -f "$MARK" ]; then
    echo "full battery ran on a docs-only range; output:"; echo "$output"; return 1
  fi
  if [[ "$output" != *"Tests: narrowed (docs-only: $n files)"* ]]; then
    echo "missing narrowed receipt for $n files: $output"; return 1
  fi
}

# full_for <path>... — each path, alone on its own branch, runs the full battery.
full_for() {
  local p i=0
  for p in "$@"; do
    i=$((i + 1))
    branch "case-$i" || return 1
    put "$p" || return 1
    commit "change $p" || return 1
    run_gate
    assert_full || { echo "path: $p"; return 1; }
  done
}

# --- passive records narrow --------------------------------------------------

@test "tag push scope forces the full battery even for passive docs" {
  branch release-docs
  put CHANGELOG.md
  commit docs
  export PG_PUSH_TEST_SCOPE=full
  run_gate
  [ "$status" -eq 0 ]
  assert_full
}

@test "merge mode retains the passive-docs exemption" {
  branch docs
  put CHANGELOG.md
  commit "passive record"
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --mode=merge --range=main..HEAD 2>&1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_narrowed 1
}

@test "passive records on the base allowlist narrow the battery and say so" {
  branch docs
  put docs/adr/0002-second.md
  put specs/001-alpha/plan.md
  put specs/002-beta/evidence/run-1/notes.md
  put research/ai-dev-trends/digests/2026-10-08.md
  printf 'more\n' >> "$PROJECT_DIR/CHANGELOG.md"
  commit "records"
  run_gate
  [ "$status" -eq 0 ]
  assert_narrowed 5
}

@test "a narrowed range runs the base policy's tests command instead of the battery" {
  local docs_mark="$BATS_TEST_TMPDIR/docs-checks-ran"
  set_main_policy "$(trellis_policy)
tests touch '$docs_mark'"
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  [ "$status" -eq 0 ]
  assert_narrowed 1
  [ -f "$docs_mark" ]
}

@test "a failing narrowed tests command still fails the row" {
  set_main_policy "$(trellis_policy)
tests exit 3"
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  [ "$status" -eq 1 ]
  assert_narrowed 1
  [[ "$output" == *'tests: `exit 3` exited 3'* ]]
}

@test "typecheck and lint still run on a narrowed range" {
  export PROCESS_GATE_LINT_CMD="exit 4"
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  [ "$status" -eq 1 ]
  assert_narrowed 1
  [[ "$output" == *'lint: `exit 4` exited 4'* ]]
}

@test "a three-dot range narrows over its merge-base" {
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate "main...docs"
  [ "$status" -eq 0 ]
  assert_narrowed 1
}

# --- Sol's acceptance cases: everything below runs the full battery ----------

@test "operative Markdown never narrows, even under a policy that allows all .md" {
  set_main_policy 'allow ^.*\.md$'
  full_for docs/SKILL.md docs/adr/claude.md research/ai-dev-trends/prompt.md \
    research/ai-dev-trends/targets.md core-rules/notes.md docs/hooks/x.md AGENTS.md
}

@test "UPGRADING and VERSION files never narrow" {
  set_main_policy 'allow ^.*\.md$'
  full_for docs/UPGRADING.md docs/adr/VERSION.md docs/version-notes.md
  full_for VERSION core-rules/VERSION
}

@test "scanner, rule and fixture changes never narrow" {
  set_main_policy 'allow ^.*$'
  full_for .semgrep.yml .gitleaks.toml tests/fixtures/sample.md \
    docs/adr/fixtures/case.md package.json
}

@test "a script renamed to a doc runs the full battery (old path is code)" {
  branch rename
  gfx mv tools/build.py docs/adr/0002-build.md
  commit "rename"
  [[ "$(gfx diff --name-status -M main HEAD)" == R* ]]
  run_gate
  assert_full
}

@test "a behaviour-bearing Markdown file renamed into the allowlist runs full" {
  branch rename
  gfx mv core-rules/notes.md docs/adr/0002-notes.md
  commit "rename"
  run_gate
  assert_full
}

@test "deleting a script runs the full battery" {
  branch delete
  gfx rm -q tools/build.py
  put docs/adr/0002-second.md
  commit "delete"
  run_gate
  assert_full
}

@test "a symlink on an allowlisted path runs the full battery" {
  branch link
  ln -s 0001-first.md "$PROJECT_DIR/docs/adr/0002-link.md"
  commit "link"
  run_gate
  assert_full
}

@test "an executable-mode doc on an allowlisted path runs the full battery" {
  branch exec
  put docs/adr/0002-exec.md
  chmod +x "$PROJECT_DIR/docs/adr/0002-exec.md"
  commit "exec"
  run_gate
  assert_full
}

@test "case aliases and unsafe names on allowlisted paths run full" {
  set_main_policy 'allow ^docs/.*$'
  full_for docs/adr/0002-up.MD "docs/adr/0002 space.md" docs/adr/-dash.md
}

@test "an unresolvable range start (missing base) runs the full battery" {
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate "0000000000000000000000000000000000000000..HEAD"
  assert_full
  run_gate "no-such-branch..HEAD"
  assert_full
}

@test "a range whose start is not an ancestor of its end runs the full battery" {
  branch side
  put docs/adr/0003-side.md
  commit "side"
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate "side..docs"
  assert_full
}

@test "an empty range runs the full battery" {
  branch docs
  run_gate "main..HEAD"
  assert_full
}

@test "a malformed base policy runs the full battery with a notice" {
  set_main_policy 'allow docs/adr/.*\.md'
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  assert_full
  [[ "$output" == *"docs-only: full tests"*"line 1"* ]]
}

@test "an unknown policy keyword or invalid regex runs the full battery" {
  set_main_policy 'permit ^docs/adr/[^/]*\.md$'
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  assert_full
  set_main_policy 'allow ^docs/adr/[[:bogus:]*\.md$'
  branch docs2
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  assert_full
}

@test "a policy edit carried in the range is ignored; the base policy decides" {
  branch widen
  write_policy .claude 'allow ^.*$'
  put notes/today.md
  commit "widen policy"
  run_gate
  assert_full
}

@test "a policy added in the range does nothing when the base has none" {
  gfx checkout -q main
  gfx rm -q .claude/skills/process-gate-local/docs-only-tests.policy
  commit "no policy"
  branch docs
  write_policy .agents "$(trellis_policy)"
  put docs/adr/0002-second.md
  commit "add policy"
  run_gate
  assert_full
  [[ "$output" != *"docs-only"* ]]
}

@test "an uncommitted working-tree policy is never read" {
  gfx checkout -q main
  gfx rm -q .claude/skills/process-gate-local/docs-only-tests.policy
  commit "no policy"
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  write_policy .claude "$(trellis_policy)"
  run_gate
  assert_full
  [[ "$output" != *"docs-only"* ]]
}

@test "two base policies that differ run the full battery" {
  gfx checkout -q main
  write_policy .agents 'allow ^CHANGELOG\.md$'
  commit "second policy"
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  assert_full
}

@test "a policy deny entry beats its allow entries" {
  branch docs
  put docs/adr/0009-pinned.md
  commit "pinned"
  run_gate
  assert_full
}

@test "a range mixing docs and code runs the full battery" {
  branch mixed
  put docs/adr/0002-second.md
  put tools/build.py 'print("changed")'
  commit "mixed"
  run_gate
  assert_full
}

@test "code changed and reverted inside the range runs full (carried history)" {
  branch carried
  put tools/build.py 'print("changed")'
  commit "change code"
  put tools/build.py 'print("build")'
  put docs/adr/0002-second.md
  commit "revert code, add doc"
  [ "$(gfx diff --name-only main HEAD)" = "docs/adr/0002-second.md" ]
  run_gate
  assert_full
}

@test "a secret added then removed inside the range runs the full battery" {
  branch secret
  put .env 'TOKEN=not-a-real-token'
  commit "oops"
  gfx rm -q .env
  put docs/adr/0002-second.md
  commit "remove"
  run_gate
  assert_full
}

@test "a gate-config change runs the full battery" {
  branch config
  put .claude/skills/process-gate-local/local.config.sh '# sourced by the gate'
  put docs/adr/0002-second.md
  commit "config"
  run_gate
  assert_full
  set_main_policy 'allow ^.*$'
  full_for .agents/skills/process-gate-local/notes.md .trellis.json .pi/settings.md
}

@test "generated HTML runs the full battery" {
  set_main_policy 'allow ^research/.*$'
  branch html
  put research/ai-dev-trends/index.html '<a href="#" onclick="x()">x</a>'
  commit "html"
  run_gate
  assert_full
}

@test "code under a docs path runs the full battery" {
  set_main_policy 'allow ^docs/.*$'
  full_for docs/x.sh docs/adr/tool.py docs/adr/page.ts
}

@test "a binary blob with a .md name runs the full battery" {
  branch binary
  mkdir -p "$PROJECT_DIR/docs/adr"
  printf 'text\000binary\n' > "$PROJECT_DIR/docs/adr/0002-bin.md"
  commit "binary"
  run_gate
  assert_full
}

@test "a merge commit inside the range runs the full battery" {
  branch side
  put docs/adr/0003-side.md
  commit "side"
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  gfx merge -q --no-ff --no-edit side
  run_gate
  assert_full
}

@test "a narrowed run skips coverage and the mutation spot-check" {
  local cov="$BATS_TEST_TMPDIR/coverage-ran"
  export PROCESS_GATE_COVERAGE_CMD="touch '$cov'"
  export PROCESS_GATE_MUTATION_SPOTCHECK=1
  branch docs
  put docs/adr/0002-second.md
  commit "adr"
  run_gate
  [ "$status" -eq 0 ]
  assert_narrowed 1
  [ ! -f "$cov" ]
  [[ "$output" != *"mutation spot-check"* ]]
}

# --- Trellis's own policy ----------------------------------------------------

REPO_POLICY="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)/.claude/skills/process-gate-local/docs-only-tests.policy"

# trellis_fixture: main carries the repository's real policy, and every
# consumer its tests line names is a stub that logs how it was invoked.
trellis_fixture() {
  CONSUMER_LOG="$BATS_TEST_TMPDIR/consumers.log"
  export CONSUMER_LOG
  : > "$CONSUMER_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/stub-bin"
  printf '#!/usr/bin/env bash\nprintf "bats %%s\\n" "$*" >> "$CONSUMER_LOG"\n' \
    > "$BATS_TEST_TMPDIR/stub-bin/bats"
  chmod +x "$BATS_TEST_TMPDIR/stub-bin/bats"
  export PATH="$BATS_TEST_TMPDIR/stub-bin:$PATH"
  gfx checkout -q main
  cp "$REPO_POLICY" "$PROJECT_DIR/.claude/skills/process-gate-local/docs-only-tests.policy"
  put scripts/conformance-check.sh 'printf "conformance\n" >> "$CONSUMER_LOG"'
  put recon.md
  commit "trellis policy"
}

@test "Trellis: a docs-only range narrows and runs exactly the policy's tests line" {
  trellis_fixture
  branch docs
  put docs/adr/0002-second.md
  put specs/001-alpha/plan.md
  put recon.md
  commit "records"
  run_gate
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_narrowed 3
  [ "$(cat "$CONSUMER_LOG")" = "bats scripts/tests/gpt6-roster-sweep.bats
bats -f A3[.]8 every off-main tag consumer pattern in the repository is reviewed scripts/tests/release-tag-consumers.bats
bats -f tracked live sources contain no full-argv process identity probe scripts/tests/check-process-liveness.bats
conformance" ] || { cat "$CONSUMER_LOG"; return 1; }
}

@test "Trellis: the tests line names suites and cases that exist" {
  local root
  root="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)"
  [ -f "$root/scripts/conformance-check.sh" ]
  grep -qF '@test "the SC1 live set contains no retired model identifiers"' \
    "$root/scripts/tests/gpt6-roster-sweep.bats"
  grep -qF '@test "A3.8 every off-main tag consumer pattern in the repository is reviewed"' \
    "$root/scripts/tests/release-tag-consumers.bats"
  grep -qF '@test "tracked live sources contain no full-argv process identity probe"' \
    "$root/scripts/tests/check-process-liveness.bats"
}

@test "Trellis: the floor and the policy still refuse behaviour-bearing paths" {
  trellis_fixture
  full_for core-rules/notes.md scripts/notes.md hooks/notes.md skills/x/notes.md \
    .claude/notes.md .pi/notes.md docs/VERSION.md docs/UPGRADING.md \
    docs/adr/SKILL.md specs/001-alpha/prompt.md AGENT_SETUP.md \
    engineering-process.md registry.md docs/MIGRATING-LOCAL-FLEETS.md \
    docs/PI-COMPUTER-USE.md docs/claude-steering.md docs/codex-routing.md \
    docs/handoffs/fleet-setup-prompt.md docs/x.sh specs/052-x/allowlist.txt
  [ ! -s "$CONSUMER_LOG" ] || { cat "$CONSUMER_LOG"; return 1; }
}
