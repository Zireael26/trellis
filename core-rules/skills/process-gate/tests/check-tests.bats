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
  PROJECT_DIR="$(mktemp -d)"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
  # Don't let an operator's ambient PROCESS_GATE_* config leak into auto-detect.
  unset PROCESS_GATE_TYPECHECK_CMD PROCESS_GATE_LINT_CMD PROCESS_GATE_TEST_CMD
  unset PROCESS_GATE_COVERAGE_CMD PROCESS_GATE_COVERAGE_FLOOR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

run_gate() {
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT'"
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
  [[ "$output" != *"Missing script"* ]]
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
  [[ "$output" != *"command not found"* ]]
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
  [[ "$output" != *"No rule to make target"* ]]
  [[ "$output" != *"make vet"* ]]
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
  ! grep -qF "if grep -qE '^vet:'" "$tree/scripts/check-tests.sh"
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
