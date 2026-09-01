#!/usr/bin/env bats
# Tests for check-tests.sh — the tests/coverage gate (HIGH-2 / DL-P7-04, swept
# across ALL toolchains by DL-P7-07 + grep-fallback scoping by DL-P7-08).
#
# BRIGHT LINE under test: a check that is DECLARED/DETECTED and FAILS at runtime
# is a HARD fail (exit 1); a check that is ABSENT/UNDECLARED/COULDN'T-RUN is a
# WARN (exit 2), never a fail. The pre-fix bug bricked these shapes of repo:
#   - JS: package.json present but no typecheck/lint/test script → the JS branch
#     built `npm run typecheck`, npm exited "Missing script", worst=fail, BLOCK.
#   - JS: no package.json at all → run_check typecheck with an empty cmd special-
#     cased worst=fail, BLOCK.
#   - Python (DL-P7-07): pyproject [tool.mypy] present but mypy not installed →
#     built `python -m mypy .` on config alone → exits nonzero → BLOCK.
#   - Go (DL-P7-07): go.mod/go.work present but `go` off PATH → `go vet ./...`
#     exits 127 → BLOCK; and a go.work workspace root with no Makefile target
#     fell through to root-level `go vet ./...`/`go test ./...` which are broken
#     from a workspace root ("directory prefix . does not contain modules") →
#     BLOCK.
#   - grep-fallback (DL-P7-08): when jq AND node are both absent, pg_has_npm_script
#     grepped the WHOLE package.json, so a devDependency literally named `test`
#     false-positived → built `npm run test` for a missing script → BLOCK.
# All of these now downgrade to warn (couldn't-run/undeclared). The regression
# guard pins that a genuinely failing DECLARED+RUNNABLE check still BLOCKs, so
# the fix did not over-rotate into never-failing.
#
# Approach mirrors the sibling process-gate bats (check-secrets.bats /
# check-analyze.bats / check-security-diff.bats): a throwaway fixture dir under
# mktemp -d, CLAUDE_PROJECT_DIR pointed at it, and the script invoked via
# `run bash -c "cd ... && SCRIPT"`. check-tests.sh takes no --range; it reads
# PROJECT_DIR + PROCESS_GATE_*_CMD.
#
# Exit codes: 0=pass, 2=warn, 1=fail(BLOCK).

setup() {
  # SCRIPT is overridable (PG_TEST_SCRIPT) so the red-green driver @test can
  # point the SAME fixtures at a reconstructed PRE-FIX copy of the scripts/
  # tree (see "RED-GREEN DRIVER" below, DL-P7-08 item 2). Default is the
  # on-disk script; normal runs are unaffected.
  SCRIPT="${PG_TEST_SCRIPT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-tests.sh}"
  COMMON="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/common.sh"
  PROJECT_DIR="$(mktemp -d)"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR TRELLIS_ROOT
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  # Don't let an operator's ambient PROCESS_GATE_* config leak into auto-detect.
  unset PROCESS_GATE_TYPECHECK_CMD PROCESS_GATE_LINT_CMD PROCESS_GATE_TEST_CMD
  unset PROCESS_GATE_COVERAGE_CMD PROCESS_GATE_COVERAGE_FLOOR
  unset PROCESS_GATE_MUTATION_SPOTCHECK PROCESS_GATE_MUTATION_TIMEOUT
  unset MUTATION_BEHAVIOR MUTATION_LOG
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
  if [ -n "${MUTATION_LOG:-}" ] && [ -f "$MUTATION_LOG" ]; then
    rm -f "$MUTATION_LOG"
  fi
}

run_gate() {
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT'"
}

# make_mutation_fixture <js|python|go>
#   Build a clean two-commit repo whose second commit changes supported tests.
# The committed runner passes the control, then either kills, survives, or hangs
# only after it observes the language-specific assertion flip in the clone.
make_mutation_fixture() {
  local kind="$1"
  command -v git >/dev/null 2>&1 || skip "git not installed"
  if ! command -v timeout >/dev/null 2>&1 \
    && ! command -v gtimeout >/dev/null 2>&1 \
    && ! command -v perl >/dev/null 2>&1; then
    skip "no bounded timeout runner"
  fi

  git init -q "$PROJECT_DIR"
  git -C "$PROJECT_DIR" config user.name "Process Gate Fixture"
  git -C "$PROJECT_DIR" config user.email "process-gate@example.invalid"
  git -C "$PROJECT_DIR" config commit.gpgsign false
  git -C "$PROJECT_DIR" config core.hooksPath /dev/null
  MUTATION_LOG="$(mktemp)"
  export MUTATION_LOG

  cat > "$PROJECT_DIR/mutation-runner.sh" <<'SH'
#!/usr/bin/env bash
# The baseline intentionally inherits its caller context. Disposable
# control/mutant runs must not: a leaked GIT_DIR could redirect their Git work
# back into the caller checkout.
if [ "$PWD" != "${CLAUDE_PROJECT_DIR:-}" ] && [ "${GIT_DIR+x}" = x ]; then
  exit 86
fi
js=0
python=0
go=0
[ ! -f tests/a.test.js ] || js="$(grep -cF '.not.toBe' tests/a.test.js)"
[ ! -f tests/test_example.py ] || python="$(grep -cF 'assert not True' tests/test_example.py)"
[ ! -f sample_test.go ] || go="$(grep -cF 'if got == want {' sample_test.go)"
printf '%s|%s|%s|%s\n' "$PWD" "$js" "$python" "$go" >> "$MUTATION_LOG"
[ "$((js + python + go))" -gt 0 ] || exit 0
case "${MUTATION_BEHAVIOR:-kill}" in
  survive) exit 0 ;;
  timeout) sleep 5; exit 0 ;;
  *)       exit 1 ;;
esac
SH
  chmod +x "$PROJECT_DIR/mutation-runner.sh"

  case "$kind" in
    js)
      mkdir -p "$PROJECT_DIR/tests"
      printf '%s\n' 'test("a", () => expect(true).toBe(true))' > "$PROJECT_DIR/tests/a.test.js"
      printf '%s\n' 'test("z", () => expect(true).toBe(true))' > "$PROJECT_DIR/tests/z.test.js"
      ;;
    python)
      mkdir -p "$PROJECT_DIR/tests"
      printf '%s\n' 'def test_example():' '    assert True' > "$PROJECT_DIR/tests/test_example.py"
      ;;
    go)
      printf '%s\n' \
        'package sample' \
        'import "testing"' \
        'func TestExample(t *testing.T) {' \
        '    got, want := 1, 1' \
        '    if got != want {' \
        '        t.Fatalf("got %d want %d", got, want)' \
        '    }' \
        '}' > "$PROJECT_DIR/sample_test.go"
      ;;
  esac
  git -C "$PROJECT_DIR" add .
  git -C "$PROJECT_DIR" commit -qm "base fixture"

  case "$kind" in
    js)
      printf '%s\n' '// changed' >> "$PROJECT_DIR/tests/a.test.js"
      printf '%s\n' '// changed' >> "$PROJECT_DIR/tests/z.test.js"
      ;;
    python) printf '%s\n' '# changed' >> "$PROJECT_DIR/tests/test_example.py" ;;
    go)     printf '%s\n' '// changed' >> "$PROJECT_DIR/sample_test.go" ;;
  esac
  git -C "$PROJECT_DIR" add .
  git -C "$PROJECT_DIR" commit -qm "change test contract"
}

run_mutation_gate() {
  run env \
    "MUTATION_LOG=$MUTATION_LOG" \
    "MUTATION_BEHAVIOR=${MUTATION_BEHAVIOR:-kill}" \
    "PROCESS_GATE_TYPECHECK_CMD=true" \
    "PROCESS_GATE_LINT_CMD=true" \
    "PROCESS_GATE_TEST_CMD=./mutation-runner.sh" \
    "PROCESS_GATE_MUTATION_SPOTCHECK=${PROCESS_GATE_MUTATION_SPOTCHECK:-1}" \
    "PROCESS_GATE_MUTATION_TIMEOUT=${PROCESS_GATE_MUTATION_TIMEOUT:-3}" \
    bash -c 'cd "$1" && "$2" --range=HEAD~1..HEAD' _ "$PROJECT_DIR" "$SCRIPT"
}

# run_resolver [runtime_root]
run_resolver() {
  local runtime="${1:-}"
  run env "TRELLIS_ROOT=$runtime" bash -c 'source "$1"; pg_resolve_pm "$2"' \
    _ "$COMMON" "$PROJECT_DIR"
}

@test "pg_resolve_pm uses canonical, legacy, then immutable runtime policy" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local runtime="$PROJECT_DIR/.trellis/runtime"
  mkdir -p "$runtime"
  printf '%s\n' '{"package_manager":"auto"}' > "$PROJECT_DIR/.trellis.json"
  printf '%s\n' '{"package_manager":"yarn"}' > "$PROJECT_DIR/.trellis.config.json"
  printf '%s\n' '{"package_manager":"npm"}' > "$runtime/trellis.config.json"
  : > "$PROJECT_DIR/bun.lock"

  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ "$output" = "bun" ]

  printf '%s\n' '{"package_manager":"pnpm"}' > "$PROJECT_DIR/.trellis.json"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ "$output" = "pnpm" ]

  rm "$PROJECT_DIR/.trellis.json"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ "$output" = "yarn" ]

  rm "$PROJECT_DIR/.trellis.config.json"
  printf '%s\n' '{"package_manager":"yarn"}' > "$PROJECT_DIR/trellis.config.json"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ "$output" = "npm" ]
}

@test "pg_resolve_pm preserves explicit PM" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '%s\n' '{"name":"fixture"}' > "$PROJECT_DIR/package.json"
  printf '%s\n' '{"package_manager":"pnpm"}' > "$PROJECT_DIR/.trellis.json"

  run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "pnpm" ]
}

@test "pg_resolve_pm preserves empty no-lockfile result" {
  printf '%s\n' '{"name":"fixture"}' > "$PROJECT_DIR/package.json"

  run_resolver
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_resolve_pm suppresses legacy/runtime PM after malformed or null canonical policy" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local runtime="$PROJECT_DIR/.trellis/runtime"
  mkdir -p "$runtime"
  printf '%s\n' '{"package_manager":"yarn"}' > "$PROJECT_DIR/.trellis.config.json"
  printf '%s\n' '{"package_manager":"pnpm"}' > "$runtime/trellis.config.json"

  printf '%s\n' '{"package_manager":' > "$PROJECT_DIR/.trellis.json"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf '%s\n' '{"package_manager":null}' > "$PROJECT_DIR/.trellis.json"
  : > "$PROJECT_DIR/bun.lock"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ "$output" = "bun" ]

  rm "$PROJECT_DIR/bun.lock"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pg_resolve_pm rejects hostile canonical PM values over lower policy" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local runtime="$PROJECT_DIR/.trellis/runtime"
  mkdir -p "$runtime"
  printf '%s\n' '{"package_manager":"yarn"}' > "$PROJECT_DIR/.trellis.config.json"
  printf '%s\n' '{"package_manager":"pnpm"}' > "$runtime/trellis.config.json"

  printf '%s\n' '{"package_manager":true}' > "$PROJECT_DIR/.trellis.json"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf '%s\n' '{"package_manager":"/tmp/hostile-package-manager"}' > "$PROJECT_DIR/.trellis.json"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  : > "$PROJECT_DIR/package-lock.json"
  run_resolver "$runtime"
  [ "$status" -eq 0 ]
  [ "$output" = "npm" ]
}

# make_toolbox <dir> [extra-tool ...]
#   Populate <dir> with symlinks to the ABSOLUTE paths of the externals the
#   gate + common.sh actually invoke (bash/sed/grep/git/dirname/head/tail/
#   mktemp/cat/rm/env), so a test can run the gate under a CONTROLLED PATH that
#   omits jq and node (to exercise the grep fallback) without losing the tools
#   the script needs. Each link target is resolved via `command -v` (absolute
#   under bash) — NO host paths are baked into the file. Refuses any tool that
#   does not resolve to an absolute path (keeps a dangling relative symlink,
#   which silently breaks the tool, out of the toolbox).
make_toolbox() {
  local dir="$1"; shift
  local b p
  for b in bash sh sed grep git dirname head tail mktemp cat rm env "$@"; do
    p="$(command -v "$b" 2>/dev/null || true)"
    case "$p" in
      /*) ln -sf "$p" "$dir/$b" ;;
    esac
  done
}

# --- Case 1: package.json with scripts {build} but NO typecheck/lint/test ---
# A package-lock.json is dropped so pg_resolve_pm resolves PM=npm and the JS
# branch fires — this is what actually exercises EDIT A (the has-script guard).
# Pre-fix this built `npm run typecheck`, npm exited "Missing script", BLOCK(1).
@test "package.json with only {build} script -> pass/warn, never fail, no missing-script run" {
  printf '%s\n' '{"name":"fixture","scripts":{"build":"true"}}' > "$PROJECT_DIR/package.json"
  printf '%s\n' '{}' > "$PROJECT_DIR/package-lock.json"
  run_gate
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # The guard kept the cmd empty, so npm was never asked to run a missing
  # script — no "Missing script" / "npm error" text in the output.
  [[ "$output" != *"Missing script"* ]] || { echo "$output"; false; }
  [[ "$output" != *"npm error"* ]]
}

# --- Case 2: no package.json / pyproject / go.mod (pure shell/docs repo) ---
# Pre-fix the empty-cmd typecheck branch forced worst=fail → BLOCK(1).
@test "no package.json / pyproject / go.mod (shell/docs repo) -> pass/warn, never fail" {
  printf '%s\n' '# just docs' > "$PROJECT_DIR/README.md"
  run_gate
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

# --- Case 3: REGRESSION GUARD — a DECLARED check that genuinely FAILS ---
# Setting PROCESS_GATE_TYPECHECK_CMD short-circuits auto-detect entirely and
# drives run_check's preserved rc-nonzero → worst=fail path. The bright line
# must survive: a real failure still BLOCKs.
@test "declared typecheck that exits nonzero still hard-fails (exit 1)" {
  printf '%s\n' '# just docs' > "$PROJECT_DIR/README.md"
  # Export the failing cmd so the inner `bash -c` child inherits it; the
  # detected value short-circuits auto-detect and feeds run_check directly.
  run bash -c "cd '$PROJECT_DIR' && export PROCESS_GATE_TYPECHECK_CMD='false' && '$SCRIPT'"
  [ "$status" -eq 1 ]
}

# --- Case 4 (DL-P7-07 Go): go.mod present but `go` forced OFF PATH ---
# A single-module go.mod with `go` off PATH: pre-fix built `go vet ./...` /
# `go test ./...` on go.mod presence ALONE → they exit 127 ("command not
# found") → worst=fail → BLOCK. The command -v go guard now skips the whole Go
# branch when go is absent → all three downgrade to warn. go-absent is
# "couldn't-run", which the bright line maps to WARN.
@test "go.mod present but go off PATH -> pass/warn, never fail (DL-P7-07)" {
  printf '%s\n' 'module example.com/m' 'go 1.21' > "$PROJECT_DIR/go.mod"
  printf '%s\n' 'package main' 'func main() {}' > "$PROJECT_DIR/main.go"
  # Toolbox PATH WITHOUT go (go is not a coreutil; make_toolbox never adds it).
  local tb; tb="$(mktemp -d)"
  make_toolbox "$tb"
  # Sanity: go really is invisible under this PATH.
  PATH="$tb" command -v go >/dev/null 2>&1 && { echo "go leaked into toolbox PATH"; false; }
  run bash -c "cd '$PROJECT_DIR' && PATH='$tb' '$SCRIPT'"
  [ -n "$tb" ] && [ -d "$tb" ] && rm -rf "$tb"
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # The broken root-level go commands were never built/run.
  [[ "$output" != *"command not found"* ]] || { echo "$output"; false; }
  [[ "$output" != *"go vet"* ]]
}

# --- Case 5 (DL-P7-07 Go): go.work workspace ROOT, no Makefile vet/lint/test ---
# `go` is ON PATH here. A go.work workspace root with no Makefile target fell
# through (pre-fix) to root-level `go vet ./...`/`go test ./...`, which exit
# nonzero from a workspace root ("directory prefix . does not contain modules
# listed in go.work") → worst=fail → BLOCK. The restructured branch leaves
# typecheck/test UNDECLARED (warn) for a go.work root with no Makefile target.
# Skips when go is unavailable on the host (the restructure is about NOT running
# go from a workspace root; with go absent Case 4 already covers the path).
@test "go.work workspace root + no Makefile vet/lint/test -> pass/warn, never fail (DL-P7-07)" {
  command -v go >/dev/null 2>&1 || skip "go not installed"
  printf '%s\n' 'go 1.21' '' 'use ./m' > "$PROJECT_DIR/go.work"
  mkdir -p "$PROJECT_DIR/m"
  printf '%s\n' 'module example.com/m' 'go 1.21' > "$PROJECT_DIR/m/go.mod"
  printf '%s\n' 'package m' > "$PROJECT_DIR/m/m.go"
  # Run under a toolbox that HAS go but OMITS golangci-lint, so this case
  # isolates the no-Makefile workspace RESTRUCTURE (typecheck/test left
  # undeclared) from whether the host happens to have golangci-lint installed
  # (which the go.work arm would otherwise declare → host-dependent outcome).
  local tb; tb="$(mktemp -d)"
  make_toolbox "$tb" go
  PATH="$tb" command -v go >/dev/null 2>&1 || { echo "go missing from toolbox"; false; }
  PATH="$tb" command -v golangci-lint >/dev/null 2>&1 && { echo "golangci-lint leaked"; false; }
  run bash -c "cd '$PROJECT_DIR' && PATH='$tb' '$SCRIPT'"
  [ -n "$tb" ] && [ -d "$tb" ] && rm -rf "$tb"
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # The broken root-level workspace commands must not have been constructed.
  [[ "$output" != *"does not contain modules"* ]]
}

# --- Case 6 (DL-P7-07 Python): pyproject [tool.mypy] but mypy NOT runnable ---
# A `python` shim that exits nonzero makes the EXACT invocation form the cmd
# would use — `python -m mypy --version` (the probe) AND `python -m mypy .`
# (the cmd) — both fail deterministically, regardless of whether the host has
# python/mypy. Pre-fix built `python -m mypy .` on [tool.mypy] presence alone →
# exits nonzero → BLOCK. The runnable-probe now leaves the cmd EMPTY → warn.
@test "pyproject [tool.mypy] but mypy not runnable -> pass/warn, never fail (DL-P7-07)" {
  printf '%s\n' '[tool.mypy]' 'strict = true' > "$PROJECT_DIR/pyproject.toml"
  local shim; shim="$(mktemp -d)"
  # python shim exits 1 for ANY argv → probe and cmd both fail.
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$shim/python"
  chmod +x "$shim/python"
  # Put the shim FIRST so it shadows any real python; keep coreutils reachable.
  run bash -c "cd '$PROJECT_DIR' && PATH='$shim:$PATH' '$SCRIPT'"
  [ -n "$shim" ] && [ -d "$shim" ] && rm -rf "$shim"
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

# --- Case 7 (DL-P7-08): grep-fallback scoped to .scripts ---
# jq AND node BOTH hidden (forces pg_has_npm_script's last-resort grep tier).
# package.json has a devDependency literally named `test` but NO test script.
# Pre-fix the WHOLE-FILE grep matched the devDep `"test":` → built `npm run
# test` → the (faked) npm exits nonzero "Missing script" → BLOCK. The scoped
# grep (sed-extract the .scripts region first) no longer matches the devDep, so
# npm is never invoked. A multi-line (pretty-printed) package.json is used —
# the real-world shape — because the grep tier is best-effort/coarse and a
# single-line manifest collapses the sed range (documented coarseness, not a
# regression: the jq/node tiers are exact and run first when available).
@test "grep-fallback: devDependency named test (no test script) -> no npm-run-test, never fail (DL-P7-08)" {
  cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "name": "fixture",
  "scripts": {
    "build": "true"
  },
  "devDependencies": {
    "test": "^1.0.0"
  }
}
JSON
  printf '%s\n' '{}' > "$PROJECT_DIR/package-lock.json"   # → pg_resolve_pm = npm
  local tb; tb="$(mktemp -d)"
  make_toolbox "$tb"   # NO jq, NO node
  # A fake npm that announces itself and FAILS, so a pre-fix `npm run test` is
  # both observable (marker) and BLOCK-inducing.
  printf '%s\n' '#!/usr/bin/env bash' 'echo "FAKE-NPM-INVOKED argv: $*"' 'exit 1' > "$tb/npm"
  chmod +x "$tb/npm"
  # Sanity: jq and node are truly hidden; npm is present.
  PATH="$tb" command -v jq   >/dev/null 2>&1 && { echo "jq leaked";   false; }
  PATH="$tb" command -v node >/dev/null 2>&1 && { echo "node leaked"; false; }
  PATH="$tb" command -v npm  >/dev/null 2>&1 || { echo "npm missing"; false; }
  run bash -c "cd '$PROJECT_DIR' && PATH='$tb' '$SCRIPT'"
  [ -n "$tb" ] && [ -d "$tb" ] && rm -rf "$tb"
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # The scoped grep kept the test cmd EMPTY → npm was never invoked.
  [[ "$output" != *"FAKE-NPM-INVOKED"* ]]
}

# --- Case 8 (DL-P7-09 Go): partial Makefile — ONLY a `test:` target ---
# `go` is ON PATH and a go.mod (single module) is present, so the Go branch
# enters. The Makefile declares ONLY `test:` (no vet:/lint:). Pre-fix the arm
# built all THREE (make vet/make lint/make test) on the branch-entry grep
# matching ANY one target → `make vet`/`make lint` each exit 2 ("No rule to make
# target") → worst=fail → exit 1 → every merge BLOCKED. The PER-TARGET guard now
# builds `make vet`/`make lint` ONLY when their target is declared, so the two
# absent targets leave their cmds EMPTY → run_check WARNs them (couldn't-run).
# Skips when go is unavailable (the Go branch requires `command -v go`).
@test "go.mod + Makefile with ONLY a test target -> pass/warn, never fail (DL-P7-09)" {
  command -v go >/dev/null 2>&1 || skip "go not installed"
  command -v make >/dev/null 2>&1 || skip "make not installed"
  printf '%s\n' 'module example.com/m' 'go 1.21' > "$PROJECT_DIR/go.mod"
  printf '%s\n' 'package main' 'func main() {}' > "$PROJECT_DIR/main.go"
  # Only a test: target — a real, runnable recipe (so it does NOT itself fail).
  printf 'test:\n\t@echo running tests\n' > "$PROJECT_DIR/Makefile"
  run_gate
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # The absent vet/lint targets must NOT have been driven through make.
  [[ "$output" != *"No rule to make target"* ]] || { echo "$output"; false; }
  [[ "$output" != *"make vet"* ]] || { echo "$output"; false; }
  [[ "$output" != *"make lint"* ]]
}

# --- Case 9 (DL-P7-09 BRIGHT LINE): declared make target whose recipe FAILS ---
# `go` on PATH, a Makefile declaring a `test:` target whose recipe exits 1.
# A DECLARED + RUNNABLE check that genuinely FAILS must STILL hard-fail (exit 1).
# The per-target guard only downgrades ABSENT targets to warn; it must not turn
# the partial-Makefile fix into a never-fails gate. (vet/lint are absent here and
# warn-skip; the `make test` failure alone drives worst=fail.)
@test "go.mod + Makefile test target whose recipe exits 1 still hard-fails (exit 1, DL-P7-09 bright line)" {
  command -v go >/dev/null 2>&1 || skip "go not installed"
  command -v make >/dev/null 2>&1 || skip "make not installed"
  printf '%s\n' 'module example.com/m' 'go 1.21' > "$PROJECT_DIR/go.mod"
  printf '%s\n' 'package main' 'func main() {}' > "$PROJECT_DIR/main.go"
  printf 'test:\n\t@exit 1\n' > "$PROJECT_DIR/Makefile"
  run_gate
  [ "$status" -eq 1 ]
}

# --- Case 10 (DL-P7-10): grep-fallback brace terminator — sole-} on its line ---
# jq AND node BOTH hidden (forces pg_has_npm_script's last-resort grep tier). A
# multi-line package.json whose .scripts has an EARLIER value containing a literal
# `}` ("lint": "... '{...}'") and THEN a real `test` script. Pre-fix the `,/}/`
# sed range stopped at the FIRST line containing ANY `}` (the lint value's inline
# brace) → the region truncated BEFORE the test line → the real test script was
# MISSED → warn-skipped (fail-OPEN). The sole-`}`-line terminator
# (`,/^[[:space:]]*}/`) no longer ends on an in-value brace, so the test script
# is DETECTED. A fake `npm` writes a marker file ONLY when invoked as `run test`
# and exits 0 (so the gate does NOT block on the fake) — the marker's presence
# proves `$PM run test` was built+run, the INVERSE of being truncated/missed.
@test "grep-fallback: in-value } before a real test script still DETECTS the test script (DL-P7-10)" {
  cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "name": "fixture",
  "scripts": {
    "lint": "eslint --rule '{block-scoped-var: error}'",
    "test": "vitest run"
  }
}
JSON
  printf '%s\n' '{}' > "$PROJECT_DIR/package-lock.json"   # → pg_resolve_pm = npm
  local tb marker; tb="$(mktemp -d)"; marker="$PROJECT_DIR/npm-test-ran"
  make_toolbox "$tb"   # NO jq, NO node
  # Fake npm: touch the marker ONLY for `npm run test`; always exit 0 (a real,
  # passing test run — so detecting+running it does not itself BLOCK the gate).
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *"run test"*) : > "'"$marker"'";; esac' \
    'exit 0' > "$tb/npm"
  chmod +x "$tb/npm"
  # Sanity: jq and node are truly hidden; npm is present.
  PATH="$tb" command -v jq   >/dev/null 2>&1 && { echo "jq leaked";   false; }
  PATH="$tb" command -v node >/dev/null 2>&1 && { echo "node leaked"; false; }
  PATH="$tb" command -v npm  >/dev/null 2>&1 || { echo "npm missing"; false; }
  run bash -c "cd '$PROJECT_DIR' && PATH='$tb' '$SCRIPT'"
  local found=no; [ -f "$marker" ] && found=yes
  [ -n "$tb" ] && [ -d "$tb" ] && rm -rf "$tb"
  # The fixed scope DETECTED the later test script → `npm run test` was built+run.
  [ "$found" = "yes" ]
  # And detecting+running a passing test does not block.
  [ "$status" -ne 1 ]
}

# --- RED-GREEN DRIVER (DL-P7-09): partial-Makefile pre-fix reconstruction ---
#
# Reconstruct the PRE-DL-P7-09 state IN-TREE at test time and prove the
# only-test-target fixture (Case 8) goes RED (exit 1) against it, GREEN
# (warn, never 1) against the fixed script — so the suite itself, not a manual
# reviewer step, pins the discriminating power of the per-target Makefile guard.
# Same brittleness avoidance as the Python driver below: NO host path baked in,
# NO `git show HEAD:` (HEAD moves on commit). We copy the REAL scripts/ tree and
# sed-rewrite ONLY the three per-target `if grep ...; then PROCESS_GATE_*_CMD=...; fi`
# lines back into the pre-fix UNCONDITIONAL three-command build (make vet/lint/
# test built behind the single branch-entry grep). The reconstruction is asserted
# to still parse (bash -n) and the only-test-target fixture is driven against
# BOTH copies.
@test "RED-GREEN driver: pre-DL-P7-09 unconditional-three-target build BLOCKS the only-test-target fixture (exit 1)" {
  command -v go >/dev/null 2>&1 || skip "go not installed"
  command -v make >/dev/null 2>&1 || skip "make not installed"
  local skill_dir tree
  skill_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  tree="$(mktemp -d)"
  mkdir -p "$tree/scripts/lib"
  cp "$skill_dir/scripts/lib/common.sh" "$tree/scripts/lib/common.sh"
  # Collapse the three per-target guarded lines back to the pre-fix
  # unconditional build: replace each
  #   if grep -qE '^vet:'  Makefile 2>/dev/null; then PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-make vet}"; fi
  # with the bare assignment (no per-target grep). Anchored on the cmd-var name so
  # only these three lines are rewritten.
  sed -E \
    -e 's/^[[:space:]]*if grep -qE .\^vet:.[[:space:]]+Makefile 2>\/dev\/null; then (PROCESS_GATE_TYPECHECK_CMD="\$\{PROCESS_GATE_TYPECHECK_CMD:-make vet\}"); fi[[:space:]]*$/      \1/' \
    -e 's/^[[:space:]]*if grep -qE .\^lint:.[[:space:]]+Makefile 2>\/dev\/null; then (PROCESS_GATE_LINT_CMD="\$\{PROCESS_GATE_LINT_CMD:-make lint\}"); fi[[:space:]]*$/      \1/' \
    -e 's/^[[:space:]]*if grep -qE .\^test:.[[:space:]]+Makefile 2>\/dev\/null; then (PROCESS_GATE_TEST_CMD="\$\{PROCESS_GATE_TEST_CMD:-make test\}"); fi[[:space:]]*$/      \1/' \
    "$skill_dir/scripts/check-tests.sh" > "$tree/scripts/check-tests.sh"
  chmod +x "$tree/scripts/check-tests.sh"

  # Confirm the reconstruction actually removed the per-target guards (else the
  # RED below would be a false negative against an un-rewritten copy). Use
  # fixed-string greps (-F): the assignment text contains ${...} which a BRE
  # would mis-parse as an interval/bracket and fail to match the literal line.
  # Counted, not `! grep -qF`: a leading `!` never trips `set -e`, so the bare
  # form could not have caught an un-rewritten copy — the exact false negative
  # this precondition exists to rule out.
  [ "$(grep -cF "if grep -qE '^vet:'" "$tree/scripts/check-tests.sh")" -eq 0 ] ||
    { grep -nF "if grep -qE '^vet:'" "$tree/scripts/check-tests.sh"; false; }
  grep -qF 'PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-make vet}"' "$tree/scripts/check-tests.sh"
  # The reconstructed script must still parse.
  bash -n "$tree/scripts/check-tests.sh"

  # Only-test-target fixture (Case 8 shape).
  printf '%s\n' 'module example.com/m' 'go 1.21' > "$PROJECT_DIR/go.mod"
  printf '%s\n' 'package main' 'func main() {}' > "$PROJECT_DIR/main.go"
  printf 'test:\n\t@echo running tests\n' > "$PROJECT_DIR/Makefile"

  # RED: pre-fix reconstruction built make vet/make lint unconditionally → each
  # "No rule to make target" exits 2 → worst=fail → BLOCK.
  run bash -c "cd '$PROJECT_DIR' && '$tree/scripts/check-tests.sh'"
  local rec_status="$status"
  # GREEN: the fixed script builds only make test (declared) → vet/lint warn-skip.
  run bash -c "cd '$PROJECT_DIR' && '$skill_dir/scripts/check-tests.sh'"
  local fixed_status="$status"

  [ -n "$tree" ] && [ -d "$tree" ] && rm -rf "$tree"

  [ "$rec_status" -eq 1 ]
  [ "$fixed_status" -ne 1 ]
}

# --- RED-GREEN DRIVER (DL-P7-08 item 2, codifies DL-P5-11) ---
#
# Reconstruct the PRE-DL-P7-07 state IN-TREE at test time and prove the
# mypy-absent fixture (Case 6) goes RED (exit 1) against it — so the suite
# itself, not a manual reviewer step, pins the discriminating power of the
# Python runnable-probe. We DELIBERATELY avoid two brittle reconstructions:
#   - NO host path (e.g. /tmp/...) is baked in (mirror-bound: core-rules/ must
#     carry no operator paths).
#   - NO `git show HEAD:` (HEAD moves the instant this work commits → the RED
#     would silently flip to GREEN).
# Instead we copy the REAL scripts/ tree to a temp dir and strip ONLY the
# `&& $PY_RUN <tool> --version ...` runnable-probe suffix with one anchored
# sed — yielding a syntactically-valid script whose Python branch builds the
# cmd on config presence alone (exactly the pre-fix semantics). PG_TEST_SCRIPT
# points the gate at the reconstructed copy; the SAME mypy-absent env+fixture
# is driven and asserted RED.
@test "RED-GREEN driver: pre-DL-P7-07 reconstruction BLOCKS the mypy-absent fixture (exit 1)" {
  local skill_dir tree
  skill_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  tree="$(mktemp -d)"
  mkdir -p "$tree/scripts/lib"
  cp "$skill_dir/scripts/lib/common.sh" "$tree/scripts/lib/common.sh"
  # Strip the per-tool runnable-probe suffix → reconstruct config-presence-only
  # (pre-DL-P7-07) Python defaulting. The braces remain (valid bash).
  sed -E 's/ && \$PY_RUN (mypy|ruff|pytest) --version >\/dev\/null 2>&1//' \
    "$skill_dir/scripts/check-tests.sh" > "$tree/scripts/check-tests.sh"
  chmod +x "$tree/scripts/check-tests.sh"

  # The reconstructed script must still parse.
  bash -n "$tree/scripts/check-tests.sh"

  # Same fixture + env as Case 6.
  printf '%s\n' '[tool.mypy]' 'strict = true' > "$PROJECT_DIR/pyproject.toml"
  local shim; shim="$(mktemp -d)"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$shim/python"
  chmod +x "$shim/python"

  # Drive the RECONSTRUCTED (pre-fix) script directly. (The PG_TEST_SCRIPT
  # setup indirection — which lets the WHOLE suite be re-pointed at a pre-fix
  # copy — is exercised by running this .bats file with PG_TEST_SCRIPT set; this
  # @test pins the reconstruction's RED self-containedly, no host/temp copy.)
  run bash -c "cd '$PROJECT_DIR' && PATH='$shim:$PATH' '$tree/scripts/check-tests.sh'"
  local rec_status="$status"

  # And the REAL (fixed) script against the identical fixture+env (GREEN).
  run bash -c "cd '$PROJECT_DIR' && PATH='$shim:$PATH' '$skill_dir/scripts/check-tests.sh'"
  local fixed_status="$status"

  [ -n "$tree" ]  && [ -d "$tree" ]  && rm -rf "$tree"
  [ -n "$shim" ]  && [ -d "$shim" ]  && rm -rf "$shim"

  # RED: pre-fix reconstruction BLOCKS (built `python -m mypy .`, it failed).
  [ "$rec_status" -eq 1 ]
  # GREEN: the fixed script never built the cmd → warn, never blocks.
  [ "$fixed_status" -ne 1 ]
}

# `run_check` drives typecheck, lint AND tests, and the timeout it applied was
# read from one variable named for only one of them. A project whose battery
# legitimately runs for hours raises PROCESS_GATE_TEST_TIMEOUT — and silently
# removed the ceiling from typecheck and lint at the same time. The ceilings are
# separate now: PROCESS_GATE_CHECK_TIMEOUT governs typecheck and lint.
@test "raising the test timeout does not raise the typecheck/lint ceiling" {
  command -v timeout >/dev/null 2>&1 || skip "no timeout(1) on this host"

  run bash -c "cd '$PROJECT_DIR' && \
    PROCESS_GATE_TEST_TIMEOUT=30 PROCESS_GATE_CHECK_TIMEOUT=1 \
    PROCESS_GATE_TYPECHECK_CMD='sleep 5' \
    PROCESS_GATE_LINT_CMD='true' \
    PROCESS_GATE_TEST_CMD='sleep 3' \
    '$SCRIPT'"

  # typecheck is killed at its own 1 s ceiling → 124 → hard fail.
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"typecheck:"*"exited 124"* ]] || { echo "$output"; false; }
  # ...while the test command, well inside the raised test ceiling, is untouched.
  [[ "$output" != *"tests:"*"exited"* ]] || { echo "$output"; false; }
}

# --- Optional assertion-flip mutation spot-check (Spec 001 Phase 8a) ---
# The feature is opt-in and report-only. Fixtures use real two-commit repos so
# changed-file selection, isolated clone setup, deterministic assertion choice,
# and caller-tree preservation are all exercised together.
@test "mutation spot-check is default-off and runs no extra test command" {
  make_mutation_fixture js
  PROCESS_GATE_MUTATION_SPOTCHECK=0
  run_mutation_gate
  local gate_status="$status" gate_output="$output"

  [ "$gate_status" -eq 0 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" != *"mutation spot-check"* ]] || { echo "$gate_output"; false; }
  [ "$(wc -l < "$MUTATION_LOG" | tr -d '[:space:]')" -eq 1 ] ||
    { cat "$MUTATION_LOG"; false; }

  run git -C "$PROJECT_DIR" status --porcelain --untracked-files=no
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "mutation scratch allocation failure warns instead of aborting under set -e" {
  make_mutation_fixture js
  mkdir -p "$PROJECT_DIR/fail-bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$PROJECT_DIR/fail-bin/mktemp"
  chmod +x "$PROJECT_DIR/fail-bin/mktemp"

  PATH="$PROJECT_DIR/fail-bin:$PATH" run_mutation_gate
  local gate_status="$status" gate_output="$output"

  [ "$gate_status" -eq 2 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"unable to create mutation scratch directory — skipped"* ]] ||
    { echo "$gate_output"; false; }
  [ "$(wc -l < "$MUTATION_LOG" | tr -d '[:space:]')" -eq 1 ] ||
    { cat "$MUTATION_LOG"; false; }
}

@test "JS assertion flip kills the lexicographically first changed assertion in an isolated clone" {
  make_mutation_fixture js
  run_mutation_gate
  local gate_status="$status" gate_output="$output"
  local last_run
  last_run="$(tail -n 1 "$MUTATION_LOG")"

  [ "$gate_status" -eq 0 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"assertion flip killed in tests/a.test.js"* ]] ||
    { echo "$gate_output"; false; }
  [ "$(wc -l < "$MUTATION_LOG" | tr -d '[:space:]')" -eq 3 ] ||
    { cat "$MUTATION_LOG"; false; }
  [[ "$last_run" == *"|1|0|0" ]] || { cat "$MUTATION_LOG"; false; }
  [ "$(grep -cF "$PROJECT_DIR|" "$MUTATION_LOG")" -eq 1 ] ||
    { cat "$MUTATION_LOG"; false; }
  [ "$(grep -cF '.not.toBe' "$PROJECT_DIR/tests/a.test.js" || true)" -eq 0 ] ||
    { cat "$PROJECT_DIR/tests/a.test.js"; false; }

  run git -C "$PROJECT_DIR" status --porcelain --untracked-files=no
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "JS assertion flip targets the expect matcher after an earlier toFixed call" {
  make_mutation_fixture js
  printf '%s\n' \
    'test("price", () => expect((1).toFixed(2)).toBe("1.00"))' \
    '// changed' > "$PROJECT_DIR/tests/a.test.js"
  git -C "$PROJECT_DIR" add tests/a.test.js
  git -C "$PROJECT_DIR" commit -q --amend --no-edit

  run_mutation_gate
  local gate_status="$status" gate_output="$output"

  [ "$gate_status" -eq 0 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"assertion flip killed in tests/a.test.js"* ]] ||
    { echo "$gate_output"; false; }
  [[ "$(tail -n 1 "$MUTATION_LOG")" == *"|1|0|0" ]] ||
    { cat "$MUTATION_LOG"; false; }
  [ "$(grep -cF '.not.toFixed' "$PROJECT_DIR/tests/a.test.js" || true)" -eq 0 ] ||
    { cat "$PROJECT_DIR/tests/a.test.js"; false; }
}

@test "inherited GIT_DIR cannot redirect scratch checkout or test commands into caller state" {
  make_mutation_fixture js
  local head_before index_before worktree_before status_before
  head_before="$(cat "$PROJECT_DIR/.git/HEAD")"
  index_before="$(git hash-object "$PROJECT_DIR/.git/index")"
  worktree_before="$(git hash-object "$PROJECT_DIR/tests/a.test.js")"
  status_before="$(git -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=all)"

  export GIT_DIR="$PROJECT_DIR/.git"
  run_mutation_gate
  local gate_status="$status" gate_output="$output"
  unset GIT_DIR

  [ "$gate_status" -eq 0 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"assertion flip killed in tests/a.test.js"* ]] ||
    { echo "$gate_output"; false; }
  [ "$(cat "$PROJECT_DIR/.git/HEAD")" = "$head_before" ] ||
    { cat "$PROJECT_DIR/.git/HEAD"; false; }
  [ "$(git hash-object "$PROJECT_DIR/.git/index")" = "$index_before" ] ||
    { echo "caller index bytes changed"; false; }
  [ "$(git hash-object "$PROJECT_DIR/tests/a.test.js")" = "$worktree_before" ] ||
    { echo "caller test bytes changed"; false; }
  run git -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=all
  [ "$status" -eq 0 ] && [ "$output" = "$status_before" ] ||
    { echo "$output"; false; }
}

@test "surviving assertion flip is a warning, never a hard failure" {
  make_mutation_fixture js
  MUTATION_BEHAVIOR=survive
  run_mutation_gate
  local gate_status="$status" gate_output="$output"

  [ "$gate_status" -eq 2 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"mutation spot-check: assertion flip survived in tests/a.test.js"* ]] ||
    { echo "$gate_output"; false; }
  [[ "$(tail -n 1 "$MUTATION_LOG")" == *"|1|0|0" ]] ||
    { cat "$MUTATION_LOG"; false; }

  run git -C "$PROJECT_DIR" status --porcelain --untracked-files=no
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "Python assert inversion is recognized and killed" {
  make_mutation_fixture python
  run_mutation_gate
  local gate_status="$status" gate_output="$output"

  [ "$gate_status" -eq 0 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"assertion flip killed in tests/test_example.py"* ]] ||
    { echo "$gate_output"; false; }
  [[ "$(tail -n 1 "$MUTATION_LOG")" == *"|0|1|0" ]] ||
    { cat "$MUTATION_LOG"; false; }

  run git -C "$PROJECT_DIR" status --porcelain --untracked-files=no
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "Go testing comparison inversion is recognized and killed" {
  make_mutation_fixture go
  run_mutation_gate
  local gate_status="$status" gate_output="$output"

  [ "$gate_status" -eq 0 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"assertion flip killed in sample_test.go"* ]] ||
    { echo "$gate_output"; false; }
  [[ "$(tail -n 1 "$MUTATION_LOG")" == *"|0|0|1" ]] ||
    { cat "$MUTATION_LOG"; false; }

  run git -C "$PROJECT_DIR" status --porcelain --untracked-files=no
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "mutation command timeout warns and stays bounded" {
  make_mutation_fixture js
  MUTATION_BEHAVIOR=timeout
  PROCESS_GATE_MUTATION_TIMEOUT=1
  run_mutation_gate
  local gate_status="$status" gate_output="$output"

  [ "$gate_status" -eq 2 ] || { echo "$gate_output"; false; }
  [[ "$gate_output" == *"assertion flip timed out after 1s in tests/a.test.js"* ]] ||
    { echo "$gate_output"; false; }

  run git -C "$PROJECT_DIR" status --porcelain --untracked-files=no
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}
