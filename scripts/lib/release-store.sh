#!/usr/bin/env bash
# Immutable Trellis release-store primitives.
#
# Bash 3.2 compatible. This file intentionally has no dependency on the later
# trellis-home/local-registry libraries so T4 can stand alone.

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  _RELEASE_STORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=semver.sh
  . "$_RELEASE_STORE_LIB_DIR/semver.sh"
fi

release_store_err() {
  printf 'trellis release: %s\n' "$*" >&2
}

release_store_trim_trailing_slashes() {
  local path="${1:-}"
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  printf '%s\n' "$path"
}

release_store_absolute_path_is_clean() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\t'*|*$'\n'*|*$'\r'*|*/../*|*/..|*/./*|*/.|*'//'*) return 1 ;;
  esac
  return 0
}

release_store_home() {
  local home
  if [ -n "${TRELLIS_HOME:-}" ]; then
    home="$TRELLIS_HOME"
  else
    [ -n "${HOME:-}" ] || {
      release_store_err "HOME is required when TRELLIS_HOME is unset"
      return 2
    }
    home="$HOME/.trellis"
  fi
  home="$(release_store_trim_trailing_slashes "$home")"
  if ! release_store_absolute_path_is_clean "$home"; then
    release_store_err "TRELLIS_HOME must be an absolute path without traversal: $home"
    return 2
  fi
  printf '%s\n' "$home"
}

release_store_releases_dir() {
  local home
  home="$(release_store_home)" || return $?
  printf '%s/releases\n' "$home"
}

release_store_ensure_dir_0700() {
  local dir="$1"
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    release_store_err "path exists but is not a directory: $dir"
    return 5
  fi
  mkdir -p "$dir" || return 5
  chmod 700 "$dir" || return 5
}

release_store_ensure_store_dirs() {
  local home releases
  home="$(release_store_home)" || return $?
  releases="$(release_store_releases_dir)" || return $?
  release_store_ensure_dir_0700 "$home" || return $?
  release_store_ensure_dir_0700 "$releases" || return $?
}

release_store_canonical_releases_dir() {
  local home releases home_canon releases_canon expected
  home="$(release_store_home)" || return $?
  releases="$(release_store_releases_dir)" || return $?
  if [ ! -d "$home" ]; then
    release_store_err "release home is unavailable: $home"
    return 4
  fi
  home_canon="$(cd "$home" && pwd -P)" || return 4
  expected="$home_canon/releases"
  if [ ! -d "$releases" ]; then
    if [ -e "$releases" ] || [ -L "$releases" ]; then
      release_store_err "release store path is not a directory: $releases"
      return 4
    fi
    release_store_err "release store is unavailable: $releases"
    return 4
  fi
  releases_canon="$(cd "$releases" && pwd -P)" || return 4
  if [ "$releases_canon" != "$expected" ]; then
    release_store_err "release store escapes canonical home: $releases -> $releases_canon"
    return 4
  fi
  printf '%s\n' "$releases_canon"
}

release_store_normalize_version() {
  local input="${1:-}" version
  version="$input"
  case "$version" in
    v*) version="${version#v}" ;;
  esac
  if [ -z "$version" ] || [ "${version#v}" != "$version" ] || ! semver_is_valid "$version"; then
    release_store_err "invalid semver version: ${input:-<empty>}"
    return 2
  fi
  printf '%s\n' "$version"
}

release_store_version_from_input() {
  release_store_normalize_version "${1:-}"
}

release_store_tag_for_version() {
  local version
  version="$(release_store_normalize_version "${1:-}")" || return $?
  printf 'v%s\n' "$version"
}

release_store_release_path() {
  local version releases
  version="$(release_store_normalize_version "${1:-}")" || return $?
  releases="$(release_store_canonical_releases_dir)" || return $?
  printf '%s/%s\n' "$releases" "$version"
}

release_store_assert_release_dir_contained() {
  local release_dir="${1:-}" version="${2:-}" releases expected actual parent parent_actual base
  version="$(release_store_normalize_version "$version")" || return $?
  releases="$(release_store_canonical_releases_dir)" || return $?
  expected="$releases/$version"
  case "$expected" in
    "$releases"/*) ;;
    *)
      release_store_err "release path escapes release store: $expected"
      return 4
      ;;
  esac
  if [ -L "$release_dir" ]; then
    release_store_err "release directory is a symlink: $release_dir"
    return 4
  fi
  if [ -d "$release_dir" ]; then
    actual="$(cd "$release_dir" && pwd -P)" || return 4
    if [ "$actual" != "$expected" ]; then
      release_store_err "release directory escapes canonical store: $release_dir -> $actual"
      return 4
    fi
    return 0
  fi
  if [ -e "$release_dir" ]; then
    release_store_err "release path exists but is not a directory: $release_dir"
    return 4
  fi
  parent="$(dirname "$release_dir")"
  base="$(basename "$release_dir")"
  parent_actual="$(cd "$parent" && pwd -P)" || return 4
  if [ "$parent_actual" != "$releases" ] || [ "$base" != "$version" ]; then
    release_store_err "release path escapes release store: $release_dir"
    return 4
  fi
}

release_store_assert_temp_dir_contained() {
  local temp_dir="${1:-}" releases actual
  releases="$(release_store_canonical_releases_dir)" || return $?
  if [ -L "$temp_dir" ] || [ ! -d "$temp_dir" ]; then
    release_store_err "temporary release directory is unavailable: $temp_dir"
    return 4
  fi
  actual="$(cd "$temp_dir" && pwd -P)" || return 4
  case "$actual" in
    "$releases"/.tmp.*) return 0 ;;
  esac
  release_store_err "temporary release directory escapes release store: $temp_dir -> $actual"
  return 4
}

release_store_locate() {
  local path version raw_releases
  version="$(release_store_normalize_version "${1:-}")" || return $?
  raw_releases="$(release_store_releases_dir)" || return $?
  if [ ! -e "$raw_releases" ] && [ ! -L "$raw_releases" ]; then
    release_store_err "release not installed: $version"
    return 5
  fi
  path="$(release_store_release_path "$version")" || return $?
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    release_store_err "release not installed: $version"
    return 5
  fi
  release_store_verify_path "$path" "$version" || return $?
  printf '%s\n' "$path"
}

release_store_list() {
  local raw_releases releases dir base normalized status rc=0
  local -a versions=()
  raw_releases="$(release_store_releases_dir)" || return $?
  if [ ! -e "$raw_releases" ] && [ ! -L "$raw_releases" ]; then
    return 0
  fi
  releases="$(release_store_canonical_releases_dir)" || return $?
  for dir in "$releases"/*; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    base="$(basename "$dir")"
    case "$base" in
      *.lock)
        normalized="$(release_store_normalize_version "${base%.lock}" 2>/dev/null)" || {
          release_store_err "unexpected release store entry: $base"
          rc=4
        }
        if [ -n "${normalized:-}" ] && { [ ! -d "$dir" ] || [ -L "$dir" ]; }; then
          release_store_err "unexpected release store entry: $base"
          rc=4
        fi
        continue
        ;;
    esac
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
      release_store_err "unexpected release store entry: $base"
      rc=4
      continue
    fi
    normalized="$(release_store_normalize_version "$base" 2>/dev/null)" || {
      release_store_err "unexpected release store entry: $base"
      rc=4
      continue
    }
    if [ "$normalized" != "$base" ]; then
      release_store_err "unexpected release store entry: $base"
      rc=4
      continue
    fi
    if release_store_verify_path "$dir" "$base"; then
      versions[${#versions[@]}]="$base"
    else
      status=$?
      if [ "$status" -gt "$rc" ]; then
        rc="$status"
      fi
    fi
  done
  if [ "${#versions[@]}" -gt 0 ]; then
    printf '%s\n' "${versions[@]}" | sort
  fi
  return "$rc"
}

release_store_path_is_safe() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  case "$path" in
    /*|.|..|./*|../*|*/../*|*/..|*/./*|*/.|*/|*'//'*) return 1 ;;
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

release_store_symlink_target_is_safe() {
  local link_path="${1:-}" target="${2:-}" parent="" rest component resolved=""
  release_store_path_is_safe "$link_path" || return 1
  [ -n "$target" ] || return 1
  case "$target" in
    /*|*'//'*) return 1 ;;
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$link_path" in
    */*) parent="${link_path%/*}" ;;
  esac
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
        case "$resolved" in
          */*) resolved="${resolved%/*}" ;;
          *) resolved="" ;;
        esac
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
  return 0
}

release_store_first_symlink_component() {
  local path="${1:-}" rest current component
  release_store_absolute_path_is_clean "$path" || return 1
  rest="${path#/}"
  current=""
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
      *) component="$rest"; rest="" ;;
    esac
    [ -n "$component" ] || continue
    current="$current/$component"
    if [ -L "$current" ]; then
      printf '%s\n' "$current"
      return 0
    fi
  done
  return 1
}

release_store_is_writable_mode() {
  local path="$1" perms write_bits
  perms="$(LC_ALL=C /bin/ls -ld -- "$path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  case "$perms" in
    *+*) return 1 ;;
  esac
  write_bits="$(/usr/bin/printf '%s' "$perms" | /usr/bin/awk '{p=substr($0,1,10); print substr(p,3,1) substr(p,6,1) substr(p,9,1)}')"
  [ "$write_bits" = "---" ]
}

release_store_mode_for_path() {
  local path="$1" perms exec_bits
  if [ -L "$path" ]; then
    printf '120000\n'
    return 0
  fi
  [ -f "$path" ] || return 1
  perms="$(LC_ALL=C ls -ld "$path" 2>/dev/null | awk '{print $1}')" || return 1
  exec_bits="$(printf '%s' "$perms" | awk '{print substr($0,4,1) substr($0,7,1) substr($0,10,1)}')"
  case "$exec_bits" in
    ---) printf '100644\n' ;;
    *) printf '100755\n' ;;
  esac
}

release_store_blob_oid_for_path() {
  local path="$1" target
  if [ -L "$path" ]; then
    target="$(readlink "$path")" || return 1
    printf '%s' "$target" | git hash-object --stdin
    return $?
  fi
  git hash-object "$path"
}

# Batched permission / mode helpers. Per-entry `ls | awk` and `git hash-object`
# spawns are the verify hot path; these follow the launcher collector so one
# `xargs ls` and one `git hash-object --stdin-paths` cover the whole tree.
release_store_permissions_not_writable() {
  local permissions="$1" write_bits
  case "$permissions" in
    *+*) return 1 ;;
  esac
  [ "${#permissions}" -ge 10 ] || return 1
  write_bits="${permissions:2:1}${permissions:5:1}${permissions:8:1}"
  [ "$write_bits" = "---" ]
}

release_store_mode_for_permissions() {
  local permissions="$1" exec_bits
  [ "${#permissions}" -ge 10 ] || return 1
  exec_bits="${permissions:3:1}${permissions:6:1}${permissions:9:1}"
  case "$exec_bits" in
    ---) printf '100644\n' ;;
    *) printf '100755\n' ;;
  esac
}

# Pair a NUL-separated absolute-path list with a newline-separated path list of
# the same length and order. ACL '+' is kept on the permission field so the
# writable-content refusal stays identical to release_store_is_writable_mode.
release_store_collect_permissions() {
  local paths_nul="$1" paths="$2" rows="$3" ls_rows="$4" permissions="$5"
  local path permission extra

  : > "$rows" || return 1
  [ -s "$paths_nul" ] || return 0
  LC_ALL=C /usr/bin/xargs -0 /bin/ls -fdl < "$paths_nul" > "$ls_rows" || return 1
  /usr/bin/awk '{ print $1 }' "$ls_rows" > "$permissions" || return 1

  exec 3< "$permissions" || return 1
  while IFS= read -r path; do
    if ! IFS= read -r permission <&3; then
      exec 3<&-
      return 1
    fi
    printf '%s\t%s\n' "$path" "$permission" >> "$rows" || {
      exec 3<&-
      return 1
    }
  done < "$paths"
  if IFS= read -r extra <&3; then
    exec 3<&-
    return 1
  fi
  exec 3<&-
}

release_store_make_tree_writable() {
  local root="${1:-}"
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  find "$root" -depth -type d -exec chmod u+w {} \; 2>/dev/null
}

release_store_mktemp_dir() {
  local template="$1" tmp
  tmp="$(mktemp -d "$template")" || return 5
  chmod 700 "$tmp" || {
    rm -rf "$tmp"
    return 5
  }
  printf '%s\n' "$tmp"
}

release_store_atomic_rename() {
  local operation="${1:-}" source="${2:-}" destination="${3:-}" python_bin="" rc
  case "$operation" in
    no-replace|swap) ;;
    *)
      release_store_err "unknown atomic rename operation: $operation"
      return 5
      ;;
  esac
  if ! command -v python3 >/dev/null 2>&1; then
    release_store_err "python3 is required for kernel-enforced atomic release publication"
    return 5
  fi
  python_bin="$(command -v python3)"

  "$python_bin" - "$operation" "$source" "$destination" <<'PY'
import ctypes
import errno
import os
import platform
import sys

operation, source, destination = sys.argv[1:4]
libc = ctypes.CDLL(None, use_errno=True)
source = source.encode("utf-8")
destination = destination.encode("utf-8")

def call(function, *args):
    ctypes.set_errno(0)
    result = function(*args)
    if result != 0:
        error_number = ctypes.get_errno() or errno.EIO
        raise OSError(error_number, os.strerror(error_number))

def rename_with_kernel_no_replace_or_swap():
    system = sys.platform
    if system == "darwin":
        function = getattr(libc, "renameatx_np", None)
        if function is None:
            raise OSError(errno.ENOSYS, "renameatx_np is unavailable")
        function.argtypes = [
            ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
        ]
        function.restype = ctypes.c_int
        at_fdcwd = -2
        flags = 0x00000004 if operation == "no-replace" else 0x00000002
        call(function, at_fdcwd, source, at_fdcwd, destination, flags)
        return

    if system.startswith("linux"):
        function = getattr(libc, "renameat2", None)
        at_fdcwd = -100
        flags = 0x00000001 if operation == "no-replace" else 0x00000002
        if function is not None:
            function.argtypes = [
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
            ]
            function.restype = ctypes.c_int
            call(function, at_fdcwd, source, at_fdcwd, destination, flags)
            return

        syscall_numbers = {
            "x86_64": 316,
            "amd64": 316,
            "aarch64": 276,
            "arm64": 276,
            "i386": 353,
            "i686": 353,
        }
        syscall_number = syscall_numbers.get(platform.machine().lower())
        if syscall_number is None:
            raise OSError(errno.ENOSYS, "renameat2 syscall is unavailable")
        function = libc.syscall
        function.restype = ctypes.c_long
        call(
            function,
            ctypes.c_long(syscall_number),
            ctypes.c_int(at_fdcwd),
            ctypes.c_char_p(source),
            ctypes.c_int(at_fdcwd),
            ctypes.c_char_p(destination),
            ctypes.c_uint(flags),
        )
        return

    raise OSError(errno.ENOSYS, "kernel atomic rename is unavailable")

try:
    rename_with_kernel_no_replace_or_swap()
except OSError as error:
    conflict_errors = (errno.EEXIST, errno.ENOTEMPTY, errno.ENOENT)
    unsupported_errors = (
        errno.ENOSYS,
        errno.EINVAL,
        errno.EOPNOTSUPP,
        getattr(errno, "ENOTSUP", errno.EOPNOTSUPP),
    )
    if error.errno in conflict_errors:
        sys.exit(17)
    if error.errno in unsupported_errors:
        sys.exit(18)
    sys.exit(19)
PY
  rc=$?
  case "$rc" in
    0) return 0 ;;
    17) return 3 ;;
    18)
      release_store_err "kernel does not support atomic no-replace/swap publication"
      return 5
      ;;
    *)
      release_store_err "kernel atomic release publication failed"
      return 5
      ;;
  esac
}

release_store_rename_no_clobber() {
  release_store_atomic_rename no-replace "$1" "$2"
}

release_store_rename_swap() {
  release_store_atomic_rename swap "$1" "$2"
}

release_store_test_barrier() {
  local phase="${1:-}" root="${TRELLIS_TEST_RELEASE_BARRIER_DIR:-}" timeout="${TRELLIS_TEST_RELEASE_BARRIER_TIMEOUT:-30}"
  local ticks=0 max_ticks
  [ -n "$root" ] || return 0
  case "$phase" in
    install-before-publish|adopt-before-publish) ;;
    *)
      release_store_err "invalid release test barrier phase: $phase"
      return 5
      ;;
  esac
  if ! release_store_absolute_path_is_clean "$root" || [ -L "$root" ] || [ ! -d "$root" ]; then
    release_store_err "release test barrier is unavailable: $root"
    return 5
  fi
  case "$timeout" in
    ''|*[!0-9]*)
      release_store_err "release test barrier timeout must be a non-negative integer"
      return 5
      ;;
  esac
  max_ticks=$((timeout * 10))
  printf '%s\n' "$$" > "$root/$phase.ready" || return 5
  while [ ! -f "$root/$phase.release" ]; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      release_store_err "release test barrier timed out: $phase"
      return 5
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  return 0
}

release_store_json_valid() {
  local release_json="$1"
  jq -e '
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
    and (.version | type == "string" and test(semver))
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

# Successful verification is memoized for the shell process that performed it
# and its subshells (call sites capture through `$(...)`, which is why the
# value is exported rather than plain). Every key is prefixed with that
# shell's `$$`, so a value inherited by an exec'd child -- which would carry
# an arbitrarily old success verdict across a fresh process boundary -- can
# never match and the child re-verifies. Failure is never recorded.
# Key: canonical release dir, sha256(release.json) from
# release_store_release_json_sha256_no_follow, plus skip_writable, allow_stage,
# and expected_version.
# TOCTOU: equivalent to the existing verify-then-use window. The caller already
# verifies and then uses the payload; a same-process tamper after a successful
# verify was already outside that check. The memo is not shared across processes,
# so a cross-process tamper is still refused on the next invocation.
: "${_TRELLIS_RELEASE_STORE_VERIFY_MEMO:=}"

release_store_verify_memo_key() {
  local release_dir="${1:-}" expected_version="${2:-}" skip_writable="${3:-0}" allow_stage="${4:-0}"
  local canon parent base digest
  [ -n "$release_dir" ] || return 1
  [ ! -L "$release_dir" ] && [ -d "$release_dir" ] || return 1
  canon="$(cd "$release_dir" && pwd -P)" || return 1
  parent="$(dirname "$canon")"
  base="$(basename "$canon")"
  [ -n "$parent" ] && [ -n "$base" ] || return 1
  digest="$(release_store_release_json_sha256_no_follow "$parent" "$base" 2>/dev/null)" || return 1
  case "$digest" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$$"$'\t'"$canon"$'\t'"$digest"$'\t'"$skip_writable"$'\t'"$allow_stage"$'\t'"$expected_version"
}

release_store_verify_memo_hit() {
  local key="${1:-}" line
  [ -n "$key" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$key" ] && return 0
  done <<EOF
${_TRELLIS_RELEASE_STORE_VERIFY_MEMO}
EOF
  return 1
}

release_store_verify_path() {
  local release_dir="${1:-}" expected_version="${2:-}" skip_writable="${3:-0}" allow_stage="${4:-0}"
  local key="" rc=0
  key="$(release_store_verify_memo_key "$release_dir" "$expected_version" "$skip_writable" "$allow_stage")" || key=""
  if [ -n "$key" ] && release_store_verify_memo_hit "$key"; then
    return 0
  fi
  release_store_verify_path_body "$release_dir" "$expected_version" "$skip_writable" "$allow_stage" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$key" ]; then
    _TRELLIS_RELEASE_STORE_VERIFY_MEMO="${_TRELLIS_RELEASE_STORE_VERIFY_MEMO}${key}"$'\n'
    export _TRELLIS_RELEASE_STORE_VERIFY_MEMO
  fi
  return "$rc"
}

release_store_verify_path_body() (
  set +e
  local release_dir="${1:-}" expected_version="${2:-}" skip_writable="${3:-0}" allow_stage="${4:-0}"
  local release_json payload_dir version expected_norm tag tmpdir manifest_paths manifest_dirs fs_paths fs_dirs rc=0
  local mode oid path full actual_mode actual_oid dir rel count release_canon payload_canon parent symlink_component entry base link_target
  local tree_ok=1 tab hash_paths hash_expected hash_actual manifest_rows
  local file_paths file_paths_nul file_perm_rows file_perm_ls file_perm_raw
  local link_paths link_paths_nul link_targets link_target_dir link_target_index
  local dir_paths dir_paths_nul dir_perm_rows dir_perm_ls dir_perm_raw
  local permission extra link_path_count link_target_count target_file

  if ! command -v jq >/dev/null 2>&1; then
    release_store_err "jq is required"
    return 5
  fi
  if ! command -v git >/dev/null 2>&1; then
    release_store_err "git is required"
    return 5
  fi
  if [ -L "$release_dir" ]; then
    release_store_err "release directory is a symlink: $release_dir"
    return 4
  fi
  if [ ! -d "$release_dir" ]; then
    release_store_err "release directory missing: $release_dir"
    return 4
  fi
  release_json="$release_dir/release.json"
  if [ -L "$release_json" ] || [ ! -f "$release_json" ] || ! release_store_json_valid "$release_json"; then
    release_store_err "release record is missing or invalid: $release_json"
    return 4
  fi

  version="$(jq -r '.version' "$release_json")" || return 4
  version="$(release_store_normalize_version "$version")" || return $?
  if [ -n "$expected_version" ]; then
    expected_norm="$(release_store_normalize_version "$expected_version")" || return $?
    if [ "$version" != "$expected_norm" ]; then
      release_store_err "release version mismatch: expected $expected_norm, found $version"
      return 4
    fi
  fi
  tag="$(jq -r '.tag' "$release_json")" || return 4
  if [ "$tag" != "v$version" ]; then
    release_store_err "release tag/version mismatch in $release_json"
    return 4
  fi

  if [ "$allow_stage" = "1" ]; then
    release_store_assert_temp_dir_contained "$release_dir" || return 4
  else
    release_store_assert_release_dir_contained "$release_dir" "$version" || return 4
  fi

  release_canon="$(cd "$release_dir" && pwd -P)" || return 4
  payload_dir="$release_dir/payload"
  if [ -L "$payload_dir" ] || [ ! -d "$payload_dir" ]; then
    release_store_err "release payload directory missing or invalid: payload"
    return 4
  fi
  payload_canon="$(cd "$payload_dir" && pwd -P)" || return 4
  if [ "$payload_canon" != "$release_canon/payload" ]; then
    release_store_err "release payload escapes release directory: $payload_dir -> $payload_canon"
    return 4
  fi

  # Match launcher_verify_release_body's canonical store-adjacent scratch.
  # The launcher drops TMPDIR under `env -i`; this does not disable global /tmp.
  # The verification sandbox denies that global-temp fallback. Ignore ambient
  # TMPDIR for direct library callers too, keeping scratch within the store.
  # A read-only store parent reports unavailable rather than falling back
  # outside the store.
  tmpdir="$(release_store_mktemp_dir "${release_canon%/*}/.tmp.$version.verify.XXXXXX")" || return 5
  cleanup_verify() {
    [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ] && rm -rf "$tmpdir"
  }
  trap cleanup_verify EXIT INT TERM

  manifest_paths="$tmpdir/manifest.paths"
  fs_paths="$tmpdir/fs.paths"
  jq -r '.tree[].path' "$release_json" > "$manifest_paths" || return 4
  sort "$manifest_paths" > "$manifest_paths.sorted"
  count="$(uniq -d "$manifest_paths.sorted" | wc -l | tr -d ' ')"
  if [ "$count" != "0" ]; then
    release_store_err "duplicate manifest path in $release_json"
    rc=4
  fi

  manifest_dirs="$tmpdir/manifest.dirs"
  : > "$manifest_dirs"
  while IFS= read -r path; do
    rel="$path"
    while [ "${rel%/*}" != "$rel" ]; do
      rel="${rel%/*}"
      printf '%s\n' "$rel" >> "$manifest_dirs"
    done
  done < "$manifest_paths"
  sort -u "$manifest_dirs" > "$manifest_dirs.sorted"

  find "$release_canon" -mindepth 1 -maxdepth 1 -print |
    while IFS= read -r entry; do
      base="$(basename "$entry")"
      case "$base" in
        release.json|payload) ;;
        *)
          release_store_err "unexpected release top-level entry: $base"
          exit 42
          ;;
      esac
    done
  if [ "$?" -ne 0 ]; then
    rc=4
  fi

  tab="$(printf '\t')"
  manifest_rows="$tmpdir/manifest.rows"
  hash_paths="$tmpdir/hash.paths"
  hash_expected="$tmpdir/hash.expected"
  hash_actual="$tmpdir/hash.actual"
  file_paths="$tmpdir/file.paths"
  file_paths_nul="$tmpdir/file.paths.nul"
  file_perm_rows="$tmpdir/file.perm.rows"
  file_perm_ls="$tmpdir/file.perm.ls"
  file_perm_raw="$tmpdir/file.perm.raw"
  link_paths="$tmpdir/link.paths"
  link_paths_nul="$tmpdir/link.paths.nul"
  link_targets="$tmpdir/link.targets"
  link_target_dir="$tmpdir/link-targets"
  jq -r '.tree[] | [.mode, .oid, .path] | @tsv' "$release_json" > "$manifest_rows" || return 4
  : > "$file_paths"
  : > "$file_paths_nul"
  : > "$link_paths"
  : > "$link_paths_nul"
  : > "$hash_paths"
  : > "$hash_expected"

  while IFS="$tab" read -r mode oid path; do
    if ! release_store_path_is_safe "$path"; then
      release_store_err "unsafe manifest path: $path"
      tree_ok=0
      break
    fi
    case "$path" in
      */*) parent="$payload_canon/${path%/*}" ;;
      *) parent="$payload_canon" ;;
    esac
    if symlink_component="$(release_store_first_symlink_component "$parent")"; then
      release_store_err "symlinked release payload parent for $path: $symlink_component"
      tree_ok=0
      break
    fi
    full="$payload_canon/$path"
    if [ ! -e "$full" ] && [ ! -L "$full" ]; then
      release_store_err "missing release content: $path"
      tree_ok=0
      break
    fi
    case "$mode" in
      120000)
        if [ -L "$full" ]; then
          printf '%s\n' "$path" >> "$link_paths"
          printf '%s\0' "$full" >> "$link_paths_nul"
        elif [ -f "$full" ]; then
          actual_mode="$(release_store_mode_for_path "$full")" || actual_mode="100644"
          release_store_err "wrong mode for $path: expected $mode, found $actual_mode"
          tree_ok=0
          break
        else
          release_store_err "wrong release content type: $path"
          tree_ok=0
          break
        fi
        ;;
      100644|100755)
        if [ -L "$full" ]; then
          release_store_err "wrong mode for $path: expected $mode, found 120000"
          tree_ok=0
          break
        fi
        if [ ! -f "$full" ]; then
          release_store_err "wrong release content type: $path"
          tree_ok=0
          break
        fi
        printf '%s\n' "$path" >> "$file_paths"
        printf '%s\0' "$full" >> "$file_paths_nul"
        ;;
      *)
        actual_mode="$(release_store_mode_for_path "$full" 2>/dev/null)" || actual_mode="unknown"
        release_store_err "wrong mode for $path: expected $mode, found $actual_mode"
        tree_ok=0
        break
        ;;
    esac
  done < "$manifest_rows"
  if [ "$tree_ok" != "1" ]; then
    rc=4
  fi

  if [ "$tree_ok" = "1" ]; then
    if ! release_store_collect_permissions \
      "$file_paths_nul" "$file_paths" "$file_perm_rows" "$file_perm_ls" "$file_perm_raw"; then
      rc=4
      tree_ok=0
    fi
  fi

  if [ "$tree_ok" = "1" ] && [ -s "$link_paths_nul" ]; then
    LC_ALL=C xargs -0 readlink < "$link_paths_nul" > "$link_targets" || {
      release_store_err "could not read release symlink"
      rc=4
      tree_ok=0
    }
    if [ "$tree_ok" = "1" ]; then
      link_path_count=0
      while IFS= read -r path; do
        link_path_count=$((link_path_count + 1))
      done < "$link_paths"
      link_target_count=0
      while IFS= read -r link_target; do
        link_target_count=$((link_target_count + 1))
      done < "$link_targets"
      if [ "$link_path_count" -ne "$link_target_count" ]; then
        release_store_err "could not read release symlink"
        rc=4
        tree_ok=0
      fi
    fi
    if [ "$tree_ok" = "1" ]; then
      mkdir "$link_target_dir" || {
        rc=5
        tree_ok=0
      }
    fi
  fi

  if [ "$tree_ok" = "1" ]; then
    exec 3< "$file_perm_rows" || {
      rc=4
      tree_ok=0
    }
  fi
  if [ "$tree_ok" = "1" ] && [ -s "$link_paths_nul" ]; then
    exec 4< "$link_targets" || {
      exec 3<&-
      release_store_err "could not read release symlink"
      rc=4
      tree_ok=0
    }
  fi
  link_target_index=0
  if [ "$tree_ok" = "1" ]; then
    while IFS="$tab" read -r mode oid path; do
      full="$payload_canon/$path"
      case "$mode" in
        120000)
          if ! IFS= read -r link_target <&4; then
            exec 3<&-
            exec 4<&-
            release_store_err "could not read release symlink: $path"
            tree_ok=0
            break
          fi
          if ! release_store_symlink_target_is_safe "$path" "$link_target"; then
            exec 3<&-
            exec 4<&-
            release_store_err "unsafe release symlink target: $path"
            tree_ok=0
            break
          fi
          link_target_index=$((link_target_index + 1))
          target_file="$link_target_dir/$link_target_index"
          printf '%s' "$link_target" > "$target_file" || {
            exec 3<&-
            exec 4<&-
            tree_ok=0
            rc=5
            break
          }
          printf '%s\n' "$target_file" >> "$hash_paths"
          printf '%s\t%s\t%s\t%s\n' "$path" "$oid" "link" "-" >> "$hash_expected"
          ;;
        100644|100755)
          if ! IFS="$tab" read -r rel permission <&3; then
            exec 3<&-
            exec 4<&-
            release_store_err "wrong release content type: $path"
            tree_ok=0
            break
          fi
          if [ "$rel" != "$path" ]; then
            exec 3<&-
            exec 4<&-
            release_store_err "wrong release content type: $path"
            tree_ok=0
            break
          fi
          actual_mode="$(release_store_mode_for_permissions "$permission")" || {
            exec 3<&-
            exec 4<&-
            release_store_err "wrong release content type: $path"
            tree_ok=0
            break
          }
          if [ "$actual_mode" != "$mode" ]; then
            exec 3<&-
            exec 4<&-
            release_store_err "wrong mode for $path: expected $mode, found $actual_mode"
            tree_ok=0
            break
          fi
          printf '%s\n' "$full" >> "$hash_paths"
          printf '%s\t%s\t%s\t%s\n' "$path" "$oid" "file" "$permission" >> "$hash_expected"
          ;;
        *)
          exec 3<&-
          exec 4<&-
          tree_ok=0
          break
          ;;
      esac
    done < "$manifest_rows"
    exec 3<&-
    exec 4<&-
  fi
  if [ "$tree_ok" != "1" ] && [ "$rc" -eq 0 ]; then
    rc=4
  fi

  if [ "$tree_ok" = "1" ] && [ -s "$hash_paths" ]; then
    git hash-object --no-filters --stdin-paths < "$hash_paths" > "$hash_actual" || {
      release_store_err "could not hash release content"
      rc=4
      tree_ok=0
    }
  elif [ "$tree_ok" = "1" ]; then
    : > "$hash_actual"
  fi

  if [ "$tree_ok" = "1" ]; then
    exec 3< "$hash_actual" || {
      release_store_err "could not hash release content"
      rc=4
      tree_ok=0
    }
  fi
  if [ "$tree_ok" = "1" ]; then
    while IFS="$tab" read -r path oid extra permission; do
      if ! IFS= read -r actual_oid <&3; then
        exec 3<&-
        release_store_err "could not hash release content: $path"
        tree_ok=0
        break
      fi
      if [ "$actual_oid" != "$oid" ]; then
        exec 3<&-
        release_store_err "changed release content: $path"
        tree_ok=0
        break
      fi
      if [ "$skip_writable" != "1" ] && [ "$extra" = "file" ]; then
        if ! release_store_permissions_not_writable "$permission"; then
          exec 3<&-
          release_store_err "writable release content: $path"
          tree_ok=0
          break
        fi
      fi
    done < "$hash_expected"
    if [ "$tree_ok" = "1" ]; then
      if IFS= read -r extra <&3; then
        exec 3<&-
        release_store_err "could not hash release content"
        tree_ok=0
      fi
    fi
    exec 3<&-
  fi
  if [ "$tree_ok" != "1" ] && [ "$rc" -eq 0 ]; then
    rc=4
  fi

  if [ "$?" -ne 0 ]; then
    rc=4
  fi

  : > "$fs_paths"
  fs_dirs="$tmpdir/fs.dirs"
  : > "$fs_dirs"
  if ! (
    cd "$payload_canon" || exit 1
    find . -mindepth 1 -print0 > "$tmpdir/fs.raw"
  ); then
    release_store_err "could not enumerate release payload"
    return 4
  fi
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    if ! release_store_path_is_safe "$rel"; then
      release_store_err "unsafe release payload path: $rel"
      return 4
    fi
    full="$payload_canon/$rel"
    if [ -L "$full" ] || [ -f "$full" ]; then
      printf '%s\n' "$rel" >> "$fs_paths"
    elif [ -d "$full" ]; then
      printf '%s\n' "$rel" >> "$fs_dirs"
    else
      release_store_err "unexpected release payload content type: $rel"
      return 4
    fi
  done < "$tmpdir/fs.raw"
  sort "$fs_paths" > "$fs_paths.sorted"
  sort "$fs_dirs" > "$fs_dirs.sorted"

  if ! diff -u "$manifest_paths.sorted" "$fs_paths.sorted" >/dev/null 2>&1; then
    diff -u "$manifest_paths.sorted" "$fs_paths.sorted" >&2
    release_store_err "release payload has missing or added paths"
    rc=4
  fi
  if ! diff -u "$manifest_dirs.sorted" "$fs_dirs.sorted" >/dev/null 2>&1; then
    diff -u "$manifest_dirs.sorted" "$fs_dirs.sorted" >&2
    release_store_err "release payload has missing or added directories"
    rc=4
  fi

  if [ "$skip_writable" != "1" ]; then
    dir_paths="$tmpdir/all.dirs"
    dir_paths_nul="$tmpdir/all.dirs.nul"
    dir_perm_rows="$tmpdir/dir.perm.rows"
    dir_perm_ls="$tmpdir/dir.perm.ls"
    dir_perm_raw="$tmpdir/dir.perm.raw"
    if ! find "$release_canon" -type d -print > "$dir_paths"; then
      rc=4
    else
      : > "$dir_paths_nul"
      while IFS= read -r dir; do
        printf '%s\0' "$dir" >> "$dir_paths_nul"
      done < "$dir_paths"
      if ! release_store_collect_permissions \
        "$dir_paths_nul" "$dir_paths" "$dir_perm_rows" "$dir_perm_ls" "$dir_perm_raw"; then
        rc=4
      else
        while IFS="$tab" read -r dir permission; do
          if ! release_store_permissions_not_writable "$permission"; then
            release_store_err "writable release directory: ${dir#$release_canon/}"
            rc=4
            break
          fi
        done < "$dir_perm_rows"
      fi
    fi
    if ! release_store_is_writable_mode "$release_json"; then
      release_store_err "writable release record: release.json"
      rc=4
    fi
  fi

  return "$rc"
)

release_store_verify() {
  local version="${1:-}" path raw_releases releases dir base normalized status rc=0
  if [ -n "$version" ]; then
    raw_releases="$(release_store_releases_dir)" || return $?
    if [ ! -e "$raw_releases" ] && [ ! -L "$raw_releases" ]; then
      release_store_err "release not installed: $version"
      return 5
    fi
    path="$(release_store_release_path "$version")" || return $?
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      release_store_err "release not installed: $version"
      return 5
    fi
    release_store_verify_path "$path" "$version"
    return $?
  fi

  raw_releases="$(release_store_releases_dir)" || return $?
  if [ ! -e "$raw_releases" ] && [ ! -L "$raw_releases" ]; then
    return 0
  fi
  releases="$(release_store_canonical_releases_dir)" || return $?
  for dir in "$releases"/*; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    base="$(basename "$dir")"
    case "$base" in
      *.lock)
        normalized="$(release_store_normalize_version "${base%.lock}" 2>/dev/null)" || {
          release_store_err "unexpected release store entry: $base"
          rc=4
        }
        if [ -n "${normalized:-}" ] && { [ ! -d "$dir" ] || [ -L "$dir" ]; }; then
          release_store_err "unexpected release store entry: $base"
          rc=4
        fi
        continue
        ;;
    esac
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
      release_store_err "unexpected release store entry: $base"
      rc=4
      continue
    fi
    normalized="$(release_store_normalize_version "$base" 2>/dev/null)" || {
      release_store_err "unexpected release store entry: $base"
      rc=4
      continue
    }
    if [ "$normalized" != "$base" ]; then
      release_store_err "unexpected release store entry: $base"
      rc=4
      continue
    fi
    if release_store_verify_path "$dir" "$base"; then
      :
    else
      status=$?
      if [ "$status" -gt "$rc" ]; then
        rc="$status"
      fi
    fi
  done
  return "$rc"
}

# Pinned copies of `trellis_process_birth_python` and `trellis_process_birth`
# (scripts/lib/trellis-home.sh — the normative definitions and the reason the
# Darwin reader exists at all). Byte-identical by contract once the name prefix
# is applied; scripts/tests/process-birth.bats compares the extracted bodies.
# This library's header declares that it depends on nothing above
# semver.sh so it can stand alone before any later library may be sourced;
# reaching the shared function by sourcing trellis-home.sh would break that,
# exactly as it does for release_store_snapshot_payload_matches below.
release_store_process_birth_python() {
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

# release_store_process_birth <pid>
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
release_store_process_birth() {
  local pid program
  pid="${1:-}"
  case "$pid" in
    ""|*[!0-9]*|0*) return 2 ;;
  esac
  [ "$pid" -le 2147483647 ] || return 2
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    command -v python3 >/dev/null 2>&1 || return 1
    program="$(release_store_process_birth_python)" || return 1
    LC_ALL=C python3 -I -c "$program" "$pid" 2>/dev/null || return "$?"
    return 0
  fi
  LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || return 1
  return 0
}

# An execution snapshot is owned by the long-lived shell that requested it,
# rather than by the short-lived command-substitution process that creates it.
# Bash 3.2 keeps $$ bound to that long-lived shell across both subshell forms.
release_store_write_snapshot_owner() {
  local snapshot="${1:-}" owner owner_pid owner_birth owner_json python_bin
  [ "$#" -eq 1 ] || {
    release_store_err "snapshot owner requires SNAPSHOT_PATH"
    return 2
  }
  release_store_absolute_path_is_clean "$snapshot" || {
    release_store_err "snapshot owner path is unsafe: $snapshot"
    return 2
  }
  owner="${snapshot}.owner.json"
  owner_pid="$$"
  case "$owner_pid" in
    ''|*[!0-9]*)
      release_store_err "snapshot owner process id is invalid"
      return 5
      ;;
  esac
  [ "$owner_pid" -gt 0 ] || {
    release_store_err "snapshot owner process id is invalid"
    return 5
  }
  owner_birth="$(release_store_process_birth "$owner_pid")" || {
    release_store_err "could not determine snapshot owner process birth"
    return 5
  }
  [ -n "$owner_birth" ] || {
    release_store_err "could not determine snapshot owner process birth"
    return 5
  }
  command -v jq >/dev/null 2>&1 || {
    release_store_err "jq is required to write snapshot owner metadata"
    return 5
  }
  owner_json="$(jq -cn --argjson pid "$owner_pid" --arg process_birth "$owner_birth" \
    '{schema_version:1,pid:$pid,process_birth:$process_birth}')" || {
    release_store_err "could not encode snapshot owner metadata"
    return 5
  }
  [ -n "$owner_json" ] || {
    release_store_err "could not encode snapshot owner metadata"
    return 5
  }
  command -v python3 >/dev/null 2>&1 || {
    release_store_err "python3 with no-follow create support is required for snapshot owner metadata"
    return 5
  }
  python_bin="$(command -v python3)" || return 5
  if ! "$python_bin" - "$owner" "$owner_json" 2>/dev/null <<'PY'
import os
import sys

path, payload = sys.argv[1:3]
no_follow = getattr(os, "O_NOFOLLOW", 0)
if not no_follow:
    raise SystemExit(1)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | no_follow, 0o600)
try:
    data = (payload + "\n").encode("utf-8")
    while data:
        written = os.write(fd, data)
        if written <= 0:
            raise OSError("short owner metadata write")
        data = data[written:]
    os.fsync(fd)
finally:
    os.close(fd)
PY
  then
    release_store_err "could not create snapshot owner metadata: $owner"
    return 5
  fi
}

# Snapshotting closes the verify-then-execute gap for consumers of an installed
# release.  Every source lookup below is rooted in an O_NOFOLLOW release-store
# descriptor; the returned snapshot is private, immutable, and independently
# verified before any caller may execute it.
release_store_release_json_sha256_no_follow() {
  local releases="${1:-}" entry="${2:-}" python_bin
  release_store_absolute_path_is_clean "$releases" || {
    release_store_err "release snapshot store path is unsafe: $releases"
    return 2
  }
  case "$entry" in
    ''|.|..|*/*|*$'\t'*|*$'\n'*|*$'\r'*)
      release_store_err "release snapshot entry is unsafe: ${entry:-<empty>}"
      return 2
      ;;
  esac
  command -v python3 >/dev/null 2>&1 || {
    release_store_err "python3 with descriptor-relative snapshot support is required"
    return 5
  }
  python_bin="$(command -v python3)" || return 5

  "$python_bin" - "$releases" "$entry" <<'PY'
import hashlib
import os
import stat
import sys

releases, entry = sys.argv[1:3]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def fail(code, message):
    sys.stderr.write("trellis release: %s\n" % message)
    raise SystemExit(code)


def unavailable(message):
    fail(5, message)


def state(message):
    fail(4, message)


def identity(value):
    return (value.st_dev, value.st_ino)


def fingerprint(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        getattr(value, "st_mtime_ns", int(value.st_mtime * 1000000000)),
        getattr(value, "st_ctime_ns", int(value.st_ctime * 1000000000)),
    )


if not O_DIRECTORY or not O_NOFOLLOW:
    unavailable("descriptor-relative no-follow snapshot support is unavailable")

releases_fd = None
release_fd = None
record_fd = None
try:
    releases_fd = os.open(releases, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if not stat.S_ISDIR(os.fstat(releases_fd).st_mode):
        state("release snapshot store is not a directory")

    before_release = os.stat(entry, dir_fd=releases_fd, follow_symlinks=False)
    if not stat.S_ISDIR(before_release.st_mode):
        state("release snapshot source is not a real directory")
    release_fd = os.open(
        entry,
        os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
        dir_fd=releases_fd,
    )
    opened_release = os.fstat(release_fd)
    after_release = os.stat(entry, dir_fd=releases_fd, follow_symlinks=False)
    if identity(before_release) != identity(opened_release) or identity(after_release) != identity(opened_release):
        state("release snapshot source changed while opening")

    before_record = os.stat("release.json", dir_fd=release_fd, follow_symlinks=False)
    if not stat.S_ISREG(before_record.st_mode):
        state("release snapshot record is not a regular file")
    record_fd = os.open(
        "release.json",
        os.O_RDONLY | O_NOFOLLOW,
        dir_fd=release_fd,
    )
    opened_record = os.fstat(record_fd)
    if not stat.S_ISREG(opened_record.st_mode) or identity(before_record) != identity(opened_record):
        state("release snapshot record changed while opening")

    digest = hashlib.sha256()
    while True:
        chunk = os.read(record_fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)

    after_record = os.stat("release.json", dir_fd=release_fd, follow_symlinks=False)
    final_record = os.fstat(record_fd)
    if fingerprint(before_record) != fingerprint(after_record) or fingerprint(before_record) != fingerprint(final_record):
        state("release snapshot record changed while hashing")
    sys.stdout.write(digest.hexdigest() + "\n")
except (AttributeError, NotImplementedError):
    unavailable("descriptor-relative no-follow snapshot support is unavailable")
except OSError as error:
    state("could not hash release snapshot record without following links: %s" % error)
finally:
    if record_fd is not None:
        os.close(record_fd)
    if release_fd is not None:
        os.close(release_fd)
    if releases_fd is not None:
        os.close(releases_fd)
PY
}

release_store_copy_snapshot_no_follow() {
  local releases="${1:-}" version="${2:-}" snapshot_base="${3:-}" digest="${4:-}" python_bin
  release_store_absolute_path_is_clean "$releases" || {
    release_store_err "release snapshot store path is unsafe: $releases"
    return 2
  }
  release_store_normalize_version "$version" >/dev/null || return $?
  # VERSION-BOUND, matching `launcher_copy_snapshot_no_follow`, which gates the
  # identical copy with `launcher_snapshot_name_is_safe "$releases"
  # "$snapshot_base" "$version"`. The bare `.tmp.*.exec.*` glob this used to
  # carry accepted any release's snapshot name under any version — including
  # `.tmp.<other-version>.exec.<n>.exec.<suffix>`, the exact shape the pinned
  # predicate exists to reject — while the python below resolves the SOURCE from
  # $version, so the two halves could disagree about which release was being
  # snapshotted. The pinned predicate also subsumes the separate
  # slash/tab/newline check: a `/` breaks the `$releases` parent match and any
  # other delimiter fails the `[!A-Za-z0-9]` suffix test.
  release_store_snapshot_name_is_safe "$releases" "$snapshot_base" "$version" || {
    release_store_err "release snapshot destination is unsafe: ${snapshot_base:-<empty>}"
    return 2
  }
  case "$digest" in
    ''|*[!0-9a-f]*)
      release_store_err "release snapshot record digest is invalid"
      return 2
      ;;
  esac
  if [ "${#digest}" -ne 64 ]; then
    release_store_err "release snapshot record digest is invalid"
    return 2
  fi
  command -v python3 >/dev/null 2>&1 || {
    release_store_err "python3 with descriptor-relative snapshot support is required"
    return 5
  }
  python_bin="$(command -v python3)" || return 5

  "$python_bin" - "$releases" "$version" "$snapshot_base" "$digest" <<'PY'
import hashlib
import os
import stat
import sys

releases, version, snapshot_name, expected_digest = sys.argv[1:5]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def fail(code, message):
    sys.stderr.write("trellis release: %s\n" % message)
    raise SystemExit(code)


def unavailable(message):
    fail(5, message)


def state(message):
    fail(4, message)


def identity(value):
    return (value.st_dev, value.st_ino)


def fingerprint(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        getattr(value, "st_mtime_ns", int(value.st_mtime * 1000000000)),
        getattr(value, "st_ctime_ns", int(value.st_ctime * 1000000000)),
    )


def safe_name(name):
    return name not in ("", ".", "..") and "/" not in name and "\x00" not in name


def lstat_at(parent_fd, name, label):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow snapshot support is unavailable")
    except OSError as error:
        state("could not inspect %s without following links: %s" % (label, error))


def open_directory(parent_fd, name, label):
    before = lstat_at(parent_fd, name, label)
    if not stat.S_ISDIR(before.st_mode):
        state("%s is not a real directory" % label)
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow snapshot support is unavailable")
    except OSError as error:
        state("could not open %s without following links: %s" % (label, error))
    opened = os.fstat(descriptor)
    after = lstat_at(parent_fd, name, label)
    if not stat.S_ISDIR(opened.st_mode) or identity(before) != identity(opened) or identity(after) != identity(opened):
        os.close(descriptor)
        state("%s changed while opening" % label)
    return descriptor


def open_regular(parent_fd, name, label):
    before = lstat_at(parent_fd, name, label)
    if not stat.S_ISREG(before.st_mode):
        state("%s is not a regular file" % label)
    try:
        descriptor = os.open(name, os.O_RDONLY | O_NOFOLLOW, dir_fd=parent_fd)
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow snapshot support is unavailable")
    except OSError as error:
        state("could not open %s without following links: %s" % (label, error))
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or identity(before) != identity(opened):
        os.close(descriptor)
        state("%s changed while opening" % label)
    return descriptor, before


def write_all(descriptor, payload):
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("short snapshot write")
        offset += written


def copy_regular(source_parent, destination_parent, name, label):
    source_fd = None
    destination_fd = None
    try:
        source_fd, before = open_regular(source_parent, name, label)
        try:
            destination_fd = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW,
                0o600,
                dir_fd=destination_parent,
            )
        except FileExistsError:
            state("snapshot destination changed while copying %s" % label)
        except OSError as error:
            state("could not create snapshot content for %s: %s" % (label, error))
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            write_all(destination_fd, chunk)
        os.fsync(destination_fd)
        os.fchmod(destination_fd, 0o700 if before.st_mode & 0o111 else 0o600)
        after = lstat_at(source_parent, name, label)
        final = os.fstat(source_fd)
        if fingerprint(before) != fingerprint(after) or fingerprint(before) != fingerprint(final):
            state("%s changed while snapshotting" % label)
    finally:
        if destination_fd is not None:
            os.close(destination_fd)
        if source_fd is not None:
            os.close(source_fd)


def copy_link(source_parent, destination_parent, name, label):
    before = lstat_at(source_parent, name, label)
    if not stat.S_ISLNK(before.st_mode):
        state("%s is not a symlink" % label)
    try:
        target = os.readlink(name, dir_fd=source_parent)
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow snapshot support is unavailable")
    except OSError as error:
        state("could not read snapshot source link %s: %s" % (label, error))
    after = lstat_at(source_parent, name, label)
    if identity(before) != identity(after) or not stat.S_ISLNK(after.st_mode):
        state("%s changed while snapshotting" % label)
    try:
        os.symlink(target, name, dir_fd=destination_parent)
    except FileExistsError:
        state("snapshot destination changed while copying %s" % label)
    except OSError as error:
        state("could not create snapshot link for %s: %s" % (label, error))


def copy_tree(source_fd, destination_fd, label):
    try:
        names = sorted(os.listdir(source_fd))
    except OSError as error:
        state("could not enumerate snapshot source %s: %s" % (label, error))
    for name in names:
        if not safe_name(name):
            state("snapshot source contains an unsafe name")
        child_label = name if not label else label + "/" + name
        value = lstat_at(source_fd, name, child_label)
        if stat.S_ISDIR(value.st_mode):
            try:
                os.mkdir(name, 0o700, dir_fd=destination_fd)
            except FileExistsError:
                state("snapshot destination changed while creating %s" % child_label)
            except OSError as error:
                state("could not create snapshot directory %s: %s" % (child_label, error))
            child_source = None
            child_destination = None
            try:
                child_source = open_directory(source_fd, name, child_label)
                child_destination = open_directory(destination_fd, name, "snapshot " + child_label)
                copy_tree(child_source, child_destination, child_label)
            finally:
                if child_destination is not None:
                    os.close(child_destination)
                if child_source is not None:
                    os.close(child_source)
        elif stat.S_ISREG(value.st_mode):
            copy_regular(source_fd, destination_fd, name, child_label)
        elif stat.S_ISLNK(value.st_mode):
            copy_link(source_fd, destination_fd, name, child_label)
        else:
            state("snapshot source has unsupported content type: %s" % child_label)


def digest_regular(parent_fd, name, label):
    descriptor = None
    try:
        descriptor, before = open_regular(parent_fd, name, label)
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = lstat_at(parent_fd, name, label)
        final = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(after) or fingerprint(before) != fingerprint(final):
            state("%s changed while hashing" % label)
        return digest.hexdigest()
    finally:
        if descriptor is not None:
            os.close(descriptor)


def seal_tree(directory_fd, label):
    try:
        names = sorted(os.listdir(directory_fd))
    except OSError as error:
        state("could not enumerate snapshot output %s: %s" % (label, error))
    for name in names:
        if not safe_name(name):
            state("snapshot output contains an unsafe name")
        child_label = name if not label else label + "/" + name
        value = lstat_at(directory_fd, name, "snapshot " + child_label)
        if stat.S_ISDIR(value.st_mode):
            child_fd = None
            try:
                child_fd = open_directory(directory_fd, name, "snapshot " + child_label)
                seal_tree(child_fd, child_label)
                os.fchmod(child_fd, 0o500)
            except OSError as error:
                state("could not seal snapshot directory %s: %s" % (child_label, error))
            finally:
                if child_fd is not None:
                    os.close(child_fd)
        elif stat.S_ISREG(value.st_mode):
            file_fd = None
            try:
                file_fd, opened = open_regular(directory_fd, name, "snapshot " + child_label)
                mode = 0o500 if opened.st_mode & 0o111 else 0o400
                os.fchmod(file_fd, mode)
            except OSError as error:
                state("could not seal snapshot content %s: %s" % (child_label, error))
            finally:
                if file_fd is not None:
                    os.close(file_fd)
        elif not stat.S_ISLNK(value.st_mode):
            state("snapshot output has unsupported content type: %s" % child_label)


if not O_DIRECTORY or not O_NOFOLLOW:
    unavailable("descriptor-relative no-follow snapshot support is unavailable")

releases_fd = None
source_fd = None
snapshot_fd = None
payload_source_fd = None
payload_snapshot_fd = None
try:
    try:
        releases_fd = os.open(releases, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    except OSError as error:
        state("could not open release snapshot store without following links: %s" % error)
    if not stat.S_ISDIR(os.fstat(releases_fd).st_mode):
        state("release snapshot store is not a directory")
    source_fd = open_directory(releases_fd, version, "release snapshot source")
    snapshot_fd = open_directory(releases_fd, snapshot_name, "release snapshot destination")
    if os.listdir(snapshot_fd):
        state("release snapshot destination is not empty")

    source_names = sorted(os.listdir(source_fd))
    if source_names != ["payload", "release.json"]:
        state("release snapshot source has unexpected top-level content")
    copy_regular(source_fd, snapshot_fd, "release.json", "release.json")
    if digest_regular(snapshot_fd, "release.json", "snapshot release.json") != expected_digest:
        state("release snapshot record changed during copy")

    try:
        os.mkdir("payload", 0o700, dir_fd=snapshot_fd)
    except OSError as error:
        state("could not create snapshot payload directory: %s" % error)
    payload_source_fd = open_directory(source_fd, "payload", "release snapshot payload")
    payload_snapshot_fd = open_directory(snapshot_fd, "payload", "snapshot payload")
    copy_tree(payload_source_fd, payload_snapshot_fd, "payload")
    os.close(payload_snapshot_fd)
    payload_snapshot_fd = None
    os.close(payload_source_fd)
    payload_source_fd = None

    if sorted(os.listdir(source_fd)) != ["payload", "release.json"]:
        state("release snapshot source changed while copying")
    seal_tree(snapshot_fd, "")
    os.fchmod(snapshot_fd, 0o500)
except (AttributeError, NotImplementedError):
    unavailable("descriptor-relative no-follow snapshot support is unavailable")
except OSError as error:
    state("could not copy release snapshot without following links: %s" % error)
finally:
    if payload_snapshot_fd is not None:
        os.close(payload_snapshot_fd)
    if payload_source_fd is not None:
        os.close(payload_source_fd)
    if snapshot_fd is not None:
        os.close(snapshot_fd)
    if source_fd is not None:
        os.close(source_fd)
    if releases_fd is not None:
        os.close(releases_fd)
PY
}

# Byte-identical copy of trellis_home_snapshot_payload_matches (see
# scripts/lib/trellis-home.sh for the normative definition and the reason the
# version segment must be matched whole rather than as a prefix). This library
# deliberately depends on nothing above semver.sh — see the file header — so it
# cannot source trellis-home.sh to reach the shared function; the body is
# pinned by scripts/tests/release-snapshot-predicate.bats instead.
release_store_snapshot_payload_matches() {
  local home="$1" payload="$2" version="$3" snapshot_root snapshot_base rest suffix
  [ "$payload" = "$home/releases/$version/payload" ] && return 0
  snapshot_root="${payload%/payload}"
  [ "$snapshot_root" != "$payload" ] || return 1
  [ "${snapshot_root%/*}" = "$home/releases" ] || return 1
  snapshot_base="${snapshot_root##*/}"
  rest="${snapshot_base#.tmp.}"
  [ "$rest" != "$snapshot_base" ] || return 1
  suffix="${rest#"$version".exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

# Is $2 a safe execution-snapshot directory name inside release store $1 for
# release $3? Delegates the parse to the pinned predicate above so this library
# and trellis-home.sh answer the delimiter-exact question the same way. The
# earlier form took the name alone and stripped the LAST `.exec.` greedily,
# which accepts `.tmp.<other-version>.exec.<n>.exec.<suffix>` — a snapshot
# belonging to a different release — under any version whose name is a prefix.
release_store_snapshot_name_is_safe() {
  local releases="${1:-}" name="${2:-}" version="${3:-}"
  case "$name" in
    .tmp.*) ;;
    *) return 1 ;;
  esac
  release_store_snapshot_payload_matches \
    "${releases%/releases}" "$releases/$name/payload" "$version"
}

release_store_remove_snapshot() {
  local snapshot="${1:-}" version="${2:-}" releases parent base owner python_bin rc
  [ "$#" -eq 2 ] || {
    release_store_err "remove snapshot requires SNAPSHOT_PATH VERSION"
    return 2
  }
  release_store_absolute_path_is_clean "$snapshot" || {
    release_store_err "snapshot path is unsafe: $snapshot"
    return 2
  }
  releases="$(release_store_canonical_releases_dir)" || return $?
  parent="${snapshot%/*}"
  base="${snapshot##*/}"
  [ "$parent" = "$releases" ] &&
    release_store_snapshot_name_is_safe "$releases" "$base" "$version" || {
    release_store_err "snapshot path is not a managed execution snapshot: $snapshot"
    return 2
  }
  owner="${snapshot}.owner.json"
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    [ ! -L "$owner" ] && [ -f "$owner" ] || {
      release_store_err "snapshot owner path is not a regular file: $owner"
      return 4
    }
  fi
  if [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] &&
     [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
    return 0
  fi
  if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
    [ ! -L "$snapshot" ] && [ -d "$snapshot" ] || {
      release_store_err "snapshot path is not a real directory: $snapshot"
      return 4
    }
  fi
  command -v python3 >/dev/null 2>&1 || {
    release_store_err "python3 with descriptor-relative snapshot cleanup support is required"
    return 5
  }
  python_bin="$(command -v python3)" || return 5

  "$python_bin" - "$releases" "$base" "${base}.owner.json" <<'PY'
import errno
import os
import stat
import sys

releases, snapshot_name, owner_name = sys.argv[1:4]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def fail(code, message):
    sys.stderr.write("trellis release: %s\n" % message)
    raise SystemExit(code)


def unavailable(message):
    fail(5, message)


def state(message):
    fail(4, message)


def identity(value):
    return (value.st_dev, value.st_ino)


def lstat_at(parent_fd, name, label):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow snapshot cleanup support is unavailable")
    except OSError as error:
        state("could not inspect %s without following links: %s" % (label, error))

def optional_lstat_at(parent_fd, name, label):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow snapshot cleanup support is unavailable")
    except OSError as error:
        if error.errno == errno.ENOENT:
            return None
        state("could not inspect %s without following links: %s" % (label, error))

def open_directory(parent_fd, name, label):
    before = lstat_at(parent_fd, name, label)
    if not stat.S_ISDIR(before.st_mode):
        state("%s is not a real directory" % label)
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow snapshot cleanup support is unavailable")
    except OSError as error:
        state("could not open %s without following links: %s" % (label, error))
    opened = os.fstat(descriptor)
    after = lstat_at(parent_fd, name, label)
    if not stat.S_ISDIR(opened.st_mode) or identity(before) != identity(opened) or identity(after) != identity(opened):
        os.close(descriptor)
        state("%s changed while opening" % label)
    return descriptor, identity(opened)


def remove_contents(directory_fd, label):
    try:
        os.fchmod(directory_fd, 0o700)
        names = sorted(os.listdir(directory_fd))
    except OSError as error:
        state("could not prepare snapshot cleanup for %s: %s" % (label, error))
    for name in names:
        if name in ("", ".", "..") or "/" in name or "\x00" in name:
            state("snapshot cleanup encountered an unsafe name")
        child_label = name if not label else label + "/" + name
        value = lstat_at(directory_fd, name, child_label)
        if stat.S_ISDIR(value.st_mode):
            child_fd = None
            child_identity = None
            try:
                child_fd, child_identity = open_directory(directory_fd, name, child_label)
                remove_contents(child_fd, child_label)
            finally:
                if child_fd is not None:
                    os.close(child_fd)
            current = lstat_at(directory_fd, name, child_label)
            if not stat.S_ISDIR(current.st_mode) or identity(current) != child_identity:
                state("snapshot cleanup target changed: %s" % child_label)
            try:
                os.rmdir(name, dir_fd=directory_fd)
            except OSError as error:
                state("could not remove snapshot directory %s: %s" % (child_label, error))
        elif stat.S_ISREG(value.st_mode) or stat.S_ISLNK(value.st_mode):
            current = lstat_at(directory_fd, name, child_label)
            if identity(current) != identity(value):
                state("snapshot cleanup target changed: %s" % child_label)
            try:
                os.unlink(name, dir_fd=directory_fd)
            except OSError as error:
                state("could not remove snapshot content %s: %s" % (child_label, error))
        else:
            state("snapshot cleanup encountered unsupported content type: %s" % child_label)


if not O_DIRECTORY or not O_NOFOLLOW:
    unavailable("descriptor-relative no-follow snapshot cleanup support is unavailable")

releases_fd = None
snapshot_fd = None
snapshot_identity = None
owner_before = None
try:
    try:
        releases_fd = os.open(releases, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    except OSError as error:
        state("could not open release snapshot store without following links: %s" % error)
    if not stat.S_ISDIR(os.fstat(releases_fd).st_mode):
        state("release snapshot store is not a directory")

    owner_before = optional_lstat_at(
        releases_fd,
        owner_name,
        "release execution snapshot owner",
    )
    if owner_before is not None and not stat.S_ISREG(owner_before.st_mode):
        state("release execution snapshot owner is not a regular file")

    snapshot_before = optional_lstat_at(
        releases_fd,
        snapshot_name,
        "release execution snapshot",
    )
    if snapshot_before is not None:
        if not stat.S_ISDIR(snapshot_before.st_mode):
            state("release execution snapshot is not a real directory")
        snapshot_fd, snapshot_identity = open_directory(
            releases_fd,
            snapshot_name,
            "release execution snapshot",
        )
        remove_contents(snapshot_fd, "")
        os.close(snapshot_fd)
        snapshot_fd = None
        current = lstat_at(releases_fd, snapshot_name, "release execution snapshot")
        if not stat.S_ISDIR(current.st_mode) or identity(current) != snapshot_identity:
            state("release execution snapshot changed during cleanup")
        try:
            os.rmdir(snapshot_name, dir_fd=releases_fd)
        except OSError as error:
            state("could not remove release execution snapshot: %s" % error)

    if owner_before is not None:
        current_owner = optional_lstat_at(
            releases_fd,
            owner_name,
            "release execution snapshot owner",
        )
        if current_owner is not None:
            if not stat.S_ISREG(current_owner.st_mode) or identity(current_owner) != identity(owner_before):
                state("release execution snapshot owner changed during cleanup")
            try:
                os.unlink(owner_name, dir_fd=releases_fd)
            except OSError as error:
                if error.errno != errno.ENOENT:
                    state("could not remove release execution snapshot owner: %s" % error)
except (AttributeError, NotImplementedError):
    unavailable("descriptor-relative no-follow snapshot cleanup support is unavailable")
except OSError as error:
    state("could not remove release execution snapshot without following links: %s" % error)
finally:
    if snapshot_fd is not None:
        os.close(snapshot_fd)
    if releases_fd is not None:
        os.close(releases_fd)
PY
  rc=$?
  return "$rc"
}

# Recover snapshots created by this shell if a command substitution returned
# between creation and the caller arming its normal cleanup state.
release_store_remove_owned_snapshots() {
  local input_version="${1:-}" version releases owner owner_pid owner_birth snapshot owner_rc rc=0
  [ "$#" -eq 1 ] || {
    release_store_err "owned snapshot cleanup requires VERSION"
    return 2
  }
  version="$(release_store_normalize_version "$input_version")" || return $?
  releases="$(release_store_canonical_releases_dir)" || return $?
  owner_pid="$$"
  case "$owner_pid" in
    ''|*[!0-9]*) return 5 ;;
  esac
  [ "$owner_pid" -gt 0 ] || return 5
  owner_birth="$(release_store_process_birth "$owner_pid")" || return 5
  [ -n "$owner_birth" ] || return 5
  command -v jq >/dev/null 2>&1 || return 5
  for owner in "$releases/.tmp.$version.exec."*.owner.json; do
    [ -e "$owner" ] || [ -L "$owner" ] || continue
    if [ -L "$owner" ] || [ ! -f "$owner" ]; then
      release_store_err "snapshot owner path is not a regular file: $owner"
      rc=4
      continue
    fi
    if ! jq -e --argjson pid "$owner_pid" --arg process_birth "$owner_birth" '
      type == "object"
      and (keys | sort) == ["pid","process_birth","schema_version"]
      and .schema_version == 1
      and .pid == $pid
      and .process_birth == $process_birth
    ' "$owner" >/dev/null 2>&1; then
      continue
    fi
    snapshot="${owner%.owner.json}"
    if release_store_snapshot_name_is_safe "$releases" "${snapshot##*/}" "$version"; then
      :
    else
      continue
    fi
    if release_store_remove_snapshot "$snapshot" "$version" >/dev/null 2>&1; then
      :
    else
      owner_rc=$?
      if [ "$owner_rc" -gt "$rc" ]; then
        rc="$owner_rc"
      fi
    fi
  done
  return "$rc"
}

release_store_snapshot_verified_release() (
  set +e
  local input_version="${1:-}" version releases source pinned_digest current_digest snapshot="" snapshot_base copied_digest final_digest rc

  [ "$#" -eq 1 ] || {
    release_store_err "snapshot verified release requires VERSION"
    return 2
  }
  version="$(release_store_normalize_version "$input_version")" || return $?
  releases="$(release_store_canonical_releases_dir)" || return $?
  source="$releases/$version"
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    release_store_err "release not installed: $version"
    return 5
  fi

  cleanup_snapshot() {
    local cleanup_rc=0
    if [ -n "${snapshot:-}" ]; then
      release_store_remove_snapshot "$snapshot" "$version" >/dev/null 2>&1 || cleanup_rc=$?
      if [ "$cleanup_rc" -ne 0 ]; then
        release_store_err "could not clean failed release execution snapshot: $snapshot"
      fi
    fi
  }
  trap cleanup_snapshot EXIT
  trap 'cleanup_snapshot; exit 129' HUP
  trap 'cleanup_snapshot; exit 130' INT
  trap 'cleanup_snapshot; exit 143' TERM

  pinned_digest="$(release_store_release_json_sha256_no_follow "$releases" "$version")" || return $?
  release_store_verify_path "$source" "$version" || return $?
  current_digest="$(release_store_release_json_sha256_no_follow "$releases" "$version")" || return $?
  if [ "$current_digest" != "$pinned_digest" ]; then
    release_store_err "release changed while preparing execution snapshot: $version"
    return 4
  fi

  snapshot="$(release_store_mktemp_dir "$releases/.tmp.$version.exec.XXXXXX")" || {
    release_store_err "could not create private release execution snapshot"
    return 5
  }
  release_store_write_snapshot_owner "$snapshot" || return $?
  release_store_assert_temp_dir_contained "$snapshot" || return $?
  snapshot_base="${snapshot##*/}"
  release_store_snapshot_name_is_safe "$releases" "$snapshot_base" "$version" || {
    release_store_err "generated release execution snapshot name is unsafe: $snapshot_base"
    return 5
  }

  release_store_copy_snapshot_no_follow "$releases" "$version" "$snapshot_base" "$pinned_digest" || return $?
  copied_digest="$(release_store_release_json_sha256_no_follow "$releases" "$snapshot_base")" || return $?
  if [ "$copied_digest" != "$pinned_digest" ]; then
    release_store_err "release snapshot record changed after copy: $version"
    return 4
  fi

  release_store_verify_path "$snapshot" "$version" 0 1 || return $?
  final_digest="$(release_store_release_json_sha256_no_follow "$releases" "$snapshot_base")" || return $?
  if [ "$final_digest" != "$pinned_digest" ]; then
    release_store_err "release snapshot record changed during verification: $version"
    return 4
  fi

  trap - EXIT HUP INT TERM
  printf '%s\t%s\n' "$snapshot" "$pinned_digest"
)


# Emit the attachment program as one verified in-memory Bash bundle.  The
# caller pipes stdout directly to `bash -s`; no pathname from SNAPSHOT is ever
# executed after this function has finished verifying and reading it.
release_store_emit_verified_attachment_bundle() {
  local snapshot="${1:-}" expected_digest="${2:-}" version="${3:-}" releases parent base python_bin
  [ "$#" -eq 3 ] || {
    release_store_err "emit verified attachment bundle requires SNAPSHOT_PATH RELEASE_JSON_SHA256 VERSION"
    return 2
  }
  release_store_absolute_path_is_clean "$snapshot" || {
    release_store_err "snapshot path is unsafe: $snapshot"
    return 2
  }
  case "$expected_digest" in
    ''|*[!0-9a-f]*)
      release_store_err "snapshot release record digest is invalid"
      return 2
      ;;
  esac
  [ "${#expected_digest}" -eq 64 ] || {
    release_store_err "snapshot release record digest is invalid"
    return 2
  }
  releases="$(release_store_canonical_releases_dir)" || return $?
  parent="${snapshot%/*}"
  base="${snapshot##*/}"
  [ "$parent" = "$releases" ] &&
    release_store_snapshot_name_is_safe "$releases" "$base" "$version" || {
    release_store_err "snapshot path is not a managed execution snapshot: $snapshot"
    return 2
  }
  command -v python3 >/dev/null 2>&1 || {
    release_store_err "python3 with descriptor-relative bundle support is required"
    return 5
  }
  python_bin="$(command -v python3)" || return 5

  "$python_bin" - "$releases" "$base" "$expected_digest" <<'PY'
import hashlib
import json
import os
import stat
import sys

releases, snapshot_name, expected_digest = sys.argv[1:4]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
REQUIRED_SOURCES = (
    "scripts/lib/semver.sh",
    "scripts/lib/trellis-home.sh",
    "scripts/lib/release-store.sh",
    "scripts/lib/local-registry.sh",
    "scripts/lib/skill-roots.sh",
    "scripts/lib/surface-plan.sh",
    "scripts/lib/attachment.sh",
    "scripts/attach-project.sh",
)


def fail(code, message):
    sys.stderr.write("trellis release: %s\n" % message)
    raise SystemExit(code)


def unavailable(message):
    fail(5, message)


def state(message):
    fail(4, message)


def identity(value):
    return (value.st_dev, value.st_ino)


def fingerprint(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        getattr(value, "st_mtime_ns", int(value.st_mtime * 1000000000)),
        getattr(value, "st_ctime_ns", int(value.st_ctime * 1000000000)),
    )


def safe_relative(path):
    if not isinstance(path, str) or not path:
        return False
    if path.startswith("/") or path.endswith("/") or "//" in path:
        return False
    if "\x00" in path or "\t" in path or "\n" in path or "\r" in path:
        return False
    return all(part not in ("", ".", "..") for part in path.split("/"))


def lstat_at(parent_fd, name, label):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow bundle support is unavailable")
    except OSError as error:
        state("could not inspect %s without following links: %s" % (label, error))


def open_directory(parent_fd, name, label):
    before = lstat_at(parent_fd, name, label)
    if not stat.S_ISDIR(before.st_mode):
        state("%s is not a real directory" % label)
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    except (AttributeError, NotImplementedError):
        unavailable("descriptor-relative no-follow bundle support is unavailable")
    except OSError as error:
        state("could not open %s without following links: %s" % (label, error))
    opened = os.fstat(descriptor)
    after = lstat_at(parent_fd, name, label)
    if not stat.S_ISDIR(opened.st_mode) or identity(before) != identity(opened) or identity(after) != identity(opened):
        os.close(descriptor)
        state("%s changed while opening" % label)
    return descriptor


def read_regular(root_fd, relative):
    if not safe_relative(relative):
        state("bundle source path is unsafe")
    parts = relative.split("/")
    parent_fd = os.dup(root_fd)
    file_fd = None
    try:
        for component in parts[:-1]:
            child_fd = open_directory(parent_fd, component, "bundle source directory")
            os.close(parent_fd)
            parent_fd = child_fd
        name = parts[-1]
        before = lstat_at(parent_fd, name, "bundle source " + relative)
        if not stat.S_ISREG(before.st_mode):
            state("bundle source is not a regular file: %s" % relative)
        try:
            file_fd = os.open(name, os.O_RDONLY | O_NOFOLLOW, dir_fd=parent_fd)
        except (AttributeError, NotImplementedError):
            unavailable("descriptor-relative no-follow bundle support is unavailable")
        except OSError as error:
            state("could not open bundle source without following links: %s" % error)
        opened = os.fstat(file_fd)
        if not stat.S_ISREG(opened.st_mode) or identity(before) != identity(opened):
            state("bundle source changed while opening: %s" % relative)
        chunks = []
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        payload = b"".join(chunks)
        after = lstat_at(parent_fd, name, "bundle source " + relative)
        final = os.fstat(file_fd)
        if fingerprint(before) != fingerprint(after) or fingerprint(before) != fingerprint(final):
            state("bundle source changed while reading: %s" % relative)
        return payload, opened
    finally:
        if file_fd is not None:
            os.close(file_fd)
        os.close(parent_fd)


def git_blob_oid(payload):
    header = ("blob %d\0" % len(payload)).encode("ascii")
    return hashlib.sha1(header + payload).hexdigest()


def manifest_tree(record):
    if not isinstance(record, dict) or not isinstance(record.get("tree"), list):
        state("snapshot release record is malformed")
    result = {}
    for entry in record["tree"]:
        if not isinstance(entry, dict):
            state("snapshot release record is malformed")
        path = entry.get("path")
        mode = entry.get("mode")
        oid = entry.get("oid")
        if not safe_relative(path) or mode not in ("100644", "100755", "120000"):
            state("snapshot release record is malformed")
        if not isinstance(oid, str) or len(oid) != 40 or any(ch not in "0123456789abcdef" for ch in oid):
            state("snapshot release record is malformed")
        if path in result:
            state("snapshot release record has duplicate paths")
        result[path] = (mode, oid)
    return result


if not O_DIRECTORY or not O_NOFOLLOW:
    unavailable("descriptor-relative no-follow bundle support is unavailable")

releases_fd = None
snapshot_fd = None
try:
    try:
        releases_fd = os.open(releases, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    except OSError as error:
        state("could not open release snapshot store without following links: %s" % error)
    if not stat.S_ISDIR(os.fstat(releases_fd).st_mode):
        state("release snapshot store is not a directory")
    snapshot_fd = open_directory(releases_fd, snapshot_name, "release execution snapshot")

    record_bytes, record_stat = read_regular(snapshot_fd, "release.json")
    if hashlib.sha256(record_bytes).hexdigest() != expected_digest:
        state("snapshot release record digest does not match its pinned value")
    try:
        record = json.loads(record_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        state("snapshot release record is malformed")
    tree = manifest_tree(record)

    sources = []
    for relative in REQUIRED_SOURCES:
        expected = tree.get(relative)
        if expected is None:
            state("snapshot release record is missing required bundle source: %s" % relative)
        payload, source_stat = read_regular(snapshot_fd, "payload/" + relative)
        actual_mode = "100755" if source_stat.st_mode & 0o111 else "100644"
        actual_oid = git_blob_oid(payload)
        if (actual_mode, actual_oid) != expected:
            state("snapshot bundle source does not match release record: %s" % relative)
        sources.append(payload)

    # Do not emit any byte until every carrier source is already in memory and
    # has matched the exact release record supplied by the caller.
    output = [b"TRELLIS_LIBS_PRELOADED=1\n", b"export TRELLIS_LIBS_PRELOADED\n"]
    for payload in sources:
        output.append(b"\n")
        output.append(payload)
        if not payload.endswith(b"\n"):
            output.append(b"\n")
    output.append(b"\nmain \"$@\"\n")
    sys.stdout.buffer.write(b"".join(output))
except (AttributeError, NotImplementedError):
    unavailable("descriptor-relative no-follow bundle support is unavailable")
except OSError as error:
    state("could not read verified attachment bundle without following links: %s" % error)
finally:
    if snapshot_fd is not None:
        os.close(snapshot_fd)
    if releases_fd is not None:
        os.close(releases_fd)
PY
}
release_store_write_manifest_json() {
  local manifest_tsv="$1" output="$2" version="$3" tag="$4" commit="$5" remote="$6"
  jq -Rn \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg commit "$commit" \
    --arg remote "$remote" \
    '{
      schema_version: 1,
      version: $version,
      tag: $tag,
      commit: $commit,
      remote: $remote,
      tree: [
        inputs
        | select(length > 0)
        | split("\t")
        | {mode: .[0], oid: .[1], path: .[2]}
      ]
    }' < "$manifest_tsv" > "$output"
}

release_store_install() (
  set +e
  local input_version="${1:-}" remote="${2:-}" source_root="${3:-}"
  local version tag releases target lock="" lock_path="" stage="" payload="" work="" repo commit version_blob expected_version_blob manifest_tsv
  local mode type oid path entry rc

  cleanup_install() {
    [ -n "${stage:-}" ] && [ -d "$stage" ] && release_store_make_tree_writable "$stage" 2>/dev/null
    [ -n "${work:-}" ] && [ -d "$work" ] && rm -rf "$work"
    [ -n "${stage:-}" ] && [ -d "$stage" ] && rm -rf "$stage"
    [ -n "${lock:-}" ] && [ -d "$lock" ] && rmdir "$lock" 2>/dev/null
  }
  trap cleanup_install EXIT INT TERM

  if [ -z "$input_version" ]; then
    release_store_err "missing release version"
    return 2
  fi
  version="$(release_store_normalize_version "$input_version")" || return $?
  tag="$(release_store_tag_for_version "$version")" || return $?

  if ! command -v jq >/dev/null 2>&1; then
    release_store_err "jq is required"
    return 5
  fi
  if ! command -v git >/dev/null 2>&1; then
    release_store_err "git is required"
    return 5
  fi
  if ! command -v tar >/dev/null 2>&1; then
    release_store_err "tar is required"
    return 5
  fi

  if [ -z "$remote" ]; then
    if [ -n "$source_root" ] && git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1; then
      remote="$source_root"
    else
      remote="."
    fi
  fi

  release_store_ensure_store_dirs || return $?
  releases="$(release_store_canonical_releases_dir)" || return $?
  target="$releases/$version"
  lock_path="$releases/$version.lock"
  release_store_assert_release_dir_contained "$target" "$version" || return 4

  if ! mkdir "$lock_path" 2>/dev/null; then
    if [ -e "$lock_path" ] || [ -L "$lock_path" ]; then
      release_store_err "release install is locked or already in progress: $version"
      return 3
    fi
    release_store_err "could not create release install lock: $version"
    return 5
  fi
  lock="$lock_path"
  chmod 700 "$lock" || {
    release_store_err "could not secure release install lock: $lock"
    return 5
  }
  if [ -e "$target" ] || [ -L "$target" ]; then
    release_store_err "release already installed, refusing overwrite: $version"
    return 3
  fi

  work="$(release_store_mktemp_dir "$releases/.tmp.$version.fetch.XXXXXX")" || return 5
  stage="$(release_store_mktemp_dir "$releases/.tmp.$version.stage.XXXXXX")" || return 5
  payload="$stage/payload"
  mkdir "$payload" || return 5
  chmod 700 "$payload" || {
    release_store_err "could not secure release staging payload"
    return 5
  }
  repo="$work/repo"

  git init -q "$repo" || return 5
  git -C "$repo" fetch -q -- "$remote" "refs/tags/$tag:refs/tags/$tag"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    release_store_err "could not fetch annotated tag $tag from $remote"
    return 5
  fi
  if [ "$(git -C "$repo" cat-file -t "refs/tags/$tag" 2>/dev/null)" != "tag" ]; then
    release_store_err "release ref is not an annotated tag: $tag"
    return 4
  fi
  commit="$(git -C "$repo" rev-list -n 1 "$tag^{commit}" 2>/dev/null)"
  if [ -z "$commit" ]; then
    release_store_err "annotated tag does not resolve to a commit: $tag"
    return 4
  fi
  version_blob="$work/VERSION.actual"
  expected_version_blob="$work/VERSION.expected"
  if ! git -C "$repo" show "$commit:core-rules/VERSION" > "$version_blob" 2>/dev/null; then
    release_store_err "core-rules/VERSION is missing for $tag"
    return 4
  fi
  printf '%s\n' "$version" > "$expected_version_blob"
  if ! cmp -s "$expected_version_blob" "$version_blob"; then
    release_store_err "core-rules/VERSION mismatch for $tag: expected exact bytes for $version"
    return 4
  fi

  manifest_tsv="$work/tree.tsv"
  : > "$manifest_tsv"
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    entry="${entry#* }"
    type="${entry%% *}"
    entry="${entry#* }"
    oid="${entry%%	*}"
    path="${entry#*	}"
    if [ "$type" != "blob" ]; then
      release_store_err "unsupported Git tree entry type for $path: $type"
      return 4
    fi
    case "$mode" in
      100644|100755|120000) ;;
      *)
        release_store_err "unsupported Git tree mode for $path: $mode"
        return 4
        ;;
    esac
    if ! release_store_path_is_safe "$path"; then
      release_store_err "unsafe Git tree path: $path"
      return 4
    fi
    printf '%s\t%s\t%s\n' "$mode" "$oid" "$path" >> "$manifest_tsv"
  done < <(git -C "$repo" ls-tree -rz -r "$commit")

  if [ ! -s "$manifest_tsv" ]; then
    release_store_err "release tree is empty: $tag"
    return 4
  fi

  git -C "$repo" archive "$commit" | tar -x -f - -C "$payload"
  if [ "$?" -ne 0 ]; then
    release_store_err "could not extract release tree: $tag"
    return 4
  fi
  release_store_write_manifest_json "$manifest_tsv" "$stage/release.json" "$version" "$tag" "$commit" "$remote" || return 4

  release_store_verify_path "$stage" "$version" 1 1 || return 4
  find "$payload" -type f -exec chmod a-w {} \; || return 5
  chmod a-w "$stage/release.json" || return 5
  find "$payload" -type d -exec chmod a-w {} \; || return 5
  chmod a-w "$stage" || return 5
  release_store_verify_path "$stage" "$version" 0 1 || return 4

  if [ -e "$target" ] || [ -L "$target" ]; then
    release_store_err "release appeared during install, refusing overwrite: $version"
    return 3
  fi
  release_store_test_barrier install-before-publish || return $?
  release_store_rename_no_clobber "$stage" "$target"
  rc=$?
  case "$rc" in
    0) ;;
    3)
      release_store_err "release appeared during install, refusing overwrite: $version"
      return 3
      ;;
    *)
      release_store_err "could not publish release: $version"
      return 5
      ;;
  esac
  stage=""
  release_store_verify_path "$target" "$version" || return 4
  rm -rf "$work"
  work=""
  if ! rmdir "$lock"; then
    release_store_err "could not release install lock: $version"
    return 5
  fi
  lock=""
  trap - EXIT INT TERM
  printf '%s\n' "$target"
  return 0
)

release_store_anchor_is_safe() {
  local anchor="${1:-}"
  release_store_absolute_path_is_clean "$anchor" || return 1
  case "$anchor" in
    */.trellis/runtime) return 0 ;;
  esac
  return 1
}

release_store_runtime_anchor_state() {
  local anchor="${1:-}"
  if [ -L "$anchor" ]; then
    printf 'symlink\n'
  elif [ -e "$anchor" ]; then
    printf 'foreign\n'
  else
    printf 'absent\n'
  fi
}

# Emit the exact device:inode pair for a real directory. Callers capture these
# before planning, then release_store_adopt_runtime_anchor_pinned rechecks them
# through no-follow descriptors at the mutation sink.
# A dev:ino probe that is correct on both stat dialects.
#
# The two forms MUST be captured separately. GNU `stat -f` is --file-system, so
# `stat -f '%d:%i' DIR` treats the format as a missing operand AND still prints a
# whole filesystem block for DIR on stdout before exiting non-zero. Chaining the
# fallback inside one command substitution therefore concatenated that block with
# the GNU result, and `${identity%%:*}` then read the leading garbage instead of a
# device number — every identity check that reached this on Linux failed closed.
#
# Exit status alone is not a sufficient probe for the same reason, so the BSD
# result is also shape-checked (exactly digits:digits) before it is trusted.
release_store_stat_dev_ino() {
  local path="$1" candidate
  candidate="$(/usr/bin/stat -f '%d:%i' "$path" 2>/dev/null)" || candidate=''
  case "$candidate" in
    *[!0-9:]*|*:*:*|:*|*:|'') candidate='' ;;
    *:*) ;;
    *) candidate='' ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(/usr/bin/stat -c '%d:%i' "$path" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

release_store_directory_identity() {
  local path="${1:-}" identity dev inode
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  identity="$(release_store_stat_dev_ino "$path")" || return 1
  case "$identity" in
    *:*) ;;
    *) return 1 ;;
  esac
  dev="${identity%%:*}"
  inode="${identity#*:}"
  case "$dev:$inode" in
    :*|*:) return 1 ;;
  esac
  case "$dev" in ''|*[!0-9]*) return 1 ;; esac
  case "$inode" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s:%s\n' "$dev" "$inode"
}

# Atomically replace ROOT/.trellis/runtime only through descriptors pinned to
# ROOT and its .trellis child. The caller supplies the root/.trellis identities
# captured by its plan and the exact old runtime target (empty means absent).
# A namespace replacement, symlink, foreign runtime, or target mismatch exits
# class 3 without following the replacement.
release_store_adopt_runtime_anchor_pinned() (
  set +e
  local input_version="${1:-}" root="${2:-}" root_identity="${3:-}" trellis_identity="${4:-}"
  local expected_old="${5:-}" version release_dir payload_dir target python_bin rc
  local root_dev root_inode trellis_dev trellis_inode

  [ "$#" -eq 5 ] || {
    release_store_err "pinned runtime adoption requires VERSION ROOT ROOT_DEV_INO TRELLIS_DEV_INO EXPECTED_OLD_PAYLOAD"
    return 2
  }
  version="$(release_store_normalize_version "$input_version")" || return $?
  release_store_absolute_path_is_clean "$root" || {
    release_store_err "pinned runtime adoption root must be an absolute canonical path: $root"
    return 2
  }
  case "$root_identity" in *:*) ;; *) release_store_err "invalid pinned root identity"; return 2 ;; esac
  root_dev="${root_identity%%:*}"
  root_inode="${root_identity#*:}"
  case "$trellis_identity" in *:*) ;; *) release_store_err "invalid pinned .trellis identity"; return 2 ;; esac
  trellis_dev="${trellis_identity%%:*}"
  trellis_inode="${trellis_identity#*:}"
  case "$root_dev:$root_inode:$trellis_dev:$trellis_inode" in
    *[!0-9:]*|:*|*::*) release_store_err "invalid pinned runtime identity"; return 2 ;;
  esac
  case "$expected_old" in
    '') ;;
    *)
      release_store_absolute_path_is_clean "$expected_old" || {
        release_store_err "pinned runtime adoption expected target must be an absolute canonical path"
        return 2
      }
      ;;
  esac

  release_dir="$(release_store_locate "$version")" || return $?
  payload_dir="$release_dir/payload"
  target="$(CDPATH='' cd "$payload_dir" && pwd -P)" || {
    release_store_err "could not canonicalize verified release payload: $payload_dir"
    return 4
  }
  [ "$target" = "$payload_dir" ] && release_store_absolute_path_is_clean "$target" || {
    release_store_err "verified release payload is not a canonical path: $payload_dir"
    return 4
  }
  command -v python3 >/dev/null 2>&1 || {
    release_store_err "python3 with descriptor-relative runtime-anchor support is required"
    return 5
  }
  python_bin="$(command -v python3)"

  "$python_bin" - "$root" "$root_dev" "$root_inode" "$trellis_dev" "$trellis_inode" "$target" "$expected_old" <<'PY'
import ctypes
import errno
import os
import platform
import secrets
import stat
import sys

root, root_dev, root_inode, trellis_dev, trellis_inode, target, expected_old = sys.argv[1:8]
expected_root = (int(root_dev), int(root_inode))
expected_trellis = (int(trellis_dev), int(trellis_inode))
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def fail(code, message):
    sys.stderr.write("trellis release: %s\n" % message)
    raise SystemExit(code)


def conflict(message):
    fail(17, message)


def unavailable(message):
    fail(18, message)


def same_identity(value, expected):
    return value.st_dev == expected[0] and value.st_ino == expected[1]


def checked_open_directory(path, expected, parent_fd=None):
    flags = os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    try:
        if parent_fd is None:
            descriptor = os.open(path, flags)
        else:
            descriptor = os.open(path, flags, dir_fd=parent_fd)
    except (AttributeError, OSError) as error:
        conflict("runtime anchor directory cannot be opened without following links: %s" % error)
    value = os.fstat(descriptor)
    if not stat.S_ISDIR(value.st_mode) or not same_identity(value, expected):
        os.close(descriptor)
        conflict("runtime anchor directory identity changed")
    return descriptor


def checked_child_directory(parent_fd, name, expected):
    try:
        value = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except (AttributeError, OSError) as error:
        conflict("runtime anchor directory is unavailable: %s" % error)
    if not stat.S_ISDIR(value.st_mode) or not same_identity(value, expected):
        conflict("runtime anchor directory identity changed")
    return checked_open_directory(name, expected, parent_fd)


def revalidate_namespace():
    current_root = checked_open_directory(root, expected_root)
    try:
        current_trellis = checked_child_directory(current_root, ".trellis", expected_trellis)
        os.close(current_trellis)
    finally:
        os.close(current_root)


def lstat_at(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except (AttributeError, OSError) as error:
        conflict("runtime anchor could not be inspected: %s" % error)


def read_link_exact(parent_fd, name):
    value = lstat_at(parent_fd, name)
    if value is None or not stat.S_ISLNK(value.st_mode):
        return None
    try:
        return os.readlink(name, dir_fd=parent_fd)
    except (AttributeError, OSError) as error:
        conflict("runtime anchor symlink could not be read: %s" % error)


def atomic_rename(source_fd, source, destination_fd, destination, operation):
    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = source.encode("utf-8")
    destination_bytes = destination.encode("utf-8")

    def call(function, *args):
        ctypes.set_errno(0)
        result = function(*args)
        if result != 0:
            error_number = ctypes.get_errno() or errno.EIO
            raise OSError(error_number, os.strerror(error_number))

    system = sys.platform
    if system == "darwin":
        function = getattr(libc, "renameatx_np", None)
        if function is None:
            unavailable("renameatx_np is unavailable for pinned runtime adoption")
        function.argtypes = [
            ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
        ]
        function.restype = ctypes.c_int
        flags = 0x00000004 if operation == "no-replace" else 0x00000002
        call(function, source_fd, source_bytes, destination_fd, destination_bytes, flags)
        return

    if system.startswith("linux"):
        function = getattr(libc, "renameat2", None)
        flags = 0x00000001 if operation == "no-replace" else 0x00000002
        if function is not None:
            function.argtypes = [
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
            ]
            function.restype = ctypes.c_int
            call(function, source_fd, source_bytes, destination_fd, destination_bytes, flags)
            return
        syscall_numbers = {
            "x86_64": 316,
            "amd64": 316,
            "aarch64": 276,
            "arm64": 276,
            "i386": 353,
            "i686": 353,
        }
        syscall_number = syscall_numbers.get(platform.machine().lower())
        if syscall_number is None:
            unavailable("renameat2 is unavailable for pinned runtime adoption")
        function = libc.syscall
        function.restype = ctypes.c_long
        call(
            function,
            ctypes.c_long(syscall_number),
            ctypes.c_int(source_fd),
            ctypes.c_char_p(source_bytes),
            ctypes.c_int(destination_fd),
            ctypes.c_char_p(destination_bytes),
            ctypes.c_uint(flags),
        )
        return

    unavailable("descriptor-relative runtime adoption is unsupported on this platform")


if not O_DIRECTORY or not O_NOFOLLOW:
    unavailable("descriptor-relative no-follow support is unavailable")

root_fd = None
trellis_fd = None
stage = None
try:
    root_fd = checked_open_directory(root, expected_root)
    trellis_fd = checked_child_directory(root_fd, ".trellis", expected_trellis)
    revalidate_namespace()

    current = lstat_at(trellis_fd, "runtime")
    if expected_old:
        if current is None or not stat.S_ISLNK(current.st_mode):
            conflict("runtime anchor no longer matches the planned symlink")
        if read_link_exact(trellis_fd, "runtime") != expected_old:
            conflict("runtime anchor target changed after planning")
        has_old = True
    else:
        if current is not None:
            conflict("runtime anchor appeared after planning")
        has_old = False

    for _ in range(32):
        candidate = ".runtime.stage." + secrets.token_hex(16)
        try:
            os.symlink(target, candidate, dir_fd=trellis_fd)
        except FileExistsError:
            continue
        stage = candidate
        if read_link_exact(trellis_fd, stage) != target:
            conflict("runtime anchor staging link changed")
        break
    if stage is None:
        unavailable("could not allocate runtime anchor staging link")

    revalidate_namespace()
    try:
        atomic_rename(
            trellis_fd,
            stage,
            trellis_fd,
            "runtime",
            "swap" if has_old else "no-replace",
        )
    except OSError as error:
        if error.errno in (errno.EEXIST, errno.ENOENT, errno.ENOTEMPTY, errno.ELOOP):
            conflict("runtime anchor changed during atomic publication")
        if error.errno in (
            errno.ENOSYS,
            errno.EINVAL,
            errno.EOPNOTSUPP,
            getattr(errno, "ENOTSUP", errno.EOPNOTSUPP),
        ):
            unavailable("kernel atomic runtime publication is unavailable")
        fail(19, "kernel atomic runtime publication failed: %s" % error)

    if read_link_exact(trellis_fd, "runtime") != target:
        conflict("runtime anchor changed during atomic publication")
    if has_old and read_link_exact(trellis_fd, stage) != expected_old:
        # The swap exposed an unexpected anchor. Restore it only while the
        # destination still contains our staged target, then leave no stage.
        try:
            atomic_rename(trellis_fd, stage, trellis_fd, "runtime", "swap")
        except OSError as error:
            fail(19, "could not restore runtime anchor after a changed swap: %s" % error)
        if read_link_exact(trellis_fd, stage) == target:
            os.unlink(stage, dir_fd=trellis_fd)
            stage = None
        conflict("runtime anchor target changed during atomic publication")

    if has_old:
        os.unlink(stage, dir_fd=trellis_fd)
        stage = None
    revalidate_namespace()
except SystemExit:
    raise
except OSError as error:
    if error.errno in (errno.EEXIST, errno.ENOENT, errno.ENOTEMPTY, errno.ELOOP):
        conflict("runtime anchor changed during descriptor-relative publication")
    fail(19, "runtime anchor descriptor-relative publication failed: %s" % error)
finally:
    if stage is not None and trellis_fd is not None:
        try:
            if read_link_exact(trellis_fd, stage) == target:
                os.unlink(stage, dir_fd=trellis_fd)
        except Exception:
            pass
    if trellis_fd is not None:
        os.close(trellis_fd)
    if root_fd is not None:
        os.close(root_fd)
PY
  rc=$?
  case "$rc" in
    0)
      printf '%s -> %s\n' "$root/.trellis/runtime" "$target"
      return 0
      ;;
    17)
      release_store_err "runtime anchor changed or its pinned identity no longer matches: $root/.trellis/runtime"
      return 3
      ;;
    18)
      release_store_err "descriptor-relative runtime-anchor support is unavailable"
      return 5
      ;;
    *)
      release_store_err "could not publish pinned runtime anchor: $root/.trellis/runtime"
      return 5
      ;;
  esac
)

release_store_adopt_runtime_anchor() (
  set +e
  local input_version="${1:-}" anchor="${2:-}" version release_dir payload_dir anchor_dir anchor_lock="" anchor_lock_path=""
  local tmpdir="" tmp target symlink_component anchor_state rc
  if [ -z "$input_version" ] || [ -z "$anchor" ]; then
    release_store_err "adopt requires VERSION and runtime anchor path"
    return 2
  fi
  version="$(release_store_normalize_version "$input_version")" || return $?

  if ! release_store_anchor_is_safe "$anchor"; then
    release_store_err "runtime anchor must be an absolute path ending in /.trellis/runtime without traversal: $anchor"
    return 2
  fi
  anchor_dir="$(dirname "$anchor")"
  if symlink_component="$(release_store_first_symlink_component "$anchor_dir")"; then
    release_store_err "runtime anchor parent contains a symlink component: $symlink_component"
    return 3
  fi
  if [ ! -d "$anchor_dir" ]; then
    release_store_err "runtime anchor parent is unavailable: $anchor_dir"
    return 5
  fi

  cleanup_adopt() {
    [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ] && release_store_make_tree_writable "$tmpdir" 2>/dev/null
    [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ] && rm -rf "$tmpdir"
    [ -n "${anchor_lock:-}" ] && [ -d "$anchor_lock" ] && rmdir "$anchor_lock" 2>/dev/null
  }
  trap cleanup_adopt EXIT INT TERM
  anchor_lock_path="$anchor_dir/.runtime.lock"
  if ! mkdir "$anchor_lock_path" 2>/dev/null; then
    if [ -e "$anchor_lock_path" ] || [ -L "$anchor_lock_path" ]; then
      release_store_err "runtime anchor adoption is locked or already in progress: $anchor"
      return 3
    fi
    release_store_err "could not create runtime anchor adoption lock: $anchor"
    return 5
  fi
  anchor_lock="$anchor_lock_path"
  chmod 700 "$anchor_lock" || {
    release_store_err "could not secure runtime anchor adoption lock: $anchor"
    return 5
  }

  anchor_state="$(release_store_runtime_anchor_state "$anchor")"
  if [ "$anchor_state" = "foreign" ]; then
    release_store_err "runtime anchor exists but is not a symlink: $anchor"
    return 3
  fi
  release_dir="$(release_store_locate "$version")" || return $?
  payload_dir="$release_dir/payload"
  target="$(cd "$payload_dir" && pwd -P)" || return 4

  tmpdir="$(release_store_mktemp_dir "$anchor_dir/.runtime.tmp.XXXXXX")" || return 5
  tmp="$tmpdir/runtime"
  ln -s "$target" "$tmp" || return 5
  release_store_test_barrier adopt-before-publish || return $?

  case "$anchor_state" in
    absent)
      release_store_rename_no_clobber "$tmp" "$anchor"
      rc=$?
      if [ "$rc" -eq 3 ]; then
        release_store_err "runtime anchor appeared during adoption, refusing overwrite: $anchor"
        return 3
      elif [ "$rc" -ne 0 ]; then
        release_store_err "could not atomically publish runtime anchor: $anchor"
        return 5
      fi
      ;;
    symlink)
      release_store_rename_swap "$tmp" "$anchor"
      rc=$?
      if [ "$rc" -eq 3 ]; then
        release_store_err "runtime anchor changed during adoption: $anchor"
        return 3
      elif [ "$rc" -ne 0 ]; then
        release_store_err "could not atomically publish runtime anchor: $anchor"
        return 5
      fi
      if [ ! -L "$tmp" ]; then
        release_store_rename_swap "$tmp" "$anchor"
        rc=$?
        if [ "$rc" -ne 0 ]; then
          release_store_err "runtime anchor changed to a foreign type and could not be restored: $anchor"
          return 5
        fi
        release_store_err "runtime anchor changed to a non-symlink during adoption: $anchor"
        return 3
      fi
      rm "$tmp" || {
        release_store_err "could not retire previous runtime anchor: $anchor"
        return 5
      }
      ;;
    *)
      release_store_err "invalid runtime anchor state: $anchor_state"
      return 4
      ;;
  esac

  if ! rmdir "$tmpdir"; then
    release_store_err "could not clean runtime anchor staging directory: $anchor"
    return 5
  fi
  tmpdir=""
  if ! rmdir "$anchor_lock"; then
    release_store_err "could not release runtime anchor adoption lock: $anchor"
    return 5
  fi
  anchor_lock=""
  trap - EXIT INT TERM
  printf '%s -> %s\n' "$anchor" "$target"
)
