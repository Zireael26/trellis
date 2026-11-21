#!/usr/bin/env bash
# Trellis machine-home primitives.
#
# Bash 3.2 compatible. This file is meant to be sourced by local setup,
# registry, release, and attachment commands.
#
# Exit classes shared by portable fleet commands:
#   0  success
#   2  bad arguments
#   3  ownership or identity conflict
#   4  invalid or corrupt local state
#   5  unavailable path, remote, or required local capability

TRELLIS_EX_USAGE=2
TRELLIS_EX_CONFLICT=3
TRELLIS_EX_STATE=4
TRELLIS_EX_UNAVAILABLE=5

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  _TRELLIS_HOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _TRELLIS_HOME_LIB_DIR=""
fi
_TRELLIS_HOME_LOCK_DIR=""
TRELLIS_HOME_LAUNCHER_ACTION=""

# trellis_dirname_to VAR [--] PATH
# trellis_basename_to VAR [--] PATH
#   Set VAR to exactly what `VAR=$(dirname [--] PATH)` / `VAR=$(basename [--]
#   PATH)` sets, without a fork or exec: POSIX rules, `//` folded like the
#   macOS and GNU tools, and trailing newlines removed as command substitution
#   removes them. Without `--`, an operand that starts with `-` (other than
#   `-` itself) is an option to the real tool, which fails: VAR becomes empty
#   and the status is 1. scripts/tests/attachment.bats runs both against the
#   platform tools over an edge corpus.
trellis_dirname_to() {
  local _trellis_pt_path
  case "$#:${2-}" in
    3:--) _trellis_pt_path=$3 ;;
    2:-?*) printf -v "$1" '%s' ''; return 1 ;;
    2:*) _trellis_pt_path=$2 ;;
    *) return 2 ;;
  esac
  case "$_trellis_pt_path" in
    '') _trellis_pt_path=. ;;
    *[!/]*)
      while :; do case "$_trellis_pt_path" in */) _trellis_pt_path=${_trellis_pt_path%/} ;; *) break ;; esac; done
      case "$_trellis_pt_path" in
        */*)
          _trellis_pt_path=${_trellis_pt_path%/*}
          while :; do case "$_trellis_pt_path" in */) _trellis_pt_path=${_trellis_pt_path%/} ;; *) break ;; esac; done
          [ -n "$_trellis_pt_path" ] || _trellis_pt_path=/
          ;;
        *) _trellis_pt_path=. ;;
      esac
      ;;
    *) _trellis_pt_path=/ ;;
  esac
  while :; do case "$_trellis_pt_path" in *$'\n') _trellis_pt_path=${_trellis_pt_path%$'\n'} ;; *) break ;; esac; done
  printf -v "$1" '%s' "$_trellis_pt_path"
}

trellis_basename_to() {
  local _trellis_pt_path
  case "$#:${2-}" in
    3:--) _trellis_pt_path=$3 ;;
    2:-?*) printf -v "$1" '%s' ''; return 1 ;;
    2:*) _trellis_pt_path=$2 ;;
    *) return 2 ;;
  esac
  case "$_trellis_pt_path" in
    '') ;;
    *[!/]*)
      while :; do case "$_trellis_pt_path" in */) _trellis_pt_path=${_trellis_pt_path%/} ;; *) break ;; esac; done
      _trellis_pt_path=${_trellis_pt_path##*/}
      ;;
    *) _trellis_pt_path=/ ;;
  esac
  while :; do case "$_trellis_pt_path" in *$'\n') _trellis_pt_path=${_trellis_pt_path%$'\n'} ;; *) break ;; esac; done
  printf -v "$1" '%s' "$_trellis_pt_path"
}

# trellis_is_sha256_hex VALUE
#   Exactly `printf '%s' VALUE | LC_ALL=C grep -Eq '^[a-f0-9]{64}$'` without
#   the pipeline: true when some newline-separated line of VALUE is 64
#   lowercase hex digits.
trellis_is_sha256_hex() {
  local _trellis_hx_rest=$1 _trellis_hx_line
  while [ -n "$_trellis_hx_rest" ]; do
    case "$_trellis_hx_rest" in
      *$'\n'*)
        _trellis_hx_line=${_trellis_hx_rest%%$'\n'*}
        _trellis_hx_rest=${_trellis_hx_rest#*$'\n'}
        ;;
      *) _trellis_hx_line=$_trellis_hx_rest; _trellis_hx_rest= ;;
    esac
    case "$_trellis_hx_line" in
      *[!0123456789abcdef]*) ;;
      *) [ "${#_trellis_hx_line}" -ne 64 ] || return 0 ;;
    esac
  done
  return 1
}

# trellis_read_nul_fields VAR...
#   Read one NUL-terminated field per VAR from stdin and require end of input
#   after them. Each VAR gets the field less its trailing newlines, as
#   `VAR=$(jq -r ...)` gets a string value, so a producer must drop NUL bytes
#   from its strings as command substitution would. A short stream (a failed
#   producer) or a long one fails.
trellis_read_nul_fields() {
  local _trellis_nf_value
  while [ "$#" -gt 0 ]; do
    IFS= read -r -d '' _trellis_nf_value || return 1
    while :; do
      case "$_trellis_nf_value" in
        *$'\n') _trellis_nf_value=${_trellis_nf_value%$'\n'} ;;
        *) break ;;
      esac
    done
    printf -v "$1" '%s' "$_trellis_nf_value"
    shift
  done
  ! IFS= read -r -d '' _trellis_nf_value && [ -z "$_trellis_nf_value" ]
}

trellis_home_die() {
  local code
  code="$1"
  shift
  printf 'trellis: %s\n' "$*" >&2
  exit "$code"
}

trellis_home_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "trellis: jq is required for local Trellis configuration" >&2
    printf '%s\n' "  macOS:  brew install jq" >&2
    printf '%s\n' "  Debian: apt-get install jq" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
}

# Small calls exec jq with the original argv; at 64 KiB of --arg/--argjson
# values, use files to avoid ARG_MAX. Shell function arguments and builtin
# printf do not cross exec's limit. Keep JSON order, bytes and hashes intact.
# The large-call path supports --arg/--argjson, --rawfile/--slurpfile, short
# flags, FILTER [FILES]; it is not a general jq CLI wrapper (-f/--args).
trellis_jq() (
  local bytes=0 remaining=0 measure=0 arg
  local original_lc_all="${LC_ALL-}" lc_all_set="${LC_ALL+x}"
  # Bash lengths count characters in multibyte locales. Restore the caller's
  # locale before exec so the fast path changes neither argv nor environment.
  LC_ALL=C
  for arg in "$@"; do
    if [ "$remaining" -gt 0 ]; then
      remaining=$((remaining - 1))
      if [ "$remaining" -eq 0 ] && [ "$measure" -eq 1 ]; then
        bytes=$((bytes + ${#arg}))
        [ "$bytes" -lt 65536 ] || break
      fi
      continue
    fi
    case "$arg" in
      --arg|--argjson) remaining=2; measure=1 ;;
      --rawfile|--slurpfile) remaining=2; measure=0 ;;
      --) break ;;
      -*) ;;
      *) break ;;
    esac
  done
  if [ "$lc_all_set" = x ]; then
    LC_ALL="$original_lc_all"
  else
    unset LC_ALL
  fi
  [ "$bytes" -ge 65536 ] || exec jq "$@"

  local name file prefix='' validation='true' count=0 kind
  local -a options=() json_options=()
  umask 077
  # Subshell-scoped, not local: Bash 3.2 can unwind locals before EXIT on
  # inherited errexit. The private name also avoids interrupted-helper locals.
  __trellis_jq_scratch="$(mktemp -d "${TMPDIR:-/tmp}/trellis-jq.XXXXXX")" || return 2
  trellis_jq_cleanup() {
    local status="$1"
    trap '' HUP INT TERM
    trap - EXIT
    rm -rf -- "${__trellis_jq_scratch:?}" || true
    exit "$status"
  }
  trap 'trellis_jq_cleanup "$?"' EXIT
  trap 'trellis_jq_cleanup 129' HUP
  trap 'trellis_jq_cleanup 130' INT
  trap 'trellis_jq_cleanup 143' TERM
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --arg|--argjson)
        [ "$#" -ge 3 ] || {
          printf 'trellis_jq: %s requires a name and value\n' "$1" >&2
          return 2
        }
        kind="$1" name="$2"
        [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
          printf '%s\n' 'trellis_jq: invalid argument name' >&2
          return 2
        }
        file="$__trellis_jq_scratch/$count"
        count=$((count + 1))
        builtin printf '%s' "$3" > "$file" || return 2
        if [ "$kind" = --argjson ]; then
          options+=(--slurpfile "$name" "$file")
          json_options+=(--slurpfile "$name" "$file")
          validation="$validation and (\$$name | length == 1)"
          prefix="$prefix (\$${name}[0]) as \$$name |"
        else
          options+=(--rawfile "$name" "$file")
        fi
        shift 3
        ;;
      --slurpfile|--rawfile)
        [ "$#" -ge 3 ] || {
          printf 'trellis_jq: %s requires a name and file\n' "$1" >&2
          return 2
        }
        options+=("$1" "$2" "$3")
        shift 3
        ;;
      -f|--*)
        printf '%s\n' 'trellis_jq: unsupported flag in file transport' >&2
        return 2
        ;;
      -*) options+=("$1"); shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || {
    printf '%s\n' 'trellis_jq: filter is required' >&2
    return 2
  }
  # Like --argjson, reject malformed/empty/multiple JSON values even when
  # stdin is empty. The files are private and cannot change between reads.
  if [ "${#json_options[@]}" -gt 0 ]; then
    jq -en "${json_options[@]}" "$validation" >/dev/null || return 2
  fi
  local filter="$1"
  shift
  jq "${options[@]+"${options[@]}"}" "$prefix ($filter)" "$@"
)

trellis_home_has_unsafe_chars() {
  local value="$1"
  # Enumerate bytes: ranges depend on locale, and changing Bash's own locale
  # can crash Bash 5.3 after fork (even with explicit save/restore).
  case "$value" in
    *[$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177']*|*$'\302'[$'\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237']*) return 0 ;;
    *) return 1 ;;
  esac
}

trellis_home_require_safe_text() {
  local label value
  label="$1"
  value="$2"
  if [ -z "$value" ]; then
    printf 'trellis: %s is required\n' "$label" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  if trellis_home_has_unsafe_chars "$value"; then
    printf 'trellis: %s contains terminal control characters, which Trellis state forbids\n' "$label" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

# env treats any command operand containing '=' as another assignment,
# even after '--'. Quoted shell metacharacters are otherwise ordinary bytes.
trellis_home_native_entry_path_is_safe() {
  local path="$1"
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in
    *=*|*[$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177']*|*$'\302'[$'\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237']*) return 1 ;;
  esac
  return 0
}

trellis_home_require_absolute_safe_path() {
  local label path normalized
  label="$1"
  path="$2"
  trellis_home_require_safe_text "$label" "$path" || return "$?"
  case "$path" in
    /*) ;;
    *)
      printf 'trellis: %s must be an absolute path: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  case "$label" in
    TRELLIS_HOME|'native companion')
      if ! trellis_home_native_entry_path_is_safe "$path"; then
        printf 'trellis: %s must not contain an env assignment operand (=)\n' "$label" >&2
        return "$TRELLIS_EX_USAGE"
      fi
      ;;
  esac
  case "$path" in
    //*)
      printf 'trellis: %s must not use an ambiguous double-slash path: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  case "$path/" in
    */./*|*/../*)
      printf 'trellis: %s must not contain . or .. path components: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  normalized="$path"
  while [ "${normalized%/}" != "$normalized" ]; do
    normalized="${normalized%/}"
  done
  if [ -z "$normalized" ]; then
    printf 'trellis: %s must not be the filesystem root: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

trellis_home_is_valid_fleet_name() {
  printf '%s' "$1" | /usr/bin/env LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$'
}

trellis_home_require_fleet_name() {
  local name
  name="$1"
  if ! trellis_home_is_valid_fleet_name "$name"; then
    printf 'trellis: invalid fleet name %s; expected ^[a-z0-9][a-z0-9._-]{0,63}$\n' "$name" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

trellis_home_is_valid_lock_name() {
  printf '%s' "$1" | /usr/bin/env LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$'
}

trellis_home_require_lock_name() {
  local name
  name="$1"
  if ! trellis_home_is_valid_lock_name "$name"; then
    printf 'trellis: invalid lock name %s; expected ^[a-z0-9][a-z0-9._-]{0,63}$\n' "$name" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

trellis_home_is_valid_semver() {
  printf '%s' "$1" | /usr/bin/env LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

# NORMATIVE DEFINITION of the release-store execution-payload predicate.
#
# A stable launcher never executes the installed release directory itself: it
# seals a snapshot of the configured release under another name and executes
# that. So a verified payload is legitimately one of
#
#   HOME/releases/VERSION/payload                      (the installed release)
#   HOME/releases/.exec/VERSION-DIGEST/payload         (its persistent execution
#                                                       snapshot, DIGEST being the
#                                                       sha256 of its release.json)
#   HOME/releases/.tmp.VERSION.exec.SUFFIX/payload     (the per-run snapshot of
#                                                       launchers before 1.4.0)
#
# and nothing else in the store. The persistent form matches the version whole
# too: what follows "VERSION-" must be exactly 64 lowercase hex digits, so the
# snapshot of release 1.2.3-rc is not accepted under 1.2.3. Every gate in the tree that admits a payload
# decides exactly this question, so the answer is defined once, here, and
# unit-tested here. SIX callers cannot reach this function at the moment they
# ask — five direct-source gates that run before any library may be sourced
# (scripts/show-config.sh, the scripts/upgrade.sh body, both the bootstrap and
# the body of scripts/sync-to-template.sh, and the scripts/trellis-launcher.sh
# body) plus scripts/lib/release-store.sh, which by its own file header depends
# on nothing above semver.sh — so each carries a byte-identical copy of this
# body under its own name. scripts/tests/release-snapshot-predicate.bats pins
# those six copies to this definition, so the seven can never drift apart. See
# that test's header for why a call cannot replace the copies.
#
# The version segment is matched WHOLE, never as a prefix. Release versions
# carry dots, so '.tmp.1.2.3.exec.9.exec.SUFFIX' — the snapshot of a release
# literally named '1.2.3.exec.9' — shares the entire '.tmp.1.2.3.exec.' prefix
# with a snapshot of release 1.2.3 and ends in an alphanumeric suffix of its
# own. A prefix glob plus a greedy '##*.exec.' strip accepts it under the 1.2.3
# attestation, which is the hole this shape closes: strip the delimiters
# literally (the version is quoted inside the pattern, so its own dots and any
# glob metacharacter stay literal) and require what remains to be exactly the
# opaque suffix.
#
# Pure string predicate: it touches no filesystem and reads no environment, so
# a caller must still prove the paths are real, unlinked, and canonical.
#
# The line below declares that every gate of this payload accepts the
# persistent .exec form. The stable launcher reads it from the verified payload
# and runs older payloads, which lack it, from a per-run snapshot instead
# (launcher_payload_runs_from_exec_store). Keep it exactly as written while the
# predicate accepts .exec/VERSION-DIGEST.
# trellis-payload-capability: exec-snapshot
trellis_home_snapshot_payload_matches() {
  local home="$1" payload="$2" version="$3" snapshot_root snapshot_base rest suffix
  [ "$payload" = "$home/releases/$version/payload" ] && return 0
  snapshot_root="${payload%/payload}"
  [ "$snapshot_root" != "$payload" ] || return 1
  snapshot_base="${snapshot_root##*/}"
  if [ "${snapshot_root%/*}" = "$home/releases/.exec" ]; then
    suffix="${snapshot_base#"$version"-}"
    [ "$suffix" != "$snapshot_base" ] && [ "${#suffix}" -eq 64 ] || return 1
    case "$suffix" in
      *[!0-9a-f]*) return 1 ;;
    esac
    return 0
  fi
  [ "${snapshot_root%/*}" = "$home/releases" ] || return 1
  rest="${snapshot_base#.tmp.}"
  [ "$rest" != "$snapshot_base" ] || return 1
  suffix="${rest#"$version".exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

trellis_home_resolve() {
  local explicit candidate
  explicit="${1:-}"
  if [ -n "$explicit" ]; then
    candidate="$explicit"
  elif [ -n "${TRELLIS_HOME:-}" ]; then
    candidate="$TRELLIS_HOME"
  else
    if [ -z "${HOME:-}" ]; then
      printf 'trellis: HOME is required when TRELLIS_HOME is not set\n' >&2
      return "$TRELLIS_EX_USAGE"
    fi
    candidate="$HOME/.trellis"
  fi
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$candidate" || return "$?"
  printf '%s\n' "$candidate"
}

# Reduce an operator-supplied home to the exact spelling the fixed launcher will
# later accept, or refuse it here. Configure is the only writer that can still
# ask; every later dispatch reads a persisted decision, so a home that merely
# passes `trellis_home_require_absolute_safe_path` (which tolerates an embedded
# `//`) but fails the launcher's stricter canonical test would strand the
# machine with a config it cannot dispatch from.
#
# Canonical here means: no repeated or trailing separators, no traversal or
# control characters, not the filesystem root, not a symlink itself, and every
# existing ancestor resolved through `pwd -P`.
trellis_home_canonical_home() {
  local path="${1:-}" suffix="" base parent real
  trellis_home_require_safe_text "TRELLIS_HOME" "$path" || return "$?"
  case "$path" in
    *//*)
      path="$(printf '%s' "$path" | tr -s '/')" || {
        printf 'trellis: could not canonicalize TRELLIS_HOME: %s\n' "$1" >&2
        return "$TRELLIS_EX_UNAVAILABLE"
      }
      ;;
  esac
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$path" || return "$?"
  if [ -L "$path" ]; then
    printf 'trellis: TRELLIS_HOME must not be a symlink: %s\n' "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  parent="$path"
  while [ "$parent" != "/" ] && [ ! -d "$parent" ]; do
    base="${parent##*/}"
    parent="${parent%/*}"
    [ -n "$parent" ] || parent="/"
    suffix="/$base$suffix"
  done
  real="$(trellis_home_real_dir "$parent")" || {
    printf 'trellis: could not canonicalize TRELLIS_HOME: %s\n' "$path" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ "$real" != "/" ] || real=""
  path="$real$suffix"
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$path" || return "$?"
  case "$path" in
    *'//'*)
      printf 'trellis: could not canonicalize TRELLIS_HOME: %s\n' "$path" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
  esac
  printf '%s\n' "$path"
}

trellis_home_config_path() {
  printf '%s/config.json\n' "$1"
}

trellis_home_schema_path() {
  if [ "${TRELLIS_LIBS_PRELOADED:-}" = 1 ]; then
    printf '\n'
  else
    printf '%s/trellis.machine.schema.json\n' "$_TRELLIS_HOME_LIB_DIR"
  fi
}

trellis_home_prepare_private_dir() {
  local path label
  path="$1"
  label="$2"
  if [ -L "$path" ]; then
    printf 'trellis: %s must not be a symlink: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    printf 'trellis: %s must be a directory: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$path" ]; then
    (umask 077; mkdir -p "$path") || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    printf 'trellis: %s must be a real directory: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  # chmod only when the mode is not already exactly 0700: GNU chmod issues a
  # same-mode chmod(2), which moves the directory ctime (BSD chmod skips it),
  # and the registry drift token reads that as a change. `-perm 0700` is an exact match, special bits
  # included, in GNU and BSD find alike; a failed probe means chmod. 00700, not
  # 700: GNU chmod keeps a directory's setuid/setgid bits for a 3-digit mode.
  if [ -n "$(find "$path" -maxdepth 0 -perm 0700 -print 2>/dev/null)" ]; then
    :
  else
    chmod 00700 "$path" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
    if [ -z "$(find "$path" -maxdepth 0 -perm 0700 -print 2>/dev/null)" ]; then
      printf 'trellis: %s could not be made exactly 0700: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
  fi
  return 0
}

trellis_home_prepare_home() {
  local home
  home="$1"
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$home" || return "$?"
  trellis_home_prepare_private_dir "$home" "TRELLIS_HOME" || return "$?"
  trellis_home_prepare_private_dir "$home/locks" "Trellis locks directory" || return "$?"
  trellis_home_prepare_private_dir "$home/state" "Trellis state directory" || return "$?"
  trellis_home_prepare_private_dir "$home/releases" "Trellis releases directory" || return "$?"
  return 0
}

trellis_home_lock_read_pid() {
  local pid_file pid
  pid_file="$1"
  if [ -L "$pid_file" ] || [ ! -f "$pid_file" ]; then
    printf 'trellis: lock is missing a regular pid record: %s\n' "$pid_file" >&2
    return "$TRELLIS_EX_STATE"
  fi
  pid="$(cat "$pid_file" 2>/dev/null)" || {
    printf 'trellis: could not read lock pid record: %s\n' "$pid_file" >&2
    return "$TRELLIS_EX_STATE"
  }
  case "$pid" in
    ''|*[!0-9]*|0*)
      printf 'trellis: lock has an invalid pid record: %s\n' "$pid_file" >&2
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  printf '%s\n' "$pid"
}

trellis_home_pid_is_live() {
  local pid probe_status
  pid="$1"
  case "$pid" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
  if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
    return 0
  fi
  # A failed shell kill or ps is not proof of death: kill can return EPERM,
  # and ps may be unavailable under a sandbox. Only ESRCH permits recovery.
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'trellis: cannot establish liveness of pid %s: python3 is unavailable; keeping lock\n' "$pid" >&2
    return 0
  fi
  if python3 -I -c '
import errno, os, sys
try:
    os.kill(int(sys.argv[1]), 0)
except OSError as exc:
    if exc.errno == errno.ESRCH:
        sys.exit(3)
' "$pid" >/dev/null 2>&1; then
    return 0
  else
    probe_status="$?"
  fi
  if [ "$probe_status" -ne 3 ]; then
    printf 'trellis: cannot establish liveness of pid %s: liveness probe failed (exit %s); keeping lock\n' \
      "$pid" "$probe_status" >&2
    return 0
  fi
  return 1
}

# ===========================================================================
# process birth
# ===========================================================================

# The Darwin process-birth reader, emitted as data.
#
# macOS ships `ps` setgid `kmem`, and a setgid binary does not run under the
# seatbelt profiles the Claude Code, Codex, and isolated-verification shells
# use. Every `LC_ALL=C ps -p PID -o lstart=` call site therefore went
# indeterminate inside them, which is what blocked the launcher owner-cleanup
# cases in specs/045-three-harness-parity. libproc answers the same question
# through an ordinary dynamic library, with no privilege and no sandbox
# exception, and returns the identical token.
#
# A consumer that already owns a child-process boundary — the disk-janitor
# descriptor-relative deletion sink — takes this program as an argument and
# runs it there as `python3 -I -c PROGRAM PID`. `-I` is load-bearing: it stops
# a poisoned cwd or PYTHONPATH from shadowing `ctypes` or `time`. The program
# is data from trusted in-memory release code and is never written to or read
# from the filesystem, so no call site discovers a mutable source path at
# runtime.
trellis_process_birth_python() {
  cat <<'TRELLIS_PROCESS_BIRTH_PY'
import ctypes
import sys
import time

# proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) fills `struct
# proc_bsdinfo` (<sys/proc_info.h>) and returns the number of bytes written:
#
#   uint32_t pbi_flags, pbi_status, pbi_xstatus, pbi_pid, pbi_ppid,
#            pbi_uid, pbi_gid, pbi_ruid, pbi_rgid, pbi_svuid, pbi_svgid, rfu_1;
#   char     pbi_comm[MAXCOMLEN];      /* 16 */
#   char     pbi_name[2 * MAXCOMLEN];  /* 32 */
#   uint32_t pbi_nfiles, pbi_pgid, pbi_pjobc, e_tdev, e_tpgid;
#   int32_t  pbi_nice;
#   uint64_t pbi_start_tvsec, pbi_start_tvusec;
#
# Only pbi_pid (head[3]) and pbi_start_tvsec are read; the rest is layout.
PROC_PIDTBSDINFO = 3
ESRCH = 3


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("head", ctypes.c_uint32 * 12),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("tail", ctypes.c_uint32 * 5),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


if len(sys.argv) != 2 or not sys.argv[1].isdigit():
    raise SystemExit(2)
pid = int(sys.argv[1])
# Reject a non-canonical spelling as well as an out-of-range value: the pid
# crosses into C as a signed int, and "007" is not the pid any record stored.
if str(pid) != sys.argv[1] or pid < 1 or pid > 2147483647:
    raise SystemExit(2)

try:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidinfo = libproc.proc_pidinfo
except (OSError, AttributeError):
    raise SystemExit(1)
proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.POINTER(ProcBsdInfo),
    ctypes.c_int,
]
proc_pidinfo.restype = ctypes.c_int

info = ProcBsdInfo()
ctypes.set_errno(0)
written = proc_pidinfo(
    pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info)
)
saved_errno = ctypes.get_errno()
# A short write is a failure, never a partially trusted record. ESRCH is the
# only errno that means "gone"; EPERM and an unsupported flavour are
# indeterminate and must not be reported as death.
if written != ctypes.sizeof(info):
    raise SystemExit(3 if saved_errno == ESRCH else 1)
if info.head[3] != pid:
    raise SystemExit(1)
if info.pbi_start_tvsec < 1:
    raise SystemExit(1)
try:
    token = time.strftime(
        "%a %b %e %H:%M:%S %Y", time.localtime(info.pbi_start_tvsec)
    )
except (OSError, OverflowError, ValueError):
    raise SystemExit(1)
# `ps -o lstart=` emits exactly 28 columns and a newline; anything else is not
# the schema every stored owner record was written in.
if not token or len(token) > 28:
    raise SystemExit(1)
sys.stdout.write(token.ljust(28) + "\n")
TRELLIS_PROCESS_BIRTH_PY
}

# trellis_process_birth <pid>
#
# The process-birth token for PID: `LC_ALL=C ps -p PID -o lstart=` wherever ps
# runs, and the libproc reader above on Darwin. Both emit the same 28-column
# localtime string, so the stored `process_birth` schema is unchanged and a
# record written by either reader compares equal to one read by the other.
#
# Status: 0 with the token on stdout, 2 for a malformed or out-of-range pid, 3
# when the Darwin reader reports ESRCH, 1 for every other failure. Callers must
# keep mapping EVERY nonzero status to "indeterminate": a birth read that fails
# after kill(0) reported the process live has not proved it dead and must never
# authorize cleanup.
trellis_process_birth() {
  local pid program
  pid="${1:-}"
  case "$pid" in
    ""|*[!0-9]*|0*) return 2 ;;
  esac
  [ "$pid" -le 2147483647 ] || return 2
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    command -v python3 >/dev/null 2>&1 || return 1
    program="$(trellis_process_birth_python)" || return 1
    /usr/bin/env LC_ALL=C python3 -I -c "$program" "$pid" 2>/dev/null || return "$?"
    return 0
  fi
  /usr/bin/env LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || return 1
  return 0
}


trellis_home_lock_release() {
  local lock_dir pid
  lock_dir="$_TRELLIS_HOME_LOCK_DIR"
  _TRELLIS_HOME_LOCK_DIR=""
  [ -n "$lock_dir" ] || return 0
  if [ -L "$lock_dir" ] || [ ! -d "$lock_dir" ]; then
    printf 'trellis: refusing to release an invalid lock directory: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  pid="$(trellis_home_lock_read_pid "$lock_dir/pid")" || return "$?"
  if [ "$pid" != "$$" ]; then
    printf 'trellis: refusing to release lock not owned by this process: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if ! trellis_home_lock_has_only_pid "$lock_dir"; then
    printf 'trellis: refusing to release lock with unexpected contents: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  rm -f "$lock_dir/pid" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! rmdir "$lock_dir" 2>/dev/null; then
    printf 'trellis: lock changed during release: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  return 0
}

trellis_home_lock_has_only_pid() {
  local lock_dir
  lock_dir="$1"
  (
    shopt -s dotglob nullglob
    set -- "$lock_dir"/*
    [ "$#" -eq 1 ] && [ "$1" = "$lock_dir/pid" ]
  )
}

trellis_home_lock_is_initializing() {
  local lock_dir pid_file pid
  lock_dir="$1"
  pid_file="$lock_dir/pid"
  if [ ! -e "$pid_file" ] && [ ! -L "$pid_file" ]; then
    return 0
  fi
  if [ -L "$pid_file" ] || [ ! -f "$pid_file" ]; then
    return 1
  fi
  pid="$(cat "$pid_file" 2>/dev/null)" || return 1
  [ -z "$pid" ]
}

# An initializing lock has no owner to check for liveness. Only after ten
# minutes, and only for the exact private shape created by this helper, may a
# missing/empty pid be removed. A pid-less directory holding only aged
# pid.recovery.<pid> residue from an interrupted dead-pid recovery is the
# same ownerless shape: there is no live owner record to protect. Collect
# stable identity and metadata without Python: this shared lock is also on
# registry and attachment paths.
trellis_home_lock_stat() {
  if [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/env LC_ALL=C /usr/bin/stat -f '%d:%i:%u:%Lp:%m:%c:%z:%l' -- "$1" 2>/dev/null
  else
    /usr/bin/env LC_ALL=C /usr/bin/stat -c '%d:%i:%u:%a:%Y:%Z:%s:%h' -- "$1" 2>/dev/null
  fi
}

trellis_home_lock_age_over() {
  case "$1:$2" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$1" -ge "$2" ] && [ "$(( $1 - $2 ))" -gt 600 ]
}

# Command substitution cannot represent NUL bytes. Treat a pid record as
# empty only when it is zero bytes or contains a bounded sequence of newlines.
trellis_home_lock_pid_is_empty() {
  local pid_path="$1" size="$2" values byte
  local -a bytes=()
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$pid_path" ] && [ ! -L "$pid_path" ] || return 1
  if [ "$size" -eq 0 ]; then [ ! -s "$pid_path" ]; return "$?"; fi
  [ "$size" -le 4096 ] || return 1
  values="$(/usr/bin/env LC_ALL=C /usr/bin/od -An -v -tu1 -- "$pid_path" 2>/dev/null)" || return 1
  values="${values//$'\n'/ }"
  IFS=$' \t\n' read -r -a bytes <<< "$values"
  [ "${#bytes[@]}" -eq "$size" ] || return 1
  for byte in "${bytes[@]}"; do [ "$byte" = 10 ] || return 1; done
  return 0
}

trellis_home_lock_recover_ownerless() {
  local lock_dir="$1" name="$2" now dir_info dir_again file_info='' file_again
  local uid mode mtime size links extra state=missing
  local residue_list='' residue_path='' residue_info='' residue_again='' residue_mtime='' residue_links='' residue_suffix='' residue_i=0
  local -a residues=() residue_infos=()
  [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] && [ -O "$lock_dir" ] || return 1
  now="$(/bin/date +%s 2>/dev/null)" || return 1
  dir_info="$(trellis_home_lock_stat "$lock_dir")" || return 1
  IFS=: read -r _ _ uid mode mtime _ _ _ extra <<< "$dir_info"
  # Enforce the same owner as -O through the %u field so the refusal is
  # testable without root and without a second filesystem probe. A missing
  # id probe compares unequal by construction and fails closed.
  [ "$uid" = "$(id -u 2>/dev/null)" ] && [ "$mode" = 700 ] && [ -z "${extra:-}" ] && trellis_home_lock_age_over "$now" "$mtime" || return 1
  if [ -e "$lock_dir/pid" ] || [ -L "$lock_dir/pid" ]; then
    [ -f "$lock_dir/pid" ] && [ ! -L "$lock_dir/pid" ] && [ -O "$lock_dir/pid" ] || return 1
    file_info="$(trellis_home_lock_stat "$lock_dir/pid")" || return 1
    IFS=: read -r _ _ _ mode mtime _ size links extra <<< "$file_info"
    [ "$links" = 1 ] && [ -z "${extra:-}" ] && trellis_home_lock_age_over "$now" "$mtime" || return 1
    trellis_home_lock_pid_is_empty "$lock_dir/pid" "$size" && trellis_home_lock_has_only_pid "$lock_dir" || return 1
    state=empty
  else
    # A missing pid qualifies only when no unrelated entry can be removed.
    # Stale pid.recovery.* residue is the same ownerless shape, but each
    # residue file is validated like a moved pid record before removal.
    residue_list="$( ( shopt -s dotglob nullglob; set -- "$lock_dir"/*; if [ "$#" -gt 0 ]; then for entry in "$@"; do if [[ $entry == "$lock_dir"/pid.recovery.* ]]; then printf '%s\n' "$entry"; else exit 1; fi; done; fi ) )" || return 1
    if [ -n "$residue_list" ]; then
      state=residue
      while IFS= read -r residue_path; do
        [ -n "$residue_path" ] || continue
        [ -f "$residue_path" ] && [ ! -L "$residue_path" ] && [ -O "$residue_path" ] || return 1
        residue_suffix="${residue_path##*/pid.recovery.}"
        case "$residue_suffix" in ''|*[!0-9]*|0*) return 1 ;; esac
        residue_info="$(trellis_home_lock_stat "$residue_path")" || return 1
        IFS=: read -r _ _ _ _ residue_mtime _ _ residue_links extra <<< "$residue_info"
        [ "$residue_links" = 1 ] && [ -z "${extra:-}" ] && trellis_home_lock_age_over "$now" "$residue_mtime" || return 1
        trellis_home_lock_read_pid "$residue_path" >/dev/null || return 1
        residues+=("$residue_path")
        residue_infos+=("$residue_info")
      done <<< "$residue_list"
    fi
  fi
  dir_again="$(trellis_home_lock_stat "$lock_dir")" || return 1
  [ "$dir_again" = "$dir_info" ] && [ ! -L "$lock_dir" ] || return 1
  if [ "$state" = empty ]; then
    file_again="$(trellis_home_lock_stat "$lock_dir/pid")" || return 1
    [ "$file_again" = "$file_info" ] && [ ! -L "$lock_dir/pid" ] || return 1
    trellis_home_lock_pid_is_empty "$lock_dir/pid" "$size" || return 1
    rm -f "${lock_dir:?}/pid" || return "$TRELLIS_EX_UNAVAILABLE"
  elif [ "$state" = residue ]; then
    [ ! -e "$lock_dir/pid" ] && [ ! -L "$lock_dir/pid" ] || return 1
    for ((residue_i=0; residue_i<${#residues[@]}; residue_i++)); do
      residue_path="${residues[$residue_i]}"
      residue_again="$(trellis_home_lock_stat "$residue_path")" || return 1
      [ "$residue_again" = "${residue_infos[$residue_i]}" ] && [ ! -L "$residue_path" ] || return 1
      trellis_home_lock_read_pid "$residue_path" >/dev/null || return 1
    done
    for ((residue_i=0; residue_i<${#residues[@]}; residue_i++)); do
      residue_path="${residues[$residue_i]}"
      rm -f "${residue_path:?}" || return "$TRELLIS_EX_UNAVAILABLE"
    done
  else
    [ ! -e "$lock_dir/pid" ] && [ ! -L "$lock_dir/pid" ] || return 1
  fi
  if ! rmdir "$lock_dir" 2>/dev/null; then
    printf 'trellis: stale %s lock changed during recovery: %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  printf 'trellis: recovered stale %s lock at %s (owner record %s for over 10 minutes)\n' "$name" "$lock_dir" "$state" >&2
  return 0
}

trellis_home_lock_try_recover_stale() {
  local lock_dir name pid moved recovered_pid
  lock_dir="$1"
  name="$2"

  if [ -L "$lock_dir" ]; then
    printf 'trellis: refusing symlinked %s lock at %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$lock_dir" ] && [ ! -d "$lock_dir" ]; then
    printf 'trellis: refusing non-directory %s lock at %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  [ -d "$lock_dir" ] || return "$TRELLIS_EX_UNAVAILABLE"

  # mkdir(2) publishes the directory before its pid; respect a young
  # initializer, but recover the tightly checked, old ownerless shape.
  if trellis_home_lock_is_initializing "$lock_dir"; then
    trellis_home_lock_recover_ownerless "$lock_dir" "$name"
    return "$?"
  fi
  pid="$(trellis_home_lock_read_pid "$lock_dir/pid")" || return "$?"
  if trellis_home_pid_is_live "$pid"; then
    return 1
  fi
  if ! trellis_home_lock_has_only_pid "$lock_dir"; then
    printf 'trellis: refusing to recover stale %s lock with unexpected contents: %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi

  # Reclaim the pid record atomically and prove it is still the one whose
  # liveness was checked. Between the checks above and here another contender
  # may have recovered the lock and published its own live pid; deleting that
  # record would leave two processes believing they hold the lock.
  moved="$lock_dir/pid.recovery.$$"
  if ! mv "$lock_dir/pid" "$moved" 2>/dev/null; then
    # Another contender moved the record first. Retry rather than reporting a
    # fatal unavailable state with no diagnosis.
    return 1
  fi
  recovered_pid="$(trellis_home_lock_read_pid "$moved")" || {
    # A new owner may be between mkdir and its pid write. Put the record back
    # instead of deleting it, then let the acquire loop retry.
    mv "$moved" "$lock_dir/pid" 2>/dev/null || true
    return 1
  }
  if [ "$recovered_pid" != "$pid" ]; then
    # Put the new owner's record back and lose the race. A failed restore
    # never deletes the moved record: if it holds a live owner's pid, the
    # delete would leave that owner without a record.
    mv "$moved" "$lock_dir/pid" 2>/dev/null || true
    return 1
  fi
  rm -f "$moved" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! rmdir "$lock_dir" 2>/dev/null; then
    printf 'trellis: stale %s lock changed during recovery: %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  printf 'trellis: recovered stale %s lock at %s (dead pid %s)\n' "$name" "$lock_dir" "$pid" >&2
  return 0
}

trellis_home_lock_acquire() {
  local home name timeout lock_root lock_dir elapsed pid recover_code wait_seconds=1 delay timeout_code
  local started wall_elapsed recoveries=0 pid_write_rc
  home="$1"
  name="${2:-config}"
  timeout="${3:-30}"
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$home" || return "$?"
  trellis_home_require_lock_name "$name" || return "$?"
  case "$timeout" in
    ''|*[!0-9]*)
      printf 'trellis: lock timeout must be a non-negative integer: %s\n' "$timeout" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  if [ -L "$home" ]; then
    printf 'trellis: TRELLIS_HOME must not be a symlink: %s\n' "$home" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$home" ]; then
    printf 'trellis: TRELLIS_HOME is unavailable: %s\n' "$home" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi

  lock_root="$home/locks"
  lock_dir="$lock_root/$name.lock"
  elapsed=0
  started="$SECONDS"
  # Contention is an unavailable capability, not evidence of corrupt state.
  # Keep the existing exit contract for other machine-state locks.
  timeout_code="$TRELLIS_EX_STATE"
  [ "$name" != registry ] || timeout_code="$TRELLIS_EX_UNAVAILABLE"
  if [ -L "$lock_root" ] || { [ -e "$lock_root" ] && [ ! -d "$lock_root" ]; }; then
    printf 'trellis: refusing invalid Trellis locks directory: %s\n' "$lock_root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$lock_root" ]; then
    (umask 077; mkdir "$lock_root") || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ -L "$lock_root" ] || [ ! -d "$lock_root" ]; then
    printf 'trellis: refusing invalid Trellis locks directory: %s\n' "$lock_root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  chmod 700 "$lock_root" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"

  while :; do
    if [ "$name" = registry ]; then
      wall_elapsed=$((SECONDS - started))
      [ "$elapsed" -ge "$wall_elapsed" ] || elapsed="$wall_elapsed"
    fi
    if mkdir -m 700 "$lock_dir" 2>/dev/null; then
      # Publish the owner immediately: a TERM in the preceding mkdir-to-pid
      # window is handled conservatively by the ten-minute stale path above.
      # Noclobber the pid write: a stalled or racing contender whose mkdir
      # succeeded before another process recovered the stale directory would
      # otherwise overwrite the winner's pid and both would return 0. The
      # loser's rmdir on the winner's non-empty directory is a no-op, so the
      # loser exits 5 and the winner keeps the lock alone.
      set -C
      printf '%s\n' "$$" 2>/dev/null > "$lock_dir/pid"
      pid_write_rc=$?
      set +C
      if [ "$pid_write_rc" -ne 0 ]; then
        rmdir "$lock_dir" 2>/dev/null || true
        return "$TRELLIS_EX_UNAVAILABLE"
      fi
      if ! chmod 600 "$lock_dir/pid" 2>/dev/null; then
        rm -f "$lock_dir/pid" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
        return "$TRELLIS_EX_UNAVAILABLE"
      fi
      _TRELLIS_HOME_LOCK_DIR="$lock_dir"
      return 0
    fi

    if [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
      printf 'trellis: could not create %s lock at %s\n' "$name" "$lock_dir" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if trellis_home_lock_try_recover_stale "$lock_dir" "$name"; then
      recover_code=0
    else
      recover_code="$?"
    fi
    if [ "$recover_code" -eq 0 ]; then
      recoveries=$((recoveries + 1))
      # Allow the normal one-stale-holder recovery even for a zero probe, but
      # repeated stale churn must not evade the registry's wall-time budget.
      if [ "$name" = registry ] && [ "$recoveries" -gt 1 ] && [ "$elapsed" -ge "$timeout" ]; then
        printf 'trellis: timed out waiting for registry lock at %s (stale holder kept changing)\n' "$lock_dir" >&2
        return "$timeout_code"
      fi
      continue
    fi
    if [ "$recover_code" -eq "$TRELLIS_EX_STATE" ] || [ "$recover_code" -eq "$TRELLIS_EX_UNAVAILABLE" ]; then
      return "$recover_code"
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      if trellis_home_lock_is_initializing "$lock_dir"; then
        printf 'trellis: timed out waiting for %s lock at %s (still initializing)\n' "$name" "$lock_dir" >&2
        return "$timeout_code"
      fi
      pid="$(trellis_home_lock_read_pid "$lock_dir/pid")" || return "$?"
      printf 'trellis: timed out waiting for %s lock at %s (held by pid %s)\n' "$name" "$lock_dir" "$pid" >&2
      return "$timeout_code"
    fi
    delay="$wait_seconds"
    [ "$delay" -le "$((timeout - elapsed))" ] || delay=$((timeout - elapsed))
    sleep "$delay" || return "$TRELLIS_EX_UNAVAILABLE"
    elapsed=$((elapsed + delay))
    if [ "$name" = registry ] && [ "$wait_seconds" -lt 8 ]; then
      wait_seconds=$((wait_seconds * 2))
    fi
  done
}

# Attachment writers share a machine-wide registry: allow a busy sibling to
# finish, with the bounded backoff above. Explicit zero remains a single probe.
trellis_home_registry_lock_acquire() {
  trellis_home_lock_acquire "$1" registry "${2:-300}"
}

trellis_home_real_dir() {
  local path
  path="$1"
  [ -d "$path" ] || return 1
  (cd "$path" && pwd -P)
}

trellis_home_require_source_root() {
  local path real
  path="$1"
  trellis_home_require_absolute_safe_path "source root" "$path" || return "$?"
  if [ ! -d "$path" ]; then
    printf 'trellis: source root is not a directory: %s\n' "$path" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  real="$(trellis_home_real_dir "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
  trellis_home_require_absolute_safe_path "source root" "$real" || return "$?"
  if [ ! -f "$real/trellis.config.json" ]; then
    printf 'trellis: source root does not look like a Trellis policy checkout: %s\n' "$real" >&2
    printf 'trellis: expected trellis.config.json under the source root\n' >&2
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$real"
}

trellis_home_validate_config() {
  local cfg schema
  cfg="$1"
  schema="$(trellis_home_schema_path)"
  trellis_home_require_jq || return "$?"
  if [ -L "$cfg" ]; then
    printf 'trellis: machine config must not be a symlink: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -f "$cfg" ]; then
    printf 'trellis: machine config must be a regular file: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ] && [ ! -f "$schema" ]; then
    printf 'trellis: machine schema missing at %s\n' "$schema" >&2
    return "$TRELLIS_EX_STATE"
  fi
  # jq otherwise evaluates each input independently and -e reports only the
  # last result, allowing an earlier document to bypass the schema check.
  if ! jq -se 'length == 1 and (.[0] | type == "object")' "$cfg" >/dev/null 2>&1; then
    printf 'trellis: config is not valid JSON object: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi

  if ! jq -e '
    def no_machine_controls:
      type == "string" and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def absolute_safe_path:
      no_machine_controls
      and startswith("/")
      and length >= 2
      and (startswith("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    def closed_object($required; $optional):
      type == "object"
      and ((keys_unsorted - ($required + $optional)) | length == 0)
      and (($required - keys_unsorted) | length == 0);
    def fleet_name:
      no_machine_controls and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def version:
      no_machine_controls and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$");
    def fleet_config:
      closed_object(["discovery_roots"]; ["shared_infra_root"])
      and (.discovery_roots | type == "array" and length >= 1)
      and ([.discovery_roots[] | absolute_safe_path] | all)
      and ((.discovery_roots | unique | length) == (.discovery_roots | length))
      and ((has("shared_infra_root") | not) or (.shared_infra_root | absolute_safe_path));

    # The heavy supervisor owns slot typing (spec 054). A bad
    # process_gate_slots value must reach it for diagnosis and a cap of 1.
    # The Stop hook alone types projects (spec 072).
    closed_object(["schema_version", "source_root", "release_remote", "active_cli_release", "default_fleet", "fleets"]; ["$schema", "heavy_slots", "heavy_light_slots", "process_gate_slots", "projects"])
    and ((has("$schema") | not) or (.["$schema"] | no_machine_controls and length > 0))
    and .schema_version == 1
    and (.source_root | absolute_safe_path)
    and (.release_remote | no_machine_controls and length > 0)
    and (.active_cli_release | version)
    and (.default_fleet | fleet_name)
    and (.fleets | type == "object" and length >= 1)
    and ([.fleets | keys[] | fleet_name] | all)
    and (.fleets[.default_fleet] != null)
    and ([.fleets[] |
      fleet_config
    ] | all)
  ' "$cfg" >/dev/null 2>&1; then
    printf 'trellis: machine config failed schema-aware validation: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi

  chmod 600 "$cfg" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  return 0
}

trellis_home_atomic_write_json() {
  local dest src dir base tmp code
  dest="$1"
  src="$2"
  trellis_home_require_jq || return "$?"
  trellis_home_require_absolute_safe_path "machine config" "$dest" || return "$?"
  if [ -L "$dest" ]; then
    printf 'trellis: refusing to replace symlinked machine config: %s\n' "$dest" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    printf 'trellis: machine config destination must be a regular file: %s\n' "$dest" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -L "$src" ] || [ ! -f "$src" ]; then
    printf 'trellis: machine config proposal must be a regular file: %s\n' "$src" >&2
    return "$TRELLIS_EX_STATE"
  fi
  dir="$(dirname "$dest")"
  base="$(basename "$dest")"
  if [ -L "$dir" ]; then
    printf 'trellis: refusing symlinked machine config directory: %s\n' "$dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$dir" ]; then
    printf 'trellis: machine config directory is unavailable: %s\n' "$dir" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  tmp="$(mktemp "$dir/.${base}.tmp.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"

  if ! jq -S . "$src" > "$tmp"; then
    rm -f "$tmp"
    printf 'trellis: refusing to write invalid JSON to %s\n' "$dest" >&2
    return "$TRELLIS_EX_STATE"
  fi
  chmod 600 "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  trellis_home_validate_config "$tmp" || {
    code="$?"
    rm -f "$tmp"
    return "$code"
  }
  mv "$tmp" "$dest" || {
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  chmod 600 "$dest" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  return 0
}

trellis_home_resolve_fleet() {
  local explicit config fleet
  explicit="${1:-}"
  config="${2:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    fleet="$explicit"
  elif [ -n "${TRELLIS_FLEET:-}" ]; then
    fleet="$TRELLIS_FLEET"
  elif [ -n "$config" ] && [ -f "$config" ]; then
    fleet="$(jq -r '.default_fleet // empty' "$config" 2>/dev/null || true)"
  else
    fleet="personal"
  fi
  trellis_home_require_fleet_name "$fleet" || return "$?"
  printf '%s\n' "$fleet"
}

trellis_home_resolve_release() {
  local explicit config source_root release
  explicit="${1:-}"
  config="${2:-}"
  source_root="${3:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    release="$explicit"
  elif [ -n "${TRELLIS_RELEASE:-}" ]; then
    release="$TRELLIS_RELEASE"
  elif [ -n "$config" ] && [ -f "$config" ]; then
    release="$(jq -r '.active_cli_release // empty' "$config" 2>/dev/null || true)"
  else
    release=""
  fi
  if [ -z "$release" ] && [ -n "$source_root" ] && [ -f "$source_root/core-rules/VERSION" ]; then
    release="$(sed -n '1p' "$source_root/core-rules/VERSION" | tr -d '[:space:]')"
  fi
  if [ -z "$release" ]; then
    printf 'trellis: active CLI release is required; pass --active-cli-release or set TRELLIS_RELEASE\n' >&2
    return "$TRELLIS_EX_USAGE"
  fi
  if ! trellis_home_is_valid_semver "$release"; then
    printf 'trellis: active CLI release is not SemVer: %s\n' "$release" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  printf '%s\n' "$release"
}

trellis_home_resolve_source_root() {
  local explicit config source
  explicit="${1:-}"
  config="${2:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    source="$explicit"
  elif [ -n "${TRELLIS_SOURCE_ROOT:-}" ]; then
    source="$TRELLIS_SOURCE_ROOT"
  elif [ -n "$config" ] && [ -f "$config" ]; then
    source="$(jq -r '.source_root // empty' "$config" 2>/dev/null || true)"
  else
    source=""
  fi
  if [ -z "$source" ]; then
    printf 'trellis: source root is required; pass --source or set TRELLIS_SOURCE_ROOT\n' >&2
    return "$TRELLIS_EX_USAGE"
  fi
  trellis_home_require_source_root "$source"
}

trellis_home_default_release_remote() {
  local explicit config source_root remote
  explicit="${1:-}"
  config="${2:-}"
  source_root="${3:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    trellis_home_require_safe_text "release remote" "$explicit" || return "$?"
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -n "$config" ] && [ -f "$config" ]; then
    remote="$(jq -r '.release_remote // empty' "$config" 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      printf '%s\n' "$remote"
      return 0
    fi
  fi
  if [ -n "$source_root" ] && [ -f "$source_root/trellis.config.json" ]; then
    remote="$(jq -r '.template.remote // empty' "$source_root/trellis.config.json" 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      trellis_home_require_safe_text "release remote" "$remote" || return "$?"
      printf '%s\n' "$remote"
      return 0
    fi
  fi
  if [ -n "$source_root" ] && git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1; then
    remote="$(git -C "$source_root" config --get remote.origin.url 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      trellis_home_require_safe_text "release remote" "$remote" || return "$?"
      printf '%s\n' "$remote"
      return 0
    fi
  fi
  trellis_home_require_safe_text "release remote" "$source_root" || return "$?"
  printf '%s\n' "$source_root"
}

trellis_home_parent_dir() {
  local path
  path="$1"
  dirname "$path"
}

trellis_home_publish_file_noreplace() {
  local tmp dest
  tmp="$1"
  dest="$2"

  case "$(uname -s)" in
    Darwin) ln -h "$tmp" "$dest" 2>/dev/null ;;
    *) ln -n "$tmp" "$dest" 2>/dev/null ;;
  esac
  if [ "$?" -eq 0 ]; then
    if ! rm -f "$tmp"; then
      printf 'trellis: launcher published but temporary file could not be removed: %s\n' "$tmp" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    return 0
  fi
  rm -f "$tmp"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    printf 'trellis: refusing to overwrite existing launcher: %s\n' "$dest" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  printf 'trellis: could not publish launcher at %s\n' "$dest" >&2
  return "$TRELLIS_EX_UNAVAILABLE"
}

# One policy, embedded as data into the isolated Python used by both the pair
# publisher and doctor. No project-selected module or candidate code is run.
# A backend may silently return incomplete NSS enumerations, including when
# directory-service enumeration is disabled or a backend fails. On macOS,
# nested/synthesized group members may also be absent from gr_mem. These
# undisclosed accounts and memberships cannot be proven absent by this policy.
trellis_home_launcher_directory_policy_python() {
  /bin/cat <<'PY'
import grp, os, pwd
def launcher_directory_safe(s):
    uid=os.getuid(); gid=s.st_gid
    if s.st_uid != uid or s.st_mode & 0o002:
        return False
    if not s.st_mode & 0o020:
        return True
    try:
        if gid == 0 or gid != os.getgid():
            return False
        user=pwd.getpwuid(uid); group=grp.getgrgid(gid)
        if user.pw_gid != gid or group.gr_gid != gid or group.gr_name != user.pw_name:
            return False
        accounts=pwd.getpwall(); groups=grp.getgrall()
        if not any(p.pw_uid==uid and p.pw_gid==gid and p.pw_name==user.pw_name for p in accounts):
            return False
        if not any(g.gr_gid==gid and g.gr_name==group.gr_name for g in groups):
            return False
        if any(p.pw_gid==gid and (p.pw_uid!=uid or p.pw_name!=user.pw_name) for p in accounts):
            return False
        if any(m!=user.pw_name for m in group.gr_mem):
            return False
        return not any(m!=user.pw_name for g in groups if g.gr_gid==gid for m in g.gr_mem)
    except Exception:
        # Reported lookup/enumeration failures must never grant write trust.
        return False
PY
}

# Publish a pair using the already trusted shell verifier, never by executing
# the candidate binary or any helper taken from the candidate release.
# Optional HOME/RELEASE on install_launcher selects this installed-only path.
trellis_home_publish_native_launcher() {
  local template="$1" dest="$2" home="$3" release="$4" release_dir action target native_version native_digest launcher_policy
  trellis_home_require_absolute_safe_path 'native companion' "$home" || return "$?"
  release_dir="$(TRELLIS_HOME="$home" release_store_locate "$release")" || return "$?"
  # Bypass stamp-only locate: publication requires a fresh byte verification.
  TRELLIS_HOME="$home" release_store_verify_path "$release_dir" "$release" || return "$?"
  target=''
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
  esac
  if [ -n "$target" ]; then
    native_digest="$(jq -r --arg target "$target" '.assets[$target].sha256 // empty' "$release_dir/payload/core-rules/native/artifacts.json")" || return 4
    native_version="$(jq -r '.version' "$release_dir/payload/core-rules/native/artifacts.json")" || return 4
    if [ -n "$native_digest" ]; then
      trellis_home_require_absolute_safe_path 'native companion' \
        "$home/bin/native/$native_version/$target/$native_digest/trellis-hooks" || return "$?"
    fi
  fi
  launcher_policy="$(trellis_home_launcher_directory_policy_python)" || return "$TRELLIS_EX_STATE"
  action="$( { printf '%s\n' "$launcher_policy"; /bin/cat <<'PY'
import ctypes, errno, hashlib, json, os, platform, re, secrets, stat, subprocess, sys
from pathlib import Path

template, destination, home, release_dir = map(Path, sys.argv[1:])
class Refusal(Exception):
    def __init__(self, message, code=4):
        super().__init__(message); self.code = code
def require(ok, message, code=4):
    if not ok:
        raise Refusal(message, code)
def sha(data):
    return hashlib.sha256(data).hexdigest()
def ident(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
def no_acl(fd):
    if sys.platform == 'darwin':
        libc = ctypes.CDLL(None, use_errno=True)
        libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.acl_get_fd_np.restype = ctypes.c_void_p
        libc.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
        libc.acl_get_entry.restype = ctypes.c_int
        libc.acl_free.argtypes = [ctypes.c_void_p]
        libc.acl_free.restype = ctypes.c_int
        ctypes.set_errno(0); acl = libc.acl_get_fd_np(fd, 0x100)
        if not acl:
            require(ctypes.get_errno() == errno.ENOENT, 'ACL inspection unavailable', 5)
            return
        entry = ctypes.c_void_p()
        result = libc.acl_get_entry(acl, 0, ctypes.byref(entry))
        freed = libc.acl_free(acl)
        # Darwin returns 0 when an entry exists, not when the ACL is empty.
        require(result == 0 and entry.value and freed == 0, 'ACL inspection failed', 5)
        raise Refusal('ACL on pair entry')
    else:
        for key in ('system.posix_acl_access', 'system.posix_acl_default'):
            try:
                os.getxattr(fd, key)
            except OSError as error:
                require(error.errno == errno.ENODATA, 'ACL inspection unavailable', 5)
            else:
                raise Refusal('ACL on pair entry')
def directory(path, private=False, create=False, launcher=False):
    path = Path(path)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = child
        s = os.fstat(fd)
        require(s.st_uid == os.getuid(), 'pair directory is not owned', 3)
        if private:
            require(stat.S_IMODE(s.st_mode) == 0o700, 'pair directory is not private')
        elif launcher:
            require(launcher_directory_safe(s), 'launcher directory is writable by others')
        else:
            require(not s.st_mode & 0o022, 'pair source directory is writable by others')
        no_acl(fd)
        return fd
    except BaseException:
        os.close(fd); raise
def read_at(parent, name, mode=None):
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    require(stat.S_ISREG(before.st_mode), 'pair source is not a regular file', 3)
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        opened = os.fstat(fd); no_acl(fd)
        require(ident(before) == ident(opened), 'pair source changed while opening')
        if mode is not None:
            require(stat.S_IMODE(opened.st_mode) == mode and opened.st_uid == os.getuid(), 'pair entry mode/owner mismatch')
        chunks = []
        while True:
            chunk = os.read(fd, 1048576)
            if not chunk:
                break
            chunks.append(chunk)
        require(ident(before) == ident(os.fstat(fd)) == ident(os.stat(name, dir_fd=parent, follow_symlinks=False)), 'pair source changed while reading')
        return b''.join(chunks), before
    finally:
        os.close(fd)
def read_path(path, mode=None):
    fd = directory(path.parent)
    try:
        return read_at(fd, path.name, mode)
    finally:
        os.close(fd)
def closed(d, keys):
    require(type(d) is dict and set(d) == set(keys.split()), 'invalid native manifest fields')
def pairs(items):
    d = {}
    for k, v in items:
        require(k not in d, 'duplicate native manifest key'); d[k] = v
    return d
def install_immutable(parent, name, data):
    try:
        existing, _ = read_at(parent, name, 0o500)
    except FileNotFoundError:
        pass
    else:
        require(existing == data, 'changed immutable pair entry', 3)
        return
    temp = '.pair.' + secrets.token_hex(16)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data); out.flush(); os.fchmod(out.fileno(), 0o500); os.fsync(out.fileno())
        # No-replace publication; an executable inode is never rewritten.
        try:
            os.link(temp, name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
        except FileExistsError:
            # Another publisher may have won after our initial lookup. Its
            # immutable bytes must pass exactly the same comparison as a warm
            # lookup; a collision is never permission to overwrite the inode.
            existing, _ = read_at(parent, name, 0o500)
            require(existing == data, 'changed immutable pair entry', 3)
        os.fsync(parent)
    finally:
        os.unlink(temp, dir_fd=parent)
def private_chain(relative):
    current = home
    root = directory(current, private=True); os.close(root)
    for component in relative.split('/'):
        current /= component
        fd = directory(current, private=True, create=True); os.close(fd)
    return current

temps = []
companion_identity = None
try:
    require(str(home).startswith('/') and '=' not in str(home) and not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in str(home)), 'unsafe native companion path', 2)
    # Resolve only caller-trusted roots once. No-follow traversal still applies
    # to every release/native descendant and to each published leaf beneath
    # these roots; symlinked ancestors (e.g. /var or ~/.local/bin) are portable.
    input_home = home
    home = home.resolve(strict=True)
    try:
        release_dir = home / release_dir.relative_to(input_home)
    except ValueError:
        require(release_dir.is_relative_to(home), 'release is outside trusted home')
    template = template.parent.resolve(strict=True) / template.name
    destination = destination.parent.resolve() / destination.name
    require('=' not in str(home) and not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in str(home)), 'unsafe resolved native companion path', 2)
    payload = release_dir / 'payload'
    template_bytes, _ = read_path(template)
    candidate, _ = read_path(payload / 'scripts/trellis-launcher.sh')
    require(template_bytes == candidate, 'native launcher must match installed release template', 3)
    record_bytes, _ = read_path(release_dir / 'release.json')
    record = json.loads(record_bytes)
    tree = {entry['path']: entry for entry in record['tree']}
    def trusted(relative):
        data, mode = read_path(payload / relative)
        entry = tree.get(relative, {})
        oid = hashlib.sha1(('blob %d\0' % len(data)).encode() + data).hexdigest()
        require(entry.get('oid') == oid and entry.get('mode') == ('100755' if mode.st_mode & 0o111 else '100644'), 'candidate bytes changed after full verification')
        return data
    require(candidate == trusted('scripts/trellis-launcher.sh'), 'candidate launcher changed')
    d = json.loads(trusted('core-rules/native/artifacts.json'), object_pairs_hook=pairs)
    closed(d, 'schema_version version source_commit generation inputs toolchain install_path adapter assets')
    numeric = r'(?:0|[1-9][0-9]*)'
    prerelease = r'(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    semver = numeric + r'\.' + numeric + r'\.' + numeric + r'(?:-' + prerelease + r'(?:\.' + prerelease + r')*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
    require(type(d['schema_version']) is int and d['schema_version'] == 1 and type(d['version']) is str and re.fullmatch(semver, d['version']) and d['version'] == record['version'], 'invalid native version')
    require(d['install_path'] == 'bin/native/{version}/{target}/{sha256}/trellis-hooks', 'invalid native install path')
    require(type(d['assets']) is dict and bool(d['assets']) and set(d['assets']) <= {'aarch64-apple-darwin', 'x86_64-unknown-linux-musl', 'aarch64-unknown-linux-musl'}, 'invalid native targets')
    machine = platform.machine(); system = platform.system()
    target = {('Darwin', 'arm64'): 'aarch64-apple-darwin', ('Linux', 'x86_64'): 'x86_64-unknown-linux-musl', ('Linux', 'aarch64'): 'aarch64-unknown-linux-musl'}.get((system, machine))
    entry = ''; digest = ''; version = ''
    if target in d['assets']:
        a = d['assets'][target]; closed(a, 'path size sha256 format signature minimum_os')
        require(a['path'] == target + '/trellis-hooks', 'invalid companion asset path')
        require(type(a['sha256']) is str and re.fullmatch('[0-9a-f]{64}', a['sha256']), 'invalid companion digest')
        data = trusted('core-rules/native/' + a['path'])
        require(type(a['size']) is int and a['size'] == len(data) and sha(data) == a['sha256'], 'companion digest/size mismatch')
        darwin = target.endswith('apple-darwin')
        require((a['format'], a['signature'], a['minimum_os']) == (('mach-o', 'adhoc', '13.0') if darwin else ('elf-static', 'none', None)), 'invalid companion metadata')
        if darwin:
            require(data[:8] == b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01', 'invalid companion Mach-O architecture')
        else:
            require(data[:6] == b'\x7fELF\x02\x01' and int.from_bytes(data[18:20], 'little') == (62 if target.startswith('x86_64') else 183), 'invalid companion ELF architecture')
            off = int.from_bytes(data[32:40], 'little'); width = int.from_bytes(data[54:56], 'little'); count = int.from_bytes(data[56:58], 'little')
            require(width == 56 and count > 0 and off + width*count <= len(data), 'invalid companion ELF program headers')
            require(all(int.from_bytes(data[off+i*width:off+i*width+4], 'little') != 3 for i in range(count)), 'dynamic companion ELF')
        digest = a['sha256']; version = d['version']
        companion_dir = private_chain('bin/native/' + version + '/' + target + '/' + digest)
        entry = str(companion_dir / 'trellis-hooks')
        require('=' not in entry and not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in entry), 'unsafe native companion path', 2)
        fd = directory(companion_dir, private=True)
        try:
            install_immutable(fd, 'trellis-hooks', data)
            installed, before = read_at(fd, 'trellis-hooks', 0o500)
            require(sha(installed) == digest, 'installed companion digest mismatch')
            if darwin:
                require(subprocess.run(['/usr/bin/codesign', '--verify', '--strict', entry], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE).returncode == 0, 'companion signature verification failed')
            require(ident(before) == ident(os.stat('trellis-hooks', dir_fd=fd, follow_symlinks=False)), 'companion identity changed during signature verification')
            companion_identity = (ident(os.fstat(fd)), ident(before))
        finally:
            os.close(fd)
    quote = lambda s: "'" + s.replace("'", "'\\''") + "'"
    rendered = candidate.decode('utf-8')
    for key, value in (('launcher_native_entry', entry), ('launcher_native_sha256', digest), ('launcher_native_version', version)):
        needle = key + "=''\n"
        require(rendered.count(needle) == 1, 'candidate launcher has no unique pin slot')
        rendered = rendered.replace(needle, key + '=' + quote(value) + '\n')
    rendered = rendered.encode()
    # Retain an immutable copy as the ownership proof for future pair switches.
    ledger = private_chain('bin/launchers/' + sha(rendered))
    fd = directory(ledger, private=True)
    try:
        install_immutable(fd, 'trellis', rendered)
    finally:
        os.close(fd)
    parent = directory(destination.parent, create=True, launcher=True)
    try:
        try:
            old, before = read_at(parent, destination.name)
        except FileNotFoundError:
            old = None; before = None
        if old == rendered:
            require(before.st_mode & 0o111, 'installed launcher is not executable', 3)
            print('retained'); raise SystemExit(0)
        if old is not None and old != candidate:
            old_ledger = home / 'bin/launchers' / sha(old) / 'trellis'
            try:
                owned_parent = directory(old_ledger.parent, private=True)
                try:
                    owned, _ = read_at(owned_parent, 'trellis', 0o500)
                finally:
                    os.close(owned_parent)
            except (FileNotFoundError, OSError):
                raise Refusal('refusing changed/custom launcher collision', 3)
            require(owned == old, 'refusing changed/custom launcher collision', 3)
        temp = '.trellis.pair.' + secrets.token_hex(16)
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        temps.append((os.dup(parent), temp))
        with os.fdopen(fd, 'wb') as out:
            out.write(rendered); out.flush(); os.fchmod(out.fileno(), 0o755); os.fsync(out.fileno())
        # Reopen the absolute entry beneath no-follow directories immediately
        # before publishing the pin, not merely the retained digest-directory fd.
        if companion_identity is not None:
            check = directory(companion_dir, private=True)
            try:
                current, file_identity = read_at(check, 'trellis-hooks', 0o500)
                require(ident(os.fstat(check)) == companion_identity[0] and ident(file_identity) == companion_identity[1] and sha(current) == digest, 'companion path identity changed before publication')
            finally:
                os.close(check)
        check = directory(destination.parent, launcher=True)
        try:
            require((os.fstat(check).st_dev, os.fstat(check).st_ino) == (os.fstat(parent).st_dev, os.fstat(parent).st_ino), 'launcher directory identity changed before publication')
        finally:
            os.close(check)
        if before is None:
            os.link(temp, destination.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
        else:
            require(ident(before) == ident(os.stat(destination.name, dir_fd=parent, follow_symlinks=False)), 'launcher changed before publication', 3)
            os.rename(temp, destination.name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
        print('installed')
    finally:
        os.close(parent)
except Refusal as error:
    print('trellis: ' + str(error), file=sys.stderr); raise SystemExit(error.code)
except (OSError, ValueError, KeyError, TypeError) as error:
    print('trellis: paired publication refused: ' + str(error), file=sys.stderr); raise SystemExit(4)
finally:
    for fd, name in temps:
        try:
            os.unlink(name, dir_fd=fd)
        except FileNotFoundError:
            pass
        os.close(fd)
PY
  } | python3 -I - "$template" "$dest" "$home" "$release_dir" )" || return "$?"
  case "$action" in
    installed|retained) ;;
    *) printf 'trellis: paired publisher returned no valid result\n' >&2; return "$TRELLIS_EX_UNAVAILABLE" ;;
  esac
  TRELLIS_HOME_LAUNCHER_ACTION="$action"
}

trellis_home_install_launcher() {
  local template dest dest_dir tmp
  template="$1"
  dest="$2"
  TRELLIS_HOME_LAUNCHER_ACTION=""

  if [ "$#" -eq 4 ] && {
    [ -e "$3/releases/$4/payload/core-rules/native/artifacts.json" ] ||
    [ -L "$3/releases/$4/payload/core-rules/native/artifacts.json" ];
  }; then
    trellis_home_publish_native_launcher "$template" "$dest" "$3" "$4"
    return "$?"
  fi

  trellis_home_require_absolute_safe_path "launcher template" "$template" || return "$?"
  if [ -L "$template" ] || [ ! -f "$template" ]; then
    printf 'trellis: launcher template not found: %s\n' "$template" >&2
    printf 'trellis: pass --launcher-template PATH once scripts/trellis-launcher.sh exists, or use --no-install-launcher for config-only setup\n' >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  trellis_home_require_absolute_safe_path "launcher destination" "$dest" || return "$?"

  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    printf 'trellis: refusing non-regular launcher destination: %s\n' "$dest" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -f "$dest" ]; then
    if cmp -s "$template" "$dest"; then
      chmod 755 "$dest" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
      TRELLIS_HOME_LAUNCHER_ACTION="retained"
      return 0
    fi
    printf 'trellis: refusing to overwrite existing launcher: %s\n' "$dest" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi

  dest_dir="$(dirname "$dest")"
  if [ -L "$dest_dir" ]; then
    printf 'trellis: refusing symlinked launcher directory: %s\n' "$dest_dir" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -e "$dest_dir" ] && [ ! -d "$dest_dir" ]; then
    printf 'trellis: launcher directory is not a directory: %s\n' "$dest_dir" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ ! -d "$dest_dir" ]; then
    (umask 022; mkdir -p "$dest_dir") || return "$TRELLIS_EX_UNAVAILABLE"
    if [ -L "$dest_dir" ] || [ ! -d "$dest_dir" ]; then
      printf 'trellis: refusing invalid launcher directory: %s\n' "$dest_dir" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    chmod 755 "$dest_dir" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  tmp="$(mktemp "$dest_dir/.trellis.launcher.tmp.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! cp "$template" "$tmp"; then
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  chmod 755 "$tmp" || {
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  trellis_home_publish_file_noreplace "$tmp" "$dest" || return "$?"
  # shellcheck disable=SC2034  # Out-parameter: the caller reads it after this function returns.
  TRELLIS_HOME_LAUNCHER_ACTION="installed"
  return 0
}
