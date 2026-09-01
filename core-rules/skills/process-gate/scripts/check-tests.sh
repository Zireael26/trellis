#!/usr/bin/env bash
# Gate 4: Tests & coverage — runs project-declared typecheck/lint/test commands.
# Usage: check-tests.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"
cd "$PROJECT_DIR"

# Git exports repository-local routing variables to hooks. The configured test
# command is a fixture suite, not an extension of the hook's Git process: if it
# inherits GIT_DIR, even `git -C "$fixture"` continues to target the checkout
# that launched pre-push. Resolve the intended project first, cd there, then
# remove every local routing override before typecheck/lint/tests (and their
# descendants) run. scripts/run-tests.sh adds a second, fail-loud mutation
# fence; this clearing is what makes the ordinary fixture path resolve normally.
# Keep this list explicit and mirrored in scripts/run-tests.sh.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
unset GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE
unset GIT_SHALLOW_FILE GIT_CEILING_DIRECTORIES
unset GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE
unset GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
while IFS= read -r git_config_var; do
  [ -n "$git_config_var" ] && unset "$git_config_var"
done < <(compgen -A variable GIT_CONFIG_KEY_ || true)
while IFS= read -r git_config_var; do
  [ -n "$git_config_var" ] && unset "$git_config_var"
done < <(compgen -A variable GIT_CONFIG_VALUE_ || true)
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

# pg_has_npm_script <script-name>  (cwd is PROJECT_DIR)
#   Returns 0 only when package.json declares the named script. Portable across
#   jq → node → a grep fallback on .scripts. Used to keep an undeclared script's
#   command EMPTY rather than constructing `$PM run <name>` which exits nonzero
#   ("Missing script") and would wrongly BLOCK repos without that script.
pg_has_npm_script() {
  [ -f package.json ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg s "$1" '.scripts[$s] != null' package.json >/dev/null 2>&1
  elif command -v node >/dev/null 2>&1; then
    node -e 'var s=(require("./package.json").scripts)||{};process.exit(s[process.argv[1]]?0:1)' "$1" 2>/dev/null
  else
    # Last-resort grep tier: best-effort (COARSE) — only the jq and node tiers
    # above are exact. Scope the match to the .scripts object region first (the
    # "scripts" key to the next closing brace) so a non-script key of the same
    # name (e.g. a devDependency literally named "test") cannot false-positive
    # into building `$PM run <name>` for a script that doesn't exist → BLOCK.
    # Terminate on a closing brace ALONE on its line (DL-P7-10): a `,/}/` range
    # stops at the FIRST line containing ANY `}`, so a .scripts VALUE that itself
    # contains a literal `}` (e.g. "lint": "eslint --rule '{...}'") before the
    # target script would truncate the region → MISS a genuinely-declared later
    # script → warn-skip a real test (fail-OPEN). `/^[[:space:]]*}/` ends only on
    # a sole-`}` line, so an in-value brace no longer closes the region.
    # STILL COARSE: a multi-line script value with its own sole-`}` line could
    # truncate, and nested script maps are not parsed — only the jq and node
    # tiers are exact. (No JSON parser here — that is what those tiers are for.)
    sed -n '/"scripts"[[:space:]]*:/,/^[[:space:]]*}/p' package.json 2>/dev/null \
      | grep -Eq "\"$1\"[[:space:]]*:" 2>/dev/null
  fi
}

worst="pass"
findings=()

# Auto-detect package manager if not declared
if [ -z "${PROCESS_GATE_TYPECHECK_CMD:-}${PROCESS_GATE_LINT_CMD:-}${PROCESS_GATE_TEST_CMD:-}" ]; then
  PM="$(pg_resolve_pm "$PROJECT_DIR")"
  # Configured-but-missing PM → surface as WARN and skip the JS toolchain rather
  # than hard-failing the gate (mirrors stop-verify / pre-push skip-on-absent-PM).
  if [ -n "$PM" ] && [ -f "package.json" ] && ! command -v "$PM" >/dev/null 2>&1; then
    pg_log warn "Tests & coverage"
    pg_finding "package manager '$PM' not on PATH — JS typecheck/lint/test skipped (install $PM, or set PROCESS_GATE_*_CMD in local.config.sh)"
    exit 2
  fi
  # `$PM run <script>` is the portable form across pnpm/npm/yarn/bun — bare
  # `npm typecheck`/`npm lint` are invalid (npm only aliases test/start/stop).
  # Only build the command when package.json actually declares the script;
  # otherwise leave the cmd EMPTY so run_check downgrades it to a WARN instead
  # of running a missing npm script that exits nonzero and BLOCKS the gate.
  if [ -n "$PM" ] && [ -f "package.json" ]; then
    if pg_has_npm_script typecheck; then PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PM run typecheck}"; fi
    if pg_has_npm_script lint;      then PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PM run lint}"; fi
    if pg_has_npm_script test;      then PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PM run test}"; fi
  fi

  # Python toolchain detection (order: uv → poetry → pdm → bare pyproject)
  if [ -z "${PM:-}" ] && [ -f "pyproject.toml" ]; then
    if   [ -f "uv.lock" ];     then PY_RUN="uv run"
    elif [ -f "poetry.lock" ]; then PY_RUN="poetry run"
    elif [ -f "pdm.lock" ];    then PY_RUN="pdm run"
    else PY_RUN="python -m"
    fi

    # Default typecheck: mypy if configured (pyproject [tool.mypy] or mypy.ini).
    # Pyright is opt-in via explicit PROCESS_GATE_TYPECHECK_CMD override.
    # Config-presence is NOT enough (DL-P7-07): also probe that the tool is
    # RUNNABLE in its own env via the EXACT `$PY_RUN <tool>` invocation form
    # (so `python -m mypy`, `uv run mypy`, `poetry run mypy` each resolve a
    # venv/uv-managed tool; `--version` is fast and side-effect-free). A
    # configured-but-not-installed tool leaves the cmd EMPTY → run_check WARNs
    # (couldn't-run), instead of failing at runtime → BLOCK.
    if { grep -q '^\[tool\.mypy\]' pyproject.toml 2>/dev/null || [ -f "mypy.ini" ]; } && $PY_RUN mypy --version >/dev/null 2>&1; then
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PY_RUN mypy .}"
    fi

    # Default lint: ruff if configured and runnable.
    if { grep -q '^\[tool\.ruff\]' pyproject.toml 2>/dev/null || [ -f "ruff.toml" ]; } && $PY_RUN ruff --version >/dev/null 2>&1; then
      PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PY_RUN ruff check .}"
    fi

    # Default tests: pytest if configured and runnable.
    if { grep -q '^\[tool\.pytest\.ini_options\]' pyproject.toml 2>/dev/null \
       || [ -f "pytest.ini" ] || [ -f "conftest.py" ]; } && $PY_RUN pytest --version >/dev/null 2>&1; then
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PY_RUN pytest}"
    fi
  fi

  # Go toolchain detection (workspaces or single module).
  # Require `go` on PATH for the ENTIRE branch (DL-P7-07): a configured Go repo
  # with `go` off PATH would make `go vet`/`go test` (and any make target that
  # drives go) exit 127 at runtime → worst=fail → BLOCK. go-absent is
  # "couldn't-run", which the bright line maps to WARN, not fail — so when go
  # is absent we build NO go commands (all three downgrade to warn). This guard
  # also covers the make-target arm: a `make vet/test` that shells out to go
  # needs go present too.
  if [ -z "${PM:-}" ] && { [ -f "go.work" ] || [ -f "go.mod" ]; } && command -v go >/dev/null 2>&1; then
    # Go workspaces break `go vet ./...` and `go test ./...` from the repo
    # root — prefer a Makefile orchestrator if one exposes vet/lint/test
    # targets. Multi-language monorepos commonly use this pattern.
    if [ -f "Makefile" ] && grep -qE '^(vet|lint|test):' Makefile 2>/dev/null; then
      # PER-TARGET guard (DL-P7-09): the branch enters on ANY ONE of
      # vet/lint/test being a Makefile target, but each `make <target>` command
      # is built ONLY when that SPECIFIC target is declared. A Makefile that
      # declares only a subset (e.g. just `test:`) previously ran `make vet` /
      # `make lint` anyway — each exits 2 ("No rule to make target") → worst=fail
      # → BLOCK. A missing make target is "couldn't-run", which the bright line
      # maps to WARN: leave its cmd EMPTY so run_check downgrades it. A DECLARED
      # target whose recipe genuinely fails (`make test` exits 1) still hard-fails.
      if grep -qE '^vet:'  Makefile 2>/dev/null; then PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-make vet}"; fi
      if grep -qE '^lint:' Makefile 2>/dev/null; then PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-make lint}"; fi
      if grep -qE '^test:' Makefile 2>/dev/null; then PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-make test}"; fi
    elif [ -f "go.work" ]; then
      # go.work workspace ROOT with no Makefile vet/lint/test target: the
      # root-level `go vet ./...` / `go test ./...` are BROKEN here (they exit
      # nonzero with "directory prefix . does not contain modules listed in
      # go.work") → would BLOCK. Leave typecheck/test UNDECLARED so they
      # downgrade to warn; do NOT build the broken root-level commands.
      # golangci-lint is still safe to declare (module-aware) when present.
      if command -v golangci-lint >/dev/null 2>&1; then
        PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-golangci-lint run ./...}"
      fi
    else
      # Single-module go.mod (no go.work, no Makefile targets): `go vet ./...`
      # and `go test ./...` are valid from the module root.
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-go vet ./...}"
      if command -v golangci-lint >/dev/null 2>&1; then
        PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-golangci-lint run ./...}"
      fi
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-go test ./...}"
    fi
  fi
fi

# Two ceilings, because `run_check` drives typecheck, lint AND tests through one
# code path. A project whose battery legitimately runs for hours has to raise the
# test ceiling, and while there was only one variable that raise silently removed
# the guard from typecheck and lint too — the two checks that should never take
# more than a few minutes and whose runaway is exactly what a timeout is for.
PROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-300}"
PROCESS_GATE_CHECK_TIMEOUT="${PROCESS_GATE_CHECK_TIMEOUT:-300}"

# Portable hard ceiling for the optional mutation probe. Unlike the main checks'
# historical timeout path above, this new work must never run unbounded on macOS
# (where GNU timeout is normally absent). The perl process-group pattern matches
# the reviewer/propose-rules guards; 125 means no bounded runner is available.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $secs = shift @ARGV;
      my $pid = fork();
      exit 125 if !defined $pid;
      if ($pid == 0) { POSIX::setsid(); exec @ARGV or POSIX::_exit(127); }
      $SIG{ALRM} = sub {
        kill("TERM", -$pid); select(undef, undef, undef, 0.3);
        kill("KILL", -$pid); waitpid($pid, 0); exit(142);
      };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@"
  else
    return 125
  fi
}

run_check() {
  local label="$1" cmd="$2" limit
  case "$label" in
    tests) limit="$PROCESS_GATE_TEST_TIMEOUT" ;;
    *)     limit="$PROCESS_GATE_CHECK_TIMEOUT" ;;
  esac
  # Bright line: ABSENT/UNDECLARED check → WARN, never a fail. A check that is
  # declared/detected and FAILS at runtime (rc nonzero, below) stays a hard
  # fail. An empty cmd means the check was never declared or auto-detected, so
  # it must not BLOCK — every label downgrades to warn (was: typecheck→fail).
  if [ -z "$cmd" ]; then
    findings+=("$label: not declared/detected — skipped")
    if [ "$worst" = "pass" ]; then
      worst="warn"
    fi
    return 0
  fi

  local out rc
  set +e
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout "$limit" bash -c "$cmd" 2>&1)"; rc=$?
  else
    out="$(bash -c "$cmd" 2>&1)"; rc=$?
  fi
  set -e

  if [ "$rc" -ne 0 ]; then
    findings+=("$label: \`$cmd\` exited $rc")
    # Last 10 lines of output for context
    while IFS= read -r line; do
      findings+=("    $line")
    done < <(printf "%s\n" "$out" | tail -n 10)
    worst="fail"
  fi
}

run_check "typecheck" "${PROCESS_GATE_TYPECHECK_CMD:-}"
run_check "lint"      "${PROCESS_GATE_LINT_CMD:-}"
run_check "tests"     "${PROCESS_GATE_TEST_CMD:-}"

# Optional: coverage
if [ -n "${PROCESS_GATE_COVERAGE_CMD:-}" ]; then
  out="$(bash -c "$PROCESS_GATE_COVERAGE_CMD" 2>&1 || true)"
  pct="$(printf "%s" "$out" | grep -oE 'All files[^|]*\|[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?$' | head -1)"
  floor="${PROCESS_GATE_COVERAGE_FLOOR:-0}"
  if [ -n "$pct" ] && [ "$(printf '%.0f' "$pct")" -lt "$floor" ]; then
    findings+=("coverage: ${pct}% < floor ${floor}%")
    if [ "$worst" = "pass" ]; then worst="warn"; fi
  fi
fi

# Optional report-only mutation spot-check. It considers at most the first 25
# supported changed test files (C-locale path order), flips exactly one
# assertion in a disposable local clone, verifies the clone's unmodified control
# first, then runs the same test command under a short hard ceiling. The caller's
# checkout is never edited. Unsupported/inconclusive/surviving probes WARN; they
# never turn a passing baseline into a hard failure.
mutation_result=""
if [ "${PROCESS_GATE_MUTATION_SPOTCHECK:-0}" = "1" ] && [ "$worst" != "fail" ]; then
  mutation_timeout="${PROCESS_GATE_MUTATION_TIMEOUT:-30}"
  mutation_skip=""
  mutation_target=""
  mutation_kind=""

  # Scratch operations must not inherit repository-local routing from a hook
  # caller. In particular, GIT_DIR can make `git -C <scratch> checkout` move the
  # caller's HEAD instead of the disposable clone's HEAD.
  mutation_clean_env=(
    env
    -u GIT_DIR
    -u GIT_WORK_TREE
    -u GIT_COMMON_DIR
    -u GIT_INDEX_FILE
    -u GIT_OBJECT_DIRECTORY
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES
    -u GIT_PREFIX
    -u GIT_IMPLICIT_WORK_TREE
    -u GIT_GRAFT_FILE
    -u GIT_REPLACE_REF_BASE
    -u GIT_SHALLOW_FILE
    -u GIT_CEILING_DIRECTORIES
    -u GIT_DISCOVERY_ACROSS_FILESYSTEM
    -u GIT_NAMESPACE
  )

  case "$mutation_timeout" in
    ""|0|*[!0-9]*) mutation_skip="invalid PROCESS_GATE_MUTATION_TIMEOUT '$mutation_timeout' — skipped" ;;
  esac
  if [ -z "$mutation_skip" ] && [ -z "${PROCESS_GATE_TEST_CMD:-}" ]; then
    mutation_skip="test command unavailable — skipped"
  fi
  case "$RANGE" in
    -*) [ -n "$mutation_skip" ] || mutation_skip="unsafe diff range '$RANGE' — skipped" ;;
  esac

  if [ -z "$mutation_skip" ]; then
    if ! tracked_dirty="$(git status --porcelain --untracked-files=no 2>/dev/null)"; then
      mutation_skip="project is not a readable git worktree — skipped"
    elif [ -n "$tracked_dirty" ]; then
      mutation_skip="tracked working tree is dirty — skipped to keep the clone/control exact"
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    if mutation_work="$(mktemp -d 2>/dev/null || mktemp -d -t check-tests-mutation)" \
      && [ -n "$mutation_work" ] && [ -d "$mutation_work" ]; then
      # shellcheck disable=SC2154  # rc is assigned inside the trap
      trap 'rc=$?; rm -rf "$mutation_work"; exit "$rc"' EXIT
    else
      mutation_skip="unable to create mutation scratch directory — skipped"
    fi

    if [ -z "$mutation_skip" ]; then
    if ! pg_diff_files "$RANGE" > "$mutation_work/changed"; then
      mutation_skip="unable to enumerate changed files for range '$RANGE' — skipped"
    else
      LC_ALL=C sort -u "$mutation_work/changed" > "$mutation_work/changed.sorted"
      mutation_scanned=0
      while IFS= read -r mutation_file; do
        mutation_file_kind=""
        case "$mutation_file" in
          *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|__tests__/*.js|__tests__/*.jsx|__tests__/*.ts|__tests__/*.tsx|test/*.js|test/*.jsx|test/*.ts|test/*.tsx|tests/*.js|tests/*.jsx|tests/*.ts|tests/*.tsx|*/__tests__/*.js|*/__tests__/*.jsx|*/__tests__/*.ts|*/__tests__/*.tsx|*/test/*.js|*/test/*.jsx|*/test/*.ts|*/test/*.tsx|*/tests/*.js|*/tests/*.jsx|*/tests/*.ts|*/tests/*.tsx)
            mutation_file_kind="js"
            ;;
          test_*.py|*_test.py|*/test_*.py|test/*.py|tests/*.py|*/test/*.py|*/tests/*.py)
            mutation_file_kind="python"
            ;;
          *_test.go)
            mutation_file_kind="go"
            ;;
        esac
        [ -n "$mutation_file_kind" ] || continue
        [ -f "$PROJECT_DIR/$mutation_file" ] || continue
        [ ! -L "$PROJECT_DIR/$mutation_file" ] || continue
        mutation_scanned=$((mutation_scanned + 1))
        [ "$mutation_scanned" -le 25 ] || break

        mutation_bytes="$(wc -c < "$PROJECT_DIR/$mutation_file" | tr -d '[:space:]')"
        case "$mutation_bytes" in
          ""|*[!0-9]*) continue ;;
        esac
        [ "$mutation_bytes" -le 262144 ] || continue

        set +e
        case "$mutation_file_kind" in
          js)
            awk '
              BEGIN {
                # Deliberately bounded to core Jest/Vitest matchers. Custom
                # matchers and arbitrary `.to*` methods are unsupported rather
                # than risking a runtime-error mutant that looks assertion-killed.
                expect_matchers = "(Be|Equal|StrictEqual|BeCloseTo|BeDefined|BeFalsy|BeGreaterThan|BeGreaterThanOrEqual|BeInstanceOf|BeLessThan|BeLessThanOrEqual|BeNaN|BeNull|BeTruthy|BeUndefined|Contain|ContainEqual|HaveBeenCalled|HaveBeenCalledTimes|HaveBeenCalledWith|HaveBeenLastCalledWith|HaveBeenNthCalledWith|HaveLastReturnedWith|HaveLength|HaveNthReturnedWith|HaveProperty|HaveReturned|HaveReturnedTimes|HaveReturnedWith|Match|MatchObject|MatchSnapshot|MatchInlineSnapshot|Throw|ThrowError|ThrowErrorMatchingSnapshot|ThrowErrorMatchingInlineSnapshot)"
                expect_modifier = "([.](resolves|rejects))?"
                expect_not = "^[[:space:]]*" expect_modifier "[.]not[.]to" expect_matchers "[[:space:]]*[(]"
                expect_positive = "^[[:space:]]*" expect_modifier "[.]to" expect_matchers "[[:space:]]*[(]"
              }
              function flip_expect(line,    scan, segment, open, i, c, depth, quote, escaped, closing, suffix, at) {
                scan = 1
                while (scan <= length(line)) {
                  segment = substr(line, scan)
                  if (!match(segment, /(^|[^[:alnum:]_$])expect[[:space:]]*[(]/)) return line
                  open = scan + RSTART + RLENGTH - 2
                  depth = 1
                  quote = ""
                  escaped = 0
                  closing = 0
                  for (i = open + 1; i <= length(line); i++) {
                    c = substr(line, i, 1)
                    if (quote != "") {
                      if (escaped) {
                        escaped = 0
                      } else if (c == "\\") {
                        escaped = 1
                      } else if (c == quote) {
                        quote = ""
                      }
                    } else if (c == "\"" || c == "\047" || c == "`") {
                      quote = c
                    } else if (c == "(") {
                      depth++
                    } else if (c == ")") {
                      depth--
                      if (depth == 0) {
                        closing = i
                        break
                      }
                    }
                  }
                  if (!closing) return line

                  suffix = substr(line, closing + 1)
                  if (suffix ~ expect_not) {
                    match(suffix, /[.]not[.]to/)
                    at = RSTART
                    return substr(line, 1, closing) substr(suffix, 1, at - 1) ".to" substr(suffix, at + 7)
                  }
                  if (suffix ~ expect_positive) {
                    match(suffix, "[.]to" expect_matchers)
                    at = RSTART
                    return substr(line, 1, closing) substr(suffix, 1, at - 1) ".not.to" substr(suffix, at + 3)
                  }
                  scan = closing + 1
                }
                return line
              }
              {
                line = $0
                if (!done && line ~ /expect[[:space:]]*[(]/) {
                  flipped = flip_expect(line)
                  if (flipped != line) {
                    line = flipped
                    done = 1
                  }
                }
                if (!done && line ~ /assert[.]/) {
                  if (line ~ /assert[.]notDeepStrictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]notDeepStrictEqual/, "assert.deepStrictEqual", line); done = 1
                  } else if (line ~ /assert[.]deepStrictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]deepStrictEqual/, "assert.notDeepStrictEqual", line); done = 1
                  } else if (line ~ /assert[.]notStrictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]notStrictEqual/, "assert.strictEqual", line); done = 1
                  } else if (line ~ /assert[.]strictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]strictEqual/, "assert.notStrictEqual", line); done = 1
                  } else if (line ~ /assert[.]notEqual[[:space:]]*[(]/) {
                    sub(/assert[.]notEqual/, "assert.equal", line); done = 1
                  } else if (line ~ /assert[.]equal[[:space:]]*[(]/) {
                    sub(/assert[.]equal/, "assert.notEqual", line); done = 1
                  }
                }
                print line
              }
              END { if (!done) exit 3 }
            ' "$PROJECT_DIR/$mutation_file" > "$mutation_work/mutated"
            mutation_rc=$?
            ;;
          python)
            awk '
              {
                line = $0
                if (!done && line ~ /^[[:space:]]*assert[[:space:]]+/) {
                  if (line ~ /^[[:space:]]*assert[[:space:]]+not[[:space:]]+/) {
                    sub(/assert[[:space:]]+not[[:space:]]+/, "assert ", line)
                  } else {
                    sub(/assert[[:space:]]+/, "assert not ", line)
                  }
                  done = 1
                }
                print line
              }
              END { if (!done) exit 3 }
            ' "$PROJECT_DIR/$mutation_file" > "$mutation_work/mutated"
            mutation_rc=$?
            ;;
          go)
            awk '
              { lines[NR] = $0 }
              END {
                for (i = 1; i <= NR && !done; i++) {
                  if (lines[i] ~ /(assert|require)[.]NotEqual[[:space:]]*[(]/) {
                    sub(/[.]NotEqual/, ".Equal", lines[i]); done = 1
                  } else if (lines[i] ~ /(assert|require)[.]Equal[[:space:]]*[(]/) {
                    sub(/[.]Equal/, ".NotEqual", lines[i]); done = 1
                  } else if (lines[i] ~ /(assert|require)[.]False[[:space:]]*[(]/) {
                    sub(/[.]False/, ".True", lines[i]); done = 1
                  } else if (lines[i] ~ /(assert|require)[.]True[[:space:]]*[(]/) {
                    sub(/[.]True/, ".False", lines[i]); done = 1
                  } else if (lines[i] ~ /^[[:space:]]*if[[:space:]]+.*(==|!=).*[{][[:space:]]*$/) {
                    assertion = 0
                    for (j = i + 1; j <= NR && j <= i + 5; j++) {
                      if (lines[j] ~ /[.](Error|Fatal)(f|ln)?[[:space:]]*[(]/) assertion = 1
                    }
                    if (assertion && lines[i] ~ /!=/) {
                      sub(/!=/, "==", lines[i]); done = 1
                    } else if (assertion && lines[i] ~ /==/) {
                      sub(/==/, "!=", lines[i]); done = 1
                    }
                  }
                }
                for (i = 1; i <= NR; i++) print lines[i]
                if (!done) exit 3
              }
            ' "$PROJECT_DIR/$mutation_file" > "$mutation_work/mutated"
            mutation_rc=$?
            ;;
        esac
        set -e

        if [ "$mutation_rc" -eq 0 ]; then
          mutation_target="$mutation_file"
          mutation_kind="$mutation_file_kind"
          break
        fi
      done < "$mutation_work/changed.sorted"

      if [ -z "$mutation_target" ]; then
        mutation_skip="no flippable assertion in the first 25 supported changed test files — skipped"
      fi
    fi
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    mutation_repo="$mutation_work/repo"
    mutation_head="$(git rev-parse --verify HEAD 2>/dev/null || true)"
    set +e
    run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" git clone --quiet --shared --no-checkout "$PROJECT_DIR" "$mutation_repo" >/dev/null 2>&1
    clone_rc=$?
    if [ "$clone_rc" -eq 0 ]; then
      run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" git -C "$mutation_repo" checkout --quiet --detach "$mutation_head" >/dev/null 2>&1
      checkout_rc=$?
    else
      checkout_rc="$clone_rc"
    fi
    set -e
    if [ "$clone_rc" -ne 0 ] || [ "$checkout_rc" -ne 0 ]; then
      mutation_skip="isolated clone/control setup failed or timed out — skipped"
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    mutation_cmd="$PROCESS_GATE_TEST_CMD"
    printf -v mutation_quoted_target '%q' "$mutation_target"
    case "$mutation_kind:$mutation_cmd" in
      js:"npm run test"|js:"pnpm run test"|js:"yarn run test"|js:"bun run test")
        mutation_cmd="$mutation_cmd -- $mutation_quoted_target"
        ;;
      python:*" pytest")
        mutation_cmd="$mutation_cmd $mutation_quoted_target"
        ;;
      go:"go test ./...")
        mutation_package="${mutation_target%/*}"
        if [ "$mutation_package" = "$mutation_target" ]; then
          mutation_package="."
        else
          mutation_package="./$mutation_package"
        fi
        printf -v mutation_quoted_package '%q' "$mutation_package"
        mutation_cmd="go test $mutation_quoted_package"
        ;;
    esac

    set +e
    run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" bash -c 'cd "$1" && exec bash -c "$2"' _ "$mutation_repo" "$mutation_cmd" >/dev/null 2>&1
    control_rc=$?
    set -e
    if [ "$control_rc" -ne 0 ]; then
      case "$control_rc" in
        124|142) mutation_skip="isolated control timed out after ${mutation_timeout}s — skipped" ;;
        125)     mutation_skip="no bounded timeout runner available — skipped" ;;
        *)       mutation_skip="isolated control exited $control_rc — skipped (mutation result would be ambiguous)" ;;
      esac
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    mkdir -p "$mutation_repo/$(dirname "$mutation_target")"
    cp "$mutation_work/mutated" "$mutation_repo/$mutation_target"
    set +e
    run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" bash -c 'cd "$1" && exec bash -c "$2"' _ "$mutation_repo" "$mutation_cmd" >/dev/null 2>&1
    mutant_rc=$?
    set -e
    case "$mutant_rc" in
      0)
        mutation_skip="assertion flip survived in $mutation_target"
        ;;
      124|142)
        mutation_skip="assertion flip timed out after ${mutation_timeout}s in $mutation_target — result inconclusive"
        ;;
      125)
        mutation_skip="no bounded timeout runner available — skipped"
        ;;
      *)
        mutation_result="mutation spot-check: assertion flip killed in $mutation_target"
        ;;
    esac
  fi

  if [ -n "$mutation_skip" ]; then
    findings+=("mutation spot-check: $mutation_skip")
    if [ "$worst" = "pass" ]; then worst="warn"; fi
  fi
fi

case "$worst" in
  pass)
    pg_log pass "Tests & coverage"
    [ -z "$mutation_result" ] || pg_finding "$mutation_result"
    ;;
  warn)
    pg_log warn "Tests & coverage"
    for f in ${findings[@]+"${findings[@]}"}; do pg_finding "$f"; done
    [ -z "$mutation_result" ] || pg_finding "$mutation_result"
    ;;
  fail)
    pg_log fail "Tests & coverage"
    for f in ${findings[@]+"${findings[@]}"}; do pg_finding "$f"; done
    ;;
esac

pg_exit_code "$worst"
