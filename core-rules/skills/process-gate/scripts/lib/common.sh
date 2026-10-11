#!/usr/bin/env bash
# Shared helpers for process-gate validators.
# Sourced by every check-*.sh script. Do not run directly.

set -euo pipefail

# Colors — only when stdout is a TTY.
if [ -t 1 ]; then
  PG_RED=$'\033[31m'; PG_YEL=$'\033[33m'; PG_GRN=$'\033[32m'
  PG_DIM=$'\033[2m'; PG_RST=$'\033[0m'
else
  PG_RED=""; PG_YEL=""; PG_GRN=""; PG_DIM=""; PG_RST=""
fi

# pg_log <level> <msg>   level ∈ pass|warn|fail|info
pg_log() {
  local lvl="$1"; shift
  case "$lvl" in
    pass) printf "%spass%s %s\n" "$PG_GRN" "$PG_RST" "$*" ;;
    warn) printf "%swarn%s %s\n" "$PG_YEL" "$PG_RST" "$*" ;;
    fail) printf "%sfail%s %s\n" "$PG_RED" "$PG_RST" "$*" ;;
    info) printf "%sinfo%s %s\n" "$PG_DIM" "$PG_RST" "$*" ;;
    *)    printf "%s\n" "$*" ;;
  esac
}

# pg_finding <file>:<line>: <msg>
pg_finding() {
  printf "  %s\n" "$*"
}

# Resolve project root. Harness env wins; PWD is the portable fallback.
pg_project_dir() {
  if [ -n "${CODEX_PROJECT_DIR:-}" ] && [ -d "$CODEX_PROJECT_DIR" ]; then
    printf "%s" "$CODEX_PROJECT_DIR"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    printf "%s" "$CLAUDE_PROJECT_DIR"
  elif [ -n "${PWD:-}" ] && [ -d "$PWD" ]; then
    git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || printf "%s" "$PWD"
  else
    git rev-parse --show-toplevel 2>/dev/null
  fi
}

# Drop shell functions that could stand in for the tools the gate relies on
# (exported BASH_FUNC_* imports; local config is data and defines none),
# including those on run-all's approval and validator paths.
pg_unshadow() {
  unset -f git gh bash env cat grep sed awk tr mktemp rm mkdir dirname wc jq \
    python3 perl chmod 2>/dev/null || true
}

# pg_range_base <dir> <range> -> full SHA the range is judged against: the left
# side of a..b, the merge-base of a...b, else the revision itself. An empty
# side means HEAD, as in git. Non-zero when it does not resolve.
pg_range_base() {
  local dir="$1" range="$2" left right
  case "$range" in
    *...*)
      left="${range%%...*}"; right="${range#*...}"
      git -C "$dir" merge-base "${left:-HEAD}" "${right:-HEAD}" 2>/dev/null
      ;;
    *..*)
      left="${range%%..*}"
      git -C "$dir" rev-parse --verify --quiet "${left:-HEAD}^{commit}" 2>/dev/null
      ;;
    *)
      git -C "$dir" rev-parse --verify --quiet "${range}^{commit}" 2>/dev/null
      ;;
  esac
}

# pg_range_head <dir> <range> -> full SHA of the range's end: the right side
# of a..b / a...b (HEAD when empty), or a single-rev range's own revision.
pg_range_head() {
  local dir="$1" range="$2" right=""
  case "$range" in
    *..*) right="${range##*..}" ;;
    *) right="$range" ;;
  esac
  git -C "$dir" rev-parse --verify --quiet "${right:-HEAD}^{commit}" 2>/dev/null
}

# NUL-framed git output: every pathname record is non-empty, so the reader
# treats the first EMPTY record as the end of data and the record after it as
# the command's exit status (written by `printf '\0%s\0' "$?"`). No filename
# can be mistaken for the status.

# pg_base_entry <dir> <commit> <path>: what <path> (relative to <dir>, taken
# literally) is at <commit> — rc 0 a regular-file blob, 1 absent, 3 a tree,
# 2 anything else (symlink, submodule) or a failed lookup. ls-tree output is
# NUL-delimited, so any filename compares exactly.
pg_base_entry() {
  local rec status=1 rc="" ended=0
  while IFS= read -r -d '' rec; do
    if [ "$ended" -eq 1 ]; then rc="$rec"; continue; fi
    if [ -z "$rec" ]; then ended=1; continue; fi
    [ "${rec#*$'\t'}" = "$3" ] || continue
    case "$rec" in
      "100644 blob "*|"100755 blob "*) status=0 ;;
      "040000 tree "*) status=3 ;;
      *) status=2 ;;
    esac
  done < <(git -C "$1" --literal-pathspecs ls-tree -z "$2" -- "$3" 2>/dev/null; printf '\0%s\0' "$?")
  [ "$rc" = 0 ] || return 2
  return "$status"
}

# pg_base_path <dir> <commit> <path>: pg_base_entry for <path> after walking
# its ancestors in the BASE tree, never the working tree. Every ancestor must
# be a tree: one that is absent makes the path absent (rc 1); a symlink,
# submodule or file on the way, or a failed lookup, is unsupported (rc 2).
# Otherwise the leaf's own rc: 0 regular blob, 1 absent, 3 tree, 2 other.
pg_base_path() {
  local prefix="" part rest="$3" rc
  while :; do
    case "$rest" in
      */*) part="${rest%%/*}"; rest="${rest#*/}" ;;
      *) break ;;
    esac
    prefix="${prefix:+$prefix/}$part"
    rc=0
    pg_base_entry "$1" "$2" "$prefix" || rc=$?
    case "$rc" in
      3) ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  done
  pg_base_entry "$1" "$2" "$3"
}

# pg_config_token: consume one data token from the front of $rest into $tok —
# a double-quoted string, a single-quoted string or a bare word. Quoted text
# carries no $, backtick, ; or (double-quoted) backslash; a bare word is plain
# path/flag characters. Works on the caller's $rest/$tok (dynamic scope).
pg_config_token() {
  local re_dq='^"([^"$`;\\]*)"(.*)$'
  local re_sq="^'([^'\$\`;]*)'(.*)\$"
  local re_bare='^([A-Za-z0-9_./:@%+,=-]+)(.*)$'
  if [[ "$rest" =~ $re_dq ]] || [[ "$rest" =~ $re_sq ]] || [[ "$rest" =~ $re_bare ]]; then
    tok="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# pg_apply_config_data <label>: parse local.config.sh text on stdin as DATA and
# apply it. Accepted lines: blank, `# comment`, `PROCESS_GATE_X=<token>`,
# `PROCESS_GATE_X="${PROCESS_GATE_X:-<literal>}"` (an inherited value wins, as
# it did when the file was sourced), and arrays `PROCESS_GATE_X=( <token>... )`
# on one line or several. A trailing ` # comment` is allowed. Anything else is
# refused. Values are assigned with printf -v / indexed read (empty items are
# kept): nothing is evaluated.
pg_apply_config_data() {
  local label="$1" line n=0 name="" value rest tok array_name="" idx=0
  local re_array='^(PROCESS_GATE_[A-Z0-9_]+)=\((.*)$'
  local re_scalar='^(PROCESS_GATE_[A-Z0-9_]+)=(.*)$'
  local re_default='^"\$\{(PROCESS_GATE_[A-Z0-9_]+):-([^"$`;\\}]*)\}"(.*)$'
  local re_tail='^([[:space:]]+#.*)?[[:space:]]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    if [ -z "$array_name" ]; then
      case "$line" in ''|'#'*) continue ;; esac
      if [[ "$line" =~ $re_array ]]; then
        array_name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; idx=0
        unset -v "$array_name"
      elif [[ "$line" =~ $re_scalar ]]; then
        name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; value=""
        if [[ "$rest" =~ $re_default ]] && [ "${BASH_REMATCH[1]}" = "$name" ]; then
          value="${!name-}"
          [ -n "$value" ] || value="${BASH_REMATCH[2]}"
          rest="${BASH_REMATCH[3]}"
        elif [ -n "$rest" ] && [[ ! "$rest" =~ $re_tail ]]; then
          pg_config_token || { pg_config_not_data "$label" "$n" "$line"; return 1; }
          value="$tok"
        fi
        [[ "$rest" =~ $re_tail ]] || { pg_config_not_data "$label" "$n" "$line"; return 1; }
        printf -v "$name" '%s' "$value"
        continue
      else
        pg_config_not_data "$label" "$n" "$line"
        return 1
      fi
    else
      rest="$line"
    fi
    # Array items until the closing parenthesis.
    while :; do
      rest="${rest#"${rest%%[![:space:]]*}"}"
      case "$rest" in
        ''|'#'*) break ;;
        ')'*)
          rest="${rest#)}"
          [[ "$rest" =~ $re_tail ]] || { pg_config_not_data "$label" "$n" "$line"; return 1; }
          array_name=""
          break
          ;;
      esac
      pg_config_token || { pg_config_not_data "$label" "$n" "$line"; return 1; }
      case "$rest" in
        ''|[[:space:]]*|')'*)
          IFS= read -r "${array_name?}[$idx]" <<< "$tok"
          idx=$((idx + 1))
          ;;
        *) pg_config_not_data "$label" "$n" "$line"; return 1 ;;
      esac
    done
  done
  if [ -n "$array_name" ]; then
    pg_config_not_data "$label" "$n" "unterminated array $array_name"
    return 1
  fi
}

pg_config_not_data() {
  pg_config_fail "process-gate local config is not data: $1:$2: $3"
}

# pg_config_fail <reason>: record why config did not load (PG_CONFIG_ERROR, for
# callers that render their own verdict) and print it as a fail line.
pg_config_fail() {
  # shellcheck disable=SC2034  # read by run-all.sh
  PG_CONFIG_ERROR="$1"
  pg_log fail "$1"
}

# pg_load_config [--range=<gitspec>] [--mode=...]: load project-local config
# from the range BASE, never the working tree, so a range cannot change the
# config it is gated with. The base is the left side of the gate's range
# (merge-base for a...b); without --range the default range applies. The file
# is parsed as data (pg_apply_config_data). Precedence is unchanged: both
# harness twins load (the active harness's last, so it wins); the deprecated
# .claude/skills/process-gate/local.config.sh only when neither exists. Sets
# PG_CONFIG_BASE. Non-zero, with the reason printed and in PG_CONFIG_ERROR,
# when the base does not resolve, a config is present but not a regular file
# (symlink, tree, a failed lookup), any ancestor of a config location in the
# base tree is a symlink, submodule or file, or a config is not data: callers
# fail closed, never fall back to defaults or to the deprecated location.
pg_load_config() {
  local pdir range rel dir content rc loaded=0
  local rels=(
    ".agents/skills/process-gate-local/local.config.sh"
    ".claude/skills/process-gate-local/local.config.sh"
  )
  pg_unshadow
  pdir="$(pg_project_dir)" || pdir=""
  if [ -z "$pdir" ]; then
    pg_config_fail "process-gate cannot resolve the project directory; local config not loaded"
    return 1
  fi
  range="$(pg_parse_range "$@")" || return 1
  PG_CONFIG_BASE="$(pg_range_base "$pdir" "$range")" || PG_CONFIG_BASE=""
  if [ -z "$PG_CONFIG_BASE" ]; then
    pg_config_fail "process-gate cannot resolve the base of range $range; local config not loaded"
    return 1
  fi

  if [ -n "${CODEX_PROJECT_DIR:-}" ]; then
    rels=(
      ".claude/skills/process-gate-local/local.config.sh"
      ".agents/skills/process-gate-local/local.config.sh"
    )
  fi
  # Deprecated Phase-B location retained for older projects until their next rollout.
  rels+=(".claude/skills/process-gate/local.config.sh")

  for dir in .agents/skills/process-gate-local .claude/skills/process-gate-local; do
    rc=0
    pg_base_path "$pdir" "$PG_CONFIG_BASE" "$dir" || rc=$?
    case "$rc" in
      1|3) ;;
      *)
        pg_config_fail "process-gate local config dir $dir at range base $PG_CONFIG_BASE is not a directory, or is reached through a symlink (or could not be read)"
        return 1
        ;;
    esac
  done
  for rel in "${rels[@]}"; do
    if [ "$rel" = .claude/skills/process-gate/local.config.sh ] && [ "$loaded" -eq 1 ]; then
      break
    fi
    rc=0
    pg_base_path "$pdir" "$PG_CONFIG_BASE" "$rel" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *)
        pg_config_fail "process-gate local config $rel at range base $PG_CONFIG_BASE is not a regular file, or is reached through a symlink (or could not be read)"
        return 1
        ;;
    esac
    if ! content="$(git -C "$pdir" show "$PG_CONFIG_BASE:./$rel")"; then
      pg_config_fail "process-gate cannot read $rel at range base $PG_CONFIG_BASE"
      return 1
    fi
    pg_apply_config_data "$rel" <<< "$content" || return 1
    loaded=1
  done
  pg_unshadow
}

# Parse --range=<spec> / --base=<ref> from "$@" -> echo the gitspec.
# An explicit --range is echoed verbatim, without consulting git (R1). Otherwise
# the shared resolver (diff-base.sh, spec 067) picks the base: --base=<ref> is
# merge-base resolved, and with neither flag the resolver's tiers decide. The
# result is <base_sha>..<head_sha>, or the D1 superset fallback below; there is
# no HEAD~1..HEAD fallback. Nothing resolvable prints the reason on stderr and
# returns 1, which aborts a direct check-*.sh run under set -e.
pg_parse_range() {
  local range=""
  for arg in "$@"; do
    case "$arg" in
      --range=*) range="${arg#--range=}" ;;
    esac
  done
  if [ -n "$range" ]; then
    printf "%s" "$range"
    return 0
  fi
  pg_resolve_diff_base "$@" || { printf '%s\n' "$DB_REASON" >&2; return 1; }
  printf "%s" "$DB_RANGE"
}

# pg_resolve_diff_base "$@": run the shared resolver in the caller's shell on
# the --range= / --base= flags in "$@", setting DB_* (db_receipt prints the
# receipt line). No mode is passed: run-all.sh owns the merge-mode refusal.
# Coordinator ruling D1 (1.3.12-a): when neither flag is given and the resolver
# cannot derive a base, keep 1.3.11's superset fallback only: local main, else
# master (1.3.11's order), whose two-dot range gates every commit not on that
# branch. It is receipted "via fallback", never as a resolved base. 1.3.11's
# last resort, HEAD~1..HEAD, under-gates a multi-commit push (R31), so with
# neither branch this refuses. A refused --range/--base never falls back, nor
# does a template.branch that names no branch.
pg_resolve_diff_base() {
  local arg flagged=false
  local -a flags=()
  for arg in "$@"; do
    case "$arg" in
      --range=*|--base=*) flags+=("$arg"); flagged=true ;;
    esac
  done
  # shellcheck source=diff-base.sh
  . "${BASH_SOURCE[0]%/*}/diff-base.sh"
  db_resolve ${flags[@]+"${flags[@]}"} && return 0
  case "$DB_REASON" in template.branch*) return 1 ;; esac
  if [ "$flagged" = true ] || ! git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
    return 1
  fi
  if git rev-parse --verify main >/dev/null 2>&1; then
    DB_RANGE="main..HEAD"
  elif git rev-parse --verify master >/dev/null 2>&1; then
    DB_RANGE="master..HEAD"
  else
    DB_REASON="$DB_REASON; no local main or master to fall back to"
    return 1
  fi
  DB_BASE_REF="${DB_RANGE%..HEAD}"
  # Public resolver outputs consumed by db_receipt and check-tests.sh.
  # shellcheck disable=SC2034
  DB_BASE_SHA="$(git rev-parse --verify -q "$DB_BASE_REF^{commit}")"
  # Public resolver output, as above.
  # shellcheck disable=SC2034
  DB_HEAD_SHA="$(git rev-parse --verify -q 'HEAD^{commit}')"
  # Public resolver output, as above.
  # shellcheck disable=SC2034
  DB_SOURCE="fallback"
  DB_REASON="no derivable base; D1 fallback gates every commit not on $DB_BASE_REF"
}

# Parse --mode=<push|merge> from "$@" -> echo the mode.
# Defaults to "merge" (the fail-closed / strict choice) when not provided or
# when the value is anything other than the literal "push". A parse miss MUST
# land in the strict mode, never the lenient one.
pg_parse_mode() {
  local mode=""
  for arg in "$@"; do
    case "$arg" in
      --mode=*) mode="${arg#--mode=}" ;;
    esac
  done
  case "$mode" in
    push) printf "push" ;;
    *)    printf "merge" ;;
  esac
}

# pg_diff_files <range> -> emit changed files in range
pg_diff_files() {
  local range="$1"
  git diff --name-only --diff-filter=ACMR "$range" 2>/dev/null
}

# Lockfile / generated detection. Echoes 1 if the path is excluded for size purposes.
pg_is_lockfile() {
  case "$1" in
    *pnpm-lock.yaml|*package-lock.json|*yarn.lock|*Cargo.lock|*go.sum|*poetry.lock|*uv.lock|*Pipfile.lock|*Gemfile.lock|*composer.lock) return 0 ;;
    *) return 1 ;;
  esac
}

# pg_resolve_pm [project_dir]
#   Echoes the resolved JS package manager (pnpm|npm|bun|yarn) for a project,
#   or empty when no JS lockfile is present (lets Python/Go detection proceed).
#   Mirror of core-rules/hooks/lib/pm.sh:trellis_resolve_pm — kept in sync by
#   hand (Trellis avoids incidental cross-subsystem coupling). Policy precedence
#   is canonical project .trellis.json, then the DEPRECATED read-only
#   .trellis.config.json (retained past v1.0.0-rc.25 only for held legacy
#   checkouts), then the immutable runtime
#   $TRELLIS_ROOT/trellis.config.json. "auto"/unset uses
#   lockfile detection; an explicit supported manager wins. A malformed,
#   non-object, or present invalid policy source suppresses lower-priority
#   policy before falling through to lockfile detection.
pg_resolve_pm() {
  local dir="${1:-$(pg_project_dir)}" pm="" cand policy_seen=0
  local config_paths=("$dir/.trellis.json" "$dir/.trellis.config.json")
  if [ -n "${TRELLIS_ROOT:-}" ]; then
    config_paths+=("$TRELLIS_ROOT/trellis.config.json")
  fi
  if command -v jq >/dev/null 2>&1; then
    for cand in "${config_paths[@]}"; do
      [ -f "$cand" ] || continue
      if ! jq -e 'type == "object"' "$cand" >/dev/null 2>&1; then
        policy_seen=1
      elif jq -e 'has("package_manager")' "$cand" >/dev/null 2>&1; then
        policy_seen=1
        pm="$(jq -r 'if (.package_manager | type) == "string" then .package_manager else empty end' "$cand" 2>/dev/null)"
      fi
      [ "$policy_seen" -eq 1 ] && break
    done
  fi
  # A present unsupported, empty, null, or invalid value suppresses lower
  # policy sources, then falls through to detection. Never emit an untrusted
  # package-manager string into callers that evaluate command names.
  case "$pm" in
    auto|"") pm="" ;;
    pnpm|npm|bun|yarn) ;;
    *) pm="" ;;
  esac
  if [ -z "$pm" ]; then
    if   [ -f "$dir/pnpm-lock.yaml" ];                       then pm=pnpm
    elif [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ];  then pm=bun
    elif [ -f "$dir/yarn.lock" ];                            then pm=yarn
    elif [ -f "$dir/package-lock.json" ];                    then pm=npm
    fi
  fi
  printf '%s' "$pm"
}

# Read-only authority check shared by check-bypass (--local) and pre-push
# (local AND effective config). Doctor requires one literal local value.
# Keep the shell-escaped restore command identical.
pg_check_managed_hooks_path() {
  local root="$1" managed="$2" scope="${3:-}" current label=local
  # Preserve trailing empty values: command substitution alone strips them.
  current="$(git -C "$root" config --local --get-all core.hooksPath 2>/dev/null || true; printf '.')"
  current="${current%.}"
  if [[ "$managed" = /* ]] && [ "$current" = "$managed"$'\n' ]; then
    [ "$scope" != --local ] || return 0
    label=effective
    current="$(git -C "$root" config --get core.hooksPath 2>/dev/null || true)"
    [ "$current" != "$managed" ] || return 0
  else
    current="${current%$'\n'}"
  fi
  printf 'core.hooksPath: %s path does not match owner-recorded managed dispatcher (value: %s) — restore with: git config --replace-all core.hooksPath %q\n' \
    "$label" "${current:-<unset>}" "$managed"
  if [ "$scope" != --local ] &&
     [ "$(git -C "$root" config --bool --get extensions.worktreeConfig 2>/dev/null || true)" = true ] &&
     git -C "$root" config --worktree --get core.hooksPath >/dev/null 2>&1; then
    printf 'core.hooksPath: clear worktree override with: git config --worktree --unset core.hooksPath\n'
  fi
  return 1
}

# pg_exit_code <pass|warn|fail> -> 0|2|1 (warn=2 to differentiate)
pg_exit_code() {
  case "$1" in
    pass) return 0 ;;
    warn) return 2 ;;
    fail) return 1 ;;
    *)    return 1 ;;
  esac
}
