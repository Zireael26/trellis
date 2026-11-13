#!/usr/bin/env bash
# Run exactly what CI runs, in one command (except the narrowed diagnostic).
#
# The process-gate's Tests & coverage row used to be pointed at `:` on the
# grounds that "Trellis is a configuration repository … no test runner". That
# stopped being true: .github/workflows/bats.yml runs the same stages this
# script does and .github/workflows/shellcheck.yml runs two more, so the gate
# was reporting a green row over an unrun suite — on the repository that defines
# the gate. `.claude/skills/process-gate-local/local.config.sh` now points
# PROCESS_GATE_TEST_CMD here.
#
# The `scripts/tests/` suites are ENUMERATED, never hand-listed. Both this
# script and the workflow used to name their suites one by one and both lists
# had drifted to 20 of 57 — the 37 omissions were nearly the whole portable
# fleet surface, and one of them was red at the committed tip while the gate
# reported pass. `scripts/lib/test-suites.sh` holds the one exclusion list, and
# `scripts/tests/suite-coverage.bats` fails when a suite is neither globbed nor
# excluded there.
#
# Usage: scripts/run-tests.sh [--quick] [--scope=local|ci] [--shard=I/N] [--list] [--plan]
#                              [--base=REV] [--native-stages=auto|always] [--native-cargo-only]
#   --quick        run only the fast deterministic slice (shellcheck, AEO static
#                  + python, conformance, bootstrap prologues). Intended for a
#                  tight local loop, never for a gate run.
#   --scope=ci     apply the CI exclusions as well as the global ones. Local
#                  runs off Darwin also apply the Darwin-only CI exclusions.
#   --shard=I/N    assign stages with deterministic longest-processing-time (LPT)
#                  scheduling over scripts/tests/stage-weights.tsv. Missing stages
#                  use the documented 30-second default weight.
#                  The workflow fans these out across a matrix; locally the
#                  default 1/1 runs everything.
#   --test-file=P  select an existing scripts/tests/*.bats or core hook test
#                  file (repeatable), retaining static stages, recipe lint and
#                  normal LPT/fencing.
#   --list         print only the stage names this invocation would run, and exit 0.
#                  Concatenating the four shards' lists must reproduce the 1/1
#                  list as a set — suite-coverage.bats asserts that.
#   --plan         print the complete N-shard plan without executing it. Rows use
#                  shard<TAB>stage<TAB>weight, followed by
#                  total<TAB>SHARD<TAB>WEIGHT rows.
#   --base=REV     the range base for the native-stage decision below. CI passes
#                  the PR base (or the pushed-from commit); locally the shared
#                  diff-base resolver picks it.
#   --native-stages=auto|always
#                  auto (default): the cargo stages are registered only when the
#                  change touches a native build input (test_suites_native_decision
#                  in scripts/lib/test-suites.sh; owner 2026-11-10). An unknown base
#                  runs them. A skip prints one labelled line per stage, never a
#                  silent pass. always: register them regardless.
#   --native-cargo-only
#                  run a narrowed native Cargo diagnostic, NOT a full battery.
#                  Requires TRELLIS_NATIVE_CARGO_ONLY=qualification, including
#                  for --list/--plan. Refuses --quick, --scope, --shard,
#                  --test-file, --base, --native-stages, and combined --list
#                  and --plan. Refuses the parent gate interface if PG_TESTS_BASE,
#                  PG_TESTS_HEAD, PG_TESTS_RECEIPT_FILE, or PG_PUSH_TEST_SCOPE
#                  is set (even empty). Qualifies script stage 03 only; this
#                  opt-in is not an authorization boundary.
#
# Environment:
#   TRELLIS_SLOW_TESTS=1  also run the slow tier: test cases that skip without it
#                  (today trellis-latency-bench-repeat.bats, 30 worktree
#                  attach/detach cycles). Unset in per-change gates; the weekly
#                  uncached battery (scripts/weekly-full-battery.py) sets it.
#                  It also forces --native-stages=always.
#
# Every stage runs even if an earlier one fails; the exit code is the number of
# failed stages, so one red suite cannot hide behind another.
# START and fenced provenance are JSON lines on stderr and in a timing receipt's
# .provenance.jsonl sidecar. --list/--plan never capture or write a receipt.
# Capture failures never stop the runner.
# Each run gets a private fence root holding TMPDIR, the Git config and shims,
# and TRELLIS_HOME, so a test run never reads the operator's ~/.trellis and need
# not be serialized against live Trellis operations, which keep their own lock.
# scripts/tests/test-fencing.bats enforces the TRELLIS_HOME half.
# The local wrapper binds a durable sidecar via TRELLIS_TEST_PROVENANCE_RECEIPT.

set -uo pipefail

RUN_TESTS_DIR="${BASH_SOURCE[0]%/*}"
[ "$RUN_TESTS_DIR" != "${BASH_SOURCE[0]}" ] || RUN_TESTS_DIR=.
ROOT="$(CDPATH='' cd "$RUN_TESTS_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

# Direct fixture attaches skip detached post-attach jobs: pre-push runs deferred
# checks inline when no status is recorded. The release.sh pathname bootstrap
# and the installed launcher use env -i, so this test-only switch does not cross
# those boundaries. Fixtures invoking them must wait for their own postjobs
# before teardown. attach-postjob.bats unsets the switch to exercise spawning.
export TRELLIS_ATTACH_POSTJOB=off

# START precedes ordinary argument validation, fence setup and any planner/test.
# Inventory interfaces and refused native-only admission never probe tools or
# bind a sidecar, even with inherited receipts.
CAPTURE_PROVENANCE=1
NATIVE_CARGO_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --list|--plan) CAPTURE_PROVENANCE=0 ;;
    --native-cargo-only) NATIVE_CARGO_ONLY=1 ;;
  esac
done
capture_runner_provenance() {
  local phase="$1" record='' reason='python3 not found'
  shift
  if command -v python3 >/dev/null 2>&1; then
    reason='provenance helper failed'
    record="$(python3 "$ROOT/scripts/lib/receipt_provenance.py" \
      "$ROOT" "$phase" "$PROVENANCE_RECEIPT" "$BASH" "$0" "$@" 2>/dev/null)" || record=''
  fi
  if [ -z "$record" ]; then
    # Fixed strings only: valid JSON even with no JSON-capable tool on PATH.
    record="$(printf '{"phase":"%s","provenance":"unavailable","reason":"%s"}' "$phase" "$reason")"
    if [ -n "$PROVENANCE_RECEIPT" ]; then
      if ! (umask 077; printf '%s\n' "$record" >> "$PROVENANCE_RECEIPT.provenance.jsonl") 2>/dev/null; then
        record="$(printf '{"phase":"%s","provenance":"unavailable","reason":"%s","provenance_sidecar":"unavailable: write failed"}' "$phase" "$reason")"
      fi
    fi
  fi
  printf '%s\n' "$record" >&2 || true
}
# Refuse unsafe native-only admission before even the START probe or sidecar.
# Presence of a parent gate interface, including an empty value, is enough.
if [ "$NATIVE_CARGO_ONLY" -eq 1 ]; then
  if [ "${TRELLIS_NATIVE_CARGO_ONLY:-}" != qualification ]; then
    printf 'run-tests: --native-cargo-only requires TRELLIS_NATIVE_CARGO_ONLY=qualification\n' >&2; exit 64
  fi
  if [ -n "${PG_TESTS_BASE+x}${PG_TESTS_HEAD+x}${PG_TESTS_RECEIPT_FILE+x}${PG_PUSH_TEST_SCOPE+x}" ]; then
    printf 'run-tests: --native-cargo-only refuses inherited PG_TESTS_BASE, PG_TESTS_HEAD, PG_TESTS_RECEIPT_FILE, or PG_PUSH_TEST_SCOPE\n' >&2; exit 64
  fi
  _native_list=0
  _native_plan=0
  for arg in "$@"; do
    case "$arg" in
      --quick|--scope|--scope=*|--shard|--shard=*|--test-file|--test-file=*|--base|--base=*|--native-stages|--native-stages=*)
        printf 'run-tests: --native-cargo-only refuses %s\n' "$arg" >&2; exit 64 ;;
      --list) _native_list=1 ;;
      --plan) _native_plan=1 ;;
    esac
  done
  if [ "$_native_list" -eq 1 ] && [ "$_native_plan" -eq 1 ]; then
    printf 'run-tests: --native-cargo-only refuses combined --list and --plan\n' >&2; exit 64
  fi
fi
# The qualifier is an invocation opt-in, never an input to any test stage.
unset TRELLIS_NATIVE_CARGO_ONLY
if [ "$CAPTURE_PROVENANCE" -eq 1 ]; then
  PROVENANCE_RECEIPT="${TRELLIS_TEST_PROVENANCE_RECEIPT:-${TRELLIS_TEST_TSV:-}}"
  capture_runner_provenance start "$@"
fi
# Runner-owned binding: fenced capture uses the private shell variable, not env.
unset TRELLIS_TEST_PROVENANCE_RECEIPT
unset PG_TESTS_BASE PG_TESTS_HEAD PG_TESTS_RECEIPT_FILE PG_PUSH_TEST_SCOPE

# shellcheck source=scripts/lib/test-suites.sh
if ! . "$ROOT/scripts/lib/test-suites.sh"; then
  printf 'run-tests: could not load scripts/lib/test-suites.sh\n' >&2
  exit 1
fi
# shellcheck source=scripts/lib/bats-jobs.sh
. "$ROOT/scripts/lib/bats-jobs.sh"

QUICK=0
LIST=0
PLAN=0
SCOPE=local
SHARD_INDEX=1
SHARD_TOTAL=1
SELECTED_TESTS=()
RANGE_BASE=''
NATIVE_STAGES=auto
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --list) LIST=1 ;;
    --plan) PLAN=1 ;;
    --native-cargo-only) ;;
    --test-file=*) SELECTED_TESTS+=( "${arg#--test-file=}" ) ;;
    --scope=*) SCOPE="${arg#--scope=}" ;;
    --base=*) RANGE_BASE="${arg#--base=}" ;;
    --native-stages=*) NATIVE_STAGES="${arg#--native-stages=}" ;;
    --shard=*)
      SHARD_INDEX="${arg#--shard=}"
      SHARD_TOTAL="${SHARD_INDEX#*/}"
      SHARD_INDEX="${SHARD_INDEX%%/*}"
      ;;
    *) printf 'run-tests: unknown argument: %s\n' "$arg" >&2; exit 64 ;;
  esac
done

case "$SCOPE" in
  local|ci) ;;
  *) printf 'run-tests: unknown scope: %s\n' "$SCOPE" >&2; exit 64 ;;
esac
case "$NATIVE_STAGES" in
  auto|always) ;;
  *) printf 'run-tests: unknown --native-stages: %s\n' "$NATIVE_STAGES" >&2; exit 64 ;;
esac
case "$SHARD_INDEX$SHARD_TOTAL" in
  *[!0-9]*|'') printf 'run-tests: --shard expects I/N\n' >&2; exit 64 ;;
esac
if [ "$SHARD_TOTAL" -lt 1 ] || [ "$SHARD_INDEX" -lt 1 ] || [ "$SHARD_INDEX" -gt "$SHARD_TOTAL" ]; then
  printf 'run-tests: --shard=%s/%s is out of range\n' "$SHARD_INDEX" "$SHARD_TOTAL" >&2
  exit 64
fi

# CI's excluded suites exercise Darwin-only launchd/plist boundaries. Local
# runs on other hosts use the same exclusions without changing their scope or
# native-stage policy. A fixed system uname keeps PATH shims from changing the
# plan independently of the platform bound into a reusable verdict.
SUITE_SCOPE="$SCOPE"
if [ "$SCOPE" = local ] && [ "$QUICK" -eq 0 ] && [ "$NATIVE_CARGO_ONLY" -eq 0 ]; then
  HOST_OS=''
  for _uname in /usr/bin/uname /bin/uname; do
    [ -x "$_uname" ] || continue
    HOST_OS="$("$_uname" -s)" || { printf 'run-tests: unable to identify host OS\n' >&2; exit 1; }
    break
  done
  [ -n "$HOST_OS" ] || { printf 'run-tests: unable to identify host OS\n' >&2; exit 1; }
  [ "$HOST_OS" = Darwin ] || SUITE_SCOPE=ci
fi

# Decide the cargo stages once, before the Git fence, so every shard of one run
# (same checkout, same base) registers the same plan.
NATIVE_DECISION=run
NATIVE_REASON=''
if [ "$QUICK" -eq 0 ] && [ "${#SELECTED_TESTS[@]}" -eq 0 ] && [ "$NATIVE_CARGO_ONLY" -eq 0 ]; then
  if [ "$NATIVE_STAGES" = always ]; then
    NATIVE_REASON='--native-stages=always'
  elif [ "${TRELLIS_SLOW_TESTS:-}" = 1 ]; then
    NATIVE_REASON='TRELLIS_SLOW_TESTS=1 runs every stage'
  else
    _native_line="$(test_suites_native_decision "$SCOPE" "$RANGE_BASE")"
    NATIVE_DECISION="${_native_line%%$'\t'*}"
    NATIVE_REASON="${_native_line#*$'\t'}"
    case "$NATIVE_DECISION" in
      run|skip) ;;
      *) NATIVE_DECISION=run; NATIVE_REASON="decision unreadable ($_native_line); fail closed" ;;
    esac
  fi
fi
# The labels belong to a run. --list and --plan print only the stage inventory
# (callers merge stderr into it), and a skipped stage is simply absent there.
native_note() {
  [ "$LIST" -eq 1 ] || [ "$PLAN" -eq 1 ] || printf 'run-tests: %s\n' "$1"
}

for test_file in ${SELECTED_TESTS[@]+"${SELECTED_TESTS[@]}"}; do
  if [[ ! "$test_file" =~ ^(scripts/tests|core-rules/hooks/tests|core-rules/codex/hooks/tests)/[A-Za-z0-9_-]+\.bats$ ]] ||
     [ ! -f "$test_file" ] || [ -L "$test_file" ] || [ "$QUICK" -eq 1 ]; then
    printf 'run-tests: invalid selected test: %s\n' "$test_file" >&2; exit 64
  fi
  # Never let a symlinked parent redirect an apparently in-tree selection.
  test_parent="$test_file"
  while [[ "$test_parent" == */* ]]; do
    test_parent="${test_parent%/*}"
    if [ -L "$test_parent" ]; then
      printf 'run-tests: invalid selected test: %s\n' "$test_file" >&2; exit 64
    fi
  done
  case "$test_file" in
    scripts/tests/*)
      suite="${test_file##*/}"
      excluded="$(test_suites_exclusion_scope "${suite%.bats}")"
      if [ "$excluded" = all ] || { [ "$SUITE_SCOPE" = ci ] && [ "$excluded" = ci ]; }; then
        reason="$(test_suites_exclusion_reason "${suite%.bats}")"
        printf 'run-tests: selected test excluded in %s: %s (%s)\n' "$SCOPE" "$test_file" "$reason" >&2; exit 64
      fi
      ;;
  esac
done

suite_selected() {
  local file
  [ "${#SELECTED_TESTS[@]}" -gt 0 ] || return 0
  for file in "${SELECTED_TESTS[@]}"; do
    [ "$file" != "$1" ] || return 0
  done
  return 1
}

# Git invokes hooks with repository-routing variables exported for the hook's
# checkout. They are poison for a fixture suite: `git -C "$fixture"` does NOT
# override an inherited GIT_DIR, so fixture init/config/worktree commands can
# silently mutate the repository that launched pre-push. Clear every routing
# variable before any executable test stage. Then put a test-only Git wrapper on
# PATH which refuses every mutation unless its canonical common directory (or
# init/clone/config destination) is below this shard's fresh private root.
# Clearing fixes the normal fixture path; the wrapper is the fail-loud backstop
# for a bad cd, empty path, upward discovery, or a test that reintroduces GIT_DIR.
install_test_git_fence() {
  local temp_parent fence_root fence_name launcher_dir real_git real_mktemp real_python real_python_exe
  local static_git="$ROOT/scripts/tests/helpers/git-fence/git"
  local static_mktemp="$ROOT/scripts/tests/helpers/git-fence/mktemp"

  # Recognize generated launchers only to reject them as delegates. Their body
  # is never parsed as authority: Git and mktemp pins retain the existing
  # inherited-delegate behavior; Python uses the shared interpreter resolver.
  is_generated_test_fence_launcher() {
    local candidate="$1" line count=0
    [ -f "$candidate" ] && [ -r "$candidate" ] || return 1
    while [ "$count" -lt 4 ] && IFS= read -r line; do
      [ "$line" = "# trellis-test-fence-launcher-v1" ] && return 0
      count=$((count + 1))
    done < "$candidate"
    return 1
  }

  # Resolve every executable while PATH still names the caller's toolchain.
  # In particular, never allocate the new root through an inherited wrapper.
  real_git="${TRELLIS_TEST_REAL_GIT:-}"
  [ -n "$real_git" ] || real_git="$(command -v git 2>/dev/null || printf '')"
  case "$real_git" in /*) ;; *) real_git="" ;; esac
  if [ -z "$real_git" ] || [ ! -x "$real_git" ] ||
     [ "$real_git" = "$static_git" ] || is_generated_test_fence_launcher "$real_git"; then
    printf 'run-tests: could not resolve the real Git executable\n' >&2
    return 1
  fi

  real_mktemp="${TRELLIS_TEST_REAL_MKTEMP:-}"
  [ -n "$real_mktemp" ] || real_mktemp="$(command -v mktemp 2>/dev/null || printf '')"
  case "$real_mktemp" in /*) ;; *) real_mktemp="" ;; esac
  if [ -z "$real_mktemp" ] || [ ! -x "$real_mktemp" ] ||
     [ "$real_mktemp" = "$static_mktemp" ] || is_generated_test_fence_launcher "$real_mktemp"; then
    printf 'run-tests: could not resolve the real mktemp executable\n' >&2
    return 1
  fi

  # Resolve once for the shard, including bare python3 calls from its suites.
  # The fence's separate TRELLIS_TEST_REAL_PYTHON pin is never an input.
  # shellcheck source=scripts/lib/trellis-python.sh
  . "$ROOT/scripts/lib/trellis-python.sh"
  # Admission must not read or update the caller's live interpreter cache.
  TRELLIS_HOME=/dev/null trellis_python || {
    printf 'run-tests: could not resolve the Python executable\n' >&2
    return 1
  }
  real_python="$TRELLIS_PYTHON"
  case "$real_python" in /*) ;; *) real_python="" ;; esac
  if [ -z "$real_python" ] || [ ! -x "$real_python" ]; then
    printf 'run-tests: could not resolve the Python executable\n' >&2
    return 1
  fi

  # Canonical paths make aliases of either checked-in helper ineligible as a
  # delegate and freeze symlink targets before launchers are written.
  real_python="$("$real_python" -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real_python")" || return 1
  real_git="$("$real_python" -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real_git")" || return 1
  real_mktemp="$("$real_python" -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real_mktemp")" || return 1
  static_git="$("$real_python" -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$static_git")" || return 1
  static_mktemp="$("$real_python" -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$static_mktemp")" || return 1
  # A pyenv-style python3 is a bash script: ~0.2 s per exec (every fenced Git
  # call pays it several times over) and dead on a PATH without bash, which
  # stripped-PATH hook tests construct. Pin the true binary behind the shim.
  real_python_exe="$("$real_python" -I -c 'import sys; print(sys.executable)' 2>/dev/null)" || real_python_exe=""
  if [ -n "$real_python_exe" ]; then
    real_python_exe="$("$real_python" -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real_python_exe" 2>/dev/null)" || real_python_exe=""
  fi
  if [ -n "$real_python_exe" ] && [ -f "$real_python_exe" ] && [ -x "$real_python_exe" ]; then
    real_python="$real_python_exe"
  fi
  if [ ! -x "$real_python" ]; then
    printf 'run-tests: could not resolve the Python executable\n' >&2
    return 1
  fi
  # A shim-only host still resolves through the shared fallback, but pays the
  # shim only during admission. Keep intentional non-shim override wrappers.
  case "$TRELLIS_PYTHON" in */shims/python3) TRELLIS_PYTHON="$real_python" ;; esac
  if [ ! -x "$real_git" ] || [ "$real_git" = "$static_git" ] ||
     is_generated_test_fence_launcher "$real_git"; then
    printf 'run-tests: could not resolve the real Git executable\n' >&2
    return 1
  fi
  if [ ! -x "$real_mktemp" ] || [ "$real_mktemp" = "$static_mktemp" ] ||
     is_generated_test_fence_launcher "$real_mktemp"; then
    printf 'run-tests: could not resolve the real mktemp executable\n' >&2
    return 1
  fi

  temp_parent="$(CDPATH='' cd "${TMPDIR:-/tmp}" && pwd -P)" || {
    printf 'run-tests: could not resolve the temporary directory\n' >&2
    return 1
  }
  fence_root="$("$real_mktemp" -d "$temp_parent/trellis-test-git.XXXXXX")" || {
    printf 'run-tests: could not create the Git mutation fence root\n' >&2
    return 1
  }
  fence_root="$(CDPATH='' cd "$fence_root" && pwd -P)" || return 1
  fence_name="${fence_root##*/}"
  case "$fence_name" in
    trellis-test-git.*) ;;
    *) printf 'run-tests: unsafe Git fence root name: %s\n' "$fence_root" >&2; return 1 ;;
  esac

  chmod 700 "$fence_root"
  cat > "$fence_root/global.gitconfig" <<'EOF'
[user]
  name = Trellis Test Fixture
  email = fixture@trellis.invalid
[commit]
  gpgSign = false
[tag]
  gpgSign = false
EOF
  chmod 600 "$fence_root/global.gitconfig"

  launcher_dir="$fence_root/bin"
  mkdir "$launcher_dir" || return 1
  chmod 700 "$launcher_dir"
  {
    printf '#!/bin/bash\n# trellis-test-fence-launcher-v1\n'
    printf 'TRELLIS_TEST_GIT_FENCE_ROOT=%q\n' "$fence_root"
    printf 'TRELLIS_TEST_REAL_GIT=%q\n' "$real_git"
    printf 'TRELLIS_TEST_REAL_MKTEMP=%q\n' "$real_mktemp"
    printf 'TRELLIS_TEST_REAL_PYTHON=%q\n' "$real_python"
    printf 'export TRELLIS_TEST_GIT_FENCE_ROOT TRELLIS_TEST_REAL_GIT TRELLIS_TEST_REAL_MKTEMP TRELLIS_TEST_REAL_PYTHON\n'
    printf 'exec /bin/bash %q "$@"\n' "$static_git"
  } > "$launcher_dir/git"
  {
    printf '#!/bin/bash\n# trellis-test-fence-launcher-v1\n'
    printf 'TRELLIS_TEST_GIT_FENCE_ROOT=%q\n' "$fence_root"
    printf 'TRELLIS_TEST_REAL_GIT=%q\n' "$real_git"
    printf 'TRELLIS_TEST_REAL_MKTEMP=%q\n' "$real_mktemp"
    printf 'TRELLIS_TEST_REAL_PYTHON=%q\n' "$real_python"
    printf 'export TRELLIS_TEST_GIT_FENCE_ROOT TRELLIS_TEST_REAL_GIT TRELLIS_TEST_REAL_MKTEMP TRELLIS_TEST_REAL_PYTHON\n'
    printf 'exec /bin/bash %q "$@"\n' "$static_mktemp"
  } > "$launcher_dir/mktemp"
  # A private PATH entry, not a shell function: suites that replace PATH to
  # exercise missing/shimmed Python still see exactly their chosen toolchain.
  ln -s "$TRELLIS_PYTHON" "$launcher_dir/python3" || return 1
  chmod 700 "$launcher_dir/git" "$launcher_dir/mktemp"
  if [ ! -f "$launcher_dir/git" ] || [ -L "$launcher_dir/git" ] || [ ! -x "$launcher_dir/git" ] ||
     [ ! -f "$launcher_dir/mktemp" ] || [ -L "$launcher_dir/mktemp" ] || [ ! -x "$launcher_dir/mktemp" ]; then
    printf 'run-tests: could not create private Git fence launchers\n' >&2
    return 1
  fi

  TRELLIS_TEST_GIT_FENCE_PARENT="$temp_parent"
  TRELLIS_TEST_GIT_FENCE_ROOT="$fence_root"
  TRELLIS_TEST_REAL_GIT="$real_git"
  TRELLIS_TEST_REAL_MKTEMP="$real_mktemp"
  TRELLIS_TEST_REAL_PYTHON="$real_python"
  # Bats derives BATS_RUN_TMPDIR, BATS_SUITE_TMPDIR, and BATS_TEST_TMPDIR
  # from TMPDIR. Point it at this shard's distinct fence root so every Bats
  # fixture is inside the security boundary by construction.
  TMPDIR="$fence_root"
  # Hooks resolve Trellis state as $TRELLIS_HOME, else $HOME/.trellis. Point it
  # into the fence (not created; a fresh machine has none) so no stage reads the
  # operator's live state. HOME stays: tool caches and credentials hang off it.
  TRELLIS_HOME="$fence_root/trellis-home"
  GIT_CONFIG_GLOBAL="$fence_root/global.gitconfig"
  GIT_CONFIG_NOSYSTEM=1
  GIT_OPTIONAL_LOCKS=0
  PATH="$launcher_dir:$PATH"
  export TRELLIS_TEST_GIT_FENCE_ROOT TRELLIS_TEST_REAL_GIT TRELLIS_TEST_REAL_MKTEMP
  export TRELLIS_TEST_REAL_PYTHON TMPDIR TRELLIS_HOME
  export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_OPTIONAL_LOCKS PATH

  # The argument to rm is deliberately a validated basename, never an absolute
  # path. The parent is the canonical directory in which mktemp created it.
  cleanup_test_git_fence() {
    local cleanup_name="${TRELLIS_TEST_GIT_FENCE_ROOT##*/}"
    case "$cleanup_name" in
      trellis-test-git.*)
        if [ -d "$TRELLIS_TEST_GIT_FENCE_ROOT/historical-releases" ]; then
          find "$TRELLIS_TEST_GIT_FENCE_ROOT/historical-releases" -type d -exec chmod u+w {} +
        fi
        (CDPATH='' cd "$TRELLIS_TEST_GIT_FENCE_PARENT" && rm -rf -- "$cleanup_name")
        ;;
    esac
  }
  trap cleanup_test_git_fence EXIT
}

if [ "$LIST" -eq 0 ] && [ "$PLAN" -eq 0 ]; then
  # These variables are documented by `git rev-parse --local-env-vars` and by
  # Git's hook contract. Keep the list explicit and mirrored in check-tests.sh.
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
  install_test_git_fence || exit 1
  # Freeze the effective fenced toolchain before planning or running a stage.
  capture_runner_provenance fenced "$@"

  # These suites require caller-owned evidence roots outside the source tree.
  # Bind defaults inside this shard's fresh Git fence, after installation so
  # --list and --plan stay side-effect-free. Explicit diagnostic bindings win.
  TRELLIS_CONFORMANCE_TEST_ROOT="${TRELLIS_CONFORMANCE_TEST_ROOT:-$TMPDIR/harness-conformance-evidence}"
  TRELLIS_T9_TEST_ROOT="${TRELLIS_T9_TEST_ROOT:-$TMPDIR/skill-eval-pi-evidence}"
  # The packer tests use an unmodified, licensed upstream fixture by default;
  # a diagnostic may still exercise an explicitly selected installed version.
  AGGREGATE_SCRIPT="${AGGREGATE_SCRIPT:-$ROOT/scripts/tests/fixtures/skill-eval-v2/aggregate_benchmark.py}"
  export TRELLIS_CONFORMANCE_TEST_ROOT TRELLIS_T9_TEST_ROOT AGGREGATE_SCRIPT

  # A direct run must never rewrite the checked-in stage weights table at
  # scripts/tests/stage-weights.tsv. Callers that need a durable receipt can
  # provide TRELLIS_TEST_TSV; otherwise keep this run's receipt private in the
  # system temporary directory.
  if [ -z "${TRELLIS_TEST_TSV:-}" ]; then
    TRELLIS_TEST_TSV="$(mktemp "${TMPDIR:-/tmp}/trellis-run-tests.XXXXXX")" || {
      printf 'run-tests: could not create a private timing receipt\n' >&2
      exit 1
    }
  fi
  mkdir -p "$(dirname "$TRELLIS_TEST_TSV")"
  # Timing receipt schema: ordinal<TAB>stage<TAB>elapsed_seconds<TAB>exit.
  printf 'ordinal\tstage\telapsed_seconds\texit\n' > "$TRELLIS_TEST_TSV"
  # Stages (including nested runners) must not inherit this runner's receipt.
  export -n TRELLIS_TEST_TSV
fi

FAILED=0
RAN=0
SKIPPED=0
FAILED_STAGES=()
STAGE_ORDINAL=0
STAGE_NAMES=()
STAGE_ARG_OFFSETS=()
STAGE_ARG_COUNTS=()
STAGE_ARGS=()
STAGE_ARG_TOTAL=0
STAGE_ASSIGNMENTS=()
STAGE_WEIGHTS=()
SHARD_WEIGHTS=()

# Stages absent from the checked-in (or TRELLIS_STAGE_WEIGHTS_TSV) table use
# this default so a new registration cannot break sharding.
DEFAULT_STAGE_WEIGHT=30
STAGE_WEIGHTS_TSV="${TRELLIS_STAGE_WEIGHTS_TSV:-$ROOT/scripts/tests/stage-weights.tsv}"

# Registration records the command vector without evaluating it. Keeping each
# argument in an array, with an offset and count per stage, avoids eval and
# preserves empty arguments and arguments containing shell metacharacters.
stage() {
  local name="$1"
  shift
  STAGE_ORDINAL=$((STAGE_ORDINAL + 1))
  STAGE_NAMES[$STAGE_ORDINAL]="$name"
  STAGE_ARG_OFFSETS[$STAGE_ORDINAL]="$STAGE_ARG_TOTAL"
  STAGE_ARG_COUNTS[$STAGE_ORDINAL]="$#"
  STAGE_ARGS+=( "$@" )
  STAGE_ARG_TOTAL=$((STAGE_ARG_TOTAL + $#))
}

# Build the deterministic LPT assignment in awk. The first input is the
# stage<TAB>seconds table; stdin carries the ordered registered stage names.
build_stage_plan() {
  local _plan_output _plan_ordinal _plan_shard _plan_weight _plan_index

  if [ ! -r "$STAGE_WEIGHTS_TSV" ]; then
    printf 'run-tests: stage weight table is not readable: %s\n' \
      "$STAGE_WEIGHTS_TSV" >&2
    return 1
  fi

  _plan_output="$(
    for ((_plan_index = 1; _plan_index <= STAGE_ORDINAL; _plan_index++)); do
      printf '%s\n' "${STAGE_NAMES[$_plan_index]}"
    done |
      awk -F '\t' \
        -v default_weight="$DEFAULT_STAGE_WEIGHT" \
        -v shard_count="$SHARD_TOTAL" \
        -v weights_file="$STAGE_WEIGHTS_TSV" '
        BEGIN { OFS = "\t" }
        FILENAME == weights_file {
          if (FNR > 1 && NF >= 2 && $1 != "") {
            table_weight[$1] = $2
          }
          next
        }
        {
          ordinal = FNR
          if ($0 in table_weight) {
            weight_text[ordinal] = table_weight[$0]
            weight_value[ordinal] = table_weight[$0] + 0
          } else {
            weight_text[ordinal] = default_weight
            weight_value[ordinal] = default_weight + 0
          }
          stage_count = ordinal
        }
        END {
          for (ordinal = 1; ordinal <= stage_count; ordinal++) {
            order[ordinal] = ordinal
          }

          # Selection sort keeps the tie-breaker explicit: original ordinal.
          for (position = 1; position <= stage_count; position++) {
            best_position = position
            for (candidate = position + 1; candidate <= stage_count; candidate++) {
              if (weight_value[order[candidate]] > weight_value[order[best_position]] || (weight_value[order[candidate]] == weight_value[order[best_position]] && order[candidate] < order[best_position])) {
                best_position = candidate
              }
            }
            temp = order[position]
            order[position] = order[best_position]
            order[best_position] = temp
          }

          for (shard = 1; shard <= shard_count; shard++) {
            total[shard] = 0
          }
          for (position = 1; position <= stage_count; position++) {
            ordinal = order[position]
            selected_shard = 1
            for (candidate = 2; candidate <= shard_count; candidate++) {
              # Strictly lower preserves the lower-numbered shard on ties.
              if (total[candidate] < total[selected_shard]) {
                selected_shard = candidate
              }
            }
            assigned[ordinal] = selected_shard
            total[selected_shard] += weight_value[ordinal]
          }

          # Emit stage rows in registration order, not assignment order.
          for (ordinal = 1; ordinal <= stage_count; ordinal++) {
            print ordinal, assigned[ordinal], weight_text[ordinal]
          }
          for (shard = 1; shard <= shard_count; shard++) {
            print "total", shard, total[shard] + 0
          }
        }
      ' "$STAGE_WEIGHTS_TSV" -
  )" || {
    printf 'run-tests: could not build stage plan from %s\n' \
      "$STAGE_WEIGHTS_TSV" >&2
    return 1
  }

  while IFS=$'\t' read -r _plan_ordinal _plan_shard _plan_weight; do
    [ -n "$_plan_ordinal" ] || continue
    if [ "$_plan_ordinal" = "total" ]; then
      SHARD_WEIGHTS[$_plan_shard]="$_plan_weight"
    else
      STAGE_ASSIGNMENTS[$_plan_ordinal]="$_plan_shard"
      STAGE_WEIGHTS[$_plan_ordinal]="$_plan_weight"
    fi
  done <<< "$_plan_output"
}

run_registered_stage() {
  local ordinal="$1"
  local name="${STAGE_NAMES[$ordinal]}"
  local arg_offset="${STAGE_ARG_OFFSETS[$ordinal]}"
  local arg_count="${STAGE_ARG_COUNTS[$ordinal]}"
  local _stage_start _stage_ec

  if [ "${STAGE_ASSIGNMENTS[$ordinal]}" -ne "$SHARD_INDEX" ]; then
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  RAN=$((RAN + 1))
  if [ "$LIST" -eq 1 ]; then
    printf '%s\n' "$name"
    return 0
  fi

  printf '\n=== %s ===\n' "$name"
  _stage_start=$SECONDS
  _stage_ec=0
  "${STAGE_ARGS[@]:$arg_offset:$arg_count}" || _stage_ec=$?
  printf '%s\t%s\t%s\t%s\n' "$ordinal" "$name" \
    "$((SECONDS - _stage_start))" "$_stage_ec" >> "$TRELLIS_TEST_TSV"
  if [ "$_stage_ec" -eq 0 ]; then
    printf '>>> %s: ok\n' "$name"
  else
    printf '>>> %s: FAILED (exit %s)\n' "$name" "$_stage_ec"
    FAILED=$((FAILED + 1))
    FAILED_STAGES+=("$name")
  fi
}

print_stage_plan() {
  local _plan_index _plan_shard
  printf 'shard\tstage\tweight\n'
  for ((_plan_index = 1; _plan_index <= STAGE_ORDINAL; _plan_index++)); do
    printf '%s\t%s\t%s\n' \
      "${STAGE_ASSIGNMENTS[$_plan_index]}" \
      "${STAGE_NAMES[$_plan_index]}" \
      "${STAGE_WEIGHTS[$_plan_index]}"
  done
  for ((_plan_shard = 1; _plan_shard <= SHARD_TOTAL; _plan_shard++)); do
    printf 'total\t%s\t%s\n' "$_plan_shard" "${SHARD_WEIGHTS[$_plan_shard]}"
  done
}

# Enumeration lives in scripts/lint-shell-tree.sh, shared with
# .github/workflows/shellcheck.yml. Both used to carry their own suffix-only
# `find`, which left every extensionless script — the pre-push hooks and the
# `trellis` entrypoint among them — unlinted in either place.
shellcheck_tree() {
  bash scripts/lint-shell-tree.sh
}

# Ruff is pinned on the command line (spec 058): `--isolated` ignores every
# config file and `--select` fixes the rule set, because the default set differs
# between binaries — 0.16.7 finds 35 errors here that 0.15.5 (CI's pin) does
# not. The `ruff:` line records which binary the receipt used; it never fails
# the stage, and a missing ruff still fails the next command.
aeo_static_and_python() {
  local _ruff_bin _ruff_ver
  if _ruff_bin="$(command -v ruff)" && _ruff_ver="$(ruff --version 2>/dev/null)"; then
    printf 'ruff: %s %s\n' "$_ruff_bin" "$_ruff_ver" || true
  else
    printf 'ruff: unavailable\n' || true
  fi
  ruff format --isolated --check core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests &&
    ruff check --isolated --select E4,E7,E9,F core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests &&
    mypy core-rules/skills/aeo-gate/scripts/lib/aeo_gate &&
    python3 -m unittest discover -s core-rules/skills/aeo-gate/tests -p 'test_*.py' &&
    bash scripts/tests/aeo-gate.test.sh
}

# Load only when an actual native stage executes: --list/--plan and quick
# fixtures need no Cargo inputs or test-helper side effects.
NATIVE_CARGO_STAGE_PREPARED=0
native_cargo_stage() {
  # shellcheck source=scripts/tests/helpers/native-cargo.bash
  . "$ROOT/scripts/tests/helpers/native-cargo.bash" || return 1
  native_cargo_run "$@"
}

if [ "$NATIVE_CARGO_ONLY" -eq 1 ]; then
  stage "cargo test native/trellis-hooks (native-only)" native_cargo_stage +1.97.1 test --locked --offline \
    --manifest-path "$ROOT/native/trellis-hooks/Cargo.toml"
else
  stage "shellcheck (CI scope, severity=warning)" shellcheck_tree
  stage "POSIX bootstrap prologues" bats scripts/tests/posix-bootstrap-prologue.bats
  stage "AEO contract, static, and entrypoint" aeo_static_and_python
  stage "conformance-check" bash scripts/conformance-check.sh
fi

if [ "$QUICK" -eq 0 ] && [ "$NATIVE_CARGO_ONLY" -eq 0 ]; then
  # HC_* must not reach the hook suites: code-reviewer.sh takes the rung-2a
  # (`pi`) branch inside an hc terminal, so every rung-2b assertion fails against
  # the operator's live roles-resolved.json when the gate is launched from the
  # Herdr app (run-tests-local.py spawns shards with os.environ.copy()). Scrubbed
  # here so it holds for every suite in the stage, including the files that do
  # not `load helpers`. Suites that need hc set it per-invocation.
  core_hook_suites="$(test_suites_core hooks)" || { printf 'run-tests: could not enumerate core hook suites\n' >&2; exit 1; }
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    suite_selected "$suite" || continue
    stage "bats $suite" env -u HC_SCOPE -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET \
      bats "$suite"
  done <<< "$core_hook_suites"
fi

if [ "$QUICK" -eq 0 ] && [ "${#SELECTED_TESTS[@]}" -eq 0 ] && [ "$NATIVE_CARGO_ONLY" -eq 0 ]; then
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    stage "bats $suite" bats "$suite"
  done < <(test_suites_core skills)

  # Native contract/event/proof/supervision targets and the local Pi suites.
  # They are separate files and separate stages for the same reason the bats
  # files are: a failure names its target, and the LPT planner can spread them.
  # The cargo stages are scoped to native build-input changes (see
  # --native-stages); a skipped one is unregistered, so it costs no shard time,
  # and is named on a labelled line instead.
  native_stage() {
    if [ "$NATIVE_DECISION" = skip ]; then
      native_note "skipped stage '$1': $NATIVE_REASON"
      return 0
    fi
    stage "$@"
  }
  native_note "native cargo stages: $NATIVE_DECISION ($NATIVE_REASON)"
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    target="${suite##*/}"
    target="${target%.rs}"
    native_stage "cargo test $suite" native_cargo_stage +1.97.1 test --locked --offline \
      --manifest-path "$ROOT/native/trellis-hooks/Cargo.toml" --test "$target"
  done < <(test_suites_native)
  # The crate's own #[cfg(test)] modules (lib and bin). `--test <stem>` above
  # never compiles them, so without this stage they ran nowhere.
  native_stage "cargo unit-tests native/trellis-hooks (lib + bins)" native_cargo_stage +1.97.1 test --locked \
    --offline --manifest-path "$ROOT/native/trellis-hooks/Cargo.toml" --lib --bins
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    stage "node --test $suite" node --test --test-reporter=tap "$suite"
  done < <(test_suites_pi)

fi

if [ "$QUICK" -eq 0 ] && [ "$NATIVE_CARGO_ONLY" -eq 0 ]; then
  stage "recipe routing lint" bash scripts/lint-recipe-routing.sh
  # Full local runs off Darwin label each host exclusion from the shared CI
  # list. Narrow selections validate their files above, so do not imply other
  # suites were selected; inventory interfaces suppress labels via native_note.
  if [ "$SCOPE" = local ] && [ "$SUITE_SCOPE" = ci ] && [ "${#SELECTED_TESTS[@]}" -eq 0 ]; then
    while IFS= read -r suite; do
      [ "$(test_suites_exclusion_scope "$suite")" = ci ] || continue
      native_note "skipped stage 'bats scripts/tests/$suite.bats': $(test_suites_exclusion_reason "$suite")"
    done < <(test_suites_all)
  fi
  # One stage per suite: a failure names the suite that caused it, and the exit
  # code stays an honest count of failing suites.
  script_suites="$(test_suites_for "$SUITE_SCOPE")" || { printf 'run-tests: could not enumerate test suites\n' >&2; exit 1; }
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    # posix-bootstrap-prologue already ran above as part of the quick slice.
    [ "$suite" = "posix-bootstrap-prologue" ] && continue
    suite_selected "scripts/tests/$suite.bats" || continue
    case "$suite" in
      rollout-hooks-part*|sync-hooks-settings-part*|doctor-part*|t6-phase-a-integration|detach-project-part*|pi-attachment|release-store-part*|setup-runbooks|attach-project|disk-janitor-apply)
        # These suites allocate all mutable fixtures per test. Keep the outer
        # four-shard bound; Bats uses two internal semaphore slots per file.
        # Disabling cross-file parallelism avoids a GNU parallel dependency.
        # bats_jobs_file reruns a file serially after the bats-core wait race (scripts/lib/bats-jobs.sh).
        stage "bats scripts/tests/$suite.bats" bats_jobs_file "scripts/tests/$suite.bats"
        ;;
      *) stage "bats scripts/tests/$suite.bats" bats "scripts/tests/$suite.bats" ;;
    esac
  done <<< "$script_suites"
fi

# A narrowed run must not succeed if discovery omitted or duplicated any
# selected test. The bootstrap prologue has its historical fixed stage name.
for test_file in ${SELECTED_TESTS[@]+"${SELECTED_TESTS[@]}"}; do
  expected_stage="bats $test_file"
  [ "$test_file" != scripts/tests/posix-bootstrap-prologue.bats ] || expected_stage='POSIX bootstrap prologues'
  matches=0
  for ((index=1; index<=STAGE_ORDINAL; index++)); do
    [ "${STAGE_NAMES[$index]}" != "$expected_stage" ] || matches=$((matches + 1))
  done
  if [ "$matches" -ne 1 ]; then
    printf 'run-tests: selected test registered %s times: %s\n' "$matches" "$test_file" >&2; exit 1
  fi
done

build_stage_plan || exit 1

if [ "$PLAN" -eq 1 ]; then
  print_stage_plan
  exit 0
fi

# Only the historical group-plan part consumes this fixture. Do not build it
# for quick, inventory-only, or unrelated shards. Never trust an inbound cache.
unset TRELLIS_TEST_HISTORICAL_RELEASES
if [ "$LIST" -eq 0 ]; then
  for ((STAGE_INDEX = 1; STAGE_INDEX <= STAGE_ORDINAL; STAGE_INDEX++)); do
    if [ "${STAGE_ASSIGNMENTS[$STAGE_INDEX]}" -eq "$SHARD_INDEX" ] &&
      [ "${STAGE_NAMES[$STAGE_INDEX]}" = 'bats scripts/tests/release-store-part1.bats' ]; then
      REPO_ROOT="$ROOT"
      RELEASE_STORE_LIB="$ROOT/scripts/lib/release-store.sh"
      # shellcheck source=scripts/tests/helpers/payload-fixture.bash
      . "$ROOT/scripts/tests/helpers/payload-fixture.bash"
      # shellcheck source=scripts/tests/helpers/group-plan.bash
      . "$ROOT/scripts/tests/helpers/group-plan.bash"
      # shellcheck source=scripts/tests/helpers/historical-releases.bash
      . "$ROOT/scripts/tests/helpers/historical-releases.bash"
      historical_releases_prepare "$TRELLIS_TEST_GIT_FENCE_ROOT" || exit 1
      break
    fi
  done
fi

for ((STAGE_INDEX = 1; STAGE_INDEX <= STAGE_ORDINAL; STAGE_INDEX++)); do
  run_registered_stage "$STAGE_INDEX"
done

if [ "$LIST" -eq 1 ]; then
  exit 0
fi

printf '\n===============================\n'
printf 'run-tests: receipt=%s\n' "$TRELLIS_TEST_TSV"
printf 'run-tests: scope=%s shard=%s/%s stages ran=%s skipped=%s\n' \
  "$SCOPE" "$SHARD_INDEX" "$SHARD_TOTAL" "$RAN" "$SKIPPED"
if [ "$NATIVE_CARGO_ONLY" -eq 1 ]; then
  printf 'run-tests: native-cargo-only: narrowed diagnostic, NOT A FULL BATTERY\n'
elif [ "$QUICK" -eq 0 ] && [ "${#SELECTED_TESTS[@]}" -eq 0 ]; then
  printf 'run-tests: native cargo stages: %s (%s)\n' "$NATIVE_DECISION" "$NATIVE_REASON"
fi
if [ "$FAILED" -eq 0 ]; then
  if [ "$NATIVE_CARGO_ONLY" -eq 1 ]; then
    printf 'run-tests: narrowed native-only stage passed (NOT A FULL BATTERY)\n'
  else
    printf 'run-tests: all stages passed\n'
  fi
else
  printf 'run-tests: %s stage(s) failed:\n' "$FAILED"
  printf '  - %s\n' ${FAILED_STAGES[@]+"${FAILED_STAGES[@]}"}
fi
exit "$FAILED"
