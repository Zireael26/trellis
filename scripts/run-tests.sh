#!/usr/bin/env bash
# Run exactly what CI runs, in one command.
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
#   --quick        run only the fast deterministic slice (shellcheck, AEO static
#                  + python, conformance, bootstrap prologues). Intended for a
#                  tight local loop, never for a gate run.
#   --scope=ci     apply the CI exclusions as well as the global ones.
#   --shard=I/N    assign stages with deterministic longest-processing-time (LPT)
#                  scheduling over scripts/tests/stage-weights.tsv. Missing stages
#                  use the documented 30-second default weight.
#                  The workflow fans these out across a matrix; locally the
#                  default 1/1 runs everything.
#   --list         print only the stage names this invocation would run, and exit 0.
#                  Concatenating the four shards' lists must reproduce the 1/1
#                  list as a set — suite-coverage.bats asserts that.
#   --plan         print the complete N-shard plan without executing it. Rows use
#                  shard<TAB>stage<TAB>weight, followed by
#                  total<TAB>SHARD<TAB>WEIGHT rows.
#
# Every stage runs even if an earlier one fails; the exit code is the number of
# failed stages, so one red suite cannot hide behind another.

set -uo pipefail

RUN_TESTS_DIR="${BASH_SOURCE[0]%/*}"
[ "$RUN_TESTS_DIR" != "${BASH_SOURCE[0]}" ] || RUN_TESTS_DIR=.
ROOT="$(CDPATH='' cd "$RUN_TESTS_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

# shellcheck source=scripts/lib/test-suites.sh
. "$ROOT/scripts/lib/test-suites.sh"

QUICK=0
LIST=0
PLAN=0
SCOPE=local
SHARD_INDEX=1
SHARD_TOTAL=1
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --list) LIST=1 ;;
    --plan) PLAN=1 ;;
    --scope=*) SCOPE="${arg#--scope=}" ;;
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
case "$SHARD_INDEX$SHARD_TOTAL" in
  *[!0-9]*|'') printf 'run-tests: --shard expects I/N\n' >&2; exit 64 ;;
esac
if [ "$SHARD_TOTAL" -lt 1 ] || [ "$SHARD_INDEX" -lt 1 ] || [ "$SHARD_INDEX" -gt "$SHARD_TOTAL" ]; then
  printf 'run-tests: --shard=%s/%s is out of range\n' "$SHARD_INDEX" "$SHARD_TOTAL" >&2
  exit 64
fi

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
  local temp_parent fence_root fence_name launcher_dir real_git real_mktemp real_python
  local static_git="$ROOT/scripts/tests/helpers/git-fence/git"
  local static_mktemp="$ROOT/scripts/tests/helpers/git-fence/mktemp"

  # Recognize generated launchers only to reject them as delegates. Their body
  # is never parsed as authority: Git and mktemp pins retain the existing
  # inherited-delegate behavior; Python is resolved only through caller PATH.
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

  # An inbound Python pin must never execute during installer admission.
  real_python="$(command -v python3 2>/dev/null || printf '')"
  case "$real_python" in /*) ;; *) real_python="" ;; esac
  if [ -z "$real_python" ] || [ ! -x "$real_python" ]; then
    printf 'run-tests: could not resolve the Python executable\n' >&2
    return 1
  fi

  # Canonical paths make aliases of either checked-in helper ineligible as a
  # delegate and freeze symlink targets before launchers are written.
  real_python="$("$real_python" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real_python")" || return 1
  real_git="$("$real_python" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real_git")" || return 1
  real_mktemp="$("$real_python" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real_mktemp")" || return 1
  static_git="$("$real_python" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$static_git")" || return 1
  static_mktemp="$("$real_python" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$static_mktemp")" || return 1
  if [ ! -x "$real_python" ]; then
    printf 'run-tests: could not resolve the Python executable\n' >&2
    return 1
  fi
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
  GIT_CONFIG_GLOBAL="$fence_root/global.gitconfig"
  GIT_CONFIG_NOSYSTEM=1
  GIT_OPTIONAL_LOCKS=0
  PATH="$launcher_dir:$PATH"
  export TRELLIS_TEST_GIT_FENCE_ROOT TRELLIS_TEST_REAL_GIT TRELLIS_TEST_REAL_MKTEMP
  export TRELLIS_TEST_REAL_PYTHON TMPDIR
  export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_OPTIONAL_LOCKS PATH

  # The argument to rm is deliberately a validated basename, never an absolute
  # path. The parent is the canonical directory in which mktemp created it.
  cleanup_test_git_fence() {
    local cleanup_name="${TRELLIS_TEST_GIT_FENCE_ROOT##*/}"
    case "$cleanup_name" in
      trellis-test-git.*)
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

aeo_static_and_python() {
  ruff format --check core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests &&
    ruff check core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests &&
    mypy core-rules/skills/aeo-gate/scripts/lib/aeo_gate &&
    python3 -m unittest discover -s core-rules/skills/aeo-gate/tests -p 'test_*.py' &&
    bash scripts/tests/aeo-gate.test.sh
}

stage "shellcheck (CI scope, severity=warning)" shellcheck_tree
stage "POSIX bootstrap prologues" bats scripts/tests/posix-bootstrap-prologue.bats
stage "AEO contract, static, and entrypoint" aeo_static_and_python
stage "conformance-check" bash scripts/conformance-check.sh

if [ "$QUICK" -eq 0 ]; then
  stage "hooks (claude + codex)" bats core-rules/hooks/tests/ core-rules/codex/hooks/tests/
  stage "skill gates" bats core-rules/skills/*/tests/
  stage "recipe routing lint" bash scripts/lint-recipe-routing.sh
  stage "Herdr panel layout" python3 core-rules/skills/herdr-foreman/tests/test_panel_layout.py

  # One stage per suite: a failure names the suite that caused it, and the exit
  # code stays an honest count of failing suites.
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    # posix-bootstrap-prologue already ran above as part of the quick slice.
    [ "$suite" = "posix-bootstrap-prologue" ] && continue
    case "$suite" in
      rollout-hooks|sync-hooks-settings|doctor|t6-phase-a-integration|detach-project|pi-attachment|release-store|setup-runbooks|attach-project|disk-janitor-apply)
        # These suites allocate all mutable fixtures per test. Keep the outer
        # four-shard bound; Bats uses two internal semaphore slots per file.
        # Disabling cross-file parallelism avoids a GNU parallel dependency.
        stage "bats scripts/tests/$suite.bats" bats --jobs 2 \
          --no-parallelize-across-files "scripts/tests/$suite.bats"
        ;;
      *) stage "bats scripts/tests/$suite.bats" bats "scripts/tests/$suite.bats" ;;
    esac
  done < <(test_suites_for "$SCOPE")
fi

build_stage_plan || exit 1

if [ "$PLAN" -eq 1 ]; then
  print_stage_plan
  exit 0
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
if [ "$FAILED" -eq 0 ]; then
  printf 'run-tests: all stages passed\n'
else
  printf 'run-tests: %s stage(s) failed:\n' "$FAILED"
  printf '  - %s\n' ${FAILED_STAGES[@]+"${FAILED_STAGES[@]}"}
fi
exit "$FAILED"
