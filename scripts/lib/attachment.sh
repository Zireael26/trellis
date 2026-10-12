#!/usr/bin/env bash

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  _ATTACHMENT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
  # shellcheck source=scripts/lib/trellis-home.sh
  source "$_ATTACHMENT_DIR/trellis-home.sh"
fi

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
  printf '%s' "$digest" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$' || return 1
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
  case "$(uname -s 2>/dev/null)" in
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
  local path=$1 candidate
  shift
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ -s "$path" ] || return 1
  for candidate in "$@"; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] || continue
    cmp -s "$path" "$candidate" && return 1
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

_attachment_has_controls() {
  LC_ALL=C printf '%s' "$1" | grep '[[:cntrl:]]' >/dev/null 2>&1
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
  parent=$(dirname "$value") || return 1
  base=$(basename "$value") || return 1
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

attachment_contextual_render_context() {
  local trellis_home=$1 user_home launcher user_home_shell trellis_home_shell launcher_shell context
  _attachment_canonical_dir "$trellis_home" || return "$TRELLIS_EX_STATE"
  [ -n "${HOME:-}" ] || return "$TRELLIS_EX_UNAVAILABLE"
  case "$HOME" in /*) ;; *) return "$TRELLIS_EX_STATE" ;; esac
  _attachment_has_controls "$HOME" && return "$TRELLIS_EX_STATE"
  [ -d "$HOME" ] || return "$TRELLIS_EX_UNAVAILABLE"
  user_home="$(CDPATH='' cd "$HOME" && pwd -P)" || return "$TRELLIS_EX_UNAVAILABLE"
  _attachment_canonical_dir "$user_home" || return "$TRELLIS_EX_STATE"
  launcher="$user_home/.local/bin/trellis"
  if [ ! -e "$launcher" ] && [ ! -L "$launcher" ]; then
    _attachment_diag "launcher missing at $launcher; install it (docs/UPGRADING.md \"Reinstalling the launcher\") and retry"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  _attachment_canonical_file "$launcher" || return "$TRELLIS_EX_STATE"
  if [ ! -x "$launcher" ]; then
    _attachment_diag "launcher at $launcher is not executable; install it (docs/UPGRADING.md \"Reinstalling the launcher\") and retry"
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
  printf '%s\n' "$context" | jq -e '
    type == "object"
    and ((keys_unsorted | sort) == ["launcher","launcher_shell","schema_version","trellis_home","trellis_home_shell","user_home","user_home_shell"])
    and .schema_version == 1
    and (.user_home | type == "string" and startswith("/"))
    and (.trellis_home | type == "string" and startswith("/"))
    and (.launcher | type == "string" and startswith("/"))
    and (.user_home_shell | type == "string" and startswith("\u0027") and endswith("\u0027"))
    and (.trellis_home_shell | type == "string" and startswith("\u0027") and endswith("\u0027"))
    and (.launcher_shell | type == "string" and startswith("\u0027") and endswith("\u0027"))
  ' >/dev/null || return "$TRELLIS_EX_STATE"
  user_home="$(printf '%s\n' "$context" | jq -r '.user_home')" || return "$TRELLIS_EX_STATE"
  trellis_home="$(printf '%s\n' "$context" | jq -r '.trellis_home')" || return "$TRELLIS_EX_STATE"
  launcher="$(printf '%s\n' "$context" | jq -r '.launcher')" || return "$TRELLIS_EX_STATE"
  user_home_shell="$(printf '%s\n' "$context" | jq -r '.user_home_shell')" || return "$TRELLIS_EX_STATE"
  trellis_home_shell="$(printf '%s\n' "$context" | jq -r '.trellis_home_shell')" || return "$TRELLIS_EX_STATE"
  launcher_shell="$(printf '%s\n' "$context" | jq -r '.launcher_shell')" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$user_home" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$trellis_home" || return "$TRELLIS_EX_STATE"
  if [ -n "$expected_trellis_home" ]; then
    _attachment_canonical_dir "$expected_trellis_home" || return "$TRELLIS_EX_STATE"
    [ "$trellis_home" = "$expected_trellis_home" ] || return "$TRELLIS_EX_STATE"
  fi
  [ "$launcher" = "$user_home/.local/bin/trellis" ] || return "$TRELLIS_EX_STATE"
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
  {"path":["hooks","SessionStart",0,"hooks",0,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook session-context claude \"$CLAUDE_PROJECT_DIR\""},
  {"path":["hooks","SessionStart",0,"hooks",1,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook post-compact-context claude \"$CLAUDE_PROJECT_DIR\""},
  {"path":["hooks","SessionStart",0,"hooks",2,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook inject-primer-index claude \"$CLAUDE_PROJECT_DIR\""}
]
JSON
      ;;
    core-rules/templates/codex-hooks.local.json)
      cat <<'JSON'
[
  {"path":["hooks","SessionStart",0,"hooks",0,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook session-context codex \"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}\""},
  {"path":["hooks","SessionStart",0,"hooks",1,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook post-compact-context codex \"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}\""},
  {"path":["hooks","SessionStart",0,"hooks",2,"command"],"command":"/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook inject-primer-index codex \"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}\""}
]
JSON
      ;;
    *) printf '[]\n' ;;
  esac
}

attachment_contextual_render_required() {
  printf '%s\n' "$1" | jq -e '
    [.artifacts[]
     | select(
         .kind == "render"
         and (
           .template == "core-rules/templates/claude-settings.local.json"
           or .template == "core-rules/templates/codex-hooks.local.json"
         )
       )]
    | length > 0
  ' >/dev/null
}

attachment_contextual_template_render() {
  local source=$1 template=$2 context=$3 expected user_home trellis_home launcher
  local user_home_shell trellis_home_shell launcher_shell
  expected="$(attachment_contextual_template_expected "$template")" || return "$TRELLIS_EX_STATE"
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
    --argjson expected "$expected" '
      def contextual_command:
        split("__TRELLIS_USER_HOME__") | join($user_home_shell)
        | split("__TRELLIS_HOME__") | join($trellis_home_shell)
        | split("__TRELLIS_LAUNCHER__") | join($launcher_shell);
      reduce $expected[] as $entry (.;
        setpath($entry.path; ($entry.command | contextual_command)))
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
  chmod 700 "$value" || return 1
  [ "$(_attachment_mode "$value")" = 700 ]
}

_attachment_prepare_state() {
  local home=$1
  _attachment_canonical_dir "$home" || return 2
  chmod 700 "$home" || return 1
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
managed_dir=$(dirname "$shim_path") || exit 0
managed_dir=$(CDPATH= cd "$managed_dir" && pwd -P) || exit 0
previous=""
if [ -f "$managed_dir/previous-hooks-path" ] && [ ! -L "$managed_dir/previous-hooks-path" ]; then
  count=0
  line=""
  candidate=""
  while IFS= read -r candidate || [ -n "$candidate" ]; do
    count=$((count + 1))
    [ "$count" -eq 1 ] || exit 0
    line="$candidate"
    candidate=""
  done < "$managed_dir/previous-hooks-path"
  [ "$count" -eq 1 ] || exit 0
  previous="$line"
fi
[ -n "$previous" ] || exit 0
if [ "${previous#/}" != "$previous" ]; then
  prior_hook="$previous/@TRELLIS_HOOK_NAME@"
else
  project_root=$(CDPATH= cd . && pwd -P) || exit 0
  prior_hook="$project_root/$previous/@TRELLIS_HOOK_NAME@"
fi
if [ -n "$prior_hook" ] && { [ -f "$prior_hook" ] || [ -L "$prior_hook" ]; } && [ -x "$prior_hook" ]; then
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
) || return 1
  body=${body//@TRELLIS_RPAREN@/)}
  body=${body//@TRELLIS_HOOK_NAME@/$name}
  printf '%s\n' "$body"
}

# Prints the pass-through shim names implied by the previous hooks dir, one per
# line, sorted. Relative previous paths resolve against the checkout root. An
# empty, missing, or unreadable previous dir yields no names; only executable
# regular hooks are listed (git skips non-executable hooks anyway).
_attachment_hooks_expected_passthrough_names() {
  local root=${1:-} previous=${2:-} dir="" entry base
  [ -n "$previous" ] || return 0
  case "$previous" in
    /*) dir="$previous" ;;
    *)
      [ -n "$root" ] || return 0
      dir="$root/$previous"
      ;;
  esac
  [ -d "$dir" ] || return 0
  for entry in "$dir"/?* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=${entry##*/}
    _attachment_hooks_is_passthrough_name "$base" || continue
    if { [ -f "$entry" ] || [ -L "$entry" ]; } && [ -x "$entry" ]; then
      printf '%s\n' "$base"
    fi
  done | LC_ALL=C sort
  return 0
}

# Every pass-through shim present in the managed dir carries deterministic
# bytes and mode 700. Needs no checkout root: it validates content, not
# completeness, so detach stays drift-tolerant.
_attachment_hooks_present_shims_match() {
  local managed=${1:-} entry base
  for entry in "$managed"/?* "$managed"/.[!.]* "$managed"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=${entry##*/}
    case "$base" in
      post-checkout|pre-push|previous-hooks-path|release-payload|pre-push-source) continue ;;
    esac
    _attachment_hooks_is_passthrough_name "$base" || return 3
    _attachment_hooks_file_matches "$entry" "$(_attachment_hooks_passthrough_shim_body "$base")" 700 || return 3
  done
  return 0
}

# The managed dir holds exactly the shims implied by the previous hooks dir:
# every expected shim present with deterministic bytes and mode 700, and no
# shim beyond the expected set.
_attachment_hooks_verify_passthrough_shims() {
  local managed=${1:-} root=${2:-} previous=${3:-} expected="" name base entry nl wrapped
  expected=$(_attachment_hooks_expected_passthrough_names "$root" "$previous") || return 3
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    _attachment_hooks_file_matches "$managed/$name" "$(_attachment_hooks_passthrough_shim_body "$name")" 700 || return 3
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
  directory="$(CDPATH='' cd "$(dirname "$candidate")" && pwd -P)" || return 1
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

_attachment_hooks_dispatcher_common_body() {
  local payload=${1:-} source=${2:-} manifest_sha256=${3:-} emitters="" library="" predicate=""
  emitters="$(_attachment_command_scratch_emitters)" || return 1
  library="$(_attachment_library_source)" || return 1
  predicate="$(_attachment_extract_shell_function "$library" trellis_toolchain_control_only)" || return 1
  cat <<'EOF'
#!/bin/sh
caller_path=${PATH-}
caller_home=${HOME-}
caller_tmpdir=${TMPDIR-}
# Carry the set/unset distinction across the control-plane env -i without
# exporting the variable into the control-plane process.
caller_docker_host_set=${DOCKER_HOST+x}
caller_docker_host=${DOCKER_HOST-}
exec /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME=/dev/null \
  LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TRELLIS_ALLOW_MAIN_PUSH=${TRELLIS_ALLOW_MAIN_PUSH-} \
  SECURITY_GATE_SKIP=${SECURITY_GATE_SKIP-} \
  /bin/bash --noprofile --norc -c '
dispatcher=$1
caller_path=$2
caller_home=$3
caller_tmpdir=$4
caller_docker_host_set=$5
caller_docker_host=$6
shift 6
/usr/bin/grep -qx "# trellis-managed-dispatcher-body" "$dispatcher" || exit 1
body="$(/usr/bin/awk "seen { print } /^# trellis-managed-dispatcher-body\$/ { seen=1 }" "$dispatcher")" || exit 1
[ -n "$body" ] || exit 1
TRELLIS_MANAGED_DISPATCHER="$dispatcher"
export TRELLIS_MANAGED_DISPATCHER
eval "$body"
' trellis-managed-dispatcher "$0" "$caller_path" "$caller_home" "$caller_tmpdir" "$caller_docker_host_set" "$caller_docker_host" "$@"
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
  record="$(LC_ALL=C "$python_bin" -I -c "$program" "$home")" || return 1
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

trellis_readonly() {
  local path="$1" permissions="" mode="" numeric
  permissions="$(LC_ALL=C /bin/ls -ld -- "$path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  case "$permissions" in *+*) return 1 ;; esac
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
    size="$(printf '%s' "$target" | LC_ALL=C wc -c | tr -d ' ')" || return 1
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
    size="$(LC_ALL=C wc -c < "$path" | tr -d ' ')" || return 1
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
  releases_dir="$(dirname "$release_dir")" || return 1
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
  parent="$(dirname "$release_json")" || return 1
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

trellis_verify_release() (
  local payload="${1:-}" release_dir="" release_json="" version=""
  local tmpdir="" manifest_paths="" manifest_dirs="" actual_paths="" actual_dirs=""
  local mode="" oid="" path="" full="" parent="" actual_mode="" actual_oid="" target="" rel=""

  trellis_verify_release_anchor "$payload" || return 1
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
# attach-postjob.sh, which sources health-checks.sh and disk-janitor-agents.sh,
# so those are listed too. A listed file the release lacks refuses. The rest of
# the payload stays covered by that reconcile verify, by pre-push (its carriers
# keep trellis_verify_release) and by doctor.
trellis_verify_release_executed() {
  local payload="${1:-}" release_dir="" python_bin="" program="" permissions="" path=""
  local -a paths=(
    scripts/seed-inheritance-symlinks.sh
    scripts/lib/trellis-home.sh
    scripts/lib/local-registry.sh
    scripts/lib/release-store.sh
    scripts/lib/semver.sh
    scripts/lib/attachment.sh
    scripts/attach-project.sh
    scripts/lib/surface-plan.sh
    scripts/lib/skill-roots.sh
    scripts/trellis-launcher.sh
    scripts/lib/trellis.machine.schema.json
    scripts/lib/trellis.registry.schema.json
    scripts/lib/attach-fastpath.py
    scripts/lib/release-executed.py
    scripts/lib/attach-postjob.sh
    scripts/lib/health-checks.sh
    scripts/lib/disk-janitor-agents.sh
    scripts/lib/config-load.sh
    scripts/lib/hygiene-common.sh
    scripts/lib/disk-janitor-lib.sh
    scripts/lib/disk-janitor-dehydrate.sh
    scripts/lib/disk-janitor-host.sh
  )
  local -a listed=("$payload/scripts" "$payload/scripts/lib")

  trellis_verify_release_anchor "$payload" || return 1
  release_dir="${payload%/payload}"
  for path in "${paths[@]}"; do
    listed+=("$payload/$path")
  done
  # One ls refuses any ACL; python checks the rest. On macOS the "@" an xattr
  # puts after the mode hides the "+" of an ACL, so list the ACL entries
  # themselves with -e (one " 0: user:... allow write" line each). Where ls has
  # no -e (GNU), the mode column's "+" is reliable.
  permissions="$(LC_ALL=C /bin/ls -lde -- "${listed[@]}" 2>/dev/null)" ||
    permissions="$(LC_ALL=C /bin/ls -ld -- "${listed[@]}" 2>/dev/null)" || return 1
  printf '%s\n' "$permissions" |
    /usr/bin/awk '/^ *[0-9]+: / { acl = 1 } $1 ~ /\+/ { acl = 1 } END { exit acl }' || return 1
  python_bin="$(command -v python3)" || return 1
  case "$python_bin" in /*) ;; *) return 1 ;; esac
  program="$(trellis_verify_executed_program)" || return 1
  LC_ALL=C "$python_bin" -I -c "$program" \
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
  releases_dir="$(dirname "$release_dir")" || return 1
  [ "$releases_dir" = "$managed_home/releases" ] || return 1
  candidate="$payload/$source"
  parent="$(dirname "$candidate")" || return 1
  while :; do
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    actual="$(CDPATH= cd "$parent" && pwd -P)" || return 1
    [ "$actual" = "$parent" ] || return 1
    [ "$parent" = "$payload" ] && break
    parent="$(dirname "$parent")" || return 1
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
  local executable="$1" toolchain_path="" gate_home="" owner="" mode="" reason=""
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
  # The caller's DOCKER_HOST reaches the gate exactly when it was set
  # (empty-but-set stays set, unset stays absent), mirroring
  # trellis_run_prior_hook. The set/unset pair crossed the control-plane
  # env -i as positional args and is never exported there.
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
  local running="" generator=""
  case "$kind" in
    post-checkout|pre-push) ;;
    *) return 2 ;;
  esac
  running="$(_attachment_hooks_running_payload 2>/dev/null)" || running=""
  if [ -n "$running" ] && [ "$payload" = "$running" ]; then
    case "$kind" in
      post-checkout) _attachment_hooks_post_checkout_dispatcher_body_in_process "$payload" "$manifest" ;;
      pre-push) _attachment_hooks_pre_push_dispatcher_body_in_process "$payload" "$source" "$manifest" ;;
    esac
    return "$?"
  fi
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
  # A failed common body must not be hidden by the successful cat that follows.
  _attachment_hooks_dispatcher_common_body "${1:-}" "" "${2:-}" || return "$?"
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
if ! trellis_record_creation_base "$@"; then
  printf 'trellis post-checkout: warning: could not record branch creation base; use diff-base.sh set <parent>.\n' >&2
fi
previous="$(trellis_read_sidecar "$managed_dir/previous-hooks-path" true)" || exit 1
prior_status=0
prior_hook="$(trellis_prior_hook "$previous" post-checkout)" || prior_hook=""
if [ -n "$prior_hook" ] && { [ -f "$prior_hook" ] || [ -L "$prior_hook" ]; } && [ -x "$prior_hook" ]; then
  trellis_run_prior_hook "$prior_hook" "$@"
  prior_status=$?
fi
# Git passes 0 as the third argument for a file checkout (`git checkout --
# <path>`, `git restore`). It changes no branch and adds no worktree, so only
# the prior hook runs. A branch switch, a rebase and a new worktree pass 1.
if [ "${3:-}" = 0 ]; then
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
  printf 'trellis post-checkout: attachment reconciliation failed in an unsafe worktree; run `trellis worktree sync` and restart this session.\n' >&2
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
prior_status=0
prior_hook="$(trellis_prior_hook "$previous" pre-push)" || prior_hook=""
if [ -n "$prior_hook" ] && { [ -f "$prior_hook" ] || [ -L "$prior_hook" ]; } && [ -x "$prior_hook" ]; then
  trellis_run_prior_hook "$prior_hook" "$@" < "$refs_file"
  prior_status=$?
fi
carrier_status=0
payload=""
source=""
if payload="$(trellis_read_sidecar "$managed_dir/release-payload")" &&
   source="$(trellis_read_sidecar "$managed_dir/pre-push-source")" &&
   [ "$source" = "$expected_pre_push_source" ] &&
   carrier="$(trellis_managed_payload_file "$payload" "$source")"; then
  # The deferred attachment checks decide first: FAILED or blocked refuses,
  # ok passes, anything else runs them inline. Only then does the gate run.
  if postjob="$(trellis_managed_payload_file "$payload" scripts/lib/attach-postjob.sh verified)"; then
    trellis_run_control_payload "$postjob" prepush --target "$project_root" < /dev/null
    attach_status=$?
  else
    attach_status=1
    printf 'trellis pre-push: managed attachment checks are unavailable\n' >&2
  fi
  if [ "$attach_status" -eq 0 ]; then
    trellis_run_gate_payload "$carrier" "$@" < "$refs_file"
    carrier_status=$?
  else
    carrier_status=1
  fi
else
  carrier_status=1
  printf 'trellis pre-push: managed immutable release carrier is unavailable\n' >&2
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
      _attachment_hooks_verify_passthrough_shims "$managed" "$root" "$previous" || return 3
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
  parent=$(dirname "$path") || return 1
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
  parent=$(dirname "$relative") || return 1
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
  local plan=$1 root artifact path parent current part relative index kind destination
  local -a parts
  root=$(printf '%s\n' "$plan" | jq -r '.worktree_root') || return 2
  index=0
  while IFS= read -r artifact; do
    path=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
    kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
    parent=$(dirname "$path") || return 2
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
          printf '%s\n' "$plan" | jq -e --arg path "$relative" --argjson index "$index" \
            'any(.artifacts[0:$index][]; .kind == "parent" and .path == $path)' >/dev/null 2>&1 || return 2
        fi
      done
    fi
    destination="$root/$path"
    if [ "$kind" = parent ] && { [ -e "$destination" ] || [ -L "$destination" ]; }; then
      [ -d "$destination" ] && [ ! -L "$destination" ] || return 3
    fi
    index=$((index + 1))
  done < <(printf '%s\n' "$plan" | jq -c '.artifacts[]')
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
  local plan=$1 error_code=$2 artifact source expected actual
  while IFS= read -r artifact; do
    if [ "$(printf '%s\n' "$artifact" | jq -r '.kind')" = file ]; then
      if printf '%s\n' "$artifact" | jq -e 'has("source")' >/dev/null 2>&1; then
        source=$(printf '%s\n' "$artifact" | jq -r '.source') || return "$error_code"
        expected=$(printf '%s\n' "$artifact" | jq -r '.sha256') || return "$error_code"
        _attachment_canonical_file "$source" || return "$error_code"
        actual=$(_attachment_hash "$source") || return "$error_code"
        [ "$actual" = "$expected" ] || return "$error_code"
      else
        printf '%s\n' "$artifact" | jq -e '.content_base64 | type == "string"' >/dev/null 2>&1 || return "$error_code"
      fi
    fi
  done < <(printf '%s\n' "$plan" | jq -c '.artifacts[]')
  return 0
}

_attachment_destination() {
  printf '%s/%s\n' "$1" "$2"
}

_attachment_validate_destinations_absent() {
  local plan=$1 root artifact destination before_hash before_mode actual
  root=$(printf '%s\n' "$plan" | jq -r '.worktree_root') || return 2
  while IFS= read -r artifact; do
    destination=$(_attachment_destination "$root" "$(printf '%s\n' "$artifact" | jq -r '.path')")
    if printf '%s\n' "$artifact" | jq -e 'has("replace")' >/dev/null 2>&1; then
      [ -f "$destination" ] && [ ! -L "$destination" ] || return 3
      before_hash=$(printf '%s\n' "$artifact" | jq -r '.replace.before_sha256') || return 2
      before_mode=$(printf '%s\n' "$artifact" | jq -r '.replace.before_mode') || return 2
      actual=$(_attachment_hash "$destination") || return 3
      [ "$actual" = "$before_hash" ] && _attachment_mode_matches "$destination" "$before_mode" || return 3
    else
      [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 3
    fi
  done < <(printf '%s\n' "$plan" | jq -c '.artifacts[]')
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

_attachment_owner_json_valid() {
  local file=$1
  _attachment_json_file "$file" || return 2
  [ "$(_attachment_mode "$file")" = 600 ] || return 3
  jq -e '
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
  ' "$file" >/dev/null 2>&1 || return 2
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
  local path=$1 artifact=$2 kind expected actual target first mode
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 1
  [ -e "$path" ] || [ -L "$path" ] || return 1
  case "$kind" in
    file)
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
      expected=$(printf '%s\n' "$artifact" | jq -r '.sha256') || return 1
      actual=$(_attachment_hash "$path") || return 1
      [ "$actual" = "$expected" ] || return 1
      if printf '%s\n' "$artifact" | jq -e 'has("mode")' >/dev/null 2>&1; then
        mode=$(printf '%s\n' "$artifact" | jq -r '.mode') || return 1
        _attachment_mode_matches "$path" "$mode" || return 1
      fi
      ;;
    symlink)
      [ -L "$path" ] || return 1
      target=$(printf '%s\n' "$artifact" | jq -r '.target') || return 1
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
  local path=$1 artifact=$2 parent base actual_parent
  case "$path" in
    /*) parent=$(dirname "$path") || return 1 ;;
    *) parent=$(CDPATH='' cd "$(dirname "$path")" && pwd -P) || return 1 ;;
  esac
  base=$(basename "$path") || return 1
  _attachment_canonical_dir "$parent" || return 1
  (
    CDPATH='' cd "$parent" || return 1
    actual_parent=$(pwd -P) || return 1
    [ "$actual_parent" = "$parent" ] || return 1
    _attachment_path_exact "./$base" "$artifact"
  )
}

_attachment_artifact_exact() {
  local root=$1 artifact=$2 relative destination
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 1
  _attachment_parent_safe "$root" "$relative" || return 1
  destination=$(_attachment_destination "$root" "$relative")
  _attachment_path_exact_pinned "$destination" "$artifact"
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

_attachment_claim_layout() {
  local path=$1 nonce=$2 token entries
  [ -n "$nonce" ] || return 1
  token=$(_attachment_hash_text "$nonce:$path") || return 1
  _ATTACHMENT_QUARANTINE="$(dirname "$path")/.trellis-attachment-remove-$token"
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

_attachment_journal_claim_layout() {
  local journal=$1 path=$2 removal removal_path nonce
  removal=$(jq -c '.removal' "$journal") || return 1
  [ "$removal" != null ] || return 1
  removal_path=$(printf '%s\n' "$removal" | jq -r '.path') || return 1
  [ "$removal_path" = "$path" ] || return 1
  nonce=$(printf '%s\n' "$removal" | jq -r '.nonce') || return 1
  _attachment_claim_layout "$path" "$nonce"
}

_attachment_claim_namespace_valid() {
  local journal=$1 path=$2 parent removal removal_path nonce expected entry
  parent=$(dirname "$path") || return 1
  removal=$(jq -c '.removal' "$journal") || return 1
  expected=
  if [ "$removal" != null ]; then
    removal_path=$(printf '%s\n' "$removal" | jq -r '.path') || return 1
    if [ "$(dirname "$removal_path")" = "$parent" ]; then
      nonce=$(printf '%s\n' "$removal" | jq -r '.nonce') || return 1
      _attachment_claim_layout "$removal_path" "$nonce" || return 1
      expected=$_ATTACHMENT_QUARANTINE
    fi
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$expected" ] || return 1
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -name '.trellis-attachment-remove-*' -print 2>/dev/null) || return 1
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
  parent=$(dirname "$path") || return 2
  base=$(basename "$path") || return 2
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
    quarantine="./$(basename "$_ATTACHMENT_QUARANTINE")"
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
  trellis_jq -c --argjson keys "$keys" '
    def lookup($value; $path):
      reduce $path[] as $key ({value:$value,exists:true};
        if .exists and (.value | type) == "object" and (.value | has($key))
        then .value = .value[$key]
        else .exists = false
        end);
    . as $current
    | if ($current | type) != "object" then error("render destination is not an object")
      else [
        $keys[] as $owned
        | lookup($current; $owned.path) as $found
        | if ($found.exists | not) then {path:$owned.path,state:"missing"}
          elif $found.value != $owned.value then {path:$owned.path,state:"changed"}
          else empty
          end
      ]
      | sort_by(.path, .state)
      | unique_by(.path)
      end
  ' "$file" 2>/dev/null
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

_attachment_verify_owner_artifacts() {
  local owner=$1 expected_trellis_home="${2:-}" record root artifact render
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
  while IFS= read -r artifact; do
    _attachment_parent_safe "$root" "$(printf '%s\n' "$artifact" | jq -r '.path')" || return 3
    if ! _attachment_artifact_exact "$root" "$artifact"; then
      _attachment_diag "owned artifact does not match its record: $(printf '%s\n' "$artifact" | jq -r '"\(.path) (recorded \(.kind))"') under $root"
      return 3
    fi
  done < <(printf '%s\n' "$record" | jq -c '
    . as $owner
    | (($owner.renders // []) | map(.path)) as $render_paths
    | $owner.artifacts[] as $artifact
    | select(($render_paths | index($artifact.path)) == null)
    | $artifact
  ')
  while IFS= read -r render; do
    _attachment_render_owned_keys_exact "$root" "$render" || return 3
  done < <(printf '%s\n' "$record" | jq -c '(.renders // [])[]')
}

_attachment_verify_detach_owner_artifacts() {
  local owner=$1 record root artifact relative code
  record=$(jq -c . "$owner") && _attachment_validate_roots "$record" && _attachment_validate_ids "$record" &&
    root=$(printf '%s\n' "$record" | jq -r '.worktree_root') || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-record-invalid "$owner"
    return 3
  }
  # Sorted by path (jq's codepoint order is LC_ALL=C byte order for UTF-8), so
  # the drifted artifact reported first is deterministic.
  while IFS= read -r artifact; do
    relative=$(printf '%s\n' "$artifact" | jq -r '.path')
    if ! _attachment_parent_safe "$root" "$relative" || ! _attachment_artifact_exact "$root" "$artifact"; then
      code=owned-file-drift
      [ "$(printf '%s\n' "$artifact" | jq -r '.kind')" != symlink ] || code=owned-symlink-drift
      _attachment_refuse "${ATTACHMENT_ACTION:-}" "$code" "$root/$relative"
      return 3
    fi
  done < <(printf '%s\n' "$record" | jq -c '
    . as $owner
    | (($owner.renders // []) | map(.path)) as $render_paths
    | [$owner.artifacts[] as $artifact
       | select(($render_paths | index($artifact.path)) == null)
       | $artifact]
    | sort_by(.path)[]
  ')
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
_attachment_commit_program() {
  cat <<'PY'
import base64
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import random
import signal
import stat
import string
import sys

# Exit statuses match the shell publish path they replace: 1 I/O, 2 shape,
# 3 conflict. FAULT is the pre-existing numeric ATTACHMENT_FAULT_PHASE stop.
FAULT = 75
ORPHANED = 76
REMOVE_PREFIX = ".trellis-attachment-remove-"


class Stop(Exception):
    def __init__(self, status):
        Exception.__init__(self, status)
        self.status = status


def refuse(status=3):
    raise Stop(status)


def orphaned():
    # Our parent is no longer the shell recorded as the lock owner, so a
    # recovery may already own the worktree: stop without another write.
    sys.stderr.write("trellis attachment: commit stopped: the transaction lock owner is gone\n")
    sys.stderr.flush()
    os._exit(ORPHANED)


def checkpoint(label):
    # Called after every durable step. The crash suites substitute this one
    # line in a copy of the program; nothing in the product activates it.
    return None  # crash-test seam


def has_controls(value):
    return any(ord(char) < 32 or ord(char) == 127 for char in value)


def valid_absolute(value):
    if not value.startswith("/") or value == "/" or value.endswith("/"):
        return False
    if "//" in value or "/./" in value or "/../" in value:
        return False
    if value.endswith("/.") or value.endswith("/.."):
        return False
    return not has_controls(value)


def lstat_or_none(path):
    try:
        return os.lstat(path)
    except OSError:
        return None


def no_symlink_components(value):
    if not valid_absolute(value):
        return False
    parts = value[1:].split("/")
    current = ""
    for index, part in enumerate(parts):
        if not part:
            return False
        current += "/" + part
        info = lstat_or_none(current)
        if info is None or stat.S_ISLNK(info.st_mode):
            return False
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            return False
    return True


def canonical_dir(value):
    # Pins the working directory, like the shell's `cd` + `pwd -P`.
    if not no_symlink_components(value):
        return False
    info = lstat_or_none(value)
    if info is None or not stat.S_ISDIR(info.st_mode):
        return False
    try:
        os.chdir(value)
        return os.getcwd() == value
    except OSError:
        return False


def canonical_file(value):
    if not no_symlink_components(value):
        return False
    info = lstat_or_none(value)
    if info is None or not stat.S_ISREG(info.st_mode):
        return False
    parent, base = os.path.split(value)
    try:
        os.chdir(parent or "/")
        actual = os.getcwd()
    except OSError:
        return False
    return (("/" + base) if actual == "/" else (actual + "/" + base)) == value


def identity(path):
    info = lstat_or_none(path)
    if info is None:
        return ""
    return "%d:%d" % (info.st_dev, info.st_ino)


def is_file(path):
    info = lstat_or_none(path)
    return info is not None and stat.S_ISREG(info.st_mode)


def is_dir(path):
    info = lstat_or_none(path)
    return info is not None and stat.S_ISDIR(info.st_mode)


def is_link(path):
    info = lstat_or_none(path)
    return info is not None and stat.S_ISLNK(info.st_mode)


def exists(path):
    return lstat_or_none(path) is not None


def rename_exclusive(source, destination):
    # rename(2) silently replaces an empty directory, so a directory raced into
    # the destination would be lost; refuse it instead, as the shell's mv did.
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        result = libc.renamex_np(source.encode(), destination.encode(), ctypes.c_uint(0x4))  # RENAME_EXCL
    else:
        result = libc.renameat2(-100, source.encode(), -100, destination.encode(), ctypes.c_uint(0x1))  # AT_FDCWD, RENAME_NOREPLACE
    if result != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            refuse(3)
        raise OSError(code, os.strerror(code), destination)


def hold_transaction_lock(holder, owner_pid):
    # The transaction lock is recorded against the shell that started us, and
    # a SIGKILL of that shell does not stop us. Hold a flock in the lock's
    # holder for our whole life: recovery reclaims the lock only once it is
    # free. A shell that died before we took it may already have been
    # reclaimed, so stop before any mutation if our parent is not that shell.
    if not canonical_dir(holder):
        refuse(3)
    fd = os.open(holder + "/publisher.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        refuse(3)
    if os.getppid() != owner_pid:
        orphaned()
    return fd


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_text(value):
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()


def mode_matches(path, expected):
    info = lstat_or_none(path)
    return info is not None and format(stat.S_IMODE(info.st_mode), "o") == expected[1:]


def identity_matches(path, expected, kind, dir_fd=None):
    if not expected:
        return False
    try:
        info = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return False
    if kind == "file" and not stat.S_ISREG(info.st_mode):
        return False
    if kind == "symlink" and not stat.S_ISLNK(info.st_mode):
        return False
    if kind in ("directory", "parent") and not stat.S_ISDIR(info.st_mode):
        return False
    return "%d:%d" % (info.st_dev, info.st_ino) == expected


def open_fresh_dir(name):
    # Pin a directory we just created before changing it: a symlink swapped in
    # after the mkdir fails O_NOFOLLOW, and the pinned inode must still be the
    # entry by that name.
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        refuse(3)
    if identity(name) != fd_identity(fd):
        os.close(fd)
        refuse(3)
    return fd


def fd_identity(fd):
    info = os.fstat(fd)
    return "%d:%d" % (info.st_dev, info.st_ino)


def path_exact(path, artifact):
    kind = artifact["kind"]
    if kind == "file":
        if not is_file(path) or sha256_file(path) != artifact["sha256"]:
            return False
        return "mode" not in artifact or mode_matches(path, artifact["mode"])
    if kind == "symlink":
        return is_link(path) and os.readlink(path) == artifact["target"]
    if kind == "directory":
        return is_dir(path) and not os.listdir(path)
    if kind == "parent":
        return is_dir(path)
    return False


def path_exact_pinned(name, artifact):
    # `name` is relative to the pinned working directory.
    here = os.getcwd()
    return canonical_dir(here) and path_exact("./" + name, artifact)


def parent_safe(root, relative):
    parent = os.path.dirname(relative)
    if not parent:
        return True
    current = root
    for part in parent.split("/"):
        if not part:
            return False
        current += "/" + part
        if not is_dir(current):
            return False
    return True


def replace_before_matches(path, artifact):
    replace = artifact["replace"]
    return (is_file(path) and sha256_file(path) == replace["before_sha256"]
            and mode_matches(path, replace["before_mode"]))


def claim_layout(path, nonce):
    return os.path.dirname(path) + "/" + REMOVE_PREFIX + sha256_text(nonce + ":" + path)


def claim_namespace_valid(path, removal):
    parent = os.path.dirname(path)
    expected = None
    if removal is not None and os.path.dirname(removal["path"]) == parent:
        expected = claim_layout(removal["path"], removal["nonce"])
    try:
        entries = os.listdir(parent)
    except OSError:
        return True
    return all(parent + "/" + entry == expected
               for entry in entries if entry.startswith(REMOVE_PREFIX))


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
  LC_ALL=C "$python_bin" -I -c "$program" \
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
  local home=$1 owner=$2 checkout worktree canonical
  [ "$#" -eq 2 ] || return 2
  _attachment_prepare_state "$home" || return $?
  _attachment_owner_json_valid "$owner" || return $?
  checkout=$(jq -r '.checkout_id' "$owner") || return 2
  worktree=$(jq -r '.worktree_id' "$owner") || return 2
  canonical=$(_attachment_ownership_path "$home" "$checkout" "$worktree")
  [ "$owner" = "$canonical" ] || return 2
  _attachment_verify_owner_artifacts "$owner" "$home"
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
  trap 'rm -f "$tmp"' RETURN
  printf '%s\n' "$data" > "$tmp" || return 1
  chmod 600 "$tmp" || return 1
  _attachment_owner_json_valid "$tmp"
  rc=$?
  rm -f "$tmp"
  trap - RETURN
  return "$rc"
}

_attachment_detach_journal_valid() {
  local file=$1 original next transfer expected after attachment journal_dir state_dir home transfer_path transfer_checkout transfer_worktree
  _attachment_valid_absolute "$file" || return 2
  _attachment_json_file "$file" || return 2
  [ "$(_attachment_mode "$file")" = 600 ] || return 3
  jq -e '
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
  ' "$file" >/dev/null 2>&1 || return 2
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
  trellis_jq -e --argjson original "$original" --argjson next "$next" '
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
  ' "$file" >/dev/null 2>&1 || return 2
  _attachment_validate_roots "$original" || return 2
  _attachment_validate_ids "$original" || return 2
  attachment=$(jq -r '.attachment_id' "$file") || return 2
  journal_dir=$(dirname "$file") || return 2
  state_dir=$(dirname "$journal_dir") || return 2
  home=$(dirname "$state_dir") || return 2
  [ "$journal_dir" = "$home/state/attachment-journals" ] || return 2
  [ "$file" = "$(_attachment_detach_journal_path "$home" "$attachment")" ] || return 2
  _attachment_detach_render_pending_runtime_valid "$file" || return $?
  if [ "$transfer" != null ]; then
    transfer_path=$(printf '%s\n' "$transfer" | jq -r '.owner_path') || return 2
    transfer_checkout=$(printf '%s\n' "$expected" | jq -r '.checkout_id') || return 2
    transfer_worktree=$(printf '%s\n' "$expected" | jq -r '.worktree_id') || return 2
    [ "$transfer_path" = "$(_attachment_ownership_path "$home" "$transfer_checkout" "$transfer_worktree")" ] || return 2
  fi
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
  local journal=$1 pending original root attachment render stage identity recorded bytes expected mode parent base actual_parent stage_rc expected_parent
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
    _attachment_detach_render_set_stage_identity_impl "$journal" "$identity"
    stage_rc=$?
    if [ "$stage_rc" -ne 0 ]; then exec 9>&-; return "$stage_rc"; fi
    chmod "${mode#0}" "./$base" || { exec 9>&-; return 1; }
    if ! printf '%s' "$bytes" | base64 -D 2>/dev/null >&9; then
      printf '%s' "$bytes" | base64 -d 2>/dev/null >&9 || { exec 9>&-; return 1; }
    fi
    exec 9>&-
    _attachment_identity_matches "./$base" "$identity" file || return 3
    [ "$(_attachment_hash "./$base")" = "$expected" ] && _attachment_mode_matches "./$base" "$mode" || return 3
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
      claimed|empty)
        _attachment_discard_pinned_claim "$journal" "$stage" "$result_artifact" "$identity" || return $?
        ;;
      absent)
        [ -e "$stage" ] || [ -L "$stage" ] || return 3
        _attachment_claim_pinned "$journal" "$stage" "$result_artifact" "$identity" || return $?
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

_attachment_detach_preflight_remaining() {
  local journal=$1 root=$2 artifact
  while IFS= read -r artifact; do
    _attachment_artifact_exact "$root" "$artifact" || {
      _attachment_refuse "${ATTACHMENT_ACTION:-}" artifact-changed "$root/$(printf '%s\n' "$artifact" | jq -r '.path')"
      return 3
    }
  done < <(jq -c '.remove | sort_by(.path)[]' "$journal")
}

_attachment_detach_remove_one() {
  local journal=$1 root=$2 artifact=$3 relative destination kind status
  relative=$(printf '%s\n' "$artifact" | jq -r '.path') || return 2
  destination=$(_attachment_destination "$root" "$relative")
  _attachment_parent_safe "$root" "$relative" || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" artifact-changed "$destination"
    return 3
  }
  kind=$(printf '%s\n' "$artifact" | jq -r '.kind') || return 2
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
  local home=$1 journal=$2 original next_owner owner root total phase artifact current
  original=$(jq -c '.original_owner' "$journal") || return 2
  next_owner=$(jq -c '.next_owner' "$journal") || return 2
  owner=$(_attachment_ownership_path "$home" "$(printf '%s\n' "$original" | jq -r '.checkout_id')" "$(printf '%s\n' "$original" | jq -r '.worktree_id')")
  root=$(printf '%s\n' "$original" | jq -r '.worktree_root') || return 2
  total=$(jq '.remove | length' "$journal") || return 2
  phase=$(jq -r '.phase' "$journal") || return 2
  if [ "$(jq -r '.owner_committed' "$journal")" = true ]; then
    if { [ "$next_owner" = null ] && { [ -e "$owner" ] || [ -L "$owner" ]; }; } ||
      { [ "$next_owner" != null ] && ! _attachment_detach_file_matches_data "$owner" "$next_owner"; }; then
      _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-changed "$owner"
      return 3
    fi
    return 0
  fi
  if ! _attachment_detach_file_matches_data "$owner" "$original"; then
    if [ "$phase" -eq "$total" ]; then
      if { [ "$next_owner" = null ] && [ ! -e "$owner" ] && [ ! -L "$owner" ]; } ||
        { [ "$next_owner" != null ] && _attachment_detach_file_matches_data "$owner" "$next_owner"; }; then
        _attachment_detach_journal_update "$journal" '.owner_committed = true' || return $?
        return 0
      fi
    fi
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-changed "$owner"
    return 3
  fi
  if [ "$phase" -eq 0 ]; then _attachment_detach_preflight_remaining "$journal" "$root" || return $?; fi
  while [ "$phase" -lt "$total" ]; do
    artifact=$(jq -c --argjson index "$phase" '.remove[$index]' "$journal") || return 2
    _attachment_detach_remove_one "$journal" "$root" "$artifact" || return $?
    phase=$((phase + 1))
    _attachment_detach_journal_update "$journal" --argjson phase "$phase" '.phase = $phase'
  done
  _attachment_detach_file_matches_data "$owner" "$original" || {
    _attachment_refuse "${ATTACHMENT_ACTION:-}" owner-changed "$owner"
    return 3
  }
  if [ "$next_owner" = null ]; then
    rm -- "$owner" || return 1
  else
    _attachment_write_json "$owner" "$next_owner" || return $?
  fi
  _attachment_detach_journal_update "$journal" '.owner_committed = true'
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
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" || return $?
  _attachment_install_lock_traps
  _attachment_upgrade_legacy_detach_render_pending "$journal" || return $?
  _attachment_detach_journal_valid "$journal" || return $?
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
  _attachment_lock_reclaim "$home" "$checkout" "$worktree" "$attachment" || return $?
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" || return $?
  _attachment_install_lock_traps
  _attachment_upgrade_legacy_detach_render_pending "$journal" || return $?
  _attachment_detach_journal_valid "$journal" || return $?
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
  _attachment_map_public_status "$status"
}

attachment_detach_render_stage() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_stage_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_render_claim() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_claim_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_render_publish() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_publish_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_render_cleanup() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_cleanup_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_render_finish() {
  local status
  [ "$#" -eq 1 ] || return 2
  _attachment_detach_render_finish_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_mark_external_phase() {
  local status
  [ "$#" -eq 3 ] || return 2
  _attachment_detach_mark_external_phase_impl "$@"; status=$?
  _attachment_map_public_status "$status"
}

attachment_detach_finalize() {
  local status
  [ "$#" -eq 2 ] || return 2
  _attachment_detach_finalize_impl "$@"; status=$?
  _attachment_map_public_status "$status"
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
    folded_trellis=$(LC_ALL=C printf '%s' "$trellis_home" | tr '[:upper:]' '[:lower:]') || return 4
    folded_destination=$(LC_ALL=C printf '%s' "$destination" | tr '[:upper:]' '[:lower:]') || return 4
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
  local file=$1 keys=$2
  trellis_jq -e --argjson keys "$keys" '
    def exists_at($value; $path):
      reduce $path[] as $key ({value:$value,exists:true};
        if .exists and (.value | type) == "object" and (.value | has($key))
        then .value = .value[$key] else .exists = false end) | .exists;
    . as $current
    | ($current | type) == "object"
    and all($keys[]; . as $owned
      | exists_at($current; $owned.path)
      and (($current | getpath($owned.path)) == $owned.value))
  ' "$file" >/dev/null 2>&1
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
  local expected_snapshot expected_mode kind quoted_destination quoted_snapshot
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
  repair=$(printf 'rm -f -- %s && { printf %%s %s | base64 -D 2>/dev/null || printf %%s %s | base64 -d; } > %s && chmod %s %s' \
    "$quoted_destination" "$quoted_snapshot" "$quoted_snapshot" "$quoted_destination" \
    "${expected_mode#0}" "$quoted_destination")
  if [ -n "$identity" ]; then
    printf 'trellis: user attachment recovery conflict: leave journal %s in place; managed %s %s no longer has its pinned filesystem identity/content. Unknown bytes were preserved; restore the journaled regular-file snapshot instead.\n' \
      "$journal" "$kind" "$destination" >&2
  else
    printf 'trellis: user attachment recovery conflict: leave journal %s in place; pending replacement %s is neither its journaled before snapshot nor a journal-pinned managed destination. Unknown bytes were preserved; restore the journaled regular-file snapshot instead.\n' \
      "$journal" "$destination" >&2
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
  trellis_jq -S --argjson keys "$keys" --argjson created "$created" --slurpfile before "$before_tmp" '
    def exists_at($value; $path):
      reduce $path[] as $key ({value:$value,exists:true};
        if .exists and (.value | type) == "object" and (.value | has($key))
        then .value = .value[$key] else .exists = false end) | .exists;
    $before[0] as $before
    | reduce $keys[] as $owned (. ;
        if exists_at($before; $owned.path)
        then setpath($owned.path; ($before | getpath($owned.path)))
        else delpaths([$owned.path])
        end)
    | reduce ($created | sort_by(length) | reverse[]) as $path
        (. ; if exists_at(.; $path)
                 and ((getpath($path) | type) == "object")
                 and ((getpath($path) | length) == 0)
             then delpaths([$path]) else . end)
  ' "$destination" > "$tmp" || return 3
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
  local home=$1 journal=$2 retain=${3:-false} owner original phase total original_data pending
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
    while [ "$(jq -r '.external.render_phase' "$journal")" -lt "$(jq '.external.renders | length' "$journal")" ]; do
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

# Reclaim and acquire, waiting a bounded 10 s while the lock is held. The
# detached post-attach job holds it for brief steps right after every attach,
# so an attach or adopt landing in that window must wait rather than refuse.
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
    [ "$rc" -eq "${TRELLIS_EX_CONFLICT:-3}" ] && [ "$tries" -lt 40 ] || return "$rc"
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
