#!/usr/bin/env bash
# Process-table liveness checks shared by process-gate coordination and the
# disk-janitor build guard. Executable identity comes from `comm`; flattened
# argv is secondary context only, never identity by itself and never a kill list.
#
# Exit codes:
#   0  CLEAR: the snapshot is valid and no matching process is live
#   1  BUSY: one or more verified process groups are live
#   2  ERROR: usage or process-table probe failure (callers must fail closed)

set -u

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/check-process-liveness.sh --gate
  scripts/check-process-liveness.sh --build PROJECT_PATH
USAGE
  exit 2
}

mode="${1:-}"
project=""
case "$mode" in
  --gate)
    [ "$#" -eq 1 ] || usage
    mode=gate
    ;;
  --build)
    [ "$#" -eq 2 ] || usage
    project="$2"
    [ -n "$project" ] || usage
    mode=build
    ;;
  *) usage ;;
esac

if ! command -v ps >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
  printf 'ERROR process-table tools unavailable\n' >&2
  exit 2
fi

snapshot="$(LC_ALL=C ps -ww -eo pid=,ppid=,pgid=,comm=,args= 2>/dev/null)"
ps_status=$?
if [ "$ps_status" -ne 0 ] || [ -z "$snapshot" ]; then
  printf 'ERROR process-table snapshot unavailable\n' >&2
  exit 2
fi

result="$(printf '%s\n' "$snapshot" | LC_ALL=C awk -v mode="$mode" -v project="$project" '
function base_name(value) {
  sub(/^.*\//, "", value)
  return value
}
function is_shell(name) {
  return name == "bash" || name == "sh" || name == "zsh"
}
function is_python(name) {
  return name == "Python" || name == "python" || name ~ /^python[0-9]+([.][0-9]+)*$/
}
function is_js_runtime(name) {
  return name == "node" || name == "nodejs" || name == "bun" || name == "deno"
}
function is_bundler(name) {
  return name ~ /^(next|vite|turbo|webpack|webpack-cli|tsc)([.](js|mjs|cjs|cmd))?$/
}
function primary_index(kind, start,    i, token) {
  for (i = start; i <= NF; i++) {
    token = $i
    if (token == "--") return i < NF ? i + 1 : 0
    if (kind == "shell" && token ~ /^-[^-]*c/) return -1
    if (kind == "python" && (token == "-c" || token == "-m" || token == "-")) return -1
    if (kind == "runtime" && (token == "-e" || token == "--eval" || token == "-p" || token == "--print")) return -1
    if (token == "-O" || token == "--rcfile" || token == "--init-file" ||
        token == "-W" || token == "-X" || token == "--require") {
      i++
      continue
    }
    if (token ~ /^-/) continue
    return i
  }
  return 0
}
function has_bats_path(start,    i) {
  for (i = start; i <= NF; i++) if ($i ~ /[.]bats$/) return 1
  return 0
}
function has_build_action(start,    i, token) {
  for (i = start; i <= NF; i++) {
    token = $i
    if (token == "dev" || token == "build" || token == "--build" || token == "-b") return 1
  }
  return 0
}
BEGIN {
  valid = 0
  found = 0
}
$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && NF >= 5 {
  valid++
  comm = base_name($4)
  args = $5
  for (i = 6; i <= NF; i++) args = args " " $i
  target = ""

  if (mode == "gate") {
    if (comm == "run-all.sh" || comm == "run-tests.sh" || comm == "run-tests-local.py" || comm == "trellis-doctor") {
      target = comm
    } else if (comm == "bats" || comm ~ /^bats-/) {
      if (has_bats_path(5)) target = "bats"
    } else if (is_shell(comm)) {
      pos = primary_index("shell", 6)
      if (pos > 0) {
        program = base_name($(pos))
        if (program == "run-all.sh" || program == "run-tests.sh" || program == "trellis-doctor") {
          target = program
        } else if (program ~ /[.]bats$/) {
          target = "bats"
        } else if ((program == "bats" || program ~ /^bats-/) && has_bats_path(pos + 1)) {
          target = "bats"
        }
      }
    } else if (is_python(comm)) {
      pos = primary_index("python", 6)
      if (pos > 0 && base_name($(pos)) == "run-tests-local.py") target = "run-tests-local.py"
    }
  } else if (mode == "build" && index(args, project) > 0) {
    pos = 0
    program = ""
    if (is_bundler(comm)) {
      program = comm
      pos = 5
    } else if (is_js_runtime(comm)) {
      pos = primary_index("runtime", 6)
      if (pos > 0) {
        program = base_name($(pos))
        if ((program == "x" || program == "bunx") && pos < NF) {
          pos++
          program = base_name($(pos))
        }
      }
    }
    if (pos > 0 && is_bundler(program) && has_build_action(pos + 1)) target = program
  }

  if (target != "" && !seen[$3]++) {
    printf "BUSY\tpid=%s\tppid=%s\tpgid=%s\tcomm=%s\ttarget=%s\n", $1, $2, $3, comm, target
    found = 1
  }
}
END {
  if (valid == 0) exit 3
  if (found) exit 1
  exit 0
}
')"
awk_status=$?

case "$awk_status" in
  0)
    if [ "$mode" = gate ]; then
      printf 'CLEAR no process-gate or Bats process detected\n'
    else
      printf 'CLEAR no build process detected for %s\n' "$project"
    fi
    exit 0
    ;;
  1)
    [ -n "$result" ] || {
      printf 'ERROR process-table matcher returned no evidence\n' >&2
      exit 2
    }
    printf '%s\n' "$result"
    exit 1
    ;;
  *)
    printf 'ERROR malformed process-table snapshot\n' >&2
    exit 2
    ;;
esac
