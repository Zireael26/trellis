#!/usr/bin/env bash
# Process-table liveness checks shared by process-gate coordination and the
# disk-janitor build guard. Executable identity comes from `ucomm`; flattened
# argv is secondary context only, never identity by itself and never a kill list.
# Gate script paths with whitespace lose their argv boundaries in ps output:
# a primary path and a different script given that path as an argument can look
# identical. Reconstructed candidates return ERROR unless the primary token is
# an existing regular file (relative paths are resolved in the process cwd).
# Shell -c and Python -c/-m payloads are excluded before reconstruction.
#
# Exit codes:
#   0  CLEAR: the snapshot is valid and no matching process is live
#   1  BUSY: one or more verified process groups are live
#   2  ERROR: usage, probe failure or ambiguous identity (callers must fail closed)

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

snapshot="$(LC_ALL=C ps -ww -eo pid=,ppid=,pgid=,ucomm=,args= 2>/dev/null)"
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
  # Node names its Linux main thread: MainThread in 24, node-MainThread in 26.
  return name == "node" || name == "MainThread" || name == "node-MainThread" || name == "nodejs" || name == "bun" || name == "deno"
}
function is_bundler(name) {
  return name ~ /^(next|vite|turbo|webpack|webpack-cli|tsc|astro|esbuild|rollup|tsup|parcel|rspack|nuxt)([.](js|mjs|cjs|cmd))?$/
}
function primary_index(kind, start,    i, j, token, uncertain) {
  for (i = start; i <= NF; i++) {
    token = $i
    if (token == "--") {
      if (kind == "runtime" && uncertain)
        for (j = i + 1; j <= NF; j++) if (is_bundler(base_name($j))) return j
      return i < NF ? i + 1 : 0
    }
    if (kind == "shell" && token ~ /^-[^-]*c/) return -1
    if (kind == "python" && (token == "-c" || token == "-m" || token == "-")) return -1
    if (kind == "runtime" && (token == "-e" || token == "--eval" || token == "-p" || token == "--print")) return -1
    if (token == "-O" || token == "--rcfile" || token == "--init-file" ||
        token == "-W" || token == "-X" || token == "--require" ||
        (kind == "runtime" && (token == "-r" || token == "--import" ||
         token == "--loader" || token == "--experimental-loader" ||
         token == "--title" || token == "--watch-path" || token == "--inspect-port" ||
         token == "--conditions" || token == "--disable-warning" ||
         token == "--unhandled-rejections" || token == "--dns-result-order" ||
         token == "-C" || token == "--env-file"))) {
      i++
      continue
    }
    if (token ~ /^-/) {
      # Unknown options may take a separate value. An equals-form is already
      # self-contained; otherwise do not let a possible value hide a bundler.
      if (kind == "runtime" && token !~ /=/) uncertain = 1
      continue
    }
    if (kind == "runtime" && uncertain)
      for (j = i; j <= NF; j++) if (is_bundler(base_name($j))) return j
    return i
  }
  return 0
}
function has_bats_path(start,    i) {
  for (i = start; i <= NF; i++) if ($i ~ /[.]bats$/) return 1
  return 0
}
function gate_script(kind, path, start,    program) {
  program = base_name(path)
  if (kind == "python") return program == "run-tests-local.py" ? program : ""
  if (program == "run-all.sh" || program == "run-tests.sh" || program == "trellis-doctor") return program
  if (program ~ /[.]bats$/) return "bats"
  if ((program == "bats" || program ~ /^bats-/) && has_bats_path(start)) return "bats"
  return ""
}
# Explicit non-build table. Unknown commands, defaults, serve and watch are
# busy: a mistaken busy result skips this janitor scan, not a live build guard.
function non_build_action(program, start,    i, token) {
  sub(/[.](js|mjs|cjs|cmd)$/, "", program)
  for (i = start; i <= NF; i++) {
    token = $i
    if (token == "--help" || token == "-h" || token == "--version") return 1
    if (token == "-v" && program ~ /^(next|vite|webpack|webpack-cli|tsc)$/) return 1
    if (program == "tsc" && (token == "--noEmit=true" ||
        (token == "--noEmit" && $(i + 1) != "false"))) return 1
  }
  return 0
}
BEGIN {
  valid = 0
  found = 0
  ambiguous = 0
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
    } else if (is_shell(comm) || is_python(comm)) {
      kind = is_shell(comm) ? "shell" : "python"
      pos = primary_index(kind, 6)
      if (pos > 0) {
        candidate = $(pos)
        target = gate_script(kind, candidate, pos + 1)
        if (target == "") {
          # Only extend from the primary script position, never from a -c/-m
          # payload. ps cannot prove which spaces belong to the script path.
          for (i = pos + 1; i <= NF; i++) {
            candidate = candidate " " $i
            if (gate_script(kind, candidate, i + 1) != "") {
              printf "ERROR\tpid=%s\tpgid=%s\tcomm=%s\tambiguous interpreter script path\t%s\n", $1, $3, comm, $(pos)
              ambiguous = 1
              break
            }
          }
        }
      }
    }
  } else if (mode == "build") {
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
    if (pos > 0 && is_bundler(program) && !non_build_action(program, pos + 1)) {
      if (index(args, project) > 0) target = program
      else {
        printf "CWD\tpid=%s\tppid=%s\tpgid=%s\tcomm=%s\ttarget=%s\n", $1, $2, $3, comm, program
        needs_cwd = 1
      }
    }
  }

  if (target != "" && !seen[$3]++) {
    printf "BUSY\tpid=%s\tppid=%s\tpgid=%s\tcomm=%s\ttarget=%s\n", $1, $2, $3, comm, target
    found = 1
  }
}
END {
  if (valid == 0) exit 3
  if (ambiguous) exit 4
  if (needs_cwd) exit 5
  if (found) exit 1
  exit 0
}
')"
awk_status=$?

# ps loses argv boundaries, but an existing primary script rules out extending
# that token into a whitespace-bearing path. Never resolve relative to our cwd.
primary_is_file() {
  local pid="$1" primary="$2" cwd field
  case "$primary" in
    /*) [ -f "$primary" ]; return ;;
  esac
  case "$(uname -s)" in
    Linux) [ -f "/proc/$pid/cwd/$primary" ] ;;
    Darwin)
      cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null)" || return 1
      while IFS= read -r field; do
        case "$field" in
          n*) [ -f "${field#n}/$primary" ]; return ;;
        esac
      done <<< "$cwd"
      return 1
      ;;
    *) return 1 ;;
  esac
}

# A bundler invocation without the project path in argv may use a global,
# cached, symlinked or relative program. Resolve its live cwd; an unreadable
# cwd is uncertain, never evidence of idleness.
process_cwd() {
  local pid="$1" field cwd
  case "$(uname -s)" in
    Linux) (CDPATH='' cd -P "/proc/$pid/cwd" && pwd -P) ;;
    Darwin)
      cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null)" || return 1
      while IFS= read -r field; do
        case "$field" in
          n*) (CDPATH='' cd -P "${field#n}" && pwd -P); return ;;
        esac
      done <<< "$cwd"
      return 1 ;;
    *) return 1 ;;
  esac
}

if [ "$awk_status" -eq 5 ]; then
  project_cwd="$(CDPATH='' cd -P "$project" 2>/dev/null && pwd -P)" || project_cwd=""
  evidence=""
  awk_status=0
  while IFS=$'\t' read -r record pid ppid pgid comm target; do
    case "$record" in
      BUSY)
        [ "$awk_status" -eq 4 ] || awk_status=1
        evidence+="${record}"$'\t'"${pid}"$'\t'"${ppid}"$'\t'"${pgid}"$'\t'"${comm}"$'\t'"${target}"$'\n'
        ;;
      CWD)
        cwd=""
        if [ -z "$project_cwd" ]; then
          awk_status=4
          evidence+="ERROR"$'\t'"${pid}"$'\t'"${pgid}"$'\t'"${comm}"$'\t'"${target}"$'\t'"cwd=<not-probed>"$'\t'"project=${project}"$'\t'"project cwd unavailable"$'\n'
        elif ! cwd="$(process_cwd "${pid#pid=}")"; then
          awk_status=4
          evidence+="ERROR"$'\t'"${pid}"$'\t'"${pgid}"$'\t'"${comm}"$'\t'"${target}"$'\t'"cwd=<unavailable>"$'\t'"project=${project}"$'\t'"build process cwd unavailable"$'\n'
        else
          case "$cwd" in
            "$project_cwd"|"$project_cwd"/*)
              [ "$awk_status" -eq 4 ] || awk_status=1
              evidence+="BUSY"$'\t'"${pid}"$'\t'"${ppid}"$'\t'"${pgid}"$'\t'"${comm}"$'\t'"${target}"$'\n'
              ;;
          esac
        fi
        ;;
    esac
  done <<< "$result"
  result="${evidence%$'\n'}"
fi

if [ "$awk_status" -eq 4 ] && [ "$mode" = gate ]; then
  evidence=""
  awk_status=0
  while IFS=$'\t' read -r record pid pgid comm detail primary; do
    if [ "$record" = ERROR ]; then
      primary_is_file "${pid#pid=}" "$primary" && continue
      awk_status=4
      evidence+="${record}"$'\t'"${pid}"$'\t'"${pgid}"$'\t'"${comm}"$'\t'"${detail}"$'\n'
    else
      # Preserve verified BUSY rows even when every ambiguous row was cleared.
      [ "$awk_status" -eq 4 ] || awk_status=1
      evidence+="${record}"$'\t'"${pid}"$'\t'"${pgid}"$'\t'"${comm}"$'\t'"${detail}"$'\t'"${primary}"$'\n'
    fi
  done <<< "$result"
  result="${evidence%$'\n'}"
fi

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
  4)
    printf '%s\n' "$result" >&2
    exit 2
    ;;
  *)
    printf 'ERROR malformed process-table snapshot\n' >&2
    exit 2
    ;;
esac
