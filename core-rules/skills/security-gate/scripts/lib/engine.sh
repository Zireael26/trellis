#!/usr/bin/env bash
# Engine resolution the scanned tree cannot steer. Sourced (not run) by
# run-diff.sh and lib/osv.sh, after each has dropped inherited shell functions.
#
# `type -P` alone trusts PATH as inherited: a relative entry resolves against
# the cwd, and a caller's PATH may already hold a directory inside the project
# (`.tools`, `node_modules/.bin`) where the range can commit a fake scanner.
#
#   sg_path_sanitize [<project-dir>]  rebuild PATH from absolute, existing
#       entries only, and drop every entry whose physical path is inside the
#       project. Without a project dir only the relative/empty entries go.
#   sg_resolve_engine <name> <project-dir>  print its checked absolute path.
#       rc 1: not on PATH. rc 3: a path component or script interpreter is
#       inside the project, or its execution chain cannot be established.
#   sg_resolve_python <project-dir>  print the real python3 binary to run
#       directly with -I. rc 1: none on PATH. rc 3: it, or what it runs, is
#       inside the project, is a script, or cannot be established.
#
# Symlinks are followed with the system readlink at a fixed path, never one
# found on PATH: a PATH readlink could vouch for the very link it is asked
# about. No system readlink means no symlinked engine can be verified.
SG_READLINK=""
for _sg_rl in /usr/bin/readlink /bin/readlink; do
  if [ -x "$_sg_rl" ]; then SG_READLINK="$_sg_rl"; break; fi
done
builtin unset _sg_rl

sg_physical_dir() {
  (builtin cd -P "$1" 2>/dev/null && builtin pwd -P)
}

# Discover the checkout without first executing a git that the as-yet-unknown
# checkout could supply. Git worktrees and submodules use a .git file; normal
# checkouts use a directory. With no marker, retain the old cwd fallback.
sg_project_from_cwd() {
  local dir next
  dir="$(builtin pwd -P)" || return 1
  while :; do
    if [ -e "$dir/.git" ] || [ -L "$dir/.git" ]; then
      builtin printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" != / ] || break
    next="${dir%/*}"
    dir="${next:-/}"
  done
  builtin pwd -P
}

# sg_inside <path> <dir>: <path> or one of its ancestors is <dir> itself, by
# filesystem identity (test -ef: device and inode), never by spelling. On a
# case-insensitive volume ProjectRoot and projectroot are one directory, and
# Bash's cd -P/pwd -P keep whichever spelling they were given.
# A relative <path> is taken from the cwd, so the walk always ends: every
# step of an absolute path drops its last component, and a step that cannot
# (at /) ends it. There is no depth cap: a cap would call a path nested
# deeper than it "outside", trusting it.
sg_inside() {
  local p="$1" next
  [ -n "$p" ] && [ -e "$2" ] || return 1
  case "$p" in /*) ;; *) p="$(builtin pwd)/$p" ;; esac
  while :; do
    if [ "$p" -ef "$2" ]; then return 0; fi
    next="${p%/*}"
    [ -n "$next" ] || next=/
    [ "$next" != "$p" ] || return 1
    p="$next"
  done
}

sg_path_sanitize() {
  local root="" entry phys kept=""
  local -a entries=()
  if [ -n "${1:-}" ]; then
    root="$(sg_physical_dir "$1")" || return 1
  fi
  IFS=: builtin read -r -a entries <<<"$PATH"
  for entry in ${entries[@]+"${entries[@]}"}; do
    case "$entry" in /*) ;; *) continue ;; esac
    phys="$(sg_physical_dir "$entry")" || continue
    if [ -n "$root" ] && sg_inside "$phys" "$1"; then continue; fi
    kept="${kept:+$kept:}$entry"
  done
  PATH="$kept"
}

# sg_realpath <absolute-path>: follow every symlink, then canonicalize the dir.
sg_realpath() {
  local p="$1" link dir n=0
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    [ -n "$SG_READLINK" ] || return 1
    link="$("$SG_READLINK" "$p")" || return 1
    case "$link" in /*) p="$link" ;; *) p="${p%/*}/$link" ;; esac
  done
  dir="$(sg_physical_dir "${p%/*}")" || return 1
  builtin printf '%s/%s\n' "$dir" "${p##*/}"
}

# Walk *each* component and symlink, not just the final realpath. A link
# outside the checkout may bounce through a project-controlled link and back
# out again; accepting only the final target would trust that intermediate
# component. The only external reader used here is the fixed system readlink.
sg_checked_path() {
  local pending="$1" root="$2" current=/ part rest candidate target links=0
  [ -d "$root" ] || return 3
  case "$pending" in /*) pending="${pending#/}" ;; *) pending="${PWD#/}/$pending" ;; esac
  while [ -n "$pending" ]; do
    part="${pending%%/*}"
    if [ "$part" = "$pending" ]; then rest=""; else rest="${pending#*/}"; fi
    pending="$rest"
    case "$part" in
      ''|.) continue ;;
      ..) current="${current%/*}"; [ -n "$current" ] || current=/; continue ;;
    esac
    candidate="${current%/}/$part"
    if sg_inside "$candidate" "$root"; then return 3; fi
    if [ -L "$candidate" ]; then
      links=$((links + 1))
      [ "$links" -le 40 ] && [ -n "$SG_READLINK" ] || return 3
      # If the scanned root itself contains the system reader, there is no
      # trusted primitive with which to follow a link.
      sg_inside "$SG_READLINK" "$root" && return 3
      target="$("$SG_READLINK" "$candidate")" || return 3
      [ -n "$target" ] || return 3
      case "$target" in /*) current=/; target="${target#/}" ;; esac
      pending="$target${pending:+/$pending}"
    else
      [ -e "$candidate" ] || return 3
      current="$candidate"
    fi
  done
  builtin printf '%s\n' "$current"
}

# Check executable scripts as well as their interpreters. In particular env's
# interpreter is discovered only on a project-sanitized PATH. The actual
# interpreter must be native: a script shim can be outside the project yet
# choose a project-owned executable from the cwd or inherited environment.
# Reject ambiguous env options/assignments and scripts without a shebang:
# Bash otherwise runs executable text after ENOEXEC. A depth bound rejects cycles.
sg_checked_program() {
  local path="$1" root="$2" depth="${3:-0}" real magic first interpreter env_program i
  local -a words=()
  [ "$depth" -lt 16 ] || return 3
  real="$(sg_checked_path "$path" "$root")" || return 3
  [ -f "$real" ] && [ -x "$real" ] || return 3
  [ -x /usr/bin/od ] || return 3
  sg_inside /usr/bin/od "$root" && return 3
  magic="$(/usr/bin/od -An -tx1 -N4 "$real" 2>/dev/null)" || return 3
  magic="${magic//[[:space:]]/}"
  case "$magic" in
    7f454c46|cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) ;;
    2321*)
      IFS= builtin read -r first < "$real" || [ -n "$first" ] || return 3
      first="${first#\#!}"
      IFS=$' \t' builtin read -r -a words <<< "$first"
      [ "${#words[@]}" -gt 0 ] || return 3
      interpreter="${words[0]}"
      case "$interpreter" in /*) ;; *) return 3 ;; esac
      interpreter="$(sg_checked_path "$interpreter" "$root")" || return 3
      if { [ -e /usr/bin/env ] && [ "$interpreter" -ef /usr/bin/env ]; } \
         || { [ -e /bin/env ] && [ "$interpreter" -ef /bin/env ]; }; then
        sg_checked_program "$interpreter" "$root" $((depth + 1)) >/dev/null || return 3
        i=1
        if [ "${words[$i]:-}" = -S ]; then i=$((i + 1)); fi
        if [ "${words[$i]:-}" = -- ]; then i=$((i + 1)); fi
        env_program="${words[$i]:-}"
        case "$env_program" in ''|-*|*=*|*\\*|*\'*|*\"*) return 3 ;; esac
        case "$env_program" in
          /*) interpreter="$env_program" ;;
          */*) return 3 ;;
          *) interpreter="$(sg_path_sanitize "$root" && builtin type -P "$env_program")" || return 3 ;;
        esac
      fi
      interpreter="$(sg_checked_program "$interpreter" "$root" $((depth + 1)))" || return 3
      magic="$(/usr/bin/od -An -tx1 -N4 "$interpreter" 2>/dev/null)" || return 3
      case "${magic//[[:space:]]/}" in
        7f454c46|cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) ;;
        *) return 3 ;;
      esac
      ;;
    *) return 3 ;;
  esac
  builtin printf '%s\n' "$real"
}

sg_resolve_engine() {
  local bin real
  bin="$(builtin type -P "$1")" || return 1
  [ -n "$bin" ] || return 1
  if ! real="$(sg_checked_program "$bin" "$2")"; then
    builtin printf 'security-gate: refusing %s at %s: unsafe path or interpreter for project %s\n' "$1" "$bin" "$2" >&2
    return 3
  fi
  # Preserve the checked entry's argv[0] (some multi-call binaries use it),
  # while requiring an absolute path. The checked links must stay stable for
  # the run, the same filesystem assumption made by sg_resolve_python.
  case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac
  builtin printf '%s\n' "$bin"
}

# Pin each bare helper to its checked path. Missing optional helpers retain
# their normal command-not-found behavior; an unsafe helper is never run.
sg_vet_helpers() {
  local root="$1" name path rc
  shift
  for name in "$@"; do
    rc=0
    path="$(sg_resolve_engine "$name" "$root")" || rc=$?
    [ "$rc" -ne 3 ] || return 3
    [ "$rc" -ne 0 ] || builtin hash -p "$path" "$name"
  done
}

# Read baseline's shared local configuration as data, never as shell. The
# accepted literal/default grammar matches the diff gate's pinned parser; the
# allowlist includes the documented shared keys even when only diff uses one.
sg_parse_local_config() {
  local line key val raw tail default n=0 whitespace=$' \t\r\n\v\f'
  # Literal shell patterns preserve C grammar without changing Bash's locale.
  SG_CONFIG_BAD_LINE=0
  while IFS= builtin read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[!$whitespace]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    SG_CONFIG_BAD_LINE="$n"
    case "$line" in *=*) ;; *) return 1 ;; esac
    key=${line%%=*} val=${line#*=}
    case "$key" in
      SECURITY_GATE_STACK_PROFILE|SECURITY_GATE_PROJECT_NAME|SECURITY_GATE_AUDIT_DIR|\
      SECURITY_GATE_SEMGREP_TIMEOUT|SECURITY_GATE_SHELLCHECK|SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS|\
      SECURITY_GATE_GARAK_TARGET|SECURITY_GATE_GARAK_PROBES|SECURITY_GATE_GARAK_TIMEOUT|\
      SECURITY_GATE_LLM_TIMEOUT_S|SECURITY_GATE_STACK_VALIDATORS|LLM_PROVIDER|LLM_MODEL) ;;
      *) return 1 ;;
    esac
    default=false
    case "$val" in
      '"'*)
        val=${val#'"'}
        case "$val" in *'"'*) tail=${val#*'"'}; val=${val%%'"'*} ;; *) return 1 ;; esac
        case "$val" in
          '${'*':-'*'}')
            raw=${val#'${'}; raw=${raw%%':-'*}
            [ "$raw" = "$key" ] || return 1
            val=${val#*':-'}; val=${val%'}'}
            case "$val" in *'}'*) return 1 ;; esac
            default=true ;;
        esac
        case "$val" in *'$'*|*'`'*|*'\'*|*'"'*) return 1 ;; esac ;;
      "'"*)
        val=${val#"'"}
        case "$val" in *"'"*) tail=${val#*"'"}; val=${val%%"'"*} ;; *) return 1 ;; esac ;;
      *)
        raw=$val; val=${val%%[$whitespace]*}; tail=${raw#"$val"}
        case "$val" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:,@+%=-]*) return 1 ;; esac ;;
    esac
    case "$tail" in
      '') ;;
      [$whitespace]*) tail=${tail#"${tail%%[!$whitespace]*}"}; case "$tail" in ''|'#'*) ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
    if [ "$default" = false ] || [ -z "${!key:-}" ]; then
      builtin printf -v "$key" '%s' "$val"
    fi
    builtin export "${key?}"
  done < "$1"
  # shellcheck disable=SC2034  # consumed by the calling baseline
  SG_CONFIG_BAD_LINE=0
}

# A python3 found on PATH may be a shim (pyenv's is `#!/usr/bin/env bash`)
# that picks what it runs from state the checkout or the caller's environment
# can set: the cwd's .python-version, PYENV_VERSION, PYENV_HOOK_PATH, PATH.
# Ask it once which binary it runs, from /, under `env -i` with only a
# sanitized PATH, HOME and LANG=C, running the file its path resolves to (the
# one just checked), not the lexical path whose links could change. Then
# vouch for the answer and run that binary directly, never the shim: a
# regular native executable (ELF or Mach-O, so no script or text Bash would
# interpret) outside the project by filesystem identity. A shim that cannot
# work from that minimal environment fails closed (rc 3).
#
# Trust boundary: the answer is the interpreter's own report, so an
# executable outside the project that the caller put on PATH is trusted to
# report honestly; env -i keeps PYTHONEXECUTABLE and __PYVENV_LAUNCHER__ from
# rewriting a real CPython's report. Directory entries on the resolved paths
# are assumed stable for the run (a concurrent swap is out of scope).
sg_resolve_python() {
  local candidate real exe magic env_bin rc=0
  [ -d "$1" ] || return 3
  if [ -x /usr/bin/env ]; then env_bin=/usr/bin/env
  elif [ -x /bin/env ]; then env_bin=/bin/env
  else return 3
  fi
  [ -x /usr/bin/od ] || return 3
  candidate="$(sg_path_sanitize "$1" && sg_resolve_engine python3 "$1")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  real="$(sg_realpath "$candidate")" || return 3
  if sg_inside "$real" "$1"; then return 3; fi
  exe="$(sg_path_sanitize "$1" && builtin cd / \
         && "$env_bin" -i PATH="$PATH" HOME="${HOME:-/}" LANG=C \
              "$real" -I -c 'import sys; print(sys.executable)' 2>/dev/null)" || return 3
  case "$exe" in /*) ;; *) return 3 ;; esac
  case "$exe" in *$'\n'*) return 3 ;; esac
  exe="$(sg_checked_path "$exe" "$1")" || return 3
  [ -f "$exe" ] && [ -x "$exe" ] || return 3
  if sg_inside "$exe" "$1"; then return 3; fi
  magic="$(/usr/bin/od -An -tx1 -N4 "$exe" 2>/dev/null)" || return 3
  case "${magic//[[:space:]]/}" in
    7f454c46|cffaedfe|cefaedfe|feedfacf|feedface|cafebabe) ;;
    *) return 3 ;;
  esac
  builtin printf '%s\n' "$exe"
}
