#!/usr/bin/env bash

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  _ATTACHMENT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
  # shellcheck source=scripts/lib/trellis-home.sh
  source "$_ATTACHMENT_DIR/trellis-home.sh"
  # Full detach commits clear their exact registry identity before owner unlink.
  # shellcheck source=scripts/lib/local-registry.sh
  source "$_ATTACHMENT_DIR/local-registry.sh"
  # shellcheck source=scripts/lib/semver.sh
  source "$_ATTACHMENT_DIR/semver.sh"
  # shellcheck source=scripts/lib/settings-hooks-merge.sh
  source "$_ATTACHMENT_DIR/settings-hooks-merge.sh"
fi

# Byte-identical copies of the trellis-home.sh path, digest and NUL-field
# helpers (scripts/tests/helpers/builtin-differential.bash compares them).
# This file must stand alone: the managed-hook generator and the owner-bound
# verifier source it with TRELLIS_LIBS_PRELOADED=1 and nothing else, and a
# health check sources a release's copy over another release's trellis-home.

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

# The BSD and GNU stat forms MUST be captured separately. GNU `stat -f` is
# --file-system: `stat -f %Lp PATH` treats the format as a missing operand and
# still prints a whole filesystem block for PATH on stdout before exiting
# non-zero. Chained inside one command substitution that block concatenates with
# the GNU mode, so every mode comparison on Linux compared against
# "  File: ...\n700" and failed closed — attach exited non-zero with no
# diagnostic. Exit status alone is not a sufficient probe for the same reason,
# so the BSD result is shape-checked (1-4 octal digits) before it is trusted.
_attachment_stat_mode() {
  local path=$1 candidate
  candidate=$(stat -f %Lp "$path" 2>/dev/null) || candidate=''
  case "$candidate" in
    ''|*[!0-7]*) candidate='' ;;
  esac
  [ "${#candidate}" -ge 1 ] && [ "${#candidate}" -le 4 ] || candidate=''
  if [ -z "$candidate" ]; then
    candidate=$(stat -c %a "$path" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$candidate"
}

_attachment_mode() {
  _attachment_stat_mode "$1"
}

_attachment_mode_matches() {
  local path=$1 expected=$2 actual
  actual=$(_attachment_mode "$path") || return 1
  [ "$actual" = "${expected#0}" ]
}

_attachment_hash() {
  local output digest
  output=$(shasum -a 256 "$1" 2>/dev/null) || output=$(sha256sum "$1" 2>/dev/null) || return 1
  case "$output" in \\*) output=${output:1} ;; esac
  digest=${output%% *}
  trellis_is_sha256_hex "$digest" || return 1
  printf '%s\n' "$digest"
}

_attachment_hash_text() {
  local output
  output=$(printf '%s' "$1" | shasum -a 256 2>/dev/null) ||
    output=$(printf '%s' "$1" | sha256sum 2>/dev/null) || return 1
  printf '%s\n' "${output%% *}"
}

_attachment_fs_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

# The kernel name cannot change within a process. Resolve it in the calling
# shell, not inside $(...), so later checks and their subshells reuse it.
# Reset on every source so an inherited value is never trusted.
_ATTACHMENT_OS_NAME="" _ATTACHMENT_OS_NAME_SET=0
_attachment_os_name_cache() {
  [ "$_ATTACHMENT_OS_NAME_SET" = 1 ] && return 0
  _ATTACHMENT_OS_NAME="$(uname -s 2>/dev/null)" || _ATTACHMENT_OS_NAME=""
  _ATTACHMENT_OS_NAME_SET=1
}

# Descriptor paths such as /dev/fd/N expose the descriptor's target through a
# symlink on GNU/Linux, while Darwin's /dev/fd filesystem presents a proxy
# vnode whose device differs from the opened file.  GNU stat can dereference
# the path directly; Darwin needs fstat on the inherited descriptor.
_attachment_fd_fs_identity() {
  local path=$1 descriptor
  case "$path" in
    /dev/fd/[0-9]*) descriptor=${path##*/} ;;
    *) return 1 ;;
  esac
  _attachment_os_name_cache
  case "$_ATTACHMENT_OS_NAME" in
    Darwin)
      command -v perl >/dev/null 2>&1 || return 1
      perl -e 'open my $handle, "<&=$ARGV[0]" or exit 1; my @stat = stat($handle) or exit 1; print "$stat[0]:$stat[1]\n"' "$descriptor"
      ;;
    *)
      stat -Lc '%d:%i' "$path" 2>/dev/null || stat -Lf '%d:%i' "$path" 2>/dev/null
      ;;
  esac
}


_attachment_capture_current_pid() {
  local directory=$1 pid_file
  pid_file=$(mktemp "$directory/.attachment-pid.XXXXXX") || return 1
  /bin/sh -c 'printf "%s\n" "$PPID" > "$1"' attachment-pid "$pid_file" || {
    rm -f "$pid_file"
    return 1
  }
  IFS= read -r _ATTACHMENT_PROCESS_PID < "$pid_file" || {
    rm -f "$pid_file"
    return 1
  }
  rm "$pid_file" || return 1
  case "$_ATTACHMENT_PROCESS_PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

# Delegates to the canonical helper (scripts/lib/trellis-home.sh), which
# attachment.sh already sources. Same token, same "any nonzero is
# indeterminate" contract for every caller below.
_attachment_process_birth() {
  trellis_process_birth "$1" 2>/dev/null
}

_attachment_symlink_matches() {
  local path=$1 expected=$2 marker actual newline
  marker=__TRELLIS_READLINK_END__
  newline='
'
  actual=$({ readlink "$path" || exit 1; printf '%s' "$marker"; }) || return 1
  actual=${actual%"$marker"}
  case "$actual" in
    *"$newline") actual=${actual%"$newline"} ;;
    *) return 1 ;;
  esac
  [ "$actual" = "$expected" ]
}

# True when the destination of a planned symlink leaf holds a regular file the
# PROJECT authored, which attach defers to instead of refusing. Called with the
# destination followed by every canonical source the planned link could resolve
# to — for a `source_scope: project` leaf that is both the project file and the
# payload fallback, because either one being copied in place is a dropping.
#
# Three conditions, all necessary:
#
#   * a regular file, not a symlink. A symlink destination is the
#     `pre-existing-symlink` shape and is decided by link text alone; a
#     directory or device is neither and stays a refusal.
#   * non-empty. A zero-byte file carries no authored content — it is a
#     leftover from an interrupted write, and deferring to it would leave the
#     harness permanently pointed at nothing.
#   * not byte-identical to any canonical source. An exact copy of the content
#     the link would have provided is a stale materialization of managed
#     content, not something the project wrote: deferring would freeze it
#     against every later release. `cmp` is content equality, so a copy that
#     has since been edited by even one byte is authored and does defer.
#
# Failing any of them leaves the leaf in the plan, so the destination preflight
# refuses it BY NAME rather than silently overwriting or silently keeping it.
_attachment_project_authored_file() {
  local path=$1 candidate rc
  shift
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ -s "$path" ] || return 1
  for candidate in "$@"; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] || continue
    if cmp -s "$path" "$candidate"; then
      return 1
    else
      rc=$?
      [ "$rc" -eq 1 ] || return 1
    fi
  done
  return 0
}

# The `project-authored-file` deferral decision for one planned symlink leaf,
# shared verbatim by attach (which records it) and by diagnosis (which
# re-derives it). One reader means the two can never drift into disagreeing
# about which destinations are project-owned.
#
# A `source_scope: project` leaf can resolve to the project file or, when that
# file is absent, to the payload fallback, so both count as canonical sources
# regardless of which one the plan currently targets: a copy of either is a
# dropping, and which one it copies says nothing about intent.
_attachment_symlink_destination_authored() {
  local record=$1 root=$2 payload=$3 path=$4 scope source fallback
  scope=$(printf '%s\n' "$record" | jq -r '.source_scope') || return 1
  source=$(printf '%s\n' "$record" | jq -r '.source') || return 1
  if [ "$scope" = project ]; then
    fallback=$(printf '%s\n' "$record" | jq -r '.fallback_source') || return 1
    _attachment_project_authored_file "$root/$path" "$root/$source" "$payload/$fallback"
  else
    _attachment_project_authored_file "$root/$path" "$payload/$source"
  fi
}

# True when $1 holds a C-locale control byte other than newline: what
# `grep '[[:cntrl:]]'` found here, line by line, in the C locale every
# production caller runs in. The bytes are listed, not ranged, so the match
# holds in any locale and in Bash 3.2.
_attachment_has_controls() {
  case "$1" in
    *[$'\001\002\003\004\005\006\007\010\011\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177']*) return 0 ;;
  esac
  return 1
}

_attachment_valid_absolute() {
  local value=$1
  case "$value" in
    /*) ;;
    *) return 1 ;;
  esac
  [ "$value" != "/" ] || return 1
  case "$value" in
    *//*|*/./*|*/../*|*/.|*/..|./*|../*|*/) return 1 ;;
  esac
  _attachment_has_controls "$value" && return 1
  return 0
}

_attachment_valid_relative() {
  local value=$1
  [ -n "$value" ] || return 1
  case "$value" in
    /*|*//*|*/./*|*/../*|.|..|*/.|*/..|./*|../*|*/) return 1 ;;
  esac
  _attachment_has_controls "$value" && return 1
  return 0
}

_attachment_no_symlink_components() {
  local value=$1 allow_missing_final=${2:-0} part current index last
  local -a components
  _attachment_valid_absolute "$value" || return 1
  IFS=/ read -r -a components <<< "${value#/}"
  current=/
  last=$((${#components[@]} - 1))
  index=0
  while [ "$index" -le "$last" ]; do
    part=${components[$index]}
    [ -n "$part" ] || return 1
    if [ "$current" = / ]; then
      current="/$part"
    else
      current="$current/$part"
    fi
    [ ! -L "$current" ] || return 1
    if [ ! -e "$current" ]; then
      [ "$allow_missing_final" -eq 1 ] && [ "$index" -eq "$last" ] && return 0
      return 1
    fi
    if [ "$index" -lt "$last" ]; then
      [ -d "$current" ] || return 1
    fi
    index=$((index + 1))
  done
  return 0
}

# Diagnostics for refusals that were previously a bare `return 3`. Always
# stderr: every caller of these functions captures stdout.
_attachment_diag() {
  printf 'trellis: %s\n' "$1" >&2
}

# One stderr line per refusal: `trellis <action>: refused (<code>): <path>`.
# Entry points name the action in ATTACHMENT_ACTION (detach, adopt, attach) and
# library sites pass it through; a caller that names no action stays silent, as
# every refusal was before spec 053.
_attachment_refuse() {
  [ -n "$1" ] || return 0
  printf 'trellis %s: refused (%s): %s\n' "$1" "$2" "$(_attachment_visible "$3")" >&2
}

# A worktree attachment lock that is held (3) or unreadable (4) was a bare
# exit from detach and recover. Names it and passes the status through.
_attachment_lock_refuse() {
  local status=$1 link pid
  link=$(_attachment_lock_path "$2" "$3" "$4")
  case "$status" in
    3)
      pid=$(jq -r '.pid' "$(dirname "$link")/$(readlink "$link")/owner.json" 2>/dev/null) || pid=unknown
      _attachment_refuse "${ATTACHMENT_ACTION:-}" attachment-lock-held \
        "$link; Trellis process ${pid:-unknown} holds this worktree's attachment lock; retry when it exits" ;;
    4)
      _attachment_refuse "${ATTACHMENT_ACTION:-}" attachment-lock-unreadable \
        "$link; it is not a well-formed Trellis lock; inspect it, and remove it only when no Trellis process is running" ;;
  esac
  return "$status"
}

# A detach journal step that met a bare conflict: name the step, keep the journal.
_attachment_detach_step_refuse() {
  local status=$1 code=$2 journal=$3 path
  [ "$status" -eq 3 ] || return "$status"
  case "$code" in
    render-conflict)
      path=$(jq -r '.original_owner.worktree_root + "/" + ((.external.render_pending.render // .external.renders[.external.render_phase]) | .path)' "$journal" 2>/dev/null) || path=unknown
      _attachment_refuse "${ATTACHMENT_ACTION:-}" render-conflict \
        "$path; it or its directory no longer matches detach journal $journal; restore the bytes Trellis rendered (journal external.renders[].after_base64), then rerun trellis recover" ;;
    *)
      _attachment_refuse "${ATTACHMENT_ACTION:-}" "$code" \
        "$journal; its recorded owner commit or phase does not allow this step; keep the journal and run trellis doctor" ;;
  esac
  return "$status"
}

# Control characters as visible escapes (`\n`, `\r`, `\t`, else `\xHH`), so
# a path can never split a one-line diagnostic. Any other text is unchanged.
_attachment_visible() {
  local LC_ALL=C value=$1 out='' char i
  case "$value" in
    *[[:cntrl:]]*) ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    case "$char" in
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      [[:cntrl:]]) out+=$(printf '\\x%02x' "'$char") ;;
      *) out+=$char ;;
    esac
  done
  printf '%s' "$out"
}

# Classifies an owner record against Git's own worktree list for the checkout
# the record names, and prints one line: `live`, `missing`, `not-a-worktree`,
# or `undetermined <why>`. Attach and doctor share it, so they never disagree.
# Git keeps a worktree listed until it is pruned, so a listed root is live even
# while its directory is absent (an unmounted volume, a locked worktree);
# `prunable` does not change that. No list, no verdict: undetermined.
attachment_owner_orphan_reason() {
  local owner=$1 root common listed entry
  root=$(jq -r '.worktree_root | strings' "$owner" 2>/dev/null) || root=
  common=$(jq -r '.exclude.git_common_dir | strings' "$owner" 2>/dev/null) || common=
  if [ -z "$root" ] || [ -z "$common" ]; then
    printf 'undetermined owner record names no worktree root or common dir\n'
    return 0
  fi
  if [ ! -d "$common" ]; then
    printf 'undetermined git common dir %s is missing\n' "$common"
    return 0
  fi
  listed=$(git --git-dir="$common" -c safe.directory='*' worktree list --porcelain 2>/dev/null) || {
    printf 'undetermined git worktree list failed for %s\n' "$common"
    return 0
  }
  root=$(_attachment_orphan_canonical "$root")
  while IFS= read -r entry; do
    case "$entry" in 'worktree '*) ;; *) continue ;; esac
    if [ "$(_attachment_orphan_canonical "${entry#worktree }")" = "$root" ]; then
      printf 'live\n'
      return 0
    fi
  done <<< "$listed"
  if [ -e "$root" ] || [ -L "$root" ]; then
    printf 'not-a-worktree\n'
  else
    printf 'missing\n'
  fi
}

# Canonical form of an absolute path, existing or not: normalised lexically
# (no `//`, `.`, `..` or trailing `/`), then its nearest existing directory
# resolved with `pwd -P` and the remainder appended.
_attachment_orphan_canonical() {
  local part base physical rest=''
  local -a parts kept=()
  IFS=/ read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) [ "${#kept[@]}" -eq 0 ] || unset 'kept[${#kept[@]}-1]' ;;
      *) kept+=("$part") ;;
    esac
  done
  base=/
  [ "${#kept[@]}" -eq 0 ] || base="/$(IFS=/; printf '%s' "${kept[*]}")"
  while [ "$base" != / ] && [ ! -d "$base" ]; do
    rest="/$(basename "$base")$rest"
    base=$(dirname "$base")
  done
  if physical=$(CDPATH='' cd "$base" 2>/dev/null && pwd -P); then base=$physical; fi
  base="${base%/}$rest"
  printf '%s\n' "${base:-/}"
}

_attachment_canonical_dir() {
  local value=$1 actual
  _attachment_no_symlink_components "$value" 0 || return 1
  [ -d "$value" ] && [ ! -L "$value" ] || return 1
  actual=$(CDPATH='' cd "$value" && pwd -P) || return 1
  [ "$actual" = "$value" ]
}

# Prints the first symlinked path prefix of an existing absolute path.
# Returns 1 when no component is a symlink (or a component is missing — the
# caller classifies missing entries separately).
_attachment_toolchain_symlink_component() {
  local value=$1 rest part current=/
  rest="${value#/}"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) part="${rest%%/*}"; rest="${rest#*/}" ;;
      *) part="$rest"; rest="" ;;
    esac
    [ -n "$part" ] || return 1
    if [ "$current" = / ]; then current="/$part"; else current="$current/$part"; fi
    if [ -L "$current" ]; then printf '%s\n' "$current"; return 0; fi
    [ -e "$current" ] || return 1
  done
  return 1
}

# Resolves a caller PATH into the recorded toolchain array (stdout JSON).
# Diagnostics go to stderr so command-substitution capture is unaffected:
# missing directories are skipped with a warning (R3.3); unsafe entries
# (empty, relative, controls, not-a-dir, symlink components, non-canonical)
# refuse the whole PATH with the entry named (R3.2). When the brew anchor
# exists as a canonical dir and the PATH carries nvm entries, the anchor is
# normalized ahead of them (R6.2; anchor overridable for tests).
_attachment_toolchain_path_resolve() {
  local raw="${1-}" remaining entry actual resolved='[]' more component
  local anchor first_nvm anchor_index
  if [ -z "$raw" ]; then
    printf 'trellis: refusing PATH: empty PATH\n' >&2
    return 1
  fi
  remaining="$raw"
  while :; do
    more=0
    case "$remaining" in
      *:*) entry="${remaining%%:*}"; remaining="${remaining#*:}"; more=1 ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    case "$entry" in
      '') printf 'trellis: refusing PATH entry: empty entry\n' >&2; return 1 ;;
      /*) ;;
      *) printf 'trellis: refusing PATH entry '\''%s'\'': relative entry\n' "$entry" >&2; return 1 ;;
    esac
    if _attachment_has_controls "$entry"; then
      printf 'trellis: refusing PATH entry '\''%s'\'': contains control characters\n' "$entry" >&2
      return 1
    fi
    if [ ! -d "$entry" ]; then
      # A missing entry -- and a symlink dangling at any component, which is
      # the same thing -- contributes nothing to resolution, so it is skipped
      # rather than fatal (R3.3). A real non-directory is still a refusal.
      if [ ! -e "$entry" ]; then
        printf 'trellis: skipping PATH entry '\''%s'\'': missing directory\n' "$entry" >&2
      else
        printf 'trellis: refusing PATH entry '\''%s'\'': not a directory\n' "$entry" >&2
        return 1
      fi
    else
      actual="$(CDPATH='' cd "$entry" && pwd -P 2>/dev/null)" || actual=""
      if [ -z "$actual" ]; then
        printf 'trellis: refusing PATH entry '\''%s'\'': unresolvable directory\n' "$entry" >&2
        return 1
      fi
      # A symlinked or trailing-slash entry is CANONICALIZED, not refused: the
      # stock macOS PATH ships /System/Cryptexes/App/usr/bin (line 2 of
      # /etc/paths) whose /System/Cryptexes/App component is a symlink, and nvm
      # ships ~/.nvm/default-node/bin. Refusing those refuses every normal
      # interactive PATH, which is the very defect R3 set out to remove. What
      # is recorded is the resolved path, so a later repoint of the link cannot
      # change an already-captured toolchain.
      if [ "$actual" != "$entry" ]; then
        component="$(_attachment_toolchain_symlink_component "$entry" 2>/dev/null)" || component=""
        [ -n "$component" ] || component="$entry"
        printf 'trellis: canonicalizing PATH entry '\''%s'\'' to '\''%s'\'' (symlink component '\''%s'\'')\n' "$entry" "$actual" "$component" >&2
      fi
      _attachment_canonical_dir "$actual" || {
        printf 'trellis: refusing PATH entry '\''%s'\'': resolved target is not canonical ('\''%s'\'')\n' "$entry" "$actual" >&2
        return 1
      }
      resolved="$(trellis_jq -cn --argjson resolved "$resolved" --arg entry "$actual" \
        '$resolved + [$entry]')" || return 1
    fi
    [ "$more" -eq 1 ] || break
  done
  if [ "$resolved" = '[]' ]; then
    printf 'trellis: refusing PATH: no usable directory entries\n' >&2
    return 1
  fi
  anchor="${TRELLIS_HOMEBREW_BIN:-/opt/homebrew/bin}"
  if _attachment_canonical_dir "$anchor" 2>/dev/null; then
    first_nvm="$(printf '%s\n' "$resolved" | jq -r '[to_entries[] | select(.value | test("(^|/)\\.nvm(/|$)")) | .key] | if length == 0 then empty else min end')" || first_nvm=""
    if [ -n "$first_nvm" ]; then
      anchor_index="$(printf '%s\n' "$resolved" | jq -r --arg anchor "$anchor" 'index($anchor) // empty')" || anchor_index=""
      if [ -z "$anchor_index" ]; then
        resolved="$(trellis_jq -cn --argjson resolved "$resolved" --arg anchor "$anchor" '[$anchor] + $resolved')" || return 1
      elif [ "$anchor_index" -gt "$first_nvm" ]; then
        resolved="$(trellis_jq -cn --argjson resolved "$resolved" --arg anchor "$anchor" --argjson first "$first_nvm" --argjson at "$anchor_index" '($resolved | del(.[$at])) | .[0:$first] + [$anchor] + .[$first:]')" || return 1
      fi
    fi
  fi
  printf '%s\n' "$resolved"
}

# Spec 055: a toolchain is control-only when its entries -- split on `:`,
# empty and whitespace-only entries dropped, each resolved with `cd -P` --
# form a subset of the sanitized control PATH set. The empty set counts.
# Deduplication is implicit: a subset test is a set comparison. A relative
# entry is never control (resolving it would depend on the working directory),
# and an unresolvable entry is kept literally, so it matches only if spelled
# exactly. The dispatcher embeds this definition verbatim (extracted like the
# launcher's scratch emitters), so keep `<name>() {` and a column-zero `}`,
# and nothing that allocates a temporary.
trellis_toolchain_control_only() {
  local remaining="${1-}" entry="" actual="" more=0
  while :; do
    more=0
    case "$remaining" in
      *:*) entry="${remaining%%:*}"; remaining="${remaining#*:}"; more=1 ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    case "$entry" in
      *[![:space:]]*)
        case "$entry" in /*) ;; *) return 1 ;; esac
        actual="$(CDPATH='' cd -P -- "$entry" 2>/dev/null && pwd -P)" || actual="$entry"
        case "$actual" in
          /usr/bin|/bin|/usr/sbin|/sbin) ;;
          *) return 1 ;;
        esac
        ;;
    esac
    [ "$more" -eq 1 ] || break
  done
  return 0
}

_attachment_canonical_file() {
  local value=$1 parent base actual_parent rebuilt
  _attachment_no_symlink_components "$value" 0 || return 1
  [ -f "$value" ] && [ ! -L "$value" ] || return 1
  trellis_dirname_to parent "$value" || return 1
  trellis_basename_to base "$value" || return 1
  actual_parent=$(CDPATH='' cd "$parent" && pwd -P) || return 1
  if [ "$actual_parent" = / ]; then
    rebuilt="/$base"
  else
    rebuilt="$actual_parent/$base"
  fi
  [ "$rebuilt" = "$value" ]
}

attachment_contextual_posix_shell_quote() {
  local value=$1 output="'" char index=0
  case "$value" in
    *$'\t'*|*$'\n'*|*$'\r'*) return "$TRELLIS_EX_STATE" ;;
  esac
  while [ "$index" -lt "${#value}" ]; do
    char="${value:$index:1}"
    if [ "$char" = "'" ]; then
      output="${output}'\\''"
    else
      output="${output}${char}"
    fi
    index=$((index + 1))
  done
  printf "%s'" "$output"
}

# The resolved launcher directory and each of its ancestors must be owned by
# the user or root. None may be group- or world-writable, except a sticky
# ancestor such as /tmp, whose entries others cannot rename. The directory
# itself never gets the sticky exception: the launcher installer refuses one
# writable by others too.
_attachment_launcher_dir_trusted() {
  python3 -I - "$1" <<'PY'
import os
import stat
import sys

path, euid, leaf = sys.argv[1], os.geteuid(), True
while True:
    try:
        info = os.lstat(path)
    except OSError:
        sys.exit(1)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (euid, 0):
        sys.exit(1)
    if info.st_mode & 0o022 and (leaf or not info.st_mode & stat.S_ISVTX):
        sys.exit(1)
    if path == "/":
        break
    path, leaf = os.path.dirname(path), False
PY
}

attachment_contextual_render_context() {
  local trellis_home=$1 user_home launcher user_home_shell trellis_home_shell launcher_shell context
  # Symlinked ancestors (macOS /var, a linked /home) resolve once; the store
  # itself named through an alias is refused, as attachment_prepare refuses it.
  if [ -L "${trellis_home%/}" ]; then
    _attachment_diag "Trellis home is a symlink: $trellis_home; name the real directory"
    return "$TRELLIS_EX_STATE"
  fi
  trellis_home="$(CDPATH='' cd "$trellis_home" && pwd -P)" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$trellis_home" || return "$TRELLIS_EX_STATE"
  [ -n "${HOME:-}" ] || return "$TRELLIS_EX_UNAVAILABLE"
  case "$HOME" in /*) ;; *) return "$TRELLIS_EX_STATE" ;; esac
  _attachment_has_controls "$HOME" && return "$TRELLIS_EX_STATE"
  [ -d "$HOME" ] || return "$TRELLIS_EX_UNAVAILABLE"
  user_home="$(CDPATH='' cd "$HOME" && pwd -P)" || return "$TRELLIS_EX_UNAVAILABLE"
  _attachment_canonical_dir "$user_home" || return "$TRELLIS_EX_STATE"
  # The user-selected launcher directory is a trusted root, which may itself
  # have a symlinked ancestor. Resolve it once, then validate the leaf without
  # following links beneath that root.
  launcher="$user_home/.local/bin/trellis"
  if [ -d "$user_home/.local/bin" ]; then
    launcher="$(CDPATH='' cd "$user_home/.local/bin" && pwd -P)/trellis" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ ! -e "$launcher" ] && [ ! -L "$launcher" ]; then
    _attachment_diag "launcher missing at $launcher; install it (docs/UPGRADING.md \"Reinstalling the launcher\") and retry"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  _attachment_canonical_file "$launcher" || return "$TRELLIS_EX_STATE"
  if [ ! -x "$launcher" ]; then
    _attachment_diag "launcher at $launcher is not executable; install it (docs/UPGRADING.md \"Reinstalling the launcher\") and retry"
    return "$TRELLIS_EX_STATE"
  fi
  if ! _attachment_launcher_dir_trusted "${launcher%/trellis}"; then
    _attachment_diag "launcher directory ${launcher%/trellis} or an ancestor is not owned by you or root, or is writable by others; refusing to pin it"
    return "$TRELLIS_EX_STATE"
  fi
  user_home_shell="$(attachment_contextual_posix_shell_quote "$user_home")" || return "$?"
  trellis_home_shell="$(attachment_contextual_posix_shell_quote "$trellis_home")" || return "$?"
  launcher_shell="$(attachment_contextual_posix_shell_quote "$launcher")" || return "$?"
  context="$(jq -cn \
    --arg user_home "$user_home" --arg trellis_home "$trellis_home" --arg launcher "$launcher" \
    --arg user_home_shell "$user_home_shell" --arg trellis_home_shell "$trellis_home_shell" --arg launcher_shell "$launcher_shell" \
    '{schema_version:1,user_home:$user_home,trellis_home:$trellis_home,launcher:$launcher,user_home_shell:$user_home_shell,trellis_home_shell:$trellis_home_shell,launcher_shell:$launcher_shell}')" || return "$TRELLIS_EX_STATE"
  attachment_contextual_render_context_validate "$context" "$trellis_home" || return "$?"
  printf '%s\n' "$context"
}

attachment_contextual_render_context_validate() {
  local context=$1 expected_trellis_home="${2:-}" user_home trellis_home launcher
  local user_home_shell trellis_home_shell launcher_shell
  # One jq validates and decodes. Fields are printed only for a single JSON
  # value whose whole shape passed, NUL-separated, with NULs dropped from the
  # values as command substitution dropped them; anything else prints nothing.
  trellis_read_nul_fields user_home trellis_home launcher user_home_shell trellis_home_shell launcher_shell \
    < <(jq -j -s '
    if length == 1 and (.[0] |
      type == "object"
      and ((keys_unsorted | sort) == ["launcher","launcher_shell","schema_version","trellis_home","trellis_home_shell","user_home","user_home_shell"])
      and .schema_version == 1
      and (.user_home | type == "string" and startswith("/"))
      and (.trellis_home | type == "string" and startswith("/"))
      and (.launcher | type == "string" and startswith("/"))
      and (.user_home_shell | type == "string" and startswith("\u0027") and endswith("\u0027"))
      and (.trellis_home_shell | type == "string" and startswith("\u0027") and endswith("\u0027"))
      and (.launcher_shell | type == "string" and startswith("\u0027") and endswith("\u0027")))
    then .[0] | (.user_home, .trellis_home, .launcher, .user_home_shell, .trellis_home_shell, .launcher_shell
          | gsub("\u0000"; ""), "\u0000")
    else empty end
  ' <<< "$context") || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$user_home" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$trellis_home" || return "$TRELLIS_EX_STATE"
  if [ -n "$expected_trellis_home" ]; then
    expected_trellis_home="$(CDPATH='' cd "$expected_trellis_home" && pwd -P)" || return "$TRELLIS_EX_STATE"
    _attachment_canonical_dir "$expected_trellis_home" || return "$TRELLIS_EX_STATE"
    [ "$trellis_home" = "$expected_trellis_home" ] || return "$TRELLIS_EX_STATE"
  fi
  [ "$launcher" = "$(CDPATH='' cd "$user_home/.local/bin" 2>/dev/null && pwd -P)/trellis" ] || return "$TRELLIS_EX_STATE"
  _attachment_canonical_file "$launcher" || return "$TRELLIS_EX_STATE"
  [ -x "$launcher" ] || return "$TRELLIS_EX_STATE"
  [ "$user_home_shell" = "$(attachment_contextual_posix_shell_quote "$user_home")" ] || return "$TRELLIS_EX_STATE"
  [ "$trellis_home_shell" = "$(attachment_contextual_posix_shell_quote "$trellis_home")" ] || return "$TRELLIS_EX_STATE"
  [ "$launcher_shell" = "$(attachment_contextual_posix_shell_quote "$launcher")" ] || return "$TRELLIS_EX_STATE"
}

_attachment_contextual_render_context_record_valid() {
  local record=$1 expected_trellis_home="${2:-}" context
  context="$(printf '%s\n' "$record" | jq -c '.render_context // null')" || return 1
  [ "$context" = null ] && return 0
  attachment_contextual_render_context_validate "$context" "$expected_trellis_home"
}
attachment_contextual_template_expected() {
  case "$1" in
    core-rules/templates/claude-settings.local.json)
      cat <<'JSON'
[
  {"path":["hooks","SessionStart",0,"hooks",0,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook session-start claude \"$CLAUDE_PROJECT_DIR\""}
]
JSON
      ;;
    core-rules/templates/codex-hooks.local.json)
      cat <<'JSON'
[
  {"path":["hooks","SessionStart",0,"hooks",0,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook session-start codex \"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}\""}
]
JSON
      ;;
    *) printf '[]\n' ;;
  esac
}

# The installed Claude Code version: X.Y.Z, nothing when `claude --version`
# gives none, status 1 when no claude is found. The launcher runs attach and
# doctor under the control PATH and forwards the caller's PATH as
# TRELLIS_ATTACH_CALLER_PATH, so that is searched first.
attachment_claude_code_version() {
  local dir claude="" saved_ifs="$IFS" version
  IFS=:
  for dir in ${TRELLIS_ATTACH_CALLER_PATH:-} ${PATH:-}; do
    case "$dir" in /*) ;; *) continue ;; esac
    if [ -f "$dir/claude" ] && [ -x "$dir/claude" ]; then
      claude="$dir/claude"
      break
    fi
  done
  IFS="$saved_ifs"
  [ -n "$claude" ] || return 1
  # perl comes from the control PATH; the CLI gets the caller's, so a
  # `#!/usr/bin/env node` claude finds the runtime installed beside it.
  # The first line must open with a canonical X.Y.Z (no leading zeros, no
  # fourth part, no prerelease) followed by whitespace or its end; anything
  # else is no version. Read it whatever the pipeline's status: a CLI may
  # print its version and then exit nonzero, and under pipefail that status
  # is the CLI's (r152-t13-code F3).
  version="$(perl -e '$ENV{PATH} = shift; alarm shift; exec @ARGV' \
    "${TRELLIS_ATTACH_CALLER_PATH:-$PATH}" 10 "$claude" --version </dev/null 2>/dev/null |
    head -n 1 |
    sed -nE 's/^((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))([[:space:]].*)?$/\1/p')" || :
  # A claude that is present but gives no version is undecided, not old.
  [ -n "$version" ] || return 2
  printf '%s\n' "$version"
}

# Claude Code 2.1.295 added the hook `onFailure` key; exec-form hooks
# (`command` + `args`) are older, but one floor keeps this simple. At or above
# it the Claude settings render is the template: exec form, onFailure on the
# guards. Below it, or when the version cannot be read, every hook outside
# SessionStart is the pre-exec shell-form wiring below, byte for byte, and the
# guard supervisor alone fails closed.
ATTACHMENT_CLAUDE_ON_FAILURE_VERSION=2.1.295

# attachment_claude_decision: one of supported (at least the floor),
# unsupported (an older valid version), absent (no claude found) or unreadable
# (found, but no version). Probes afresh; nothing is cached across processes.
attachment_claude_decision() {
  local version rc=0 order
  version="$(attachment_claude_code_version)" || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'absent\n'; return 0 ;;
    *) printf 'unreadable\n'; return 0 ;;
  esac
  # Only a canonical X.Y.Z from the version source (the CLI, an override, a
  # wrapper) is decided; anything else, and any comparison that does not
  # answer -1, 0 or 1, is undecided, never supported.
  case "$version" in
    ''|*[!0-9.]*) printf 'unreadable\n'; return 0 ;;
  esac
  semver_is_valid "$version" || { printf 'unreadable\n'; return 0; }
  order="$(semver_compare "$version" "$ATTACHMENT_CLAUDE_ON_FAILURE_VERSION")" ||
    { printf 'unreadable\n'; return 0; }
  case "$order" in
    -1) printf 'unsupported\n' ;;
    0|1) printf 'supported\n' ;;
    *) printf 'unreadable\n' ;;
  esac
}

# T13 D2: an attach boundary (attach_cmd_attach) makes the decision once and
# owns it here; every render in that process, the donor fast path's included,
# uses it. Never inherited: sourcing the library clears it.
unset _ATTACHMENT_CLAUDE_DECISION
attachment_claude_decide_boundary() {
  _ATTACHMENT_CLAUDE_DECISION="$(attachment_claude_decision)" || _ATTACHMENT_CLAUDE_DECISION=unreadable
}

# 0: supported. 1: absent or older. 2: present but unreadable (the canonical
# render still takes the shell form; callers that must not guess, like the
# donor fast path, treat 2 as undecided).
attachment_claude_on_failure_supported() {
  local decision="${_ATTACHMENT_CLAUDE_DECISION:-}"
  case "$decision" in
    supported|unsupported|absent|unreadable) ;;
    *) decision="$(attachment_claude_decision)" || decision=unreadable ;;
  esac
  case "$decision" in
    supported) return 0 ;;
    unsupported|absent) return 1 ;;
    *) return 2 ;;
  esac
}

# The shell-form `.hooks` of claude-settings.local.json before exec form,
# SessionStart excluded (that stays the template's contextual entries).
# Return one file from the complete, digest-pinned pre-native provider. No
# provider code executes; the captured manifest and every file are byte-checked.
attachment_legacy_template_file() {
  local provider="$1" name="$2"
  python3 -I - "$provider" "$name" <<'PY'
import hashlib,json,os,stat,sys
from pathlib import Path
base=Path(sys.argv[1]); name=sys.argv[2]
try:
    fd=os.open(base,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    def read(name):
        f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
        try:
            assert stat.S_ISREG(os.fstat(f).st_mode), 'non-regular provider file'
            with os.fdopen(os.dup(f),'rb') as stream:
                return stream.read()
        finally:
            os.close(f)
    try:
        raw=read('manifest.json')
        assert hashlib.sha256(raw).hexdigest()=='4714e988215571784c6eaacffbff30259e17065dc0aade6c14a785c21122e99e', 'legacy provider manifest digest mismatch'
        manifest=json.loads(raw)
        expected=set(manifest['files'])|{'manifest.json'}
        assert set(os.listdir(fd))==expected, 'missing/unlisted legacy provider file'
        files={}
        for path,digest in manifest['files'].items():
            assert '/' not in path and path not in ('.','..'), 'unsafe legacy provider file'
            files[path]=read(path)
            assert hashlib.sha256(files[path]).hexdigest()==digest, 'legacy provider file digest mismatch: '+path
        assert name in files, 'unknown legacy template'
        print(str(base/name))
    finally:
        os.close(fd)
except (OSError,ValueError,KeyError,AssertionError) as error:
    print('legacy provider refused: '+str(error),file=sys.stderr)
    raise SystemExit(4)
PY
}

attachment_claude_legacy_hooks() {
  local provider="$1" file
  file="$(attachment_legacy_template_file "$provider" claude-shell-hooks.json)" || return "$?"
  cat "$file"
}

attachment_contextual_render_required() {
  printf '%s\n' "$1" | jq -e '
    [.artifacts[]
     | select(
         .kind == "render"
         and (
           .template == "core-rules/templates/claude-settings.local.json"
           or .template == "core-rules/templates/codex-hooks.local.json"
           or .template == "core-rules/templates/claude-user-settings.json"
         )
       )]
    | length > 0
  ' >/dev/null
}

# Candidate registrations use only the existing contextual markers. A native
# hook is represented before rendering as command=__TRELLIS_LAUNCHER__ with
# args=[hook,event,HARNESS,EVENT]. It becomes I-A3 R1/R2, not a launcher guard
# hop. This source-only representation never reaches effective settings.
attachment_contextual_candidate_render() {
  local source="$1" template="$2" context="$3" project_root="${4:-}" direct=false
  attachment_contextual_render_context_validate "$context" || return "$?"
  if [ "$template" = core-rules/templates/claude-user-settings.json ]; then
    project_root="$(printf '%s\n' "$context" | jq -r '.user_home')" || return 4
  fi
  [ -z "$project_root" ] || _attachment_canonical_dir "$project_root" || return 4
  attachment_claude_on_failure_supported && direct=true
  python3 -I - "$source" "$template" "$context" "$project_root" "$direct" <<'PY'
import hashlib, json, os, platform, re, shlex, stat, sys
from pathlib import Path
source, template, encoded_context, root, direct = sys.argv[1:]
markers = ('__TRELLIS_USER_HOME__', '__TRELLIS_HOME__', '__TRELLIS_LAUNCHER__')
def require(ok, reason):
    if not ok:
        raise ValueError(reason)
def pairs(items):
    d = {}
    for k, v in items:
        require(k not in d, 'duplicate contextual JSON key'); d[k] = v
    return d
def parse(text):
    return json.loads(text, object_pairs_hook=pairs)
def marked(v):
    return type(v) is str and any(m in v for m in markers)
def reject_marks(v):
    if type(v) is dict:
        require(not any(marked(k) for k in v), 'marker in JSON key')
        for value in v.values():
            reject_marks(value)
    elif type(v) is list:
        for value in v:
            reject_marks(value)
    else:
        require(not marked(v), 'marker outside validated hook command')
def ordinary(path):
    p = Path(path)
    require(p.is_absolute() and str(p) == path and not any(x in ('..', '.') for x in p.parts), 'unsafe registration path')
    for lexical, physical in trusted_roots:
        try:
            relative = p.relative_to(lexical)
        except ValueError:
            continue
        p = physical / relative
        break
    else:
        raise ValueError('registration dependency outside trusted roots')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in p.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = child
        child = os.open(p.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            s = os.fstat(child)
            require(stat.S_ISREG(s.st_mode), 'non-regular registration dependency')
            with os.fdopen(os.dup(child), 'rb') as stream:
                data = stream.read()
            require((s.st_ino, s.st_size, s.st_ctime_ns) == (os.fstat(child).st_ino, os.fstat(child).st_size, os.fstat(child).st_ctime_ns), 'registration dependency changed')
            return data, s
        finally:
            os.close(child)
    finally:
        os.close(fd)
try:
    context = parse(encoded_context)
    user, home, launcher = (context[k] for k in ('user_home', 'trellis_home', 'launcher'))
    # Resolve trusted caller roots once, never native/release descendants. A
    # symlinked HOME ancestor or launcher directory is portable; planted links
    # beneath the companion root still fail the descriptor walk below.
    trusted_roots = [(p, p.resolve(strict=True)) for p in
                     (Path(home), Path(source).parents[2], Path(launcher).parent)]
    require('=' not in home and not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in home), 'unsafe native env command operand')
    replacements = dict(zip(markers, (user, home, launcher)))
    q = shlex.quote
    # I-A3 Q always single-quotes, even words shlex.quote would leave bare.
    q = lambda value: "'" + value.replace("'", "'\\''") + "'"
    doc = parse(Path(source).read_text()); require(type(doc) is dict, 'contextual template must be an object')
    hooks = doc.get('hooks', {}); require(type(hooks) is dict, 'invalid hook events')
    sentinel = []
    harness = 'codex' if template.endswith('/codex-hooks.local.json') else 'claude'
    events = {'PreToolUse','PostToolUse','UserPromptSubmit','UserPromptExpansion','SessionStart','Stop','PreCompact','WorktreeCreate','WorktreeRemove'}
    for event, blocks in hooks.items():
        require(event in events and type(blocks) is list, 'invalid rendered hook event')
        for block in blocks:
            require(type(block) is dict and type(block.get('hooks')) is list, 'invalid rendered hook block')
            for hook in block['hooks']:
                require(type(hook) is dict, 'invalid rendered hook')
                command = hook.get('command')
                if command == markers[2]:
                    require(hook.get('type') == 'command' and hook.get('args') == ['hook','event',harness,event], 'invalid native registration placeholder')
                    require(type(hook.get('timeout')) is int and hook['timeout'] >= 30, 'native registration timeout below 30')
                    require(set(hook) <= {'type','command','args','timeout','onFailure'}, 'unknown native registration field')
                    # T34b: the user worktree callbacks fail by exit status and
                    # render in shell form without onFailure (a placeholder
                    # may carry it; the render drops it); every other Claude
                    # entry blocks.
                    worktree = harness == 'claude' and event in ('WorktreeCreate', 'WorktreeRemove')
                    require(worktree or harness != 'claude' or hook.get('onFailure') == 'block', 'native Claude registration must block on failure')
                    require(not worktree or hook.get('onFailure', 'block') == 'block', 'native worktree registration onFailure must be block or absent')
                    require(harness != 'codex' or 'onFailure' not in hook, 'unsupported Codex onFailure')
                    sentinel.append((event, hook))
                    continue
                args = hook.get('args')
                if type(args) is list and any(marked(v) for v in args):
                    require(command == '/usr/bin/env' and args[:5] == ['-i','HOME='+markers[0], 'TRELLIS_HOME='+markers[1], 'PATH=/usr/bin:/bin:/usr/sbin:/sbin',markers[2]], 'invalid contextual exec registration')
                    require(all(type(v) is str for v in args) and len(args) > 5, 'invalid contextual argv')
                    hook['args'] = [v.replace(markers[0], user).replace(markers[1], home).replace(markers[2], launcher) for v in args]
                elif marked(command):
                    prefix = '/usr/bin/env -i HOME='+markers[0]+' TRELLIS_HOME='+markers[1]+' PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc '+markers[2]+' '
                    require(command.startswith(prefix), 'invalid contextual shell registration')
                    for marker, value in replacements.items():
                        command = command.replace(marker, q(value))
                    hook['command'] = command
    if sentinel:
        require(root and Path(root).is_dir() and str(Path(root).resolve()) == root, 'native registration needs a concrete canonical project root')
        base = Path(source).parents[1] / 'native'
        # A payload that ships no native manifest is a legacy-only payload
        # (pre-1.5 releases and test payloads): its complete pinned legacy
        # surface, silently (11). A listed manifest without this host's target
        # is a native miss, labelled below (10). Never a partial native set.
        if not os.path.lexists(base) and not os.path.lexists(base/'artifacts.json'):
            raise SystemExit(11)
        manifest_bytes, _ = ordinary(str(base/'artifacts.json')); d = parse(manifest_bytes.decode())
        target = {('Darwin','arm64'):'aarch64-apple-darwin',('Linux','x86_64'):'x86_64-unknown-linux-musl',('Linux','aarch64'):'aarch64-unknown-linux-musl'}.get((platform.system(), platform.machine()))
        # The cutover selector must choose the complete labelled legacy template
        # for an unlisted target; never emit a partial native registration set.
        if target not in d.get('assets', {}):
            print('native registration unavailable: select the complete legacy template', file=sys.stderr)
            raise SystemExit(10)
        a = d['assets'][target]
        numeric = r'(?:0|[1-9][0-9]*)'
        prerelease = r'(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
        semver = numeric + r'\.' + numeric + r'\.' + numeric + r'(?:-' + prerelease + r'(?:\.' + prerelease + r')*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
        require(type(d['version']) is str and re.fullmatch('[0-9a-f]{64}', a['sha256']) and re.fullmatch(semver, d['version']), 'invalid native registration identity')
        companion = home+'/bin/native/'+d['version']+'/'+target+'/'+a['sha256']+'/trellis-hooks'
        # The first 1.4.x -> 1.5.x configure relinks the user surface through
        # this payload before any companion is staged (the old configure cannot
        # stage one). With no companion anywhere on its path, the user template
        # takes the complete legacy surface (labelled); the second configure
        # stages the companion and relinks native. A present-but-wrong
        # companion still refuses below, and project templates still refuse.
        if template == 'core-rules/templates/claude-user-settings.json':
            try:
                ordinary(companion)
            except FileNotFoundError:
                print('native registration unavailable: no companion is installed yet; select the complete legacy template', file=sys.stderr)
                raise SystemExit(10)
        data, mode = ordinary(companion)
        require(stat.S_IMODE(mode.st_mode) == 0o500 and mode.st_uid == os.getuid(), 'unsafe companion ownership/mode')
        require(len(data) == a['size'] and hashlib.sha256(data).hexdigest() == a['sha256'], 'registration companion digest mismatch')
        # Policy belongs to this verified release and its immutable companion,
        # not the global management launcher's currently selected generation.
        # Mixed-release checkouts keep using their own digest entry after a
        # management repin (including interruption before a scoped adoption).
        adapter_bytes, _ = ordinary(str(base/'hook-adapter.sh'))
        require(hashlib.sha256(adapter_bytes).hexdigest() == d['adapter']['sha256'] and len(adapter_bytes) == d['adapter']['size'], 'registration adapter digest mismatch')
        adapter = '\n'.join(line for line in adapter_bytes.decode().splitlines() if not line.lstrip().startswith('#'))
        shell = '/bin/dash' if os.access('/bin/dash', os.X_OK) else '/bin/sh'
        # T34: the client timeout outlasts the native per-event supervisor
        # budget (protocol::event_deadline_secs) by 10 s.
        budgets = {'Stop': 300, 'PostToolUse': 120, 'WorktreeCreate': 50, 'WorktreeRemove': 110}
        # The caller settings each shell-form member reads, forwarded as data
        # exactly as protocol::{STOP,POST_ACTION,WORKTREE}_SETTINGS name them;
        # legacy direct registrations inherited them from the harness.
        STOP_SETTINGS = ('TRELLIS_REVIEW_IN_PROGRESS', 'PROCESS_GATE_FORCE_ROOT', 'PROCESS_GATE_NO_RECEIPTS', 'TODOS_FILE', 'TRELLIS_NO_JQ_DEGRADE', 'RUSTUP_HOME')
        POST_ACTION_SETTINGS = ('SLOP_TRIPWIRE', 'TRELLIS_NO_JQ_DEGRADE')
        WORKTREE_SETTINGS = ('TRELLIS_WORKTREE_ROOT', 'TRELLIS_WORKTREE_SYNC_WAIT_S')
        def settings(names):
            return ''.join('"' + name + '=${' + name + '-}" ' for name in names)
        for event, hook in sentinel:
            timeout = budgets.get(event, 20) + 10
            hook.clear()
            if harness == 'claude' and event in ('WorktreeCreate', 'WorktreeRemove'):
                # T34b (apex ruling A): shell form, so the caller's PATH is
                # forwarded, as data only, in TRELLIS_ATTACH_CALLER_PATH; the
                # companion never resolves a command through it.
                command = '/usr/bin/env -i HOME='+q(user)+' TRELLIS_HOME='+q(home)+' PATH=/usr/bin:/bin:/usr/sbin:/sbin "TRELLIS_ATTACH_CALLER_PATH=$PATH" '+settings(WORKTREE_SETTINGS)+q(companion)+' event-client claude '+event+' '+q(root)
                hook.update(type='command', command=command, timeout=timeout)
            elif harness == 'claude' and direct == 'true' and event in ('PostToolUse', 'Stop'):
                # R1 PATH ruling (option A): these events run project tools,
                # so they take the shell form and forward the caller's PATH as
                # data in TRELLIS_CALLER_PATH; onFailure still blocks.
                command = '/usr/bin/env -i HOME='+q(user)+' TRELLIS_HOME='+q(home)+' PATH=/usr/bin:/bin:/usr/sbin:/sbin "TRELLIS_CALLER_PATH=$PATH" '+settings(STOP_SETTINGS if event == 'Stop' else POST_ACTION_SETTINGS)+q(companion)+' event-client claude '+event+' '+q(root)
                hook.update(type='command', command=command, timeout=timeout, onFailure='block')
            elif harness == 'claude' and direct == 'true':
                hook.update(type='command', command='/usr/bin/env', args=['-i','HOME='+user,'TRELLIS_HOME='+home,'PATH=/usr/bin:/bin:/usr/sbin:/sbin',companion,'event-client',harness,event,root], timeout=timeout, onFailure='block')
            else:
                command = 'HOME='+q(user)+' TRELLIS_HOME='+q(home)+' '+q(shell)+' -c '+q(adapter)+' trellis-hooks '+q(companion)+' '+q(harness)+' '+q(event)+' '+q(root)
                hook.update(type='command', command=command, timeout=timeout)
    reject_marks(doc)
    print(json.dumps(doc, sort_keys=True, indent=2))
except (OSError, ValueError, KeyError, TypeError) as error:
    print('contextual registration refused: '+str(error), file=sys.stderr)
    raise SystemExit(4)
PY
}

# T34 consumes this one selector. Native miss 10 selects the entire captured
# legacy surface and is labelled on stderr; it is never a native success.
attachment_contextual_template_select() {
  local source="$1" template="$2" context="$3" root="${4:-}" rc provider fallback
  attachment_contextual_template_render_impl "$source" "$template" "$context" "$root" && return 0
  rc=$?
  [ "$rc" -eq 10 ] || [ "$rc" -eq 11 ] || return "$rc"
  provider="${source%/*}"; provider="${provider%/*}/legacy-hooks"
  fallback="$(attachment_legacy_template_file "$provider" "${template##*/}")" || return "$?"
  [ "$rc" -eq 11 ] || _attachment_diag 'legacy fallback: native selection miss 10; rendering the complete pinned legacy surface'
  # The pinned legacy surface replaces only the hook registrations; every
  # other key (permissions, owned explicit-json values) comes from the
  # current template, as on the native route.
  local merged
  merged="$(mktemp -d "${TMPDIR:-/tmp}/trellis-legacy-render.XXXXXX")" || return 1
  mkdir -p "$merged/core-rules/templates" &&
    cp -R "$provider" "$merged/core-rules/legacy-hooks" &&
    chmod -R u+w "$merged/core-rules/legacy-hooks" &&
    jq --slurpfile legacy "$fallback" 'if ($legacy[0] | has("hooks")) then .hooks = $legacy[0].hooks else del(.hooks) end' \
      "$source" > "$merged/core-rules/templates/${template##*/}" || { rm -rf "${merged:?}"; return 4; }
  attachment_contextual_template_render_impl "$merged/core-rules/templates/${template##*/}" "$template" "$context" "$root"
  rc=$?
  rm -rf "${merged:?}"
  return "$rc"
}

attachment_contextual_template_render() {
  attachment_contextual_template_select "$@"
}

attachment_contextual_template_render_impl() {
  local source=$1 template=$2 context=$3 expected user_home trellis_home launcher provider
  local user_home_shell trellis_home_shell launcher_shell legacy_hooks=null
  if printf '%s\n' "$template" | grep -Eq '^core-rules/templates/(claude-settings.local|codex-hooks.local|claude-user-settings)\.json$' &&
     jq -e 'any(.. | objects; .command? == "__TRELLIS_LAUNCHER__" or (has("args") and (.args | type) == "array" and any(.args[]; type == "string" and contains("__TRELLIS_")))) or (any(.. | strings; contains("__TRELLIS_")) and has("hooks") and (.hooks | has("WorktreeCreate") or has("WorktreeRemove")))' "$source" >/dev/null 2>&1; then
    attachment_contextual_candidate_render "$source" "$template" "$context" "${4:-}"
    return "$?"
  fi
  expected="$(attachment_contextual_template_expected "$template")" || return "$TRELLIS_EX_STATE"
  if [ "$template" = core-rules/templates/claude-settings.local.json ] &&
     ! attachment_claude_on_failure_supported; then
    provider="${source%/*}"; provider="${provider%/*}/legacy-hooks"
    legacy_hooks="$(attachment_claude_legacy_hooks "$provider")" || return "$?"
  fi
  if [ "$(printf '%s\n' "$expected" | jq 'length')" -eq 0 ]; then
    jq -e \
      --arg user_home_marker '__TRELLIS_USER_HOME__' \
      --arg home_marker '__TRELLIS_HOME__' \
      --arg launcher_marker '__TRELLIS_LAUNCHER__' '
        def contextual_marker:
          contains($user_home_marker) or contains($home_marker) or contains($launcher_marker);
        [
          paths(type == "string") as $path
          | getpath($path)
          | select(contextual_marker)
        ]
        | length == 0
        and (
          [
            paths(objects) as $path
            | getpath($path)
            | keys_unsorted[]
            | select(contextual_marker)
          ]
          | length == 0
        )
      ' "$source" >/dev/null || return "$TRELLIS_EX_STATE"
    cat "$source"
    return 0
  fi
  attachment_contextual_render_context_validate "$context" || return "$?"
  user_home="$(printf '%s\n' "$context" | jq -r '.user_home')" || return "$TRELLIS_EX_STATE"
  trellis_home="$(printf '%s\n' "$context" | jq -r '.trellis_home')" || return "$TRELLIS_EX_STATE"
  if ! trellis_home_native_entry_path_is_safe "$trellis_home"; then
    _attachment_diag 'registration TRELLIS_HOME is not a safe native env command path'
    return "$TRELLIS_EX_STATE"
  fi
  launcher="$(printf '%s\n' "$context" | jq -r '.launcher')" || return "$TRELLIS_EX_STATE"
  user_home_shell="$(printf '%s\n' "$context" | jq -r '.user_home_shell')" || return "$TRELLIS_EX_STATE"
  trellis_home_shell="$(printf '%s\n' "$context" | jq -r '.trellis_home_shell')" || return "$TRELLIS_EX_STATE"
  launcher_shell="$(printf '%s\n' "$context" | jq -r '.launcher_shell')" || return "$TRELLIS_EX_STATE"
  jq -e \
    --arg user_home_marker '__TRELLIS_USER_HOME__' \
    --arg home_marker '__TRELLIS_HOME__' \
    --arg launcher_marker '__TRELLIS_LAUNCHER__' \
    --argjson expected "$expected" '
      def contextual_marker:
        contains($user_home_marker) or contains($home_marker) or contains($launcher_marker);
      def marked_strings:
        [
          paths(type == "string") as $path
          | {path:($path | @json),value:getpath($path)}
          | select(.value | contextual_marker)
        ];
      marked_strings as $actual
      | ($actual | sort_by(.path)) as $actual
      | ([$expected[] | {path:(.path | @json),value:.command}] | sort_by(.path)) as $wanted
      | $actual == $wanted
      and (
        [
          paths(objects) as $path
          | getpath($path)
          | keys_unsorted[]
          | select(contextual_marker)
        ]
        | length == 0
      )
    ' "$source" >/dev/null || return "$TRELLIS_EX_STATE"
  jq -S \
    --arg user_home_shell "$user_home_shell" \
    --arg trellis_home_shell "$trellis_home_shell" \
    --arg launcher_shell "$launcher_shell" \
    --argjson legacy_hooks "$legacy_hooks" \
    --argjson expected "$expected" '
      def contextual_command:
        split("__TRELLIS_USER_HOME__") | join($user_home_shell)
        | split("__TRELLIS_HOME__") | join($trellis_home_shell)
        | split("__TRELLIS_LAUNCHER__") | join($launcher_shell);
      reduce $expected[] as $entry (.;
        setpath($entry.path; ($entry.command | contextual_command)))
      | if $legacy_hooks == null then . else .hooks = $legacy_hooks + {SessionStart: .hooks.SessionStart} end
    ' "$source"
}

_attachment_ensure_private_dir() {
  local value=$1 parent
  if [ -e "$value" ] || [ -L "$value" ]; then
    _attachment_canonical_dir "$value" || return 1
  else
    parent=$(dirname "$value") || return 1
    _attachment_canonical_dir "$parent" || return 1
    mkdir "$value" || return 1
  fi
  # Same-mode chmod moves ctime on Linux; see trellis_home_prepare_private_dir.
  if [ -n "$(find "$value" -maxdepth 0 -perm 0700 -print 2>/dev/null)" ]; then
    :
  else
    chmod 00700 "$value" || return 1
    [ -n "$(find "$value" -maxdepth 0 -perm 0700 -print 2>/dev/null)" ] || return 1
  fi
  [ "$(_attachment_mode "$value")" = 700 ]
}

# The artifact-verdict reader needs only these existing private directories.
# Unlike _attachment_prepare_state it must never create or chmod state.
_attachment_state_readonly_ok() {
  local home=$1 dir uid
  uid=$(id -u) || return 1
  for dir in "$home" "$home/state" "$home/state/attachments"; do
    _attachment_canonical_dir "$dir" || return 1
    [ -n "$(find "$dir" -maxdepth 0 -user "$uid" -perm 0700 -print 2>/dev/null)" ] || return 1
  done
}

_attachment_prepare_state() {
  local home=$1
  _attachment_canonical_dir "$home" || return 2
  # Same-mode chmod moves ctime on Linux; see trellis_home_prepare_private_dir.
  if [ -n "$(find "$home" -maxdepth 0 -perm 0700 -print 2>/dev/null)" ]; then
    :
  else
    chmod 00700 "$home" || return 1
    [ -n "$(find "$home" -maxdepth 0 -perm 0700 -print 2>/dev/null)" ] || return 1
  fi
  _attachment_ensure_private_dir "$home/state" || return 1
  _attachment_ensure_private_dir "$home/state/attachments" || return 1
  _attachment_ensure_private_dir "$home/state/attachment-journals" || return 1
  _attachment_ensure_private_dir "$home/state/locks" || return 1
}

_attachment_hooks_pre_push_source_valid() {
  case "${1:-}" in
    core-rules/husky/pre-push|core-rules/githooks/pre-push) return 0 ;;
    *) return 1 ;;
  esac
}

_attachment_hooks_pre_push_source_for_root() {
  local root=$1
  if [ -d "$root/.husky" ]; then
    printf '%s\n' 'core-rules/husky/pre-push'
  else
    printf '%s\n' 'core-rules/githooks/pre-push'
  fi
}
_attachment_hooks_release_manifest_sha256() {
  local payload=$1 release
  release="${payload%/payload}"
  [ "$release/payload" = "$payload" ] || return 1
  _attachment_canonical_file "$release/release.json" || return 1
  _attachment_hash "$release/release.json"
}

_attachment_hooks_read_sidecar() {
  local path=$1 allow_empty=${2:-false} line="" candidate="" count=0
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r candidate || [ -n "$candidate" ]; do
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    line=$candidate
    candidate=""
  done < "$path"
  [ "$count" -eq 1 ] || return 1
  _attachment_has_controls "$line" && return 1
  [ "$allow_empty" = true ] || [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

_attachment_hooks_file_matches() {
  local path=$1 expected=$2 mode=$3 actual_hash expected_hash
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  _attachment_canonical_file "$path" || return 1
  _attachment_mode_matches "$path" "$mode" || return 1
  actual_hash=$(_attachment_hash "$path") || return 1
  expected_hash=$(_attachment_hash_text "$expected"$'\n') || return 1
  [ "$actual_hash" = "$expected_hash" ]
}

_attachment_hooks_has_only_state_files() {
  local managed=$1 entry base core=0
  for entry in "$managed"/?* "$managed"/.[!.]* "$managed"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=${entry##*/}
    case "$base" in
      post-checkout|pre-push|previous-hooks-path|release-payload|pre-push-source) core=$((core + 1)) ;;
      *)
        _attachment_hooks_is_passthrough_name "$base" || return 1
        ;;
    esac
  done
  [ "$core" -eq 5 ]
}

# Standard git hook names Trellis passes through (see `man githooks`). Trellis
# owns post-checkout and pre-push; every other executable hook under
# previous-hooks-path gets a deterministic shim so project hooks (husky
# pre-commit, commitlint commit-msg, ...) keep running while core.hooksPath
# points at the managed dir.
_attachment_hooks_is_passthrough_name() {
  case "${1:-}" in
    applypatch-msg|commit-msg|fsmonitor-watchman|p4-changelist|p4-post-changelist|p4-pre-submit|p4-prepare-changelist|post-applypatch|post-commit|post-index-change|post-merge|post-receive|post-rewrite|post-update|pre-applypatch|pre-auto-gc|pre-commit|pre-merge-commit|pre-rebase|pre-receive|prepare-commit-msg|proc-receive|push-to-checkout|reference-transaction|sendemail-validate|update) return 0 ;;
    *) return 1 ;;
  esac
}

# The names _attachment_hooks_is_passthrough_name accepts, one per line. The
# hook digest memo records a shim digest for each; a test keeps the two equal.
_attachment_hooks_passthrough_names() {
  printf '%s\n' applypatch-msg commit-msg fsmonitor-watchman p4-changelist p4-post-changelist \
    p4-pre-submit p4-prepare-changelist post-applypatch post-commit post-index-change post-merge \
    post-receive post-rewrite post-update pre-applypatch pre-auto-gc pre-commit pre-merge-commit \
    pre-rebase pre-receive prepare-commit-msg proc-receive push-to-checkout reference-transaction \
    sendemail-validate update
}

# Hook digest memo (spec 072 T8): the sha256 of every managed hook file this
# release generates for one pre-push source, both dispatchers and both shims
# (recorded predecessor, default hooks dir) of each pass-through name, so the
# post-checkout fast path compares installed bytes instead of regenerating
# them. Content-addressed as
# state/hook-digests/<release manifest sha256>-<sha256 of the source>.json
# (0600 in 0700), so a changed input is another memo, never a stale one. Only
# a verified attach writes it, and from the generator, not the installed
# files. The owner record vouches for what it binds: the fast path takes a
# memo only for the owner's release payload and pre-push source and for the
# manifest the stamped release.json has. A missing or mismatched memo is a
# fast-path miss.
_attachment_hooks_digest_memo_py() {
  LC_ALL=C python3 -I -c '
import hashlib, json, os, stat, sys
home, payload, manifest, source, folder = sys.argv[1:6]
directory = home + "/state/hook-digests"
name = manifest + "-" + hashlib.sha256(source.encode()).hexdigest() + ".json"
def digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()
def private(path, kind, mode):
    info = os.lstat(path)
    if not kind(info.st_mode) or stat.S_IMODE(info.st_mode) != mode or info.st_uid != os.geteuid():
        sys.exit(1)
private(directory, stat.S_ISDIR, 0o700)
memo = {"schema_version": 1, "manifest_sha256": manifest, "payload": payload, "pre_push_source": source,
        "post_checkout": digest(folder + "/post-checkout"), "pre_push": digest(folder + "/pre-push"),
        "shims": dict((entry, digest(folder + "/shims/" + entry)) for entry in os.listdir(folder + "/shims"))}
# Schema 2 adds the default hooks dir shims, for a payload that expects them;
# the fast path of an earlier payload reads only schema 1.
if os.path.isdir(folder + "/default-shims"):
    memo["schema_version"] = 2
    memo["default_shims"] = dict((entry, digest(folder + "/default-shims/" + entry))
                                 for entry in os.listdir(folder + "/default-shims"))
data = (json.dumps(memo, sort_keys=True) + "\n").encode()
temporary = "%s/.%s.%s.tmp" % (directory, name, os.urandom(8).hex())
out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    os.fchmod(out, 0o600)
    view = memoryview(data)
    while view:
        view = view[os.write(out, view):]
    os.close(out)
    os.replace(temporary, directory + "/" + name)
except BaseException:
    os.unlink(temporary)
    raise
' "$@" 2>/dev/null
}

# Records the memo for <payload> <manifest> <source>, rebuilt from the
# generator every time. Callers run it only after verifying the installed hook
# set; <manifest> is the release manifest sha256 the dispatchers embed.
_attachment_hooks_digest_memo_write() {
  local home=$1 payload=$2 manifest=$3 source=$4 work name body rc=0
  _attachment_ensure_private_dir "$home/state/hook-digests" || return 1
  work="$(mktemp -d "${TMPDIR:-/tmp}/trellis-hook-digests.XXXXXX")" || return 1
  mkdir "$work/shims" "$work/default-shims" || rc=1
  if [ "$rc" -eq 0 ]; then
    body="$(_attachment_hooks_post_checkout_dispatcher_body "$payload" "$manifest")" && [ -n "$body" ] &&
      printf '%s\n' "$body" > "$work/post-checkout" &&
      body="$(_attachment_hooks_pre_push_dispatcher_body "$payload" "$source" "$manifest")" && [ -n "$body" ] &&
      printf '%s\n' "$body" > "$work/pre-push" || rc=1
  fi
  for name in $(_attachment_hooks_passthrough_names); do
    [ "$rc" -eq 0 ] || break
    body="$(_attachment_hooks_passthrough_shim_body "$name")" && printf '%s\n' "$body" > "$work/shims/$name" &&
      body="$(_attachment_hooks_default_passthrough_shim_body "$name")" &&
      printf '%s\n' "$body" > "$work/default-shims/$name" || rc=1
  done
  if [ "$rc" -eq 0 ] && ! _attachment_hooks_payload_shims_default "$payload"; then
    rm -rf "$work/default-shims" || rc=1
  fi
  [ "$rc" -ne 0 ] || _attachment_hooks_digest_memo_py "$home" "$payload" "$manifest" "$source" "$work" || rc=1
  rm -rf "$work"
  return "$rc"
}

# Deterministic pass-through shim for one previous project hook. Mirrors the
# prior-hook env-delegation contract (PR #358): the caller's PATH, HOME, and
# TMPDIR are captured before any sanitization and restored for the delegated
# hook via `env -i`. Trellis control-plane pins (fixed PATH, HOME=/dev/null,
# GIT_CONFIG_* isolation, TRELLIS_* allowlist) are NOT applied to the project
# hook. A missing or non-executable previous hook exits 0 so a removed project
# hook never blocks the git operation.
_attachment_hooks_passthrough_shim_body() {
  local name=${1:-} body
  _attachment_hooks_is_passthrough_name "$name" || return 1
  body=$(cat <<'SHIM_EOF'
#!/bin/sh
# trellis-managed-passthrough: @TRELLIS_HOOK_NAME@
caller_path=${PATH-}
caller_home=${HOME-}
caller_tmpdir=${TMPDIR-}
shim_path=$0
if [ "${shim_path#/}" = "$shim_path" ]; then
  shim_path="$PWD/$shim_path"
fi
managed_dir=$(dirname "$shim_path") || exit 1
managed_dir=$(CDPATH= cd "$managed_dir" && pwd -P) || exit 1
sidecar="$managed_dir/previous-hooks-path"
if [ ! -f "$sidecar" ] || [ -L "$sidecar" ]; then
  printf 'trellis hook: invalid previous hooks path record: %s\n' "$sidecar" >&2
  exit 1
fi
count=0
line=""
candidate=""
while IFS= read -r candidate || [ -n "$candidate" ]; do
  count=$((count + 1))
  if [ "$count" -ne 1 ]; then
    printf 'trellis hook: invalid previous hooks path record: %s\n' "$sidecar" >&2
    exit 1
  fi
  line="$candidate"
  candidate=""
done < "$sidecar" || exit 1
if [ "$count" -ne 1 ]; then
  printf 'trellis hook: invalid previous hooks path record: %s\n' "$sidecar" >&2
  exit 1
fi
previous="$line"
[ -n "$previous" ] || exit 0
if [ "${previous#/}" != "$previous" ]; then
  prior_hook="$previous/@TRELLIS_HOOK_NAME@"
else
  project_root=$(CDPATH= cd . && pwd -P) || exit 0
  prior_hook="$project_root/$previous/@TRELLIS_HOOK_NAME@"
fi
if [ -n "$prior_hook" ] && { [ -f "$prior_hook" ] || [ -L "$prior_hook" ]; } && [ -x "$prior_hook" ]; then
SHIM_EOF
) || return 1
  body="$body
$(_attachment_hooks_passthrough_shim_delegation)" || return 1
  body=${body//@TRELLIS_RPAREN@/)}
  body=${body//@TRELLIS_HOOK_NAME@/$name}
  printf '%s\n' "$body"
}

# trellis-capability: default-hooks-dir-shims
# Other releases read the line above from a payload's bundled library to learn
# that its verifier expects default hooks dir shims; never remove or reword it.
#
# The pass-through shim for one hook in the default hooks dir, used when no
# previous hooks path is recorded: git ran <common dir>/hooks then, so the shim
# resolves it the way the managed dispatchers do and delegates as above. Only a
# regular executable file in a real directory runs; a symlink is never followed.
_attachment_hooks_default_passthrough_shim_body() {
  local name=${1:-} body
  _attachment_hooks_is_passthrough_name "$name" || return 1
  body=$(cat <<'SHIM_EOF'
#!/bin/sh
# trellis-managed-passthrough-default: @TRELLIS_HOOK_NAME@
caller_path=${PATH-}
caller_home=${HOME-}
caller_tmpdir=${TMPDIR-}
common=$(/usr/bin/git -C "$PWD" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$common" in
  ""@TRELLIS_RPAREN@ exit 0 ;;
  /*@TRELLIS_RPAREN@ ;;
  *@TRELLIS_RPAREN@ common="$PWD/$common" ;;
esac
prior_hook="$common/hooks/@TRELLIS_HOOK_NAME@"
if [ -d "$common/hooks" ] && [ ! -L "$common/hooks" ] && [ -f "$prior_hook" ] && [ ! -L "$prior_hook" ] && [ -x "$prior_hook" ]; then
SHIM_EOF
) || return 1
  body="$body
$(_attachment_hooks_passthrough_shim_delegation)" || return 1
  body=${body//@TRELLIS_RPAREN@/)}
  body=${body//@TRELLIS_HOOK_NAME@/$name}
  printf '%s\n' "$body"
}

# True when <payload>'s own library shims the default hooks dir, as this one
# does: the payload running this library, a provisional payload without a
# bundled generator (generated in process, as its dispatchers are), or one whose
# bundled library carries the capability marker. A payload from before T68
# expects no default shim and its own verifier refuses one, so the expected set
# for it is empty: a rollback or an attach at that release writes none.
_attachment_hooks_payload_shims_default() {
  local payload=${1:-} running="" generator
  [ -n "$payload" ] || return 1
  running="$(_attachment_hooks_running_payload 2>/dev/null)" || running=""
  [ -z "$running" ] || [ "$payload" != "$running" ] || return 0
  generator="$payload/scripts/lib/attachment.sh"
  if [ -e "$generator" ] || [ -L "$generator" ]; then
    _attachment_canonical_file "$generator" || return 1
    grep -Fqx '# trellis-capability: default-hooks-dir-shims' "$generator"
    return
  fi
  ! _attachment_hooks_payload_declares_generator "$payload"
}

# The shim body strict verification expects for <name> under <previous>: the
# recorded predecessor's shim, or the default hooks dir's when none is recorded.
_attachment_hooks_shim_body_for() {
  if [ -n "${2:-}" ]; then
    _attachment_hooks_passthrough_shim_body "$1"
  else
    _attachment_hooks_default_passthrough_shim_body "$1"
  fi
}

# The delegation both shim bodies end with, from inside the `if` that found
# $prior_hook runnable.
_attachment_hooks_passthrough_shim_delegation() {
  cat <<'SHIM_EOF'
  hook_argc=$#
  line=""
  git_name=""
  hook_arg=""
  hook_index=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      GIT_*=*@TRELLIS_RPAREN@ ;;
      *@TRELLIS_RPAREN@ continue ;;
    esac
    git_name=${line%%=*}
    case "$git_name" in
      GIT_*@TRELLIS_RPAREN@ ;;
      *@TRELLIS_RPAREN@ continue ;;
    esac
    case "$git_name" in
      *[!A-Za-z0-9_]*@TRELLIS_RPAREN@ continue ;;
    esac
    set -- "$@" "$line"
    line=""
  done <<TRELLIS_GIT_ENV_EOF
$(/usr/bin/env)
TRELLIS_GIT_ENV_EOF
  set -- "$@" "$prior_hook"
  hook_index=0
  while [ "$hook_index" -lt "$hook_argc" ]; do
    hook_arg=$1
    shift
    set -- "$@" "$hook_arg"
    hook_index=$((hook_index + 1))
  done
  if [ "${DOCKER_HOST+x}" = x ]; then
    set -- "DOCKER_HOST=$DOCKER_HOST" "$@"
  fi
  exec /usr/bin/env -i PATH="$caller_path" HOME="$caller_home" TMPDIR="$caller_tmpdir" TMP="$caller_tmpdir" TEMP="$caller_tmpdir" LC_ALL=C "$@"
fi
exit 0
SHIM_EOF
}

# The hooks dir git uses for <root> when core.hooksPath is unset: hooks under
# the common dir, so every linked worktree shares it (`git rev-parse --git-path
# hooks` before core.hooksPath names the managed dir).
_attachment_hooks_default_hooks_dir() {
  local root=$1 common
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    "") return 1 ;;
    /*) ;;
    *) common="$root/$common" ;;
  esac
  printf '%s\n' "$common/hooks"
}

# Prints the pass-through shim names implied by the previous hooks dir, one per
# line, sorted. Relative previous paths resolve against the checkout root. A
# missing previous dir yields no names; an uninspectable dir refuses and names
# the path. Only executable hooks are listed (git skips non-executable hooks
# anyway). An empty previous means the default hooks dir, where only a regular
# file in a real directory counts, and none at all for a [payload] whose
# library predates default shims.
_attachment_hooks_expected_passthrough_names() {
  local root=${1:-} previous=${2:-} payload=${3:-} dir="" entry base regular=false seen=false
  local LC_ALL=C
  case "$previous" in
    "")
      [ -n "$root" ] || return 0
      [ -z "$payload" ] || _attachment_hooks_payload_shims_default "$payload" || return 0
      dir=$(_attachment_hooks_default_hooks_dir "$root") || return 1
      [ ! -L "$dir" ] || return 0
      regular=true
      ;;
    /*) dir="$previous" ;;
    *)
      [ -n "$root" ] || return 0
      dir="$root/$previous"
      ;;
  esac
  # A readable, searchable, nonempty directory is the normal case. Bash's C
  # locale glob is already sorted, and hook names never begin with a dot. If
  # the glob finds no entries, it may be empty or a failed enumeration: ask
  # the slow scanner rather than treating that ambiguity as proof of absence.
  if [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ]; then
    for entry in "$dir"/?* "$dir"/.[!.]* "$dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      seen=true
      base=${entry##*/}
      _attachment_hooks_is_passthrough_name "$base" || continue
      if [ "$regular" = true ] && [ -L "$entry" ]; then
        continue
      fi
      if { [ -f "$entry" ] || [ -L "$entry" ]; } && [ -x "$entry" ]; then
        printf '%s\n' "$base"
      fi
    done
    [ "$seen" = false ] || return 0
  fi
  _attachment_hooks_expected_passthrough_names_slow "$dir" "$regular"
}

_attachment_hooks_expected_passthrough_names_slow() (
  local dir=$1 regular=${2:-false} entry base entries python_helper=""
  if [ "${TRELLIS_LIBS_PRELOADED:-}" = 1 ]; then
    [ -z "${TRELLIS_VERIFIED_PAYLOAD:-}" ] || python_helper="$TRELLIS_VERIFIED_PAYLOAD/scripts/lib/trellis-python.sh"
  else
    [ -z "${_ATTACHMENT_DIR:-}" ] || python_helper="$_ATTACHMENT_DIR/trellis-python.sh"
  fi
  entries=$(mktemp "${TMPDIR:-/tmp}/trellis-hook-names.XXXXXX") || return 3
  trap 'rm -f "${entries:?}"' EXIT
  # Start a clean shell before sourcing the resolver: imported BASH_FUNC_*
  # functions can otherwise override even builtin, command or unset. Keep
  # resolver selection and the filesystem probe inside that same boundary.
  if /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc -c '
    helper=$1
    [ -n "$helper" ] && [ -f "$helper" ] && [ ! -L "$helper" ] || exit 40
    . "$helper" && declare -F trellis_python_trusted >/dev/null || exit 40
    trellis_python_trusted || exit 41
    "$TRELLIS_PYTHON" -I - "$2" <<'"'"'PY'"'"' || exit 42
import os
import sys

try:
    directory = os.scandir(sys.argv[1])
except (FileNotFoundError, NotADirectoryError):
    sys.exit(0)
except OSError:
    sys.exit(1)
try:
    with directory:
        if not os.access(sys.argv[1], os.R_OK | os.X_OK):
            sys.exit(1)
        for entry in directory:
            sys.stdout.buffer.write(os.fsencode(entry.path) + b"\0")
    sys.stdout.buffer.flush()
except OSError:
    sys.exit(1)
PY
  ' _ "$python_helper" "$dir" > "$entries"; then
    :
  else
    case "$?" in
      40) printf 'trellis attachment: trusted python3 interpreter resolver unavailable; cannot classify previous hooks directory: %q\n' "$dir" >&2 ;;
      41) printf 'trellis attachment: trusted python3 interpreter unavailable; cannot classify previous hooks directory: %q\n' "$dir" >&2 ;;
      *) printf 'trellis attachment: cannot enumerate previous hooks directory: %q\n' "$dir" >&2 ;;
    esac
    return 3
  fi
  while IFS= read -r -d '' entry; do
    base=${entry##*/}
    _attachment_hooks_is_passthrough_name "$base" || continue
    if [ "$regular" = true ] && [ -L "$entry" ]; then
      continue
    fi
    if { [ -f "$entry" ] || [ -L "$entry" ]; } && [ -x "$entry" ]; then
      printf '%s\n' "$base"
    fi
  done < "$entries" | /usr/bin/env LC_ALL=C sort
)

# SHA-256 of the exact released shim bytes, including the final newline.
# v1.0.0-rc.52 through v1.3.5 used the first body; v1.3.6 through
# v1.4.2 added DOCKER_HOST. Keep these pins per name, never a pattern match.
_attachment_hooks_released_shim_matches() {
  local path=$1 name=$2 digest
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  _attachment_canonical_file "$path" && _attachment_mode_matches "$path" 700 || return 1
  digest=$(_attachment_hash "$path") || return 1
  case "$name" in
    applypatch-msg) set -- f0edc3dda596331393ffc37963912730ed348f5714ced0a7679e3816836ddd45 91b7b64d06229471593f5374bd900579d97402d03ee723c4d529ca6f0f427a57 ;;
    commit-msg) set -- 984e3d5b9d9696905edb05e611874577ccbcf352e98c7b161e261957729a5fff 76df1734280aa5ce502ab93bbb35a653f7644310ec54817c041797a78998d688 ;;
    fsmonitor-watchman) set -- b3ff21126d42baf40c07c87de2fb1c5a3dbe8e828834fc84e6a5b06c71101b1b 0d148ab47fa27eea7c8a1b50440bec5ae5c8fcf94ee77b45522604955053d905 ;;
    p4-changelist) set -- 30282d92cb32f2e1e8a50e7b578727469a1cd430b2d31a801b636727e1823b91 72c490a2b2a39d029a085b84afefb91a42382258e169dbe98cbc50bc9f742a7e ;;
    p4-post-changelist) set -- 1bc4849728f330b8f279f6f07e426200ed4a50bb6ec0341c93ea0f47a913dec9 53bddbe5af0314d6e8f5272a22c55bfad4e71d7f6c377f6711fa0a6723a1e2d4 ;;
    p4-pre-submit) set -- 6a0869af11084a928538d1b4dc3f32bbca03f9b54eafbbc6b4aa241afd82f993 b2f44d05e29622407d1669d3b4750bb24cc8215fb7affa08c0af08512db57ad9 ;;
    p4-prepare-changelist) set -- aeaf6d297e104312ed1f2da0ab81e0acd88b3e5a6c06de6fbcc5bc72caede9c6 6d4b2cfef0010503b0f530f4946af5518e35d25cd39c0855b01d58cff6272e27 ;;
    post-applypatch) set -- 0d5c2050a9a0e537ff40d5f3f32922ee24b6ede67fd506bd9c1b80017cd0b133 baf1f1bb62436134572ae611fe99c8585dc50b9640ba694aeb64903067365506 ;;
    post-commit) set -- ec0bc5b2271bfe2f782df7e4234ab68700c4d5599ccfad83d415aeed9fc15b3b 22b9b5b6c70dbf2381dfed6c744de4deea02cde1a7f0c9e281929bd795c1ed9d ;;
    post-index-change) set -- fbc26d0014f8c212eb6d502c0fec16413f75c8c9ad7d92843f2a286908bb25e5 097b7d32180ec6831744784f1d97f5c73bbdf9387462eb6eff812c9c91e3367e ;;
    post-merge) set -- 28762acc6a15e29ad4f754c68654c84933ccf95981d295deb6f14f0cb30933a4 1c1a98dbbbf1091278be333ca107537e99d2474bae9975dbbfa30999be4e8e46 ;;
    post-receive) set -- b13b35d7e91380a989c6737f0b871ef5a949e11c17397ab12de85ba3d46f5434 a6be69849b0851fe40cd75b1504f46bfc450c7c35a473642042dc976b8ae161c ;;
    post-rewrite) set -- 0c03334fdeeda97fafaa891d915119f2a2fa54f770cf62ca6626f6799ed4be75 c913fef7959d58753b8c96b35cdee8d4be94ff17c30a2db8cd77a7f8acf0288f ;;
    post-update) set -- 06c0def42dbd2f5eb62a626ecdde67bea1d9b9b3f64dc6653679b939c7eef984 6bbb2bf8384cd6d9c8e04c32cec9908f0a3b158eb5e7b5a14b6e02411430c751 ;;
    pre-applypatch) set -- 324cf024f846a32d155bc6fec847c1de9b4ef11dc972a4eaf1f38d138b7dd10f 49f1a35cc942ca5f870f29178d4fc30b1147a6f315659f2dc92326ddfbc63cab ;;
    pre-auto-gc) set -- 6f8202eebe28a9540ec086305e3e567588fb224ca3d5be42f52a40da6092782c 5bcf1c273d077b136084e9f290ee32ee803633d95e5ac42afb942e1352f1b0d0 ;;
    pre-commit) set -- 5efdca080184f3d17339b80f8b5d4d47e8d6c47c012f6b79e2f9405b7a294442 36b82c9dd9a6bb366ca127f7d3ff22d30eb2ad0a907dad6da442fdf2a952369f ;;
    pre-merge-commit) set -- 3c8ac155ebb632f28e2613faf37c16cb5486fdbbdc02fb93c9438eb145ad3215 6ce02fbcce4398066c0a826c59851f82d2741a1096e3dea3e492463d615d0e38 ;;
    pre-rebase) set -- 7b32f12d34f8fc0565c651532f0baeeb37133bbc4f04452ae529d55f6122a9da 619ad62bd0c642984cc236085d7092a0f42157143a5fdc05f53572b274070288 ;;
    pre-receive) set -- 2cea63494a5ea090fa756f4bd9acd9cb5d7809f6b1f556f49c514a39466996ca 7d83b6ce404286709fa124dd073d86c943d4133e8fe81a40dc24f354fe0386a4 ;;
    prepare-commit-msg) set -- df6fbc31381c1faea3817415b2b2af0f1797c39cc233a0cfa0ff1db8bf30a4ad 8e40f511b2ba8f55a5143677d30c5343e200f1a65179349e020095aae07e7ad3 ;;
    proc-receive) set -- fcb55cc01fb952191018641a80f85ad8ecedc67d128e4291714607364b26e292 565a763db7e16b049334583ac8d6d4185f02699c063e4a2a364f32785df8014a ;;
    push-to-checkout) set -- cb623eca24a421f93c6698e051250010fcc3259992d9576cde7afb59f65fd6b9 3944782b881807b206a5eb01ec6299583e9326829609a7299d9ecc35e43f66bc ;;
    reference-transaction) set -- 0ea1e748c275058a0d70ae4dda005688991f17f38d2ffefa20f7d8959acf6afb a3097277f6fecaf41d04ff5c8b892f9c8b42cb617958e91935a499de0697408d ;;
    sendemail-validate) set -- 2c86da6dc32b1c2a9e84c42f1c7dfc710b0152c2e086f2294302e4a0281cdd51 a2ed3c597f29aa880ed3ce7424b279fd93a3bf4e72147281f533a6f920c64c48 ;;
    update) set -- 689b6ea43f064c244a768a4319221f899c442188641ed56b21c6e6865b790996 c83ac8e34788253edf6e0750b3c883d6d4dd40ca9e1adb5eb3c78d7005967009 ;;
    *) return 1 ;;
  esac
  [ "$digest" = "$1" ] || [ "$digest" = "$2" ]
}

_attachment_hooks_known_shim_matches() {
  local path=$1 name=$2 body
  body=$(_attachment_hooks_passthrough_shim_body "$name") || return 1
  _attachment_hooks_file_matches "$path" "$body" 700 ||
    _attachment_hooks_released_shim_matches "$path" "$name"
}

# <path> is a shim for <name> under <previous>: a recorded predecessor's
# current or released shim, or, with none recorded, the default hooks dir's
# current shim. Default shims were never released, so no digest pins apply.
_attachment_hooks_shim_matches_for() {
  if [ -n "${3:-}" ]; then
    _attachment_hooks_known_shim_matches "$1" "$2"
  else
    _attachment_hooks_file_matches "$1" "$(_attachment_hooks_default_passthrough_shim_body "$2")" 700
  fi
}

# Every pass-through shim present in the managed dir carries deterministic
# bytes, of either shim body or digest-pinned released bytes, and mode 700.
# Needs no checkout root: it validates content, not completeness, so detach
# stays drift-tolerant.
_attachment_hooks_present_shims_match() {
  local managed=${1:-} entry base
  for entry in "$managed"/?* "$managed"/.[!.]* "$managed"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=${entry##*/}
    case "$base" in
      post-checkout|pre-push|previous-hooks-path|release-payload|pre-push-source) continue ;;
    esac
    _attachment_hooks_is_passthrough_name "$base" || return 3
    _attachment_hooks_known_shim_matches "$entry" "$base" ||
      _attachment_hooks_file_matches "$entry" "$(_attachment_hooks_default_passthrough_shim_body "$base")" 700 ||
      return 3
  done
  return 0
}

# The managed dir holds exactly the shims implied by the previous hooks dir:
# every expected shim present with deterministic bytes and mode 700, and no
# shim beyond the expected set, for the release <payload> names.
_attachment_hooks_verify_passthrough_shims() {
  local managed=${1:-} root=${2:-} previous=${3:-} payload=${4:-} expected="" name base entry nl wrapped
  expected=$(_attachment_hooks_expected_passthrough_names "$root" "$previous" "$payload") || return 3
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    _attachment_hooks_shim_matches_for "$managed/$name" "$name" "$previous" || return 3
  done <<<"$expected"
  nl=$(printf '\nx')
  nl=${nl%x}
  wrapped="$nl$expected$nl"
  for entry in "$managed"/?* "$managed"/.[!.]* "$managed"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=${entry##*/}
    case "$base" in
      post-checkout|pre-push|previous-hooks-path|release-payload|pre-push-source) continue ;;
    esac
    _attachment_hooks_is_passthrough_name "$base" || return 3
    case "$wrapped" in
      *"$nl$base$nl"*) ;;
      *) return 3 ;;
    esac
  done
  return 0
}

_attachment_hooks_current_path() {
  local root=$1 values rc count
  # Preserve every value, including trailing empty values, as doctor does.
  values=$(git -C "$root" config --local --get-all core.hooksPath 2>/dev/null && printf '.')
  rc=$?
  values="${values%.}"
  case "$rc" in
    0)
      count=$(printf '%s' "$values" | wc -l | tr -d ' ') || return 4
      [ "$count" -eq 1 ] || return 3
      printf '%s' "$values"
      ;;
    1) printf '\n' ;;
    *) return 4 ;;
  esac
}

# Operator policy 4585ec6 recognizes an exact recorded predecessor as operator authority.
_attachment_hooks_authority() {
  local home=$1 owner=$2 enabled root checkout managed recorded_managed previous current
  [ "$#" -eq 2 ] || return 4
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 4
  root=$(jq -r '
    if type == "object" and (.worktree_root | type == "string" and length > 0)
    then .worktree_root
    else error("invalid worktree root")
    end
  ' "$owner" 2>/dev/null) || return 4
  checkout=$(jq -r '
    if type == "object" and (.checkout_id | type == "string" and length > 0)
    then .checkout_id
    else error("invalid checkout id")
    end
  ' "$owner" 2>/dev/null) || return 4
  enabled=$(jq -r '
    if type != "object" then error("invalid owner")
    elif has("git_hooks") then
      if (.git_hooks | type) == "object"
         and (.git_hooks | has("enabled"))
         and (.git_hooks.enabled | type) == "boolean"
      then .git_hooks.enabled
      else error("invalid git hook owner")
      end
    else false
    end
  ' "$owner" 2>/dev/null) || return 4
  managed="$home/state/git-hooks/$checkout"
  previous=""
  case "$enabled" in
    true)
      recorded_managed=$(jq -r '
        if (.git_hooks | has("managed_hooks_path"))
           and (.git_hooks.managed_hooks_path | type == "string" and length > 0)
        then .git_hooks.managed_hooks_path
        else error("invalid managed hooks path")
        end
      ' "$owner" 2>/dev/null) || return 4
      [ "$recorded_managed" = "$managed" ] || return 3
      previous=$(jq -r '
        if (.git_hooks | has("previous_hooks_path") | not)
        then error("missing previous hooks path")
        elif .git_hooks.previous_hooks_path == null
        then ""
        elif (.git_hooks.previous_hooks_path | type == "string" and length > 0)
        then .git_hooks.previous_hooks_path
        else error("invalid previous hooks path")
        end
      ' "$owner" 2>/dev/null) || return 4
      ;;
    false) ;;
    *) return 4 ;;
  esac
  current=$(_attachment_hooks_current_path "$root") || return $?
  if [ "$current" = "$managed" ]; then
    printf '%s\n' managed
  elif [ "$enabled" = false ] || { [ -n "$previous" ] && [ "$current" = "$previous" ]; }; then
    printf '%s\n' operator-owned
  else
    return 3
  fi
}

# This generator's OWN launcher, never the target payload's. The launcher lives
# beside scripts/lib in the same release tree, so it is oid-verified by the same
# gate that already lets a foreign generator be sourced. Ordinary sourcing sets
# _ATTACHMENT_DIR; the preloaded-bundle route deliberately does not, and binds
# TRELLIS_VERIFIED_PAYLOAD instead. Both spellings resolve to the running
# implementation — the target payload is never a fallback, because an older
# foreign release runs its own generator in a clean subprocess and must keep
# emitting its own bytes.
_attachment_launcher_source() {
  local candidate="" directory=""
  if [ -n "${_ATTACHMENT_DIR:-}" ]; then
    case "$_ATTACHMENT_DIR" in
      */scripts/lib) candidate="${_ATTACHMENT_DIR%/lib}/trellis-launcher.sh" ;;
      *) return 1 ;;
    esac
  elif [ -n "${TRELLIS_VERIFIED_PAYLOAD:-}" ]; then
    case "$TRELLIS_VERIFIED_PAYLOAD" in
      /*/payload) candidate="$TRELLIS_VERIFIED_PAYLOAD/scripts/trellis-launcher.sh" ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  trellis_dirname_to directory "$candidate" || :
  directory="$(CDPATH='' cd "$directory" && pwd -P)" || return 1
  printf '%s\n' "$directory/${candidate##*/}"
}

# This library's own file, located the same way as the launcher above, so the
# dispatcher can embed a library function verbatim rather than a second copy.
_attachment_library_source() {
  local launcher="" candidate=""
  launcher="$(_attachment_launcher_source)" || return 1
  candidate="${launcher%/*}/lib/attachment.sh"
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

# Extract one complete, fixed-name shell function definition verbatim. Refuses
# a missing, duplicated, truncated or empty definition, and refuses text that
# does not parse, so a broken emitter can never reach a generated dispatcher.
# See the EXTRACTION CONTRACT comment in scripts/trellis-launcher.sh.
_attachment_extract_shell_function() {
  local file=$1 name=$2 text=""
  text="$(/usr/bin/awk -v open="$name() {" '
    $0 == open { opens++; depth = 1 }
    depth { print }
    depth && $0 == "}" { depth = 0; closes++ }
    END { if (opens != 1 || closes != 1 || depth) exit 1 }
  ' "$file")" || return 1
  [ -n "$text" ] || return 1
  printf '%s\n' "$text" | /bin/bash --noprofile --norc -n || return 1
  printf '%s\n' "$text"
}

_attachment_command_scratch_emitters() {
  local launcher="" create="" remove=""
  launcher="$(_attachment_launcher_source)" || return 1
  create="$(_attachment_extract_shell_function "$launcher" launcher_command_scratch_create_program)" || return 1
  remove="$(_attachment_extract_shell_function "$launcher" launcher_command_scratch_remove_program)" || return 1
  printf '%s\n%s\n' "$create" "$remove"
}

# The release stamp program (release_stamp.py beside this library), emitted as
# a function that prints it. The dispatcher checks a payload before trusting
# any file in it, so it carries the program rather than running the payload's
# copy. Refuses a program with a single quote, which would end the wrapper.
_attachment_release_stamp_emitter() {
  local library="" program="" text=""
  library="$(_attachment_library_source)" || return 1
  program="${library%/*}/release_stamp.py"
  [ -f "$program" ] && [ ! -L "$program" ] || return 1
  text="$(cat "$program")" || return 1
  [ -n "$text" ] || return 1
  case "$text" in *"'"*) return 1 ;; esac
  text="trellis_release_stamp_program() {
  printf '%s' '$text
'
}"
  printf '%s\n' "$text" | /bin/bash --noprofile --norc -n || return 1
  printf '%s\n' "$text"
}

# A fourth argument "post-checkout" leaves out what only pre-push uses (the
# gate environment list) and wraps the private scratch allocation in
# trellis_enter_command_scratch, so a file checkout can run the prior hook and
# exit before it; the post-checkout body calls it for everything else.
_attachment_hooks_dispatcher_common_body() {
  local payload=${1:-} source=${2:-} manifest_sha256=${3:-} kind=${4:-} emitters="" library="" predicate="" stamp=""
  emitters="$(_attachment_command_scratch_emitters)" || return 1
  library="$(_attachment_library_source)" || return 1
  predicate="$(_attachment_extract_shell_function "$library" trellis_toolchain_control_only)" || return 1
  stamp="$(_attachment_release_stamp_emitter)" || return 1
  cat <<'EOF'
#!/bin/bash -p
caller_path=${PATH-}
caller_home=${HOME-}
caller_tmpdir=${TMPDIR-}
caller_xdg_config_set=${XDG_CONFIG_HOME+x}
caller_xdg_config=${XDG_CONFIG_HOME-}
trellis_gate_env_name_safe() {
  local name=${1:-}
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}
caller_gate_env=()
trellis_collect_gate_env() {
  local trellis_env_root=${1:-} trellis_env_names="" trellis_env_name trellis_env_ifs trellis_env_decl
  local trellis_env_policy=none
  local -a trellis_env_names_array=()
  caller_gate_env=()
  [ -x /usr/bin/git ] && [ -x /usr/bin/python3 ] || return 0
  trellis_env_names="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
    /usr/bin/python3 -I -c '
import json, re, subprocess, sys

root = sys.argv[1]
env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/dev/null",
       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
       "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_OPTIONAL_LOCKS": "0"}


def git(*args):
    try:
        return subprocess.run(["/usr/bin/git", "-C", root, *args],
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


symbolic = git("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
if symbolic is None or symbolic.returncode != 0:
    sys.exit(0)
resolved = git("rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD^{commit}")
if resolved is None or resolved.returncode != 0:
    sys.exit(0)
commit = resolved.stdout.decode("ascii", "strict").strip()
if re.fullmatch("[0-9a-f]{40}|[0-9a-f]{64}", commit) is None:
    sys.exit(0)
tree = git("ls-tree", "-z", commit, "--", ".trellis.json")
if tree is None or tree.returncode != 0:
    sys.exit(0)
records = tree.stdout.split(b"\0")
if len(records) != 2 or not records[0]:
    sys.exit(0)
match = re.fullmatch(rb"(?:100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})\t\.trellis\.json", records[0])
if match is None:
    sys.exit(0)
manifest = git("cat-file", "blob", match.group(1).decode("ascii"))
if manifest is None or manifest.returncode != 0:
    sys.exit(0)
try:
    document = json.loads(manifest.stdout.decode("utf-8"), object_pairs_hook=unique_object)
except (UnicodeError, ValueError):
    sys.exit(0)
if not isinstance(document, dict):
    sys.exit(0)
gate = document.get("gate", {})
if (not isinstance(gate, dict) or set(gate) - {"env_passthrough", "verdict_reuse"}
        or not isinstance(gate.get("verdict_reuse", True), bool)):
    sys.exit(0)
names = gate.get("env_passthrough", [])
if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
    sys.exit(0)
if len(names) != len(set(names)):
    sys.exit(0)
reserved = {"PATH", "HOME", "TMP", "TMPDIR", "TEMP", "BASH_ENV", "ENV", "SHELLOPTS",
            "BASHOPTS", "IFS", "CDPATH", "NODE_OPTIONS", "DOCKER_HOST", "DOCKER_CONTEXT",
            "POSIXLY_CORRECT", "ZDOTDIR", "RUBYOPT", "PERL5OPT", "JAVA_TOOL_OPTIONS",
            "JDK_JAVA_OPTIONS", "PWD", "OLDPWD", "SHLVL", "_", "LANG", "LANGUAGE", "TZ",
            "NODE_PATH", "NODE_REPL_EXTERNAL_MODULE", "NODE_EXTRA_CA_CERTS", "NODE_ICU_DATA", "NODE_V8_COVERAGE",
            "RANDOM", "SRANDOM", "SECONDS", "LINENO", "OPTIND", "OPTARG", "PPID", "UID", "EUID",
            "GROUPS", "DIRSTACK", "FUNCNAME", "PIPESTATUS", "SHELL", "PS1", "PS2", "PS3", "PS4"}
prefixes = ("XDG_", "TMP", "TEMP", "GIT_", "TRELLIS_", "PROCESS_GATE_",
            "SECURITY_GATE_", "PYTHON", "BASH", "LD_", "DYLD_", "CALLER_", "LC_",
            "DOCKER_", "COREPACK_", "PERL", "RUBY", "GEM_", "GH_")
for name in names:
    if re.fullmatch("[A-Za-z_][A-Za-z0-9_]*", name) is None:
        sys.exit(0)
    upper = name.upper()
    if any(secret in upper for secret in ("TOKEN", "SECRET", "KEY", "PASSWORD")):
        sys.exit(0)
    if upper in reserved or upper.startswith(prefixes):
        sys.exit(0)
# The policy identity first, so the gate keys the same policy it was forwarded.
print("@" + match.group(1).decode("ascii"))
for name in names:
    print(name)
' "$trellis_env_root" 2>/dev/null)" || trellis_env_names=""
  trellis_env_ifs=$IFS
  IFS=$'\n'
  set -f
  trellis_env_names_array=( $trellis_env_names )
  set +f
  IFS=$trellis_env_ifs
  for trellis_env_name in "${trellis_env_names_array[@]}"; do
    [ -n "$trellis_env_name" ] || continue
    case "$trellis_env_name" in
      @*) trellis_env_policy=${trellis_env_name#@}; continue ;;
    esac
    trellis_gate_env_name_safe "$trellis_env_name" || return 1
    trellis_env_decl="$(declare -p "$trellis_env_name" 2>/dev/null)" || continue
    trellis_env_decl="${trellis_env_decl#declare -}"
    trellis_env_decl="${trellis_env_decl%% *}"
    # Only exported caller values, never non-exported shell internals. All
    # collector locals use the denied TRELLIS_ namespace to avoid shadowing.
    case "$trellis_env_decl" in
      *x*) caller_gate_env+=("$trellis_env_name=${!trellis_env_name}") ;;
    esac
  done
  # Last, and never a caller value: TRELLIS_ names are refused above.
  caller_gate_env+=("TRELLIS_GATE_ENV_POLICY=$trellis_env_policy")
}
# Resolve a context with the caller's HOME before isolation, forwarding only
# its endpoint. The caller's XDG config path is retained as a positional input
# for the single pnpm-setting query; neither value is exported to payloads.
# An explicit DOCKER_HOST, including an empty one, always wins.
caller_docker_host_set=${DOCKER_HOST+x}
caller_docker_host=${DOCKER_HOST-}
if [ "$caller_docker_host_set" != x ] && [ "${DOCKER_CONTEXT+x}" = x ]; then
  if caller_docker_host=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' </dev/null 2>/dev/null) && [ -n "$caller_docker_host" ]; then
    caller_docker_host_set=x
  else
    printf 'Trellis: cannot resolve Docker context "%s"; continuing without DOCKER_HOST.\n' \
      "$(printf '%s' "$DOCKER_CONTEXT" | /usr/bin/env LC_ALL=C /usr/bin/tr '[:cntrl:]' '?')" >&2
  fi
fi
EOF
  if [ "$kind" != post-checkout ]; then
    cat <<'EOF'
trellis_env_project_root="$(CDPATH='' cd . && pwd -P)" || exit 1
if ! trellis_collect_gate_env "$trellis_env_project_root"; then
  caller_gate_env=()
  printf 'trellis gate: refused (env-passthrough): invalid protected gate environment list\n' >&2
fi
EOF
  fi
  cat <<'EOF'
exec /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME=/dev/null \
  LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TRELLIS_ALLOW_MAIN_PUSH="${TRELLIS_ALLOW_MAIN_PUSH-}" \
  SECURITY_GATE_SKIP="${SECURITY_GATE_SKIP-}" \
  /bin/bash --noprofile --norc -c '
dispatcher=$1
caller_path=$2
caller_home=$3
caller_tmpdir=$4
caller_docker_host_set=$5
caller_docker_host=$6
caller_xdg_config_set=$7
caller_xdg_config=$8
[ "$#" -ge 9 ] || exit 1
caller_gate_env_count=$9
case "$caller_gate_env_count" in ""|*[!0-9]*) exit 1 ;; esac
shift 9
caller_gate_env=()
while [ "$caller_gate_env_count" -gt 0 ]; do
  [ "$#" -gt 0 ] || exit 1
  caller_gate_env+=("$1")
  shift
  caller_gate_env_count=$((caller_gate_env_count - 1))
done
/usr/bin/grep -qx "# trellis-managed-dispatcher-body" "$dispatcher" || exit 1
body="$(/usr/bin/awk "seen { print } /^# trellis-managed-dispatcher-body\$/ { seen=1 }" "$dispatcher")" || exit 1
[ -n "$body" ] || exit 1
TRELLIS_MANAGED_DISPATCHER="$dispatcher"
export TRELLIS_MANAGED_DISPATCHER
eval "$body"
' trellis-managed-dispatcher "$0" "$caller_path" "$caller_home" "$caller_tmpdir" "$caller_docker_host_set" "$caller_docker_host" "$caller_xdg_config_set" "$caller_xdg_config" "${#caller_gate_env[@]}" "${caller_gate_env[@]}" "$@"
# trellis-managed-dispatcher-body
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
HOME=/dev/null
LC_ALL=C
GIT_CONFIG_NOSYSTEM=1
GIT_CONFIG_GLOBAL=/dev/null
export PATH HOME LC_ALL GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
export TRELLIS_ALLOW_MAIN_PUSH SECURITY_GATE_SKIP
readonly PATH HOME GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
# TMPDIR/TMP/TEMP are deliberately absent until the private command scratch
# below exists: the outer env -i drops the caller's, and nothing here may
# allocate a temporary — no here-document, no here-string, no mktemp — before
# then, because Bash 3.2 spools a here-document through $TMPDIR.
managed_dispatcher="${TRELLIS_MANAGED_DISPATCHER:?}"
unset TRELLIS_MANAGED_DISPATCHER
project_root="$(CDPATH= cd . && pwd -P)" || exit 1
cd "$project_root" || exit 1
managed_dir="$(CDPATH= cd "$(dirname "$managed_dispatcher")" && pwd -P)" || exit 1
managed_home="$(CDPATH= cd "$managed_dir/../../.." && pwd -P)" || exit 1
readonly project_root managed_dir managed_home
# trellis-command-scratch-begin
EOF
  printf '%s\n' "$emitters"
  cat <<'EOF'
trellis_scratch=""
trellis_scratch_root=""
trellis_scratch_name=""
trellis_scratch_identity=""
trellis_scratch_root_identity=""

# Mirrors launcher_derive_command_scratch: run the extracted allocator with an
# isolated interpreter and keep the four recorded values in memory only. There
# is no sidecar and no second allocator.
trellis_derive_command_scratch() {
  local home="$1" python_bin="" program="" record="" rest="" name=""
  local scratch_identity="" root_identity=""
  python_bin="$(command -v python3)" || {
    printf 'trellis managed hook: python3 is required for the private command scratch directory\n' >&2
    return 1
  }
  case "$python_bin" in /*) ;; *) return 1 ;; esac
  program="$(launcher_command_scratch_create_program)" || return 1
  [ -n "$program" ] || return 1
  record="$(/usr/bin/env LC_ALL=C "$python_bin" -I -c "$program" "$home")" || return 1
  case "$record" in
    *$'\t'*$'\t'*) ;;
    *) return 1 ;;
  esac
  name="${record%%$'\t'*}"
  rest="${record#*$'\t'}"
  scratch_identity="${rest%%$'\t'*}"
  root_identity="${rest#*$'\t'}"
  case "$name" in .cmd.*) ;; *) return 1 ;; esac
  case "${name#.cmd.}" in ''|*[!0-9a-f]*) return 1 ;; esac
  [[ "$scratch_identity" =~ ^[0123456789]+:[0123456789]+$ ]] || return 1
  [[ "$root_identity" =~ ^[0123456789]+:[0123456789]+$ ]] || return 1
  trellis_scratch_root="$home/state/scratch"
  trellis_scratch_name="$name"
  trellis_scratch_identity="$scratch_identity"
  trellis_scratch_root_identity="$root_identity"
  trellis_scratch="$trellis_scratch_root/$name"
}

# Remove exactly the recorded directory, or refuse and name what was retained.
# Consumed state is cleared first, so the signal path and the EXIT trap that
# follows it cannot both act on — or both complain about — the same directory.
# Refusal returns nonzero. The EXIT handler promotes only an otherwise-green
# command while preserving prior-hook, carrier and signal precedence.
trellis_cleanup_command_scratch() {
  local scratch="$trellis_scratch" root="$trellis_scratch_root"
  local name="$trellis_scratch_name" identity="$trellis_scratch_identity"
  local root_identity="$trellis_scratch_root_identity"
  local python_bin="" program=""
  trellis_scratch=""
  trellis_scratch_root=""
  trellis_scratch_name=""
  trellis_scratch_identity=""
  trellis_scratch_root_identity=""
  [ -n "$scratch" ] || return 0
  if ! python_bin="$(command -v python3)" ||
    ! program="$(launcher_command_scratch_remove_program)" ||
    ! LC_ALL=C "$python_bin" -I -c "$program" \
      "$root" "$name" "$identity" "$root_identity"; then
    printf 'trellis managed hook: could not clean command scratch directory: %s\n' \
      "$scratch" >&2
    return 1
  fi
  return 0
}

EOF
  [ "$kind" != post-checkout ] || printf 'trellis_enter_command_scratch() {\n'
  cat <<'EOF'
trellis_derive_command_scratch "$managed_home" || {
  printf 'trellis managed hook: could not create a private command scratch directory under %s\n' \
    "$managed_home" >&2
  exit 1
}
trap 'trellis_exit_status=$?; trap - EXIT; if ! trellis_cleanup_command_scratch; then [ "$trellis_exit_status" -ne 0 ] || trellis_exit_status=1; fi; exit "$trellis_exit_status"' EXIT
trap 'trellis_cleanup_command_scratch; exit 129' HUP
trap 'trellis_cleanup_command_scratch; exit 130' INT
trap 'trellis_cleanup_command_scratch; exit 143' TERM
TMPDIR="$trellis_scratch"
TMP="$TMPDIR"
TEMP="$TMPDIR"
export TMPDIR TMP TEMP
readonly TMPDIR TMP TEMP
EOF
  [ "$kind" != post-checkout ] || printf '}\n'
  cat <<'EOF'
# trellis-command-scratch-end
# trellis-gate-xdg-begin
# Writable XDG dirs for node toolchains (corepack/pnpm) under managed state,
# never the real HOME. Control payloads keep HOME=/dev/null; gate payloads
# use a per-command private HOME inside the command scratch.
gate_xdg_base="$managed_home/state/gate-xdg"
gate_xdg_config="$gate_xdg_base/config"
gate_xdg_cache="$gate_xdg_base/cache"
gate_umask="$(umask)" || gate_umask=022
umask 077
mkdir -p "$gate_xdg_config" "$gate_xdg_cache" "$gate_xdg_cache/node/corepack" 2>/dev/null || true
umask "$gate_umask"
chmod 700 "$gate_xdg_base" "$gate_xdg_config" "$gate_xdg_cache" 2>/dev/null || true
XDG_CONFIG_HOME="$gate_xdg_config"
XDG_CACHE_HOME="$gate_xdg_cache"
COREPACK_HOME="$gate_xdg_cache/node/corepack"
export XDG_CONFIG_HOME XDG_CACHE_HOME COREPACK_HOME
# trellis-gate-xdg-end
EOF
  printf 'expected_payload=%q\n' "$payload"
  printf 'expected_pre_push_source=%q\n' "$source"
  printf 'expected_release_manifest_sha256=%q\n' "$manifest_sha256"
  printf '%s\n' "$stamp"
  cat <<'EOF'

trellis_read_sidecar() {
  local path="$1" allow_empty="${2:-false}" line="" candidate="" count=0
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r candidate || [ -n "$candidate" ]; do
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    line="$candidate"
    candidate=""
  done < "$path"
  [ "$count" -eq 1 ] || return 1
  case "$line" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  [ "$allow_empty" = true ] || [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

trellis_hash_file() {
  local path="$1" output=""
  output="$(shasum -a 256 "$path" 2>/dev/null)" ||
    output="$(sha256sum "$path" 2>/dev/null)" || return 1
  printf '%s\n' "${output%% *}"
}

trellis_hash_text() {
  local output=""
  output="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)" ||
    output="$(printf '%s' "$1" | sha256sum 2>/dev/null)" || return 1
  printf '%s\n' "${output%% *}"
}

# Spec 055 R2.1: each failure has its own first line and, where one exists, a
# remedy line. Only an entry that is no longer a canonical directory says
# "toolchain moved". Every failure returns 1 (R2.2).
trellis_gate_toolchain_path() {
  local common="" gitdir="" checkout="" worktree="" owner="" mode="" entries="" entry="" toolchain_path=""
  common="$(/usr/bin/git -C "$project_root" rev-parse --git-common-dir 2>/dev/null)" || common=""
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$project_root/$common" ;; esac
    common="$(CDPATH= cd "$common" && pwd -P 2>/dev/null)" || common=""
  fi
  if [ -n "$common" ]; then
    checkout="$(trellis_hash_text "$common")" || checkout=""
    worktree="$(trellis_hash_text "$project_root")" || worktree=""
  fi
  if [ -z "$checkout" ] || [ -z "$worktree" ]; then
    printf 'trellis gate: cannot identify the checkout: %s\n' "$project_root" >&2
    return 1
  fi
  owner="$managed_home/state/attachments/$checkout/$worktree.json"
  if [ -L "$owner" ]; then
    printf 'trellis gate: record unsafe (symlink): %s\n' "$owner" >&2
    return 1
  fi
  if [ ! -e "$owner" ]; then
    printf 'trellis gate: not attached: %s\n' "$project_root" >&2
    gitdir="$(/usr/bin/git -C "$project_root" rev-parse --absolute-git-dir 2>/dev/null)" || gitdir=""
    if [ -n "$gitdir" ]; then
      gitdir="$(CDPATH= cd "$gitdir" && pwd -P 2>/dev/null)" || gitdir=""
    fi
    if [ -n "$gitdir" ] && [ "$gitdir" != "$common" ]; then
      printf 'trellis gate: run `trellis worktree sync %s`\n' "$project_root" >&2
    else
      printf 'trellis gate: run `trellis attach %s`\n' "$project_root" >&2
    fi
    return 1
  fi
  if [ ! -f "$owner" ]; then
    printf 'trellis gate: record unsafe (not a regular file): %s\n' "$owner" >&2
    return 1
  fi
  mode="$(trellis_mode "$owner" 2>/dev/null)" || mode=""
  if [ "$mode" != 600 ]; then
    printf 'trellis gate: record unsafe (mode %s, expected 600): %s\n' "${mode:-unreadable}" "$owner" >&2
    return 1
  fi
  entries="$(jq -er \
    --arg checkout "$checkout" --arg worktree "$worktree" --arg root "$project_root" '
      if .schema_version == 1
         and .status == "committed"
         and .checkout_id == $checkout
         and .worktree_id == $worktree
         and .project_root == $root
         and .worktree_root == $root
         and (.toolchain_path | type == "array" and length > 0)
         and all(.toolchain_path[];
           type == "string" and startswith("/") and . != "/"
           and (endswith("/") | not) and (contains("//") | not)
           and (test("(^|/)\\.\\.?(/|$)") | not)
           and (test("[[:cntrl:]]") | not))
      then .toolchain_path[]
      else error("invalid recorded toolchain PATH")
      end
    ' "$owner" 2>/dev/null)" || {
    printf 'trellis gate: record invalid, re-attach: %s\n' "$owner" >&2
    return 1
  }
  while IFS= read -r entry; do
    if [ -n "$toolchain_path" ]; then
      toolchain_path="$toolchain_path:$entry"
    else
      toolchain_path="$entry"
    fi
  done <<< "$entries"
  # A known-bad record blocks the push instead of passing silently, whatever
  # recorded it.
  if trellis_toolchain_control_only "$toolchain_path"; then
    printf 'trellis gate: toolchain is the sanitized control PATH: %s\n' "$owner" >&2
    printf 'trellis gate: run `trellis attach --refresh-toolchain %s`\n' "$project_root" >&2
    return 1
  fi
  while IFS= read -r entry; do
    if ! trellis_canonical_dir "$entry"; then
      printf 'trellis gate: toolchain moved, re-attach: %s\n' "$entry" >&2
      return 1
    fi
  done <<< "$entries"
  printf '%s\n' "$toolchain_path"
}

# This function is emitted VERBATIM into the managed dispatcher body (it is
# inside the heredoc above), and the dispatcher runs with no library sourced.
# So it may call only functions emitted into that same body — trellis_readonly
# and trellis_release_mode below do exactly that, and call this one. What it
# cannot call is a library-only helper: _attachment_stat_mode is not emitted,
# which is why the dialect handling below is duplicated here rather than shared.
# The BSD and GNU stat probes are captured separately because GNU `stat -f` is
# --file-system and prints a whole filesystem block on stdout before failing on
# the format operand; chained in one substitution that block concatenates with
# the GNU mode. The BSD result is shape-checked (1-4 octal digits) rather than
# trusted on exit status alone, for the same reason.
trellis_mode() {
  local path="$1" candidate=""
  candidate="$(stat -f %Lp "$path" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  [ "${#candidate}" -ge 1 ] && [ "${#candidate}" -le 4 ] || candidate=""
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %a "$path" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

# Darwin's ls prints an xattr's "@" in place of an ACL's "+", so list the ACL
# entries with -e: any line after the first is one. Where ls has no -e (GNU)
# the "+" is reliable. A Darwin -e failure refuses rather than retrying
# ACL-blind.
trellis_readonly() {
  local path="$1" permissions="" mode="" numeric
  permissions="$(/usr/bin/env LC_ALL=C /bin/ls -lde -- "$path" 2>/dev/null)" || {
    [ "$(/usr/bin/uname -s 2>/dev/null)" != Darwin ] || return 1
    permissions="$(/usr/bin/env LC_ALL=C /bin/ls -ld -- "$path" 2>/dev/null)" || return 1
  }
  case "$permissions" in *"
"*) return 1 ;; esac
  permissions="${permissions%% *}"
  case "$permissions" in ''|*+*) return 1 ;; esac
  mode="$(trellis_mode "$path")" || return 1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  numeric=$((8#$mode))
  [ $((numeric & 0222)) -eq 0 ]
}

trellis_canonical_dir() {
  local path="$1" actual=""
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  actual="$(CDPATH= cd "$path" && pwd -P)" || return 1
  [ "$actual" = "$path" ]
}

trellis_release_path_safe() {
  case "${1:-}" in
    ''|/*|.|..|./*|../*|*/../*|*/..|*/./*|*/.|*/|*'//'*) return 1 ;;
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
}

trellis_release_link_safe() {
  local link_path="$1" target="$2" parent="" rest="" component="" resolved=""
  trellis_release_path_safe "$link_path" || return 1
  [ -n "$target" ] || return 1
  case "$target" in
    /*|*'//'*) return 1 ;;
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$link_path" in */*) parent="${link_path%/*}" ;; esac
  if [ -n "$parent" ]; then
    rest="$parent/$target"
  else
    rest="$target"
  fi
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
      *) component="$rest"; rest="" ;;
    esac
    case "$component" in
      ""|.) ;;
      ..)
        [ -n "$resolved" ] || return 1
        case "$resolved" in */*) resolved="${resolved%/*}" ;; *) resolved="" ;; esac
        ;;
      *)
        if [ -n "$resolved" ]; then
          resolved="$resolved/$component"
        else
          resolved="$component"
        fi
        ;;
    esac
  done
}

trellis_release_mode() {
  local path="$1" mode=""
  if [ -L "$path" ]; then
    printf '120000\n'
    return 0
  fi
  [ -f "$path" ] || return 1
  mode="$(trellis_mode "$path")" || return 1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  if [ $((8#$mode & 0111)) -eq 0 ]; then
    printf '100644\n'
  else
    printf '100755\n'
  fi
}

trellis_release_blob_oid() {
  local path="$1" target="" size="" output=""
  if [ -L "$path" ]; then
    target="$(readlink "$path")" || return 1
    size="$(printf '%s' "$target" | /usr/bin/env LC_ALL=C wc -c | tr -d ' ')" || return 1
    if command -v shasum >/dev/null 2>&1; then
      output="$(
        set -o pipefail
        { printf 'blob %s\000' "$size"; printf '%s' "$target"; } | shasum -a 1 2>/dev/null
      )" || return 1
    else
      output="$(
        set -o pipefail
        { printf 'blob %s\000' "$size"; printf '%s' "$target"; } | sha1sum 2>/dev/null
      )" || return 1
    fi
  else
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    # No temporary LC_ALL= in a redirected command substitution (bash 5.3 under
    # Node segfaults); wc -c counts bytes in every locale.
    size="$(wc -c < "$path" | tr -d ' ')" || return 1
    if command -v shasum >/dev/null 2>&1; then
      output="$(
        set -o pipefail
        { printf 'blob %s\000' "$size"; cat "$path"; } | shasum -a 1 2>/dev/null
      )" || return 1
    else
      output="$(
        set -o pipefail
        { printf 'blob %s\000' "$size"; cat "$path"; } | sha1sum 2>/dev/null
      )" || return 1
    fi
  fi
  printf '%s\n' "${output%% *}"
}

trellis_release_manifest_valid() {
  local release_json="$1" version="$2"
  jq -e --arg version "$version" '
    def semver:
      "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\\+([0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*))?$";
    def keyset($keys): (keys_unsorted | sort) == ($keys | sort);
    def safe_relative_path:
      type == "string"
      and length > 0
      and (startswith("/") | not)
      and (endswith("/") | not)
      and (contains("//") | not)
      and (contains("\u0000") | not)
      and (contains("\t") | not)
      and (contains("\n") | not)
      and (contains("\r") | not)
      and (test("(^|/)\\.(/|$)") | not)
      and (test("(^|/)\\.\\.(/|$)") | not);
    type == "object"
    and (
      keyset(["schema_version", "version", "tag", "commit", "remote", "tree"])
      or keyset(["$schema", "schema_version", "version", "tag", "commit", "remote", "tree"])
    )
    and ((has("$schema") | not) or (."$schema" | type == "string" and length > 0))
    and .schema_version == 1
    and (.version | type == "string" and . == $version and test(semver))
    and (.tag == ("v" + .version))
    and (.commit | type == "string" and test("^[a-f0-9]{40}$"))
    and (.remote | type == "string" and length > 0)
    and (.tree | type == "array" and length > 0)
    and ([.tree[].path] | length == (unique | length))
    and all(.tree[];
      type == "object"
      and keyset(["path", "mode", "oid"])
      and (.path | safe_relative_path)
      and (.mode == "100644" or .mode == "100755" or .mode == "120000")
      and (.oid | type == "string" and test("^[a-f0-9]{40}$"))
    )
  ' "$release_json" >/dev/null 2>&1
}

# The sealed-store checks both release checks below share: the store layout,
# the read-only release and payload directories, release.json's pinned sha256
# and manifest shape, and nothing beside release.json and payload.
trellis_verify_release_anchor() {
  local payload="${1:-}" release_dir="" releases_dir="" release_json="" version="" hash=""
  local entry="" base="" parent=""

  [ -n "$expected_release_manifest_sha256" ] || return 1
  [ "$payload" = "$expected_payload" ] || return 1
  case "$payload" in /*) ;; *) return 1 ;; esac
  release_dir="${payload%/payload}"
  [ "$release_dir/payload" = "$payload" ] || return 1
  releases_dir="${release_dir%/*}"
  [ -n "$releases_dir" ] || releases_dir=/
  [ "$releases_dir" = "$managed_home/releases" ] || return 1
  [ -d "$managed_home" ] && [ ! -L "$managed_home" ] || return 1
  trellis_canonical_dir "$managed_home" || return 1
  trellis_canonical_dir "$releases_dir" || return 1
  trellis_canonical_dir "$release_dir" || return 1
  trellis_readonly "$release_dir" || return 1
  trellis_canonical_dir "$payload" || return 1
  trellis_readonly "$payload" || return 1
  version="${release_dir##*/}"
  [ -n "$version" ] || return 1
  release_json="$release_dir/release.json"
  [ -f "$release_json" ] && [ ! -L "$release_json" ] || return 1
  parent="${release_json%/*}"
  trellis_canonical_dir "$parent" || return 1
  trellis_readonly "$release_json" || return 1
  hash="$(trellis_hash_file "$release_json")" || return 1
  [ "$hash" = "$expected_release_manifest_sha256" ] || return 1
  trellis_release_manifest_valid "$release_json" "$version" || return 1
  for entry in "$release_dir"/?* "$release_dir"/.[!.]* "$release_dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="${entry##*/}"
    case "$base" in release.json|payload) ;; *) return 1 ;; esac
  done
}

# Spec 072 D-A: the release stamp (release_stamp.py, carried above) is a stat
# manifest with ctime of a release a full verify passed, under
# state/release-stamps. "check" passes only when every entry is unchanged since;
# any change, or an absent, unreadable or foreign stamp, falls back to the full
# verify, and "write" follows only that verify's success. Every call sweeps
# afresh, so no verdict crosses the pre-push prior-hook boundary. A hit is exit
# 0 with the program's "hit" line, so a python3 that exits 0 without running
# the program is a miss.
trellis_release_stamp() {
  local python_bin="" program=""
  python_bin="$(command -v python3)" || return 1
  case "$python_bin" in /*) ;; *) return 1 ;; esac
  program="$(trellis_release_stamp_program)" || return 1
  /usr/bin/env LC_ALL=C "$python_bin" -I -c "$program" "$@" 2>/dev/null
}

trellis_verify_release() {
  local payload="${1:-}" token=""
  trellis_verify_release_anchor "$payload" || return 1
  if token="$(trellis_release_stamp check "$managed_home" "${payload%/payload}")" && [ "$token" = hit ]; then
    return 0
  fi
  trellis_verify_release_tree "$payload" || return 1
  # Best effort: an unwritten stamp only means the next call verifies in full.
  trellis_release_stamp write "$managed_home" "${payload%/payload}" "$token" >/dev/null || :
}

# The full per-file verify, after the anchor.
trellis_verify_release_tree() (
  local payload="${1:-}" release_dir="" release_json="" version=""
  local tmpdir="" manifest_paths="" manifest_dirs="" actual_paths="" actual_dirs=""
  local mode="" oid="" path="" full="" parent="" actual_mode="" actual_oid="" target="" rel=""

  release_dir="${payload%/payload}"
  version="${release_dir##*/}"
  release_json="$release_dir/release.json"

  # Scratch belongs in this invocation's own private command scratch, never in
  # ambient temp space and no longer beside the sealed release store: TMPDIR is
  # the readonly directory allocated under the Trellis home above. The trap is
  # subshell-local — this function is a ( ) body — so it stays independent of
  # the command scratch cleanup armed for the dispatcher itself.
  tmpdir="$(mktemp -d "$TMPDIR/verify.$version.XXXXXX")" || return 1
  trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
  manifest_paths="$tmpdir/manifest.paths"
  manifest_dirs="$tmpdir/manifest.dirs"
  actual_paths="$tmpdir/actual.paths"
  actual_dirs="$tmpdir/actual.dirs"
  jq -r '.tree[].path' "$release_json" > "$manifest_paths" || return 1
  : > "$manifest_dirs"
  while IFS= read -r path; do
    rel="$path"
    while [ "${rel%/*}" != "$rel" ]; do
      rel="${rel%/*}"
      printf '%s\n' "$rel" >> "$manifest_dirs" || return 1
    done
  done < "$manifest_paths"
  sort "$manifest_paths" > "$manifest_paths.sorted" || return 1
  sort -u "$manifest_dirs" > "$manifest_dirs.sorted" || return 1

  while IFS=$'\t' read -r mode oid path; do
    trellis_release_path_safe "$path" || return 1
    full="$payload/$path"
    case "$path" in */*) parent="$payload/${path%/*}" ;; *) parent="$payload" ;; esac
    trellis_canonical_dir "$parent" || return 1
    [ -e "$full" ] || [ -L "$full" ] || return 1
    actual_mode="$(trellis_release_mode "$full")" || return 1
    [ "$actual_mode" = "$mode" ] || return 1
    if [ "$actual_mode" = 120000 ]; then
      target="$(readlink "$full")" || return 1
      trellis_release_link_safe "$path" "$target" || return 1
    else
      trellis_readonly "$full" || return 1
    fi
    actual_oid="$(trellis_release_blob_oid "$full")" || return 1
    [ "$actual_oid" = "$oid" ] || return 1
  done < <(jq -r '.tree[] | [.mode, .oid, .path] | @tsv' "$release_json")

  find "$payload" -mindepth 1 -print0 > "$tmpdir/actual.raw" || return 1
  : > "$actual_paths"
  : > "$actual_dirs"
  while IFS= read -r -d '' full; do
    rel="${full#$payload/}"
    [ "$rel" != "$full" ] || return 1
    trellis_release_path_safe "$rel" || return 1
    if [ -L "$full" ] || [ -f "$full" ]; then
      printf '%s\n' "$rel" >> "$actual_paths" || return 1
    elif [ -d "$full" ]; then
      trellis_canonical_dir "$full" || return 1
      trellis_readonly "$full" || return 1
      printf '%s\n' "$rel" >> "$actual_dirs" || return 1
    else
      return 1
    fi
  done < "$tmpdir/actual.raw"
  sort "$actual_paths" > "$actual_paths.sorted" || return 1
  sort "$actual_dirs" > "$actual_dirs.sorted" || return 1
  diff -u "$manifest_paths.sorted" "$actual_paths.sorted" >/dev/null 2>&1 || return 1
  diff -u "$manifest_dirs.sorted" "$actual_dirs.sorted" >/dev/null 2>&1 || return 1
)

# The post-checkout check. trellis_verify_release spawns about ten processes per
# manifest entry, and post-checkout runs on every worktree add, branch switch
# and rebase, so this checks only what that hook is about to run: the anchor
# above, then in one python process the content, mode and read-only state of
# every payload file the reconcile runs, sources or reads as code before its own
# full release verify (release_store_locate) — or without one, when the registry
# names another release, since seed-inheritance-symlinks.sh still sources this
# payload's attach-project.sh. That attach can take the donor fast path
# (attach-fastpath.py, which loads release-executed.py) and starts
# attach-postjob.sh, which sources health-checks.sh, disk-janitor-agents.sh and
# release-stamp.sh (which runs release_stamp.py), so those are listed too, as is
# owner_verify.py, which attachment_verify_owners_batch runs. A
# listed file the release lacks refuses. release_verify.py, which that full
# verify runs when the release has one, is checked whenever it is present; a
# release from before it has only the shell pass in release-store.sh. The rest
# of the payload stays covered by that reconcile verify, by pre-push (its carriers keep
# trellis_verify_release) and by doctor. A release stamp left by a full verify
# and unchanged since covers every listed file, so it skips the content check
# below; the no-link and ACL checks still run. A second argument "stamped"
# refuses instead of falling back to the content check, for a caller that needs
# the whole release proved unchanged.
trellis_verify_release_executed() {
  local payload="${1:-}" mode="${2:-}" release_dir="" python_bin="" program="" permissions="" path="" stamp=""
  local -a paths=(
    scripts/seed-inheritance-symlinks.sh
    scripts/lib/trellis-home.sh
    scripts/lib/local-registry.sh
    scripts/lib/release-store.sh
    scripts/lib/trellis-python.sh
    scripts/lib/semver.sh
    scripts/lib/attachment.sh
    scripts/attach-project.sh
    scripts/lib/surface-plan.sh
    scripts/lib/skill-roots.sh
    scripts/lib/settings-hooks-merge.sh
    scripts/trellis-launcher.sh
    scripts/lib/trellis.machine.schema.json
    scripts/lib/trellis.registry.schema.json
    scripts/lib/attach-fastpath.py
    scripts/lib/release-executed.py
    scripts/lib/attachment_fs.py
    scripts/lib/detach_native.py
    scripts/lib/attach-postjob.sh
    scripts/lib/health-checks.sh
    scripts/lib/disk-janitor-agents.sh
    scripts/lib/config-load.sh
    scripts/lib/hygiene-common.sh
    scripts/lib/disk-janitor-lib.sh
    scripts/lib/disk-janitor-dehydrate.sh
    scripts/lib/disk-janitor-host.sh
    scripts/lib/release_tmp.py
    scripts/lib/release-stamp.sh
    scripts/lib/release_stamp.py
    scripts/lib/owner_verify.py
  )
  local -a listed=("$payload/scripts" "$payload/scripts/lib")

  trellis_verify_release_anchor "$payload" || return 1
  release_dir="${payload%/payload}"
  # A full verify accepts links in a release, so a stamp does not prove the
  # rule python enforces here: real directories and regular files, no links.
  for path in "${listed[@]}"; do
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
  done
  if [ -e "$payload/scripts/lib/release_verify.py" ] || [ -L "$payload/scripts/lib/release_verify.py" ]; then
    paths+=(scripts/lib/release_verify.py)
  fi
  # Older releases have no registry batch helper and use the scalar path.
  # When present, its executable bytes need the same snapshot proof.
  if [ -e "$payload/scripts/lib/registry_identity_batch.py" ] || [ -L "$payload/scripts/lib/registry_identity_batch.py" ]; then
    paths+=(scripts/lib/registry_identity_batch.py)
  fi
  for path in "${paths[@]}"; do
    [ -f "$payload/$path" ] && [ ! -L "$payload/$path" ] || return 1
    listed+=("$payload/$path")
  done
  # One ls refuses any ACL; python checks the rest. On macOS the "@" an xattr
  # puts after the mode hides the "+" of an ACL, so list the ACL entries
  # themselves with -e (one " 0: user:... allow write" line each). Where ls has
  # no -e (GNU), the mode column's "+" is reliable. This runs on every call:
  # the full verify behind a stamp reads ACLs only through that hidden "+".
  permissions="$(/usr/bin/env LC_ALL=C /bin/ls -lde -- "${listed[@]}" 2>/dev/null)" ||
    permissions="$(/usr/bin/env LC_ALL=C /bin/ls -ld -- "${listed[@]}" 2>/dev/null)" || return 1
  printf '%s\n' "$permissions" |
    /usr/bin/awk '/^ *[0-9]+: / { acl = 1 } $1 ~ /\+/ { acl = 1 } END { exit acl }' || return 1
  if stamp="$(trellis_release_stamp check "$managed_home" "$release_dir")" && [ "$stamp" = hit ]; then
    return 0
  fi
  [ "$mode" != stamped ] || return 1
  python_bin="$(command -v python3)" || return 1
  case "$python_bin" in /*) ;; *) return 1 ;; esac
  program="$(trellis_verify_executed_program)" || return 1
  /usr/bin/env LC_ALL=C "$python_bin" -I -c "$program" \
    "$payload" "$release_dir/release.json" "$expected_release_manifest_sha256" "${paths[@]}"
}

trellis_verify_executed_program() {
  printf '%s' 'import hashlib
import json
import os
import stat
import sys

payload, release_json, expected = sys.argv[1], sys.argv[2], sys.argv[3]


def refuse():
    raise SystemExit(1)


try:
    with open(release_json, "rb") as handle:
        raw = handle.read()
    if hashlib.sha256(raw).hexdigest() != expected:
        refuse()
    tree = {}
    for item in json.loads(raw.decode("utf-8"))["tree"]:
        tree[item["path"]] = item
    for path in sys.argv[4:]:
        item = tree.get(path)
        if item is None or item["mode"] not in ("100644", "100755"):
            refuse()
        current = payload
        for component in path.split("/")[:-1]:
            current = current + "/" + component
            info = os.lstat(current)
            if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o222:
                refuse()
        descriptor = os.open(payload + "/" + path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            chunks = []
            while True:
                chunk = os.read(descriptor, 1048576)
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            os.close(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o222:
            refuse()
        if ("100755" if info.st_mode & 0o111 else "100644") != item["mode"]:
            refuse()
        content = b"".join(chunks)
        if hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest() != item["oid"]:
            refuse()
except (OSError, ValueError, KeyError, TypeError):
    refuse()
'
}

# A third argument "verified" skips the release verify for a payload this
# dispatcher run has just verified through this function.
trellis_managed_payload_file() {
  local payload="$1" source="$2" verified="${3:-}" release_dir releases_dir candidate parent actual
  case "$source" in
    scripts/seed-inheritance-symlinks.sh|scripts/lib/attach-postjob.sh|core-rules/husky/pre-push|core-rules/githooks/pre-push) ;;
    *) return 1 ;;
  esac
  [ "$payload" = "$expected_payload" ] || return 1
  case "$verified:$source" in
    verified:*) ;;
    *:scripts/seed-inheritance-symlinks.sh) trellis_verify_release_executed "$payload" || return 1 ;;
    *) trellis_verify_release "$payload" || return 1 ;;
  esac
  release_dir="${payload%/payload}"
  releases_dir="${release_dir%/*}"
  [ -n "$releases_dir" ] || releases_dir=/
  [ "$releases_dir" = "$managed_home/releases" ] || return 1
  candidate="$payload/$source"
  parent="${candidate%/*}"
  while :; do
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    actual="$(CDPATH= cd "$parent" && pwd -P)" || return 1
    [ "$actual" = "$parent" ] || return 1
    [ "$parent" = "$payload" ] && break
    [ "$parent" != / ] || return 1
    parent="${parent%/*}"
    [ -n "$parent" ] || parent=/
  done
  [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -x "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

trellis_prior_hook() {
  local previous="$1" name="$2" common=""
  if [ -n "$previous" ]; then
    case "$previous" in
      /*) printf '%s\n' "$previous/$name" ;;
      *) printf '%s\n' "$PWD/$previous/$name" ;;
    esac
    return 0
  fi
  common="$(/usr/bin/git -C "$PWD" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    /*) ;;
    "") printf '\n'; return 0 ;;
    *) common="$PWD/$common" ;;
  esac
  printf '%s\n' "$common/hooks/$name"
}

trellis_run_prior_hook() {
  local hook="$1"
  local -a prior_env=(
    "PATH=$caller_path" "HOME=$caller_home"
    "TMPDIR=$caller_tmpdir" "TMP=$caller_tmpdir" "TEMP=$caller_tmpdir"
    'LC_ALL=C' 'pnpm_config_verify_deps_before_run=error'
  )
  shift
  if [ "${caller_docker_host_set:-}" = x ]; then
    prior_env+=("DOCKER_HOST=$caller_docker_host")
  fi
  /usr/bin/env -i "${prior_env[@]}" "$hook" "$@"
}

# Mirror only pnpm's global enableGlobalVirtualStore setting into the private
# gate XDG config. The isolated query sees caller HOME/XDG only to read this
# setting; payloads never receive the caller HOME, config store, credentials or
# unrelated variables. Writing at global scope keeps project/workspace overrides
# ahead of it; an absent user value deletes a stale private override and leaves
# pnpm's default.
trellis_sync_pnpm_global_virtual_store() {
  [ "$#" -eq 9 ] || return 1
  local toolchain_path="$1" caller_home="$2" caller_xdg_config_set="$3" caller_xdg_config="$4"
  local gate_home="$5" gate_xdg_config="$6" gate_xdg_cache="$7" corepack_home="$8" scratch="$9"
  local pnpm_bin="" setting="" action=""
  pnpm_bin="$(/usr/bin/env -i PATH="$toolchain_path" /bin/sh -c 'command -v pnpm' 2>/dev/null)" || pnpm_bin=""
  [ -n "$pnpm_bin" ] || return 0
  case "$pnpm_bin" in /*) ;; *) return 1 ;; esac
  [ -f "$pnpm_bin" ] && [ -x "$pnpm_bin" ] || return 1
  if [ "$caller_xdg_config_set" = x ]; then
    setting="$(/usr/bin/env -i \
      PATH="$toolchain_path" HOME="$caller_home" XDG_CONFIG_HOME="$caller_xdg_config" \
      COREPACK_HOME="$corepack_home" TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch" LC_ALL=C \
      "$pnpm_bin" --dir "$scratch" config get --location=global enableGlobalVirtualStore \
      </dev/null 2>/dev/null)" || return 1
  else
    setting="$(/usr/bin/env -i \
      PATH="$toolchain_path" HOME="$caller_home" \
      COREPACK_HOME="$corepack_home" TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch" LC_ALL=C \
      "$pnpm_bin" --dir "$scratch" config get --location=global enableGlobalVirtualStore \
      </dev/null 2>/dev/null)" || return 1
  fi
  setting="$(printf '%s' "$setting" | /usr/bin/env LC_ALL=C tr -d '[:space:]')" || return 1
  case "$setting" in
    true|false) action=set ;;
    ''|undefined) action=delete ;;
    *) return 1 ;;
  esac
  if [ "$action" = set ]; then
    (
      umask 077
      /usr/bin/env -i \
        PATH="$toolchain_path" HOME="$gate_home" XDG_CONFIG_HOME="$gate_xdg_config" \
        XDG_CACHE_HOME="$gate_xdg_cache" COREPACK_HOME="$corepack_home" \
        TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch" LC_ALL=C \
        "$pnpm_bin" --dir "$scratch" config set --location=global enableGlobalVirtualStore "$setting" \
        </dev/null >/dev/null 2>&1
    ) || return 1
  else
    (
      umask 077
      /usr/bin/env -i \
        PATH="$toolchain_path" HOME="$gate_home" XDG_CONFIG_HOME="$gate_xdg_config" \
        XDG_CACHE_HOME="$gate_xdg_cache" COREPACK_HOME="$corepack_home" \
        TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch" LC_ALL=C \
        "$pnpm_bin" --dir "$scratch" config delete --location=global enableGlobalVirtualStore \
        </dev/null >/dev/null 2>&1
    ) || return 1
  fi
}

trellis_run_control_payload() {
  local executable="$1"
  shift
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/dev/null \
    TMPDIR="$TMPDIR" \
    TMP="$TMPDIR" \
    TEMP="$TMPDIR" \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    XDG_CONFIG_HOME="$gate_xdg_config" \
    XDG_CACHE_HOME="$gate_xdg_cache" \
    COREPACK_HOME="$gate_xdg_cache/node/corepack" \
    TRELLIS_HOME="$managed_home" \
    TRELLIS_ALLOW_MAIN_PUSH="${TRELLIS_ALLOW_MAIN_PUSH-}" \
    SECURITY_GATE_SKIP="${SECURITY_GATE_SKIP-}" \
    /bin/bash --noprofile --norc "$executable" "$@"
}

trellis_run_gate_payload() {
  local executable="$1" toolchain_path="" gate_home="" owner="" mode="" reason="" gate_env_entry
  local -a gate_env
  shift
  if [ -z "${TMPDIR:-}" ] || [ ! -d "$TMPDIR" ] || [ -L "$TMPDIR" ]; then
    reason="private command scratch is unavailable"
  else
    gate_home="$TMPDIR/gate-home"
    if ! (umask 077 && mkdir "$gate_home" 2>/dev/null); then
      reason="could not create $gate_home"
    elif [ ! -d "$gate_home" ] || [ -L "$gate_home" ]; then
      reason="not a directory: $gate_home"
    else
      owner="$(stat -f '%u' "$gate_home" 2>/dev/null)" ||
        owner="$(stat -c '%u' "$gate_home" 2>/dev/null)" || owner=""
      mode="$(stat -f '%Lp' "$gate_home" 2>/dev/null)" ||
        mode="$(stat -c '%a' "$gate_home" 2>/dev/null)" || mode=""
      if [ "$owner" != "$(id -u)" ] || [ "$mode" != 700 ]; then
        reason="unsafe owner or mode: $gate_home"
      fi
    fi
  fi
  if [ -n "$reason" ]; then
    printf 'trellis gate: refused (gate-home): %s\n' "$reason" >&2
    return 1
  fi
  toolchain_path="$(trellis_gate_toolchain_path)" || return 1
  if ! trellis_sync_pnpm_global_virtual_store \
    "$toolchain_path" "$caller_home" "$caller_xdg_config_set" "$caller_xdg_config" \
    "$gate_home" "$gate_xdg_config" "$gate_xdg_cache" "$COREPACK_HOME" "$TMPDIR"; then
    # Convenience only: an unreadable setting (offline Corepack, no node on the
    # recorded toolchain) leaves pnpm's default and must not block the gate.
    printf 'trellis gate: warning: could not mirror pnpm enableGlobalVirtualStore; using the gate default\n' >&2
  fi
  # Forward the caller's explicit DOCKER_HOST (including empty), or the
  # endpoint resolved from its context before isolation. The set/unset pair
  # crossed the control-plane env -i as positional args, never exports.
  gate_env=(
    "PATH=$toolchain_path"
    "HOME=$gate_home"
    "TMPDIR=$TMPDIR"
    "TMP=$TMPDIR"
    "TEMP=$TMPDIR"
    'LC_ALL=C'
    'GIT_CONFIG_NOSYSTEM=1'
    'GIT_CONFIG_GLOBAL=/dev/null'
    "XDG_CONFIG_HOME=$gate_xdg_config"
    "XDG_CACHE_HOME=$gate_xdg_cache"
    "COREPACK_HOME=$gate_xdg_cache/node/corepack"
    "TRELLIS_HOME=$managed_home"
    # Bare-name form: older-payload fixtures age this file by deleting ^NAME= lines.
    TRELLIS_ALLOW_MAIN_PUSH="${TRELLIS_ALLOW_MAIN_PUSH-}"
    SECURITY_GATE_SKIP="${SECURITY_GATE_SKIP-}"
  )
  for gate_env_entry in ${caller_gate_env[@]+"${caller_gate_env[@]}"}; do
    gate_env+=("$gate_env_entry")
  done
  if [ "${caller_docker_host_set:-}" = x ]; then
    gate_env+=("DOCKER_HOST=$caller_docker_host")
  fi
  /usr/bin/env -i "${gate_env[@]}" /bin/bash --noprofile --norc "$executable" "$@"
}
EOF
  printf '%s\n' "$predicate"
}

# Dispatcher bytes are release-versioned. A command bundle may be running a
# different release from the one recorded by a managed hook, so verification and
# rewrites use that payload's generator rather than silently using this process's
# implementation.
_attachment_hooks_running_payload() {
  local candidate actual
  if [ -n "${_ATTACHMENT_DIR:-}" ]; then
    case "$_ATTACHMENT_DIR" in
      */scripts/lib) candidate="${_ATTACHMENT_DIR%/scripts/lib}" ;;
      *) return 1 ;;
    esac
  elif [ -n "${TRELLIS_VERIFIED_PAYLOAD:-}" ]; then
    candidate="$TRELLIS_VERIFIED_PAYLOAD"
  else
    return 1
  fi
  case "$candidate" in
    */payload) ;;
    *) return 1 ;;
  esac

  [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  actual="$(CDPATH='' cd "$candidate" && pwd -P)" || return 1
  printf '%s\n' "$actual"
}

_attachment_hooks_payload_declares_generator() {
  local payload=$1 release
  release="${payload%/payload}"
  [ "$release/payload" = "$payload" ] || return 1
  [ -f "$release/release.json" ] && [ ! -L "$release/release.json" ] || return 1
  jq -e 'any(.tree[]?; .path == "scripts/lib/attachment.sh")' \
    "$release/release.json" >/dev/null 2>&1
}

_attachment_hooks_dispatcher_body_from_payload() {
  local kind=$1 payload=$2 source=${3:-} manifest=${4:-}
  local running="" generator="" depth="${TRELLIS_HOOK_GENERATOR_DEPTH:-0}"
  case "$kind" in
    post-checkout|pre-push) ;;
    *) return 2 ;;
  esac
  # A non-payload or aliased path can never equal the child generator's
  # physical payload, causing unbounded recursive starts. Reject it before
  # sourcing anything, and allow at most one cross-payload generation hop.
  case "$payload" in /*/payload) ;; *) return 1 ;; esac
  _attachment_canonical_dir "$payload" || return 1
  case "$depth" in 0|1) ;; *) return 1 ;; esac
  running="$(_attachment_hooks_running_payload 2>/dev/null)" || running=""
  if [ -n "$running" ] && [ "$payload" = "$running" ]; then
    case "$kind" in
      post-checkout) _attachment_hooks_post_checkout_dispatcher_body_in_process "$payload" "$manifest" ;;
      pre-push) _attachment_hooks_pre_push_dispatcher_body_in_process "$payload" "$source" "$manifest" ;;
    esac
    return "$?"
  fi
  [ "$depth" = 0 ] || return 1
  generator="$payload/scripts/lib/attachment.sh"
  if [ -e "$generator" ] || [ -L "$generator" ]; then
    _attachment_canonical_file "$generator" || return 1
  else
    # Provisional payloads used while creating state predate the bundled
    # generator. A release manifest that declares it must provide it.
    if _attachment_hooks_payload_declares_generator "$payload"; then
      return 1
    else
      case "$?" in
        1) ;;
        *) return 1 ;;
      esac
    fi
    case "$kind" in
      post-checkout) _attachment_hooks_post_checkout_dispatcher_body_in_process "$payload" "$manifest" ;;
      pre-push) _attachment_hooks_pre_push_dispatcher_body_in_process "$payload" "$source" "$manifest" ;;
    esac
    return "$?"
  fi
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/dev/null \
    TMPDIR=/tmp \
    TMP=/tmp \
    TEMP=/tmp \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    XDG_CONFIG_HOME="${XDG_CONFIG_HOME-}" \
    XDG_CACHE_HOME="${XDG_CACHE_HOME-}" \
    COREPACK_HOME="${COREPACK_HOME-}" \
    TRELLIS_LIBS_PRELOADED=1 \
    "TRELLIS_VERIFIED_PAYLOAD=$payload" \
    TRELLIS_HOOK_GENERATOR_DEPTH=1 \
    /bin/bash --noprofile --norc -c '
set -u
generator="$1"
kind="$2"
payload="$3"
source="$4"
manifest="$5"
. "$generator" >/dev/null 2>&1 || exit $?
case "$kind" in
  post-checkout) _attachment_hooks_post_checkout_dispatcher_body "$payload" "$manifest" ;;
  pre-push) _attachment_hooks_pre_push_dispatcher_body "$payload" "$source" "$manifest" ;;
  *) exit 2 ;;
esac
' attachment-dispatcher-generator "$generator" "$kind" "$payload" "$source" "$manifest"
}

_attachment_hooks_post_checkout_dispatcher_body_in_process() {
  local passthrough_names="" library="" registry="" home_lib=""
  # A failed common body must not be hidden by the successful cat that follows.
  _attachment_hooks_dispatcher_common_body "${1:-}" "" "${2:-}" post-checkout || return "$?"
  passthrough_names="$(_attachment_hooks_passthrough_names)" || return 1
  [ -n "$passthrough_names" ] || return 1
  printf 'expected_passthrough_names=%q\n' "$passthrough_names" || return 1
  library="$(_attachment_library_source)" || return 1
  registry="${library%/*}/local-registry.sh"
  home_lib="${library%/*}/trellis-home.sh"
  # Extract both jq predicates from the release generator itself. Only the
  # known wrappers and helper implementations may be elided: if those change,
  # emit empty filters so current-worktree proof misses rather than guessing.
  if [ -f "$registry" ] && [ ! -L "$registry" ] && [ -f "$home_lib" ] && [ ! -L "$home_lib" ]; then
    if /usr/bin/env LC_ALL=C python3 -I - "$library" "$registry" "$home_lib" 2>/dev/null <<'PY'
import base64
import hashlib
from pathlib import Path
import re
import sys

library, registry, home = (Path(path).read_text(encoding="utf-8") for path in sys.argv[1:4])


def function(source, name):
    matches = re.findall(r"(?ms)^" + re.escape(name) + r"\(\) \{\n.*?^\}\n", source)
    if len(matches) != 1:
        raise ValueError("missing or duplicate function: " + name)
    return matches[0]


def require_known(source, name, expected):
    actual = hashlib.sha256(function(source, name).encode()).hexdigest()
    if actual != expected:
        raise ValueError("helper changed: " + name)


def jq_filter(source, name, prefix, suffix):
    text = function(source, name)
    if not text.startswith(prefix) or not text.endswith(suffix):
        raise ValueError("validator wrapper changed: " + name)
    result = text[len(prefix):-len(suffix)]
    if not result.strip():
        raise ValueError("empty validator: " + name)
    return result


require_known(library, "_attachment_json_file", "8e376af326e997b5a62c76eadf6d9c91b62559939317dc483455bf8a1737aad1")
require_known(library, "_attachment_mode", "3a3018155df2c2b88aefa6836e2ee04bfba76b0b13f57b998efd2165ac7d4a60")
require_known(library, "_attachment_stat_mode", "f47543f5ddb2d5d5a21e72d265482df28edfaf0406a1e92d2bdd27dde681e418")
require_known(registry, "local_registry_require_project_id", "e9beb759f7c4466c592443965bbd0adc386a3e4973eb445f5fa0af165950b542")
require_known(home, "trellis_home_require_jq", "89152ac34108df047ee82d0032a290e8f69be237219ca9423233aa4410da41cd")
# The owner schema is the single-quoted assignment the per-file check and the
# batch owner checks share. The wrapper must be exactly this text, so the
# assignment is what it evaluates; any other text refuses.
owner_wrapper = (
    '_attachment_owner_json_valid() {\n'
    '  local file=$1\n'
    '  _attachment_json_file "$file" || return 2\n'
    '  [ "$(_attachment_mode "$file")" = 600 ] || return 3\n'
    '  jq -e "$_attachment_owner_schema_filter" "$file" >/dev/null 2>&1 || return 2\n'
    '}\n'
)


def assignment(source, name):
    if len(re.findall(r"(?m)^" + re.escape(name) + r"=", source)) != 1:
        raise ValueError("missing or reassigned schema: " + name)
    matches = re.findall(r"(?ms)^" + re.escape(name) + r"='\n(.*?)^'\n", source)
    if len(matches) != 1 or "'" in matches[0] or not matches[0].strip():
        raise ValueError("schema assignment changed: " + name)
    return matches[0]


manifest_prefix = (
    'local_registry_manifest_project_id() {\n'
    '  local manifest="${1:-}" project_id\n'
    '  trellis_home_require_jq || return "$?"\n'
    '  if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then\n'
    '    local_registry_err "project manifest must be a regular file: $manifest"\n'
    '    return "$TRELLIS_EX_STATE"\n'
    '  fi\n'
    "  if ! jq -e -s '\n"
)
manifest_suffix = (
    "  ' \"$manifest\" >/dev/null 2>&1; then\n"
    '    local_registry_err "project manifest failed schema-aware validation: $manifest"\n'
    '    return "$TRELLIS_EX_STATE"\n'
    '  fi\n'
    '  project_id="$(jq -r \'.project_id\' "$manifest")" || return "$TRELLIS_EX_STATE"\n'
    '  local_registry_require_project_id "$project_id" || return "$?"\n'
    '  printf \'%s\\n\' "$project_id"\n'
    '}\n'
)
if function(library, "_attachment_owner_json_valid") != owner_wrapper:
    raise ValueError("validator wrapper changed: _attachment_owner_json_valid")
owner = assignment(library, "_attachment_owner_schema_filter")
manifest = jq_filter(registry, "local_registry_manifest_project_id", manifest_prefix, manifest_suffix)
for name, expression in (("trellis_owner_schema_b64", owner), ("trellis_manifest_schema_b64", manifest)):
    print(name + "=" + base64.b64encode(expression.encode()).decode("ascii"))
PY
    then
      :
    else
      printf '%s\n' 'trellis post-checkout generator: canonical schema unavailable; current-worktree fast path will reconcile' >&2 || :
      printf 'trellis_owner_schema_b64=\ntrellis_manifest_schema_b64=\n' || return 1
    fi
  else
    printf '%s\n' 'trellis post-checkout generator: canonical schema unavailable; current-worktree fast path will reconcile' >&2 || :
    printf 'trellis_owner_schema_b64=\ntrellis_manifest_schema_b64=\n' || return 1
  fi
  cat <<'EOF'
# trellis-diff-base-creation-recorder-v1 (spec 067 T10; delivery marker)
trellis_record_creation_base() {
  local branch="" log="" record="" parent="" base="" stamp="" count="" head_log="" rc=0
  [ "${3:-}" = 1 ] || return 0
  branch="$(git -C "$project_root" symbolic-ref -q --short HEAD 2>/dev/null)" || return 0
  # --local reads/writes the common config, even with extensions.worktreeConfig.
  if git -C "$project_root" config --local --get "branch.$branch.trellisParent" >/dev/null 2>&1; then
    return 0
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
  log="$(git -C "$project_root" rev-parse --git-path "logs/refs/heads/$branch")" || return 1
  [ -f "$log" ] || return 0
  record="$(awk -F '\t' '
    { count++ }
    !seen && index($2, "branch: Created from ") == 1 {
      seen=1; n=split($1, meta, " ")
      parent=substr($2, length("branch: Created from ")+1)
      base=meta[2]; stamp=meta[n-1]
    }
    END { if (seen) printf "%s\t%s\t%s\t%d\n", parent, base, stamp, count }
  ' "$log")" || return 1
  [ -n "$record" ] || return 0
  IFS=$'\t' read -r parent base stamp count <<< "$record"
  # HEAD is not a stable parent name. Use the matching checkout reflog event,
  # never the previous-head argument ($1), which may be null or unrelated.
  if [ "$parent" = HEAD ]; then
    head_log="$(git -C "$project_root" rev-parse --git-path logs/HEAD)" || return 1
    [ -f "$head_log" ] || return 1
    parent="$(awk -F '\t' -v branch="$branch" -v base="$base" -v stamp="$stamp" '
      {
        n=split($1, meta, " "); suffix=" to " branch
        if (meta[2] == base && meta[n-1] == stamp &&
            index($2, "checkout: moving from ") == 1 &&
            substr($2, length($2)-length(suffix)+1) == suffix) {
          print substr($2, length("checkout: moving from ")+1,
            length($2)-length("checkout: moving from ")-length(suffix)); exit
        }
      }
    ' "$head_log")" || return 1
    [ -n "$parent" ] || return 1
  fi
  # On a fresh branch $2 is the start commit; on a later checkout retain the
  # creation entry SHA, not today's tip. No ancestry heuristic is used.
  if [ "$count" -eq 1 ]; then base="${2:-}"; fi
  git -C "$project_root" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || return 1
  # Parent last: a failed earlier write must not publish an incomplete record.
  git -C "$project_root" config --local "branch.$branch.trellisBase" "$base" || return 1
  git -C "$project_root" config --local "branch.$branch.trellisSource" post-checkout || return 1
  git -C "$project_root" config --local "branch.$branch.trellisParent" "$parent" || return 1
}
# Spec 072 U5: a branch checkout needs no reconcile when this worktree is
# already attached to the verified release and nothing the reconcile checks
# has moved. Each check is O(1) in the release:
# - no pending adoption;
# - the two commits differ in neither .trellis.json nor an owned path, a path
#   below one or an ancestor of one (Git replaces ignored files), compared
#   case-folded, and any name Git quotes (non-ASCII, so any Unicode
#   normalization variant, or a control character) counts as a change;
#   .trellis.json has no staged, unstaged or untracked change either;
# - the recorded payload is the one this dispatcher carries: anchor, ACLs of the
#   files it executes, and its release stamp unchanged since a full verify;
# - the committed owner record names the runtime link to that payload and the
#   project id .trellis.json declares, and every owned artifact on disk matches
#   it: each link its target, each file its mode and digest (a render: its
#   owned keys, equal as jq compares JSON), each recorded parent and every
#   ancestor a real directory;
# - each sidecar is the owner record's value and the release manifest is the
#   stamped release.json's, and the managed hook set is what this release
#   generates, as the hook digest memo a verified attach recorded it: both
#   dispatchers and the shims the predecessor (or, with none recorded, the
#   default hooks dir) calls for byte for byte, no other file, the modes, and
#   core.hooksPath naming it.
# A new worktree (old HEAD all zeros) has no owner yet. Any miss takes the full
# reconcile.
trellis_worktree_current() {
  local old="${1:-}" new="${2:-}" payload="" common="" checkout="" worktree="" owner=""
  local owned="" changed="" manifest="" memo_attempt=0 proof_rc=0
  while :; do
  case "$old:$new" in *[!0-9a-f:]*|:*|*:) return 1 ;; esac
  case "$old" in *[!0]*) ;; *) return 1 ;; esac
  payload="$(trellis_read_sidecar "$managed_dir/release-payload")" || return 1
  common="$(/usr/bin/git -C "$project_root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*) ;; *) common="$project_root/$common" ;; esac
  common="$(CDPATH= cd "$common" && pwd -P)" || return 1
  checkout="$(trellis_hash_text "$common")" || return 1
  worktree="$(trellis_hash_text "$project_root")" || return 1
  [ ! -e "$managed_home/state/release-adoptions/$checkout" ] &&
    [ ! -L "$managed_home/state/release-adoptions/$checkout" ] || return 1
  owner="$managed_home/state/attachments/$checkout/$worktree.json"
  [ -f "$owner" ] && [ ! -L "$owner" ] && [ "$(trellis_mode "$owner")" = 600 ] || return 1
  changed="$(/usr/bin/git -C "$project_root" diff --name-only --no-renames "$old" "$new" -- 2>/dev/null)" ||
    return 1
  manifest="$(/usr/bin/git -C "$project_root" status --porcelain --untracked-files=all -- .trellis.json 2>/dev/null)" ||
    return 1
  [ -z "$manifest" ] || return 1
  # Keep the canonical anchor, executed-file and ACL checks unchanged. In this
  # subshell only, make their stamp check run the owner/hooks proof in the same
  # Python process. FD 3 carries owned paths back to this invocation, never an
  # exported verdict or a persistent authorization file. A failure anywhere
  # still makes the entire canonical stamped check miss. This depends on B3's
  # trellis_verify_release_executed calling trellis_release_stamp with exactly
  # check HOME RELEASE; a changed call shape must miss until requalified.
  owned="$(
    exec 3>&1
    trellis_release_stamp() {
      local program=""
      [ "$#" -eq 3 ] && [ "$1" = check ] || return 1
      program="$(trellis_release_stamp_program)" || return 1
      /usr/bin/env LC_ALL=C python3 -I -c '
import base64, binascii, decimal, hashlib, json, os, stat, subprocess, sys
operation, stamp_home, release_dir, program = sys.argv[1:5]
root, payload, managed, record, managed_home, manifest, common = sys.argv[5:12]
passthrough_names = sys.argv[12].splitlines()
owner_schema_b64, manifest_schema_b64 = sys.argv[13:15]
# Execute the exact trusted, generator-embedded schema-2 stamp implementation,
# not the as-yet-unproved payload copy. Its normal hit line goes to stdout for
# trellis_verify_release_executed; owned paths go separately to FD 3.
stamp = {"__name__": "trellis_embedded_stamp"}
exec(compile(program, "<embedded-release-stamp>", "exec"), stamp)
if (operation != "check" or stamp_home != managed_home or release_dir != payload.rsplit("/", 1)[0]
        or stamp["check"](stamp_home, release_dir) != 0):
    sys.exit(1)
def constant(name):
    raise ValueError(name)
def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result
def load(data):
    return json.loads(data, parse_float=decimal.Decimal, parse_constant=constant, object_pairs_hook=unique_object)
# JSON equality as jq judges it, or stricter: a Boolean is never a number, and
# numbers compare exactly.
def same(left, right):
    if isinstance(left, bool) or isinstance(right, bool) or left is None or right is None:
        return left is right
    if isinstance(left, (int, decimal.Decimal)) and isinstance(right, (int, decimal.Decimal)):
        return left == right
    if isinstance(left, str) and isinstance(right, str):
        return left == right
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(same(a, b) for a, b in zip(left, right))
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(same(left[key], right[key]) for key in left)
    return False
# B1 owns only the canonical positional prefixes of hook event arrays and of
# each canonical block hook list. Remaining blocks and hooks are project-owned.
def same_event_value(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(same_event_value(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(same_event_value(a, b) for a, b in zip(left, right))
    return left == right
def owned_value_matches(path, actual, expected):
    if len(path) != 2 or path[0] != "hooks":
        return same(actual, expected)
    if not isinstance(actual, list) or not isinstance(expected, list) or len(actual) < len(expected):
        return False
    for block, canonical in zip(actual, expected):
        if (not isinstance(block, dict) or not isinstance(canonical, dict) or "hooks" not in canonical
                or block.keys() != canonical.keys() or not isinstance(block.get("hooks"), list)
                or not isinstance(canonical["hooks"], list)):
            return False
        if any(not same_event_value(block[k], v) for k, v in canonical.items() if k != "hooks"):
            return False
        hooks, prefix = block["hooks"], canonical["hooks"]
        if len(hooks) < len(prefix) or not all(same_event_value(a, b) for a, b in zip(hooks, prefix)):
            return False
    return True
# trellis-schema-validation-begin
def trellis_schema_valid(owner_bytes, manifest_bytes, owner_encoded, manifest_encoded):
    try:
        owner_filter = base64.b64decode(owner_encoded, validate=True).decode("utf-8")
        manifest_filter = base64.b64decode(manifest_encoded, validate=True).decode("utf-8")
        if not owner_filter or not manifest_filter:
            return False
        expression = ("def trellis_owner_schema:\n" + owner_filter + ";\n"
                      + "def trellis_manifest_schema:\n" + manifest_filter + ";\n"
                      + "input as $o | [inputs] as $m | ($o | trellis_owner_schema) and ($m | trellis_manifest_schema)")
        result = subprocess.run(("jq", "-n", "-e", expression), input=owner_bytes + b"\n" + manifest_bytes + b"\n",
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except (OSError, ValueError, UnicodeError, binascii.Error):
        return False
# trellis-schema-validation-end
# Keep the exact bytes lent to the canonical-derived validators pinned until
# all owner, artifact and hooks checks finish; a changed name or inode misses.
pins = []
def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)
def capture_regular(path, mode=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or (mode is not None and
            (stat.S_IMODE(info.st_mode) != mode or info.st_uid != os.geteuid()))):
        os.close(fd)
        sys.exit(1)
    expected = fingerprint(info)
    with os.fdopen(os.dup(fd), "rb") as handle:
        data = handle.read()
    if fingerprint(os.fstat(fd)) != expected or fingerprint(os.lstat(path)) != expected:
        os.close(fd)
        sys.exit(1)
    pins.append((fd, path, expected))
    return data
owner_bytes = capture_regular(record, 0o600)
manifest_bytes = capture_regular(root + "/.trellis.json")
owner = load(owner_bytes)
declared = load(manifest_bytes)
if (not trellis_schema_valid(owner_bytes, manifest_bytes, owner_schema_b64, manifest_schema_b64)
        or owner.get("checkout_id") != hashlib.sha256(os.fsencode(common)).hexdigest()
        or owner.get("worktree_id") != hashlib.sha256(os.fsencode(root)).hexdigest()):
    sys.exit(1)
hooks = owner["git_hooks"]
# A linked worktree records no hook state (enabled false): the checkout has one
# hooks-enabled owner, and the full reconcile verifies the managed hooks of
# that owner for every sibling. Bind the hook checks below to it: the only enabled
# owner record in this checkout, pinned, schema-valid, committed, another
# canonical worktree on the same release. None, several, an unreadable or
# unexpected entry, or a relative predecessor (resolved from another root)
# takes the full reconcile.
if hooks.get("enabled") is False:
    owners_dir = managed_home + "/state/attachments/" + owner["checkout_id"]
    enabled = []
    for name in sorted(os.listdir(owners_dir)):
        if (len(name) != 69 or not name.endswith(".json")
                or any(char not in "0123456789abcdef" for char in name[:64])):
            sys.exit(1)
        if name[:64] == owner["worktree_id"]:
            continue
        fd = os.open(owners_dir + "/" + name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                    or info.st_uid != os.geteuid()):
                sys.exit(1)
            with os.fdopen(os.dup(fd), "rb") as handle:
                candidate = load(handle.read())
        except (OSError, ValueError, UnicodeError):
            sys.exit(1)
        finally:
            os.close(fd)
        state = candidate.get("git_hooks") if isinstance(candidate, dict) else None
        if not isinstance(state, dict):
            sys.exit(1)
        if state.get("enabled") is True:
            enabled.append(name)
    if len(enabled) != 1:
        sys.exit(1)
    hooks_bytes = capture_regular(owners_dir + "/" + enabled[0], 0o600)
    hooks_owner = load(hooks_bytes)
    if (not trellis_schema_valid(hooks_bytes, manifest_bytes, owner_schema_b64, manifest_schema_b64)
            or hooks_owner.get("checkout_id") != owner["checkout_id"]
            or hooks_owner.get("worktree_id") != enabled[0][:64]
            or hooks_owner.get("worktree_id") != hashlib.sha256(os.fsencode(hooks_owner["worktree_root"])).hexdigest()
            or hooks_owner["worktree_root"] == root or hooks_owner["status"] != "committed"
            or hooks_owner["release"] != owner["release"] or hooks_owner["git_hooks"].get("enabled") is not True
            or not (hooks_owner["git_hooks"].get("previous_hooks_path") or "/").startswith("/")):
        sys.exit(1)
    hooks = hooks_owner["git_hooks"]
runtime = [item for item in owner["artifacts"] if item["path"] == ".trellis/runtime"]
if (owner["status"] != "committed" or owner["project_root"] != root
        or owner["worktree_root"] != root or declared["project_id"] != owner["project_id"]
        or len(runtime) != 1 or runtime[0]["kind"] != "symlink" or runtime[0]["target"] != payload):
    sys.exit(1)
# The hook state the owner record names, as _attachment_hooks_state_owned_matches
# compares it: the managed path, every sidecar, and the release manifest the
# dispatchers were generated from.
def sidecar(name, allow_empty=False):
    path = managed + "/" + name
    if not stat.S_ISREG(os.lstat(path).st_mode):
        sys.exit(1)
    with open(path, "rb") as handle:
        data = handle.read()
    line = data[:-1] if data.endswith(b"\n") else data
    if not data or b"\n" in line or any(byte < 32 or byte == 127 for byte in line) or not (line or allow_empty):
        sys.exit(1)
    return line.decode("utf-8")
release = managed_home + "/releases/" + owner["release"]
previous = sidecar("previous-hooks-path", True)
if (hooks["enabled"] is not True or hooks["managed_hooks_path"] != managed
        or managed != managed_home + "/state/git-hooks/" + owner["checkout_id"]
        or previous != (hooks["previous_hooks_path"] or "") or previous == managed
        or sidecar("release-payload") != release + "/payload" or release + "/payload" != payload
        or sidecar("pre-push-source") != hooks["pre_push_source"]):
    sys.exit(1)
release += "/release.json"
if os.path.realpath(release) != release or not stat.S_ISREG(os.lstat(release).st_mode):
    sys.exit(1)
release_bytes = capture_regular(release)
release_device = os.fstat(pins[-1][0]).st_dev
if hashlib.sha256(release_bytes).hexdigest() != manifest:
    sys.exit(1)
# The managed hook set against the hook digest memo for this manifest and
# source: both dispatchers and every shim byte for byte, the modes, exactly the
# shims the predecessor calls for, and core.hooksPath naming the managed dir.
def private(path, kind, mode):
    info = os.lstat(path)
    if not kind(info.st_mode) or stat.S_IMODE(info.st_mode) != mode or info.st_uid != os.geteuid():
        sys.exit(1)
def digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()
source = hooks["pre_push_source"]
memo = managed_home + "/state/hook-digests/" + manifest + "-" + hashlib.sha256(source.encode()).hexdigest() + ".json"
# Fail closed: a real 0700 directory and a regular 0600 file of this uid,
# opened without following a link, at most 64 KiB, with exactly these keys.
memo_dir, memo_name = memo.rsplit("/", 1)
private(memo_dir, stat.S_ISDIR, 0o700)
dir_fd = os.open(memo_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
dir_info = fingerprint(os.fstat(dir_fd))
if fingerprint(os.lstat(memo_dir)) != dir_info:
    sys.exit(1)
try:
    handle = os.open(memo_name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
except FileNotFoundError:
    import tempfile
    # Publication may not follow a substituted state ancestor or repair an
    # unsafe directory. Pin the private home and state names throughout.
    if os.path.realpath(memo_dir) != memo_dir:
        sys.exit(1)
    for ancestor in (managed_home, managed_home + "/state"):
        private(ancestor, stat.S_ISDIR, 0o700)
        fd = os.open(ancestor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        expected = fingerprint(os.fstat(fd))
        if fingerprint(os.lstat(ancestor)) != expected:
            sys.exit(1)
        pins.append((fd, ancestor, expected))
    # The stamp proof is valid only on its own fine-ctime device. A scratch
    # mount on another device, or a device whose ctime no longer moves, must
    # take canonical reconciliation rather than trusting snapshot fingerprints.
    stamp_dir = managed_home + "/state/release-stamps"
    private(stamp_dir, stat.S_ISDIR, 0o700)
    stamp_fd = os.open(stamp_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    stamp_info = os.fstat(stamp_fd)
    stamp_pin = fingerprint(stamp_info)
    if stamp_info.st_dev != release_device or fingerprint(os.lstat(stamp_dir)) != stamp_pin:
        sys.exit(1)
    pins.append((stamp_fd, stamp_dir, stamp_pin))
    stamp_device = stamp_info.st_dev
    # A miss is not a proof. Capture the actual generator and every file it
    # reads, validate those exact bytes against the stamped release manifest,
    # and generate only inside a new private scratch snapshot. Never hash the
    # installed hooks into an expected memo. The original input descriptors
    # stay pinned until the exclusive publication has completed.
    paths = ("scripts/lib/attachment.sh", "scripts/lib/trellis-home.sh",
             "scripts/lib/local-registry.sh", "scripts/lib/release_stamp.py",
             "scripts/trellis-launcher.sh")
    tree = load(release_bytes)["tree"]
    entries = {}
    for path in paths:
        found = [item for item in tree if item.get("path") == path]
        if len(found) != 1 or found[0].get("mode") not in ("100644", "100755"):
            sys.exit(1)
        entries[path] = found[0]
    captured = {}
    for path in paths:
        original = payload + "/" + path
        if os.path.realpath(original) != original:
            sys.exit(1)
        content = capture_regular(original)
        info = os.fstat(pins[-1][0])
        item = entries[path]
        mode = "100755" if info.st_mode & 0o111 else "100644"
        oid = hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest()
        if info.st_dev != stamp_device or info.st_mode & 0o222 or mode != item["mode"] or oid != item.get("oid"):
            sys.exit(1)
        captured[path] = content
    if source not in ("core-rules/githooks/pre-push", "core-rules/husky/pre-push"):
        sys.exit(1)
    scratch = os.environ.get("TMPDIR") or None
    with tempfile.TemporaryDirectory(prefix=".trellis-generator-", dir=scratch) as snapshot:
        snapshot_info = os.stat(snapshot, follow_symlinks=False)
        snapshot_fd = os.open(snapshot, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            opened = os.fstat(snapshot_fd)
            if (snapshot_info.st_dev != stamp_device or opened.st_dev != stamp_device
                    or snapshot_info.st_ino != opened.st_ino or not stat.S_ISDIR(opened.st_mode)
                    or stat.S_IMODE(opened.st_mode) != 0o700 or opened.st_uid != os.geteuid()):
                sys.exit(1)
        finally:
            os.close(snapshot_fd)
        with tempfile.TemporaryFile(dir=snapshot) as probe:
            if os.fstat(probe.fileno()).st_dev != stamp_device or not stamp["ctime_moves"](probe.fileno()):
                sys.exit(1)
        snapshot_payload = snapshot + "/payload"
        for path, content in captured.items():
            target = snapshot_payload + "/" + path
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
            with open(target, "xb") as output:
                output.write(content)
            os.chmod(target, 0o600)
        os.mkdir(snapshot + "/tmp", 0o700)
        # Pin the snapshot names and ancestors as well as the original inputs.
        # The only shell code executed is the exact captured generator through
        # an unlinked descriptor; the snapshot files are data, never sourced.
        for directory in (snapshot, snapshot_payload, snapshot_payload + "/scripts",
                          snapshot_payload + "/scripts/lib"):
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            info = os.fstat(fd)
            expected = fingerprint(info)
            if info.st_dev != stamp_device or fingerprint(os.lstat(directory)) != expected:
                sys.exit(1)
            pins.append((fd, directory, expected))
        for path, content in captured.items():
            if (capture_regular(snapshot_payload + "/" + path, 0o600) != content
                    or os.fstat(pins[-1][0]).st_dev != stamp_device):
                sys.exit(1)
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/dev/null",
                       "TMPDIR": snapshot + "/tmp", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                       "GIT_CONFIG_GLOBAL": "/dev/null", "TRELLIS_LIBS_PRELOADED": "1",
                       "TRELLIS_VERIFIED_PAYLOAD": snapshot_payload}
        script = """set -eu
payload=$1
manifest=$2
source=$3
. "/dev/fd/$4" >/dev/null
body=$(_attachment_hooks_post_checkout_dispatcher_body_in_process "$payload" "$manifest")
[ -n "$body" ]
printf "%s\\n\\0" "$body"
body=$(_attachment_hooks_pre_push_dispatcher_body_in_process "$payload" "$source" "$manifest")
[ -n "$body" ]
printf "%s\\n\\0" "$body"
for name in $(_attachment_hooks_passthrough_names); do
  body=$(_attachment_hooks_passthrough_shim_body "$name")
  default=$(_attachment_hooks_default_passthrough_shim_body "$name")
  printf "%s\\0%s\\n\\0%s\\n\\0" "$name" "$body" "$default"
done
"""
        with tempfile.TemporaryFile(dir=snapshot + "/tmp") as generator_input:
            generator_input.write(captured["scripts/lib/attachment.sh"])
            generator_input.flush()
            os.fchmod(generator_input.fileno(), 0o400)
            input_info = os.fstat(generator_input.fileno())
            if input_info.st_dev != stamp_device:
                sys.exit(1)
            expected_input = fingerprint(input_info)
            generator_input.seek(0)
            result = subprocess.run(("/bin/bash", "--noprofile", "--norc", "-c", script, "trellis-memo-generator",
                                     payload, manifest, source, str(generator_input.fileno())), env=environment,
                                    pass_fds=(generator_input.fileno(),), stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if fingerprint(os.fstat(generator_input.fileno())) != expected_input:
                sys.exit(1)
        if result.returncode != 0:
            sys.exit(1)
        parts = result.stdout.split(b"\0")
        if len(parts) != 3 + 3 * len(passthrough_names) or parts[-1] != b"":
            sys.exit(1)
        def generated_digest(data):
            return hashlib.sha256(data).hexdigest()
        generated = {"schema_version": 2, "manifest_sha256": manifest, "payload": payload,
                     "pre_push_source": source, "post_checkout": generated_digest(parts[0]),
                     "pre_push": generated_digest(parts[1]), "shims": {}, "default_shims": {}}
        for index, name in enumerate(passthrough_names):
            offset = 2 + index * 3
            if parts[offset] != name.encode():
                sys.exit(1)
            generated["shims"][name] = generated_digest(parts[offset + 1])
            generated["default_shims"][name] = generated_digest(parts[offset + 2])
        data = (json.dumps(generated, sort_keys=True) + "\n").encode()
        if len(data) > 65536:
            sys.exit(1)
        # Refuse changed source names/inodes, a changed scratch snapshot or a
        # changed target directory. A competing memo is never replaced.
        for fd, path, expected in pins:
            if fingerprint(os.fstat(fd)) != expected or fingerprint(os.lstat(path)) != expected:
                sys.exit(1)
        if fingerprint(os.fstat(dir_fd)) != dir_info or fingerprint(os.lstat(memo_dir)) != dir_info:
            sys.exit(1)
        # Stage in the existing command scratch, not hook-digests. A killed
        # writer cannot strand a .memo file in the persistent memo directory;
        # an interrupted command scratch remains the existing orphan class.
        staging = snapshot + "/tmp"
        staging_fd = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        staging_info = os.fstat(staging_fd)
        if (staging_info.st_dev != stamp_device or fingerprint(os.lstat(staging)) != fingerprint(staging_info)
                or stat.S_IMODE(staging_info.st_mode) != 0o700 or staging_info.st_uid != os.geteuid()):
            sys.exit(1)
        temporary = ".memo-" + os.urandom(16).hex()
        out = os.open(temporary, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=staging_fd)
        try:
            os.fchmod(out, 0o600)
            view = memoryview(data)
            while view:
                view = view[os.write(out, view):]
            if fingerprint(os.stat(temporary, dir_fd=staging_fd, follow_symlinks=False)) != fingerprint(os.fstat(out)):
                sys.exit(1)
            # trellis-memo-publish-link: exclusive publication from private scratch.
            os.link(temporary, memo_name, src_dir_fd=staging_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
            published = os.stat(memo_name, dir_fd=dir_fd, follow_symlinks=False)
            written = os.fstat(out)
            if (not stat.S_ISREG(published.st_mode) or not stat.S_ISREG(written.st_mode)
                    or published.st_dev != written.st_dev or published.st_ino != written.st_ino
                    or published.st_nlink != 2 or written.st_nlink != 2
                    or stat.S_IMODE(written.st_mode) != 0o600 or written.st_uid != os.geteuid()):
                sys.exit(1)
            os.lseek(out, 0, os.SEEK_SET)
            if os.read(out, len(data) + 1) != data:
                sys.exit(1)
            if (fingerprint(os.fstat(out)) != fingerprint(written)
                    or fingerprint(os.stat(memo_name, dir_fd=dir_fd, follow_symlinks=False)) != fingerprint(written)):
                sys.exit(1)
        finally:
            if out is not None:
                os.close(out)
            os.unlink(temporary, dir_fd=staging_fd)
            os.close(staging_fd)
        for fd, path, expected in pins:
            if fingerprint(os.fstat(fd)) != expected or fingerprint(os.lstat(path)) != expected:
                sys.exit(1)
        current_dir, named_dir = os.fstat(dir_fd), os.lstat(memo_dir)
        if (not stat.S_ISDIR(named_dir.st_mode) or stat.S_IMODE(named_dir.st_mode) != 0o700
                or named_dir.st_uid != os.geteuid() or current_dir.st_dev != named_dir.st_dev
                or current_dir.st_ino != named_dir.st_ino):
            sys.exit(1)
    # This is a retry request, not an authorization. The caller repeats the
    # complete current-worktree proof, including Git, stamp, owner and hooks.
    with os.fdopen(os.dup(3), "w", encoding="utf-8") as output:
        print("trellis-memo-rebuilt-reprove", file=output)
    sys.exit(1)
info = os.fstat(handle)
if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.geteuid():
    sys.exit(1)
data = os.read(handle, 65537)
os.close(handle)
memo = load(data.decode("utf-8"))
def is_sha(value):
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)
if (len(data) > 65536 or not isinstance(memo, dict) or sorted(memo) != ["default_shims", "manifest_sha256", "payload",
        "post_checkout", "pre_push", "pre_push_source", "schema_version", "shims"]
        or type(memo["schema_version"]) is not int or memo["schema_version"] != 2 or memo["manifest_sha256"] != manifest or memo["payload"] != payload
        or memo["pre_push_source"] != source or not is_sha(memo["post_checkout"]) or not is_sha(memo["pre_push"])
        or not isinstance(memo["shims"], dict) or not all(is_sha(value) for value in memo["shims"].values())
        or not isinstance(memo["default_shims"], dict) or not all(is_sha(value) for value in memo["default_shims"].values())
        or not passthrough_names or len(set(passthrough_names)) != len(passthrough_names)
        or set(memo["shims"]) != set(passthrough_names) or set(memo["default_shims"]) != set(passthrough_names)
        or source not in ("core-rules/githooks/pre-push", "core-rules/husky/pre-push")
        or os.path.realpath(managed) != managed):
    sys.exit(1)
private(managed, stat.S_ISDIR, 0o700)
private(managed.rsplit("/", 1)[0], stat.S_ISDIR, 0o700)
wanted = {"post-checkout": memo["post_checkout"], "pre-push": memo["pre_push"]}
# No recorded predecessor: the default hooks dir, regular files only.
if previous:
    folder = previous if previous.startswith("/") else root + "/" + previous
    shims, links = memo["shims"], True
else:
    folder = common + "/hooks"
    shims, links = memo["default_shims"], False
if os.path.isdir(folder) and (links or not os.path.islink(folder)):
    for name in os.listdir(folder):
        entry = folder + "/" + name
        if (name in shims and (os.path.isfile(entry) or os.path.islink(entry)) and os.access(entry, os.X_OK)
                and (links or not os.path.islink(entry))):
            wanted[name] = shims[name]
sidecars = ("previous-hooks-path", "release-payload", "pre-push-source")
if set(os.listdir(managed)) != set(wanted) | set(sidecars):
    sys.exit(1)
for name in sidecars:
    private(managed + "/" + name, stat.S_ISREG, 0o600)
for name in wanted:
    private(managed + "/" + name, stat.S_ISREG, 0o700)
    if digest(managed + "/" + name) != wanted[name]:
        sys.exit(1)
def hooks_path(*scope):
    found = subprocess.run(("/usr/bin/git", "-C", root, "config") + scope + ("core.hooksPath",),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return found.returncode == 0 and found.stdout == (managed + "\n").encode()
if not (hooks_path("--local", "--get-all") and hooks_path("--get")):
    sys.exit(1)
renders = dict((item["path"], item) for item in owner.get("renders") or [])
owned = []
for item in owner["artifacts"]:
    path = root
    for part in item["path"].split("/")[:-1]:
        path += "/" + part
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            sys.exit(1)
    path = root + "/" + item["path"]
    info = os.lstat(path)
    if item["kind"] == "symlink":
        exact = stat.S_ISLNK(info.st_mode) and os.readlink(path) == item["target"]
    elif item["kind"] == "parent":
        exact = stat.S_ISDIR(info.st_mode)
    elif item["kind"] == "file":
        exact = stat.S_ISREG(info.st_mode) and "%04o" % stat.S_IMODE(info.st_mode) == item["mode"]
        if exact:
            with open(path, "rb") as handle:
                data = handle.read()
            render = renders.get(item["path"])
            if render is None:
                exact = hashlib.sha256(data).hexdigest() == item["sha256"]
            else:
                current = load(data.decode("utf-8"))
                exact = isinstance(current, dict) and "%04o" % stat.S_IMODE(info.st_mode) == render["after_mode"]
                for key in render["owned_keys"]:
                    value = current
                    for part in key["path"]:
                        if not exact or not isinstance(value, dict) or part not in value:
                            exact = False
                            break
                        value = value[part]
                    exact = exact and owned_value_matches(key["path"], value, key["value"])
    else:
        exact = False
    if not exact:
        sys.exit(1)
    owned.append(item["path"])
for fd, path, expected in pins:
    if fingerprint(os.fstat(fd)) != expected or fingerprint(os.lstat(path)) != expected:
        sys.exit(1)
with os.fdopen(os.dup(3), "w", encoding="utf-8") as output:
    for path in owned:
        print(path, file=output)
' "$@" "$program" "$project_root" "$payload" "$managed_dir" "$owner" "$managed_home" \
        "$expected_release_manifest_sha256" "$common" "$expected_passthrough_names" \
        "$trellis_owner_schema_b64" "$trellis_manifest_schema_b64" 2>/dev/null
    }
    trellis_verify_release_executed "$payload" stamped
  )" || proof_rc=$?
  if [ "$proof_rc" -ne 0 ]; then
    if [ "$memo_attempt" -eq 0 ] && [ "$owned" = trellis-memo-rebuilt-reprove ]; then
      memo_attempt=1
      proof_rc=0
      continue
    fi
    return 1
  fi
  if [ -n "$changed" ]; then
    printf '%s\n' "$owned" "" "$changed" | /usr/bin/awk '
      !sep && $0 == "" { sep = 1; next }
      { $0 = tolower($0) }
      !sep { owned[$0] = 1; up = $0; while (sub(/\/[^\/]*$/, "", up)) above[up] = 1; next }
      $0 == ".trellis.json" || substr($0, 1, 1) == "\"" || ($0 in owned) || ($0 in above) { exit 1 }
      { up = $0; while (sub(/\/[^\/]*$/, "", up)) if (up in owned) exit 1 }
    ' || return 1
  fi
  return 0
  done
}
# Git passes 0 as the third argument for a file checkout (`git checkout --
# <path>`, `git restore`). It changes no branch and adds no worktree, so only
# the prior hook runs, before the private scratch exists: nothing on that path
# allocates a temporary. A branch switch, a rebase and a new worktree pass 1.
if [ "${3:-}" != 0 ]; then
  trellis_enter_command_scratch
  if ! trellis_record_creation_base "$@"; then
    printf 'trellis post-checkout: warning: could not record branch creation base; use diff-base.sh set <parent>.\n' >&2
  fi
fi
previous="$(trellis_read_sidecar "$managed_dir/previous-hooks-path" true)" || exit 1
prior_status=0
prior_hook="$(trellis_prior_hook "$previous" post-checkout)" || prior_hook=""
if [ -n "$prior_hook" ] && { [ -f "$prior_hook" ] || [ -L "$prior_hook" ]; } && [ -x "$prior_hook" ]; then
  trellis_run_prior_hook "$prior_hook" "$@"
  prior_status=$?
fi
if [ "${3:-}" = 0 ] || trellis_worktree_current "$@"; then
  exit "$prior_status"
fi
reconcile_status=0
reconcile_output=""
payload=""
if payload="$(trellis_read_sidecar "$managed_dir/release-payload")" &&
   reconcile="$(trellis_managed_payload_file "$payload" scripts/seed-inheritance-symlinks.sh)"; then
  reconcile_output="$(trellis_run_control_payload "$reconcile" --target "$project_root" --quiet 2>&1)"
  reconcile_status=$?
else
  reconcile_status=1
  reconcile_output="managed release reconciliation payload is unavailable"
fi
if [ "$prior_status" -ne 0 ]; then
  exit "$prior_status"
fi
if [ "$reconcile_status" -ne 0 ]; then
  printf 'trellis post-checkout: attachment reconciliation failed (status %s); see the cause below, then retry `trellis worktree sync` and restart this session.\n' "$reconcile_status" >&2
  [ -z "$reconcile_output" ] || printf '%s\n' "$reconcile_output" >&2
  exit "$reconcile_status"
fi
# trellis-deferred-release-verify: the check before the reconcile covered only
# the files it runs. The async attachment-status job (1.3.12 A4) starts the
# full release verify here; pre-push still runs it in full before any carrier.
exit 0
EOF
}

_attachment_hooks_pre_push_dispatcher_body_in_process() {
  # A failed common body must not be hidden by the successful cat that follows.
  _attachment_hooks_dispatcher_common_body "${1:-}" "${2:-}" "${3:-}" || return "$?"
  cat <<'EOF'
# Leave the common body's EXIT scratch cleanup intact, including signal exits.
trellis_pre_push_postcheck() {
  local local_hooks effective_hooks
  local_hooks="$(git -C "$project_root" config --local --get-all core.hooksPath 2>/dev/null || true; printf '.')"
  local_hooks="${local_hooks%.}"
  effective_hooks="$(git -C "$project_root" config --get core.hooksPath 2>/dev/null || true)"
  if [ "$local_hooks" = "$managed_dir"$'\n' ] && [ "$effective_hooks" = "$managed_dir" ]; then
    return 0
  fi
  printf 'trellis pre-push: core.hooksPath does not match managed dispatcher — restore with: git config --replace-all core.hooksPath %q\n' "$managed_dir" >&2
  if [ "$(git -C "$project_root" config --bool --get extensions.worktreeConfig 2>/dev/null || true)" = true ] &&
     git -C "$project_root" config --worktree --get core.hooksPath >/dev/null 2>&1; then
    printf 'core.hooksPath: clear worktree override with: git config --worktree --unset core.hooksPath\n' >&2
  fi
  return 1
}
trap 'trellis_pre_push_postcheck || :; exit 129' HUP
trap 'trellis_pre_push_postcheck || :; exit 130' INT
trap 'trellis_pre_push_postcheck || :; exit 143' TERM
# Refs staging lives in the private command scratch, which the EXIT trap armed
# above removes wholesale. A refs-only EXIT trap here would replace that trap
# and leak the scratch directory, so there is none.
refs_file="$(mktemp "$TMPDIR/trellis-pre-push.XXXXXX")" || exit 1
chmod 600 "$refs_file" || exit 1
cat > "$refs_file" || exit 1
previous="$(trellis_read_sidecar "$managed_dir/previous-hooks-path" true)" || exit 1
carrier_status=0
attach_status=0
payload=""
source=""
carrier=""
if payload="$(trellis_read_sidecar "$managed_dir/release-payload")" &&
   source="$(trellis_read_sidecar "$managed_dir/pre-push-source")" &&
   [ "$source" = "$expected_pre_push_source" ] &&
   carrier="$(trellis_managed_payload_file "$payload" "$source")"; then
  # The deferred attachment checks decide first, before any suite: FAILED or
  # blocked refuses, ok passes, anything else runs them inline. A refusal
  # starts neither the chained prior hook nor the gate.
  if postjob="$(trellis_managed_payload_file "$payload" scripts/lib/attach-postjob.sh verified)"; then
    trellis_run_control_payload "$postjob" prepush --target "$project_root" < /dev/null
    attach_status=$?
  else
    attach_status=1
    printf 'trellis pre-push: managed attachment checks are unavailable\n' >&2
  fi
else
  carrier_status=1
  printf 'trellis pre-push: managed immutable release carrier is unavailable\n' >&2
fi
prior_status=0
if [ "$attach_status" -eq 0 ]; then
  prior_hook="$(trellis_prior_hook "$previous" pre-push)" || prior_hook=""
  if [ -n "$prior_hook" ] && { [ -f "$prior_hook" ] || [ -L "$prior_hook" ]; } && [ -x "$prior_hook" ]; then
    trellis_run_prior_hook "$prior_hook" "$@" < "$refs_file"
    prior_status=$?
  fi
fi
# The chained prior hook ran after the early verdict, so the release payload, the
# pre-push source and the carrier are read and fully verified again, and the
# deferred attachment checks decide again, before the gate. The early verdict is
# not reused across that hook boundary: a prior hook may replace the carrier or
# publish a pending adoption while the suite runs.
if [ "$attach_status" -eq 0 ] && [ "$carrier_status" -eq 0 ]; then
  if payload="$(trellis_read_sidecar "$managed_dir/release-payload")" &&
     source="$(trellis_read_sidecar "$managed_dir/pre-push-source")" &&
     [ "$source" = "$expected_pre_push_source" ] &&
     carrier="$(trellis_managed_payload_file "$payload" "$source")"; then
    if postjob="$(trellis_managed_payload_file "$payload" scripts/lib/attach-postjob.sh verified)"; then
      trellis_run_control_payload "$postjob" prepush --target "$project_root" < /dev/null
      attach_status=$?
    else
      attach_status=1
      printf 'trellis pre-push: managed attachment checks are unavailable\n' >&2
    fi
  else
    carrier_status=1
    printf 'trellis pre-push: managed immutable release carrier is unavailable\n' >&2
  fi
fi
if [ "$attach_status" -eq 0 ] && [ "$carrier_status" -eq 0 ]; then
  trellis_run_gate_payload "$carrier" "$@" < "$refs_file"
  carrier_status=$?
else
  carrier_status=1
fi
# Check after BOTH hooks, even when no carrier ran. Mirror common.sh/doctor:
# one literal local value plus the effective value, never last-local-value wins.
trellis_pre_push_postcheck || exit 1
if [ "$prior_status" -ne 0 ]; then
  exit "$prior_status"
fi
exit "$carrier_status"
EOF
}

_attachment_hooks_post_checkout_dispatcher_body() {
  _attachment_hooks_dispatcher_body_from_payload post-checkout "${1:-}" "" "${2:-}"
}

_attachment_hooks_pre_push_dispatcher_body() {
  _attachment_hooks_dispatcher_body_from_payload pre-push "${1:-}" "${2:-}" "${3:-}"
}

_attachment_hooks_state_owned_matches_data() {
  local home=$1 owner=$2 strict=${3:-true} checkout managed previous release payload source manifest stored root post_checkout pre_push
  checkout=$(printf '%s\n' "$owner" | jq -r '.checkout_id') || return 4
  managed=$(printf '%s\n' "$owner" | jq -r '.git_hooks.managed_hooks_path // empty') || return 4
  [ "$managed" = "$home/state/git-hooks/$checkout" ] || return 3
  [ -d "$home/state/git-hooks" ] && [ ! -L "$home/state/git-hooks" ] || return 3
  _attachment_canonical_dir "$home/state/git-hooks" || return 3
  _attachment_mode_matches "$home/state/git-hooks" 700 || return 3
  _attachment_canonical_dir "$managed" || return 3
  _attachment_mode_matches "$managed" 700 || return 3
  _attachment_hooks_has_only_state_files "$managed" || return 3
  previous=$(printf '%s\n' "$owner" | jq -r '.git_hooks.previous_hooks_path // empty') || return 4
  release=$(printf '%s\n' "$owner" | jq -r '.release') || return 4
  source=$(printf '%s\n' "$owner" | jq -r '.git_hooks.pre_push_source // empty') || return 4
  _attachment_hooks_pre_push_source_valid "$source" || return 3
  payload="$home/releases/$release/payload"
  stored=$(_attachment_hooks_read_sidecar "$managed/previous-hooks-path" true) || return 3
  [ "$stored" = "$previous" ] || return 3
  [ "$previous" != "$managed" ] || return 3
  stored=$(_attachment_hooks_read_sidecar "$managed/release-payload") || return 3
  [ "$stored" = "$payload" ] || return 3
  payload="$stored"
  manifest=$(_attachment_hooks_release_manifest_sha256 "$payload") || return 3
  stored=$(_attachment_hooks_read_sidecar "$managed/pre-push-source") || return 3
  [ "$stored" = "$source" ] || return 3
  _attachment_mode_matches "$managed/previous-hooks-path" 600 || return 3
  _attachment_mode_matches "$managed/release-payload" 600 || return 3
  _attachment_mode_matches "$managed/pre-push-source" 600 || return 3
  post_checkout="$(_attachment_hooks_post_checkout_dispatcher_body "$payload" "$manifest")" || return 3
  pre_push="$(_attachment_hooks_pre_push_dispatcher_body "$payload" "$source" "$manifest")" || return 3
  [ -n "$post_checkout" ] && [ -n "$pre_push" ] || return 3
  _attachment_hooks_file_matches "$managed/post-checkout" "$post_checkout" 700 || return 3
  _attachment_hooks_file_matches "$managed/pre-push" "$pre_push" 700 || return 3
  case "$strict" in
    true)
      root=$(printf '%s\n' "$owner" | jq -r '.worktree_root') || return 4
      _attachment_hooks_verify_passthrough_shims "$managed" "$root" "$previous" "$payload" || return 3
      ;;
    *)
      _attachment_hooks_present_shims_match "$managed" || return 3
      ;;
  esac
}

_attachment_hooks_state_owned_matches() {
  local home=$1 owner=$2 data
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 4
  data=$(jq -c . "$owner") || return 4
  _attachment_hooks_state_owned_matches_data "$home" "$data"
}

_attachment_hooks_state_matches() {
  local home=$1 owner=$2 release payload source carrier
  _attachment_hooks_state_owned_matches "$home" "$owner" || return $?
  release=$(jq -r '.release' "$owner") || return 4
  source=$(jq -r '.git_hooks.pre_push_source' "$owner") || return 4
  payload="$home/releases/$release/payload"
  _attachment_canonical_dir "$payload" || return 3
  carrier="$payload/$source"
  _attachment_canonical_file "$carrier" || return 3
  [ -x "$carrier" ] || return 3
}

_attachment_verify_managed_hooks() {
  local home=$1 owner=$2 enabled root managed current
  enabled=$(jq -r '.git_hooks.enabled // false' "$owner") || return 4
  [ "$enabled" = true ] || return 0
  _attachment_hooks_state_matches "$home" "$owner" || return $?
  root=$(jq -r '.worktree_root' "$owner") || return 4
  managed=$(jq -r '.git_hooks.managed_hooks_path' "$owner") || return 4
  current=$(_attachment_hooks_current_path "$root") || return $?
  [ "$current" = "$managed" ] || return 3
}

_attachment_verify_adoption_hooks() {
  local home=$1 owner=$2 enabled
  enabled=$(jq -r '.git_hooks.enabled // false' "$owner") || return 4
  case "$enabled" in
    true) _attachment_hooks_state_matches "$home" "$owner" || return $? ;;
    false) ;;
    *) return 4 ;;
  esac
  _attachment_hooks_authority "$home" "$owner"
}

_attachment_json_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  jq -e . "$1" >/dev/null 2>&1
}

_attachment_write_json() {
  local path=$1 json=$2 parent tmp
  [ ! -L "$path" ] || return 3
  trellis_dirname_to parent "$path" || return 1
  _attachment_canonical_dir "$parent" || return 1
  tmp=$(mktemp "$path.tmp.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

_attachment_plan_filter='
  def exact($allowed): ((keys_unsorted - $allowed) | length) == 0;
  def controls: test("[[:cntrl:]]");
  def abs: type == "string" and startswith("/") and . != "/" and (endswith("/") | not)
    and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
  def toolchain_path: type == "array" and length > 0 and all(.[]; abs);
  def rel: type == "string" and length > 0 and (startswith("/") | not) and (endswith("/") | not)
    and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
  def sha: type == "string" and test("^[a-f0-9]{64}$");
  def b64: type == "string" and test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");
  def mode: type == "string" and test("^0[0-7]{3}$");
  def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
  def semver: type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\\+([0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*))?$");
  def replacement:
    type == "object" and exact(["before_base64","before_mode","before_sha256"])
    and (.before_base64 | b64) and (.before_mode | mode) and (.before_sha256 | sha);
  def artifact:
    type == "object" and (.path | rel) and
    if .kind == "file" then
      (.sha256 | sha)
      and (if has("source")
           then exact(["kind","path","sha256","source","mode","replace"])
             and (.source | abs)
           elif has("content_base64")
           then exact(["content_base64","kind","mode","path","replace","sha256"])
             and (.content_base64 | b64)
           else false end)
      and (if has("mode") then (.mode | mode) else true end)
      and (if has("replace") then (.replace | replacement) else true end)
    elif .kind == "symlink" then exact(["kind","path","target"]) and (.target | type == "string" and length > 0 and (controls | not))
    elif .kind == "directory" or .kind == "parent" then exact(["kind","path"])
    else false end;
  def hook_source: . == "core-rules/husky/pre-push" or . == "core-rules/githooks/pre-push";
  def hooks:
    type == "object" and exact(["enabled","managed_hooks_path","previous_hooks_path","pre_push_source"])
    and (.enabled | type == "boolean")
    and (if .enabled then
      has("managed_hooks_path") and (.managed_hooks_path | abs)
      and has("previous_hooks_path") and (.previous_hooks_path == null or (.previous_hooks_path | type == "string" and length > 0 and (controls | not)))
      and has("pre_push_source") and (.pre_push_source | hook_source)
    else
      (if has("managed_hooks_path") then .managed_hooks_path == null else true end)
      and (if has("previous_hooks_path") then .previous_hooks_path == null else true end)
      and (if has("pre_push_source") then .pre_push_source == null else true end)
    end);
  def exclude:
    type == "object" and exact(["after_base64","after_exists","after_sha256","before_base64","before_exists","before_sha256","git_common_dir","managed_block_base64","managed_block_sha256","managed_by_attachment","path"])
    and (.path | abs) and (.git_common_dir | abs) and (.path == (.git_common_dir + "/info/exclude"))
    and (.before_exists | type == "boolean") and (.after_exists | type == "boolean")
    and (.before_sha256 | sha) and (.managed_block_sha256 | sha) and (.after_sha256 | sha)
    and (.before_base64 | b64) and (.managed_block_base64 | b64) and (.after_base64 | b64)
    and (.managed_by_attachment | type == "boolean");
  def json_path: type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (controls | not));
  def rendered:
    type == "object" and exact(["after_base64","after_mode","after_sha256","before_base64","before_exists","before_mode","before_sha256","created_paths","merge","mode","owned_keys","path"])
    and (.path | rel) and .merge == "explicit-json" and (.mode | mode) and (.after_mode | mode)
    and (.before_exists | type == "boolean")
    and (.before_mode == null or (.before_mode | mode))
    and (.before_sha256 | sha) and (.before_base64 | b64) and (.after_sha256 | sha) and (.after_base64 | b64)
    and (.owned_keys | type == "array" and all(.[]; type == "object" and exact(["path","value"]) and (.path | json_path)))
    and (.created_paths | type == "array" and all(.[]; json_path));
  def shell_quote:
    type == "string" and length >= 2 and startswith("\u0027") and endswith("\u0027") and (controls | not);
  def render_context:
    type == "object"
    and exact(["launcher","launcher_shell","schema_version","trellis_home","trellis_home_shell","user_home","user_home_shell"])
    and .schema_version == 1
    and (.user_home | abs) and (.trellis_home | abs) and (.launcher | abs)
    and (.user_home_shell | shell_quote) and (.trellis_home_shell | shell_quote) and (.launcher_shell | shell_quote);
  def contextual_render:
    .path == ".claude/settings.local.json" or .path == ".codex/hooks.json";
  def contextual_renders:
    has("renders") and (.renders | type == "array" and any(.[]; contextual_render));
  def deferred:
    type == "object" and exact(["kind","path","reason","target"]) and (.path | rel)
    and (if .kind == "symlink"
         then (.reason == "pre-existing-symlink" or .reason == "project-authored-file")
           and (.target | type == "string" and length > 0 and (controls | not))
         elif .kind == "file"
         then .reason == "project-authored-render" and .target == null
         else false end);
  type == "object"
    and exact(["$schema","artifacts","attachment_id","checkout_id","exclude","exclude_block_hash","fleet","git_hooks","pre_existing","project_id","project_root","release","render_context","renders","schema_version","status","surface","toolchain_path","worktree_id","worktree_root"])
    and (if has("$schema") then (."$schema" | type == "string" and length > 0) else true end)
    and .schema_version == 1 and .status == "prepared"
    and (if has("surface") then .surface == "project" else true end)
    and (.fleet | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))
    and (.project_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
    and (.checkout_id | sha) and (.worktree_id | sha) and (.attachment_id | uuid)
    and (.project_root | abs) and (.worktree_root | abs) and (.release | semver)
    and (.artifacts | type == "array" and length > 0 and all(.[]; artifact))
    and (if has("pre_existing") then (.pre_existing | type == "array" and all(.[]; deferred) and ((map(.path) | unique | length) == length)) else true end)
    and (([.artifacts[].path] - [(.pre_existing // [])[].path] | length) == (.artifacts | length))
    and (if has("renders") then (.renders | type == "array" and all(.[]; rendered) and ((map(.path) | unique | length) == length)) else true end)
    and (if contextual_renders then has("render_context") and (.render_context | render_context) else ((has("render_context") | not) or .render_context == null) end)
    and (if has("exclude_block_hash") then (.exclude_block_hash | sha) else true end)
    and (if has("exclude") then has("exclude_block_hash") and (.exclude_block_hash == .exclude.managed_block_sha256) and (.exclude | exclude) else true end)
    and (if has("toolchain_path") then (.toolchain_path | toolchain_path) else true end)
    and (if has("git_hooks") then (.git_hooks | hooks) else true end)'
_attachment_validate_plan_file() {
  _attachment_json_file "$1" || return 2
  jq -e "$_attachment_plan_filter" "$1" >/dev/null 2>&1 || return 2
}

_attachment_normalize_plan() {
  jq -cS '{schema_version,status,fleet,project_id,checkout_id,worktree_id,attachment_id,project_root,worktree_root,release,artifacts}
    + (if has("surface") then {surface} else {} end)
    + (if has("toolchain_path") then {toolchain_path} else {} end)
    + (if has("pre_existing") then {pre_existing} else {} end)
    + (if has("renders") then {renders} else {} end)
    + (if has("render_context") then {render_context} else {} end)
    + (if has("exclude_block_hash") then {exclude_block_hash} else {} end)
    + (if has("exclude") then {exclude} else {} end)
    + (if has("git_hooks") then {git_hooks} else {} end)' "$1"
}
_attachment_validate_collisions() {
  printf '%s\n' "$1" | jq -e '
    .artifacts as $artifacts
    | [
        range(0; $artifacts | length) as $left
        | range($left + 1; $artifacts | length) as $right
        | ($artifacts[$left].path | ascii_downcase) as $left_path
        | ($artifacts[$right].path | ascii_downcase) as $right_path
        | select(
            $left_path == $right_path
            or (($right_path | startswith($left_path + "/")) and $artifacts[$left].kind != "parent")
            or ($left_path | startswith($right_path + "/"))
          )
      ]
    | length == 0
  ' >/dev/null 2>&1
}

_attachment_parent_safe() {
  local root=$1 relative=$2 parent current part
  local -a parts
  trellis_dirname_to parent -- "$relative" || return 1
  [ "$parent" != . ] || return 0
  current=$root
  IFS=/ read -r -a parts <<< "$parent"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || return 1
    current="$current/$part"
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
  done
  return 0
}

_attachment_validate_planned_parents() {
  local plan=$1 root path parent current part relative kind destination planned found
  local -a parts planned_parents=()
  root=$(printf '%s\n' "$plan" | jq -r '.worktree_root') || return 2
  while IFS= read -r -d '' path && IFS= read -r -d '' kind; do
    trellis_dirname_to parent -- "$path" || return 2
    if [ "$parent" != . ]; then
      current=$root
      relative=
      IFS=/ read -r -a parts <<< "$parent"
      for part in "${parts[@]}"; do
        [ -n "$part" ] || return 2
        current="$current/$part"
        if [ -n "$relative" ]; then relative="$relative/$part"; else relative=$part; fi
        if [ -e "$current" ] || [ -L "$current" ]; then
          [ -d "$current" ] && [ ! -L "$current" ] || return 3
        else
          found=false
          for planned in "${planned_parents[@]+"${planned_parents[@]}"}"; do
            [ "$planned" != "$relative" ] || { found=true; break; }
          done
          [ "$found" = true ] || return 2
        fi
      done
    fi
    destination="$root/$path"
    if [ "$kind" = parent ] && { [ -e "$destination" ] || [ -L "$destination" ]; }; then
      [ -d "$destination" ] && [ ! -L "$destination" ] || return 3
    fi
    [ "$kind" != parent ] || planned_parents+=("$path")
  done < <(printf '%s\n' "$plan" | jq -j '.artifacts[] | .path, "\u0000", .kind, "\u0000"')
  return 0
}

_attachment_git_common_dir() {
  local root=$1 common
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) CDPATH='' cd "$common" && pwd -P ;;
    *) CDPATH='' cd "$root/$common" && pwd -P ;;
  esac
}

_attachment_validate_ids() {
  local plan=$1 root common expected actual
  root=$(printf '%s\n' "$plan" | jq -r '.worktree_root') || return 2
  expected=$(printf '%s\n' "$plan" | jq -r '.worktree_id') || return 2
  actual=$(_attachment_hash_text "$root") || return 2
  [ "$actual" = "$expected" ] || return 2
  common=$(_attachment_git_common_dir "$root") || return 2
  expected=$(printf '%s\n' "$plan" | jq -r '.checkout_id') || return 2
  actual=$(_attachment_hash_text "$common") || return 2
  [ "$actual" = "$expected" ] || return 2
}

_attachment_validate_roots() {
  local plan=$1 project_root worktree_root
  project_root=$(printf '%s\n' "$plan" | jq -r '.project_root') || return 2
  worktree_root=$(printf '%s\n' "$plan" | jq -r '.worktree_root') || return 2
  _attachment_canonical_dir "$project_root" || return 2
  _attachment_canonical_dir "$worktree_root" || return 2
}

_attachment_validate_sources() {
  local plan=$1 error_code=$2 has_source source expected content_type actual
  while IFS= read -r -d '' has_source && IFS= read -r -d '' source &&
        IFS= read -r -d '' expected && IFS= read -r -d '' content_type; do
    if [ "$has_source" = true ]; then
      _attachment_canonical_file "$source" || return "$error_code"
      actual=$(_attachment_hash "$source") || return "$error_code"
      [ "$actual" = "$expected" ] || return "$error_code"
    else
      [ "$content_type" = string ] || return "$error_code"
    fi
  done < <(printf '%s\n' "$plan" | jq -j '
    .artifacts[] | select(.kind == "file")
    | has("source"), "\u0000", .source, "\u0000", .sha256, "\u0000", (.content_base64 | type), "\u0000"')
  return 0
}

_attachment_destination() {
  printf '%s/%s\n' "$1" "$2"
}

_attachment_validate_destinations_absent() {
  local plan=$1 root path has_replace destination before_hash before_mode actual
  root=$(printf '%s\n' "$plan" | jq -r '.worktree_root') || return 2
  while IFS= read -r -d '' path && IFS= read -r -d '' has_replace &&
        IFS= read -r -d '' before_hash && IFS= read -r -d '' before_mode; do
    destination="$root/$path"
    if [ "$has_replace" = true ]; then
      [ -f "$destination" ] && [ ! -L "$destination" ] || return 3
      actual=$(_attachment_hash "$destination") || return 3
      [ "$actual" = "$before_hash" ] && _attachment_mode_matches "$destination" "$before_mode" || return 3
    else
      [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
    fi
  done < <(printf '%s\n' "$plan" | jq -j '
    .artifacts[] | .path, "\u0000", has("replace"), "\u0000",
    .replace.before_sha256, "\u0000", .replace.before_mode, "\u0000"')
}

_attachment_ownership_path() {
  printf '%s/state/attachments/%s/%s.json\n' "$1" "$2" "$3"
}

_attachment_journal_path() {
  printf '%s/state/attachment-journals/%s.json\n' "$1" "$2"
}

_attachment_detach_journal_path() {
  printf '%s/state/attachment-journals/detach-%s.json\n' "$1" "$2"
}

_attachment_stage_prefix() {
  local root=$1 relative=$2 attachment=$3 destination parent base
  destination=$(_attachment_destination "$root" "$relative")
  parent=$(dirname "$destination")
  base=$(basename "$destination")
  printf '%s/.%s.attachment-stage-%s.' "$parent" "$base" "$attachment"
}

_attachment_stage_path() {
  printf '%stest\n' "$(_attachment_stage_prefix "$1" "$2" "$3")"
}

_attachment_stage_candidate() {
  mktemp -u "$(_attachment_stage_prefix "$1" "$2" "$3")XXXXXX"
}

_attachment_stage_path_valid() {
  local root=$1 artifact=$2 attachment=$3 stage=$4 relative prefix suffix
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 1
  _attachment_parent_safe "$root" "$relative" || return 1
  _attachment_valid_absolute "$stage" || return 1
  prefix=$(_attachment_stage_prefix "$root" "$relative" "$attachment") || return 1
  case "$stage" in
    "$prefix"*) ;;
    *) return 1 ;;
  esac
  suffix=${stage#"$prefix"}
  [ -n "$suffix" ] || return 1
  case "$suffix" in */*) return 1 ;; esac
  _attachment_has_controls "$suffix" && return 1
  return 0
}

_attachment_reclaim_unidentified_stage() (
  local stage=$1 expected_parent=$2 kind=${3:-file} parent base
  parent=$(dirname "$stage") || return 2
  base=$(basename "$stage") || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  if [ -e "./$base" ] || [ -L "./$base" ]; then
    case "$kind" in
      file|symlink)
        [ -L "./$base" ] || { [ -f "./$base" ] && [ ! -L "./$base" ]; } || return 3
        rm -- "./$base" || return 1
        ;;
      directory|parent)
        [ -d "./$base" ] && [ ! -L "./$base" ] || return 3
        rmdir -- "./$base" || return 3
        ;;
      *) return 2 ;;
    esac
  fi
)

_attachment_journal_json_valid() {
  local file=$1
  _attachment_json_file "$file" || return 2
  [ "$(_attachment_mode "$file")" = 600 ] || return 3
  jq -e "(. as \$journal
    | (del(.applied,.phase,.pending,.removal,.journal_version) | $_attachment_plan_filter)
    and ((has(\"journal_version\") | not) or .journal_version == 2)
    and ((keys_unsorted - [\"applied\",\"phase\",\"pending\",\"removal\",\"journal_version\",\"artifacts\",\"attachment_id\",\"checkout_id\",\"exclude\",\"exclude_block_hash\",\"fleet\",\"git_hooks\",\"pre_existing\",\"project_id\",\"project_root\",\"release\",\"render_context\",\"renders\",\"schema_version\",\"status\",\"surface\",\"toolchain_path\",\"worktree_id\",\"worktree_root\"]) | length) == 0
    and (.phase | type == \"number\" and floor == . and . >= 0 and . <= (\$journal.artifacts | length))
    and (.applied | type == \"array\")
    and .applied == .artifacts[0:.phase]
    and (.removal == null or (.removal | type == \"object\"
      and (keys | sort) == [\"nonce\",\"path\"]
      and (.path | type == \"string\" and startswith(\"/\") and . != \"/\" and (endswith(\"/\") | not)
        and (contains(\"//\") | not) and (test(\"(^|/)\\\\.\\\\.?(/|$)\") | not) and (test(\"[[:cntrl:]]\") | not))
      and (.nonce | type == \"string\" and test(\"^[a-f0-9]{64}$\"))))
    and (.pending == null or (.pending | type == \"object\"
      and ((keys_unsorted - [\"artifact\",\"destination_identity\",\"parent_identity\",\"staging_identity\",\"staging_path\"]) | length) == 0
      and \$journal.phase < (\$journal.artifacts | length)
      and .artifact == \$journal.artifacts[\$journal.phase]
      and ((has(\"parent_identity\") | not) or (.parent_identity | type == \"string\" and test(\"^[0-9]+:[0-9]+$\")))
      and (.staging_path == null or (.staging_path | type == \"string\"))
      and (.staging_identity == null or (.staging_identity | type == \"string\" and test(\"^[0-9]+:[0-9]+$\")))
      and (.destination_identity == null or (.destination_identity | type == \"string\" and test(\"^[0-9]+:[0-9]+$\")))
      and (if .artifact.kind == \"directory\" or .artifact.kind == \"parent\"
        then ((.staging_path == null and .staging_identity == null) or (.staging_path | type == \"string\"))
        else (.staging_path | type == \"string\") and .destination_identity == null
        end))))" "$file" >/dev/null 2>&1 || return 2
}

# The owner record schema, shared by the per-file check and the batch check of
# a checkout's owners (attachment_detach_owners_batch).
_attachment_owner_schema_filter='
    def exact($allowed): ((keys_unsorted - $allowed) | length) == 0;
    def controls: test("[[:cntrl:]]");
    def abs: type == "string" and startswith("/") and . != "/" and (endswith("/") | not)
      and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
    def toolchain_path: type == "array" and length > 0 and all(.[]; abs);
    def rel: type == "string" and length > 0 and (startswith("/") | not) and (endswith("/") | not)
      and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
    def sha: type == "string" and test("^[a-f0-9]{64}$");
    def b64: type == "string" and test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");
    def mode: type == "string" and test("^0[0-7]{3}$");
    def semver: type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\\+([0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*))?$");
    def hook_source: . == "core-rules/husky/pre-push" or . == "core-rules/githooks/pre-push";
    def hooks:
      type == "object" and exact(["enabled","managed_hooks_path","previous_hooks_path","pre_push_source"])
      and (.enabled | type == "boolean")
      and (if .enabled then
        has("managed_hooks_path") and (.managed_hooks_path | abs)
        and has("previous_hooks_path") and (.previous_hooks_path == null or (.previous_hooks_path | type == "string" and length > 0 and (controls | not)))
        and has("pre_push_source") and (.pre_push_source | hook_source)
      else
        (if has("managed_hooks_path") then .managed_hooks_path == null else true end)
        and (if has("previous_hooks_path") then .previous_hooks_path == null else true end)
        and (if has("pre_push_source") then .pre_push_source == null else true end)
      end);
    def exclude:
      type == "object" and exact(["after_base64","after_exists","after_sha256","before_base64","before_exists","before_sha256","git_common_dir","managed_block_base64","managed_block_sha256","managed_by_attachment","path"])
      and (.path | abs) and (.git_common_dir | abs) and (.path == (.git_common_dir + "/info/exclude"))
      and (.before_exists | type == "boolean") and (.after_exists | type == "boolean")
      and (.before_sha256 | sha) and (.managed_block_sha256 | sha) and (.after_sha256 | sha)
      and (.before_base64 | b64) and (.managed_block_base64 | b64) and (.after_base64 | b64)
      and (.managed_by_attachment | type == "boolean");
    def json_path: type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (controls | not));
    def rendered:
      type == "object" and exact(["after_base64","after_mode","after_sha256","before_base64","before_exists","before_mode","before_sha256","created_paths","merge","mode","owned_keys","path"])
      and (.path | rel) and .merge == "explicit-json" and (.mode | mode) and (.after_mode | mode)
      and (.before_exists | type == "boolean") and (.before_mode == null or (.before_mode | mode))
      and (.before_sha256 | sha) and (.before_base64 | b64) and (.after_sha256 | sha) and (.after_base64 | b64)
      and (.owned_keys | type == "array" and all(.[]; type == "object" and exact(["path","value"]) and (.path | json_path)))
      and (.created_paths | type == "array" and all(.[]; json_path));
    def shell_quote:
      type == "string" and length >= 2 and startswith("\u0027") and endswith("\u0027") and (controls | not);
    def render_context:
      type == "object"
      and exact(["launcher","launcher_shell","schema_version","trellis_home","trellis_home_shell","user_home","user_home_shell"])
      and .schema_version == 1
      and (.user_home | abs) and (.trellis_home | abs) and (.launcher | abs)
      and (.user_home_shell | shell_quote) and (.trellis_home_shell | shell_quote) and (.launcher_shell | shell_quote);
    def contextual_render:
      .path == ".claude/settings.local.json" or .path == ".codex/hooks.json";
    def contextual_renders:
      has("renders") and (.renders | type == "array" and any(.[]; contextual_render));
    def deferred:
      type == "object" and exact(["kind","path","reason","target"]) and (.path | rel)
      and (if .kind == "symlink"
           then (.reason == "pre-existing-symlink" or .reason == "project-authored-file")
             and (.target | type == "string" and length > 0 and (controls | not))
           elif .kind == "file"
           then .reason == "project-authored-render" and .target == null
           else false end);
    def owned:
      type == "object" and (.path | rel) and
      if .kind == "file" then exact(["kind","mode","path","sha256"]) and (.sha256 | sha) and (if has("mode") then (.mode | mode) else true end)
      elif .kind == "symlink" then exact(["kind","path","target"]) and (.target | type == "string" and length > 0 and (controls | not))
      elif .kind == "directory" or .kind == "parent" then exact(["kind","path"])
      else false end;
    type == "object"
      and exact(["$schema","artifacts","attachment_id","checkout_id","exclude","exclude_block_hash","fleet","git_hooks","pre_existing","project_id","project_root","release","render_context","renders","schema_version","status","surface","toolchain_path","worktree_id","worktree_root"])
      and (if has("$schema") then (."$schema" | type == "string" and length > 0) else true end)
      and .schema_version == 1 and .status == "committed"
      and (if has("surface") then .surface == "project" else true end)
      and (.fleet | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))
      and (.project_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      and (.checkout_id | sha) and (.worktree_id | sha)
      and (.attachment_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
      and (.project_root | abs) and (.worktree_root | abs) and (.release | semver)
      and (.artifacts | type == "array" and length > 0 and all(.[]; owned))
      and (if has("pre_existing") then (.pre_existing | type == "array" and all(.[]; deferred) and ((map(.path) | unique | length) == length)) else true end)
      and (([.artifacts[].path] - [(.pre_existing // [])[].path] | length) == (.artifacts | length))
      and (if has("renders") then (.renders | type == "array" and all(.[]; rendered) and ((map(.path) | unique | length) == length)) else true end)
      and (if contextual_renders then has("render_context") and (.render_context | render_context) else ((has("render_context") | not) or .render_context == null) end)
      and (if has("exclude_block_hash") then (.exclude_block_hash | sha) else true end)
      and (if has("exclude") then has("exclude_block_hash") and (.exclude_block_hash == .exclude.managed_block_sha256) and (.exclude | exclude) else true end)
      and (if has("toolchain_path") then (.toolchain_path | toolchain_path) else true end)
      and (if has("git_hooks") then (.git_hooks | hooks) else true end)
'

_attachment_owner_json_valid() {
  local file=$1
  _attachment_json_file "$file" || return 2
  [ "$(_attachment_mode "$file")" = 600 ] || return 3
  jq -e "$_attachment_owner_schema_filter" "$file" >/dev/null 2>&1 || return 2
}

_attachment_plan_from_journal() {
  jq -cS 'del(.applied,.phase,.pending,.removal,.journal_version)' "$1"
}

_attachment_owner_from_plan() {
  printf '%s\n' "$1" | jq -cS '.status = "committed" | .artifacts |= map(if .kind == "file" then del(.source,.content_base64,.replace) else . end)'
}

_attachment_journal_from_plan() {
  local plan=$1 phase=${2:-0}
  printf '%s\n' "$plan" | jq -cS --argjson phase "$phase" \
    '. + {applied: .artifacts[0:$phase], phase: $phase, pending: null, removal: null}'
}

_attachment_same_journal_plan() {
  local journal=$1 plan=$2 actual expected
  _attachment_journal_json_valid "$journal" || return $?
  actual=$(_attachment_plan_from_journal "$journal") || return 2
  expected=$(printf '%s\n' "$plan" | jq -cS .) || return 2
  [ "$actual" = "$expected" ] || return 3
}

_attachment_path_exact() {
  local path=$1 artifact=$2 kind expected has_mode mode target
  while IFS= read -r -d '' kind && IFS= read -r -d '' expected &&
        IFS= read -r -d '' has_mode && IFS= read -r -d '' mode && IFS= read -r -d '' target; do
    _attachment_path_exact_fields "$path" "$kind" "$expected" "$has_mode" "$mode" "$target"
    return $?
  done < <(printf '%s\n' "$artifact" | jq -j '
    .kind, "\u0000", .sha256, "\u0000", has("mode"), "\u0000", .mode, "\u0000", .target, "\u0000"')
  return 1
}

# Decoded fields let owner verification keep one jq process for the whole loop.
_attachment_path_exact_fields() {
  local path=$1 kind=$2 expected=$3 has_mode=$4 mode=$5 target=$6 actual first
  [ -e "$path" ] || [ -L "$path" ] || return 1
  case "$kind" in
    file)
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
      actual=$(_attachment_hash "$path") || return 1
      [ "$actual" = "$expected" ] || return 1
      if [ "$has_mode" = true ]; then
        _attachment_mode_matches "$path" "$mode" || return 1
      fi
      ;;
    symlink)
      [ -L "$path" ] || return 1
      _attachment_symlink_matches "$path" "$target"
      ;;
    directory)
      [ -d "$path" ] && [ ! -L "$path" ] || return 1
      first=$(find "$path" -mindepth 1 -print -quit 2>/dev/null) || return 1
      [ -z "$first" ]
      ;;
    parent)
      [ -d "$path" ] && [ ! -L "$path" ]
      ;;
    *) return 1 ;;
  esac
}

_attachment_path_exact_pinned() {
  local path=$1 artifact=$2 kind expected has_mode mode target
  while IFS= read -r -d '' kind && IFS= read -r -d '' expected &&
        IFS= read -r -d '' has_mode && IFS= read -r -d '' mode && IFS= read -r -d '' target; do
    _attachment_path_exact_pinned_fields "$path" "$kind" "$expected" "$has_mode" "$mode" "$target"
    return $?
  done < <(printf '%s\n' "$artifact" | jq -j '
    .kind, "\u0000", .sha256, "\u0000", has("mode"), "\u0000", .mode, "\u0000", .target, "\u0000"')
  return 1
}

_attachment_path_exact_pinned_fields() {
  local path=$1 kind=$2 expected=$3 has_mode=$4 mode=$5 target=$6 parent base actual_parent
  case "$path" in
    /*) trellis_dirname_to parent "$path" || return 1 ;;
    *)
      trellis_dirname_to parent "$path" || :
      parent=$(CDPATH='' cd "$parent" && pwd -P) || return 1
      ;;
  esac
  trellis_basename_to base "$path" || return 1
  _attachment_canonical_dir "$parent" || return 1
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 1
    _attachment_path_exact_fields "./$base" "$kind" "$expected" "$has_mode" "$mode" "$target"
  )
}

_attachment_artifact_exact() {
  local root=$1 artifact=$2 relative destination
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 1
  _attachment_parent_safe "$root" "$relative" || return 1
  destination=$(_attachment_destination "$root" "$relative")
  _attachment_path_exact_pinned "$destination" "$artifact"
}

# Keep the artifact-level parent recheck before pinning, including when the
# caller already preflighted the parent and decoded all fields in one batch.
_attachment_artifact_exact_fields() {
  local root=$1 relative=$2
  shift 2
  _attachment_parent_safe "$root" "$relative" || return 1
  _attachment_path_exact_pinned_fields "$root/$relative" "$@"
}

_attachment_artifact_absent_or_exact() {
  local root=$1 artifact=$2 journal=$3 relative destination removal_path
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 1
  _attachment_parent_safe "$root" "$relative" || return 1
  destination=$(_attachment_destination "$root" "$relative")
  _attachment_claim_namespace_valid "$journal" "$destination" || return 1
  removal_path=$(jq -r '.removal.path // empty' "$journal") || return 1
  if [ "$removal_path" = "$destination" ]; then
    _attachment_journal_claim_layout "$journal" "$destination" || return 1
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      [ "$_ATTACHMENT_CLAIM_STATE" != claimed ] || return 1
      _attachment_path_exact_pinned "$destination" "$artifact"
      return $?
    fi
    case "$_ATTACHMENT_CLAIM_STATE" in
      absent|empty) return 0 ;;
      claimed) _attachment_path_exact_pinned "$_ATTACHMENT_CLAIM_PATH" "$artifact" ;;
      *) return 1 ;;
    esac
    return $?
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    _attachment_path_exact_pinned "$destination" "$artifact"
    return $?
  fi
  return 0
}

_attachment_stage_exact() {
  local stage=$1 artifact=$2 expected actual
  [ -f "$stage" ] && [ ! -L "$stage" ] || return 1
  expected=$(printf '%s\n' "$artifact" | jq -r '.sha256') || return 1
  actual=$(_attachment_hash "$stage") || return 1
  [ "$actual" = "$expected" ]
}

_attachment_identity_matches() {
  local path=$1 expected=$2 kind=$3 actual
  [ -n "$expected" ] || return 1
  case "$kind" in
    file) [ -f "$path" ] && [ ! -L "$path" ] || return 1 ;;
    symlink) [ -L "$path" ] || return 1 ;;
    directory|parent) [ -d "$path" ] && [ ! -L "$path" ] || return 1 ;;
    *) return 1 ;;
  esac
  actual=$(_attachment_fs_identity "$path") || return 1
  [ "$actual" = "$expected" ]
}

# The claim token is a pure function of "nonce:path". One removal asks for
# the same layout several times, so the last digest is reused for the same
# input. Reset on every source so an inherited value is never trusted.
_ATTACHMENT_CLAIM_TOKEN_INPUT=
_ATTACHMENT_CLAIM_TOKEN=

_attachment_claim_layout() {
  local path=$1 nonce=$2 token entries parent
  [ -n "$nonce" ] || return 1
  if [ -n "${_ATTACHMENT_CLAIM_TOKEN:-}" ] && [ "${_ATTACHMENT_CLAIM_TOKEN_INPUT:-}" = "$nonce:$path" ]; then
    token=$_ATTACHMENT_CLAIM_TOKEN
  else
    token=$(_attachment_hash_text "$nonce:$path") || return 1
    _ATTACHMENT_CLAIM_TOKEN_INPUT="$nonce:$path"
    _ATTACHMENT_CLAIM_TOKEN=$token
  fi
  trellis_dirname_to parent "$path" || :
  _ATTACHMENT_QUARANTINE="$parent/.trellis-attachment-remove-$token"
  _ATTACHMENT_CLAIM_PATH="$_ATTACHMENT_QUARANTINE/artifact"
  _ATTACHMENT_CLAIM_STATE=absent
  if [ ! -e "$_ATTACHMENT_QUARANTINE" ] && [ ! -L "$_ATTACHMENT_QUARANTINE" ]; then
    return 0
  fi
  _attachment_canonical_dir "$_ATTACHMENT_QUARANTINE" || return 1
  entries=$(find "$_ATTACHMENT_QUARANTINE" -mindepth 1 -maxdepth 1 -print 2>/dev/null) || return 1
  if [ -z "$entries" ]; then
    _ATTACHMENT_CLAIM_STATE=empty
    return 0
  fi
  [ "$entries" = "$_ATTACHMENT_CLAIM_PATH" ] || return 1
  [ -e "$_ATTACHMENT_CLAIM_PATH" ] || [ -L "$_ATTACHMENT_CLAIM_PATH" ] || return 1
  _ATTACHMENT_CLAIM_STATE=claimed
}

# One jq decodes a journal's removal intent as three NUL-terminated fields:
# "null" and two empty fields, or "set", the path and the nonce (NULs dropped
# as command substitution drops them). A removal that is not an object with
# string path and nonce prints nothing, so the read fails closed.
_attachment_removal_fields_filter='
  if .removal == null then "null", "\u0000\u0000\u0000"
  elif (.removal | type == "object") and (.removal.path | type == "string") and (.removal.nonce | type == "string")
  then "set", "\u0000", (.removal.path | gsub("\u0000"; "")), "\u0000", (.removal.nonce | gsub("\u0000"; "")), "\u0000"
  else empty end'

_attachment_journal_claim_layout() {
  local journal=$1 path=$2 state removal_path nonce
  trellis_read_nul_fields state removal_path nonce < <(jq -j "$_attachment_removal_fields_filter" "$journal") || return 1
  [ "$state" = set ] || return 1
  [ "$removal_path" = "$path" ] || return 1
  _attachment_claim_layout "$path" "$nonce"
}

_attachment_claim_namespace_valid() {
  local journal=$1 path=$2 parent state removal_path removal_parent nonce expected entry entries
  trellis_dirname_to parent "$path" || return 1
  trellis_read_nul_fields state removal_path nonce < <(jq -j "$_attachment_removal_fields_filter" "$journal") || return 1
  expected=
  if [ "$state" = set ]; then
    trellis_dirname_to removal_parent "$removal_path" || :
    if [ "$removal_parent" = "$parent" ]; then
      _attachment_claim_layout "$removal_path" "$nonce" || return 1
      expected=$_ATTACHMENT_QUARANTINE
    fi
  fi
  entries=$(find "$parent" -mindepth 1 -maxdepth 1 -name '.trellis-attachment-remove-*' -print 2>/dev/null) || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$expected" ] || return 1
  done <<< "$entries"
  return 0
}
_attachment_restore_pinned_claim() (
  local journal=$1 path=$2 parent base actual_parent claim identity
  parent=$(dirname "$path") || return 2
  base=$(basename "$path") || return 2
  _attachment_canonical_dir "$parent" || return 3
  _attachment_journal_claim_layout "$journal" "$path" || return 3
  [ "$_ATTACHMENT_CLAIM_STATE" = claimed ] || return 3
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 3
    claim="./$(basename "$_ATTACHMENT_QUARANTINE")/artifact"
    [ -f "$claim" ] && [ ! -L "$claim" ] || return 3
    [ ! -e "./$base" ] && [ ! -L "./$base" ] || return 3
    identity=$(_attachment_fs_identity "$claim") || return 1
    ln -P -- "$claim" "./$base" 2>/dev/null || return 3
    _attachment_identity_matches "./$base" "$identity" file || return 3
    rm -- "$claim" || return 1
    rmdir "./$(basename "$_ATTACHMENT_QUARANTINE")" || return 1
    _attachment_clear_removal_intent "$journal"
  )
)

_attachment_claim_pinned() (
  local journal=$1 path=$2 artifact=$3 expected_identity=$4
  local parent base actual_parent removal removal_path kind claim
  parent=$(dirname "$path") || return 2
  base=$(basename "$path") || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  [ "$kind" = file ] || return 2
  _attachment_canonical_dir "$parent" || return 3
  _attachment_claim_namespace_valid "$journal" "$path" || return 3
  removal=$(jq -c '.removal' "$journal") || return 2
  if [ "$removal" = null ]; then
    _attachment_identity_matches "$path" "$expected_identity" file || return 3
    _attachment_path_exact "$path" "$artifact" || return 3
    _attachment_set_removal_intent "$journal" "$path" || return 1
  else
    removal_path=$(printf '%s\n' "$removal" | jq -r '.path') || return 2
    [ "$removal_path" = "$path" ] || return 3
  fi
  _attachment_journal_claim_layout "$journal" "$path" || return 3
  _attachment_claim_namespace_valid "$journal" "$path" || return 3
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 3
    _attachment_journal_claim_layout "$journal" "$path" || return 3
    claim="./$(basename "$_ATTACHMENT_QUARANTINE")/artifact"
    case "$_ATTACHMENT_CLAIM_STATE" in
      absent)
        _attachment_identity_matches "./$base" "$expected_identity" file || return 3
        _attachment_path_exact "./$base" "$artifact" || return 3
        mkdir -- "./$(basename "$_ATTACHMENT_QUARANTINE")" 2>/dev/null || return 3
        chmod 700 "./$(basename "$_ATTACHMENT_QUARANTINE")" || return 1
        mv -- "./$base" "$claim" || return 3
        ;;
      empty)
        # Killed between creating the journaled quarantine and claiming the
        # leaf: finish that claim, as _attachment_remove_pinned does. Up to
        # 1.5.1 this refused forever (render-conflict on recover).
        _attachment_identity_matches "./$base" "$expected_identity" file || return 3
        _attachment_path_exact "./$base" "$artifact" || return 3
        chmod 700 "./$(basename "$_ATTACHMENT_QUARANTINE")" || return 1
        mv -- "./$base" "$claim" || return 3
        ;;
      claimed)
        [ ! -e "./$base" ] && [ ! -L "./$base" ] || return 3
        ;;
      *) return 3 ;;
    esac
    if ! _attachment_identity_matches "$claim" "$expected_identity" file ||
      ! _attachment_path_exact "$claim" "$artifact"; then
      _attachment_restore_pinned_claim "$journal" "$path" || return 3
      return 3
    fi
  )
)

_attachment_discard_pinned_claim() (
  local journal=$1 path=$2 artifact=$3 expected_identity=$4
  local parent actual_parent claim
  parent=$(dirname "$path") || return 2
  _attachment_canonical_dir "$parent" || return 3
  _attachment_journal_claim_layout "$journal" "$path" || return 3
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 3
    claim="./$(basename "$_ATTACHMENT_QUARANTINE")/artifact"
    case "$_ATTACHMENT_CLAIM_STATE" in
      claimed)
        _attachment_identity_matches "$claim" "$expected_identity" file || return 3
        _attachment_path_exact "$claim" "$artifact" || return 3
        rm -- "$claim" || return 1
        ;;
      empty) ;;
      absent)
        # Killed after the claim and its quarantine were removed, before the
        # clear: only the clear is left, unless the claimed file is back in
        # place. Up to 1.5.1 this refused forever.
        claim="./$(basename "$path")"
        if [ -e "$claim" ] || [ -L "$claim" ]; then
          ! _attachment_identity_matches "$claim" "$expected_identity" file || return 3
        fi
        _attachment_clear_removal_intent "$journal"
        return $?
        ;;
      *) return 3 ;;
    esac
    rmdir "./$(basename "$_ATTACHMENT_QUARANTINE")" || return 1
    _attachment_clear_removal_intent "$journal"
  )
)

_attachment_publish_pinned_stage() (
  local stage=$1 destination=$2 identity=$3 expected_hash=$4 expected_mode=$5
  local parent stage_parent stage_base destination_base actual_parent actual
  parent=$(dirname "$destination") || return 2
  stage_parent=$(dirname "$stage") || return 2
  [ "$parent" = "$stage_parent" ] || return 3
  stage_base=$(basename "$stage") || return 2
  destination_base=$(basename "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 3
    _attachment_identity_matches "./$stage_base" "$identity" file || return 3
    actual=$(_attachment_hash "./$stage_base") || return 1
    [ "$actual" = "$expected_hash" ] && _attachment_mode_matches "./$stage_base" "$expected_mode" || return 3
    [ ! -e "./$destination_base" ] && [ ! -L "./$destination_base" ] || return 3
    ln -P -- "./$stage_base" "./$destination_base" 2>/dev/null || return 3
    _attachment_identity_matches "./$destination_base" "$identity" file || return 3
    actual=$(_attachment_hash "./$destination_base") || return 1
    [ "$actual" = "$expected_hash" ] && _attachment_mode_matches "./$destination_base" "$expected_mode" || return 3
  )
)

_attachment_remove_pinned() {
  local journal=$1 path=$2 artifact=$3 expected_identity=${4:-} require_identity=${5:-0} require_exact=${6:-1}
  local removal removal_path resuming=1 parent base actual_parent kind quarantine claimed remove_status
  trellis_dirname_to parent "$path" || return 2
  trellis_basename_to base "$path" || return 2
  _attachment_canonical_dir "$parent" || return 3
  _attachment_claim_namespace_valid "$journal" "$path" || return 3
  removal=$(jq -c '.removal' "$journal") || return 2
  if [ "$removal" = null ]; then
    _attachment_set_removal_intent "$journal" "$path" || return 1
    resuming=0
  else
    removal_path=$(printf '%s\n' "$removal" | jq -r '.path') || return 2
    if [ "$removal_path" != "$path" ]; then
      [ ! -e "$path" ] && [ ! -L "$path" ] || return 3
      return 0
    fi
  fi
  _attachment_journal_claim_layout "$journal" "$path" || return 3
  [ "$resuming" -eq 1 ] || [ "$_ATTACHMENT_CLAIM_STATE" = absent ] || return 3
  _attachment_claim_namespace_valid "$journal" "$path" || return 3
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 3
    _attachment_journal_claim_layout "$journal" "$path" || return 3
    trellis_basename_to quarantine "$_ATTACHMENT_QUARANTINE" || :
    quarantine="./$quarantine"
    claimed="$quarantine/artifact"
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
    case "$_ATTACHMENT_CLAIM_STATE" in
      absent)
        if [ ! -e "./$base" ] && [ ! -L "./$base" ]; then
          _attachment_clear_removal_intent "$journal" || return 1
          return 0
        fi
        mkdir -- "$quarantine" 2>/dev/null || return 3
        chmod 700 "$quarantine" || return 1
        mv -- "./$base" "$claimed" || return 3
        ;;
      empty)
        if [ -e "./$base" ] || [ -L "./$base" ]; then
          chmod 700 "$quarantine" || return 1
          mv -- "./$base" "$claimed" || return 3
        else
          rmdir "$quarantine" || return 1
          _attachment_clear_removal_intent "$journal" || return 1
          return 0
        fi
        ;;
      claimed)
        [ ! -e "./$base" ] && [ ! -L "./$base" ] || return 3
        ;;
      *) return 3 ;;
    esac
    if { [ "$require_identity" -eq 1 ] && ! _attachment_identity_matches "$claimed" "$expected_identity" "$kind"; } ||
      { [ "$require_exact" -eq 1 ] && ! _attachment_path_exact "$claimed" "$artifact"; }; then
      if [ ! -e "./$base" ] && [ ! -L "./$base" ]; then
        mv -- "$claimed" "./$base" 2>/dev/null || return 3
        rmdir "$quarantine" 2>/dev/null || return 3
      fi
      return 3
    fi
    remove_status=0
    case "$kind" in
      directory|parent) rmdir -- "$claimed" || remove_status=3 ;;
      file|symlink) rm -- "$claimed" || remove_status=1 ;;
      *) remove_status=2 ;;
    esac
    if [ "$remove_status" -ne 0 ]; then
      if [ -e "$claimed" ] || [ -L "$claimed" ]; then
        if [ ! -e "./$base" ] && [ ! -L "./$base" ]; then
          mv -- "$claimed" "./$base" 2>/dev/null || return "$remove_status"
        fi
      fi
      rmdir "$quarantine" 2>/dev/null
      return "$remove_status"
    fi
    rmdir "$quarantine" || return 1
    _attachment_clear_removal_intent "$journal" || return 1
    return 0
  )
}

_attachment_pending_stage_owned() {
  local root=$1 pending=$2 journal=$3 artifact kind stage identity attachment removal_path expected_parent parent
  artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  [ -n "$stage" ] || return 0
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  _attachment_stage_path_valid "$root" "$artifact" "$attachment" "$stage" || return 3
  parent=$(dirname "$stage") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  _attachment_claim_namespace_valid "$journal" "$stage" || return 3
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  removal_path=$(jq -r '.removal.path // empty' "$journal") || return 2
  if [ -z "$identity" ]; then
    [ -z "$removal_path" ] || return 3
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      case "$kind" in
        file|symlink)
          [ -L "$stage" ] || { [ -f "$stage" ] && [ ! -L "$stage" ]; } || return 3
          ;;
        directory|parent)
          [ -d "$stage" ] && [ ! -L "$stage" ] || return 3
          ;;
        *) return 2 ;;
      esac
    fi
    return 0
  fi
  if [ "$removal_path" = "$stage" ]; then
    _attachment_journal_claim_layout "$journal" "$stage" || return 3
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      [ "$_ATTACHMENT_CLAIM_STATE" != claimed ] || return 3
      _attachment_identity_matches "$stage" "$identity" "$kind" || return 3
      return 0
    fi
    case "$_ATTACHMENT_CLAIM_STATE" in
      absent|empty) return 0 ;;
      claimed) _attachment_identity_matches "$_ATTACHMENT_CLAIM_PATH" "$identity" "$kind" || return 3 ;;
      *) return 3 ;;
    esac
    return 0
  fi
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    _attachment_identity_matches "$stage" "$identity" "$kind" || return 3
  fi
}

_attachment_pending_destination_owned() {
  local root=$1 pending=$2 journal=$3 artifact relative destination kind identity removal_path
  artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
  _attachment_parent_safe "$root" "$relative" || return 3
  destination=$(_attachment_destination "$root" "$relative")
  _attachment_claim_namespace_valid "$journal" "$destination" || return 3
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  if [ "$kind" = directory ] || [ "$kind" = parent ]; then
    identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // .staging_identity // empty') || return 2
  else
    identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  fi
  removal_path=$(jq -r '.removal.path // empty' "$journal") || return 2
  if [ "$removal_path" = "$destination" ]; then
    _attachment_journal_claim_layout "$journal" "$destination" || return 3
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      [ "$_ATTACHMENT_CLAIM_STATE" != claimed ] || return 3
      _attachment_identity_matches "$destination" "$identity" "$kind" || return 3
      _attachment_path_exact_pinned "$destination" "$artifact" || return 3
      return 0
    fi
    case "$_ATTACHMENT_CLAIM_STATE" in
      absent|empty) return 0 ;;
      claimed)
        _attachment_identity_matches "$_ATTACHMENT_CLAIM_PATH" "$identity" "$kind" || return 3
        _attachment_path_exact_pinned "$_ATTACHMENT_CLAIM_PATH" "$artifact" || return 3
        ;;
      *) return 3 ;;
    esac
    return 0
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    _attachment_identity_matches "$destination" "$identity" "$kind" || return 3
    _attachment_path_exact_pinned "$destination" "$artifact" || return 3
  fi
}

attach_detach_json_keys_detail() {
  local file=$1 keys=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  # The planner is the single type-strict comparison authority. jq numeric
  # equality normalizes 1 and 1.0, which must not disagree with subtraction.
  settings_owned_json detail "$file" "$keys" 2>/dev/null
}

attach_detach_json_keys_match() {
  local file=$1 keys=$2 detail
  detail="$(attach_detach_json_keys_detail "$file" "$keys")" || return 1
  printf '%s\n' "$detail" | jq -e 'length == 0' >/dev/null 2>&1
}

attach_detach_render_state() {
  local root=$1 render=$2 path current_hash after_hash before_hash after_mode before_mode before_exists keys
  path="$(printf '%s\n' "$render" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  before_exists="$(printf '%s\n' "$render" | jq -r '.before_exists')" || return "$TRELLIS_EX_STATE"
  after_hash="$(printf '%s\n' "$render" | jq -r '.after_sha256')" || return "$TRELLIS_EX_STATE"
  before_hash="$(printf '%s\n' "$render" | jq -r '.before_sha256')" || return "$TRELLIS_EX_STATE"
  after_mode="$(printf '%s\n' "$render" | jq -r '.after_mode')" || return "$TRELLIS_EX_STATE"
  before_mode="$(printf '%s\n' "$render" | jq -r '.before_mode // empty')" || return "$TRELLIS_EX_STATE"
  if [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ]; then
    [ "$before_exists" = false ] && { printf 'before\n'; return 0; }
    _attachment_refuse "${ATTACHMENT_ACTION:-}" render-missing "$root/$path"
    return "$TRELLIS_EX_CONFLICT"
  fi
  [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" render-not-regular "$root/$path"
    return "$TRELLIS_EX_CONFLICT"
  }
  current_hash="$(_attachment_hash "$root/$path")" || return "$TRELLIS_EX_STATE"
  if [ "$current_hash" = "$after_hash" ] && _attachment_mode_matches "$root/$path" "$after_mode"; then
    printf 'after\n'
    return 0
  fi
  if [ "$before_exists" = true ] && [ "$current_hash" = "$before_hash" ] && _attachment_mode_matches "$root/$path" "$before_mode"; then
    printf 'before\n'
    return 0
  fi
  keys="$(printf '%s\n' "$render" | jq -c '.owned_keys')" || return "$TRELLIS_EX_STATE"
  _attachment_mode_matches "$root/$path" "$after_mode" || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" render-mode "$root/$path"
    return "$TRELLIS_EX_CONFLICT"
  }
  attach_detach_json_keys_match "$root/$path" "$keys" || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owned-key-value-changed "$root/$path"
    return "$TRELLIS_EX_CONFLICT"
  }
  printf 'merged\n'
}

attach_detach_render_preflight() {
  local owner=$1 renders=$2 root render state path
  root="$(printf '%s\n' "$owner" | jq -r '.worktree_root')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r render; do
    state="$(attach_detach_render_state "$root" "$render")" || return "$?"
    case "$state" in
      after|merged) ;;
      *)
        # `before`: the file is back to its pre-attach bytes, or gone when it
        # did not exist before attach.
        path="$root/$(printf '%s\n' "$render" | jq -r '.path')"
        if [ -e "$path" ] || [ -L "$path" ]; then
          _attachment_refuse "${ATTACHMENT_ACTION:-}" render-reverted "$path"
        else
          _attachment_refuse "${ATTACHMENT_ACTION:-}" render-missing "$path"
        fi
        return "$TRELLIS_EX_CONFLICT"
        ;;
    esac
  done < <(printf '%s\n' "$renders" | jq -c 'sort_by(.path)[]')
}

_attachment_render_pairings_valid() {
  printf '%s\n' "$1" | jq -e '
    . as $owner
    | all(($owner.renders // [])[];
        . as $render
        | [$owner.artifacts[] | select(.path == $render.path)] as $artifacts
        | ($artifacts | length) == 1
        and $artifacts[0].kind == "file"
        and $artifacts[0].path == $render.path
        and $artifacts[0].mode == $render.after_mode
        and $artifacts[0].sha256 == $render.after_sha256)
  ' >/dev/null 2>&1
}

_attachment_render_owned_keys_exact() (
  local root=$1 render=$2 relative destination parent base actual_parent after_mode keys
  relative="$(printf '%s\n' "$render" | jq -r '.path')" || return 1
  after_mode="$(printf '%s\n' "$render" | jq -r '.after_mode')" || return 1
  keys="$(printf '%s\n' "$render" | jq -c '.owned_keys')" || return 1
  _attachment_parent_safe "$root" "$relative" || return 1
  destination="$(_attachment_destination "$root" "$relative")" || return 1
  parent="$(dirname "$destination")" || return 1
  base="$(basename "$destination")" || return 1
  _attachment_canonical_dir "$parent" || return 1
  CDPATH='' cd "$parent" || return 1
  actual_parent="$(pwd -P)" || return 1
  [ "$actual_parent" = "$parent" ] || return 1
  [ -f "./$base" ] && [ ! -L "./$base" ] || return 1
  _attachment_mode_matches "./$base" "$after_mode" || return 1
  jq -e 'type == "object"' "./$base" >/dev/null 2>&1 || return 1
  attach_detach_json_keys_match "./$base" "$keys"
)

# A third argument "proven-leaves" skips only the per-artifact leaf loop. The
# donor fast path passes it when a canonical verify of these exact owner bytes
# ran in this attach (attachment_verify_donor) and attach-fastpath.py has just
# re-proved every leaf under the transaction locks with its stricter
# artifact_exact (no-follow walk from /, single-link files, sha256, mode,
# symlink target, empty directory). Every other check here still runs.
_attachment_verify_owner_artifacts() {
  local owner=$1 expected_trellis_home="${2:-}" leaves="${3:-all}" record root relative kind expected has_mode mode target render
  record=$(jq -c . "$owner") || return 3
  _attachment_contextual_render_context_record_valid "$record" "$expected_trellis_home" || return 3
  # Before _attachment_validate_roots: that is the check that actually refuses a
  # vanished worktree, and it does so with a bare 3 naming nothing.
  root=$(printf '%s\n' "$record" | jq -r '.worktree_root') || return 3
  if [ ! -d "$root" ]; then
    _attachment_diag "owner record names a worktree root that no longer exists: $root"
    return 3
  fi
  _attachment_validate_roots "$record" || return 3
  _attachment_validate_ids "$record" || return 3
  _attachment_render_pairings_valid "$record" || return 3
  case "$leaves" in all|proven-leaves) ;; *) return 2 ;; esac
  if [ "$leaves" = all ]; then
  while IFS= read -r -d '' relative && IFS= read -r -d '' kind &&
        IFS= read -r -d '' expected && IFS= read -r -d '' has_mode &&
        IFS= read -r -d '' mode && IFS= read -r -d '' target; do
    if ! _attachment_parent_safe "$root" "$relative" ||
       ! _attachment_artifact_exact_fields "$root" "$relative" "$kind" "$expected" "$has_mode" "$mode" "$target"; then
      _attachment_diag "owned artifact does not match its record: $relative (recorded $kind) under $root"
      return 3
    fi
  done < <(printf '%s\n' "$record" | jq -j '
    . as $owner
    | (($owner.renders // []) | map(.path)) as $render_paths
    | $owner.artifacts[] as $artifact
    | select(($render_paths | index($artifact.path)) == null)
    | $artifact | .path, "\u0000", .kind, "\u0000", .sha256, "\u0000",
      has("mode"), "\u0000", .mode, "\u0000", .target, "\u0000"
  ')
  fi
  while IFS= read -r render; do
    _attachment_render_owned_keys_exact "$root" "$render" || {
      _attachment_diag "owned render does not match its record: $root/$(printf '%s\n' "$render" | jq -r '.path')"
      return 3
    }
  done < <(printf '%s\n' "$record" | jq -c '(.renders // [])[]')
}

_attachment_verify_detach_owner_artifacts() {
  local owner=$1 record
  record=$(jq -c . "$owner") && _attachment_validate_roots "$record" && _attachment_validate_ids "$record" || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-record-invalid "$owner"
    return 3
  }
  # Sorted by path (code point order, as jq sorted it), so the drifted
  # artifact reported first is deterministic; one process checks them all.
  _attachment_detach_python verify "${ATTACHMENT_ACTION:-}" <<< "$record" || return 3
}

_attachment_owner_matches_plan() {
  local owner=$1 plan=$2 actual expected
  _attachment_owner_json_valid "$owner" || return $?
  actual=$(jq -cS . "$owner") || return 2
  expected=$(_attachment_owner_from_plan "$plan") || return 2
  [ "$actual" = "$expected" ] || return 3
  _attachment_verify_owner_artifacts "$owner"
}

_attachment_lock_path() {
  printf '%s/state/locks/attachment-%s-%s.lock\n' "$1" "$2" "$3"
}

_attachment_lock_holder_prefix() {
  printf '.attachment-%s-%s.holder-' "$1" "$2"
}

_attachment_lock_release() {
  local link=${_ATTACHMENT_LOCK_LINK:-} holder=${_ATTACHMENT_LOCK_HOLDER:-} target
  [ -n "$link" ] && [ -n "$holder" ] || return 0
  if [ -L "$link" ]; then
    target=$(readlink "$link") || return 1
    [ "$(dirname "$holder")/$(basename "$target")" = "$holder" ] || return 1
    rm "$link" || return 1
  fi
  rm -f "$holder/owner.json" "$holder/publisher.lock" || return 1
  rmdir "$holder" 2>/dev/null || return 1
  _ATTACHMENT_LOCK_LINK=
  _ATTACHMENT_LOCK_HOLDER=
}

_attachment_lock_acquire() {
  local home=$1 checkout=$2 worktree=$3 attachment=$4 locks link prefix holder metadata target pid birth
  locks="$home/state/locks"
  link=$(_attachment_lock_path "$home" "$checkout" "$worktree")
  [ ! -e "$link" ] && [ ! -L "$link" ] || return 3
  _attachment_capture_current_pid "$locks" || return 1
  pid=$_ATTACHMENT_PROCESS_PID
  birth=$(_attachment_process_birth "$pid") || return 1
  [ -n "$birth" ] || return 1
  prefix=$(_attachment_lock_holder_prefix "$checkout" "$worktree")
  holder=$(mktemp -d "$locks/${prefix}${attachment}.${pid}.XXXXXX") || return 1
  chmod 700 "$holder" || { rmdir "$holder"; return 1; }
  metadata=$(jq -cn --arg checkout "$checkout" --arg worktree "$worktree" --arg attachment "$attachment" --arg birth "$birth" --argjson pid "$pid" \
    '{checkout_id:$checkout,worktree_id:$worktree,attachment_id:$attachment,pid:$pid,process_birth:$birth}') || { rmdir "$holder"; return 1; }
  _attachment_write_json "$holder/owner.json" "$metadata" || { rmdir "$holder" 2>/dev/null; return 1; }
  target=$(basename "$holder")
  if ! ln -sn -- "$target" "$link" 2>/dev/null; then
    rm -f "$holder/owner.json"
    rmdir "$holder" 2>/dev/null
    return 3
  fi
  _ATTACHMENT_LOCK_LINK=$link
  _ATTACHMENT_LOCK_HOLDER=$holder
  return 0
}

_attachment_lock_reclaim() {
  local home=$1 checkout=$2 worktree=$3 attachment=$4 link locks target holder metadata pid prefix recorded_birth current_birth
  link=$(_attachment_lock_path "$home" "$checkout" "$worktree")
  [ -e "$link" ] || [ -L "$link" ] || return 0
  [ -L "$link" ] || return 4
  target=$(readlink "$link") || return 4
  case "$target" in
    */*|.|..) return 4 ;;
  esac
  prefix=$(_attachment_lock_holder_prefix "$checkout" "$worktree")
  case "$target" in "$prefix"*) ;; *) return 4 ;; esac
  locks="$home/state/locks"
  holder="$locks/$target"
  [ -d "$holder" ] && [ ! -L "$holder" ] || return 4
  metadata="$holder/owner.json"
  _attachment_json_file "$metadata" || return 4
  [ "$(_attachment_mode "$metadata")" = 600 ] || return 4
  jq -e --arg checkout "$checkout" --arg worktree "$worktree" '
    type == "object" and (keys | sort) == ["attachment_id","checkout_id","pid","process_birth","worktree_id"]
      and .checkout_id == $checkout and .worktree_id == $worktree
      and (.attachment_id | type == "string")
      and (.pid | type == "number" and floor == . and . > 0)
      and (.process_birth | type == "string" and length > 0)
  ' "$metadata" >/dev/null 2>&1 || return 4
  [ "$(jq -r '.attachment_id' "$metadata")" = "$attachment" ] || return 3
  pid=$(jq -r '.pid' "$metadata") || return 4
  recorded_birth=$(jq -r '.process_birth' "$metadata") || return 4
  if kill -0 "$pid" 2>/dev/null; then
    current_birth=$(_attachment_process_birth "$pid") || return 4
    [ -n "$current_birth" ] || return 4
    [ "$current_birth" != "$recorded_birth" ] || return 3
  fi
  if [ -e "$holder/publisher.lock" ] || [ -L "$holder/publisher.lock" ]; then
    [ -f "$holder/publisher.lock" ] && [ ! -L "$holder/publisher.lock" ] || return 4
    _attachment_publisher_idle "$holder/publisher.lock" || return $?
  fi
  rm "$link" || return 1
  rm "$metadata" || return 1
  rm -f "$holder/publisher.lock" || return 1
  rmdir "$holder" || return 1
}

# A commit's publisher holds this flock until it exits, even when the shell
# that owns the transaction lock was killed first. Returns 3 while it is held.
_attachment_publisher_idle() {
  local python_bin
  python_bin=$(command -v python3) || return 1
  case "$python_bin" in /*) ;; *) return 1 ;; esac
  "$python_bin" -I -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(3)
' "$1"
}

_attachment_test_stage_lock() {
  local home=$1 checkout=$2 worktree=$3 attachment=$4 pid=$5 locks link prefix holder metadata birth
  _attachment_prepare_state "$home" || return $?
  locks="$home/state/locks"
  link=$(_attachment_lock_path "$home" "$checkout" "$worktree")
  prefix=$(_attachment_lock_holder_prefix "$checkout" "$worktree")
  holder=$(mktemp -d "$locks/${prefix}${attachment}.${pid}.XXXXXX") || return 1
  chmod 700 "$holder" || return 1
  birth=$(_attachment_process_birth "$pid" 2>/dev/null) || birth=test-dead-process
  [ -n "$birth" ] || birth=test-dead-process
  metadata=$(jq -cn --arg checkout "$checkout" --arg worktree "$worktree" --arg attachment "$attachment" --arg birth "$birth" --argjson pid "$pid" \
    '{checkout_id:$checkout,worktree_id:$worktree,attachment_id:$attachment,pid:$pid,process_birth:$birth}') || return 1
  _attachment_write_json "$holder/owner.json" "$metadata" || return 1
  ln -sn -- "$(basename "$holder")" "$link"
}

_attachment_checkout_lock_path() {
  printf '%s/state/locks/attachment-checkout-%s.lock\n' "$1" "$2"
}

_attachment_checkout_lock_holder_prefix() {
  printf '.attachment-checkout-%s.holder-' "$1"
}

_attachment_checkout_lock_release() {
  local link=${_ATTACHMENT_CHECKOUT_LOCK_LINK:-} holder=${_ATTACHMENT_CHECKOUT_LOCK_HOLDER:-} target
  [ -n "$link" ] && [ -n "$holder" ] || return 0
  if [ -L "$link" ]; then
    target=$(readlink "$link") || return 1
    [ "$(dirname "$holder")/$(basename "$target")" = "$holder" ] || return 1
    rm "$link" || return 1
  fi
  rm -f "$holder/owner.json" || return 1
  rmdir "$holder" 2>/dev/null || return 1
  _ATTACHMENT_CHECKOUT_LOCK_LINK=
  _ATTACHMENT_CHECKOUT_LOCK_HOLDER=
}

_attachment_checkout_lock_acquire() {
  local home=$1 checkout=$2 common=$3 locks link prefix holder metadata target pid birth
  _attachment_canonical_dir "$common" || return 2
  [ "$(_attachment_hash_text "$common")" = "$checkout" ] || return 2
  locks="$home/state/locks"
  link=$(_attachment_checkout_lock_path "$home" "$checkout")
  [ ! -e "$link" ] && [ ! -L "$link" ] || return 3
  _attachment_capture_current_pid "$locks" || return 1
  pid=$_ATTACHMENT_PROCESS_PID
  birth=$(_attachment_process_birth "$pid") || return 1
  [ -n "$birth" ] || return 1
  prefix=$(_attachment_checkout_lock_holder_prefix "$checkout")
  holder=$(mktemp -d "$locks/${prefix}${pid}.XXXXXX") || return 1
  chmod 700 "$holder" || { rmdir "$holder"; return 1; }
  metadata=$(jq -cn --arg checkout "$checkout" --arg common "$common" --arg birth "$birth" --argjson pid "$pid" \
    '{checkout_id:$checkout,git_common_dir:$common,pid:$pid,process_birth:$birth}') || { rmdir "$holder"; return 1; }
  _attachment_write_json "$holder/owner.json" "$metadata" || { rmdir "$holder" 2>/dev/null; return 1; }
  target=$(basename "$holder")
  if ! ln -sn -- "$target" "$link" 2>/dev/null; then
    rm -f "$holder/owner.json"
    rmdir "$holder" 2>/dev/null
    return 3
  fi
  _ATTACHMENT_CHECKOUT_LOCK_LINK=$link
  _ATTACHMENT_CHECKOUT_LOCK_HOLDER=$holder
  return 0
}

_attachment_checkout_lock_reclaim() {
  local home=$1 checkout=$2 common=$3 link locks target holder metadata pid prefix recorded_birth current_birth
  _attachment_canonical_dir "$common" || return 2
  [ "$(_attachment_hash_text "$common")" = "$checkout" ] || return 2
  link=$(_attachment_checkout_lock_path "$home" "$checkout")
  [ -e "$link" ] || [ -L "$link" ] || return 0
  [ -L "$link" ] || return 4
  target=$(readlink "$link") || return 4
  case "$target" in
    */*|.|..) return 4 ;;
  esac
  prefix=$(_attachment_checkout_lock_holder_prefix "$checkout")
  case "$target" in "$prefix"*) ;; *) return 4 ;; esac
  locks="$home/state/locks"
  holder="$locks/$target"
  [ -d "$holder" ] && [ ! -L "$holder" ] || return 4
  metadata="$holder/owner.json"
  _attachment_json_file "$metadata" || return 4
  [ "$(_attachment_mode "$metadata")" = 600 ] || return 4
  jq -e --arg checkout "$checkout" --arg common "$common" '
    type == "object" and (keys | sort) == ["checkout_id","git_common_dir","pid","process_birth"]
      and .checkout_id == $checkout and .git_common_dir == $common
      and (.pid | type == "number" and floor == . and . > 0)
      and (.process_birth | type == "string" and length > 0)
  ' "$metadata" >/dev/null 2>&1 || return 4
  pid=$(jq -r '.pid' "$metadata") || return 4
  recorded_birth=$(jq -r '.process_birth' "$metadata") || return 4
  if kill -0 "$pid" 2>/dev/null; then
    current_birth=$(_attachment_process_birth "$pid") || return 4
    [ -n "$current_birth" ] || return 4
    [ "$current_birth" != "$recorded_birth" ] || return 3
  fi
  rm "$link" || return 1
  rm "$metadata" || return 1
  rmdir "$holder" || return 1
}

_attachment_test_stage_checkout_lock() {
  local home=$1 checkout=$2 common=$3 pid=$4 birth=${5:-} locks link prefix holder metadata
  _attachment_prepare_state "$home" || return $?
  _attachment_canonical_dir "$common" || return 2
  [ "$(_attachment_hash_text "$common")" = "$checkout" ] || return 2
  locks="$home/state/locks"
  link=$(_attachment_checkout_lock_path "$home" "$checkout")
  prefix=$(_attachment_checkout_lock_holder_prefix "$checkout")
  holder=$(mktemp -d "$locks/${prefix}${pid}.XXXXXX") || return 1
  chmod 700 "$holder" || return 1
  if [ -z "$birth" ]; then
    birth=$(_attachment_process_birth "$pid" 2>/dev/null) || birth=test-dead-process
    [ -n "$birth" ] || birth=test-dead-process
  fi
  metadata=$(jq -cn --arg checkout "$checkout" --arg common "$common" --arg birth "$birth" --argjson pid "$pid" \
    '{checkout_id:$checkout,git_common_dir:$common,pid:$pid,process_birth:$birth}') || return 1
  _attachment_write_json "$holder/owner.json" "$metadata" || return 1
  ln -sn -- "$(basename "$holder")" "$link"
}

_attachment_validate_journal_binding() {
  local home=$1 journal=$2 checkout worktree attachment canonical plan root pending kind stage artifact
  local destination parent expected_parent
  _attachment_valid_absolute "$journal" || return 2
  _attachment_journal_json_valid "$journal" || return $?
  checkout=$(jq -r '.checkout_id' "$journal") || return 2
  worktree=$(jq -r '.worktree_id' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  canonical=$(_attachment_journal_path "$home" "$attachment")
  [ "$journal" = "$canonical" ] || return 2
  plan=$(_attachment_plan_from_journal "$journal") || return 2
  _attachment_validate_roots "$plan" || return 2
  _attachment_validate_ids "$plan" || return 2
  root=$(jq -r '.worktree_root' "$journal") || return 2
  pending=$(jq -c '.pending' "$journal") || return 2
  _attachment_contextual_render_context_record_valid "$plan" "$home" || return 2
  if [ "$pending" != null ]; then
    artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
    stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
    if [ -n "$stage" ]; then
      parent=$(dirname "$stage") || return 2
      [ "$parent" = "$(dirname "$(_attachment_destination "$root" "$(printf '%s\n' "$artifact" | jq -r '.path')")")" ] || return 2
    elif [ "$kind" = directory ] || [ "$kind" = parent ]; then
      destination=$(_attachment_destination "$root" "$(printf '%s\n' "$artifact" | jq -r '.path')")
      parent=$(dirname "$destination") || return 2
    else
      return 2
    fi
    expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity // empty') || return 2
    _attachment_canonical_dir "$parent" || return 2
    if [ -n "$expected_parent" ]; then
      [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
    fi
    if [ "$kind" = directory ] || [ "$kind" = parent ]; then
      _attachment_parent_safe "$root" "$(printf '%s\n' "$artifact" | jq -r '.path')" || return 2
      if [ -n "$stage" ]; then
        _attachment_stage_path_valid "$root" "$artifact" "$attachment" "$stage" || return 2
      fi
    else
      _attachment_stage_path_valid "$root" "$artifact" "$attachment" "$stage" || return 2
    fi
  fi
  return 0
}

_attachment_upgrade_legacy_journal_pending() {
  local home=$1 journal=$2 pending root artifact kind relative destination stage parent identity next
  _attachment_journal_json_valid "$journal" || return $?
  pending=$(jq -c '.pending' "$journal") || return 2
  [ "$pending" != null ] || return 0
  [ "$(printf '%s\n' "$pending" | jq -r 'has("parent_identity")')" = false ] || return 0
  [ "$journal" = "$(_attachment_journal_path "$home" "$(jq -r '.attachment_id' "$journal")")" ] || return 2
  root=$(jq -r '.worktree_root' "$journal") || return 2
  artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
  _attachment_parent_safe "$root" "$relative" || return 3
  destination=$(_attachment_destination "$root" "$relative")
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  if [ -n "$stage" ]; then
    _attachment_stage_path_valid "$root" "$artifact" "$(jq -r '.attachment_id' "$journal")" "$stage" || return 2
    [ "$(dirname "$stage")" = "$(dirname "$destination")" ] || return 2
    parent=$(dirname "$stage") || return 2
  else
    case "$kind" in directory|parent) parent=$(dirname "$destination") || return 2 ;; *) return 2 ;; esac
  fi
  _attachment_canonical_dir "$parent" || return 3
  identity=$(_attachment_fs_identity "$parent") || return 1
  next=$(jq -cS --arg identity "$identity" '
    if .schema_version == 1 and .pending != null and (.pending | has("parent_identity") | not)
    then .pending.parent_identity = $identity
    else error("invalid legacy pending migration")
    end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_prepare_impl() {
  local home=$1 plan_file=$2 journal=$3 plan checkout worktree attachment owner owner_dir journal_json phase
  [ "$#" -eq 3 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_validate_plan_file "$plan_file" || return $?
  plan=$(_attachment_normalize_plan "$plan_file") || return 2
  _attachment_contextual_render_context_record_valid "$plan" "$home" || return 2
  _attachment_validate_collisions "$plan" || return 3
  _attachment_validate_roots "$plan" || return 2
  _attachment_validate_ids "$plan" || return 2
  _attachment_validate_planned_parents "$plan" || return $?
  _attachment_validate_sources "$plan" 2 || return $?
  checkout=$(printf '%s\n' "$plan" | jq -r '.checkout_id') || return 2
  worktree=$(printf '%s\n' "$plan" | jq -r '.worktree_id') || return 2
  attachment=$(printf '%s\n' "$plan" | jq -r '.attachment_id') || return 2
  [ "$journal" = "$(_attachment_journal_path "$home" "$attachment")" ] || return 2
  owner=$(_attachment_ownership_path "$home" "$checkout" "$worktree")
  owner_dir=$(dirname "$owner")
  _attachment_ensure_private_dir "$owner_dir" || return 1

  if [ -e "$owner" ] || [ -L "$owner" ]; then
    [ "$owner" = "$(_attachment_ownership_path "$home" "$checkout" "$worktree")" ] || return 2
    _attachment_owner_matches_plan "$owner" "$plan" || return $?
    if [ -e "$journal" ] || [ -L "$journal" ]; then
      _attachment_same_journal_plan "$journal" "$plan" || return $?
      return 0
    fi
    phase=$(printf '%s\n' "$plan" | jq '.artifacts | length') || return 1
    journal_json=$(_attachment_journal_from_plan "$plan" "$phase") || return 1
    _attachment_write_json "$journal" "$journal_json" || return $?
    return 0
  fi

  if [ -e "$journal" ] || [ -L "$journal" ]; then
    _attachment_same_journal_plan "$journal" "$plan" || return $?
    return 0
  fi
  _attachment_validate_destinations_absent "$plan" || return $?
  journal_json=$(_attachment_journal_from_plan "$plan" 0) || return 1
  _attachment_write_json "$journal" "$journal_json" || return $?
  return 0
}

_attachment_set_pending_identity() {
  local journal=$1 field=$2 identity=$3 next
  case "$field" in
    staging_identity)
      next=$(jq -cS --arg identity "$identity" '.pending.staging_identity = $identity' "$journal") || return 1
      ;;
    destination_identity)
      next=$(jq -cS --arg identity "$identity" '.pending.destination_identity = $identity' "$journal") || return 1
      ;;
    *) return 2 ;;
  esac
  _attachment_write_json "$journal" "$next"
}

_attachment_new_removal_nonce() {
  local journal=$1 path=$2 candidate
  candidate=$(mktemp -u "$journal.removal.XXXXXX") || return 1
  _attachment_hash_text "$candidate:$path:$RANDOM:$RANDOM"
}

_attachment_set_removal_intent() {
  local journal=$1 path=$2 nonce next
  nonce=$(_attachment_new_removal_nonce "$journal" "$path") || return 1
  next=$(jq -cS --arg path "$path" --arg nonce "$nonce" \
    'if .removal == null then .removal = {path:$path,nonce:$nonce} else error("removal already active") end' "$journal") || return 1
  _attachment_write_json "$journal" "$next"
}

_attachment_clear_removal_intent() {
  local journal=$1 next
  next=$(jq -cS '.removal = null' "$journal") || return 1
  _attachment_write_json "$journal" "$next"
}

_attachment_finalize_pending() {
  local journal=$1 artifact=$2 next
  next=$(trellis_jq -cS --argjson artifact "$artifact" '.applied += [$artifact] | .phase = (.applied | length) | .pending = null' "$journal") || return 1
  _attachment_write_json "$journal" "$next"
}

_attachment_create_file_stage() (
  local journal=$1 artifact=$2 stage_path=$3 source expected actual identity parent base expected_parent stage mode content
  parent=$(dirname "$stage_path") || return 2
  base=$(basename "$stage_path") || return 2
  expected_parent=$(jq -r '.pending.parent_identity // empty' "$journal") || return 2
  [ -n "$expected_parent" ] || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  stage="./$base"
  set -o noclobber
  if ! { exec 9>"$stage"; } 2>/dev/null; then
    set +o noclobber
    return 3
  fi
  set +o noclobber
  identity=$(_attachment_fs_identity "$stage") || { exec 9>&-; return 1; }
  if ! _attachment_set_pending_identity "$journal" staging_identity "$identity"; then
    exec 9>&-
    _attachment_remove_pinned "$journal" "$stage_path" "$artifact" "$identity" 1 0
    return 1
  fi
  if printf '%s\n' "$artifact" | jq -e 'has("mode")' >/dev/null 2>&1; then
    mode=$(printf '%s\n' "$artifact" | jq -r '.mode') || { exec 9>&-; return 2; }
    chmod "${mode#0}" "$stage" || { exec 9>&-; return 1; }
  else
    chmod 600 "$stage" || { exec 9>&-; return 1; }
  fi
  if printf '%s\n' "$artifact" | jq -e 'has("source")' >/dev/null 2>&1; then
    source=$(printf '%s\n' "$artifact" | jq -r '.source') || { exec 9>&-; return 2; }
    cat "$source" >&9 || { exec 9>&-; return 1; }
  else
    content=$(printf '%s\n' "$artifact" | jq -r '.content_base64') || { exec 9>&-; return 2; }
    printf '%s' "$content" | base64 -D 2>/dev/null >&9 || printf '%s' "$content" | base64 -d 2>/dev/null >&9 || { exec 9>&-; return 1; }
  fi
  exec 9>&-
  _attachment_identity_matches "$stage" "$identity" file || return 3
  expected=$(printf '%s\n' "$artifact" | jq -r '.sha256') || return 2
  actual=$(_attachment_hash "$stage") || return 1
  [ "$actual" = "$expected" ] || return 3
  if [ -n "${mode:-}" ]; then _attachment_mode_matches "$stage" "$mode" || return 3; fi
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_create_symlink_stage() (
  local journal=$1 artifact=$2 stage_path=$3 target identity parent base expected_parent stage
  parent=$(dirname "$stage_path") || return 2
  base=$(basename "$stage_path") || return 2
  expected_parent=$(jq -r '.pending.parent_identity // empty' "$journal") || return 2
  [ -n "$expected_parent" ] || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  stage="./$base"
  target=$(printf '%s\n' "$artifact" | jq -r '.target') || return 2
  ln -sn -- "$target" "$stage" 2>/dev/null || return 3
  identity=$(_attachment_fs_identity "$stage") || return 1
  if ! _attachment_set_pending_identity "$journal" staging_identity "$identity"; then
    _attachment_remove_pinned "$journal" "$stage_path" "$artifact" "$identity" 1 0
    return 1
  fi
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_create_directory_destination() (
  local journal=$1 artifact=$2 destination=$3 identity parent base expected_parent path
  parent=$(dirname "$destination") || return 2
  base=$(basename "$destination") || return 2
  expected_parent=$(jq -r '.pending.parent_identity // empty' "$journal") || return 2
  [ -n "$expected_parent" ] || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  path="./$base"
  mkdir -- "$path" 2>/dev/null || return 3
  identity=$(_attachment_fs_identity "$path") || return 1
  if ! _attachment_set_pending_identity "$journal" destination_identity "$identity"; then
    _attachment_remove_pinned "$journal" "$destination" "$artifact" "$identity" 1 1
    return 1
  fi
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_create_directory_stage() (
  local journal=$1 artifact=$2 stage_path=$3 identity parent base expected_parent stage
  parent=$(dirname "$stage_path") || return 2
  base=$(basename "$stage_path") || return 2
  expected_parent=$(jq -r '.pending.parent_identity // empty' "$journal") || return 2
  [ -n "$expected_parent" ] || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  stage="./$base"
  mkdir -- "$stage" 2>/dev/null || return 3
  chmod 700 "$stage" || { rmdir "$stage" 2>/dev/null; return 1; }
  identity=$(_attachment_fs_identity "$stage") || { rmdir "$stage" 2>/dev/null; return 1; }
  if ! _attachment_set_pending_identity "$journal" staging_identity "$identity"; then
    _attachment_identity_matches "$stage" "$identity" "$(printf '%s\n' "$artifact" | jq -r '.kind')" &&
      rmdir "$stage" 2>/dev/null
    return 1
  fi
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_publish_directory_stage() (
  local pending=$1 artifact=$2 stage=$3 destination=$4 expected_parent identity parent stage_parent
  local stage_base destination_base kind
  parent=$(dirname "$destination") || return 2
  stage_parent=$(dirname "$stage") || return 2
  [ "$parent" = "$stage_parent" ] || return 3
  stage_base=$(basename "$stage") || return 2
  destination_base=$(basename "$destination") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  [ -n "$identity" ] || return 3
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  if [ -e "./$stage_base" ] || [ -L "./$stage_base" ]; then
    _attachment_identity_matches "./$stage_base" "$identity" "$kind" || return 3
    [ ! -e "./$destination_base" ] && [ ! -L "./$destination_base" ] || return 3
    mv -- "./$stage_base" "./$destination_base" || return 1
  fi
  _attachment_identity_matches "./$destination_base" "$identity" "$kind" || return 3
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_publish_stage_link() (
  local pending=$1 artifact=$2 stage=$3 destination=$4 kind identity parent stage_parent
  local stage_base destination_base expected_parent
  parent=$(dirname "$destination") || return 2
  stage_parent=$(dirname "$stage") || return 2
  [ "$parent" = "$stage_parent" ] || return 3
  stage_base=$(basename "$stage") || return 2
  destination_base=$(basename "$destination") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  _attachment_identity_matches "./$stage_base" "$identity" "$kind" || return 3
  _attachment_path_exact_pinned "./$stage_base" "$artifact" || return 3
  [ ! -e "./$destination_base" ] && [ ! -L "./$destination_base" ] || return 3
  ln -P -- "./$stage_base" "./$destination_base" 2>/dev/null || return 3
  _attachment_identity_matches "./$destination_base" "$identity" "$kind" || return 3
  _attachment_path_exact_pinned "./$destination_base" "$artifact" || return 3
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_replace_before_matches() {
  local path=$1 artifact=$2 expected mode actual
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  expected=$(printf '%s\n' "$artifact" | jq -r '.replace.before_sha256') || return 1
  mode=$(printf '%s\n' "$artifact" | jq -r '.replace.before_mode') || return 1
  actual=$(_attachment_hash "$path") || return 1
  [ "$actual" = "$expected" ] && _attachment_mode_matches "$path" "$mode"
}

_attachment_publish_stage_replace() (
  local pending=$1 artifact=$2 stage=$3 destination=$4 identity kind parent stage_parent stage_base destination_base expected_parent
  parent=$(dirname "$destination") || return 2
  stage_parent=$(dirname "$stage") || return 2
  [ "$parent" = "$stage_parent" ] || return 3
  stage_base=$(basename "$stage") || return 2
  destination_base=$(basename "$destination") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  _attachment_identity_matches "./$stage_base" "$identity" "$kind" || return 3
  _attachment_path_exact_pinned "./$stage_base" "$artifact" || return 3
  _attachment_replace_before_matches "./$destination_base" "$artifact" || return 3
  mv -f -- "./$stage_base" "./$destination_base" || return 1
  _attachment_identity_matches "./$destination_base" "$identity" "$kind" || return 3
  _attachment_path_exact_pinned "./$destination_base" "$artifact" || return 3
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_publish_stage_restore() (
  local pending=$1 artifact=$2 stage=$3 destination=$4 identity kind parent stage_parent
  local stage_base destination_base expected_parent
  parent=$(dirname "$destination") || return 2
  stage_parent=$(dirname "$stage") || return 2
  [ "$parent" = "$stage_parent" ] || return 3
  stage_base=$(basename "$stage") || return 2
  destination_base=$(basename "$destination") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  [ -n "$identity" ] || return 3
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  _attachment_identity_matches "./$stage_base" "$identity" "$kind" || return 3
  _attachment_path_exact_pinned "./$stage_base" "$artifact" || return 3
  _attachment_user_restore_exact "./$destination_base" "$artifact" || return $?
  mv -f -- "./$stage_base" "./$destination_base" || return 1
  _attachment_identity_matches "./$destination_base" "$identity" "$kind" || return 3
  _attachment_path_exact_pinned "./$destination_base" "$artifact" || return 3
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_restore_replaced_file() (
  local root=$1 artifact=$2 relative destination parent base tmp expected mode content
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
  _attachment_parent_safe "$root" "$relative" || return 3
  destination=$(_attachment_destination "$root" "$relative")
  if _attachment_replace_before_matches "$destination" "$artifact"; then return 0; fi
  _attachment_artifact_exact "$root" "$artifact" || return 3
  expected=$(printf '%s\n' "$artifact" | jq -r '.replace.before_sha256') || return 2
  mode=$(printf '%s\n' "$artifact" | jq -r '.replace.before_mode') || return 2
  parent=$(dirname "$destination") || return 2
  base=$(basename "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  tmp=$(mktemp "$parent/.${base}.attachment-restore.XXXXXX") || return 1
  trap 'rm -f "$tmp"' EXIT
  content=$(printf '%s\n' "$artifact" | jq -r '.replace.before_base64') || return 2
  printf '%s' "$content" | base64 -D 2>/dev/null > "$tmp" || printf '%s' "$content" | base64 -d 2>/dev/null > "$tmp" || return 1
  [ "$(_attachment_hash "$tmp")" = "$expected" ] || return 2
  chmod "${mode#0}" "$tmp" || return 1
  mv -f -- "$tmp" "$destination" || return 1
  _attachment_replace_before_matches "$destination" "$artifact"
)

_attachment_remove_pending_stage() {
  local root=$1 pending=$2 journal=$3 artifact kind stage identity attachment expected_parent
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  [ -n "$stage" ] || return 0
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  _attachment_pending_stage_owned "$root" "$pending" "$journal" || return $?
  artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  _attachment_stage_path_valid "$root" "$artifact" "$attachment" "$stage" || return 3
  if [ -z "$identity" ]; then
    expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
    _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" "$kind"
    return $?
  fi
  _attachment_remove_pinned "$journal" "$stage" "$artifact" "$identity" 1 0
}

_attachment_remove_pending_destination() {
  local root=$1 pending=$2 journal=$3 artifact relative destination kind identity
  artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
  _attachment_parent_safe "$root" "$relative" || return 3
  destination=$(_attachment_destination "$root" "$relative")
  # A replacement killed before its publish still holds the project's bytes,
  # with no staged identity to prove ownership by: there is nothing to undo.
  if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1 &&
    _attachment_replace_before_matches "$destination" "$artifact"; then
    return 0
  fi
  _attachment_pending_destination_owned "$root" "$pending" "$journal" || return $?
  if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
    _attachment_restore_replaced_file "$root" "$artifact"
    return $?
  fi
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  if [ "$kind" = directory ] || [ "$kind" = parent ]; then
    identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // .staging_identity // empty') || return 2
  else
    identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  fi
  _attachment_remove_pinned "$journal" "$destination" "$artifact" "$identity" 1 1
}

_attachment_publish_pending() {
  local journal=$1 plan=$2 pending artifact root attachment path kind destination stage target
  local parent expected_parent stage_identity
  pending=$(jq -c '.pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
  root=$(printf '%s\n' "$plan" | jq -r '.worktree_root') || return 2
  attachment=$(printf '%s\n' "$plan" | jq -r '.attachment_id') || return 2
  path=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  _attachment_parent_safe "$root" "$path" || return 3
  destination=$(_attachment_destination "$root" "$path")
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  parent=$(dirname "$destination") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3

  if [ "$kind" = directory ] || [ "$kind" = parent ]; then
    if [ -z "$stage" ]; then
      if [ "$kind" = parent ]; then
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
      fi
      if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        _attachment_create_directory_destination "$journal" "$artifact" "$destination" || return $?
        pending=$(jq -c '.pending' "$journal") || return 2
      fi
    else
      _attachment_stage_path_valid "$root" "$artifact" "$attachment" "$stage" || return 2
      stage_identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
      if [ -z "$stage_identity" ]; then
        if [ -e "$stage" ] || [ -L "$stage" ]; then
          _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" "$kind" || return $?
        fi
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
        _attachment_create_directory_stage "$journal" "$artifact" "$stage" || return $?
        pending=$(jq -c '.pending' "$journal") || return 2
        stage_identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity') || return 2
      fi
      if [ -e "$stage" ] || [ -L "$stage" ]; then
        _attachment_publish_directory_stage "$pending" "$artifact" "$stage" "$destination" || return $?
      else
        _attachment_identity_matches "$destination" "$stage_identity" "$kind" || return 3
      fi
      if [ "$(printf '%s\n' "$pending" | jq -r '.destination_identity == null')" = true ]; then
        _attachment_set_pending_identity "$journal" destination_identity "$stage_identity" || return $?
        pending=$(jq -c '.pending' "$journal") || return 2
      fi
    fi
    _attachment_pending_destination_owned "$root" "$pending" "$journal" || return 3
    [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
    _attachment_finalize_pending "$journal" "$artifact"
    return $?
  fi

  _attachment_stage_path_valid "$root" "$artifact" "$attachment" "$stage" || return 2
  stage_identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  if [ -z "$stage_identity" ] && { [ -e "$stage" ] || [ -L "$stage" ]; }; then
    _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" || return $?
  fi
  if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      if _attachment_pending_destination_owned "$root" "$pending" "$journal"; then
        [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
        _attachment_finalize_pending "$journal" "$artifact"
        return $?
      fi
      _attachment_replace_before_matches "$destination" "$artifact" || return 3
    else
      return 3
    fi
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      _attachment_pending_stage_owned "$root" "$pending" "$journal" || return 3
      _attachment_stage_exact "$stage" "$artifact" || return 3
    else
      _attachment_create_file_stage "$journal" "$artifact" "$stage" || return $?
      pending=$(jq -c '.pending' "$journal") || return 2
    fi
    _attachment_publish_stage_replace "$pending" "$artifact" "$stage" "$destination" || return $?
    pending=$(jq -c '.pending' "$journal") || return 2
    _attachment_pending_destination_owned "$root" "$pending" "$journal" || return 3
    [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
    _attachment_finalize_pending "$journal" "$artifact"
    return $?
  fi

  if [ -e "$destination" ] || [ -L "$destination" ]; then
    _attachment_pending_destination_owned "$root" "$pending" "$journal" || return 3
    _attachment_remove_pending_stage "$root" "$pending" "$journal" || return $?
    [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
    _attachment_finalize_pending "$journal" "$artifact"
    return $?
  fi

  if [ -e "$stage" ] || [ -L "$stage" ]; then
    _attachment_pending_stage_owned "$root" "$pending" "$journal" || return 3
    if [ "$kind" = file ]; then
      _attachment_stage_exact "$stage" "$artifact" || return 3
    else
      target=$(printf '%s\n' "$artifact" | jq -r '.target') || return 2
      _attachment_symlink_matches "$stage" "$target" || return 3
    fi
  else
    if [ "$kind" = file ]; then
      _attachment_create_file_stage "$journal" "$artifact" "$stage" || return $?
    else
      _attachment_create_symlink_stage "$journal" "$artifact" "$stage" || return $?
    fi
    pending=$(jq -c '.pending' "$journal") || return 2
  fi

  _attachment_publish_stage_link "$pending" "$artifact" "$stage" "$destination" || return $?
  _attachment_pending_destination_owned "$root" "$pending" "$journal" || return 3
  _attachment_remove_pending_stage "$root" "$pending" "$journal" || return $?
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  _attachment_finalize_pending "$journal" "$artifact"
}

_attachment_remove_artifact_exact_or_absent() {
  local root=$1 artifact=$2 journal=$3 relative destination
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
  _attachment_parent_safe "$root" "$relative" || return 3
  destination=$(_attachment_destination "$root" "$relative")
  _attachment_remove_pinned "$journal" "$destination" "$artifact" "" 0 1
}

_attachment_rollback_locked() {
  local journal=$1 root pending artifact stage_rc=0 destination_rc=0 conflict=0
  root=$(jq -r '.worktree_root' "$journal") || return 2
  pending=$(jq -c '.pending' "$journal") || return 2
  if [ "$pending" != null ]; then
    _attachment_pending_stage_owned "$root" "$pending" "$journal" || stage_rc=$?
    artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
    if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      _attachment_artifact_exact "$root" "$artifact" || _attachment_replace_before_matches "$root/$(printf '%s\n' "$artifact" | jq -r '.path')" "$artifact" || destination_rc=3
    else
      _attachment_pending_destination_owned "$root" "$pending" "$journal" || destination_rc=$?
    fi
    [ "$stage_rc" -eq 0 ] || conflict=3
    [ "$destination_rc" -eq 0 ] || conflict=3
  fi
  while IFS= read -r artifact; do
    if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      _attachment_artifact_exact "$root" "$artifact" || _attachment_replace_before_matches "$root/$(printf '%s\n' "$artifact" | jq -r '.path')" "$artifact" || return 3
    else
      _attachment_artifact_absent_or_exact "$root" "$artifact" "$journal" || return 3
    fi
  done < <(jq -c '.applied | reverse[]' "$journal")

  if [ "$pending" != null ]; then
    # A kill between journaling the stage's removal and claiming it leaves
    # that removal active, and the destination's removal refuses any other
    # active claim. Finish the journaled one first.
    if [ "$stage_rc" -eq 0 ] &&
      [ "$(trellis_jq -r --argjson pending "$pending" '.removal != null and .removal.path == $pending.staging_path' "$journal")" = true ]; then
      _attachment_remove_pending_stage "$root" "$pending" "$journal" || return $?
    fi
    [ "$destination_rc" -ne 0 ] || _attachment_remove_pending_destination "$root" "$pending" "$journal" || return $?
    [ "$stage_rc" -ne 0 ] || _attachment_remove_pending_stage "$root" "$pending" "$journal" || return $?
  fi
  while IFS= read -r artifact; do
    if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      _attachment_restore_replaced_file "$root" "$artifact" || return $?
    else
      _attachment_remove_artifact_exact_or_absent "$root" "$artifact" "$journal" || return $?
    fi
  done < <(jq -c '.applied | reverse[]' "$journal")
  [ "$conflict" -eq 0 ] || return "$conflict"
  rm "$journal" || return 1
  return 0
}

_attachment_signal_exit() {
  trap - HUP INT TERM
  exit "${TRELLIS_EX_UNAVAILABLE:-5}"
}

_attachment_install_lock_traps() {
  trap '_attachment_lock_release >/dev/null 2>&1' EXIT
  trap '_attachment_signal_exit' HUP
  trap '_attachment_signal_exit' INT
  trap '_attachment_signal_exit' TERM
}

_attachment_install_checkout_lock_traps() {
  trap '_attachment_checkout_lock_release >/dev/null 2>&1' EXIT
  trap '_attachment_signal_exit' HUP
  trap '_attachment_signal_exit' INT
  trap '_attachment_signal_exit' TERM
}

# Journal v2: the commit marks the journal once (`journal_version: 2`) and
# appends each per-artifact transition to a progress log instead of rewriting
# the journal. Folding replays that log onto the journal's v1 fields, writes the
# v1 shape back and drops the log, so rollback and recovery keep reading the v1
# journal they always have. Releases without v2 refuse a marked journal as an
# unknown shape instead of rolling back a prefix they cannot see. The log is
# replayed only on top of a clean begin record, every event must follow from
# the state before it, and a torn final line (a kill mid-append) is the step
# before it.
_attachment_progress_path() {
  printf '%s/state/attachment-progress/%s.log\n' "$1" "$2"
}

_attachment_progress_fold_filter='
  def exact($allowed): (keys | sort) == ($allowed | sort);
  def ident: type == "string" and test("^[0-9]+:[0-9]+$");
  ($log | split("\n") | .[0:-1] | map(fromjson)) as $events
  | if ($events | length) == 0 then .
    elif ($events[0] | exact(["attachment_id","e","phase","v"]) and .e == "begin" and .v == 2)
      and $events[0].attachment_id == .attachment_id and $events[0].phase == .phase
      and .pending == null and .removal == null
    then reduce $events[1:][] as $event (.;
      if $event.e == "pending" and ($event | exact(["e","index","parent_identity","staging_path"]))
        and .pending == null and .removal == null and $event.index == .phase and .phase < (.artifacts | length)
        and ($event.staging_path | type == "string") and ($event.parent_identity | ident)
      then .pending = {artifact: .artifacts[.phase], staging_path: $event.staging_path, staging_identity: null,
        destination_identity: null, parent_identity: $event.parent_identity}
      elif ($event.e == "staging_identity" or $event.e == "destination_identity")
        and ($event | exact(["e","identity"])) and ($event.identity | ident)
        and .pending != null and .pending[$event.e] == null
      then .pending[$event.e] = $event.identity
      elif $event.e == "removal" and ($event | exact(["e","nonce","path"])) and .removal == null
        and ($event.path | type == "string") and ($event.nonce | type == "string" and test("^[a-f0-9]{64}$"))
      then .removal = {path: $event.path, nonce: $event.nonce}
      elif $event.e == "removal_clear" and ($event | exact(["e"])) and .removal != null
      then .removal = null
      elif $event.e == "applied" and ($event | exact(["e","index"])) and .pending != null and .removal == null
        and $event.index == .phase
      then .applied += [.artifacts[.phase]] | .phase += 1 | .pending = null
      else error("invalid attachment progress event") end)
    else error("invalid attachment progress header") end
  | del(.journal_version)'

_attachment_fold_progress_log() {
  local home=$1 journal=$2 log version next tmp status
  log=$(_attachment_progress_path "$home" "$(jq -r '.attachment_id' "$journal")") || return 2
  version=$(jq -r '.journal_version // 1' "$journal") || return 2
  if [ -e "$log" ] || [ -L "$log" ]; then
    _attachment_canonical_dir "$(dirname "$log")" && [ -f "$log" ] && [ ! -L "$log" ] &&
      [ "$(_attachment_mode "$log")" = 600 ] || return 3
  fi
  if [ "$version" = 2 ]; then
    [ ! -L "$journal" ] || return 3
    if [ -f "$log" ]; then
      next=$(jq -cS --rawfile log "$log" "$_attachment_progress_fold_filter" "$journal") || return 2
    else
      next=$(jq -cS 'del(.journal_version)' "$journal") || return 2
    fi
    tmp=$(mktemp "$journal.tmp.XXXXXX") || return 1
    { chmod 600 "$tmp" && printf '%s\n' "$next" > "$tmp"; } || { rm -f "$tmp"; return 1; }
    _attachment_journal_json_valid "$tmp" || { status=$?; rm -f "$tmp"; return "$status"; }
    mv -f "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
  fi
  # The fold writes the journal before it drops the log, so a log beside an
  # unmarked journal has already been replayed into it. Drop the directory
  # when it is empty so a rolled-back attach leaves no mark behind; a
  # concurrent commit keeps it alive by holding its own log.
  [ ! -f "$log" ] || rm "$log" || return 1
  rmdir "$(dirname "$log")" 2>/dev/null || true
}

# The commit's publisher: every remaining artifact in one process, through the
# same pinned stage, identity and claim steps as _attachment_publish_pending,
# with each transition appended to the progress log.
# The absolute path of attachment_fs.py in this payload: the verified payload
# when the libraries are preloaded, else beside this library. Refuses a path
# that could not be embedded literally in a Python raw string.
_attachment_fs_module() {
  local path
  if [ "${TRELLIS_LIBS_PRELOADED:-}" = 1 ]; then
    path="${TRELLIS_VERIFIED_PAYLOAD:-}/scripts/lib/attachment_fs.py"
  else
    path="${_ATTACHMENT_DIR:-}/attachment_fs.py"
  fi
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *"'"*|*\\*|*[[:cntrl:]]*) return 1 ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
  printf '%s\n' "$path"
}

_attachment_commit_program() {
  local fs
  fs=$(_attachment_fs_module) || return 1
  printf "ATTACHMENT_FS = r'%s'\n" "$fs"
  cat <<'PY'
import importlib.util
import os
import signal
import sys


def _load_attachment_fs(path):
    # The shared primitives, by absolute payload path, never from sys.path.
    spec = importlib.util.spec_from_file_location("trellis_attachment_fs", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return {name: value for name, value in vars(module).items() if not name.startswith("__")}


globals().update(_load_attachment_fs(ATTACHMENT_FS))


def checkpoint(label):
    # Called after every durable step. The crash suites substitute this one
    # line in a copy of the program; nothing in the product activates it.
    return None  # crash-test seam


class Commit(object):
    def __init__(self, journal_path, log_path, fault, owner_pid):
        self.journal_path = journal_path
        self.log_path = log_path
        self.fault = fault
        self.owner_pid = owner_pid
        with open(journal_path, "rb") as handle:
            self.journal = json.loads(handle.read().decode("utf-8"))
        self.root = self.journal["worktree_root"]
        self.attachment = self.journal["attachment_id"]
        self.artifacts = self.journal["artifacts"]
        self.removal = None
        self.log = None

    def guard(self):
        # The transaction lock belongs to the shell recorded as its owner, not
        # to whichever process adopts us after it dies. Called before every
        # write; the flock keeps recovery out for the one write in flight.
        if os.getppid() != self.owner_pid:
            orphaned()

    def step(self, label):
        self.guard()
        checkpoint(label)

    def emit(self, record):
        self.guard()
        data = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        if os.write(self.log, data) != len(data):
            raise OSError("short progress write")
        checkpoint(record["e"])

    def validate_sources(self):
        for artifact in self.artifacts:
            if artifact["kind"] != "file":
                continue
            if "source" in artifact:
                source = artifact["source"]
                if not canonical_file(source) or sha256_file(source) != artifact["sha256"]:
                    refuse(3)
            elif not isinstance(artifact.get("content_base64"), str):
                refuse(3)

    def mark_journal(self):
        # Journal v2: the marker makes releases that cannot replay the log
        # refuse this journal instead of rolling back an empty prefix.
        directory = os.path.dirname(self.journal_path)
        if not canonical_dir(directory) or not is_file(self.journal_path):
            refuse(3)
        marked = dict(self.journal)
        marked["journal_version"] = 2
        temporary = self.journal_path + ".tmp." + random_suffix()
        self.guard()
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            self.guard()
            os.fchmod(fd, 0o600)
            data = (json.dumps(marked, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
            self.guard()
            if os.write(fd, data) != len(data):
                raise OSError("short journal write")
        finally:
            os.close(fd)
        self.guard()
        os.rename(temporary, self.journal_path)
        self.step("journal-marked")
        self.guard()
        self.log = os.open(self.log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        self.guard()
        os.fchmod(self.log, 0o600)
        self.emit({"e": "begin", "v": 2, "attachment_id": self.attachment, "phase": self.journal["phase"]})

    def run(self):
        if self.journal.get("pending") is not None or self.journal.get("removal") is not None:
            refuse(2)
        phase = self.journal["phase"]
        self.validate_sources()
        self.mark_journal()
        for index in range(phase, len(self.artifacts)):
            self.publish(index, self.artifacts[index])
            if self.fault == str(index + 1):
                raise Stop(FAULT)

    def reclaim_unidentified_stage(self, stage, parent_identity, kind):
        if not canonical_dir(os.path.dirname(stage)) or identity(".") != parent_identity:
            refuse(3)
        base = "./" + os.path.basename(stage)
        if not exists(base):
            return
        if kind in ("file", "symlink"):
            if not (is_link(base) or is_file(base)):
                refuse(3)
            self.guard()
            os.unlink(base)
        else:
            if not is_dir(base):
                refuse(3)
            try:
                self.guard()
                os.rmdir(base)
            except OSError:
                refuse(3)
        self.step("stage-reclaimed")

    def destination_owned(self, destination, artifact, owned_identity):
        if not parent_safe(self.root, artifact["path"]) or not claim_namespace_valid(destination, self.removal):
            return False
        if not exists(destination):
            return True
        if not identity_matches(destination, owned_identity, artifact["kind"]):
            return False
        parent, base = os.path.split(destination)
        return canonical_dir(parent) and path_exact_pinned(base, artifact)

    def publish(self, index, artifact):
        relative = artifact["path"]
        kind = artifact["kind"]
        if not parent_safe(self.root, relative):
            refuse(3)
        destination = self.root + "/" + relative
        parent, base = os.path.split(destination)
        if not canonical_dir(parent):
            refuse(3)
        parent_identity = identity(".")
        if not parent_identity:
            refuse(1)
        stage = "%s/.%s.attachment-stage-%s.%s" % (parent, base, self.attachment, random_suffix())
        self.emit({"e": "pending", "index": index, "staging_path": stage, "parent_identity": parent_identity})
        if not parent_safe(self.root, relative):
            refuse(3)
        if identity(parent) != parent_identity:
            refuse(3)
        if exists(stage):
            self.reclaim_unidentified_stage(stage, parent_identity, kind)
        if kind in ("directory", "parent"):
            if exists(destination):
                refuse(3)
            staged = self.create_directory_stage(parent, stage, parent_identity)
            self.publish_directory_stage(parent, stage, destination, parent_identity, staged, kind)
            self.emit({"e": "destination_identity", "identity": staged})
            if not self.destination_owned(destination, artifact, staged):
                refuse(3)
        elif "replace" in artifact:
            if not exists(destination) or not replace_before_matches(destination, artifact):
                refuse(3)
            staged = self.create_leaf_stage(parent, stage, artifact, parent_identity)
            self.publish_stage_replace(parent, stage, destination, artifact, parent_identity, staged)
            if not self.destination_owned(destination, artifact, staged):
                refuse(3)
        else:
            if exists(destination):
                refuse(3)
            staged = self.create_leaf_stage(parent, stage, artifact, parent_identity)
            self.publish_stage_link(parent, stage, destination, artifact, parent_identity, staged)
            if not self.destination_owned(destination, artifact, staged):
                refuse(3)
            self.remove_stage(parent, stage, artifact, parent_identity, staged)
        if identity(parent) != parent_identity:
            refuse(3)
        self.emit({"e": "applied", "index": index})

    def pin(self, parent, parent_identity):
        if not canonical_dir(parent) or identity(".") != parent_identity:
            refuse(3)

    def create_directory_stage(self, parent, stage, parent_identity):
        self.pin(parent, parent_identity)
        name = "./" + os.path.basename(stage)
        try:
            self.guard()
            os.mkdir(name, 0o700)
        except OSError:
            refuse(3)
        self.step("stage-created")
        fd = open_fresh_dir(name)
        try:
            self.guard()
            os.fchmod(fd, 0o700)
            staged = fd_identity(fd)
        finally:
            os.close(fd)
        if identity(name) != staged:
            refuse(3)
        self.emit({"e": "staging_identity", "identity": staged})
        if identity(".") != parent_identity:
            refuse(3)
        return staged

    def publish_directory_stage(self, parent, stage, destination, parent_identity, staged, kind):
        self.pin(parent, parent_identity)
        stage_name = "./" + os.path.basename(stage)
        destination_name = "./" + os.path.basename(destination)
        if exists(stage_name):
            if not identity_matches(stage_name, staged, kind) or exists(destination_name):
                refuse(3)
            self.guard()
            rename_exclusive(stage_name, destination_name)
            self.step("published")
        if not identity_matches(destination_name, staged, kind) or identity(".") != parent_identity:
            refuse(3)

    def create_leaf_stage(self, parent, stage, artifact, parent_identity):
        self.pin(parent, parent_identity)
        name = "./" + os.path.basename(stage)
        if artifact["kind"] == "symlink":
            try:
                self.guard()
                os.symlink(artifact["target"], name)
            except OSError:
                refuse(3)
            self.step("stage-created")
            staged = identity(name)
            if not staged:
                refuse(1)
            self.emit({"e": "staging_identity", "identity": staged})
            if identity(".") != parent_identity:
                refuse(3)
            return staged
        try:
            self.guard()
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except OSError:
            refuse(3)
        try:
            self.step("stage-created")
            staged = identity(name)
            if not staged:
                refuse(1)
            self.emit({"e": "staging_identity", "identity": staged})
            self.guard()
            os.fchmod(fd, int(artifact.get("mode", "0600"), 8))
            if "source" in artifact:
                with open(artifact["source"], "rb") as handle:
                    content = handle.read()
            else:
                content = base64.b64decode(artifact["content_base64"])
            view = memoryview(content)
            while view:
                self.guard()
                written = os.write(fd, view)
                view = view[written:]
        finally:
            os.close(fd)
        self.step("stage-written")
        if not identity_matches(name, staged, "file") or sha256_file(name) != artifact["sha256"]:
            refuse(3)
        if "mode" in artifact and not mode_matches(name, artifact["mode"]):
            refuse(3)
        if identity(".") != parent_identity:
            refuse(3)
        return staged

    def publish_stage_link(self, parent, stage, destination, artifact, parent_identity, staged):
        self.pin(parent, parent_identity)
        kind = artifact["kind"]
        stage_name = os.path.basename(stage)
        destination_name = os.path.basename(destination)
        if not identity_matches("./" + stage_name, staged, kind) or not path_exact_pinned(stage_name, artifact):
            refuse(3)
        if exists("./" + destination_name):
            refuse(3)
        try:
            self.guard()
            os.link("./" + stage_name, "./" + destination_name, follow_symlinks=False)
        except OSError as error:
            if not link_unsupported(error):
                refuse(3)
            try:
                rename_exclusive("./" + stage_name, "./" + destination_name)
            except OSError:
                refuse(3)
        self.step("published")
        if not identity_matches("./" + destination_name, staged, kind) or not path_exact_pinned(destination_name, artifact):
            refuse(3)
        if identity(".") != parent_identity:
            refuse(3)

    def publish_stage_replace(self, parent, stage, destination, artifact, parent_identity, staged):
        self.pin(parent, parent_identity)
        stage_name = os.path.basename(stage)
        destination_name = os.path.basename(destination)
        if not identity_matches("./" + stage_name, staged, "file") or not path_exact_pinned(stage_name, artifact):
            refuse(3)
        if not replace_before_matches("./" + destination_name, artifact):
            refuse(3)
        self.guard()
        os.rename("./" + stage_name, "./" + destination_name)
        self.step("published")
        if not identity_matches("./" + destination_name, staged, "file") or not path_exact_pinned(destination_name, artifact):
            refuse(3)
        if identity(".") != parent_identity:
            refuse(3)

    def remove_stage(self, parent, stage, artifact, parent_identity, staged):
        # The shell's pinned removal: journal the claim, move the stage into a
        # fresh quarantine, check its identity, then delete it.
        kind = artifact["kind"]
        if identity(parent) != parent_identity or not claim_namespace_valid(stage, None):
            refuse(3)
        if exists(stage) and not identity_matches(stage, staged, kind):
            refuse(3)
        if not canonical_dir(parent):
            refuse(3)
        nonce = hashlib.sha256(os.urandom(32)).hexdigest()
        self.emit({"e": "removal", "path": stage, "nonce": nonce})
        self.removal = {"path": stage, "nonce": nonce}
        quarantine = claim_layout(stage, nonce)
        if exists(quarantine) or not claim_namespace_valid(stage, self.removal):
            refuse(3)
        if not canonical_dir(parent):
            refuse(3)
        stage_name = "./" + os.path.basename(stage)
        quarantine_name = "./" + os.path.basename(quarantine)
        if exists(stage_name):
            try:
                self.guard()
                os.mkdir(quarantine_name, 0o700)
            except OSError:
                refuse(3)
            self.step("quarantine-created")
            # The claim goes through the pinned quarantine, never its name.
            fd = open_fresh_dir(quarantine_name)
            try:
                pinned = fd_identity(fd)
                self.guard()
                os.fchmod(fd, 0o700)
                if identity(quarantine_name) != pinned:
                    refuse(3)
                try:
                    self.guard()
                    os.rename(stage_name, "artifact", dst_dir_fd=fd)
                except OSError:
                    refuse(3)
                self.step("stage-claimed")
                if identity(quarantine_name) != pinned:
                    refuse(3)
                if not identity_matches("artifact", staged, kind, dir_fd=fd):
                    if not exists(stage_name):
                        self.guard()
                        os.rename("artifact", stage_name, src_dir_fd=fd)
                        self.guard()
                        os.rmdir(quarantine_name)
                    refuse(3)
                self.guard()
                os.unlink("artifact", dir_fd=fd)
                self.step("claim-removed")
            finally:
                os.close(fd)
            self.guard()
            os.rmdir(quarantine_name)
            self.step("quarantine-removed")
        self.emit({"e": "removal_clear"})
        self.removal = None


def random_suffix():
    alphabet = string.ascii_letters + string.digits
    generator = random.SystemRandom()
    return "".join(generator.choice(alphabet) for _ in range(6))


def main(argv):
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    journal_path, log_path, fault, holder, owner_pid = argv
    try:
        hold_transaction_lock(holder, int(owner_pid))
        Commit(journal_path, log_path, fault, int(owner_pid)).run()
    except Stop as stop:
        return stop.status
    except OSError as error:
        sys.stderr.write("trellis attachment: commit stopped: %s\n" % error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
}

_attachment_commit_batch() {
  local home=$1 journal=$2 python_bin program attachment holder=${_ATTACHMENT_LOCK_HOLDER:-} owner_pid
  python_bin=$(command -v python3) || return 1
  case "$python_bin" in /*) ;; *) return 1 ;; esac
  program=$(_attachment_commit_program) || return 1
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  [ -n "$holder" ] || return 1
  owner_pid=$(jq -r '.pid' "$holder/owner.json") || return 1
  _attachment_ensure_private_dir "$home/state/attachment-progress" || return 1
  # -B: the program loads attachment_fs.py by path; never cache its bytecode
  # beside the source (a writable checkout must stay unchanged).
  LC_ALL=C "$python_bin" -I -B -c "$program" \
    "$journal" "$(_attachment_progress_path "$home" "$attachment")" "${ATTACHMENT_FAULT_PHASE:-}" \
    "$holder" "$owner_pid"
}

_attachment_commit_impl() (
  local home=$1 journal=$2 plan checkout worktree attachment owner phase owner_json rc rollback_rc removal
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_validate_journal_binding "$home" "$journal" || return $?
  plan=$(_attachment_plan_from_journal "$journal") || return 2
  checkout=$(jq -r '.checkout_id' "$journal") || return 2
  worktree=$(jq -r '.worktree_id' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" || return $?
  _attachment_install_lock_traps
  if [ -n "${ATTACHMENT_TEST_HOLD_LOCK:-}" ]; then
    sleep "$ATTACHMENT_TEST_HOLD_LOCK"
  fi
  _attachment_fold_progress_log "$home" "$journal" || return $?
  _attachment_upgrade_legacy_journal_pending "$home" "$journal" || return $?
  _attachment_validate_journal_binding "$home" "$journal" || return $?
  owner=$(_attachment_ownership_path "$home" "$checkout" "$worktree")
  removal=$(jq -c '.removal' "$journal") || return 2
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    _attachment_owner_matches_plan "$owner" "$plan" || return $?
    [ "$removal" = null ] || return 3
    [ "$(jq -r '.phase' "$journal")" -eq "$(jq '.artifacts | length' "$journal")" ] || return 3
    [ "$(jq -r '.pending == null' "$journal")" = true ] || return 3
    rm "$journal" || return 1
    return 0
  fi
  if [ "$removal" != null ]; then
    _attachment_rollback_locked "$journal" || return $?
    return 5
  fi
  # A pending artifact from an interrupted commit finishes on the shell path.
  if [ "$(jq -r '.pending == null' "$journal")" = false ]; then
    _attachment_validate_sources "$plan" 3 || return $?
    _attachment_publish_pending "$journal" "$plan"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      rollback_rc=0
      _attachment_rollback_locked "$journal" || rollback_rc=$?
      [ "$rollback_rc" -eq 0 ] || return "$rollback_rc"
      return "$rc"
    fi
    phase=$(jq -r '.phase' "$journal") || return 2
    if [ "${ATTACHMENT_FAULT_PHASE:-}" = "$phase" ]; then
      _attachment_rollback_locked "$journal" || return $?
      return 5
    fi
  fi

  _attachment_commit_batch "$home" "$journal"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # An unmarked journal means the publisher stopped before its first write,
    # as the shell loop stopped on a changed source: nothing to roll back.
    [ "$(jq -r '.journal_version // 1' "$journal")" = 2 ] || return "$rc"
    _attachment_fold_progress_log "$home" "$journal" || return $?
    rollback_rc=0
    _attachment_rollback_locked "$journal" || rollback_rc=$?
    [ "$rollback_rc" -eq 0 ] || return "$rollback_rc"
    [ "$rc" -ne 75 ] || return 5
    return "$rc"
  fi
  _attachment_fold_progress_log "$home" "$journal" || return $?

  [ "$(jq -r '.removal == null and .pending == null and .phase == (.artifacts | length)' "$journal")" = true ] || return 3
  owner_json=$(_attachment_owner_from_plan "$plan") || return 1
  if ! _attachment_write_json "$owner" "$owner_json"; then
    _attachment_rollback_locked "$journal" || return $?
    return 1
  fi
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = owner-published ]; then
    return 5
  fi
  rm "$journal" || return 1
  return 0
)

_attachment_rollback_impl() (
  local home=$1 journal=$2 checkout worktree attachment rc
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_validate_journal_binding "$home" "$journal" || return $?
  checkout=$(jq -r '.checkout_id' "$journal") || return 2
  worktree=$(jq -r '.worktree_id' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" || return $?
  _attachment_install_lock_traps
  _attachment_fold_progress_log "$home" "$journal" || return $?
  _attachment_upgrade_legacy_journal_pending "$home" "$journal" || return $?
  _attachment_validate_journal_binding "$home" "$journal" || return $?
  _attachment_rollback_locked "$journal"
)

_attachment_recover_impl() (
  local home=$1 journal=$2 checkout worktree attachment plan owner phase total pending
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_validate_journal_binding "$home" "$journal" || return $?
  checkout=$(jq -r '.checkout_id' "$journal") || return 2
  worktree=$(jq -r '.worktree_id' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  _attachment_lock_reclaim "$home" "$checkout" "$worktree" "$attachment" || return $?
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" || return $?
  _attachment_install_lock_traps
  _attachment_fold_progress_log "$home" "$journal" || return $?
  _attachment_upgrade_legacy_journal_pending "$home" "$journal" || return $?
  _attachment_validate_journal_binding "$home" "$journal" || return $?
  plan=$(_attachment_plan_from_journal "$journal") || return 2
  owner=$(_attachment_ownership_path "$home" "$checkout" "$worktree")
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    _attachment_owner_matches_plan "$owner" "$plan" || return $?
    phase=$(jq -r '.phase' "$journal") || return 2
    total=$(jq '.artifacts | length' "$journal") || return 2
    pending=$(jq -r '.pending == null' "$journal") || return 2
    [ "$phase" -eq "$total" ] && [ "$pending" = true ] &&
      [ "$(jq -r '.removal == null' "$journal")" = true ] || return 3
    rm "$journal" || return 1
    return 0
  fi
  _attachment_rollback_locked "$journal"
)

_attachment_verify_owner_artifacts_impl() {
  local home=$1 owner=$2 leaves="${3:-all}" checkout worktree canonical
  [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_owner_json_valid "$owner" || return $?
  checkout=$(jq -r '.checkout_id' "$owner") || return 2
  worktree=$(jq -r '.worktree_id' "$owner") || return 2
  canonical=$(_attachment_ownership_path "$home" "$checkout" "$worktree")
  [ "$owner" = "$canonical" ] || return 2
  _attachment_verify_owner_artifacts "$owner" "$home" "$leaves"
}

# attachment_verify_donor HOME OWNER: attachment_verify bound to the owner
# bytes it judged. Prints their sha256 on success; a change during the verify
# is a failure. The caller records the proof (pid, owner, digest, release) for
# the donor fast path, which honours it only for the same bytes and release.
attachment_verify_donor() {
  local before after
  before=$(_attachment_hash "$2") || return 3
  attachment_verify "$1" "$2" || return $?
  after=$(_attachment_hash "$2") || return 3
  [ "$before" = "$after" ] || return 3
  printf '%s\n' "$after"
}

_attachment_verify_impl() {
  _attachment_verify_owner_artifacts_impl "$@" || return $?
  _attachment_verify_managed_hooks "$1" "$2"
}

_attachment_verify_adoption_impl() {
  _attachment_verify_owner_artifacts_impl "$@" || return $?
  _attachment_verify_adoption_hooks "$1" "$2"
}

_attachment_verify_detach_impl() {
  local home=$1 owner=$2 checkout worktree canonical status
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_owner_json_valid "$owner" || {
    status=$?
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-record-invalid "$owner"
    return "$status"
  }
  checkout=$(jq -r '.checkout_id' "$owner") && worktree=$(jq -r '.worktree_id' "$owner") || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-record-invalid "$owner"
    return 2
  }
  canonical=$(_attachment_ownership_path "$home" "$checkout" "$worktree")
  [ "$owner" = "$canonical" ] || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-path-mislocated "$owner"
    return 2
  }
  _attachment_verify_detach_owner_artifacts "$owner"
}

_attachment_detach_owner_data_valid() {
  local data=$1 tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/trellis.detach.owner.XXXXXX") || return 1
  # RETURN traps outlive the function unless disarmed. Clear it while this
  # frame still owns tmp, before a caller can return with its own local tmp.
  trap 'trap - RETURN; rm -f "$tmp"' RETURN
  printf '%s\n' "$data" > "$tmp" || return 1
  chmod 600 "$tmp" || return 1
  _attachment_owner_json_valid "$tmp"
  rc=$?
  rm -f "$tmp"
  trap - RETURN
  return "$rc"
}

# Record shape and canonical control-plane paths, without requiring a live root.
# The detach journal's schema and its cross-field invariants (`$original` and
# `$next` are the journal's owner records), shared by the shell validator and
# the native detach program, which runs the same jq filters.
_attachment_detach_journal_schema_filter='
    def exact($allowed): (keys_unsorted | sort) == ($allowed | sort);
    def controls: test("[[:cntrl:]]");
    def abs: type == "string" and startswith("/") and . != "/" and (endswith("/") | not)
      and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
    def rel: type == "string" and length > 0 and (startswith("/") | not) and (endswith("/") | not)
      and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
    def sha: type == "string" and test("^[a-f0-9]{64}$");
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def mode: type == "string" and test("^0[0-7]{3}$");
    def identity: type == "string" and test("^[0-9]+:[0-9]+$");
    def b64: type == "string" and test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");
    def json_path: type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (controls | not));
    def rendered:
      type == "object" and exact(["after_base64","after_mode","after_sha256","before_base64","before_exists","before_mode","before_sha256","created_paths","merge","mode","owned_keys","path"])
      and (.path | rel) and .merge == "explicit-json" and (.mode | mode) and (.after_mode | mode)
      and (.before_exists | type == "boolean") and (.before_mode == null or (.before_mode | mode))
      and (.before_sha256 | sha) and (.before_base64 | b64) and (.after_sha256 | sha) and (.after_base64 | b64)
      and (.owned_keys | type == "array" and all(.[]; type == "object" and exact(["path","value"]) and (.path | json_path)))
      and (.created_paths | type == "array" and all(.[]; json_path));
    def removal:
      type == "object" and exact(["nonce","path"]) and (.nonce | sha) and (.path | abs);
    def render_pending:
      type == "object"
      and exact(["parent_identity","render","result_base64","result_exists","result_mode","result_sha256","source_identity","source_mode","source_sha256","staging_identity","staging_path"])
      and ((has("parent_identity") | not) or (.parent_identity | identity))
      and (.render | rendered)
      and (.source_identity | identity) and (.source_sha256 | sha) and (.source_mode | mode)
      and (.result_exists | type == "boolean") and (.result_base64 | b64) and (.result_sha256 | sha)
      and (.result_mode == null or (.result_mode | mode))
      and (.staging_path == null or (.staging_path | abs))
      and (.staging_identity == null or (.staging_identity | identity))
      and (if .result_exists
           then (.result_mode | mode) and (.staging_path | abs)
           else .result_base64 == "" and .result_sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
             and .result_mode == null and .staging_path == null and .staging_identity == null
           end);
    def transfer:
      type == "object" and exact(["after","expected","owner_path"])
      and (.owner_path | abs) and (.expected | type == "object") and (.after | type == "object");
    def checkout:
      type == "object" and exact(["root","git_common_dir","release","harnesses","worktrees"])
      and (.root | abs) and (.git_common_dir | abs)
      and (.release | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$"))
      and (.harnesses | type == "array" and length > 0
        and all(.[]; . == "claude" or . == "codex" or . == "pi") and (unique | length) == length)
      and (.worktrees | type == "object" and all(keys[]; sha)
        and all(.[]; type == "object"
          and (exact(["root"]) or exact(["root","attachment_id"]))
          and (.root | abs) and (if has("attachment_id") then (.attachment_id | uuid) else true end)));
    def registry_update:
      type == "object" and exact(["expected","after"])
      and (.expected | checkout) and (.after | checkout)
      and (.expected | del(.harnesses)) == (.after | del(.harnesses))
      and (.after.harnesses - .expected.harnesses | length) == 0
      and (.expected.harnesses - .after.harnesses | length) > 0;
    def external:
      type == "object"
      and ((del(.registry_update)) | exact(["clear_registry","exclude_action","phase","render_pending","render_phase","renders","restore_hooks","transfer"]))
      and (if has("registry_update") then (.registry_update == null or (.registry_update | registry_update)) else true end)
      and (.phase | type == "number" and floor == . and . >= 0 and . <= 5)
      and (.transfer == null or (.transfer | transfer))
      and (.renders | type == "array" and all(.[]; rendered) and ((map(.path) | unique | length) == length))
      and ((.exclude_action == "none") or (.exclude_action == "transfer") or (.exclude_action == "restore"))
      and (.restore_hooks | type == "boolean") and (.clear_registry | type == "boolean")
      and (.render_phase | type == "number" and floor == . and . >= 0)
      and (.render_pending == null or (.render_pending | render_pending));
    . as $journal
    | type == "object"
    and exact(["attachment_id","checkout_id","external","next_owner","original_owner","owner_committed","phase","removal","remove","schema_version","status","worktree_id"])
    and .schema_version == 1 and .status == "detaching"
    and (if has("surface") then .surface == "project" else true end)
    and (.attachment_id | uuid) and (.checkout_id | sha) and (.worktree_id | sha)
    and (.remove | type == "array")
    and (.phase | type == "number" and floor == . and . >= 0 and . <= ($journal.remove | length))
    and (.owner_committed | type == "boolean")
    and (.removal == null or (.removal | removal))
    and (.external | external)
    and (.next_owner == null or (.next_owner | type == "object"))
    and (.original_owner | type == "object")
    and (if .external.render_pending == null then true else .external.phase == 1 end)
    and (if .external.phase >= 2 then .external.render_pending == null and .removal == null else true end)
'

_attachment_detach_journal_invariants_filter='
    def paths_unique($items): ($items | map(.path) | unique | length) == ($items | length);
    def no_path_overlap($left; $right):
      all($left[]; .path as $path | any($right[]; .path == $path) | not);
    def ordered_subset($items; $all):
      reduce $items[] as $item
        ({cursor:0,ok:true};
          . as $state
          | if $state.ok then
              ([range($state.cursor; ($all | length)) | select($all[.] == $item)] | .[0]) as $found
              | if $found == null then .ok = false else .cursor = ($found + 1) end
            else . end)
      | .ok;
    def harness($path):
      if ($path | startswith(".codex/")) then "codex"
      elif ($path | startswith(".pi/")) then "pi"
      elif ($path | startswith(".claude/")) then "claude"
      elif $path == "AGENTS.md" or ($path | startswith(".agents/")) then "shared_agents"
      else null end;
    def harnesses($owner):
      ($owner.artifacts + ($owner.pre_existing // [])) as $owned
      | (any($owned[]; .path | startswith(".pi/"))) as $has_pi
      | [$owned[] | harness(.path)
         | if . == "shared_agents" then (if $has_pi then empty else "codex" end)
           elif . == null then empty else . end] | unique | sort;
    def keep($path; $remaining):
      harness($path) as $h
      | ($h != null and ($remaining | index($h)) != null)
        or ($h == "shared_agents" and any($remaining[]; . == "codex" or . == "pi"));
    . as $journal
    | .external as $external
    | ($external.registry_update // null) as $update
    | (if $next == null then [] else harnesses($next) end) as $remaining
    | (if $next == null then [] else $next.artifacts end) as $next_artifacts
    | (if $next == null then [] else ($next.renders // []) end) as $next_renders
    | ($external.renders | map(.path)) as $render_paths
    | ($original.artifacts | map(.path) | unique | length == ($original.artifacts | length))
    and paths_unique($next_artifacts)
    and paths_unique($journal.remove)
    and ($journal.attachment_id == $original.attachment_id)
    and ($journal.checkout_id == $original.checkout_id)
    and ($journal.worktree_id == $original.worktree_id)
    and (if $next == null then true
         else ($next | del(.artifacts,.render_context,.renders,.pre_existing)) == ($original | del(.artifacts,.render_context,.renders,.pre_existing))
           and ($next | has("pre_existing")) == ($original | has("pre_existing"))
           and ($next.pre_existing // []) == [($original.pre_existing // [])[] | select(keep(.path; $remaining))]
           and [$next_artifacts[] | select(.kind != "parent")]
             == [$original.artifacts[] | select(.kind != "parent")
                 | select(.path == ".trellis/runtime" or keep(.path; $remaining))]
           and $next_renders == [($original.renders // [])[] | select(keep(.path; $remaining))]
           and (if any($next_renders[]; .path == ".claude/settings.local.json" or .path == ".codex/hooks.json")
                then $next.render_context == $original.render_context
                else ($next.render_context // null) == null
                end)
           and ordered_subset($next_artifacts; $original.artifacts)
           and ordered_subset($next_renders; ($original.renders // []))
         end)
    and all($journal.remove[];
      . as $artifact
      | .kind != "parent" and .kind != "directory"
      and any($original.artifacts[]; . == $artifact)
      and (any($next_artifacts[]; . == $artifact) | not)
      and (($render_paths | index($artifact.path)) == null))
    and ordered_subset($external.renders; ($original.renders // []))
    and no_path_overlap($external.renders; $next_renders)
    and all($external.renders[];
      . as $render
      | (any($next_renders[]; . == $render) | not)
      and any($original.artifacts[]; .path == $render.path))
    and no_path_overlap($external.renders; $next_artifacts)
    and (
      ([$original.artifacts[]
        | select(.kind != "parent" and .kind != "directory")
        | select(. as $artifact | any($next_artifacts[]; . == $artifact) | not)
        | .path] | sort)
      == (($journal.remove
           + [$original.artifacts[] | select(.path as $path | ($render_paths | index($path)) != null)]
          | map(.path) | sort))
    )
    and (
      ([($original.renders // [])[] | select(. as $render | any($next_renders[]; . == $render) | not) | .path] | sort)
      == ($external.renders | map(.path) | sort)
    )
    and ($external.render_phase <= ($external.renders | length))
    and (if $external.render_pending == null then true
         else $external.render_phase < ($external.renders | length)
           and $external.render_pending.render == $external.renders[$external.render_phase]
         end)
    and (if $journal.owner_committed then
           $journal.phase == ($journal.remove | length)
         else true end)
    and (if $external.phase > 0 then $journal.owner_committed else true end)
    and (if $external.phase >= 2 then
           $external.render_phase == ($external.renders | length)
           and $external.render_pending == null and $journal.removal == null
         else true end)
    and (if $journal.removal == null then true
         elif $journal.phase < ($journal.remove | length) then
           ($journal.remove[$journal.phase].kind == "file" or $journal.remove[$journal.phase].kind == "symlink")
           and $journal.removal.path == ($original.worktree_root + "/" + $journal.remove[$journal.phase].path)
         elif $external.render_pending != null then
           $journal.owner_committed and $external.phase == 1
           and ($journal.removal.path == ($original.worktree_root + "/" + $external.render_pending.render.path)
                or $journal.removal.path == $external.render_pending.staging_path)
         else false end)
    and (($external.exclude_action == "transfer") == ($external.transfer != null))
    and (if $external.exclude_action == "restore" then
           $external.transfer == null and $original.exclude.managed_by_attachment == true and $next == null
         else true end)
    and (if $external.exclude_action == "none" then $external.transfer == null else true end)
    and (if $external.restore_hooks then $original.git_hooks.enabled == true else true end)
    and ($external.clear_registry == ($next == null))
    and (if $next == null then $update == null
         else $update != null and $external.exclude_action == "none" and $external.restore_hooks == false
           and ($update.expected.harnesses | sort) == harnesses($original)
           and ($update.after.harnesses | sort) == $remaining
           and $update.expected.release == $original.release
           and $update.expected.git_common_dir == $original.exclude.git_common_dir
           and ([$update.expected.worktrees | to_entries[] | select(.value | has("attachment_id"))]
             == [{key:$original.worktree_id,value:{root:$original.worktree_root,attachment_id:$original.attachment_id}}])
         end)
    and (if $external.transfer == null then true
         else $external.transfer.expected.fleet == $original.fleet
           and $external.transfer.expected.project_id == $original.project_id
           and $external.transfer.expected.checkout_id == $original.checkout_id
           and ($external.transfer.after | del(.exclude,.exclude_block_hash,.git_hooks))
             == ($external.transfer.expected | del(.exclude,.exclude_block_hash,.git_hooks))
           and $external.transfer.after.artifacts == $external.transfer.expected.artifacts
           and ($external.transfer.after.renders // []) == ($external.transfer.expected.renders // [])
           and $external.transfer.after.exclude == $original.exclude
           and $external.transfer.after.exclude_block_hash == $original.exclude_block_hash
           and (if ($original | has("git_hooks"))
                then $external.transfer.after.git_hooks == $original.git_hooks
                else ($external.transfer.after | has("git_hooks") | not)
                end)
         end)
'

_attachment_detach_journal_data_valid() {
  local file=$1 original next transfer expected after attachment journal_dir state_dir home transfer_path transfer_checkout transfer_worktree
  _attachment_valid_absolute "$file" || return 2
  _attachment_json_file "$file" || return 2
  [ "$(_attachment_mode "$file")" = 600 ] || return 3
  jq -e "$_attachment_detach_journal_schema_filter" "$file" >/dev/null 2>&1 || return 2
  original=$(jq -c '.original_owner' "$file") || return 2
  _attachment_detach_owner_data_valid "$original" || return 2
  next=$(jq -c '.next_owner' "$file") || return 2
  if [ "$next" != null ] && [ "$(jq -r '.external.registry_update == null' "$file")" = true ]; then
    printf 'trellis attachment: legacy partial detach journal lacks a trusted registry snapshot\n' >&2
    return 2
  fi
  [ "$next" = null ] || _attachment_detach_owner_data_valid "$next" || return 2
  transfer=$(jq -c '.external.transfer' "$file") || return 2
  if [ "$transfer" != null ]; then
    expected=$(printf '%s\n' "$transfer" | jq -c '.expected') || return 2
    after=$(printf '%s\n' "$transfer" | jq -c '.after') || return 2
    _attachment_detach_owner_data_valid "$expected" || return 2
    _attachment_detach_owner_data_valid "$after" || return 2
  fi
  trellis_jq -e --argjson original "$original" --argjson next "$next" "$_attachment_detach_journal_invariants_filter" "$file" >/dev/null 2>&1 || return 2
  attachment=$(jq -r '.attachment_id' "$file") || return 2
  journal_dir=$(dirname "$file") || return 2
  state_dir=$(dirname "$journal_dir") || return 2
  home=$(dirname "$state_dir") || return 2
  [ "$journal_dir" = "$home/state/attachment-journals" ] || return 2
  [ "$file" = "$(_attachment_detach_journal_path "$home" "$attachment")" ] || return 2
  if [ "$transfer" != null ]; then
    transfer_path=$(printf '%s\n' "$transfer" | jq -r '.owner_path') || return 2
    transfer_checkout=$(printf '%s\n' "$expected" | jq -r '.checkout_id') || return 2
    transfer_worktree=$(printf '%s\n' "$expected" | jq -r '.worktree_id') || return 2
    [ "$transfer_path" = "$(_attachment_ownership_path "$home" "$transfer_checkout" "$transfer_worktree")" ] || return 2
  fi
}

_attachment_detach_journal_valid() {
  local file=$1 original
  _attachment_detach_journal_data_valid "$file" || return $?
  original=$(jq -c '.original_owner' "$file") || return 2
  _attachment_validate_roots "$original" || return 2
  _attachment_validate_ids "$original" || return 2
  _attachment_detach_render_pending_runtime_valid "$file"
}

# The re-check under the worktree lock: state that changed since the caller's
# own validation is refused by name rather than as a bare exit.
_attachment_detach_journal_revalid() {
  local status
  _attachment_detach_journal_valid "$1" && return 0
  status=$?
  _attachment_refuse "${ATTACHMENT_ACTION:-}" journal-invalid "$1"
  return "$status"
}

_attachment_detach_file_matches_data() {
  local file=$1 expected=$2 actual
  _attachment_owner_json_valid "$file" || return 1
  actual=$(jq -cS . "$file") || return 1
  [ "$actual" = "$(printf '%s\n' "$expected" | jq -cS .)" ]
}

_attachment_detach_journal_update() {
  local journal=$1 next
  shift
  next=$(trellis_jq -cS "$@" "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_upgrade_legacy_detach_render_pending() {
  local journal=$1 pending original root render destination stage parent identity next
  _attachment_detach_journal_valid "$journal" || return $?
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 0
  [ "$(printf '%s\n' "$pending" | jq -r 'has("parent_identity")')" = false ] || return 0
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  render=$(printf '%s\n' "$pending" | jq -c '.render') || return 2
  _attachment_parent_safe "$root" "$(printf '%s\n' "$render" | jq -r '.path')" || return 3
  destination="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return 2
  parent=$(dirname "$destination") || return 2
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  if [ -n "$stage" ]; then
    _attachment_stage_path_valid "$root" "$render" "$(jq -r '.attachment_id' "$journal")" "$stage" || return 2
    [ "$(dirname "$stage")" = "$parent" ] || return 2
  fi
  _attachment_canonical_dir "$parent" || return 3
  identity=$(_attachment_fs_identity "$parent") || return 1
  next=$(jq -cS --arg identity "$identity" '
    if .schema_version == 1 and .external.render_pending != null
      and (.external.render_pending | has("parent_identity") | not)
    then .external.render_pending.parent_identity = $identity
    else error("invalid legacy render migration")
    end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}
_attachment_detach_render_artifact() {
  local render=$1 sha=$2 mode=$3
  jq -cn --arg path "$(printf '%s\n' "$render" | jq -r '.path')" --arg sha "$sha" --arg mode "$mode" \
    '{path:$path,kind:"file",sha256:$sha,mode:$mode}'
}

_attachment_detach_render_begin_impl() {
  local journal=$1 render=$2 source_identity=$3 source_sha=$4 source_mode=$5
  local result_exists=$6 result_base64=$7 result_sha=$8 result_mode=$9 staging_path=${10} next
  local original root destination parent parent_identity
  [ "$#" -eq 10 ] || return 2
  _attachment_detach_journal_valid "$journal" || return $?
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  destination="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return 2
  parent=$(dirname "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  parent_identity=$(_attachment_fs_identity "$parent") || return 1
  next=$(trellis_jq -cS --argjson render "$render" --arg source_identity "$source_identity" --arg source_sha "$source_sha" --arg source_mode "$source_mode" \
    --argjson result_exists "$result_exists" --arg result_base64 "$result_base64" --arg result_sha "$result_sha" --argjson result_mode "$result_mode" \
    --argjson staging_path "$staging_path" --arg parent_identity "$parent_identity" '
      if .owner_committed == true and .removal == null and .external.phase == 1
        and .external.render_pending == null and .external.render_phase < (.external.renders | length)
        and .external.renders[.external.render_phase] == $render
      then .external.render_pending = {
        render:$render,source_identity:$source_identity,source_sha256:$source_sha,source_mode:$source_mode,
        result_exists:$result_exists,result_base64:$result_base64,result_sha256:$result_sha,result_mode:$result_mode,
        staging_path:$staging_path,staging_identity:null,parent_identity:$parent_identity
      }
      else error("invalid detach render begin") end
    ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_detach_render_set_stage_identity_impl() {
  local journal=$1 identity=$2 next
  [ "$#" -eq 2 ] || return 2
  next=$(jq -cS --arg identity "$identity" '
    if .external.render_pending != null
      and .external.render_pending.result_exists == true
      and .external.render_pending.staging_identity == null
      and (.external.render_pending.staging_path | type == "string")
    then .external.render_pending.staging_identity = $identity
    else error("invalid detach render stage identity") end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_detach_render_stage_impl() (
  local journal=$1 pending original root attachment render stage identity recorded bytes expected mode parent base actual_parent expected_parent
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_journal_valid "$journal" || return $?
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  [ "$(printf '%s\n' "$pending" | jq -r '.result_exists')" = true ] || return 0
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  render=$(printf '%s\n' "$pending" | jq -c '.render') || return 2
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path') || return 2
  recorded=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  expected=$(printf '%s\n' "$pending" | jq -r '.result_sha256') || return 2
  mode=$(printf '%s\n' "$pending" | jq -r '.result_mode') || return 2
  bytes=$(printf '%s\n' "$pending" | jq -r '.result_base64') || return 2
  _attachment_stage_path_valid "$root" "$render" "$attachment" "$stage" || return 3
  parent=$(dirname "$stage") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  _attachment_claim_namespace_valid "$journal" "$stage" || return 3
  if [ -z "$recorded" ] && { [ -e "$stage" ] || [ -L "$stage" ]; }; then
    _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" || return $?
  fi
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    [ -n "$recorded" ] || return 3
    _attachment_identity_matches "$stage" "$recorded" file || return 3
    [ "$(_attachment_hash "$stage")" = "$expected" ] && _attachment_mode_matches "$stage" "$mode" || return 3
    return 0
  fi
  [ -z "$recorded" ] || return 3
  parent=$(dirname "$stage") || return 2
  base=$(basename "$stage") || return 2
  _attachment_canonical_dir "$parent" || return 3
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 3
    set -o noclobber
    if ! { exec 9>"./$base"; } 2>/dev/null; then
      set +o noclobber
      return 3
    fi
    set +o noclobber
    identity=$(_attachment_fs_identity "./$base") || { exec 9>&-; return 1; }
    chmod "${mode#0}" "./$base" || { exec 9>&-; return 1; }
    if ! printf '%s' "$bytes" | base64 -D 2>/dev/null >&9; then
      printf '%s' "$bytes" | base64 -d 2>/dev/null >&9 || { exec 9>&-; return 1; }
    fi
    exec 9>&-
    _attachment_identity_matches "./$base" "$identity" file || return 3
    [ "$(_attachment_hash "./$base")" = "$expected" ] && _attachment_mode_matches "./$base" "$mode" || return 3
    # Journaled only once complete: a crash before this leaves an unidentified
    # stage, which recovery reclaims (up to 1.5.1 the identity came first and
    # a crash before the bytes left a stage refused forever).
    _attachment_detach_render_set_stage_identity_impl "$journal" "$identity"
  )
)

_attachment_detach_render_claim_impl() {
  local journal=$1 pending original root render path artifact
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_journal_valid "$journal" || return $?
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  render=$(printf '%s\n' "$pending" | jq -c '.render') || return 2
  path="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return 2
  artifact=$(_attachment_detach_render_artifact "$render" "$(printf '%s\n' "$pending" | jq -r '.source_sha256')" "$(printf '%s\n' "$pending" | jq -r '.source_mode')") || return 2
  _attachment_claim_pinned "$journal" "$path" "$artifact" "$(printf '%s\n' "$pending" | jq -r '.source_identity')"
}

_attachment_detach_render_publish_impl() {
  local journal=$1 pending original root render path artifact
  local result_exists stage identity expected mode
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_journal_valid "$journal" || return $?
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  render=$(printf '%s\n' "$pending" | jq -c '.render') || return 2
  path="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return 2
  artifact=$(_attachment_detach_render_artifact "$render" "$(printf '%s\n' "$pending" | jq -r '.source_sha256')" "$(printf '%s\n' "$pending" | jq -r '.source_mode')") || return 2
  _attachment_journal_claim_layout "$journal" "$path" || return 3
  [ "$_ATTACHMENT_CLAIM_STATE" = claimed ] || return 3
  _attachment_identity_matches "$_ATTACHMENT_CLAIM_PATH" "$(printf '%s\n' "$pending" | jq -r '.source_identity')" file || return 3
  _attachment_path_exact "$_ATTACHMENT_CLAIM_PATH" "$artifact" || return 3
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 3
  result_exists=$(printf '%s\n' "$pending" | jq -r '.result_exists') || return 2
  if [ "$result_exists" = false ]; then return 0; fi
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  expected=$(printf '%s\n' "$pending" | jq -r '.result_sha256') || return 2
  mode=$(printf '%s\n' "$pending" | jq -r '.result_mode') || return 2
  _attachment_publish_pinned_stage "$stage" "$path" "$identity" "$expected" "$mode"
}

_attachment_detach_render_cleanup_impl() {
  local journal=$1 pending original root render path source_artifact result_artifact
  local result_exists stage identity removal removal_path
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_journal_valid "$journal" || return $?
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  render=$(printf '%s\n' "$pending" | jq -c '.render') || return 2
  path="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return 2
  source_artifact=$(_attachment_detach_render_artifact "$render" "$(printf '%s\n' "$pending" | jq -r '.source_sha256')" "$(printf '%s\n' "$pending" | jq -r '.source_mode')") || return 2
  result_exists=$(printf '%s\n' "$pending" | jq -r '.result_exists') || return 2
  removal=$(jq -c '.removal' "$journal") || return 2
  if [ "$removal" != null ]; then
    removal_path=$(printf '%s\n' "$removal" | jq -r '.path') || return 2
    if [ "$removal_path" = "$path" ]; then
      _attachment_discard_pinned_claim "$journal" "$path" "$source_artifact" "$(printf '%s\n' "$pending" | jq -r '.source_identity')" || return $?
    elif [ "$result_exists" != true ] || [ "$removal_path" != "$(printf '%s\n' "$pending" | jq -r '.staging_path')" ]; then
      return 3
    fi
  fi
  if [ "$result_exists" != true ]; then
    [ "$(jq -r '.removal == null' "$journal")" = true ] || return 3
    return 0
  fi
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  result_artifact=$(_attachment_detach_render_artifact "$render" "$(printf '%s\n' "$pending" | jq -r '.result_sha256')" "$(printf '%s\n' "$pending" | jq -r '.result_mode')") || return 2
  removal=$(jq -c '.removal' "$journal") || return 2
  if [ "$removal" != null ] && [ "$(printf '%s\n' "$removal" | jq -r '.path')" = "$stage" ]; then
    _attachment_journal_claim_layout "$journal" "$stage" || return 3
    case "$_ATTACHMENT_CLAIM_STATE" in
      claimed)
        _attachment_discard_pinned_claim "$journal" "$stage" "$result_artifact" "$identity" || return $?
        ;;
      empty|absent)
        # A stage still in place is claimed first (up to 1.5.1 an empty
        # quarantine was discarded and the stage left behind); one already
        # gone was claimed and discarded, and the discard clears.
        if [ -e "$stage" ] || [ -L "$stage" ]; then
          _attachment_claim_pinned "$journal" "$stage" "$result_artifact" "$identity" || return $?
        fi
        _attachment_discard_pinned_claim "$journal" "$stage" "$result_artifact" "$identity" || return $?
        ;;
      *) return 3 ;;
    esac
  elif [ -e "$stage" ] || [ -L "$stage" ]; then
    _attachment_claim_pinned "$journal" "$stage" "$result_artifact" "$identity" || return $?
    _attachment_discard_pinned_claim "$journal" "$stage" "$result_artifact" "$identity" || return $?
  fi
  [ "$(jq -r '.removal == null' "$journal")" = true ] || return 3
}

_attachment_detach_render_finish_impl() {
  local journal=$1 next pending original root render path result_exists identity expected mode
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_journal_valid "$journal" || return $?
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  render=$(printf '%s\n' "$pending" | jq -c '.render') || return 2
  path="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return 2
  result_exists=$(printf '%s\n' "$pending" | jq -r '.result_exists') || return 2
  if [ "$result_exists" = false ]; then
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 3
  else
    identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
    expected=$(printf '%s\n' "$pending" | jq -r '.result_sha256') || return 2
    mode=$(printf '%s\n' "$pending" | jq -r '.result_mode') || return 2
    _attachment_identity_matches "$path" "$identity" file || return 3
    [ "$(_attachment_hash "$path")" = "$expected" ] && _attachment_mode_matches "$path" "$mode" || return 3
  fi
  next=$(jq -cS '
    if .owner_committed == true and .removal == null and .external.phase == 1
      and .external.render_pending != null
      and .external.render_phase < (.external.renders | length)
      and .external.render_pending.render == .external.renders[.external.render_phase]
    then .external.render_phase += 1 | .external.render_pending = null
    else error("invalid detach render finish") end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}
_attachment_detach_render_pending_runtime_valid() (
  local journal=$1 pending original root render path artifact removal removal_path has_parent
  local result_exists result_sha result_mode result_base64 stage stage_identity attachment tmp parent expected_parent
  stage=
  stage_identity=
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 0
  has_parent=$(printf '%s\n' "$pending" | jq -r 'has("parent_identity")') || return 2
  [ "$has_parent" = true ] || return 0
  original=$(jq -c '.original_owner' "$journal") || return 2
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  render=$(printf '%s\n' "$pending" | jq -c '.render') || return 2
  path="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return 2
  parent=$(dirname "$path") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  _attachment_parent_safe "$root" "$(printf '%s\n' "$render" | jq -r '.path')" || return 3
  _attachment_claim_namespace_valid "$journal" "$path" || return 3
  result_exists=$(printf '%s\n' "$pending" | jq -r '.result_exists') || return 2
  result_sha=$(printf '%s\n' "$pending" | jq -r '.result_sha256') || return 2
  result_mode=$(printf '%s\n' "$pending" | jq -r '.result_mode // empty') || return 2
  result_base64=$(printf '%s\n' "$pending" | jq -r '.result_base64') || return 2
  if [ "$result_exists" = true ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/trellis.detach.render.XXXXXX") || return 1
    trap 'rm -f "$tmp"' EXIT
    chmod 600 "$tmp" || return 1
    if ! printf '%s' "$result_base64" | base64 -D 2>/dev/null > "$tmp"; then
      printf '%s' "$result_base64" | base64 -d 2>/dev/null > "$tmp" || return 2
    fi
    [ "$(_attachment_hash "$tmp")" = "$result_sha" ] || return 2
    stage=$(printf '%s\n' "$pending" | jq -r '.staging_path') || return 2
    stage_identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
    attachment=$(jq -r '.attachment_id' "$journal") || return 2
    _attachment_stage_path_valid "$root" "$render" "$attachment" "$stage" || return 2
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      if [ -n "$stage_identity" ]; then
        _attachment_identity_matches "$stage" "$stage_identity" file || return 3
        [ "$(_attachment_hash "$stage")" = "$result_sha" ] && _attachment_mode_matches "$stage" "$result_mode" || return 3
      else
        [ -f "$stage" ] && [ ! -L "$stage" ] || return 3
      fi
    elif [ -n "$stage_identity" ]; then
      _attachment_identity_matches "$path" "$stage_identity" file || return 3
      [ "$(_attachment_hash "$path")" = "$result_sha" ] && _attachment_mode_matches "$path" "$result_mode" || return 3
    fi
  fi
  artifact=$(_attachment_detach_render_artifact "$render" "$(printf '%s\n' "$pending" | jq -r '.source_sha256')" "$(printf '%s\n' "$pending" | jq -r '.source_mode')") || return 2
  removal=$(jq -c '.removal' "$journal") || return 2
  if [ "$removal" != null ]; then
    removal_path=$(printf '%s\n' "$removal" | jq -r '.path') || return 2
    if [ "$removal_path" = "$path" ]; then
      _attachment_journal_claim_layout "$journal" "$path" || return 3
      if [ "$_ATTACHMENT_CLAIM_STATE" = claimed ]; then
        _attachment_identity_matches "$_ATTACHMENT_CLAIM_PATH" "$(printf '%s\n' "$pending" | jq -r '.source_identity')" file || return 3
        _attachment_path_exact "$_ATTACHMENT_CLAIM_PATH" "$artifact" || return 3
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then return 0; fi
      fi
    elif [ "$result_exists" = true ] && [ "$removal_path" = "$stage" ]; then
      _attachment_journal_claim_layout "$journal" "$stage" || return 3
      if [ "$_ATTACHMENT_CLAIM_STATE" = claimed ]; then
        artifact=$(_attachment_detach_render_artifact "$render" "$result_sha" "$result_mode") || return 2
        _attachment_identity_matches "$_ATTACHMENT_CLAIM_PATH" "$stage_identity" file || return 3
        _attachment_path_exact "$_ATTACHMENT_CLAIM_PATH" "$artifact" || return 3
      fi
    fi
  fi
  if [ -f "$path" ] && [ ! -L "$path" ] &&
    _attachment_identity_matches "$path" "$(printf '%s\n' "$pending" | jq -r '.source_identity')" file &&
    [ "$(_attachment_hash "$path")" = "$(printf '%s\n' "$pending" | jq -r '.source_sha256')" ] &&
    _attachment_mode_matches "$path" "$(printf '%s\n' "$pending" | jq -r '.source_mode')"; then
    return 0
  fi
  if [ "$result_exists" = false ]; then
    [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
    return 3
  fi
  _attachment_identity_matches "$path" "$stage_identity" file || return 3
  [ "$(_attachment_hash "$path")" = "$result_sha" ] && _attachment_mode_matches "$path" "$result_mode" || return 3
)

_attachment_detach_prepare_impl() {
  local home=$1 owner=$2 next_owner=$3 remove=$4 external=$5 original checkout worktree attachment journal expected status
  [ "$#" -eq 5 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_owner_json_valid "$owner" || {
    status=$?
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-record-invalid "$owner"
    return "$status"
  }
  _attachment_verify_detach_owner_artifacts "$owner" || return 3
  original=$(jq -cS . "$owner") || return 2
  checkout=$(printf '%s\n' "$original" | jq -r '.checkout_id') || return 2
  worktree=$(printf '%s\n' "$original" | jq -r '.worktree_id') || return 2
  attachment=$(printf '%s\n' "$original" | jq -r '.attachment_id') || return 2
  [ "$owner" = "$(_attachment_ownership_path "$home" "$checkout" "$worktree")" ] || return 2
  case "$next_owner" in
    null) ;;
    *) _attachment_detach_owner_data_valid "$next_owner" || return 2
       printf '%s\n' "$next_owner" | jq -e --arg checkout "$checkout" --arg worktree "$worktree" --arg attachment "$attachment" \
         '.checkout_id == $checkout and .worktree_id == $worktree and .attachment_id == $attachment' >/dev/null 2>&1 || return 2 ;;
  esac
  printf '%s\n' "$remove" | trellis_jq -e --argjson original "$original" --argjson next "$next_owner" '
    type == "array"
    and all(.[]; . as $artifact | any($original.artifacts[]; . == $artifact))
    and ($next == null or (all($next.artifacts[]; . as $artifact | any($original.artifacts[]; . == $artifact))))
  ' >/dev/null 2>&1 || return 2
  printf '%s\n' "$external" | jq -e 'type == "object"' >/dev/null 2>&1 || return 2
  journal=$(_attachment_detach_journal_path "$home" "$attachment")
  expected=$(trellis_jq -cn --argjson original "$original" --argjson next "$next_owner" --argjson remove "$remove" --argjson external "$external" \
    '{schema_version:1,status:"detaching",attachment_id:$original.attachment_id,checkout_id:$original.checkout_id,worktree_id:$original.worktree_id,original_owner:$original,next_owner:$next,remove:$remove,phase:0,owner_committed:false,removal:null,external:($external + {phase:0,render_phase:0,render_pending:null})}') || return 2
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    _attachment_detach_journal_valid "$journal" || {
      status=$?
      _attachment_refuse "${ATTACHMENT_ACTION:-}" journal-invalid "$journal"
      return "$status"
    }
    [ "$(jq -cS . "$journal")" = "$(printf '%s\n' "$expected" | jq -cS .)" ] || {
      _attachment_refuse "${ATTACHMENT_ACTION:-}" journal-mismatch "$journal"
      return 3
    }
    return 0
  fi
  _attachment_write_json "$journal" "$expected"
}

# Native detach (1.5.1): the per-artifact removal protocol of a detach commit
# (preflight, removal intent, quarantine claim, exact check, remove, clear,
# phase) and owner artifact verification run in one Python process instead of
# ~50 short processes per artifact. The durable states are the v1 detach
# journal's, written in the same order through the same atomic replace, so a
# crash at any step recovers through the same path, and a release that only
# has the shell protocol can still finish it. The program is
# scripts/lib/detach_native.py; it loads the filesystem primitives it shares
# with the attach publisher from scripts/lib/attachment_fs.py, so the claim
# namespace guard has one Python implementation. Its text is emitted after the
# module path, so the crash suites can substitute the checkpoint seam.
_attachment_detach_program() {
  local fs program
  fs=$(_attachment_fs_module) || return 1
  program="${fs%/attachment_fs.py}/detach_native.py"
  [ -f "$program" ] && [ ! -L "$program" ] && [ -r "$program" ] || return 1
  printf "ATTACHMENT_FS = r'%s'\n" "$fs"
  cat -- "$program"
}

# attachment_detach_owners_batch HOME OWNER...: every check that
# attachment_verify_detach makes, for all of a checkout's owners in one jq and
# one Python pass. Prints the owners as [{path,record}] (record as jq -cS
# prints it) when all pass. Status 10, printing nothing, when any check fails
# or cannot run: the caller then verifies owner by owner, which names the
# first refusal exactly as before.
attachment_detach_owners_batch() {
  local home=$1 checks expected
  shift
  [ "$#" -gt 0 ] || { printf '[]\n'; return 0; }
  _attachment_prepare_state "$home" >/dev/null 2>&1 || return 10
  # exact_inputs: one parsed document per requested owner file, in order, or
  # 10 and the per-owner path refuses (an empty or two-document file).
  expected=$(_attachment_paths_json "$@") || return 10
  checks=$(trellis_jq -cS -n --arg home "$home" --argjson expected "$expected" "$_attachment_exact_inputs_def
    [exact_inputs | .path as \$path | .record | {path: \$path, record: .,
      valid: (try ($_attachment_owner_schema_filter) catch false),
      canonical: (try (\$path == (\$home + \"/state/attachments/\" + .checkout_id + \"/\" + .worktree_id + \".json\")) catch false)}]
  " "$@" 2>/dev/null) || return 10
  printf '%s\n' "$checks" | _attachment_detach_python verify-owners || return 10
  printf '%s\n' "$checks" | jq -c 'map({path, record})' || return 10
}

# The validator filters the native program runs (spec 075 R5: one source).
_attachment_detach_python_filters() {
  TRELLIS_DETACH_JOURNAL_SCHEMA="$_attachment_detach_journal_schema_filter" \
    TRELLIS_DETACH_JOURNAL_INVARIANTS="$_attachment_detach_journal_invariants_filter" \
    TRELLIS_OWNER_SCHEMA="$_attachment_owner_schema_filter" \
    _attachment_detach_python "$@"
}

_attachment_detach_python() {
  local python_bin program
  python_bin=$(command -v python3) || return 1
  case "$python_bin" in /*) ;; *) return 1 ;; esac
  program=$(_attachment_detach_program) || return 1
  # -B, as in _attachment_commit_batch: attachment_fs.py loads by path.
  /usr/bin/env LC_ALL=C "$python_bin" -I -B -c "$program" "$@"
}

# Finish phases 1 and 2 (mark 1, render restore, mark 2) under the worktree
# attachment lock, by the shell that holds it. The journal is validated as a
# whole first, as every shell step did. Status 77: a render must be begun.
_attachment_detach_renders_batch() {
  local holder=${_ATTACHMENT_LOCK_HOLDER:-} owner_pid
  [ -n "$holder" ] || return 1
  _attachment_detach_journal_valid "$1" || return $?
  owner_pid=$(jq -r '.pid' "$holder/owner.json") || return 1
  _attachment_detach_python renders "${ATTACHMENT_ACTION:-}" "$1" "$holder" "$owner_pid"
}

_attachment_detach_preflight_remaining() {
  local journal=$1 root=$2 artifact relative kind expected has_mode mode target removal_path
  removal_path=$(jq -r '.removal.path // empty' "$journal") || return 2
  # One jq decodes every entry, as the owner preflight does; the validated
  # journal's paths hold no control bytes. The compact entry rides along for
  # the claimed-removal check.
  while IFS= read -r -d '' relative && IFS= read -r -d '' kind &&
        IFS= read -r -d '' expected && IFS= read -r -d '' has_mode &&
        IFS= read -r -d '' mode && IFS= read -r -d '' target &&
        IFS= read -r -d '' artifact; do
    # A detach killed inside its first removal has journaled the claim for that
    # leaf; the claim layout, not the bare path, says whether it is still exact.
    if [ -n "$removal_path" ] && [ "$root/$relative" = "$removal_path" ]; then
      _attachment_artifact_absent_or_exact "$root" "$artifact" "$journal" && continue
    elif _attachment_artifact_exact_fields "$root" "$relative" "$kind" "$expected" "$has_mode" "$mode" "$target"; then
      continue
    elif [ "$relative" = .trellis/runtime ] &&
         _attachment_parent_safe "$root" .trellis/runtime &&
         [ ! -e "$root/.trellis/runtime" ] && [ ! -L "$root/.trellis/runtime" ]; then
      # The withdrawn anchor of a refused attach, as in the owner preflight.
      continue
    fi
    _attachment_refuse "${ATTACHMENT_ACTION:-}" artifact-changed "$root/$relative"
    return 3
  done < <(jq -j '.remove | sort_by(.path)[] | .path, "\u0000", .kind, "\u0000", .sha256, "\u0000",
    has("mode"), "\u0000", .mode, "\u0000", .target, "\u0000", tojson, "\u0000"' "$journal")
}

_attachment_detach_remove_one() {
  local journal=$1 root=$2 artifact=$3 relative destination kind status
  # The committed journal was validated: path and kind are strings.
  trellis_read_nul_fields relative kind < <(printf '%s\n' "$artifact" | jq -j '
    if (.path | type == "string") and (.kind | type == "string")
    then (.path | gsub("\u0000"; "")), "\u0000", (.kind | gsub("\u0000"; "")), "\u0000"
    else empty end') || return 2
  destination=$(_attachment_destination "$root" "$relative")
  _attachment_parent_safe "$root" "$relative" || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" artifact-changed "$destination"
    return 3
  }
  case "$kind" in
    parent|directory)
      if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then return 0; fi
      if [ -d "$destination" ] && [ ! -L "$destination" ]; then
        rmdir -- "$destination" 2>/dev/null && return 0
        [ -d "$destination" ] && [ ! -L "$destination" ] && return 0
      fi
      _attachment_refuse "${ATTACHMENT_ACTION:-}" parent-not-removable "$destination"
      return 3
      ;;
    file|symlink)
      _attachment_remove_pinned "$journal" "$destination" "$artifact" "" 0 1
      status=$?
      [ "$status" -ne 3 ] || _attachment_refuse "${ATTACHMENT_ACTION:-}" artifact-changed "$destination"
      return "$status"
      ;;
    *) return 2 ;;
  esac
}

_attachment_detach_commit_locked() {
  local home=$1 journal=$2 holder=${_ATTACHMENT_LOCK_HOLDER:-} owner_pid
  # The whole commit (removal loop, owner checks, registry clear through the
  # shell's own writer, owner removal or rewrite, owner_committed) runs in the
  # native program under this shell's worktree lock (spec 075 T4b).
  [ -n "$holder" ] || return 1
  owner_pid=$(jq -r '.pid' "$holder/owner.json") || return 1
  TRELLIS_DETACH_BASH="$BASH" _attachment_detach_python_filters commit "${ATTACHMENT_ACTION:-}" "$journal" "$holder" "$owner_pid" "$home"
}

_attachment_detach_commit_impl() (
  local home=$1 journal=$2 checkout worktree attachment
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_detach_journal_valid "$journal" || return $?
  checkout=$(jq -r '.checkout_id' "$journal") || return 2
  worktree=$(jq -r '.worktree_id' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  [ "$journal" = "$(_attachment_detach_journal_path "$home" "$attachment")" ] || return 2
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" ||
    _attachment_lock_refuse $? "$home" "$checkout" "$worktree" || return $?
  _attachment_install_lock_traps
  _attachment_upgrade_legacy_detach_render_pending "$journal" ||
    _attachment_detach_step_refuse $? render-conflict "$journal" || return $?
  _attachment_detach_journal_revalid "$journal" || return $?
  _attachment_detach_commit_locked "$home" "$journal"
)

_attachment_detach_recover_impl() (
  local home=$1 journal=$2 checkout worktree attachment
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_detach_journal_valid "$journal" || return $?
  checkout=$(jq -r '.checkout_id' "$journal") || return 2
  worktree=$(jq -r '.worktree_id' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  [ "$journal" = "$(_attachment_detach_journal_path "$home" "$attachment")" ] || return 2
  _attachment_lock_reclaim "$home" "$checkout" "$worktree" "$attachment" ||
    _attachment_lock_refuse $? "$home" "$checkout" "$worktree" || return $?
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" ||
    _attachment_lock_refuse $? "$home" "$checkout" "$worktree" || return $?
  _attachment_install_lock_traps
  _attachment_upgrade_legacy_detach_render_pending "$journal" ||
    _attachment_detach_step_refuse $? render-conflict "$journal" || return $?
  _attachment_detach_journal_revalid "$journal" || return $?
  _attachment_detach_commit_locked "$home" "$journal"
)

_attachment_detach_mark_external_phase_impl() {
  local home=$1 journal=$2 phase=$3 current
  [ "$#" -eq 3 ] || return 2
  case "$phase" in 0|1|2|3|4|5) ;; *) return 2 ;; esac
  _attachment_prepare_state "$home" || return $?
  _attachment_detach_journal_valid "$journal" || return $?
  [ "$(jq -r '.owner_committed' "$journal")" = true ] || return 3
  current=$(jq -r '.external.phase' "$journal") || return 2
  [ "$phase" -eq $((current + 1)) ] || return 3
  if [ "$phase" -eq 2 ]; then
    jq -e '
      .external.render_phase == (.external.renders | length)
      and .external.render_pending == null and .removal == null
    ' "$journal" >/dev/null 2>&1 || return 3
  fi
  _attachment_detach_journal_update "$journal" --argjson phase "$phase" '.external.phase = $phase'
}

_attachment_detach_finalize_impl() {
  local home=$1 journal=$2
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_detach_journal_valid "$journal" || return $?
  [ "$(jq -r '.owner_committed' "$journal")" = true ] || return 3
  [ "$(jq -r '.external.phase' "$journal")" = 5 ] || return 3
  rm -- "$journal"
}

attachment_detach_prepare() {
  local status
  [ "$#" -eq 5 ] || return 2
  _attachment_detach_prepare_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_commit() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_detach_commit_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_recover() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_detach_recover_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}
attachment_detach_render_begin() {
  local status
  [ "$#" -eq 10 ] || return 2
  _attachment_detach_render_begin_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" render-conflict "$1"
  _attachment_map_public_status "$?"
}

attachment_detach_render_stage() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_stage_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" render-conflict "$1"
  _attachment_map_public_status "$?"
}

attachment_detach_render_claim() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_claim_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" render-conflict "$1"
  _attachment_map_public_status "$?"
}

attachment_detach_render_publish() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_publish_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" render-conflict "$1"
  _attachment_map_public_status "$?"
}

attachment_detach_render_cleanup() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_cleanup_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" render-conflict "$1"
  _attachment_map_public_status "$?"
}

attachment_detach_render_finish() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_finish_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" render-conflict "$1"
  _attachment_map_public_status "$?"
}

attachment_detach_mark_external_phase() {
  local status
  [ "$#" -eq 3 ] || return 2
  _attachment_detach_mark_external_phase_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" journal-phase-conflict "$2"
  _attachment_map_public_status "$?"
}

attachment_detach_finalize() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_detach_finalize_impl "$@"; status=$?
  _attachment_detach_step_refuse "$status" journal-phase-conflict "$2"
  _attachment_map_public_status "$?"
}
# User-surface attachment state is deliberately isolated from project
# attachments.  User records contain absolute HOME destinations and never pass
# through the Git-bound project transaction functions above.
_attachment_user_owner_path() {
  printf '%s/attachments/user.json\n' "$1"
}

_attachment_user_journal_path() {
  printf '%s/state/user-attachment-journals/attach.json\n' "$1"
}

_attachment_user_detach_journal_path() {
  printf '%s/state/user-attachment-journals/detach.json\n' "$1"
}

_attachment_user_lock_path() {
  printf '%s/state/locks/attachment-user.lock\n' "$1"
}

_attachment_user_lock_holder_prefix() {
  printf '%s\n' '.attachment-user.holder-'
}

_attachment_user_prepare_state() {
  local home=$1
  _attachment_canonical_dir "$home" || return 2
  _attachment_ensure_private_dir "$home/attachments" || return 1
  _attachment_ensure_private_dir "$home/state" || return 1
  _attachment_ensure_private_dir "$home/state/user-attachment-journals" || return 1
  _attachment_ensure_private_dir "$home/state/locks" || return 1
}

_attachment_user_lock_release() {
  local link=${_ATTACHMENT_USER_LOCK_LINK:-} holder=${_ATTACHMENT_USER_LOCK_HOLDER:-} target
  [ -n "$link" ] && [ -n "$holder" ] || return 0
  if [ -L "$link" ]; then
    target=$(readlink "$link") || return 1
    [ "$(dirname "$holder")/$(basename "$target")" = "$holder" ] || return 1
    rm "$link" || return 1
  elif [ -e "$link" ]; then
    return 1
  fi
  rm -f "$holder/owner.json" || return 1
  rmdir "$holder" 2>/dev/null || return 1
  _ATTACHMENT_USER_LOCK_LINK=
  _ATTACHMENT_USER_LOCK_HOLDER=
}

_attachment_user_lock_acquire() {
  local home=$1 attachment=$2 locks link prefix holder metadata target pid birth
  locks="$home/state/locks"
  link=$(_attachment_user_lock_path "$home")
  [ ! -e "$link" ] && [ ! -L "$link" ] || return 3
  _attachment_capture_current_pid "$locks" || return 1
  pid=$_ATTACHMENT_PROCESS_PID
  birth=$(_attachment_process_birth "$pid") || return 1
  [ -n "$birth" ] || return 1
  prefix=$(_attachment_user_lock_holder_prefix)
  holder=$(mktemp -d "$locks/${prefix}${attachment}.${pid}.XXXXXX") || return 1
  chmod 700 "$holder" || { rmdir "$holder"; return 1; }
  metadata=$(jq -cn --arg attachment "$attachment" --arg birth "$birth" --argjson pid "$pid" \
    '{surface:"user",attachment_id:$attachment,pid:$pid,process_birth:$birth}') || {
      rmdir "$holder"
      return 1
    }
  _attachment_write_json "$holder/owner.json" "$metadata" || {
    rmdir "$holder" 2>/dev/null
    return 1
  }
  target=$(basename "$holder")
  if ! ln -sn -- "$target" "$link" 2>/dev/null; then
    rm -f "$holder/owner.json"
    rmdir "$holder" 2>/dev/null
    return 3
  fi
  _ATTACHMENT_USER_LOCK_LINK=$link
  _ATTACHMENT_USER_LOCK_HOLDER=$holder
}

_attachment_user_lock_reclaim() {
  local home=$1 link locks target holder metadata pid prefix recorded_birth current_birth
  link=$(_attachment_user_lock_path "$home")
  [ -e "$link" ] || [ -L "$link" ] || return 0
  [ -L "$link" ] || return 4
  target=$(readlink "$link") || return 4
  case "$target" in */*|.|..) return 4 ;; esac
  prefix=$(_attachment_user_lock_holder_prefix)
  case "$target" in "$prefix"*) ;; *) return 4 ;; esac
  locks="$home/state/locks"
  holder="$locks/$target"
  [ -d "$holder" ] && [ ! -L "$holder" ] || return 4
  [ "$(_attachment_mode "$holder")" = 700 ] || return 4
  metadata="$holder/owner.json"
  _attachment_json_file "$metadata" || return 4
  [ "$(_attachment_mode "$metadata")" = 600 ] || return 4
  jq -e '
    type == "object"
    and (keys | sort) == ["attachment_id","pid","process_birth","surface"]
    and .surface == "user"
    and (.attachment_id | type == "string" and length > 0)
    and (.pid | type == "number" and floor == . and . > 0)
    and (.process_birth | type == "string" and length > 0)
  ' "$metadata" >/dev/null 2>&1 || return 4
  pid=$(jq -r '.pid' "$metadata") || return 4
  recorded_birth=$(jq -r '.process_birth' "$metadata") || return 4
  if kill -0 "$pid" 2>/dev/null; then
    current_birth=$(_attachment_process_birth "$pid") || return 4
    [ -n "$current_birth" ] || return 4
    [ "$current_birth" != "$recorded_birth" ] || return 3
  fi
  rm "$link" || return 1
  rm "$metadata" || return 1
  rmdir "$holder" || return 1
}

_attachment_install_user_lock_traps() {
  trap '_attachment_user_lock_release >/dev/null 2>&1' EXIT
  trap '_attachment_signal_exit' HUP
  trap '_attachment_signal_exit' INT
  trap '_attachment_signal_exit' TERM
}

_attachment_user_runtime_home() {
  local home=${HOME:-} canonical
  [ -n "$home" ] || return 5
  _attachment_valid_absolute "$home" || return 4
  [ -d "$home" ] && [ ! -L "$home" ] || return 5
  canonical=$(CDPATH='' cd "$home" 2>/dev/null && pwd -P) || return 5
  _attachment_canonical_dir "$canonical" || return 4
  printf '%s\n' "$canonical"
}

_attachment_user_home_paths_match_json() {
  local record=$1 current
  current=$(_attachment_user_runtime_home) || return $?
  printf '%s\n' "$record" | jq -e --arg home "$current" \
    '.home_paths == [$home]' >/dev/null 2>&1 || return 3
}

_attachment_user_home_paths_match_file() {
  local file=$1 current
  [ ! -L "$file" ] && [ -f "$file" ] || return 3
  current=$(_attachment_user_runtime_home) || return $?
  jq -e --arg home "$current" \
    '.home_paths == [$home]' "$file" >/dev/null 2>&1 || return 3
}

# Existing callers pass a state pathname; keep this entry point file-only so
# pathnames are never sent to jq as JSON text.
_attachment_user_home_paths_match() {
  _attachment_user_home_paths_match_file "$1"
}

_attachment_user_runtime_binding_matches() {
  local home=$1 record=$2 user_home expected actual
  user_home=$(_attachment_user_runtime_home) || return $?
  _attachment_user_home_paths_match_file "$record" || return $?
  expected=$(jq -r '.home_identity // empty' "$record") || return 2
  [ -n "$expected" ] || return 2
  actual=$(_attachment_fs_identity "$user_home") || return 1
  [ "$actual" = "$expected" ] || return 3
  expected=$(jq -r '.trellis_home_identity // empty' "$record") || return 2
  [ -n "$expected" ] || return 2
  actual=$(_attachment_fs_identity "$home") || return 1
  [ "$actual" = "$expected" ] || return 3
}

_attachment_user_destination_safe() {
  local user_home=$1 trellis_home=$2 destination=$3 folded_trellis folded_destination
  _attachment_canonical_dir "$user_home" || return 4
  _attachment_canonical_dir "$trellis_home" || return 4
  _attachment_valid_absolute "$destination" || return 4
  case "$destination" in "$user_home"/*) ;; *) return 4 ;; esac
  case "$destination" in
    "$trellis_home"|"$trellis_home"/*) return 4 ;;
  esac
  case "$trellis_home" in
    "$destination"/*) return 4 ;;
  esac
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    folded_trellis=$( (export LC_ALL=C && printf '%s' "$trellis_home") | tr '[:upper:]' '[:lower:]') || return 4
    folded_destination=$( (export LC_ALL=C && printf '%s' "$destination") | tr '[:upper:]' '[:lower:]') || return 4
    case "$folded_destination" in
      "$folded_trellis"|"$folded_trellis"/*) return 4 ;;
    esac
    case "$folded_trellis" in
      "$folded_destination"/*) return 4 ;;
    esac
  fi
}

_attachment_user_parent_safe() {
  local user_home=$1 destination=$2 relative parent current part
  local -a parts
  case "$destination" in "$user_home"/*) ;; *) return 1 ;; esac
  relative=${destination#"$user_home"/}
  parent=$(dirname "$relative") || return 1
  [ "$parent" != . ] || return 0
  current=$user_home
  IFS=/ read -r -a parts <<< "$parent"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || return 1
    current="$current/$part"
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
  done
}

_attachment_user_plan_filter='
  def exact($allowed): ((keys_unsorted - $allowed) | length) == 0;
  def controls: test("[[:cntrl:]]");
  def abs: type == "string" and startswith("/") and . != "/" and (endswith("/") | not)
    and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
  def rel: type == "string" and length > 0 and (startswith("/") | not) and (endswith("/") | not)
    and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
  def sha: type == "string" and test("^[a-f0-9]{64}$");
  def b64: type == "string" and test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");
  def mode: type == "string" and test("^0[0-7]{3}$");
  def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
  def semver: type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\\+([0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*))?$");
  def json_path: type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (controls | not));
  def replacement:
    type == "object" and exact(["before_base64","before_mode","before_sha256"])
    and (.before_base64 | b64) and (.before_mode | mode) and (.before_sha256 | sha);
  def symlink_restore:
    replacement
    or (type == "object" and exact(["before_target"]) and (.before_target | abs));
  def artifact:
    type == "object" and (.destination | abs)
    and if .kind == "file" then
      (.sha256 | sha) and (.mode | mode)
      and (if has("source") then
             exact(["destination","kind","mode","replace","restore","sha256","source"]) and (.source | abs)
           elif has("content_base64") then
             exact(["content_base64","destination","kind","mode","replace","restore","sha256"]) and (.content_base64 | b64)
           else false end)
      and (if has("replace") then (.replace | replacement) else true end)
      and (if has("restore") then (.restore | replacement) else true end)
    elif .kind == "symlink" then
      exact(["destination","kind","replace","restore","source","target"]) and (.source | rel) and (.target | abs)
      and ((has("replace") and has("restore")) | not)
      and (if has("replace") then (.replace | replacement) else true end)
      and (if has("restore") then (.restore | symlink_restore) else true end)
    elif .kind == "parent" then exact(["destination","kind"])
    else false end;
  def render:
    type == "object"
    and exact(["after_base64","after_mode","after_sha256","before_base64","before_exists","before_mode","before_sha256","created_paths","destination","merge","mode","owned_keys"])
    and (.destination | abs) and .merge == "explicit-json" and (.mode | mode)
    and (.before_exists | type == "boolean")
    and (.before_sha256 | sha) and (.before_base64 | b64)
    and (.before_mode == null or (.before_mode | mode))
    and (.after_sha256 | sha) and (.after_base64 | b64) and (.after_mode | mode)
    and (.owned_keys | type == "array" and length > 0
      and all(.[]; type == "object" and exact(["path","value"]) and (.path | json_path)))
    and (.created_paths | type == "array" and all(.[]; json_path));
  type == "object"
  and exact(["artifacts","attachment_id","home_paths","release","renders","schema_version","status","surface"])
  and .schema_version == 1 and .surface == "user" and .status == "prepared"
  and (.attachment_id | uuid) and (.release | semver)
  and (.home_paths | type == "array" and length == 1 and (.[0] | abs))
  and (.artifacts | type == "array" and length > 0 and all(.[]; artifact))
  and (.renders | type == "array" and all(.[]; render)
    and ((map(.destination) | unique | length) == length))
'

_attachment_user_owner_filter='
  def exact($allowed): ((keys_unsorted - $allowed) | length) == 0;
  def controls: test("[[:cntrl:]]");
  def abs: type == "string" and startswith("/") and . != "/" and (endswith("/") | not)
    and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
  def rel: type == "string" and length > 0 and (startswith("/") | not) and (endswith("/") | not)
    and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
  def sha: type == "string" and test("^[a-f0-9]{64}$");
  def b64: type == "string" and test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");
  def mode: type == "string" and test("^0[0-7]{3}$");
  def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
  def semver: type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\\+([0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*))?$");
  def json_path: type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (controls | not));
  def replacement:
    type == "object" and exact(["before_base64","before_mode","before_sha256"])
    and (.before_base64 | b64) and (.before_mode | mode) and (.before_sha256 | sha);
  def symlink_restore:
    replacement
    or (type == "object" and exact(["before_target"]) and (.before_target | abs));
  def artifact:
    type == "object" and (.destination | abs)
    and if .kind == "file" then
      exact(["destination","kind","mode","restore","sha256","source"]) and (.sha256 | sha) and (.mode | mode)
      and (if has("source") then (.source | abs) else true end)
      and (if has("restore") then (.restore | replacement) else true end)
    elif .kind == "symlink" then
      exact(["destination","kind","restore","source","target"]) and (.source | rel) and (.target | abs)
      and (if has("restore") then (.restore | symlink_restore) else true end)
    elif .kind == "parent" then exact(["destination","kind"])
    else false end;
  def render:
    type == "object"
    and exact(["after_base64","after_mode","after_sha256","before_base64","before_exists","before_mode","before_sha256","created_paths","destination","merge","mode","owned_keys"])
    and (.destination | abs) and .merge == "explicit-json" and (.mode | mode)
    and (.before_exists | type == "boolean")
    and (.before_sha256 | sha) and (.before_base64 | b64)
    and (.before_mode == null or (.before_mode | mode))
    and (.after_sha256 | sha) and (.after_base64 | b64) and (.after_mode | mode)
    and (.owned_keys | type == "array" and length > 0
      and all(.[]; type == "object" and exact(["path","value"]) and (.path | json_path)))
    and (.created_paths | type == "array" and all(.[]; json_path));
  type == "object"
  and exact(["artifacts","attachment_id","home_paths","release","renders","schema_version","status","surface"])
  and .schema_version == 1 and .surface == "user" and .status == "committed"
  and (.attachment_id | uuid) and (.release | semver)
  and (.home_paths | type == "array" and length == 1 and (.[0] | abs))
  and (.artifacts | type == "array" and length > 0 and all(.[]; artifact))
  and (.renders | type == "array" and all(.[]; render)
    and ((map(.destination) | unique | length) == length))
'

_attachment_user_snapshots_valid() (
  local file=$1 tmp record encoded expected format actual
  jq -e '
    all(.. | objects | select(.merge? == "explicit-json");
      .after_mode == .mode
      and (if .before_exists
           then .before_mode != null
           else .before_mode == null and .before_base64 == ""
             and .before_sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
           end))
  ' "$file" >/dev/null 2>&1 || return 2
  tmp=$(mktemp "${TMPDIR:-/tmp}/trellis.user-snapshot.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  while IFS= read -r record; do
    encoded=$(printf '%s\n' "$record" | jq -r '.[0]') || return 2
    expected=$(printf '%s\n' "$record" | jq -r '.[1]') || return 2
    format=$(printf '%s\n' "$record" | jq -r '.[2]') || return 2
    if ! printf '%s' "$encoded" | base64 -D 2>/dev/null > "$tmp"; then
      printf '%s' "$encoded" | base64 -d 2>/dev/null > "$tmp" || return 2
    fi
    actual=$(_attachment_hash "$tmp") || return 1
    [ "$actual" = "$expected" ] || return 2
    if [ "$format" = json ]; then
      jq -e 'type == "object"' "$tmp" >/dev/null 2>&1 || return 2
    fi
  done < <(jq -c '
    [
      (.. | objects | select(has("before_base64") and has("before_sha256"))
        | [.before_base64,.before_sha256,(if .merge? == "explicit-json" and .before_exists then "json" else "bytes" end)]),
      (.. | objects | select(has("after_base64") and has("after_sha256"))
        | [.after_base64,.after_sha256,"json"])
    ][]
  ' "$file")
)

_attachment_user_validate_plan_file() {
  _attachment_json_file "$1" || return 2
  jq -e "$_attachment_user_plan_filter" "$1" >/dev/null 2>&1 || return 2
  _attachment_user_snapshots_valid "$1"
}

_attachment_user_owner_json_valid() {
  local file=$1
  [ -e "$file" ] || [ -L "$file" ] || return 5
  [ -f "$file" ] && [ ! -L "$file" ] || return 4
  [ "$(_attachment_mode "$file")" = 600 ] || return 4
  jq -e "$_attachment_user_owner_filter" "$file" >/dev/null 2>&1 || return 2
  _attachment_user_snapshots_valid "$file"
}

_attachment_user_plan_from_journal() {
  jq -cS '{schema_version,surface,status,attachment_id,release,home_paths,artifacts,renders}' "$1"
}

_attachment_user_owner_from_plan() {
  printf '%s\n' "$1" | jq -cS '
    .status = "committed"
    | .artifacts |= map(
        if .kind == "file" then del(.content_base64,.replace)
        elif .kind == "symlink" and has("replace") then
          .replace as $restore | del(.replace) | .restore = $restore
        else . end
      )
  '
}

_attachment_user_repair_binding_valid() {
  printf '%s\n' "$1" | jq -e '
    .original_owner as $owner
    | $owner != null and .owner_override == $owner and .next_owner == null
    and .attachment_id == $owner.attachment_id and .release == $owner.release
    and .home_paths == $owner.home_paths and .renders == []
    and all(.artifacts[];
      . as $artifact
      | .kind == "symlink" and (has("restore") | not) and (has("replace") | not)
      and any($owner.artifacts[]; .kind == "symlink" and del(.restore) == $artifact))
  ' >/dev/null 2>&1 || return 2
}

_attachment_user_journal_json_valid() {
  local file=$1 plan original override next_owner
  [ -f "$file" ] && [ ! -L "$file" ] || return 4
  [ "$(_attachment_mode "$file")" = 600 ] || return 4
  plan=$(_attachment_user_plan_from_journal "$file") || return 2
  printf '%s\n' "$plan" | jq -e "$_attachment_user_plan_filter" >/dev/null 2>&1 || return 2
  jq -e '
    . as $journal
    |
    type == "object"
    and ((keys_unsorted - [
      "applied","artifacts","attachment_id","home_identity","home_paths","identities","operation",
      "original_owner","owner_override","pending","phase","release","removal",
      "renders","schema_version","status","surface","next_owner","trellis_home_identity"
    ]) | length) == 0
    and (.home_identity | type == "string" and test("^[0-9]+:[0-9]+$"))
    and (.trellis_home_identity | type == "string" and test("^[0-9]+:[0-9]+$"))
    and (.operation == "attach" or .operation == "relink" or .operation == "restore" or .operation == "repair")
    and (.phase | type == "number" and floor == . and . >= 0 and . <= ($journal.artifacts | length))
    and (.applied | type == "array") and .applied == .artifacts[0:.phase]
    and (.identities | type == "array" and length == $journal.phase
      and all(.[]; type == "string" and test("^[0-9]+:[0-9]+$")))
    and (.pending == null or (
      .pending | type == "object"
      and ((keys_unsorted - ["artifact","destination_identity","parent_identity","rollback_state","staging_identity","staging_path"]) | length) == 0
      and (.artifact | type == "object")
      and .artifact == $journal.artifacts[$journal.phase]
      and (.parent_identity | type == "string" and test("^[0-9]+:[0-9]+$"))
      and (.staging_path == null or (.staging_path | type == "string" and startswith("/")))
      and (.staging_identity == null or (.staging_identity | type == "string" and test("^[0-9]+:[0-9]+$")))
      and (.destination_identity == null or (.destination_identity | type == "string" and test("^[0-9]+:[0-9]+$")))
      and (.rollback_state == null
        or .rollback_state == "destination"
        or .rollback_state == "stage")
      and (if .rollback_state == "destination"
           then (.destination_identity != null
             and .staging_path != null
             and .staging_identity == .destination_identity)
           elif .rollback_state == "stage" and .destination_identity != null
           then (.staging_path != null and .staging_identity == .destination_identity)
           else true end)
    ))
    and .removal == null
    and (.original_owner == null or (.original_owner | type == "object"))
    and (.owner_override == null or (.owner_override | type == "object"))
    and (.next_owner == null or (.next_owner | type == "object"))
  ' "$file" >/dev/null 2>&1 || return 2
  original=$(jq -c '.original_owner' "$file") || return 2
  if [ "$original" != null ]; then
    printf '%s\n' "$original" | jq -e "$_attachment_user_owner_filter" >/dev/null 2>&1 || return 2
  fi
  override=$(jq -c '.owner_override' "$file") || return 2
  if [ "$override" != null ]; then
    printf '%s\n' "$override" | jq -e "$_attachment_user_owner_filter" >/dev/null 2>&1 || return 2
  fi
  next_owner=$(jq -c '.next_owner' "$file") || return 2
  if [ "$next_owner" != null ]; then
    printf '%s\n' "$next_owner" | jq -e "$_attachment_user_plan_filter" >/dev/null 2>&1 || return 2
  fi
  _attachment_user_snapshots_valid "$file" || return $?
  if [ "$(jq -r '.operation' "$file")" = repair ]; then
    _attachment_user_repair_binding_valid "$(jq -c . "$file")" || return $?
    _attachment_user_validate_collisions "$original" || return 2
    _attachment_user_validate_collisions "$plan" || return 2
  fi
}

_attachment_user_validate_collisions() {
  printf '%s\n' "$1" | jq -e '
    .artifacts as $artifacts
    | [
        range(0; $artifacts | length) as $left
        | range($left + 1; $artifacts | length) as $right
        | ($artifacts[$left].destination | ascii_downcase) as $left_path
        | ($artifacts[$right].destination | ascii_downcase) as $right_path
        | select(
            $left_path == $right_path
            or (($right_path | startswith($left_path + "/")) and $artifacts[$left].kind != "parent")
            or ($left_path | startswith($right_path + "/"))
          )
      ]
    | length == 0
  ' >/dev/null 2>&1
}

_attachment_user_validate_plan_destinations() {
  local home=$1 plan=$2 user_home artifact destination
  user_home=$(_attachment_user_runtime_home) || return $?
  _attachment_user_home_paths_match_json "$plan" || return $?
  while IFS= read -r artifact; do
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    _attachment_user_destination_safe "$user_home" "$home" "$destination" || return $?
  done < <(printf '%s\n' "$plan" | jq -c '.artifacts[]')
}

_attachment_user_validate_sources() {
  local plan=$1 payload=$2 artifact kind source target expected actual
  _attachment_canonical_dir "$payload" || return 4
  while IFS= read -r artifact; do
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
    case "$kind" in
      symlink)
        source=$(printf '%s\n' "$artifact" | jq -r '.source') || return 2
        target=$(printf '%s\n' "$artifact" | jq -r '.target') || return 2
        expected="$payload/$source"
        [ "$target" = "$expected" ] || return 4
        [ -f "$target" ] || [ -d "$target" ] || return 4
        [ ! -L "$target" ] || return 4
        ;;
      file)
        if printf '%s\n' "$artifact" | jq -e 'has("source")' >/dev/null 2>&1; then
          source=$(printf '%s\n' "$artifact" | jq -r '.source') || return 2
          case "$source" in "$payload"/*) ;; *) return 4 ;; esac
          _attachment_canonical_file "$source" || return 4
          expected=$(printf '%s\n' "$artifact" | jq -r '.sha256') || return 2
          actual=$(_attachment_hash "$source") || return 1
          [ "$actual" = "$expected" ] || return 4
        fi
        ;;
    esac
  done < <(printf '%s\n' "$plan" | jq -c '.artifacts[]')
}

_attachment_user_validate_journal_sources() {
  local home=$1 journal=$2 plan release payload release_dir
  plan=$(_attachment_user_plan_from_journal "$journal") || return 2
  release=$(printf '%s\n' "$plan" | jq -r '.release') || return 2
  payload="$home/releases/$release/payload"
  if [ "$(jq -r '.operation' "$journal")" = repair ]; then
    # Recovery must reverify the sealed release, not merely a surviving target.
    command -v release_store_locate >/dev/null 2>&1 || return 4
    release_dir=$(TRELLIS_HOME="$home" release_store_locate "$release") || return $?
    [ "$release_dir/payload" = "$payload" ] || return 4
    _attachment_user_validate_sources "$(jq -c '.original_owner' "$journal")" "$payload" || return $?
  fi
  _attachment_canonical_dir "$payload" || return 4
  _attachment_user_validate_sources "$plan" "$payload"
}

_attachment_user_stage_prefix() {
  local destination=$1 attachment=$2 parent base
  parent=$(dirname "$destination") || return 1
  base=$(basename "$destination") || return 1
  printf '%s/.%s.user-attachment-stage-%s.' "$parent" "$base" "$attachment"
}

_attachment_user_stage_candidate() {
  mktemp -u "$(_attachment_user_stage_prefix "$1" "$2")XXXXXX"
}

_attachment_user_stage_path_valid() {
  local destination=$1 attachment=$2 stage=$3 prefix suffix
  _attachment_valid_absolute "$stage" || return 1
  [ "$(dirname "$destination")" = "$(dirname "$stage")" ] || return 1
  prefix=$(_attachment_user_stage_prefix "$destination" "$attachment") || return 1
  case "$stage" in "$prefix"*) ;; *) return 1 ;; esac
  suffix=${stage#"$prefix"}
  [ -n "$suffix" ] || return 1
  case "$suffix" in */*) return 1 ;; esac
  _attachment_has_controls "$suffix" && return 1
  return 0
}

_attachment_user_artifact_exact() {
  local home=$1 artifact=$2 allow_missing_symlink=${3:-false} destination kind
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 1
  _attachment_user_parent_safe "$home" "$destination" || {
    _attachment_diag "unsafe owned user destination parent: $destination"
    return 1
  }
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 1
    if [ "$allow_missing_symlink" = true ] && [ "$kind" = symlink ]; then return 0; fi
    _attachment_diag "owned user destination is missing: $destination"
    return 1
  fi
  _attachment_path_exact_pinned "$destination" "$artifact" || {
    _attachment_diag "owned user destination was modified: $destination"
    return 1
  }
}

_attachment_user_restore_kind() {
  local artifact=$1 kind
  kind=$(printf '%s\n' "$artifact" | jq -er '
    .restore
    | if (keys | sort) == ["before_target"] then "symlink"
      elif (keys | sort) == ["before_base64","before_mode","before_sha256"] then "file"
      else empty end
  ' 2>/dev/null) || return 2
  printf '%s\n' "$kind"
}

_attachment_user_restore_exact() {
  local destination=$1 artifact=$2 kind expected actual mode target
  kind=$(_attachment_user_restore_kind "$artifact") || return 2
  printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1 || return 2
  case "$kind" in
    file)
      [ -f "$destination" ] && [ ! -L "$destination" ] || return 3
      expected=$(printf '%s\n' "$artifact" | jq -r '.restore.before_sha256') || return 2
      actual=$(_attachment_hash "$destination") || return 1
      [ "$actual" = "$expected" ] || return 3
      mode=$(printf '%s\n' "$artifact" | jq -r '.restore.before_mode') || return 2
      _attachment_mode_matches "$destination" "$mode" || return 3
      ;;
    symlink)
      [ -L "$destination" ] || return 3
      target=$(printf '%s\n' "$artifact" | jq -r '.restore.before_target') || return 2
      _attachment_symlink_matches "$destination" "$target" || return 3
      ;;
    *) return 2 ;;
  esac
}

_attachment_user_json_keys_match() {
  attach_detach_json_keys_match "$1" "$2"
}

_attachment_user_verify_owner_artifacts_impl() {
  local home=$1 owner=$2 allow_missing_symlinks=${3:-false} canonical user_home artifact destination kind render keys
  canonical=$(_attachment_user_owner_path "$home")
  [ "$owner" = "$canonical" ] || return 2
  _attachment_user_owner_json_valid "$owner" || return $?
  _attachment_user_home_paths_match_file "$owner" || return $?
  user_home=$(_attachment_user_runtime_home) || return $?
  while IFS= read -r artifact; do
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
    _attachment_user_destination_safe "$user_home" "$home" "$destination" || return $?
    if [ "$kind" = file ] && jq -e --arg destination "$destination" \
      'any(.renders[]; .destination == $destination)' "$owner" >/dev/null 2>&1; then
      continue
    fi
    _attachment_user_artifact_exact "$user_home" "$artifact" "$allow_missing_symlinks" || return 3
    if [ "$kind" = parent ]; then
      _attachment_mode_matches "$destination" 0700 || return 3
    fi
  done < <(jq -c '.artifacts[]' "$owner")
  while IFS= read -r render; do
    destination=$(printf '%s\n' "$render" | jq -r '.destination') || return 2
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 3
    _attachment_user_parent_safe "$user_home" "$destination" || return 3
    _attachment_mode_matches "$destination" "$(printf '%s\n' "$render" | jq -r '.after_mode')" || return 3
    keys=$(printf '%s\n' "$render" | jq -c '.owned_keys') || return 2
    _attachment_user_json_keys_match "$destination" "$keys" || return 3
  done < <(jq -c '.renders[]' "$owner")
}

_attachment_user_owner_matches_plan() {
  local owner=$1 plan=$2 expected actual
  _attachment_user_owner_json_valid "$owner" || return $?
  expected=$(_attachment_user_owner_from_plan "$plan") || return 2
  actual=$(jq -cS . "$owner") || return 2
  [ "$actual" = "$expected" ] || return 3
}

_attachment_user_set_pending() {
  local journal=$1 artifact=$2 stage=$3 destination parent identity destination_identity="" next kind operation
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  parent=$(dirname "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  identity=$(_attachment_fs_identity "$parent") || return 1
  if [ "$kind" = parent ] && { [ -e "$destination" ] || [ -L "$destination" ]; }; then
    jq -e --arg destination "$destination" '
      (.operation == "relink" or .operation == "restore")
      and any(.original_owner.artifacts[]?; .kind == "parent" and .destination == $destination)
    ' "$journal" >/dev/null 2>&1 || return 3
    [ -d "$destination" ] && [ ! -L "$destination" ] || return 3
    destination_identity=$(_attachment_fs_identity "$destination") || return 1
  fi
  if [ "$kind" != parent ] &&
     printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1; then
    operation=$(jq -r '.operation' "$journal") || return 2
    case "$operation" in
      relink|restore)
        if [ -e "$destination" ] || [ -L "$destination" ]; then
          _attachment_user_restore_exact "$destination" "$artifact" || return $?
        fi
        ;;
    esac
  fi
  next=$(trellis_jq -cS --argjson artifact "$artifact" --arg stage "$stage" --arg identity "$identity" \
    --arg destination_identity "$destination_identity" '
    .pending = {
      artifact:$artifact,
      staging_path:(if $stage == "" then null else $stage end),
      staging_identity:null,
      destination_identity:(if $destination_identity == "" then null else $destination_identity end),
      parent_identity:$identity
    }
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_finalize_pending() {
  local journal=$1 artifact=$2 identity next
  identity=$(jq -r '.pending.destination_identity // empty' "$journal") || return 2
  [ -n "$identity" ] || return 3
  next=$(trellis_jq -cS --argjson artifact "$artifact" --arg identity "$identity" '
    .applied += [$artifact]
    | .identities += [$identity]
    | .phase = (.applied | length)
    | .pending = null
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_pending_stage_owned() {
  local pending=$1 artifact=$2 stage identity kind
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 1
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 1
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 1
  [ -n "$stage" ] && [ -n "$identity" ] || return 1
  _attachment_identity_matches "$stage" "$identity" "$kind" || return 1
  _attachment_path_exact_pinned "$stage" "$artifact"
}
_attachment_user_complete_owned_file_stage() (
  local artifact=$1 stage=$2 identity=$3 mode source content expected actual fd_identity
  _attachment_identity_matches "$stage" "$identity" file || return 3
  exec 9<>"$stage" || return 3
  fd_identity=$(_attachment_fd_fs_identity /dev/fd/9) || { exec 9>&-; return 1; }
  [ "$fd_identity" = "$identity" ] || { exec 9>&-; return 3; }
  : > /dev/fd/9 || { exec 9>&-; return 1; }
  mode=$(printf '%s\n' "$artifact" | jq -r '.mode') || { exec 9>&-; return 2; }
  chmod "${mode#0}" /dev/fd/9 || { exec 9>&-; return 1; }
  if printf '%s\n' "$artifact" | jq -e 'has("source")' >/dev/null 2>&1; then
    source=$(printf '%s\n' "$artifact" | jq -r '.source') || { exec 9>&-; return 2; }
    cat "$source" >&9 || { exec 9>&-; return 1; }
  else
    content=$(printf '%s\n' "$artifact" | jq -r '.content_base64') || { exec 9>&-; return 2; }
    if printf '%s' "$content" | base64 -D 2>/dev/null >&9; then
      :
    elif printf '%s' "$content" | base64 -d 2>/dev/null >&9; then
      :
    else
      exec 9>&-
      return 1
    fi
  fi
  exec 9>&-
  _attachment_identity_matches "$stage" "$identity" file || return 3
  expected=$(printf '%s\n' "$artifact" | jq -r '.sha256') || return 2
  actual=$(_attachment_hash "$stage") || return 1
  [ "$actual" = "$expected" ] || return 3
  _attachment_mode_matches "$stage" "$mode" || return 3
)

_attachment_user_pending_destination_owned() {
  local pending=$1 artifact=$2 destination identity kind
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 1
  identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // empty') || return 1
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 1
  [ -n "$identity" ] || return 1
  _attachment_identity_matches "$destination" "$identity" "$kind" || return 1
  _attachment_path_exact_pinned "$destination" "$artifact"
}

_attachment_user_publish_pending() {
  local home=$1 journal=$2 pending artifact destination kind stage attachment parent expected_parent identity rc operation
  pending=$(jq -c '.pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  parent=$(dirname "$destination") || return 2
  _attachment_user_parent_safe "$(_attachment_user_runtime_home)" "$destination" || return 3
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  if [ "$kind" = parent ]; then
    stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
    identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // empty') || return 2
    if [ -n "$identity" ]; then
      _attachment_identity_matches "$destination" "$identity" parent || return 3
    elif [ -z "$stage" ]; then
      if [ -e "$destination" ] || [ -L "$destination" ]; then return 3; fi
      _attachment_create_directory_destination "$journal" "$artifact" "$destination" || return $?
      pending=$(jq -c '.pending' "$journal") || return 2
    else
      _attachment_user_stage_path_valid "$destination" "$attachment" "$stage" || return 2
      identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
      if [ -z "$identity" ]; then
        if [ -e "$stage" ] || [ -L "$stage" ]; then
          _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" parent || return $?
        fi
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
        _attachment_create_directory_stage "$journal" "$artifact" "$stage" || return $?
        pending=$(jq -c '.pending' "$journal") || return 2
        identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity') || return 2
      fi
      if [ -e "$stage" ] || [ -L "$stage" ]; then
        _attachment_publish_directory_stage "$pending" "$artifact" "$stage" "$destination" || return $?
      else
        _attachment_identity_matches "$destination" "$identity" parent || return 3
      fi
      _attachment_set_pending_identity "$journal" destination_identity "$identity" || return $?
      pending=$(jq -c '.pending' "$journal") || return 2
    fi
    _attachment_user_pending_destination_owned "$pending" "$artifact" || return 3
    _attachment_mode_matches "$destination" 0700 || return 3
    [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
    _attachment_fault_before_user_finalize_pending || return $?
    _attachment_user_finalize_pending "$journal" "$artifact"
    return $?
  fi
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  _attachment_user_stage_path_valid "$destination" "$attachment" "$stage" || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // empty') || return 2
  if [ "$(printf '%s\n' "$pending" | jq -r '.staging_identity == null')" = true ]; then
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" || return $?
    fi
    case "$kind" in
      file) _attachment_create_file_stage "$journal" "$artifact" "$stage" || return $? ;;
      symlink) _attachment_create_symlink_stage "$journal" "$artifact" "$stage" || return $? ;;
      *) return 2 ;;
    esac
    pending=$(jq -c '.pending' "$journal") || return 2
  fi
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    if ! _attachment_user_pending_stage_owned "$pending" "$artifact"; then
      [ "$kind" = file ] || return 3
      identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
      [ -n "$identity" ] || return 3
      _attachment_user_complete_owned_file_stage "$artifact" "$stage" "$identity" || return $?
      pending=$(jq -c '.pending' "$journal") || return 2
      _attachment_user_pending_stage_owned "$pending" "$artifact" || return 3
    fi
  fi
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = user-replace-staged ] &&
     printf '%s\n' "$artifact" | jq -e 'has("replace") and (has("restore") | not)' >/dev/null 2>&1; then
    return 5
  fi
  if [ "$(printf '%s\n' "$pending" | jq -r '.destination_identity == null')" = true ]; then
    operation=$(jq -r '.operation' "$journal") || return 2
    if { [ "$operation" = relink ] || [ "$operation" = restore ]; } &&
       printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1 &&
       { [ -e "$destination" ] || [ -L "$destination" ]; }; then
      if _attachment_user_pending_stage_owned "$pending" "$artifact"; then
        _attachment_publish_stage_restore "$pending" "$artifact" "$stage" "$destination" || return $?
      else
        identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
        _attachment_identity_matches "$destination" "$identity" "$kind" || return 3
        _attachment_path_exact_pinned "$destination" "$artifact" || return 3
      fi
    elif printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        if _attachment_user_pending_stage_owned "$pending" "$artifact"; then
          _attachment_publish_stage_replace "$pending" "$artifact" "$stage" "$destination" || return $?
        else
          identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
          _attachment_identity_matches "$destination" "$identity" "$kind" || return 3
          _attachment_path_exact_pinned "$destination" "$artifact" || return 3
        fi
      else
        return 3
      fi
    else
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
        _attachment_identity_matches "$destination" "$identity" "$kind" || return 3
        _attachment_path_exact_pinned "$destination" "$artifact" || return 3
      else
        _attachment_publish_stage_link "$pending" "$artifact" "$stage" "$destination" || return $?
      fi
    fi
    identity=$(_attachment_fs_identity "$destination") || return 1
    _attachment_set_pending_identity "$journal" destination_identity "$identity" || return $?
    pending=$(jq -c '.pending' "$journal") || return 2
  else
    _attachment_user_pending_destination_owned "$pending" "$artifact" || return 3
  fi
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
    _attachment_user_remove_exact "$stage" "$artifact" "$identity" "$expected_parent" || return $?
  fi
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  _attachment_fault_before_user_finalize_pending || return $?
  _attachment_user_finalize_pending "$journal" "$artifact"
}

_attachment_user_restore_replaced_file() (
  local destination=$1 artifact=$2 identity=$3 parent base tmp content mode expected kind parent_identity
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  parent=$(dirname "$destination") || return 2
  base=$(basename "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  parent_identity=$(_attachment_fs_identity "$parent") || return 1
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$parent_identity" ] || return 3
  destination="./$base"
  if _attachment_replace_before_matches "$destination" "$artifact"; then return 0; fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    _attachment_identity_matches "$destination" "$identity" "$kind" || return 3
    _attachment_path_exact_pinned "$destination" "$artifact" || return 3
  fi
  tmp=$(mktemp "./.${base}.user-attachment-restore.XXXXXX") || return 1
  content=$(printf '%s\n' "$artifact" | jq -r '.replace.before_base64') || { rm -f "$tmp"; return 2; }
  mode=$(printf '%s\n' "$artifact" | jq -r '.replace.before_mode') || { rm -f "$tmp"; return 2; }
  printf '%s' "$content" | base64 -D 2>/dev/null > "$tmp" ||
    printf '%s' "$content" | base64 -d 2>/dev/null > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod "${mode#0}" "$tmp" || { rm -f "$tmp"; return 1; }
  expected=$(printf '%s\n' "$artifact" | jq -r '.replace.before_sha256') || { rm -f "$tmp"; return 2; }
  [ "$(_attachment_hash "$tmp")" = "$expected" ] || { rm -f "$tmp"; return 2; }
  if _attachment_replace_before_matches "$destination" "$artifact"; then
    rm -f "$tmp"
    return 0
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    _attachment_identity_matches "$destination" "$identity" "$kind" || { rm -f "$tmp"; return 3; }
    _attachment_path_exact_pinned "$destination" "$artifact" || { rm -f "$tmp"; return 3; }
  fi
  mv -f -- "$tmp" "$destination" || { rm -f "$tmp"; return 1; }
  [ "$(_attachment_fs_identity .)" = "$parent_identity" ] || return 3
  _attachment_replace_before_matches "$destination" "$artifact"
)

_attachment_move_pinned() (
  local parent=$1 expected_parent=$2 source=$3 destination=$4 identity=$5 kind=$6 replace=${7:-false}
  local replaced_identity=${8:-} replaced_kind=${9:-} source_base destination_base
  [ "$(dirname "$source")" = "$parent" ] && [ "$(dirname "$destination")" = "$parent" ] || return 2
  source_base=$(basename "$source") || return 2
  destination_base=$(basename "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  _attachment_identity_matches "./$source_base" "$identity" "$kind" || return 3
  if [ "$replace" = true ]; then
    [ -n "$replaced_identity" ] && [ -n "$replaced_kind" ] || return 2
    _attachment_identity_matches "./$destination_base" "$replaced_identity" "$replaced_kind" || return 3
  else
    [ ! -e "./$destination_base" ] && [ ! -L "./$destination_base" ] || return 3
  fi
  if [ "$replace" = true ]; then
    mv -f -- "./$source_base" "./$destination_base" || return 1
  else
    mv -- "./$source_base" "./$destination_base" || return 1
  fi
  _attachment_identity_matches "./$destination_base" "$identity" "$kind" || return 3
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_user_remove_exact() (
  local destination=$1 artifact=$2 identity=$3 expected_parent=${4:-} kind parent base
  parent=$(dirname "$destination") || return 2
  base=$(basename "$destination") || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  _attachment_canonical_dir "$parent" || return 3
  if [ -z "$expected_parent" ]; then
    expected_parent=$(_attachment_fs_identity "$parent") || return 1
  fi
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  _attachment_identity_matches "./$base" "$identity" "$kind" || return 3
  _attachment_path_exact "./$base" "$artifact" || return 3
  case "$kind" in
    parent) rmdir "./$base" 2>/dev/null || return 3 ;;
    file|symlink) rm "./$base" || return 1 ;;
    *) return 2 ;;
  esac
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_user_restore_adopted() (
  local destination=$1 artifact=$2 identity=$3 kind parent base expected_parent restore_kind tmp content mode expected target
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  _attachment_identity_matches "$destination" "$identity" "$kind" || return 3
  _attachment_path_exact_pinned "$destination" "$artifact" || return 3
  restore_kind=$(_attachment_user_restore_kind "$artifact") || return 2
  parent=$(dirname "$destination") || return 2
  base=$(basename "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  expected_parent=$(_attachment_fs_identity "$parent") || return 1
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  case "$restore_kind" in
    file)
      tmp=$(mktemp "./.${base}.user-attachment-restore.XXXXXX") || return 1
      content=$(printf '%s\n' "$artifact" | jq -r '.restore.before_base64') || { rm -f "$tmp"; return 2; }
      mode=$(printf '%s\n' "$artifact" | jq -r '.restore.before_mode') || { rm -f "$tmp"; return 2; }
      if ! printf '%s' "$content" | base64 -D 2>/dev/null > "$tmp"; then
        printf '%s' "$content" | base64 -d 2>/dev/null > "$tmp" || { rm -f "$tmp"; return 1; }
      fi
      chmod "${mode#0}" "$tmp" || { rm -f "$tmp"; return 1; }
      expected=$(printf '%s\n' "$artifact" | jq -r '.restore.before_sha256') || { rm -f "$tmp"; return 2; }
      [ "$(_attachment_hash "$tmp")" = "$expected" ] || { rm -f "$tmp"; return 2; }
      ;;
    symlink)
      tmp=$(mktemp -u "./.${base}.user-attachment-restore.XXXXXX") || return 1
      target=$(printf '%s\n' "$artifact" | jq -r '.restore.before_target') || return 2
      ln -sn -- "$target" "$tmp" 2>/dev/null || return 3
      ;;
    *) return 2 ;;
  esac
  _attachment_identity_matches "./$base" "$identity" "$kind" || { rm -f "$tmp"; return 3; }
  _attachment_path_exact "./$base" "$artifact" || { rm -f "$tmp"; return 3; }
  mv -f -- "$tmp" "./$base" || { rm -f "$tmp"; return 1; }
  _attachment_user_restore_exact "./$base" "$artifact" || return $?
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_user_parent_from_original() {
  local journal=$1 artifact=$2
  printf '%s\n' "$artifact" | jq -e '.kind == "parent"' >/dev/null 2>&1 || return 1
  trellis_jq -e --argjson artifact "$artifact" '
    .original_owner != null and any(.original_owner.artifacts[]?; . == $artifact)
  ' "$journal" >/dev/null 2>&1
}
_attachment_user_rollback_replace_conflict() {
  local home=$1 journal=$2 operation=$3 destination=$4 artifact=$5 identity=$6 release command repair
  local expected_snapshot expected_mode kind quoted_destination quoted_snapshot backup quoted_backup
  release=$(jq -r '.release' "$journal") || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  printf -v quoted_destination '%q' "$destination"
  case "$operation" in
    attach) command=attach ;;
    relink|restore) command=relink ;;
    *) return 2 ;;
  esac
  expected_snapshot=$(printf '%s\n' "$artifact" | jq -r '.replace.before_base64') || return 2
  expected_mode=$(printf '%s\n' "$artifact" | jq -r '.replace.before_mode') || return 2
  printf -v quoted_snapshot '%q' "$expected_snapshot"
  backup="${destination}.trellis-recovery-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  printf -v quoted_backup '%q' "$backup"
  # Copy the current destination aside before the snapshot rewrite. The bytes
  # named in the message below may be user edits that exist nowhere else.
  repair=$(printf 'cp -p -- %s %s && rm -f -- %s && { printf %%s %s | base64 -D 2>/dev/null || printf %%s %s | base64 -d; } > %s && chmod %s %s' \
    "$quoted_destination" "$quoted_backup" "$quoted_destination" \
    "$quoted_snapshot" "$quoted_snapshot" "$quoted_destination" \
    "${expected_mode#0}" "$quoted_destination")
  if [ -n "$identity" ]; then
    printf 'trellis: user attachment recovery conflict: leave journal %s in place; managed %s %s no longer has its pinned filesystem identity/content. Unknown bytes are still at the destination; the remedy first copies them to %s, then restores the journaled regular-file snapshot instead.\n' \
      "$journal" "$kind" "$destination" "$backup" >&2
  else
    printf 'trellis: user attachment recovery conflict: leave journal %s in place; pending replacement %s is neither its journaled before snapshot nor a journal-pinned managed destination. Unknown bytes are still at the destination; the remedy first copies them to %s, then restores the journaled regular-file snapshot instead.\n' \
      "$journal" "$destination" "$backup" >&2
  fi
  printf 'trellis: user attachment recovery remedy: %s\n' "$repair" >&2
  printf 'trellis: then rerun: trellis %s --user --home %q --release %q\n' \
    "$command" "$home" "$release" >&2
  return 3
}

_attachment_user_rollback_clear_pending() {
  local journal=$1 artifact=$2 next
  next=$(trellis_jq -cS --argjson artifact "$artifact" '
    . as $current
    | if ($current.pending != null and $current.pending.artifact == $artifact)
      then .pending = null
      else error("invalid user rollback pending progress")
      end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_rollback_begin_pending_destination() {
  local journal=$1 artifact=$2 destination attachment stage state pending next
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  stage=$(jq -r '.pending.staging_path // empty' "$journal") || return 2
  state=$(jq -r '.pending.rollback_state // empty' "$journal") || return 2
  if [ -z "$stage" ]; then
    stage=$(_attachment_user_stage_candidate "$destination" "$attachment") || return 1
  fi
  _attachment_user_stage_path_valid "$destination" "$attachment" "$stage" || return 2
  if [ -z "$state" ] && { [ -e "$stage" ] || [ -L "$stage" ]; }; then
    pending=$(jq -c '.pending' "$journal") || return 2
    _attachment_user_pending_stage_owned "$pending" "$artifact" || return 3
    [ "$(printf '%s\n' "$pending" | jq -r '.staging_identity')" = \
      "$(printf '%s\n' "$pending" | jq -r '.destination_identity')" ] || return 3
  fi
  next=$(trellis_jq -cS --argjson artifact "$artifact" --arg stage "$stage" '
    . as $current
    | if ($current.pending != null
          and $current.pending.artifact == $artifact
          and $current.pending.destination_identity != null
          and (($current.pending.rollback_state // null) == null
               or $current.pending.rollback_state == "destination")
          and ($current.pending.staging_path == null or $current.pending.staging_path == $stage)
          and ($current.pending.staging_identity == null
               or $current.pending.staging_identity == $current.pending.destination_identity))
      then .pending.staging_path = $stage
        | .pending.staging_identity = .pending.destination_identity
        | .pending.rollback_state = "destination"
      else error("invalid user rollback pending destination intent")
      end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_rollback_record_pending_destination_stage() {
  local journal=$1 artifact=$2 pending destination next
  pending=$(jq -c '.pending' "$journal") || return 2
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
  _attachment_user_rollback_pending_parent_matches "$pending" "$destination" || return $?
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
  _attachment_user_pending_stage_owned "$pending" "$artifact" || return 3
  next=$(trellis_jq -cS --argjson artifact "$artifact" '
    . as $current
    | if ($current.pending != null
          and $current.pending.artifact == $artifact
          and $current.pending.destination_identity != null
          and (($current.pending.rollback_state // null) == "destination")
          and $current.pending.staging_path != null
          and $current.pending.staging_identity == $current.pending.destination_identity)
      then .pending.rollback_state = "stage"
      else error("invalid user rollback pending destination stage")
      end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_rollback_begin_pending_stage() {
  local journal=$1 artifact=$2 next
  next=$(trellis_jq -cS --argjson artifact "$artifact" '
    . as $current
    | if ($current.pending != null
          and $current.pending.artifact == $artifact
          and $current.pending.destination_identity == null
          and (($current.pending.rollback_state // null) == null
               or $current.pending.rollback_state == "stage"))
      then .pending.rollback_state = (.pending.rollback_state // "stage")
      else error("invalid user rollback pending stage intent")
      end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_rollback_pending_parent_matches() {
  local pending=$1 destination=$2 expected_parent parent
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity // empty') || return 2
  [ -n "$expected_parent" ] || return 2
  parent=$(dirname "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
}

_attachment_user_rollback_pending_destination_undone() {
  local pending=$1 artifact=$2 destination=$3
  _attachment_user_rollback_pending_parent_matches "$pending" "$destination" || return $?
  if printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1; then
    _attachment_user_restore_exact "$destination" "$artifact"
  elif printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
    _attachment_replace_before_matches "$destination" "$artifact"
  else
    return 1
  fi
}

_attachment_user_rollback_pending_stage() {
  local journal=$1 pending=$2 artifact=$3 stage identity kind destination destination_identity state expected_parent
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
  destination_identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // empty') || return 2
  state=$(printf '%s\n' "$pending" | jq -r '.rollback_state // empty') || return 2
  if [ -n "$destination_identity" ]; then
    [ "$state" = stage ] || return 3
    [ -n "$stage" ] && [ -n "$identity" ] || return 2
    _attachment_user_rollback_pending_parent_matches "$pending" "$destination" || return $?
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
    [ ! -e "$stage" ] && [ ! -L "$stage" ] && return 0
    _attachment_user_pending_stage_owned "$pending" "$artifact" || return 3
    expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
    _attachment_user_remove_exact "$stage" "$artifact" "$identity" "$expected_parent"
    return $?
  fi
  [ -n "$stage" ] || return 0
  [ ! -e "$stage" ] && [ ! -L "$stage" ] && return 0
  case "$state" in
    '') _attachment_user_rollback_begin_pending_stage "$journal" "$artifact" || return $? ;;
    stage) ;;
    *) return 3 ;;
  esac
  if [ -n "$identity" ]; then
    expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
    _attachment_user_remove_exact "$stage" "$artifact" "$identity" "$expected_parent"
  else
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
    _attachment_reclaim_unidentified_stage "$stage" "$(printf '%s\n' "$pending" | jq -r '.parent_identity')" "$kind"
  fi
}

_attachment_user_rollback_pending_destination() {
  local home=$1 journal=$2 operation=$3 pending=$4 artifact=$5 destination=$6 identity=$7
  local state expected_parent parent stage kind
  [ -n "$identity" ] || return 2
  state=$(printf '%s\n' "$pending" | jq -r '.rollback_state // empty') || return 2
  [ "$state" = destination ] || return 2
  if _attachment_user_rollback_pending_destination_undone "$pending" "$artifact" "$destination"; then
    return 0
  fi
  if printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1; then
    _attachment_user_restore_adopted "$destination" "$artifact" "$identity" || return $?
  elif printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
    _attachment_user_rollback_restore_replaced_file "$home" "$journal" "$operation" \
      "$destination" "$artifact" "$identity" || return $?
  else
    stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
    expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
    parent=$(dirname "$destination") || return 2
    _attachment_user_rollback_pending_parent_matches "$pending" "$destination" || return $?
    [ -n "$stage" ] || return 2
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      _attachment_user_pending_destination_owned "$pending" "$artifact" || return 3
      if [ -e "$stage" ] || [ -L "$stage" ]; then
        _attachment_user_pending_stage_owned "$pending" "$artifact" || return 3
        [ "$(printf '%s\n' "$pending" | jq -r '.staging_identity')" = "$identity" ] || return 3
        _attachment_user_remove_exact "$destination" "$artifact" "$identity" "$expected_parent" || return $?
      else
        _attachment_move_pinned "$parent" "$expected_parent" "$destination" "$stage" "$identity" "$kind" || return $?
      fi
    else
      _attachment_user_pending_stage_owned "$pending" "$artifact" || return 3
    fi
    _attachment_fault_after_user_rollback_pending_destination || return $?
    _attachment_user_rollback_record_pending_destination_stage "$journal" "$artifact" || return $?
    return 0
  fi
  return 0
}

_attachment_user_rollback_pending_replace() {
  local home=$1 journal=$2 operation=$3 pending=$4 artifact=$5 destination=$6
  local identity stage stage_identity expected_parent attachment
  identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // .staging_identity // empty') || return 2
  _attachment_user_rollback_restore_replaced_file "$home" "$journal" "$operation" \
    "$destination" "$artifact" "$identity" || return $?
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
  if [ -n "$stage" ]; then
    attachment=$(jq -r '.attachment_id' "$journal") || return 2
    _attachment_user_stage_path_valid "$destination" "$attachment" "$stage" || return 2
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      _attachment_user_pending_stage_owned "$pending" "$artifact" || return 3
      stage_identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
      expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
      _attachment_user_remove_exact "$stage" "$artifact" "$stage_identity" "$expected_parent" || return $?
    fi
  fi
}

_attachment_user_rollback_finish_applied() {
  local journal=$1 index=$2 artifact=$3 next
  next=$(trellis_jq -cS --argjson index "$index" --argjson artifact "$artifact" '
    . as $current
    | if ($current.pending == null
          and $current.phase == ($index + 1)
          and $current.artifacts[$index] == $artifact
          and $current.applied[$index] == $artifact
          and (($current.identities | length) == $current.phase))
      then .phase = $index
        | .applied = .artifacts[0:$index]
        | .identities = .identities[0:$index]
      else error("invalid user rollback applied progress")
      end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_fault_after_user_rollback_phase() {
  local phase=$1
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = "user-rollback-$phase" ]; then
    ATTACHMENT_FAULT_PHASE=
    export ATTACHMENT_FAULT_PHASE
    return 5
  fi
  return 0
}

_attachment_fault_after_user_rollback_replace_restore() {
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = user-rollback-replace-restored ]; then
    ATTACHMENT_FAULT_PHASE=
    export ATTACHMENT_FAULT_PHASE
    return 5
  fi
  return 0
}

_attachment_fault_before_user_finalize_pending() {
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = user-pending-finalize ]; then
    ATTACHMENT_FAULT_PHASE=
    export ATTACHMENT_FAULT_PHASE
    return 5
  fi
  return 0
}

_attachment_fault_after_user_rollback_pending_destination() {
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = user-rollback-pending-destination ]; then
    ATTACHMENT_FAULT_PHASE=
    export ATTACHMENT_FAULT_PHASE
    return 5
  fi
  return 0
}

_attachment_fault_after_user_rollback_pending() {
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = user-rollback-pending ]; then
    ATTACHMENT_FAULT_PHASE=
    export ATTACHMENT_FAULT_PHASE
    return 5
  fi
  return 0
}

_attachment_user_rollback_replace_destination_recoverable() {
  local destination=$1 artifact=$2 identity=$3 kind
  if _attachment_replace_before_matches "$destination" "$artifact"; then return 0; fi
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then return 0; fi
  [ -n "$identity" ] || return 1
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 1
  _attachment_identity_matches "$destination" "$identity" "$kind" &&
    _attachment_path_exact_pinned "$destination" "$artifact"
}

_attachment_user_rollback_preflight_replacements() {
  local home=$1 journal=$2 operation=$3 pending artifact destination identity phase index
  pending=$(jq -c '.pending' "$journal") || return 2
  if [ "$pending" != null ]; then
    artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
    if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
      identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // .staging_identity // empty') || return 2
      if ! _attachment_user_rollback_replace_destination_recoverable \
        "$destination" "$artifact" "$identity"; then
        _attachment_user_rollback_replace_conflict "$home" "$journal" "$operation" \
          "$destination" "$artifact" "$identity"
        return $?
      fi
    fi
  fi
  phase=$(jq -r '.phase' "$journal") || return 2
  index=$phase
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    artifact=$(jq -c --argjson index "$index" '.artifacts[$index]' "$journal") || return 2
    printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1 || continue
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    identity=$(jq -r --argjson index "$index" '.identities[$index]' "$journal") || return 2
    if ! _attachment_user_rollback_replace_destination_recoverable \
      "$destination" "$artifact" "$identity"; then
      _attachment_user_rollback_replace_conflict "$home" "$journal" "$operation" \
        "$destination" "$artifact" "$identity"
      return $?
    fi
  done
}

_attachment_user_rollback_restore_replaced_file() {
  local home=$1 journal=$2 operation=$3 destination=$4 artifact=$5 identity=$6 rc
  if _attachment_replace_before_matches "$destination" "$artifact"; then return 0; fi
  _attachment_user_restore_replaced_file "$destination" "$artifact" "$identity"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    _attachment_user_rollback_replace_conflict "$home" "$journal" "$operation" \
      "$destination" "$artifact" "$identity"
    return $?
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  _attachment_fault_after_user_rollback_replace_restore
}

_attachment_user_repair_remove_pinned() {
  local home=$1 destination=$2 artifact=$3 identity=$4 expected_parent=${5:-} user_home
  user_home=$(_attachment_user_runtime_home) || return $?
  if ! _attachment_user_destination_safe "$user_home" "$home" "$destination" ||
     ! _attachment_user_parent_safe "$user_home" "$destination"; then
    _attachment_diag "repair rollback preserved unsafe user path: $destination"
    return 0
  fi
  [ -e "$destination" ] || [ -L "$destination" ] || return 0
  if [ -z "$identity" ] ||
     ! _attachment_identity_matches "$destination" "$identity" symlink ||
     ! _attachment_path_exact_pinned "$destination" "$artifact"; then
    _attachment_diag "repair rollback preserved unpinned or modified user path: $destination"
    return 0
  fi
  if [ -n "$expected_parent" ] &&
     [ "$(_attachment_fs_identity "$(dirname "$destination")")" != "$expected_parent" ]; then
    _attachment_diag "repair rollback preserved changed user parent: $destination"
    return 0
  fi
  _attachment_user_remove_exact "$destination" "$artifact" "$identity" "$expected_parent"
}

_attachment_user_discard_repair_locked() {
  local home=$1 journal=$2 pending artifact destination identity stage parent attachment phase index rc=0
  [ "$journal" = "$(_attachment_user_journal_path "$home")" ] || return 2
  _attachment_user_journal_json_valid "$journal" || return $?
  [ "$(jq -r '.operation' "$journal")" = repair ] || return 2
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  # No owner/source verification: removing a pinned link needs neither a live
  # target nor an unchanged render. Foreign replacements are never ours to undo.
  pending=$(jq -c '.pending' "$journal") || return 2
  if [ "$pending" != null ]; then
    artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // .staging_identity // empty') || return 2
    parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
    _attachment_user_repair_remove_pinned "$home" "$destination" "$artifact" "$identity" "$parent" || rc=$?
    stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
    if [ -n "$stage" ]; then
      attachment=$(jq -r '.attachment_id' "$journal") || return 2
      if _attachment_user_stage_path_valid "$destination" "$attachment" "$stage"; then
        identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty') || return 2
        if [ -n "$identity" ]; then
          _attachment_user_repair_remove_pinned "$home" "$stage" "$artifact" "$identity" "$parent" || rc=$?
        else
          _attachment_reclaim_unidentified_stage "$stage" "$parent" symlink || rc=$?
        fi
      else
        _attachment_diag "repair rollback preserved invalid stage path: $stage"
      fi
    fi
  fi
  phase=$(jq -r '.phase' "$journal") || return 2
  index=$phase
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    artifact=$(jq -c --argjson index "$index" '.artifacts[$index]' "$journal") || return 2
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    identity=$(jq -r --argjson index "$index" '.identities[$index]' "$journal") || return 2
    _attachment_user_repair_remove_pinned "$home" "$destination" "$artifact" "$identity" || rc=$?
  done
  # A failed repair must not block every subsequent user lifecycle operation.
  rm "$journal" || return 1
  return "$rc"
}

_attachment_user_rollback_locked() {
  local home=$1 journal=$2 pending artifact destination identity pending_state stage phase index operation conflict=0
  _attachment_user_journal_json_valid "$journal" || return $?
  operation=$(jq -r '.operation' "$journal") || return 2
  if [ "$operation" = repair ]; then
    _attachment_user_discard_repair_locked "$home" "$journal"
    return $?
  fi
  _attachment_user_rollback_preflight_replacements "$home" "$journal" "$operation" || return $?
  pending=$(jq -c '.pending' "$journal") || return 2
  if [ "$pending" != null ]; then
    artifact=$(printf '%s\n' "$pending" | jq -c '.artifact') || return 2
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    identity=$(printf '%s\n' "$pending" | jq -r '.destination_identity // empty') || return 2
    pending_state=$(printf '%s\n' "$pending" | jq -r '.rollback_state // empty') || return 2
    if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      _attachment_user_rollback_pending_replace "$home" "$journal" "$operation" \
        "$pending" "$artifact" "$destination" || return $?
    elif [ -n "$identity" ]; then
      if _attachment_user_parent_from_original "$journal" "$artifact"; then
        _attachment_identity_matches "$destination" "$identity" parent || return 3
        _attachment_path_exact_pinned "$destination" "$artifact" || return 3
        stage=$(printf '%s\n' "$pending" | jq -r '.staging_path // empty') || return 2
        [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 3
      elif [ "$pending_state" = stage ]; then
        _attachment_user_rollback_pending_stage "$journal" "$pending" "$artifact" || return $?
      elif [ -z "$pending_state" ] || [ "$pending_state" = destination ]; then
        _attachment_user_rollback_begin_pending_destination "$journal" "$artifact" || return $?
        pending=$(jq -c '.pending' "$journal") || return 2
        _attachment_user_rollback_pending_destination "$home" "$journal" "$operation" \
          "$pending" "$artifact" "$destination" "$identity" || return $?
        pending=$(jq -c '.pending' "$journal") || return 2
        pending_state=$(printf '%s\n' "$pending" | jq -r '.rollback_state // empty') || return 2
        if [ "$pending_state" = stage ]; then
          _attachment_user_rollback_pending_stage "$journal" "$pending" "$artifact" || return $?
        elif [ "$pending_state" = destination ]; then
          _attachment_user_rollback_pending_destination_undone "$pending" "$artifact" "$destination" || return 3
        else
          return 2
        fi
      else
        return 2
      fi
    elif [ -e "$destination" ] || [ -L "$destination" ]; then
      if printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1; then
        _attachment_user_restore_exact "$destination" "$artifact" || return 3
      else
        return 3
      fi
      _attachment_user_rollback_pending_stage "$journal" "$pending" "$artifact" || return $?
    else
      _attachment_user_rollback_pending_stage "$journal" "$pending" "$artifact" || return $?
    fi
    _attachment_user_rollback_clear_pending "$journal" "$artifact" || return $?
    _attachment_fault_after_user_rollback_pending || return $?
  fi
  phase=$(jq -r '.phase' "$journal") || return 2
  index=$phase
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    artifact=$(jq -c --argjson index "$index" '.artifacts[$index]' "$journal") || return 2
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    identity=$(jq -r --argjson index "$index" '.identities[$index]' "$journal") || return 2
    if _attachment_user_parent_from_original "$journal" "$artifact"; then
      _attachment_identity_matches "$destination" "$identity" parent || return 3
      _attachment_path_exact_pinned "$destination" "$artifact" || return 3
    elif printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1; then
      _attachment_user_restore_adopted "$destination" "$artifact" "$identity" || return $?
    elif printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      _attachment_user_rollback_restore_replaced_file "$home" "$journal" "$operation" \
        "$destination" "$artifact" "$identity" || return $?
    else
      _attachment_user_remove_exact "$destination" "$artifact" "$identity" || return $?
    fi
    _attachment_user_rollback_finish_applied "$journal" "$index" "$artifact" || return $?
    _attachment_fault_after_user_rollback_phase "$index" || return $?
  done
  rm "$journal" || return 1
  [ "$conflict" -eq 0 ] || return "$conflict"
}

_attachment_user_prepare_impl() {
  local home=$1 plan_file=$2 journal=$3 plan journal_json home_identity trellis_home_identity
  [ "$#" -eq 3 ] || return 2
  _attachment_user_prepare_state "$home" || return $?
  [ "$journal" = "$(_attachment_user_journal_path "$home")" ] || return 2
  _attachment_user_validate_plan_file "$plan_file" || return $?
  plan=$(jq -cS . "$plan_file") || return 2
  _attachment_user_validate_plan_destinations "$home" "$plan" || return $?
  _attachment_user_validate_collisions "$plan" || return 2
  [ ! -e "$journal" ] && [ ! -L "$journal" ] || return 3
  [ ! -e "$(_attachment_user_owner_path "$home")" ] &&
    [ ! -L "$(_attachment_user_owner_path "$home")" ] || return 3
  home_identity=$(_attachment_fs_identity "$(_attachment_user_runtime_home)") || return 1
  trellis_home_identity=$(_attachment_fs_identity "$home") || return 1
  journal_json=$(printf '%s\n' "$plan" | jq -cS --arg home_identity "$home_identity" \
    --arg trellis_home_identity "$trellis_home_identity" '
    . + {
      home_identity:$home_identity,
      trellis_home_identity:$trellis_home_identity,
      operation:"attach",
      original_owner:null,
      next_owner:null,
      owner_override:null,
      applied:[],
      identities:[],
      phase:0,
      pending:null,
      removal:null
    }
  ') || return 2
  _attachment_write_json "$journal" "$journal_json" || return $?
}

_attachment_user_prepare_relink_impl() {
  local home=$1 plan_file=$2 original=$3 journal=$4 operation=${5:-relink}
  local plan current_owner journal_json home_identity trellis_home_identity artifact destination
  [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || return 2
  case "$operation" in relink|repair) ;; *) return 2 ;; esac
  _attachment_user_prepare_state "$home" || return $?
  [ "$journal" = "$(_attachment_user_journal_path "$home")" ] || return 2
  _attachment_user_validate_plan_file "$plan_file" || return $?
  plan=$(jq -cS . "$plan_file") || return 2
  _attachment_user_validate_plan_destinations "$home" "$plan" || return $?
  _attachment_user_validate_collisions "$plan" || return 2
  printf '%s\n' "$original" | jq -e "$_attachment_user_owner_filter" >/dev/null 2>&1 || return 2
  current_owner=$(_attachment_user_owner_path "$home")
  _attachment_user_owner_json_valid "$current_owner" || return $?
  [ "$(jq -cS . "$current_owner")" = "$(printf '%s\n' "$original" | jq -cS .)" ] || return 3
  [ ! -e "$journal" ] && [ ! -L "$journal" ] || return 3
  if [ "$operation" = repair ]; then
    _attachment_user_validate_collisions "$original" || return 2
    _attachment_user_verify_owner_artifacts_impl "$home" "$current_owner" true || return $?
    while IFS= read -r artifact; do
      destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
      [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
    done < <(printf '%s\n' "$plan" | jq -c '.artifacts[]')
  fi
  home_identity=$(_attachment_fs_identity "$(_attachment_user_runtime_home)") || return 1
  trellis_home_identity=$(_attachment_fs_identity "$home") || return 1
  journal_json=$(printf '%s\n' "$plan" | trellis_jq -cS --argjson original "$original" \
    --arg operation "$operation" --arg home_identity "$home_identity" --arg trellis_home_identity "$trellis_home_identity" '
    . + {
      home_identity:$home_identity,
      trellis_home_identity:$trellis_home_identity,
      operation:$operation,
      original_owner:$original,
      next_owner:null,
      owner_override:(if $operation == "repair" then $original else null end),
      applied:[],
      identities:[],
      phase:0,
      pending:null,
      removal:null
    }
    | if $operation == "relink" then .next_owner = {
        schema_version:.schema_version,surface:.surface,status:.status,
        attachment_id:.attachment_id,release:.release,home_paths:.home_paths,
        artifacts:.artifacts,renders:.renders
      } else . end
  ') || return 2
  if [ "$operation" = repair ]; then
    _attachment_user_repair_binding_valid "$journal_json" || return $?
  fi
  _attachment_write_json "$journal" "$journal_json" || return $?
}

_attachment_user_set_reconcile_state() {
  local journal=$1 operation=$2 original=$3 next_plan=$4 owner_override=${5:-null} next
  next=$(trellis_jq -cS --arg operation "$operation" --argjson original "$original" \
    --argjson next_owner "$next_plan" --argjson owner_override "$owner_override" '
      .operation = $operation
      | .original_owner = $original
      | .next_owner = $next_owner
      | .owner_override = $owner_override
    ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_commit_locked() {
  local home=$1 journal=$2 operation rc discard_rc repair_interrupted=false
  _attachment_user_journal_json_valid "$journal" || return $?
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  operation=$(jq -r '.operation' "$journal") || return 2
  _attachment_user_commit_apply_locked "$home" "$journal"
  rc=$?
  if [ "$operation" = repair ] && [ "$rc" -ne 0 ] &&
     [ "$repair_interrupted" = false ] && { [ -e "$journal" ] || [ -L "$journal" ]; }; then
    discard_rc=0
    _attachment_user_discard_repair_locked "$home" "$journal" || discard_rc=$?
    [ "$discard_rc" -eq 0 ] || return "$discard_rc"
  fi
  return "$rc"
}

_attachment_user_commit_apply_locked() {
  local home=$1 journal=$2 plan owner artifact kind stage phase owner_json pending operation rc rollback_rc total match_rc
  _attachment_user_journal_json_valid "$journal" || return $?
  operation=$(jq -r '.operation' "$journal") || return 2
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  _attachment_user_validate_journal_sources "$home" "$journal" || return $?
  plan=$(_attachment_user_plan_from_journal "$journal") || return 2
  owner=$(_attachment_user_owner_path "$home")
  if [ "$operation" = repair ]; then
    _attachment_user_owner_json_valid "$owner" || return $?
    [ "$(jq -cS . "$owner")" = "$(jq -cS '.original_owner' "$journal")" ] || return 3
    _attachment_user_verify_owner_artifacts_impl "$home" "$owner" true || return $?
  fi
  if [ "$(jq -r '.pending.rollback_state // empty' "$journal")" != "" ]; then
    _attachment_user_rollback_locked "$home" "$journal" || return $?
    return 0
  fi
  if [ "$operation" != repair ] && { [ -e "$owner" ] || [ -L "$owner" ]; }; then
    _attachment_user_owner_matches_plan "$owner" "$plan"
    match_rc=$?
    if [ "$match_rc" -ne 0 ]; then
      if [ "$(jq -c '.owner_override' "$journal")" != null ]; then
        _attachment_user_owner_json_valid "$owner" || return $?
        [ "$(jq -cS . "$owner")" = "$(jq -cS '.owner_override' "$journal")" ] || return 3
      else
        return "$match_rc"
      fi
    fi
    phase=$(jq -r '.phase' "$journal") || return 2
    total=$(jq '.artifacts | length' "$journal") || return 2
    [ "$phase" -eq "$total" ] && [ "$(jq -r '.pending == null' "$journal")" = true ] || return 3
    _attachment_user_verify_owner_artifacts_impl "$home" "$owner" || return $?
    rm "$journal" || return 1
    return 0
  fi
  while :; do
    if [ "$(jq -r '.pending == null' "$journal")" = false ]; then
      _attachment_user_publish_pending "$home" "$journal"
      rc=$?
    else
      phase=$(jq -r '.phase' "$journal") || return 2
      total=$(jq '.artifacts | length' "$journal") || return 2
      [ "$phase" -lt "$total" ] || break
      artifact=$(jq -c --argjson phase "$phase" '.artifacts[$phase]' "$journal") || return 2
      stage=$(_attachment_user_stage_candidate "$(printf '%s\n' "$artifact" | jq -r '.destination')" "$(jq -r '.attachment_id' "$journal")") || return 1
      _attachment_user_set_pending "$journal" "$artifact" "$stage" || return $?
      _attachment_user_publish_pending "$home" "$journal"
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      rollback_rc=0
      _attachment_user_rollback_locked "$home" "$journal" || rollback_rc=$?
      [ "$rollback_rc" -eq 0 ] || return "$rollback_rc"
      return "$rc"
    fi
    phase=$(jq -r '.phase' "$journal") || return 2
    if [ "$operation" != restore ] && [ "${ATTACHMENT_FAULT_PHASE:-}" = "$phase" ]; then
      # This fault models a signal/crash, unlike a publication failure.
      if [ "$operation" = repair ]; then repair_interrupted=true; fi
      return 5
    fi
  done
  if [ "$(jq -c '.owner_override' "$journal")" != null ]; then
    owner_json=$(jq -cS '.owner_override' "$journal") || return 2
  else
    owner_json=$(_attachment_user_owner_from_plan "$plan") || return 2
  fi
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  _attachment_user_validate_journal_sources "$home" "$journal" || return $?
  if [ "$operation" = repair ]; then
    # A repair never republishes ownership, even with identical JSON bytes.
    _attachment_user_owner_json_valid "$owner" || return $?
    [ "$(jq -cS . "$owner")" = "$(jq -cS '.original_owner' "$journal")" ] || return 3
  elif ! _attachment_write_json "$owner" "$owner_json"; then
    _attachment_user_rollback_locked "$home" "$journal" || return $?
    return 1
  fi
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  _attachment_user_validate_journal_sources "$home" "$journal" || return $?
  _attachment_user_verify_owner_artifacts_impl "$home" "$owner" || return $?
  if [ "$operation" != restore ] && [ "${ATTACHMENT_FAULT_PHASE:-}" = owner-published ]; then
    if [ "$operation" = repair ]; then repair_interrupted=true; fi
    return 5
  fi
  rm "$journal" || return 1
}

_attachment_user_rollback_impl() {
  local home=$1 journal=$2
  _attachment_user_journal_json_valid "$journal" || return $?
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  _attachment_user_rollback_locked "$home" "$journal"
}

_attachment_user_recover_impl() {
  local home=$1 journal=$2 owner plan phase total
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  _attachment_user_journal_json_valid "$journal" || return $?
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  if [ "$(jq -r '.operation' "$journal")" = repair ]; then
    # Discard first, then the caller can re-plan against the current owner.
    _attachment_user_discard_repair_locked "$home" "$journal"
    return $?
  fi
  _attachment_user_validate_journal_sources "$home" "$journal" || return $?
  owner=$(_attachment_user_owner_path "$home")
  plan=$(_attachment_user_plan_from_journal "$journal") || return 2
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    if [ "$(jq -c '.owner_override' "$journal")" != null ]; then
      _attachment_user_owner_json_valid "$owner" || return $?
      [ "$(jq -cS . "$owner")" = "$(jq -cS '.owner_override' "$journal")" ] || return 3
    else
      _attachment_user_owner_matches_plan "$owner" "$plan" || return $?
    fi
    phase=$(jq -r '.phase' "$journal") || return 2
    total=$(jq '.artifacts | length' "$journal") || return 2
    [ "$phase" -eq "$total" ] && [ "$(jq -r '.pending == null' "$journal")" = true ] || return 3
    _attachment_user_validate_journal_sources "$home" "$journal" || return $?
    _attachment_user_verify_owner_artifacts_impl "$home" "$owner" || return $?
    rm "$journal" || return 1
    return 0
  fi
  _attachment_user_commit_locked "$home" "$journal"
}

_attachment_user_verify_impl() {
  _attachment_user_verify_owner_artifacts_impl "$@"
}

attachment_user_lock_reclaim() {
  local status
  [ "$#" -eq 1 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_prepare_state "$1" || { status=$?; _attachment_map_public_status "$status"; return $?; }
  _attachment_user_lock_reclaim "$1"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_lock_acquire() {
  local status
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_prepare_state "$1" || { status=$?; _attachment_map_public_status "$status"; return $?; }
  _attachment_user_lock_acquire "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_lock_release() {
  local status
  _attachment_user_lock_release
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_prepare() {
  local status
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_prepare_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_commit() {
  local status
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_commit_locked "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_rollback() {
  local status
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_rollback_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_recover() {
  local status
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_recover_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_verify() {
  local status
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_verify_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}


_attachment_user_render_state() {
  local render=$1 destination current_hash after_hash after_mode keys
  destination=$(printf '%s\n' "$render" | jq -r '.destination') || return 2
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 3
  after_hash=$(printf '%s\n' "$render" | jq -r '.after_sha256') || return 2
  after_mode=$(printf '%s\n' "$render" | jq -r '.after_mode') || return 2
  current_hash=$(_attachment_hash "$destination") || return 1
  if [ "$current_hash" = "$after_hash" ] && _attachment_mode_matches "$destination" "$after_mode"; then
    printf 'after\n'
    return 0
  fi
  keys=$(printf '%s\n' "$render" | jq -c '.owned_keys') || return 2
  _attachment_mode_matches "$destination" "$after_mode" &&
    _attachment_user_json_keys_match "$destination" "$keys" || return 3
  printf 'merged\n'
}

_attachment_user_inverse_render_result() (
  local render=$1 destination state before_exists before_mode after_mode keys created tmp before_tmp result_mode
  local before_base64 before_hash result_hash result_base64 current_hash
  destination=$(printf '%s\n' "$render" | jq -r '.destination') || return 2
  state=$(_attachment_user_render_state "$render") || return $?
  before_exists=$(printf '%s\n' "$render" | jq -r '.before_exists') || return 2
  before_mode=$(printf '%s\n' "$render" | jq -r '.before_mode // empty') || return 2
  after_mode=$(printf '%s\n' "$render" | jq -r '.after_mode') || return 2
  if [ "$state" = after ]; then
    if [ "$before_exists" = false ]; then
      jq -cn --arg sha "$(_attachment_hash_text '')" \
        '{result_exists:false,result_base64:"",result_sha256:$sha,result_mode:null}'
    else
      trellis_jq -cn \
        --arg bytes "$(printf '%s\n' "$render" | jq -r '.before_base64')" \
        --arg sha "$(printf '%s\n' "$render" | jq -r '.before_sha256')" \
        --arg mode "$before_mode" \
        '{result_exists:true,result_base64:$bytes,result_sha256:$sha,result_mode:$mode}'
    fi
    return $?
  fi
  keys=$(printf '%s\n' "$render" | jq -c '.owned_keys') || return 2
  created=$(printf '%s\n' "$render" | jq -c '.created_paths') || return 2
  current_hash=$(_attachment_hash "$destination") || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/trellis.user-render-inverse.XXXXXX") || return 1
  before_tmp=$(mktemp "${TMPDIR:-/tmp}/trellis.user-render-before.XXXXXX") || {
    rm -f "$tmp"
    return 1
  }
  trap 'rm -f "$tmp" "$before_tmp"' EXIT
  if [ "$before_exists" = true ]; then
    before_base64=$(printf '%s\n' "$render" | jq -r '.before_base64') || return 2
    before_hash=$(printf '%s\n' "$render" | jq -r '.before_sha256') || return 2
    printf '%s' "$before_base64" | base64 -D 2>/dev/null > "$before_tmp" ||
      printf '%s' "$before_base64" | base64 -d 2>/dev/null > "$before_tmp" || return 2
    [ "$(_attachment_hash "$before_tmp")" = "$before_hash" ] || return 2
    jq -e 'type == "object"' "$before_tmp" >/dev/null 2>&1 || return 2
  else
    printf '{}\n' > "$before_tmp" || return 1
  fi
  settings_owned_json inverse "$destination" "$keys" '' "$before_tmp" "$created" > "$tmp" || return 3
  [ "$(_attachment_hash "$destination")" = "$current_hash" ] || return 3
  if [ "$before_exists" = false ] &&
     [ "$(jq -r 'type == "object" and length == 0' "$tmp")" = true ]; then
    jq -cn --arg sha "$(_attachment_hash_text '')" \
      '{result_exists:false,result_base64:"",result_sha256:$sha,result_mode:null}'
    return $?
  fi
  if [ "$before_exists" = true ]; then result_mode=$before_mode; else result_mode=$after_mode; fi
  chmod "${result_mode#0}" "$tmp" || return 1
  result_hash=$(_attachment_hash "$tmp") || return 1
  result_base64=$(base64 < "$tmp" | tr -d '\n') || return 1
  trellis_jq -cn --arg bytes "$result_base64" --arg sha "$result_hash" --arg mode "$result_mode" \
    '{result_exists:true,result_base64:$bytes,result_sha256:$sha,result_mode:$mode}'
)

_attachment_user_detach_journal_update() {
  local journal=$1 next
  shift
  next=$(trellis_jq -cS "$@" "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_detach_journal_valid() {
  local file=$1 original next journal_dir state_dir home user_home artifact destination removal pending
  local phase attachment stage parent expected_parent result_exists
  [ -f "$file" ] && [ ! -L "$file" ] || return 4
  [ "$(_attachment_mode "$file")" = 600 ] || return 4
  jq -e '
    def exact($allowed): (keys | sort) == ($allowed | sort);
    def controls: test("[[:cntrl:]]");
    def abs: type == "string" and startswith("/") and . != "/" and (endswith("/") | not)
      and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and (controls | not);
    def sha: type == "string" and test("^[a-f0-9]{64}$");
    def identity: type == "string" and test("^[0-9]+:[0-9]+$");
    def mode: type == "string" and test("^0[0-7]{3}$");
    def b64: type == "string" and test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");
    def render_pending:
      type == "object"
      and exact(["parent_identity","render","result_base64","result_exists","result_mode","result_sha256","source_identity","source_mode","source_sha256","staging_identity","staging_path"])
      and (.parent_identity | identity)
      and (.render | type == "object")
      and (.source_identity | identity) and (.source_sha256 | sha) and (.source_mode | mode)
      and (.result_exists | type == "boolean") and (.result_base64 | b64) and (.result_sha256 | sha)
      and (.result_mode == null or (.result_mode | mode))
      and (.staging_path == null or (.staging_path | abs))
      and (.staging_identity == null or (.staging_identity | identity))
      and (if .result_exists
           then (.result_mode | mode) and (.staging_path | abs)
           else .result_base64 == "" and .result_sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
             and .result_mode == null and .staging_path == null and .staging_identity == null
           end);
    . as $journal
    | type == "object"
    and exact([
      "attachment_id","external","home_identity","home_paths","next_owner","operation",
      "original_owner","owner_committed","parent_identities","parents","phase",
      "removal","remove","remove_identities","schema_version","status","surface",
      "trellis_home_identity"
    ])
    and (.home_identity | identity) and (.trellis_home_identity | identity)
    and .schema_version == 1 and .surface == "user" and .status == "detaching"
    and (.attachment_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.home_paths | type == "array" and length == 1 and (.[0] | abs))
    and (.operation == "detach" or .operation == "relink")
    and (.original_owner | type == "object")
    and (.next_owner == null or (.next_owner | type == "object"))
    and (.remove | type == "array")
    and (.remove_identities | type == "array" and length == ($journal.remove | length) and all(.[]; identity))
    and (.parents | type == "array")
    and (.parent_identities | type == "array" and length == ($journal.parents | length) and all(.[]; identity))
    and (.phase | type == "number" and floor == . and . >= 0 and . <= ($journal.remove | length))
    and (.owner_committed | type == "boolean")
    and (.removal == null or (
      .removal | type == "object"
      and exact(["artifact","destination","identity","index","parent_identity","restore_identity","staging_path"])
      and (.destination | abs) and (.staging_path | abs)
      and (.identity | identity) and (.parent_identity | identity)
      and (.restore_identity == null or (.restore_identity | identity))
      and (.index | type == "number" and floor == . and . >= 0)
    ))
    and (.external | type == "object"
      and exact(["phase","render_pending","render_phase","renders"])
      and (.phase | type == "number" and floor == . and . >= 0 and . <= 2)
      and (.renders | type == "array")
      and (.render_phase | type == "number" and floor == . and . >= 0 and . <= ($journal.external.renders | length))
      and (.render_pending == null or (.render_pending | render_pending)))
    and (if .removal == null then true
         else .phase < (.remove | length)
           and .removal.index == .phase
           and .removal.artifact == .remove[.phase]
           and .removal.destination == .remove[.phase].destination
           and .removal.identity == .remove_identities[.phase]
         end)
    and (if .external.render_pending == null then true
         else .external.phase == 1
           and .external.render_phase < (.external.renders | length)
           and .external.render_pending.render == .external.renders[.external.render_phase]
         end)
    and (if .external.phase >= 2 then
           .external.render_phase == (.external.renders | length)
           and .external.render_pending == null and .removal == null
         else true end)
    and (if .owner_committed then
           .phase == (.remove | length) and .external.phase == 2
           and .external.render_pending == null and .removal == null
         else true end)
  ' "$file" >/dev/null 2>&1 || return 2
  original=$(jq -c '.original_owner' "$file") || return 2
  printf '%s\n' "$original" | jq -e "$_attachment_user_owner_filter" >/dev/null 2>&1 || return 2
  next=$(jq -c '.next_owner' "$file") || return 2
  if [ "$next" != null ]; then
    printf '%s\n' "$next" | jq -e "$_attachment_user_plan_filter" >/dev/null 2>&1 || return 2
  fi
  trellis_jq -e --argjson original "$original" --argjson next "$next" '
    . as $journal
    | ([$original.renders[].destination]) as $render_destinations
    | ([$original.artifacts[]
        | select(.kind != "parent")
        | select(.destination as $destination | ($render_destinations | index($destination)) == null)]
       | reverse) as $expected_remove
    | ([$original.artifacts[] | select(.kind == "parent")] | reverse) as $expected_parents
    | .remove == $expected_remove
    and .parents == $expected_parents
    and .external.renders == $original.renders
    and (if .operation == "detach" then $next == null else $next != null end)
  ' "$file" >/dev/null 2>&1 || return 2
  _attachment_user_snapshots_valid "$file" || return $?
  journal_dir=$(dirname "$file") || return 2
  state_dir=$(dirname "$journal_dir") || return 2
  home=$(dirname "$state_dir") || return 2
  [ "$journal_dir" = "$home/state/user-attachment-journals" ] || return 2
  [ "$file" = "$(_attachment_user_detach_journal_path "$home")" ] || return 2
  user_home=$(_attachment_user_runtime_home) || return $?
  while IFS= read -r artifact; do
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    _attachment_user_destination_safe "$user_home" "$home" "$destination" || return $?
  done < <(jq -c '.original_owner.artifacts[], .original_owner.renders[], .next_owner.artifacts[]?, .next_owner.renders[]?' "$file")
  removal=$(jq -c '.removal' "$file") || return 2
  if [ "$removal" != null ]; then
    phase=$(jq -r '.phase' "$file") || return 2
    attachment=$(jq -r '.attachment_id' "$file") || return 2
    destination=$(printf '%s\n' "$removal" | jq -r '.destination') || return 2
    stage=$(printf '%s\n' "$removal" | jq -r '.staging_path') || return 2
    [ "$stage" = "$(_attachment_user_detach_removal_stage "$destination" "$attachment" "$phase")" ] || return 2
    parent=$(dirname "$destination") || return 2
    [ "$(dirname "$stage")" = "$parent" ] || return 2
    expected_parent=$(printf '%s\n' "$removal" | jq -r '.parent_identity') || return 2
    _attachment_canonical_dir "$parent" || return 3
    [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  fi
  pending=$(jq -c '.external.render_pending' "$file") || return 2
  if [ "$pending" != null ]; then
    destination=$(printf '%s\n' "$pending" | jq -r '.render.destination') || return 2
    parent=$(dirname "$destination") || return 2
    expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
    _attachment_canonical_dir "$parent" || return 3
    [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
    result_exists=$(printf '%s\n' "$pending" | jq -r '.result_exists') || return 2
    if [ "$result_exists" = true ]; then
      stage=$(printf '%s\n' "$pending" | jq -r '.staging_path') || return 2
      [ "$(dirname "$stage")" = "$parent" ] || return 2
      _attachment_user_stage_path_valid "$destination" "$(jq -r '.attachment_id' "$file")" "$stage" || return 2
    fi
  fi
}

_attachment_user_detach_prepare_impl() {
  local home=$1 owner=$2 next_owner=$3 remove=$4 external=$5 journal original artifact destination identity rc
  local parents remove_identities='[]' parent_identities='[]' journal_json home_identity trellis_home_identity
  [ "$#" -eq 5 ] || return 2
  _attachment_user_prepare_state "$home" || return $?
  [ "$owner" = "$(_attachment_user_owner_path "$home")" ] || return 2
  _attachment_user_verify_owner_artifacts_impl "$home" "$owner" || return $?
  journal=$(_attachment_user_detach_journal_path "$home")
  [ ! -e "$journal" ] && [ ! -L "$journal" ] || return 3
  original=$(jq -cS . "$owner") || return 2
  printf '%s\n' "$remove" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  printf '%s\n' "$external" | jq -e '
    type == "object"
    and (keys | sort) == ["phase","render_pending","render_phase","renders"]
    and .phase == 0 and .render_phase == 0 and .render_pending == null
    and (.renders | type == "array")
  ' >/dev/null 2>&1 || return 2
  if [ "$next_owner" != null ]; then
    printf '%s\n' "$next_owner" | jq -e "$_attachment_user_plan_filter" >/dev/null 2>&1 || return 2
  fi
  printf '%s\n' "$original" | trellis_jq -e --argjson remove "$remove" \
    --argjson external "$external" --argjson next "$next_owner" '
      . as $original
      | ([.renders[].destination]) as $render_destinations
      | ([.artifacts[]
          | select(.kind != "parent")
          | select(.destination as $destination | ($render_destinations | index($destination)) == null)]
         | reverse) as $expected_remove
      | ([.artifacts[] | select(.kind == "parent")] | reverse) as $expected_parents
      | $remove == $expected_remove
      and $external.renders == $original.renders
      and (if $next == null then true else ($next | type) == "object" end)
      and ($expected_parents | type) == "array"
    ' >/dev/null 2>&1 || return 2
  while IFS= read -r artifact; do
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    _attachment_user_artifact_exact "$(_attachment_user_runtime_home)" "$artifact" || return 3
    identity=$(_attachment_fs_identity "$destination") || return 1
    remove_identities=$(trellis_jq -cn --argjson current "$remove_identities" --arg identity "$identity" \
      '$current + [$identity]') || return 2
  done < <(printf '%s\n' "$remove" | jq -c '.[]')
  parents=$(printf '%s\n' "$original" | jq -c '[.artifacts[] | select(.kind == "parent")] | reverse') || return 2
  while IFS= read -r artifact; do
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    [ -d "$destination" ] && [ ! -L "$destination" ] || return 3
    identity=$(_attachment_fs_identity "$destination") || return 1
    parent_identities=$(trellis_jq -cn --argjson current "$parent_identities" --arg identity "$identity" \
      '$current + [$identity]') || return 2
  done < <(printf '%s\n' "$parents" | jq -c '.[]')

  home_identity=$(_attachment_fs_identity "$(_attachment_user_runtime_home)") || return 1
  trellis_home_identity=$(_attachment_fs_identity "$home") || return 1
  journal_json=$(trellis_jq -cn \
    --arg attachment "$(printf '%s\n' "$original" | jq -r '.attachment_id')" \
    --arg home_identity "$home_identity" --arg trellis_home_identity "$trellis_home_identity" \
    --argjson homes "$(printf '%s\n' "$original" | jq -c '.home_paths')" \
    --argjson original "$original" --argjson next "$next_owner" \
    --argjson remove "$remove" --argjson identities "$remove_identities" \
    --argjson parents "$parents" --argjson parent_ids "$parent_identities" \
    --argjson external "$external" '
      {
        schema_version:1,surface:"user",status:"detaching",
        attachment_id:$attachment,home_paths:$homes,
        home_identity:$home_identity,trellis_home_identity:$trellis_home_identity,
        operation:(if $next == null then "detach" else "relink" end),
        original_owner:$original,next_owner:$next,
        remove:$remove,remove_identities:$identities,
        parents:$parents,parent_identities:$parent_ids,
        phase:0,owner_committed:false,removal:null,external:$external
      }
    ') || return 2
  _attachment_write_json "$journal" "$journal_json" || return $?
  _attachment_user_detach_journal_valid "$journal"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -- "$journal" || return 1
    return "$rc"
  fi
  printf '%s\n' "$journal"
}

_attachment_user_detach_removal_stage() {
  local destination=$1 attachment=$2 index=$3 parent base
  parent=$(dirname "$destination") || return 1
  base=$(basename "$destination") || return 1
  printf '%s/.%s.user-attachment-remove-%s-%s\n' "$parent" "$base" "$attachment" "$index"
}

_attachment_user_detach_restoration_stage() {
  local destination=$1 attachment=$2 index=$3
  printf '%srestore-%s\n' "$(_attachment_user_stage_prefix "$destination" "$attachment")" "$index"
}

_attachment_user_detach_set_restore_identity() {
  local journal=$1 identity=$2 next
  next=$(jq -cS --arg identity "$identity" '
    if .removal != null and .removal.restore_identity == null
    then .removal.restore_identity = $identity
    else error("invalid user restoration identity transition") end
  ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_detach_restore_stage() (
  local journal=$1 removal=$2 stage=$3 artifact destination restore_kind identity expected_parent restore_artifact rc
  local parent stage_base destination_base stage_ref destination_ref
  artifact=$(printf '%s\n' "$removal" | jq -c '.artifact') || return 2
  destination=$(printf '%s\n' "$removal" | jq -r '.destination') || return 2
  restore_kind=$(_attachment_user_restore_kind "$artifact") || return 2
  expected_parent=$(printf '%s\n' "$removal" | jq -r '.parent_identity') || return 2
  _attachment_user_stage_path_valid "$destination" "$(jq -r '.attachment_id' "$journal")" "$stage" || return 2
  parent=$(dirname "$destination") || return 2
  [ "$(dirname "$stage")" = "$parent" ] || return 2
  stage_base=$(basename "$stage") || return 2
  destination_base=$(basename "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  stage_ref="./$stage_base"
  destination_ref="./$destination_base"
  identity=$(printf '%s\n' "$removal" | jq -r '.restore_identity // empty') || return 2
  if [ -z "$identity" ]; then
    if [ -e "$stage_ref" ] || [ -L "$stage_ref" ]; then
      _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" || return $?
    fi
    case "$restore_kind" in
      file)
        set -o noclobber
        if ! { : > "$stage_ref"; } 2>/dev/null; then
          set +o noclobber
          return 3
        fi
        set +o noclobber
        ;;
      symlink)
        ln -sn -- "$(printf '%s\n' "$artifact" | jq -r '.restore.before_target')" "$stage_ref" 2>/dev/null ||
          return 3
        ;;
      *) return 2 ;;
    esac
    identity=$(_attachment_fs_identity "$stage_ref") || return 1
    _attachment_user_detach_set_restore_identity "$journal" "$identity"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      _attachment_identity_matches "$stage_ref" "$identity" "$restore_kind" && rm -- "$stage_ref"
      return "$rc"
    fi
    removal=$(jq -c '.removal' "$journal") || return 2
  fi
  if [ ! -e "$stage_ref" ] && [ ! -L "$stage_ref" ]; then
    _attachment_identity_matches "$destination_ref" "$identity" "$restore_kind" || return 3
    _attachment_user_restore_exact "$destination_ref" "$artifact"
    return $?
  fi
  _attachment_identity_matches "$stage_ref" "$identity" "$restore_kind" || return 3
  if [ "$restore_kind" = file ] && ! _attachment_user_restore_exact "$stage_ref" "$artifact"; then
    restore_artifact=$(printf '%s\n' "$artifact" | jq -c '
      {
        destination:.destination,kind:"file",mode:.restore.before_mode,
        sha256:.restore.before_sha256,content_base64:.restore.before_base64
      }
    ') || return 2
    _attachment_user_complete_owned_file_stage "$restore_artifact" "$stage_ref" "$identity" || return $?
  fi
  _attachment_user_restore_exact "$stage_ref" "$artifact" || return $?
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_user_detach_resume_removal() {
  local journal=$1 removal index phase artifact destination stage identity kind next operation attachment
  local parent expected_parent restore=false restoration_stage restore_identity restore_record restore_kind
  removal=$(jq -c '.removal' "$journal") || return 2
  [ "$removal" != null ] || return 0
  index=$(printf '%s\n' "$removal" | jq -r '.index') || return 2
  phase=$(jq -r '.phase' "$journal") || return 2
  artifact=$(printf '%s\n' "$removal" | jq -c '.artifact') || return 2
  destination=$(printf '%s\n' "$removal" | jq -r '.destination') || return 2
  stage=$(printf '%s\n' "$removal" | jq -r '.staging_path') || return 2
  identity=$(printf '%s\n' "$removal" | jq -r '.identity') || return 2
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
  parent=$(dirname "$destination") || return 2
  expected_parent=$(printf '%s\n' "$removal" | jq -r '.parent_identity') || return 2
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  operation=$(jq -r '.operation' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  if printf '%s\n' "$artifact" | jq -e 'has("restore")' >/dev/null 2>&1; then
    restore_record=$(printf '%s\n' "$artifact" | jq -c '.restore') || return 2
    restore_kind=$(_attachment_user_restore_kind "$artifact") || return 2
    if [ "$operation" = detach ] || ! trellis_jq -e --arg destination "$destination" --arg kind "$kind" \
      --argjson restore "$restore_record" '
        any(.next_owner.artifacts[]?;
          .destination == $destination and .kind == $kind and .restore == $restore)
      ' "$journal" >/dev/null 2>&1; then
      restore=true
    fi
  fi
  restoration_stage=$(_attachment_user_detach_restoration_stage "$destination" "$attachment" "$index") || return 1
  _attachment_user_stage_path_valid "$destination" "$attachment" "$restoration_stage" || return 2
  if [ "$restore" != true ]; then
    [ ! -e "$restoration_stage" ] && [ ! -L "$restoration_stage" ] || return 3
  fi
  [ "$phase" -eq "$index" ] || return 3
  if [ ! -e "$stage" ] && [ ! -L "$stage" ]; then
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      if _attachment_identity_matches "$destination" "$identity" "$kind" &&
         _attachment_path_exact_pinned "$destination" "$artifact"; then
        _attachment_move_pinned "$parent" "$expected_parent" "$destination" "$stage" "$identity" "$kind" false || return $?
      elif [ "$restore" = true ]; then
        restore_identity=$(printf '%s\n' "$removal" | jq -r '.restore_identity // empty') || return 2
        [ -n "$restore_identity" ] || return 3
        _attachment_identity_matches "$destination" "$restore_identity" "$restore_kind" || return 3
        _attachment_user_restore_exact "$destination" "$artifact" || return $?
      else
        return 3
      fi
    elif [ "$restore" = true ]; then
      restore_identity=$(printf '%s\n' "$removal" | jq -r '.restore_identity // empty') || return 2
      [ -z "$restore_identity" ] || return 3
    fi
  fi
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    _attachment_identity_matches "$stage" "$identity" "$kind" || return 3
    _attachment_path_exact_pinned "$stage" "$artifact" || return 3
  fi
  if [ "$restore" = true ]; then
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
      removal=$(jq -c '.removal' "$journal") || return 2
      _attachment_user_detach_restore_stage "$journal" "$removal" "$restoration_stage" || return $?
      removal=$(jq -c '.removal' "$journal") || return 2
      restore_identity=$(printf '%s\n' "$removal" | jq -r '.restore_identity // empty') || return 2
      [ -n "$restore_identity" ] || return 3
      if [ -e "$restoration_stage" ] || [ -L "$restoration_stage" ]; then
        _attachment_move_pinned "$parent" "$expected_parent" "$restoration_stage" "$destination" "$restore_identity" "$restore_kind" false || return $?
      fi
    fi
    restore_identity=$(printf '%s\n' "$removal" | jq -r '.restore_identity // empty') || return 2
    [ -n "$restore_identity" ] || return 3
    _attachment_identity_matches "$destination" "$restore_identity" "$restore_kind" || return 3
    _attachment_user_restore_exact "$destination" "$artifact" || return $?
    [ ! -e "$restoration_stage" ] && [ ! -L "$restoration_stage" ] || return 3
  else
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
  fi
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    _attachment_user_remove_exact "$stage" "$artifact" "$identity" "$expected_parent" || return $?
  fi
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  _attachment_user_detach_journal_update "$journal" --argjson next_phase "$((index + 1))" \
    '.phase = $next_phase | .removal = null'
}

_attachment_user_detach_remove_one() {
  local journal=$1 phase artifact destination identity stage attachment intent parent parent_identity restoration_stage
  phase=$(jq -r '.phase' "$journal") || return 2
  artifact=$(jq -c --argjson phase "$phase" '.remove[$phase]' "$journal") || return 2
  [ "$artifact" != null ] || return 2
  destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
  identity=$(jq -r --argjson phase "$phase" '.remove_identities[$phase]' "$journal") || return 2
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  stage=$(_attachment_user_detach_removal_stage "$destination" "$attachment" "$phase") || return 1
  [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 3
  _attachment_identity_matches "$destination" "$identity" "$(printf '%s\n' "$artifact" | jq -r '.kind')" || return 3
  _attachment_path_exact_pinned "$destination" "$artifact" || return 3
  parent=$(dirname "$destination") || return 2
  _attachment_canonical_dir "$parent" || return 3
  parent_identity=$(_attachment_fs_identity "$parent") || return 1
  restoration_stage=$(_attachment_user_detach_restoration_stage "$destination" "$attachment" "$phase") || return 1
  [ ! -e "$restoration_stage" ] && [ ! -L "$restoration_stage" ] || return 3
  intent=$(trellis_jq -cS --argjson artifact "$artifact" --arg destination "$destination" \
    --arg stage "$stage" --arg identity "$identity" --arg parent_identity "$parent_identity" \
    --argjson index "$phase" '
      .removal = {
        artifact:$artifact,destination:$destination,staging_path:$stage,
        identity:$identity,index:$index,parent_identity:$parent_identity,restore_identity:null
      }
    ' "$journal") || return 2
  _attachment_write_json "$journal" "$intent" || return $?
  _attachment_user_detach_resume_removal "$journal"
}

_attachment_user_detach_render_begin() {
  local journal=$1 phase render destination source_identity source_sha source_mode result result_exists stage parent_identity next
  phase=$(jq -r '.external.render_phase' "$journal") || return 2
  render=$(jq -c --argjson phase "$phase" '.external.renders[$phase]' "$journal") || return 2
  [ "$render" != null ] || return 2
  destination=$(printf '%s\n' "$render" | jq -r '.destination') || return 2
  _attachment_user_render_state "$render" >/dev/null || return $?
  source_identity=$(_attachment_fs_identity "$destination") || return 1
  source_sha=$(_attachment_hash "$destination") || return 1
  source_mode=$(_attachment_mode "$destination") || return 1
  case "$source_mode" in [0-7][0-7][0-7]) source_mode="0$source_mode" ;; *) return 2 ;; esac
  result=$(_attachment_user_inverse_render_result "$render") || return $?
  result_exists=$(printf '%s\n' "$result" | jq -r '.result_exists') || return 2
  if [ "$result_exists" = true ]; then
    stage=$(_attachment_user_stage_candidate "$destination" "$(jq -r '.attachment_id' "$journal")") || return 1
  else
    stage=
  fi
  parent_identity=$(_attachment_fs_identity "$(dirname "$destination")") || return 1
  next=$(trellis_jq -cS --argjson render "$render" --arg source_identity "$source_identity" \
    --arg source_sha "$source_sha" --arg source_mode "$source_mode" \
    --argjson result "$result" --arg stage "$stage" --arg parent_identity "$parent_identity" '
      .external.render_pending = ({
        render:$render,source_identity:$source_identity,source_sha256:$source_sha,
        source_mode:$source_mode,staging_path:(if $stage == "" then null else $stage end),
        staging_identity:null,parent_identity:$parent_identity
      } + $result)
    ' "$journal") || return 2
  _attachment_write_json "$journal" "$next"
}

_attachment_user_detach_render_stage() (
  local journal=$1 pending stage destination parent identity next content mode expected actual rc fd_identity
  local attachment expected_parent stage_base destination_base
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  [ "$(printf '%s\n' "$pending" | jq -r '.result_exists')" = true ] || return 0
  stage=$(printf '%s\n' "$pending" | jq -r '.staging_path') || return 2
  destination=$(printf '%s\n' "$pending" | jq -r '.render.destination') || return 2
  parent=$(dirname "$destination") || return 2
  [ "$parent" = "$(dirname "$stage")" ] || return 3
  attachment=$(jq -r '.attachment_id' "$journal") || return 2
  _attachment_user_stage_path_valid "$destination" "$attachment" "$stage" || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  [ "$(_attachment_fs_identity "$parent")" = "$expected_parent" ] || return 3
  _attachment_canonical_dir "$parent" || return 3
  stage_base=$(basename "$stage") || return 2
  destination_base=$(basename "$destination") || return 2
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  stage="./$stage_base"
  destination="./$destination_base"
  if [ "$(printf '%s\n' "$pending" | jq -r '.staging_identity == null')" = false ] &&
     [ ! -e "$stage" ] && [ ! -L "$stage" ]; then
    identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity') || return 2
    expected=$(printf '%s\n' "$pending" | jq -r '.result_sha256') || return 2
    mode=$(printf '%s\n' "$pending" | jq -r '.result_mode') || return 2
    _attachment_identity_matches "$destination" "$identity" file || return 3
    [ "$(_attachment_hash "$destination")" = "$expected" ] || return 3
    _attachment_mode_matches "$destination" "$mode" || return 3
    return 0
  fi
  if [ "$(printf '%s\n' "$pending" | jq -r '.staging_identity == null')" = true ]; then
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      _attachment_reclaim_unidentified_stage "$stage" "$expected_parent" || return $?
    fi
    set -o noclobber
    if ! { exec 9>"$stage"; } 2>/dev/null; then
      set +o noclobber
      return 3
    fi
    set +o noclobber
    identity=$(_attachment_fs_identity "$stage") || { exec 9>&-; return 1; }
    next=$(jq -cS --arg identity "$identity" '.external.render_pending.staging_identity = $identity' "$journal") || {
      exec 9>&-
      return 2
    }
    if _attachment_write_json "$journal" "$next"; then
      :
    else
      rc=$?
      exec 9>&-
      return "$rc"
    fi
    content=$(printf '%s\n' "$pending" | jq -r '.result_base64') || { exec 9>&-; return 2; }
    if printf '%s' "$content" | base64 -D 2>/dev/null >&9; then
      :
    elif printf '%s' "$content" | base64 -d 2>/dev/null >&9; then
      :
    else
      exec 9>&-
      return 1
    fi
    exec 9>&-
    mode=$(printf '%s\n' "$pending" | jq -r '.result_mode') || return 2
    chmod "${mode#0}" "$stage" || return 1
    pending=$(jq -c '.external.render_pending' "$journal") || return 2
  fi
  identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity') || return 2
  _attachment_identity_matches "$stage" "$identity" file || return 3
  expected=$(printf '%s\n' "$pending" | jq -r '.result_sha256') || return 2
  mode=$(printf '%s\n' "$pending" | jq -r '.result_mode') || return 2
  actual=$(_attachment_hash "$stage") || return 1
  if [ "$actual" != "$expected" ] || ! _attachment_mode_matches "$stage" "$mode"; then
    exec 9<>"$stage" || return 3
    fd_identity=$(_attachment_fd_fs_identity /dev/fd/9) || { exec 9>&-; return 1; }
    [ "$fd_identity" = "$identity" ] || { exec 9>&-; return 3; }
    : > /dev/fd/9 || { exec 9>&-; return 1; }
    content=$(printf '%s\n' "$pending" | jq -r '.result_base64') || { exec 9>&-; return 2; }
    if printf '%s' "$content" | base64 -D 2>/dev/null >&9; then
      :
    elif printf '%s' "$content" | base64 -d 2>/dev/null >&9; then
      :
    else
      exec 9>&-
      return 1
    fi
    chmod "${mode#0}" /dev/fd/9 || { exec 9>&-; return 1; }
    exec 9>&-
  fi
  _attachment_identity_matches "$stage" "$identity" file || return 3
  [ "$(_attachment_hash "$stage")" = "$expected" ] || return 3
  _attachment_mode_matches "$stage" "$mode" || return 3
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
)

_attachment_user_detach_render_publish() (
  local journal=$1 pending destination parent source_identity source_sha source_mode result_exists stage stage_identity
  local expected_parent stage_base destination_base destination_ref
  pending=$(jq -c '.external.render_pending' "$journal") || return 2
  [ "$pending" != null ] || return 2
  destination=$(printf '%s\n' "$pending" | jq -r '.render.destination') || return 2
  parent=$(dirname "$destination") || return 2
  expected_parent=$(printf '%s\n' "$pending" | jq -r '.parent_identity') || return 2
  _attachment_canonical_dir "$parent" || return 3
  destination_base=$(basename "$destination") || return 2
  CDPATH='' cd "$parent" || return 1
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  destination_ref="./$destination_base"
  source_identity=$(printf '%s\n' "$pending" | jq -r '.source_identity') || return 2
  source_sha=$(printf '%s\n' "$pending" | jq -r '.source_sha256') || return 2
  source_mode=$(printf '%s\n' "$pending" | jq -r '.source_mode') || return 2
  result_exists=$(printf '%s\n' "$pending" | jq -r '.result_exists') || return 2
  if [ "$result_exists" = true ]; then
    stage=$(printf '%s\n' "$pending" | jq -r '.staging_path') || return 2
    [ "$(dirname "$stage")" = "$parent" ] || return 2
    stage_base=$(basename "$stage") || return 2
    stage_identity=$(printf '%s\n' "$pending" | jq -r '.staging_identity') || return 2
    if [ -e "./$stage_base" ]; then
      _attachment_identity_matches "$destination_ref" "$source_identity" file || return 3
      [ "$(_attachment_hash "$destination_ref")" = "$source_sha" ] &&
        _attachment_mode_matches "$destination_ref" "$source_mode" || return 3
      _attachment_identity_matches "./$stage_base" "$stage_identity" file || return 3
      [ "$(_attachment_hash "./$stage_base")" = "$(printf '%s\n' "$pending" | jq -r '.result_sha256')" ] || return 3
      _attachment_move_pinned "$parent" "$expected_parent" "$stage" "$destination" "$stage_identity" file \
        true "$source_identity" file || return $?
    else
      _attachment_identity_matches "$destination_ref" "$stage_identity" file || return 3
      [ "$(_attachment_hash "$destination_ref")" = "$(printf '%s\n' "$pending" | jq -r '.result_sha256')" ] || return 3
    fi
    _attachment_identity_matches "$destination_ref" "$stage_identity" file || return 3
    [ "$(_attachment_hash "$destination_ref")" = "$(printf '%s\n' "$pending" | jq -r '.result_sha256')" ] || return 3
    _attachment_mode_matches "$destination_ref" "$(printf '%s\n' "$pending" | jq -r '.result_mode')" || return 3
  else
    if [ -e "$destination_ref" ] || [ -L "$destination_ref" ]; then
      _attachment_identity_matches "$destination_ref" "$source_identity" file || return 3
      [ "$(_attachment_hash "$destination_ref")" = "$source_sha" ] &&
        _attachment_mode_matches "$destination_ref" "$source_mode" || return 3
      rm -- "$destination_ref" || return 1
    fi
    [ ! -e "$destination_ref" ] && [ ! -L "$destination_ref" ] || return 3
  fi
  [ "$(_attachment_fs_identity .)" = "$expected_parent" ] || return 3
  _attachment_user_detach_journal_update "$journal" '
    .external.render_phase += 1
    | .external.render_pending = null
  '
)

_attachment_user_detach_cleanup_parent() (
  local destination=$1 identity=$2 container base first
  container=$(dirname "$destination") || return 2
  base=$(basename "$destination") || return 2
  _attachment_canonical_dir "$container" || return 3
  CDPATH='' cd "$container" || return 1
  if [ -e "./$base" ] || [ -L "./$base" ]; then
    _attachment_identity_matches "./$base" "$identity" parent || return 3
    first=$(find "./$base" -mindepth 1 -print -quit 2>/dev/null) || return 1
    if [ -z "$first" ]; then
      rmdir -- "./$base" || return 1
    fi
  fi
)

_attachment_user_detach_cleanup_parents() {
  local journal=$1 total index artifact destination identity
  total=$(jq '.parents | length' "$journal") || return 2
  index=0
  while [ "$index" -lt "$total" ]; do
    artifact=$(jq -c --argjson index "$index" '.parents[$index]' "$journal") || return 2
    destination=$(printf '%s\n' "$artifact" | jq -r '.destination') || return 2
    identity=$(jq -r --argjson index "$index" '.parent_identities[$index]' "$journal") || return 2
    _attachment_user_detach_cleanup_parent "$destination" "$identity" || return $?
    index=$((index + 1))
  done
  _attachment_user_detach_journal_update "$journal" '.external.phase = 2'
}

_attachment_fault_after_user_detach_phase() {
  local phase=$1
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = "user-detach-$phase" ]; then
    ATTACHMENT_FAULT_PHASE=
    export ATTACHMENT_FAULT_PHASE
    return 5
  fi
  return 0
}

_attachment_user_detach_commit_locked() {
  local home=$1 journal=$2 retain=${3:-false} owner original phase total original_data pending render_phase render_total
  _attachment_user_detach_journal_valid "$journal" || return $?
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  owner=$(_attachment_user_owner_path "$home")
  original=$(jq -cS '.original_owner' "$journal") || return 2
  if [ "$(jq -r '.owner_committed' "$journal")" = false ]; then
    if [ -e "$owner" ] || [ -L "$owner" ]; then
      _attachment_user_owner_json_valid "$owner" || return $?
      original_data=$(jq -cS . "$owner") || return 2
      [ "$original_data" = "$original" ] || return 3
    elif [ "$(jq -r '.external.phase' "$journal")" -lt 2 ]; then
      return 3
    fi
    if [ "$(jq -r '.removal == null' "$journal")" = false ]; then
      _attachment_user_detach_resume_removal "$journal" || return $?
    fi
    phase=$(jq -r '.phase' "$journal") || return 2
    _attachment_fault_after_user_detach_phase "$phase" || return $?
    total=$(jq '.remove | length' "$journal") || return 2
    while [ "$phase" -lt "$total" ]; do
      _attachment_user_detach_remove_one "$journal" || return $?
      phase=$(jq -r '.phase' "$journal") || return 2
      _attachment_fault_after_user_detach_phase "$phase" || return $?
    done
    if [ "$(jq -r '.external.phase' "$journal")" -lt 1 ]; then
      _attachment_user_detach_journal_update "$journal" '.external.phase = 1' || return $?
    fi
    while :; do
      render_phase=$(jq -r '.external.render_phase' "$journal") || return 2
      render_total=$(jq '.external.renders | length' "$journal") || return 2
      case "$render_phase" in ''|*[!0-9]*) return 2 ;; esac
      case "$render_total" in ''|*[!0-9]*) return 2 ;; esac
      [ "$render_phase" -le "$render_total" ] || return 2
      [ "$render_phase" -lt "$render_total" ] || break
      pending=$(jq -c '.external.render_pending' "$journal") || return 2
      if [ "$pending" = null ]; then
        _attachment_user_detach_render_begin "$journal" || return $?
      fi
      _attachment_user_detach_render_stage "$journal" || return $?
      _attachment_user_detach_render_publish "$journal" || return $?
    done
    if [ "$(jq -r '.external.phase' "$journal")" -lt 2 ]; then
      _attachment_user_detach_cleanup_parents "$journal" || return $?
    fi
    _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
    if [ -e "$owner" ] || [ -L "$owner" ]; then
      [ "$(jq -cS . "$owner")" = "$original" ] || return 3
      rm "$owner" || return 1
    fi
    _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
    _attachment_user_detach_journal_update "$journal" '.owner_committed = true' || return $?
  fi
  if [ "$retain" = true ] || [ "$(jq -r '.operation' "$journal")" = relink ]; then
    return 0
  fi
  rm "$journal" || return 1
}

_attachment_user_detach_recover_impl() {
  local home=$1 journal=$2 retain=false
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  _attachment_user_detach_journal_valid "$journal" || return $?
  if [ "$(jq -r '.operation' "$journal")" = relink ]; then retain=true; fi
  _attachment_user_detach_commit_locked "$home" "$journal" "$retain"
}

_attachment_user_detach_finalize_impl() {
  local home=$1 journal=$2
  [ "$journal" = "$(_attachment_user_detach_journal_path "$home")" ] || return 2
  _attachment_user_detach_journal_valid "$journal" || return $?
  _attachment_user_runtime_binding_matches "$home" "$journal" || return $?
  [ "$(jq -r '.owner_committed' "$journal")" = true ] || return 3
  [ "$(jq -r '.external.phase' "$journal")" -eq 2 ] || return 3
  [ "$(jq -r '.external.render_pending == null' "$journal")" = true ] || return 3
  rm "$journal" || return 1
}

attachment_user_detach_prepare() {
  local status
  [ "$#" -eq 5 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_detach_prepare_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_detach_commit() {
  local status
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_detach_commit_locked "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_detach_recover() {
  local status
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_detach_recover_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_user_detach_finalize() {
  local status
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _attachment_user_detach_finalize_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

_attachment_map_public_status() {
  local status=$1
  case "$status" in
    0) return 0 ;;
    1) return "${TRELLIS_EX_UNAVAILABLE:-5}" ;;
    2) return "${TRELLIS_EX_STATE:-4}" ;;
    3) return "${TRELLIS_EX_CONFLICT:-3}" ;;
    4) return "${TRELLIS_EX_STATE:-4}" ;;
    5) return "${TRELLIS_EX_UNAVAILABLE:-5}" ;;
    129|130|143) return "${TRELLIS_EX_UNAVAILABLE:-5}" ;;
    *) return "${TRELLIS_EX_STATE:-4}" ;;
  esac
}

attachment_checkout_lock_acquire() {
  local status
  [ "$#" -eq 3 ] || return 2
  _attachment_prepare_state "$1" || return $?
  _attachment_checkout_lock_acquire "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_checkout_lock_reclaim() {
  local status tries=0
  [ "$#" -eq 3 ] || return 2
  _attachment_prepare_state "$1" || return $?
  # A holder that releases between the link read and the holder read looks
  # malformed. Releases take milliseconds; only a lock that stays malformed
  # for two seconds is refused.
  while :; do
    _attachment_checkout_lock_reclaim "$@"
    status=$?
    [ "$status" -eq 4 ] && [ "$tries" -lt 10 ] || break
    tries=$((tries + 1))
    sleep 0.2
  done
  _attachment_map_public_status "$status"
}

# Reclaim and acquire, waiting a bounded 900 s while the lock is held.
# This exceeds the observed 9-12 minute foreground attach on large groups. The
# detached post-attach job can hold it for minutes while verifying siblings,
# so an immediate second worktree add must wait rather than refuse.
# Still held when the wait runs out: 3, and the caller names the lock.
attachment_checkout_lock_wait() {
  local rc tries=0
  [ "$#" -eq 3 ] || return 2
  while :; do
    if attachment_checkout_lock_reclaim "$@"; then
      attachment_checkout_lock_acquire "$@" && return 0
      rc=$?
    else
      rc=$?
    fi
    [ "$rc" -eq "${TRELLIS_EX_CONFLICT:-3}" ] && [ "$tries" -lt 3600 ] || return "$rc"
    tries=$((tries + 1))
    sleep 0.25
  done
}

attachment_prepare() {
  local status
  [ "$#" -eq 3 ] || return 2
  _attachment_prepare_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_commit() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_commit_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_rollback() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_rollback_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_recover() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_recover_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

# Owner files read as jq inputs must each parse to exactly one JSON document,
# in the order requested: an empty or whitespace-only file yields no input and
# a file holding two documents yields two, so a batch would drop or double an
# owner without any check refusing it. A program that starts with this def,
# given the requested paths as $expected (_attachment_paths_json), reads its
# owners through exact_inputs ({path, record} per file, in order) or fails.
_attachment_exact_inputs_def='def exact_inputs: [inputs | {path: input_filename, record: .}] as $docs | if ($docs | map(.path)) == $expected then $docs[] else error("owner files must each hold one JSON document, as requested") end;'

# The requested owner paths as one JSON array of strings (for $expected), or
# status 10. jq turns filename bytes that are not UTF-8 into U+FFFD, so
# distinct files could share one expected path, and exact_inputs would then
# compare a collapsed list (Sol r152-perf-2 M1-R). Every owner file a batch
# reads is .../<checkout id>/<worktree id>.json, both 64 lowercase hex digits,
# so a path whose last two components are not that, or a path requested
# twice, misses the batch instead: the caller's per-owner path decides it.
# The digits are matched as an explicit ASCII list, which no other byte can
# match in any locale.
_attachment_paths_json() {
  local path name parent
  for path in "$@"; do
    name=${path##*/}
    parent=${path%/*}
    parent=${parent##*/}
    [[ $name =~ ^[0123456789abcdef]{64}[.]json$ ]] && [[ $parent =~ ^[0123456789abcdef]{64}$ ]] || return 10
  done
  # Distinct as NUL-framed byte strings, so no character inside a path can
  # split or merge two of them.
  [ "$#" -le 1 ] || [ "$(printf '%s\0' "$@" | /usr/bin/env LC_ALL=C sort -zu | tr -cd '\000' | wc -c | tr -d ' ')" -eq "$#" ] || return 10
  jq -cn '$ARGS.positional' --args "$@"
}

# Run scripts/lib/owner_verify.py VERB HOME FS ARG... (see that file) on the
# entries JSON read from stdin; prints its output. 10 when it cannot run.
_attachment_owner_verify_exec() {
  local verb=$1 home=$2 lib fs python_bin settings
  shift 2
  fs=$(_attachment_fs_module) || return 10
  lib=${fs%/*}
  [ -f "$lib/owner_verify.py" ] && [ ! -L "$lib/owner_verify.py" ] || return 10
  declare -F _settings_owned_json_program >/dev/null || return 10
  python_bin=$(command -v python3) || return 10
  case "$python_bin" in /*) ;; *) return 10 ;; esac
  if [ "${_attachment_owner_verify_readonly:-0}" = 1 ]; then
    _attachment_state_readonly_ok "$home" || return 10
  else
    _attachment_prepare_state "$home" >/dev/null 2>&1 || return 10
  fi
  settings=$(_settings_owned_json_program) || return 10
  # Set locale in the child: Bash 5.3 on macOS can crash while restoring a
  # temporary LC_ALL assignment inside a captured owner-batch call.
  /usr/bin/env TRELLIS_SETTINGS_OWNED_JSON_PROGRAM="$settings" LC_ALL=C "$python_bin" -I -B "$lib/owner_verify.py" \
    "$verb" "$home" "$fs" "$@" 2>/dev/null
}

# Run scripts/lib/owner_verify.py VERB over OWNER... (see that file); prints
# its output. 10 when it cannot run.
_attachment_owner_verify_run() {
  local verb=$1 home=$2 checks expected
  shift 2
  expected=$(_attachment_paths_json "$@") || return 10
  checks=$(trellis_jq -cS -n --arg home "$home" --argjson expected "$expected" "$_attachment_exact_inputs_def
    [exact_inputs | .path as \$path | .record | {path: \$path, record: null, data: null,
      valid: (try ($_attachment_owner_schema_filter) catch false),
      canonical: (try (\$path == (\$home + \"/state/attachments/\" + .checkout_id + \"/\" + .worktree_id + \".json\")) catch false)}]
  " "$@" 2>/dev/null) || return 10
  printf '%s\n' "$checks" | _attachment_owner_verify_exec "$verb" "$home"
}

# attachment_verify_owners_batch HOME OWNER...: every check attachment_verify
# makes, for many owners at once. The owner checks run in one Python pass
# (scripts/lib/owner_verify.py, on the attach and detach programs' shared
# filesystem helpers); the managed hooks of each hooks-enabled owner, one per
# checkout, then run through the same shell check attachment_verify uses.
# 0: every owner passed. 10, printing nothing: any check failed or could not
# run; the caller then verifies owner by owner, which reports the first
# refusal exactly as before. Nothing is remembered between calls.
attachment_verify_owners_batch() {
  local home=$1 hooks_owner hooks_owners
  shift
  [ "$#" -gt 0 ] || return 0
  hooks_owners=$(_attachment_owner_verify_run verify-owner-records "$home" "$@") || return 10
  while IFS= read -r hooks_owner; do
    [ -n "$hooks_owner" ] || continue
    _attachment_verify_managed_hooks "$home" "$hooks_owner" >/dev/null 2>&1 || return 10
  done <<EOF
$hooks_owners
EOF
  return 0
}

# attachment_owner_artifact_verdicts HOME OWNER...: for each OWNER, in order, a
# line "0<TAB>OWNER" when it passes exactly what _attachment_verify_owner_artifacts
# OWNER HOME checks (owner_verify.py mode "artifacts"; like that call, it does
# not judge the owner file's mode, schema or location), else "1<TAB>OWNER". No
# managed hooks. 0 when the pass ran, 10 when it could not (fall back for every
# owner). A doctor run that uses these verdicts across its rows reports what
# held when the pass ran: read-only doctor only; same verify-then-report window
# as a per-row check, longer at scale.
attachment_owner_artifact_verdicts() {
  local home=$1
  shift
  [ "$#" -gt 0 ] || return 0
  _attachment_owner_verify_run owner-verdicts "$home" "$@" || return 10
}

# Same ordered verdicts, without preparing machine state. Large jq arguments
# can use temporary scratch under TMPDIR; callers control that location.
attachment_owner_artifact_verdicts_readonly() {
  local _attachment_owner_verify_readonly=1
  export -n _attachment_owner_verify_readonly
  attachment_owner_artifact_verdicts "$@"
}

attachment_verify() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_verify_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_verify_adoption() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_verify_adoption_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attachment_verify_detach() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_verify_detach_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}
