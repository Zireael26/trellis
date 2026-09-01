#!/bin/sh
# The direct-entry shell performs one operation only: start a known Bash through
# env -i. The clean Bash extracts and runs the launcher body, so BASH_ENV, ENV,
# exported functions, Git overrides, loader variables, and ambient PATH never
# reach an evaluated launcher command.
# shellcheck shell=bash
# The `#!/bin/sh` line above is a POSIX bootstrap: it does nothing but `exec` a
# clean `/bin/bash --noprofile --norc` through `env -i`, so every line of this
# file after the bootstrap is Bash and must be linted as Bash. Without this
# directive ShellCheck believed the shebang and buried ~30 real findings under
# ~250 SC30xx dialect complaints about a dialect that never runs.
#
# ShellCheck only honours `shell=` at the top of a file, so the directive covers
# the POSIX prologue too. `scripts/tests/posix-bootstrap-prologue.bats` re-checks
# each prologue as `sh` to keep that guarantee, since this line removes it here.
launcher_ssh_auth_sock=${SSH_AUTH_SOCK-}
launcher_attach_caller_path=
if [ "${1-}" = attach ]; then
  launcher_attach_caller_path=${PATH-}
fi
# shellcheck disable=SC2093  # nothing after this exec runs in the outer shell:
# the trusted body below the marker is read as DATA by the re-exec'd bootstrap.
exec /usr/bin/env -i \
  "HOME=${HOME-}" "TRELLIS_HOME=${TRELLIS_HOME-}" \
  "SSH_AUTH_SOCK=$launcher_ssh_auth_sock" \
  "TRELLIS_ATTACH_CALLER_PATH=$launcher_attach_caller_path" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  /bin/bash --noprofile --norc -c '
set -u
umask 077
launcher_source="$1"
shift
launcher_body="$(/usr/bin/mktemp /tmp/trellis-launcher.XXXXXX)" || {
  /usr/bin/printf "%s\n" "trellis: could not prepare trusted launcher bootstrap" >&2
  exit 5
}
if ! /usr/bin/awk "body { print } /^# -- trellis launcher body --\$/ { body = 1 }" "$launcher_source" > "$launcher_body" ||
  ! /bin/test -s "$launcher_body" ||
  ! /bin/chmod 600 "$launcher_body"; then
  /bin/rm -f "$launcher_body"
  /usr/bin/printf "%s\n" "trellis: could not prepare trusted launcher bootstrap" >&2
  exit 5
fi
exec /usr/bin/env -i \
  "HOME=${HOME-}" "TRELLIS_HOME=${TRELLIS_HOME-}" \
  "SSH_AUTH_SOCK=${SSH_AUTH_SOCK-}" \
  "TRELLIS_ATTACH_CALLER_PATH=${TRELLIS_ATTACH_CALLER_PATH-}" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  "TRELLIS_LAUNCHER_BODY=$launcher_body" \
  /bin/bash --noprofile --norc "$launcher_body" "$@"
' trellis-launcher-bootstrap "$0" "$@"

# -- trellis launcher body --
# Stable Trellis launcher.
#
# This file is copied verbatim to a user-owned executable (normally
# ~/.local/bin/trellis). It intentionally contains its release verification
# logic so installed launchers never depend on a mutable source checkout.

# Capture the caller's REAL PATH here: this line runs before the hardening
# below replaces PATH with the system set, so this is the only point at which
# the user's toolchain (homebrew, nvm, pyenv shims) is still visible. Using
# `-` rather than `:-` recorded an empty value whenever the override was unset,
# which made the attach-time toolchain capture record the system set it was
# built to replace, leaving every gate stage at exit 127.
launcher_attach_caller_path=${TRELLIS_ATTACH_CALLER_PATH:-${PATH-}}
unset BASH_ENV ENV CDPATH TRELLIS_ATTACH_CALLER_PATH
PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH
set -u

launcher_cleanup_body() {
  local body="${TRELLIS_LAUNCHER_BODY:-}"
  [ -z "$body" ] || /bin/rm -f "$body"
}
trap 'launcher_cleanup_body' EXIT

TRELLIS_EX_USAGE=2
TRELLIS_EX_CONFLICT=3
TRELLIS_EX_STATE=4
TRELLIS_EX_UNAVAILABLE=5

launcher_error() {
  printf 'trellis: %s\n' "$*" >&2
}

launcher_die() {
  local code="$1"
  shift
  launcher_error "$*"
  exit "$code"
}

launcher_absolute_path_is_clean() {
  local path="${1:-}"
  [ -n "$path" ] && [ "$path" != "/" ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\t'*|*$'\n'*|*$'\r'*|*/../*|*/..|*/./*|*/.|*'//'*) return 1 ;;
  esac
  return 0
}

# Resolve SSH_AUTH_SOCK to the physical path of the agent socket, or to the
# empty string when there is no socket we are willing to forward.
#
# Only the *spelling* of the path may differ from what the caller handed us: a
# symlinked directory anywhere above the socket is fine (stock macOS spells the
# launchd agent socket /var/run/..., and /var is a symlink to /private/var), but
# the socket itself must still be a real socket, must not be a symlink, and the
# resolved path must name the same file. What leaves here is the canonical
# spelling, so nothing downstream re-traverses a symlink that could be swapped.
launcher_verified_ssh_auth_sock() {
  local socket="${SSH_AUTH_SOCK:-}" parent base canonical_parent canonical
  [ -n "$socket" ] || {
    printf '\n'
    return 0
  }
  launcher_absolute_path_is_clean "$socket" &&
    [ -S "$socket" ] &&
    [ ! -L "$socket" ] || {
    printf '\n'
    return 0
  }
  parent="${socket%/*}"
  base="${socket##*/}"
  [ -n "$parent" ] && [ -n "$base" ] &&
    [ -d "$parent" ] || {
    printf '\n'
    return 0
  }
  canonical_parent="$(CDPATH='' cd -P -- "$parent" && pwd -P)" || {
    printf '\n'
    return 0
  }
  canonical="$canonical_parent/$base"
  launcher_absolute_path_is_clean "$canonical" &&
    [ -S "$canonical" ] &&
    [ ! -L "$canonical" ] &&
    [ "$canonical" -ef "$socket" ] || {
    printf '\n'
    return 0
  }
  printf '%s\n' "$canonical"
}

launcher_safe_relative_path() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  case "$path" in
    /*|.|..|./*|../*|*/../*|*/..|*/./*|*/.|*/|*'//'*) return 1 ;;
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

launcher_safe_symlink_target() {
  local link_path="$1" target="$2" parent="" rest component resolved=""

  launcher_safe_relative_path "$link_path" || return 1
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
      ''|.) ;;
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

launcher_real_directory() {
  local path="$1"
  [ ! -L "$path" ] && [ -d "$path" ] || return 1
  (CDPATH='' cd "$path" && pwd -P)
}

launcher_not_writable() {
  local path="$1" permissions write_bits
  permissions="$(LC_ALL=C /bin/ls -ld "$path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  case "$permissions" in *+*) return 1 ;; esac
  write_bits="$(/usr/bin/printf '%s' "$permissions" | /usr/bin/awk '{p=substr($0, 1, 10); print substr(p, 3, 1) substr(p, 6, 1) substr(p, 9, 1)}')"
  [ "$write_bits" = "---" ]
}

launcher_private_config() {
  local path="$1" permissions private_bits
  [ ! -L "$path" ] && [ -f "$path" ] || return 1
  permissions="$(LC_ALL=C /bin/ls -ld "$path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  case "$permissions" in *+*) return 1 ;; esac
  private_bits="$(/usr/bin/printf '%s' "$permissions" | /usr/bin/awk '{p=substr($0, 1, 10); print substr(p, 5, 6)}')"
  [ "$private_bits" = "------" ]
}

launcher_private_directory() {
  local path="$1" permissions private_bits
  [ ! -L "$path" ] && [ -d "$path" ] || return 1
  permissions="$(LC_ALL=C /bin/ls -ld "$path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  case "$permissions" in *+*) return 1 ;; esac
  private_bits="$(/usr/bin/printf '%s' "$permissions" | /usr/bin/awk '{p=substr($0, 1, 10); print substr(p, 5, 6)}')"
  [ "$private_bits" = "------" ]
}

launcher_permissions_not_writable() {
  local permissions="$1" write_bits
  [ "${#permissions}" -eq 10 ] || return 1
  write_bits="${permissions:2:1}${permissions:5:1}${permissions:8:1}"
  [ "$write_bits" = "---" ]
}

launcher_mode_for_permissions() {
  local permissions="$1" exec_bits
  [ "${#permissions}" -eq 10 ] || return 1
  exec_bits="${permissions:3:1}${permissions:6:1}${permissions:9:1}"
  case "$exec_bits" in
    ---) printf '100644\n' ;;
    *) printf '100755\n' ;;
  esac
}

launcher_collect_permissions() {
  local paths_nul="$1" paths="$2" rows="$3" ls_rows="$4" permissions="$5"
  local path permission extra

  : > "$rows" || return 1
  [ -s "$paths_nul" ] || return 0
  LC_ALL=C /usr/bin/xargs -0 /bin/ls -fdl < "$paths_nul" > "$ls_rows" || return 1
  /usr/bin/awk '{
    if ($1 ~ /\+/) exit 42
    print substr($1, 1, 10)
  }' "$ls_rows" > "$permissions" || return 1

  exec 3< "$permissions" || return 1
  while IFS= read -r path; do
    if ! IFS= read -r permission <&3; then
      exec 3<&-
      return 1
    fi
    case "$permission" in
      [bcdlps-]?????????) ;;
      *)
        exec 3<&-
        return 1
        ;;
    esac
    printf '%s\t%s\n' "$path" "$permission" >> "$rows" || {
      exec 3<&-
      return 1
    }
  done < "$paths"
  # shellcheck disable=SC2034  # Presence of a further line is the signal; its content is not read.
  if IFS= read -r extra <&3; then
    exec 3<&-
    return 1
  fi
  exec 3<&-
}

launcher_validate_machine_config() {
  local config="$1"
  jq -e '
    def no_controls:
      type == "string" and all(explode[]; . != 0 and . != 9 and . != 10 and . != 13);
    def absolute_safe_path:
      no_controls
      and startswith("/")
      and length >= 2
      and (startswith("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    def closed_object($required; $optional):
      type == "object"
      and ((keys_unsorted - ($required + $optional)) | length == 0)
      and (($required - keys_unsorted) | length == 0);
    def fleet_name:
      no_controls and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def version:
      no_controls and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$");
    def fleet_config:
      closed_object(["discovery_roots"]; ["shared_infra_root"])
      and (.discovery_roots | type == "array" and length >= 1)
      and ([.discovery_roots[] | absolute_safe_path] | all)
      and ((.discovery_roots | unique | length) == (.discovery_roots | length))
      and ((has("shared_infra_root") | not) or (.shared_infra_root | absolute_safe_path));

    closed_object(["schema_version", "source_root", "release_remote", "active_cli_release", "default_fleet", "fleets"]; ["$schema"])
    and ((has("$schema") | not) or (."$schema" | no_controls and length > 0))
    and .schema_version == 1
    and (.source_root | absolute_safe_path)
    and (.release_remote | no_controls and length > 0)
    and (.active_cli_release | version)
    and (.default_fleet | fleet_name)
    and (.fleets | type == "object" and length >= 1)
    and ([.fleets | keys[] | fleet_name] | all)
    and (.fleets[.default_fleet] != null)
    and ([.fleets[] | fleet_config] | all)
  ' "$config" >/dev/null 2>&1
}

launcher_validate_release_record() {
  local record="$1"
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
  ' "$record" >/dev/null 2>&1
}

launcher_validate_payload_parent() {
  local payload="$1" relative="$2" remaining component current
  case "$relative" in
    */*) remaining="${relative%/*}" ;;
    *) return 0 ;;
  esac
  current="$payload"
  while [ -n "$remaining" ]; do
    component="${remaining%%/*}"
    current="$current/$component"
    [ ! -L "$current" ] && [ -d "$current" ] || return 1
    if [ "$component" = "$remaining" ]; then
      break
    fi
    remaining="${remaining#*/}"
  done
}

launcher_verify_release() (
  local release_dir="$1" version="$2" record payload record_version record_tag cli
  local tmp manifest_paths manifest_rows manifest_dirs actual_raw actual_paths actual_dirs actual_link_paths
  local actual_link_paths_nul actual_link_targets actual_link_rows actual_link_target_dir
  local actual_metadata_paths actual_metadata_paths_nul actual_metadata_types actual_metadata_rows
  local actual_metadata_ls actual_metadata_permissions actual_metadata_typed_rows manifest_metadata_rows
  local hash_paths hash_expected hash_actual
  local mode oid path full actual_type permissions actual_mode actual_oid target entry base tab
  local target_index link_target_index link_path_count link_target_count

  [ ! -L "$release_dir" ] && [ -d "$release_dir" ] || {
    launcher_error "configured release is not a real directory: $release_dir"
    return "$TRELLIS_EX_STATE"
  }
  launcher_not_writable "$release_dir" || {
    launcher_error "configured release directory is writable: $release_dir"
    return "$TRELLIS_EX_STATE"
  }

  record="$release_dir/release.json"
  [ ! -L "$record" ] && [ -f "$record" ] && launcher_not_writable "$record" && launcher_validate_release_record "$record" || {
    launcher_error "configured release record is missing, writable, or invalid: $record"
    return "$TRELLIS_EX_STATE"
  }
  record_version="$(jq -r '.version' "$record")" || return "$TRELLIS_EX_STATE"
  record_tag="$(jq -r '.tag' "$record")" || return "$TRELLIS_EX_STATE"
  [ "$record_version" = "$version" ] && [ "$record_tag" = "v$version" ] || {
    launcher_error "configured release record does not match active_cli_release: $version"
    return "$TRELLIS_EX_STATE"
  }

  payload="$release_dir/payload"
  [ ! -L "$payload" ] && [ -d "$payload" ] || {
    launcher_error "configured release payload is missing or invalid: $payload"
    return "$TRELLIS_EX_STATE"
  }
  [ "$(launcher_real_directory "$payload")" = "$release_dir/payload" ] || {
    launcher_error "configured release payload escapes its release directory: $payload"
    return "$TRELLIS_EX_STATE"
  }
  launcher_not_writable "$payload" || {
    launcher_error "configured release payload is writable: $payload"
    return "$TRELLIS_EX_STATE"
  }

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trellis-launcher.XXXXXX")" || {
    launcher_error "could not allocate release verification state"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  trap 'rm -rf "${tmp:-}"' EXIT
  manifest_paths="$tmp/manifest.paths"
  manifest_rows="$tmp/manifest.rows"
  manifest_dirs="$tmp/manifest.dirs"
  actual_raw="$tmp/actual.raw"
  actual_paths="$tmp/actual.paths"
  actual_dirs="$tmp/actual.dirs"
  actual_link_paths="$tmp/actual.links"
  actual_link_paths_nul="$tmp/actual.links.nul"
  actual_link_targets="$tmp/actual.link.targets"
  actual_link_rows="$tmp/actual.link.rows"
  actual_link_target_dir="$tmp/actual.link-targets"
  actual_metadata_paths="$tmp/actual.metadata.paths"
  actual_metadata_paths_nul="$tmp/actual.metadata.paths.nul"
  actual_metadata_types="$tmp/actual.metadata.types"
  actual_metadata_rows="$tmp/actual.metadata.rows"
  actual_metadata_ls="$tmp/actual.metadata.ls"
  actual_metadata_permissions="$tmp/actual.metadata.permissions"
  actual_metadata_typed_rows="$tmp/actual.metadata.typed.rows"
  manifest_metadata_rows="$tmp/manifest.metadata.rows"
  hash_paths="$tmp/hash.paths"
  hash_expected="$tmp/hash.expected"
  hash_actual="$tmp/hash.actual"

  if ! find "$release_dir" -mindepth 1 -maxdepth 1 -print0 > "$tmp/top-level.raw"; then
    launcher_error "could not enumerate configured release directory"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r -d '' entry; do
    base="${entry##*/}"
    case "$base" in
      release.json|payload) ;;
      *)
        launcher_error "configured release has unexpected top-level content: $base"
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done < "$tmp/top-level.raw"

  jq -r '.tree[].path' "$record" > "$manifest_paths" || return "$TRELLIS_EX_STATE"
  jq -r '.tree[] | [.mode, .oid, .path] | @tsv' "$record" > "$manifest_rows" || return "$TRELLIS_EX_STATE"
  : > "$manifest_dirs"
  while IFS= read -r path; do
    while [ "${path%/*}" != "$path" ]; do
      path="${path%/*}"
      printf '%s\n' "$path" >> "$manifest_dirs"
    done
  done < "$manifest_paths"
  LC_ALL=C sort "$manifest_paths" > "$tmp/manifest.paths.sorted" || return "$TRELLIS_EX_UNAVAILABLE"
  LC_ALL=C sort -u "$manifest_dirs" > "$tmp/manifest.dirs.sorted" || return "$TRELLIS_EX_UNAVAILABLE"

  if ! (
    CDPATH='' cd "$payload" || exit 1
    find . -mindepth 1 -print0 > "$actual_raw"
  ); then
    launcher_error "could not enumerate configured release payload"
    return "$TRELLIS_EX_STATE"
  fi
  : > "$actual_paths"
  : > "$actual_dirs"
  : > "$actual_link_paths"
  : > "$actual_link_paths_nul"
  : > "$actual_link_targets"
  : > "$actual_link_rows"
  : > "$actual_metadata_paths"
  : > "$actual_metadata_paths_nul"
  : > "$actual_metadata_types"
  while IFS= read -r -d '' entry; do
    path="${entry#./}"
    launcher_safe_relative_path "$path" || {
      launcher_error "configured release contains an unsafe payload path: $path"
      return "$TRELLIS_EX_STATE"
    }
    full="$payload/$path"
    if [ -L "$full" ]; then
      printf '%s\n' "$path" >> "$actual_paths"
      printf '%s\n' "$path" >> "$actual_link_paths"
      printf '%s\0' "$full" >> "$actual_link_paths_nul"
    elif [ -f "$full" ]; then
      printf '%s\n' "$path" >> "$actual_paths"
      printf '%s\n' "$path" >> "$actual_metadata_paths"
      printf '%s\0' "$full" >> "$actual_metadata_paths_nul"
      printf 'regular\t%s\n' "$path" >> "$actual_metadata_types"
    elif [ -d "$full" ]; then
      printf '%s\n' "$path" >> "$actual_dirs"
      printf '%s\n' "$path" >> "$actual_metadata_paths"
      printf '%s\0' "$full" >> "$actual_metadata_paths_nul"
      printf 'directory\t%s\n' "$path" >> "$actual_metadata_types"
    else
      launcher_error "configured release contains an unsupported payload type: $path"
      return "$TRELLIS_EX_STATE"
    fi
  done < "$actual_raw"
  LC_ALL=C sort "$actual_paths" > "$tmp/actual.paths.sorted" || return "$TRELLIS_EX_UNAVAILABLE"
  LC_ALL=C sort "$actual_dirs" > "$tmp/actual.dirs.sorted" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! diff -u "$tmp/manifest.paths.sorted" "$tmp/actual.paths.sorted" >/dev/null 2>&1; then
    launcher_error "configured release payload has missing or added paths"
    return "$TRELLIS_EX_STATE"
  fi
  if ! diff -u "$tmp/manifest.dirs.sorted" "$tmp/actual.dirs.sorted" >/dev/null 2>&1; then
    launcher_error "configured release payload has missing or added directories"
    return "$TRELLIS_EX_STATE"
  fi

  if [ -s "$actual_link_paths_nul" ]; then
    LC_ALL=C xargs -0 readlink < "$actual_link_paths_nul" > "$actual_link_targets" || {
      launcher_error "could not read configured release symlink"
      return "$TRELLIS_EX_STATE"
    }
    link_path_count=0
    while IFS= read -r path; do
      link_path_count=$((link_path_count + 1))
    done < "$actual_link_paths"
    link_target_count=0
    while IFS= read -r target; do
      link_target_count=$((link_target_count + 1))
    done < "$actual_link_targets"
    [ "$link_path_count" -eq "$link_target_count" ] || {
      launcher_error "could not read configured release symlink"
      return "$TRELLIS_EX_STATE"
    }
    mkdir "$actual_link_target_dir" || {
      launcher_error "could not allocate release verification state"
      return "$TRELLIS_EX_UNAVAILABLE"
    }
    exec 3< "$actual_link_targets" || {
      launcher_error "could not read configured release symlink"
      return "$TRELLIS_EX_STATE"
    }
    link_target_index=0
    while IFS= read -r path; do
      if ! IFS= read -r target <&3; then
        exec 3<&-
        launcher_error "could not read configured release symlink: $path"
        return "$TRELLIS_EX_STATE"
      fi
      launcher_safe_relative_path "$path" && launcher_safe_symlink_target "$path" "$target" || {
        exec 3<&-
        launcher_error "configured release contains an unsafe symlink: $path"
        return "$TRELLIS_EX_STATE"
      }
      link_target_index=$((link_target_index + 1))
      printf '%s' "$target" > "$actual_link_target_dir/$link_target_index" || {
        exec 3<&-
        launcher_error "could not allocate release verification state"
        return "$TRELLIS_EX_UNAVAILABLE"
      }
      printf '%s\t%s\n' "$path" "$link_target_index" >> "$actual_link_rows" || {
        exec 3<&-
        launcher_error "could not allocate release verification state"
        return "$TRELLIS_EX_UNAVAILABLE"
      }
    done < "$actual_link_paths"
    if IFS= read -r entry <&3; then
      exec 3<&-
      launcher_error "could not read configured release symlink"
      return "$TRELLIS_EX_STATE"
    fi
    exec 3<&-
  fi

  launcher_collect_permissions \
    "$actual_metadata_paths_nul" \
    "$actual_metadata_paths" \
    "$actual_metadata_rows" \
    "$actual_metadata_ls" \
    "$actual_metadata_permissions" || {
      launcher_error "could not collect configured release metadata"
      return "$TRELLIS_EX_STATE"
    }
  tab="$(printf '\t')"
  if ! awk -F "$tab" -v type_rows="$actual_metadata_types" '
    FILENAME == type_rows {
      type[$2] = $1
      count++
      next
    }
    {
      if (!($1 in type) || seen[$1]++) exit 42
      seen_count++
      print type[$1] "\t" $1 "\t" $2
    }
    END {
      if (seen_count != count) exit 42
    }
  ' "$actual_metadata_types" "$actual_metadata_rows" > "$actual_metadata_typed_rows"; then
    launcher_error "could not collect configured release metadata"
    return "$TRELLIS_EX_STATE"
  fi
  if ! awk -F "$tab" -v link_rows="$actual_link_rows" -v metadata_rows="$actual_metadata_typed_rows" '
    FILENAME == link_rows {
      type[$1] = "symlink"
      target_index[$1] = $2
      next
    }
    FILENAME == metadata_rows {
      type[$2] = $1
      permissions[$2] = $3
      next
    }
    {
      path = $3
      actual_type = (path in type) ? type[path] : "missing"
      actual_permissions = (path in permissions) ? permissions[path] : "-"
      target = (path in target_index) ? target_index[path] : "-"
      print $1 "\t" $2 "\t" path "\t" actual_type "\t" actual_permissions "\t" target
    }
  ' "$actual_link_rows" "$actual_metadata_typed_rows" "$manifest_rows" > "$manifest_metadata_rows"; then
    launcher_error "could not map configured release metadata"
    return "$TRELLIS_EX_STATE"
  fi

  : > "$hash_paths"
  : > "$hash_expected"
  while IFS="$tab" read -r mode oid path actual_type permissions target_index; do
    launcher_safe_relative_path "$path" && launcher_validate_payload_parent "$payload" "$path" || {
      launcher_error "configured release contains an unsafe payload path: $path"
      return "$TRELLIS_EX_STATE"
    }
    full="$payload/$path"
    [ -e "$full" ] || [ -L "$full" ] || {
      launcher_error "configured release content is missing: $path"
      return "$TRELLIS_EX_STATE"
    }
    case "$mode" in
      120000)
        [ "$actual_type" = "symlink" ] || {
          launcher_error "configured release content has the wrong mode: $path"
          return "$TRELLIS_EX_STATE"
        }
        case "$target_index" in
          ''|*[!0-9]*)
            launcher_error "could not read configured release symlink: $path"
            return "$TRELLIS_EX_STATE"
            ;;
        esac
        [ -f "$actual_link_target_dir/$target_index" ] || {
          launcher_error "could not read configured release symlink: $path"
          return "$TRELLIS_EX_STATE"
        }
        printf '%s\n' "$actual_link_target_dir/$target_index" >> "$hash_paths"
        printf '%s\t%s\n' "$path" "$oid" >> "$hash_expected"
        ;;
      100644|100755)
        [ "$actual_type" = "regular" ] || {
          launcher_error "configured release content has the wrong mode: $path"
          return "$TRELLIS_EX_STATE"
        }
        actual_mode="$(launcher_mode_for_permissions "$permissions")" || {
          launcher_error "configured release content has an invalid type: $path"
          return "$TRELLIS_EX_STATE"
        }
        [ "$actual_mode" = "$mode" ] || {
          launcher_error "configured release content has the wrong mode: $path"
          return "$TRELLIS_EX_STATE"
        }
        launcher_permissions_not_writable "$permissions" || {
          launcher_error "configured release content is writable: $path"
          return "$TRELLIS_EX_STATE"
        }
        printf '%s\n' "$full" >> "$hash_paths"
        printf '%s\t%s\n' "$path" "$oid" >> "$hash_expected"
        ;;
      *)
        launcher_error "configured release record has an unsupported mode: $mode"
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done < "$manifest_metadata_rows"

  if [ -s "$hash_paths" ]; then
    git hash-object --no-filters --stdin-paths < "$hash_paths" > "$hash_actual" || {
      launcher_error "could not hash configured release content"
      return "$TRELLIS_EX_STATE"
    }
    exec 3< "$hash_actual" || {
      launcher_error "could not read configured release hashes"
      return "$TRELLIS_EX_STATE"
    }
    while IFS="$tab" read -r path oid; do
      if ! IFS= read -r actual_oid <&3; then
        exec 3<&-
        launcher_error "could not hash configured release content: $path"
        return "$TRELLIS_EX_STATE"
      fi
      [ "$actual_oid" = "$oid" ] || {
        exec 3<&-
        launcher_error "configured release content has changed: $path"
        return "$TRELLIS_EX_STATE"
      }
    done < "$hash_expected"
    if IFS= read -r entry <&3; then
      exec 3<&-
      launcher_error "could not hash configured release content"
      return "$TRELLIS_EX_STATE"
    fi
    exec 3<&-
  fi

  while IFS="$tab" read -r actual_type path permissions; do
    [ "$actual_type" = "directory" ] || continue
    launcher_permissions_not_writable "$permissions" || {
      launcher_error "configured release directory is writable: $path"
      return "$TRELLIS_EX_STATE"
    }
  done < "$actual_metadata_typed_rows"

  cli="$payload/scripts/trellis"
  [ ! -L "$cli" ] && [ -f "$cli" ] && [ -x "$cli" ] || {
    launcher_error "configured release CLI is missing or not executable: $cli"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$cli"
)

# The one pre-active command is intentionally implemented here rather than in
# a mutable checkout.  It creates the first immutable payload that the normal
# launcher path will subsequently snapshot and execute.
launcher_bootstrap_remote_is_safe() {
  local remote="${1:-}"
  [ -n "$remote" ] || return 1
  case "$remote" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

# Transport allowlist for the one place a release remote is actually dialled.
# Control-character screening says nothing about authenticity: `http://` and
# `git://` are unauthenticated and on git's default protocol.allow list, so an
# on-path attacker could serve an annotated tag whose payload this installer
# would then seal read-only and execute. Refuse them by construction.
#
# Deliberately NOT paired with GIT_PROTOCOL_FROM_USER=0: git classifies a plain
# local path as the `file` transport, whose default protocol.file.allow is
# `user`, so setting it would break local-path release remotes — the form the
# install flow and every release fixture use.
launcher_bootstrap_remote_transport_is_allowed() {
  local remote="${1:-}"
  case "$remote" in
    https://*|ssh://*|git+ssh://*|file://*) return 0 ;;
    # Any other scheme, including http://, git://, ftp:// and rsync://.
    *://*) return 1 ;;
    # `ext::` and friends hand git an arbitrary command as a transport.
    *::*) return 1 ;;
    /*) return 0 ;;
    # scp-like `user@host:path`, which git resolves over ssh.
    *@*:*) return 0 ;;
    *) return 1 ;;
  esac
}

launcher_atomic_publish_no_replace() {
  local source="${1:-}" destination="${2:-}" python_bin rc
  launcher_absolute_path_is_clean "$source" &&
    launcher_absolute_path_is_clean "$destination" || return "$TRELLIS_EX_USAGE"
  command -v python3 >/dev/null 2>&1 || {
    launcher_error "python3 is required for kernel-enforced immutable release publication"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  python_bin="$(command -v python3)" || return "$TRELLIS_EX_UNAVAILABLE"

  "$python_bin" - "$source" "$destination" <<'PY'
import ctypes
import errno
import os
import platform
import sys

source, destination = sys.argv[1:3]
libc = ctypes.CDLL(None, use_errno=True)
source = source.encode("utf-8")
destination = destination.encode("utf-8")

def call(function, *args):
    ctypes.set_errno(0)
    result = function(*args)
    if result != 0:
        error_number = ctypes.get_errno() or errno.EIO
        raise OSError(error_number, os.strerror(error_number))

def rename_no_replace():
    if sys.platform == "darwin":
        function = getattr(libc, "renameatx_np", None)
        if function is None:
            raise OSError(errno.ENOSYS, "renameatx_np is unavailable")
        function.argtypes = [
            ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
        ]
        function.restype = ctypes.c_int
        call(function, -2, source, -2, destination, 0x00000004)
        return

    if sys.platform.startswith("linux"):
        function = getattr(libc, "renameat2", None)
        if function is not None:
            function.argtypes = [
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
            ]
            function.restype = ctypes.c_int
            call(function, -100, source, -100, destination, 0x00000001)
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
            ctypes.c_int(-100),
            ctypes.c_char_p(source),
            ctypes.c_int(-100),
            ctypes.c_char_p(destination),
            ctypes.c_uint(0x00000001),
        )
        return

    raise OSError(errno.ENOSYS, "kernel atomic rename is unavailable")

try:
    rename_no_replace()
except OSError as error:
    if error.errno in (errno.EEXIST, errno.ENOTEMPTY, errno.ENOENT):
        sys.exit(17)
    if error.errno in (
        errno.ENOSYS,
        errno.EINVAL,
        errno.EOPNOTSUPP,
        getattr(errno, "ENOTSUP", errno.EOPNOTSUPP),
    ):
        sys.exit(18)
    sys.exit(19)
PY
  rc=$?
  case "$rc" in
    0) return 0 ;;
    17) return "$TRELLIS_EX_CONFLICT" ;;
    18)
      launcher_error "kernel does not support atomic no-replace release publication"
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
    *)
      launcher_error "kernel atomic release publication failed"
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
  esac
}

launcher_bootstrap_release_install() (
  set +e
  local home="${1:-}" config="${2:-}" releases="${3:-}" configured_version="${4:-}"
  local command subcommand version remote="" configured_remote=""
  local target lock="" stage="" payload="" work="" repo="" tree_raw="" manifest_tsv=""
  local tag commit version_blob expected_version_blob entry mode type oid path ssh_auth_sock rc

  shift 4
  command="${1:-}"
  subcommand="${2:-}"
  version="${3:-}"
  if [ "$command" != release ] || [ "$subcommand" != install ] || [ -z "$version" ]; then
    launcher_error "configured active CLI release is not installed; only 'trellis release install $configured_version [--remote URL]' is available"
    return "$TRELLIS_EX_USAGE"
  fi
  shift 3
  case "$#" in
    0) ;;
    2)
      [ "$1" = --remote ] || {
        launcher_error "pre-active release install accepts only --remote URL"
        return "$TRELLIS_EX_USAGE"
      }
      remote="$2"
      ;;
    *)
      launcher_error "pre-active release install accepts only --remote URL"
      return "$TRELLIS_EX_USAGE"
      ;;
  esac

  [ "$version" = "$configured_version" ] || {
    launcher_error "pre-active release install must name configured active_cli_release: $configured_version"
    return "$TRELLIS_EX_USAGE"
  }
  launcher_bootstrap_remote_is_safe "$remote" || [ -z "$remote" ] || {
    launcher_error "pre-active release remote is invalid"
    return "$TRELLIS_EX_USAGE"
  }
  configured_remote="$(jq -r '.release_remote' "$config" 2>/dev/null)" ||
    return "$TRELLIS_EX_STATE"
  if [ -z "$remote" ]; then
    remote="$configured_remote"
  fi
  launcher_bootstrap_remote_is_safe "$remote" || {
    launcher_error "configured release remote is invalid"
    return "$TRELLIS_EX_STATE"
  }
  command -v tar >/dev/null 2>&1 || {
    launcher_error "tar is required to install immutable releases"
    return "$TRELLIS_EX_UNAVAILABLE"
  }

  target="$releases/$version"
  lock="$releases/$version.lock"
  cleanup_bootstrap_install() {
    if [ -n "${stage:-}" ] && [ -d "$stage" ] && [ ! -L "$stage" ]; then
      find "$stage" -depth -type d -exec chmod u+w {} \; >/dev/null 2>&1
      rm -rf "$stage"
    fi
    [ -n "${work:-}" ] && [ -d "$work" ] && [ ! -L "$work" ] && rm -rf "$work"
    [ -n "${lock:-}" ] && [ -d "$lock" ] && [ ! -L "$lock" ] && rmdir "$lock" >/dev/null 2>&1
  }
  trap cleanup_bootstrap_install EXIT HUP INT TERM

  [ ! -e "$target" ] && [ ! -L "$target" ] || {
    launcher_error "configured active CLI release is already installed: $version"
    return "$TRELLIS_EX_CONFLICT"
  }
  if ! mkdir "$lock" 2>/dev/null; then
    if [ -e "$lock" ] || [ -L "$lock" ]; then
      launcher_error "release install is locked or already in progress: $version"
      return "$TRELLIS_EX_CONFLICT"
    fi
    launcher_error "could not create release install lock: $version"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  chmod 700 "$lock" || {
    launcher_error "could not secure release install lock"
    return "$TRELLIS_EX_UNAVAILABLE"
  }

  stage="$(mktemp -d "$releases/.tmp.$version.stage.XXXXXX")" || {
    launcher_error "could not create immutable release staging directory"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ "${stage%/*}" = "$releases" ] &&
    [ ! -L "$stage" ] &&
    [ "$(launcher_real_directory "$stage")" = "$stage" ] || {
    launcher_error "immutable release staging directory is unsafe"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  chmod 700 "$stage" || {
    launcher_error "could not secure immutable release staging directory"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  payload="$stage/payload"
  mkdir "$payload" && chmod 700 "$payload" || {
    launcher_error "could not secure immutable release staging payload"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  work="$(mktemp -d "$releases/.tmp.$version.fetch.XXXXXX")" || {
    launcher_error "could not create immutable release fetch directory"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ "${work%/*}" = "$releases" ] &&
    [ ! -L "$work" ] &&
    [ "$(launcher_real_directory "$work")" = "$work" ] || {
    launcher_error "immutable release fetch directory is unsafe"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  chmod 700 "$work" || {
    launcher_error "could not secure immutable release fetch directory"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  repo="$work/repo"
  ssh_auth_sock="$(launcher_verified_ssh_auth_sock)"
  launcher_bootstrap_git() {
    if [ -n "$ssh_auth_sock" ]; then
      SSH_AUTH_SOCK="$ssh_auth_sock" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
        git "$@"
    else
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
        git "$@"
    fi
  }

  launcher_bootstrap_git init -q "$repo" || {
    launcher_error "could not initialize immutable release fetch repository"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  tag="v$version"
  launcher_bootstrap_remote_transport_is_allowed "$remote" || {
    launcher_error "release remote uses a transport that cannot authenticate its origin: $remote"
    return "$TRELLIS_EX_USAGE"
  }
  launcher_bootstrap_git -C "$repo" fetch -q -- "$remote" "refs/tags/$tag:refs/tags/$tag"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    launcher_error "could not fetch annotated tag $tag from configured release remote"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  [ "$(launcher_bootstrap_git -C "$repo" cat-file -t "refs/tags/$tag" 2>/dev/null)" = tag ] || {
    launcher_error "release ref is not an annotated tag: $tag"
    return "$TRELLIS_EX_STATE"
  }
  commit="$(launcher_bootstrap_git -C "$repo" rev-list -n 1 "$tag^{commit}" 2>/dev/null)"
  case "$commit" in
    ''|*[!0-9a-f]*)
      launcher_error "annotated tag does not resolve to a commit: $tag"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  [ "${#commit}" -eq 40 ] || {
    launcher_error "annotated tag does not resolve to a commit: $tag"
    return "$TRELLIS_EX_STATE"
  }
  version_blob="$work/VERSION.actual"
  expected_version_blob="$work/VERSION.expected"
  launcher_bootstrap_git -C "$repo" show "$commit:core-rules/VERSION" > "$version_blob" 2>/dev/null || {
    launcher_error "core-rules/VERSION is missing for $tag"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$version" > "$expected_version_blob"
  cmp -s "$expected_version_blob" "$version_blob" || {
    launcher_error "core-rules/VERSION mismatch for $tag: expected exact bytes for $version"
    return "$TRELLIS_EX_STATE"
  }

  tree_raw="$work/tree.raw"
  manifest_tsv="$work/tree.tsv"
  launcher_bootstrap_git -C "$repo" ls-tree -rz -r "$commit" > "$tree_raw" || {
    launcher_error "could not enumerate immutable release tree"
    return "$TRELLIS_EX_STATE"
  }
  : > "$manifest_tsv"
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    entry="${entry#* }"
    type="${entry%% *}"
    entry="${entry#* }"
    oid="${entry%%	*}"
    path="${entry#*	}"
    case "$mode" in 100644|100755|120000) ;; *)
      launcher_error "immutable release tree has an unsupported mode: $mode"
      return "$TRELLIS_EX_STATE"
      ;;
    esac
    [ "$type" = blob ] || {
      launcher_error "immutable release tree has an unsupported entry type: $path"
      return "$TRELLIS_EX_STATE"
    }
    launcher_safe_relative_path "$path" && case "$path" in
      *$'\t'*|*$'\n'*|*$'\r'*) false ;;
      *) true ;;
    esac || {
      launcher_error "immutable release tree has an unsafe path"
      return "$TRELLIS_EX_STATE"
    }
    case "$oid" in
      ''|*[!0-9a-f]*)
        launcher_error "immutable release tree has an invalid object ID"
        return "$TRELLIS_EX_STATE"
        ;;
    esac
    [ "${#oid}" -eq 40 ] || {
      launcher_error "immutable release tree has an invalid object ID"
      return "$TRELLIS_EX_STATE"
    }
    printf '%s\t%s\t%s\n' "$mode" "$oid" "$path" >> "$manifest_tsv" || {
      launcher_error "could not record immutable release tree"
      return "$TRELLIS_EX_UNAVAILABLE"
    }
  done < "$tree_raw"
  [ -s "$manifest_tsv" ] || {
    launcher_error "immutable release tree is empty: $tag"
    return "$TRELLIS_EX_STATE"
  }

  set -o pipefail
  launcher_bootstrap_git -C "$repo" archive "$commit" | tar -x -f - -C "$payload"
  rc=$?
  set +o pipefail
  [ "$rc" -eq 0 ] || {
    launcher_error "could not extract immutable release tree: $tag"
    return "$TRELLIS_EX_STATE"
  }
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
    }' < "$manifest_tsv" > "$stage/release.json" || {
      launcher_error "could not write immutable release record"
      return "$TRELLIS_EX_UNAVAILABLE"
    }

  find "$payload" -type f -exec chmod a-w {} \; &&
    chmod a-w "$stage/release.json" &&
    find "$payload" -type d -exec chmod a-w {} \; &&
    chmod a-w "$stage" || {
      launcher_error "could not seal immutable release staging payload"
      return "$TRELLIS_EX_UNAVAILABLE"
    }
  launcher_verify_release "$stage" "$version" >/dev/null || return "$?"

  [ ! -e "$target" ] && [ ! -L "$target" ] || {
    launcher_error "release appeared during install, refusing overwrite: $version"
    return "$TRELLIS_EX_CONFLICT"
  }
  launcher_atomic_publish_no_replace "$stage" "$target"
  rc=$?
  case "$rc" in
    0) ;;
    "$TRELLIS_EX_CONFLICT")
      launcher_error "release appeared during install, refusing overwrite: $version"
      return "$TRELLIS_EX_CONFLICT"
      ;;
    *) return "$rc" ;;
  esac
  stage=""
  launcher_verify_release "$target" "$version" >/dev/null || return "$?"
  rm -rf "$work"
  work=""
  if ! rmdir "$lock"; then
    launcher_error "could not release immutable release install lock"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  lock=""
  trap - EXIT HUP INT TERM
  printf '%s\n' "$target"
)

# The launcher cannot source release-store.sh before it has frozen an installed
# payload, so it carries the same descriptor-relative snapshot boundary here.
launcher_release_json_sha256_no_follow() {
  local releases="${1:-}" entry="${2:-}" python_bin
  launcher_absolute_path_is_clean "$releases" || return "$TRELLIS_EX_USAGE"
  case "$entry" in
    ''|.|..|*/*|*$'\t'*|*$'\n'*|*$'\r'*) return "$TRELLIS_EX_USAGE" ;;
  esac
  command -v python3 >/dev/null 2>&1 || {
    launcher_error "python3 with descriptor-relative snapshot support is required"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  python_bin="$(command -v python3)" || return "$TRELLIS_EX_UNAVAILABLE"

  "$python_bin" - "$releases" "$entry" <<'PY'
import hashlib
import os
import stat
import sys

releases, entry = sys.argv[1:3]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def fail(code, message):
    sys.stderr.write("trellis: %s\n" % message)
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

# Pinned copy of `trellis_home_snapshot_payload_matches` (scripts/lib/
# trellis-home.sh). Byte-identical by contract — scripts/tests/
# release-snapshot-predicate.bats compares the extracted bodies. The launcher
# cannot source the library here for the same reason it carries its own
# verification logic: this runs while it is still deciding which payload may
# execute at all.
launcher_snapshot_payload_matches() {
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
# release $3? Delegates the parse to the pinned predicate above so the launcher
# and the library answer the delimiter-exact question the same way. The earlier
# form took the name alone and stripped the LAST `.exec.` greedily, which
# accepts `.tmp.<other-version>.exec.<n>.exec.<suffix>` — a snapshot belonging
# to a different release — under any version whose name is a prefix.
launcher_snapshot_name_is_safe() {
  local releases="${1:-}" name="${2:-}" version="${3:-}"
  case "$name" in
    .tmp.*) ;;
    *) return 1 ;;
  esac
  launcher_snapshot_payload_matches \
    "${releases%/releases}" "$releases/$name/payload" "$version"
}

# An execution snapshot is owned by the long-lived launcher shell, rather than
# by the short-lived command-substitution process that creates it. Bash 3.2
# keeps $$ bound to that long-lived shell across both subshell forms.
launcher_write_snapshot_owner() {
  local snapshot="${1:-}" owner owner_pid owner_birth owner_json python_bin
  [ "$#" -eq 1 ] || {
    launcher_error "snapshot owner requires SNAPSHOT_PATH"
    return "$TRELLIS_EX_USAGE"
  }
  launcher_absolute_path_is_clean "$snapshot" || {
    launcher_error "snapshot owner path is unsafe: $snapshot"
    return "$TRELLIS_EX_USAGE"
  }
  owner="${snapshot}.owner.json"
  owner_pid="$$"
  case "$owner_pid" in
    ''|*[!0-9]*)
      launcher_error "snapshot owner process id is invalid"
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
  esac
  [ "$owner_pid" -gt 0 ] || {
    launcher_error "snapshot owner process id is invalid"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  owner_birth="$(LC_ALL=C ps -p "$owner_pid" -o lstart= 2>/dev/null)" || {
    launcher_error "could not determine snapshot owner process birth"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ -n "$owner_birth" ] || {
    launcher_error "could not determine snapshot owner process birth"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  command -v jq >/dev/null 2>&1 || {
    launcher_error "jq is required to write snapshot owner metadata"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  owner_json="$(jq -cn --argjson pid "$owner_pid" --arg process_birth "$owner_birth" \
    '{schema_version:1,pid:$pid,process_birth:$process_birth}')" || {
    launcher_error "could not encode snapshot owner metadata"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ -n "$owner_json" ] || {
    launcher_error "could not encode snapshot owner metadata"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  command -v python3 >/dev/null 2>&1 || {
    launcher_error "python3 with no-follow create support is required for snapshot owner metadata"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  python_bin="$(command -v python3)" || return "$TRELLIS_EX_UNAVAILABLE"
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
    launcher_error "could not create snapshot owner metadata: $owner"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
}

# Recover snapshots created by this shell if a command substitution returned
# between creation and the caller arming its normal cleanup state.
launcher_remove_owned_snapshots() {
  local releases="${1:-}" version="${2:-}" owner owner_pid owner_birth snapshot owner_rc rc=0
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  launcher_absolute_path_is_clean "$releases" || return "$TRELLIS_EX_USAGE"
  case "$version" in
    ''|*/*|*$'\t'*|*$'\n'*|*$'\r'*) return "$TRELLIS_EX_USAGE" ;;
  esac
  owner_pid="$$"
  case "$owner_pid" in
    ''|*[!0-9]*) return "$TRELLIS_EX_UNAVAILABLE" ;;
  esac
  [ "$owner_pid" -gt 0 ] || return "$TRELLIS_EX_UNAVAILABLE"
  owner_birth="$(LC_ALL=C ps -p "$owner_pid" -o lstart= 2>/dev/null)" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -n "$owner_birth" ] || return "$TRELLIS_EX_UNAVAILABLE"
  command -v jq >/dev/null 2>&1 || return "$TRELLIS_EX_UNAVAILABLE"
  for owner in "$releases/.tmp.$version.exec."*.owner.json; do
    [ -e "$owner" ] || [ -L "$owner" ] || continue
    if [ -L "$owner" ] || [ ! -f "$owner" ]; then
      launcher_error "snapshot owner path is not a regular file: $owner"
      rc="$TRELLIS_EX_STATE"
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
    launcher_snapshot_name_is_safe "$releases" "${snapshot##*/}" "$version" || continue
    if launcher_remove_snapshot "$releases" "$snapshot" "$version" >/dev/null 2>&1; then
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

launcher_copy_snapshot_no_follow() {
  local releases="${1:-}" version="${2:-}" snapshot_base="${3:-}" digest="${4:-}" python_bin
  launcher_absolute_path_is_clean "$releases" || return "$TRELLIS_EX_USAGE"
  launcher_snapshot_name_is_safe "$releases" "$snapshot_base" "$version" ||
    return "$TRELLIS_EX_USAGE"
  case "$digest" in
    ''|*[!0-9a-f]*) return "$TRELLIS_EX_USAGE" ;;
  esac
  [ "${#digest}" -eq 64 ] || return "$TRELLIS_EX_USAGE"
  command -v python3 >/dev/null 2>&1 || {
    launcher_error "python3 with descriptor-relative snapshot support is required"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  python_bin="$(command -v python3)" || return "$TRELLIS_EX_UNAVAILABLE"

  "$python_bin" - "$releases" "$version" "$snapshot_base" "$digest" <<'PY'
import hashlib
import os
import stat
import sys

releases, version, snapshot_name, expected_digest = sys.argv[1:5]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def fail(code, message):
    sys.stderr.write("trellis: %s\n" % message)
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
    return (
        name not in ("", ".", "..")
        and "/" not in name
        and "\x00" not in name
        and "\t" not in name
        and "\n" not in name
        and "\r" not in name
    )


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
    if sorted(os.listdir(source_fd)) != ["payload", "release.json"]:
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


launcher_remove_snapshot() {
  local releases="${1:-}" snapshot="${2:-}" version="${3:-}" parent base owner python_bin rc
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  launcher_absolute_path_is_clean "$releases" &&
    launcher_absolute_path_is_clean "$snapshot" || return "$TRELLIS_EX_USAGE"
  parent="${snapshot%/*}"
  base="${snapshot##*/}"
  [ "$parent" = "$releases" ] &&
    launcher_snapshot_name_is_safe "$releases" "$base" "$version" ||
    return "$TRELLIS_EX_USAGE"
  owner="${snapshot}.owner.json"
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    [ ! -L "$owner" ] && [ -f "$owner" ] || {
      launcher_error "snapshot owner path is not a regular file: $owner"
      return "$TRELLIS_EX_STATE"
    }
  fi
  if [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] &&
     [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
    return 0
  fi
  if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
    [ ! -L "$snapshot" ] && [ -d "$snapshot" ] || {
      launcher_error "release execution snapshot is not a real directory: $snapshot"
      return "$TRELLIS_EX_STATE"
    }
  fi
  command -v python3 >/dev/null 2>&1 || {
    launcher_error "python3 with descriptor-relative snapshot cleanup support is required"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  python_bin="$(command -v python3)" || return "$TRELLIS_EX_UNAVAILABLE"

  "$python_bin" - "$releases" "$base" "${base}.owner.json" <<'PY'
import errno
import os
import stat
import sys

releases, snapshot_name, owner_name = sys.argv[1:4]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def fail(code, message):
    sys.stderr.write("trellis: %s\n" % message)
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

launcher_snapshot_verified_release() (
  set +e
  local releases="${1:-}" version="${2:-}" source pinned_digest current_digest snapshot="" snapshot_base copied_digest final_digest snapshot_cli

  launcher_absolute_path_is_clean "$releases" || return "$TRELLIS_EX_USAGE"
  case "$version" in
    ''|*/*|*$'\t'*|*$'\n'*|*$'\r'*) return "$TRELLIS_EX_USAGE" ;;
  esac
  source="$releases/$version"
  cleanup_snapshot() {
    if [ -n "${snapshot:-}" ]; then
      launcher_remove_snapshot "$releases" "$snapshot" "$version" >/dev/null 2>&1 ||
        launcher_error "could not clean failed release execution snapshot: $snapshot"
    fi
  }
  trap cleanup_snapshot EXIT
  trap 'cleanup_snapshot; exit 129' HUP
  trap 'cleanup_snapshot; exit 130' INT
  trap 'cleanup_snapshot; exit 143' TERM

  pinned_digest="$(launcher_release_json_sha256_no_follow "$releases" "$version")" || return $?
  launcher_verify_release "$source" "$version" >/dev/null || return $?
  current_digest="$(launcher_release_json_sha256_no_follow "$releases" "$version")" || return $?
  if [ "$current_digest" != "$pinned_digest" ]; then
    launcher_error "configured release changed while preparing execution snapshot: $version"
    return "$TRELLIS_EX_STATE"
  fi

  snapshot="$(mktemp -d "$releases/.tmp.$version.exec.XXXXXX")" || {
    launcher_error "could not create private release execution snapshot"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  launcher_write_snapshot_owner "$snapshot" || return $?
  chmod 700 "$snapshot" || {
    launcher_error "could not secure release execution snapshot"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  snapshot_base="${snapshot##*/}"
  [ "${snapshot%/*}" = "$releases" ] &&
    launcher_snapshot_name_is_safe "$releases" "$snapshot_base" "$version" || {
    launcher_error "generated release execution snapshot is unsafe"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ ! -L "$snapshot" ] && [ -d "$snapshot" ] &&
    [ "$(launcher_real_directory "$snapshot")" = "$snapshot" ] || {
    launcher_error "release execution snapshot is unavailable"
    return "$TRELLIS_EX_UNAVAILABLE"
  }

  launcher_copy_snapshot_no_follow "$releases" "$version" "$snapshot_base" "$pinned_digest" || return $?
  copied_digest="$(launcher_release_json_sha256_no_follow "$releases" "$snapshot_base")" || return $?
  if [ "$copied_digest" != "$pinned_digest" ]; then
    launcher_error "release snapshot record changed after copy: $version"
    return "$TRELLIS_EX_STATE"
  fi
  snapshot_cli="$(launcher_verify_release "$snapshot" "$version")" || return $?
  [ "$snapshot_cli" = "$snapshot/payload/scripts/trellis" ] || {
    launcher_error "verified release snapshot has an invalid payload path"
    return "$TRELLIS_EX_STATE"
  }
  final_digest="$(launcher_release_json_sha256_no_follow "$releases" "$snapshot_base")" || return $?
  if [ "$final_digest" != "$pinned_digest" ]; then
    launcher_error "release snapshot record changed during verification: $version"
    return "$TRELLIS_EX_STATE"
  fi

  trap - EXIT HUP INT TERM
  printf '%s\t%s\n' "$snapshot" "$pinned_digest"
)

# Buffer the command carrier, every sourced helper, and the command bodies from
# a sealed snapshot before emitting any script bytes. The resulting stdin program
# is the only thing the child Bash executes; no snapshot pathname is executed.
# The 'release' route carries the release body alone; the 'upgrade' route carries
# the same release body as a preloaded command surface plus the upgrade body, so
# upgrade never reopens a release-script pathname.
launcher_emit_verified_command_bundle() {
  local snapshot="${1:-}" expected_digest="${2:-}" command="${3:-}" version="${4:-}" releases base python_bin
  [ "$#" -eq 4 ] || {
    launcher_error "verified command bundle requires SNAPSHOT_PATH RELEASE_JSON_SHA256 COMMAND VERSION"
    return "$TRELLIS_EX_USAGE"
  }
  # DEFENSIVE, unreachable from the only caller — kept, not deleted, in the same
  # style as the record-digest re-validation in launcher_main below, which also
  # re-checks a value its producer already guaranteed. Both branches are here so
  # a future second caller cannot reintroduce the hole silently, and neither is
  # reachable from a test through the real caller:
  #
  #   version: launcher_validate_config pins .active_cli_release to strict
  #     semver before any release path is built, so by the time this runs the
  #     version cannot be empty or carry a tab, newline, or carriage return.
  #   command: launcher_main calls this only inside
  #     `if [ "${1:-}" = release ] || [ "${1:-}" = upgrade ]`, so no other route
  #     word can arrive here.
  case "$version" in
    ''|*$'\t'*|*$'\n'*|*$'\r'*)
      launcher_error "verified command bundle requires a clean release version"
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  case "$command" in
    release|upgrade) ;;
    *)
      launcher_error "verified command bundle route is unsupported"
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  launcher_absolute_path_is_clean "$snapshot" || return "$TRELLIS_EX_USAGE"
  case "$expected_digest" in ''|*[!0-9a-f]*) return "$TRELLIS_EX_USAGE" ;; esac
  [ "${#expected_digest}" -eq 64 ] || return "$TRELLIS_EX_USAGE"
  releases="${snapshot%/*}"
  base="${snapshot##*/}"
  launcher_absolute_path_is_clean "$releases" &&
    [ "$releases/$base" = "$snapshot" ] &&
    launcher_snapshot_name_is_safe "$releases" "$base" "$version" || {
      launcher_error "release command snapshot is unsafe"
      return "$TRELLIS_EX_USAGE"
    }
  command -v python3 >/dev/null 2>&1 || {
    launcher_error "python3 with descriptor-relative bundle support is required"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  python_bin="$(command -v python3)" || return "$TRELLIS_EX_UNAVAILABLE"

  "$python_bin" - "$releases" "$base" "$expected_digest" "$command" "$version" <<'PY'
import hashlib
import json
import os
import stat
import sys

releases, snapshot_name, expected_digest, command, version = sys.argv[1:6]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
CARRIER = "scripts/trellis"
LIBRARIES = (
    "scripts/lib/semver.sh",
    "scripts/lib/trellis-home.sh",
    "scripts/lib/release-store.sh",
    "scripts/lib/local-registry.sh",
    "scripts/lib/attachment.sh",
)
RELEASE_TARGET = "scripts/release.sh"
UPGRADE_TARGET = "scripts/upgrade.sh"
UPGRADE_BODY_MARKER = b"# -- trellis upgrade body --\n"
# The one token a bundle-capable upgrade body must consult before it accepts
# in-memory release execution. Its absence is the new-launcher/old-payload skew.
UPGRADE_BUNDLE_CAPABILITY = b"trellis_command_bundle_is_verified"
if command == "release":
    TARGETS = (RELEASE_TARGET,)
elif command == "upgrade":
    TARGETS = (RELEASE_TARGET, UPGRADE_TARGET)
else:
    sys.stderr.write("trellis: verified command bundle route is unsupported\n")
    raise SystemExit(2)

def fail(code, message):
    sys.stderr.write("trellis: %s\n" % message)
    raise SystemExit(code)

def state(message):
    fail(4, message)

def unavailable(message):
    fail(5, message)

def upgrade_skew(detail):
    # A new fixed launcher routes upgrade through this bundle, but the
    # installed payload can predate that route. That is installed-release
    # state — not a caller mistake and not a missing host capability — so it
    # keeps the state class every other snapshot-content refusal here uses.
    # Name the payload version and the one command that repairs it.
    state(
        "installed release %s cannot run 'trellis upgrade' as a verified "
        "in-memory bundle (%s); it predates bundle upgrade execution. Install "
        "a newer release first: trellis release install VERSION [--remote URL]"
        % (version, detail)
    )

def safe_relative(path):
    if not isinstance(path, str) or not path:
        return False
    if path.startswith("/") or path.endswith("/") or "//" in path:
        return False
    if "\x00" in path or "\t" in path or "\n" in path or "\r" in path:
        return False
    return all(part not in ("", ".", "..") for part in path.split("/"))

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
    if (
        not stat.S_ISDIR(opened.st_mode)
        or identity(before) != identity(opened)
        or identity(after) != identity(opened)
        or stat.S_IMODE(opened.st_mode) != 0o500
    ):
        os.close(descriptor)
        state("%s changed or has an invalid sealed mode" % label)
    return descriptor

def read_regular(root_fd, relative):
    if not safe_relative(relative):
        state("release bundle source path is unsafe")
    parts = relative.split("/")
    parent_fd = os.dup(root_fd)
    file_fd = None
    try:
        for component in parts[:-1]:
            child_fd = open_directory(parent_fd, component, "release bundle source directory")
            os.close(parent_fd)
            parent_fd = child_fd
        name = parts[-1]
        before = lstat_at(parent_fd, name, "release bundle source " + relative)
        if not stat.S_ISREG(before.st_mode):
            state("release bundle source is not a regular file: %s" % relative)
        try:
            file_fd = os.open(name, os.O_RDONLY | O_NOFOLLOW, dir_fd=parent_fd)
        except (AttributeError, NotImplementedError):
            unavailable("descriptor-relative no-follow bundle support is unavailable")
        except OSError as error:
            state("could not open release bundle source without following links: %s" % error)
        opened = os.fstat(file_fd)
        if not stat.S_ISREG(opened.st_mode) or identity(before) != identity(opened):
            state("release bundle source changed while opening: %s" % relative)
        chunks = []
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        payload = b"".join(chunks)
        after = lstat_at(parent_fd, name, "release bundle source " + relative)
        final = os.fstat(file_fd)
        if fingerprint(before) != fingerprint(after) or fingerprint(before) != fingerprint(final):
            state("release bundle source changed while reading: %s" % relative)
        return payload, opened
    finally:
        if file_fd is not None:
            os.close(file_fd)
        os.close(parent_fd)

def blob_oid(payload):
    return hashlib.sha1(("blob %d\0" % len(payload)).encode("ascii") + payload).hexdigest()

def upgrade_body(payload):
    # The upgrade source wrapper is a pathname bootstrap; only the body below
    # its marker is a command surface. Slice it from bytes that already matched
    # the pinned manifest, so nothing unverified can reach the child shell.
    found = payload.count(UPGRADE_BODY_MARKER)
    if found == 0:
        upgrade_skew("its scripts/upgrade.sh carries no command-body marker")
    if found != 1:
        state("snapshot upgrade source does not carry exactly one command body")
    index = payload.find(UPGRADE_BODY_MARKER)
    if index != 0 and payload[index - 1:index] != b"\n":
        state("snapshot upgrade source body marker is not a whole line")
    body = payload[index + len(UPGRADE_BODY_MARKER):]
    if not body.strip():
        state("snapshot upgrade source has an empty command body")
    if UPGRADE_BUNDLE_CAPABILITY not in body:
        # A body that never consults the bundle attestation is a pre-bundle
        # upgrade command. Executing it here dead-ends inside the child shell
        # on an unset pathname bootstrap variable, so refuse it by name.
        upgrade_skew(
            "its scripts/upgrade.sh command body predates the verified "
            "command-bundle attestation"
        )
    return body

def manifest_tree(record):
    if not isinstance(record, dict) or not isinstance(record.get("tree"), list):
        state("snapshot release record is malformed")
    tree = {}
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
        if path in tree:
            state("snapshot release record has duplicate paths")
        tree[path] = (mode, oid)
    return tree

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
    if stat.S_IMODE(record_stat.st_mode) != 0o400:
        state("snapshot release record does not have its sealed mode")
    if hashlib.sha256(record_bytes).hexdigest() != expected_digest:
        state("snapshot release record digest does not match its pinned value")
    try:
        tree = manifest_tree(json.loads(record_bytes.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError):
        state("snapshot release record is malformed")

    sources = {}
    for relative in (CARRIER,) + LIBRARIES + TARGETS:
        expected = tree.get(relative)
        if expected is None:
            if command == "upgrade" and relative == UPGRADE_TARGET:
                upgrade_skew("it ships no scripts/upgrade.sh")
            state("snapshot release record is missing required release source: %s" % relative)
        payload, source_stat = read_regular(snapshot_fd, "payload/" + relative)
        actual_mode = "100755" if source_stat.st_mode & 0o111 else "100644"
        expected_mode = 0o500 if expected[0] == "100755" else 0o400
        if stat.S_IMODE(source_stat.st_mode) != expected_mode:
            state("snapshot release source does not have its sealed mode: %s" % relative)
        if (actual_mode, blob_oid(payload)) != expected:
            state("snapshot release source does not match release record: %s" % relative)
        sources[relative] = payload

    final_record, final_record_stat = read_regular(snapshot_fd, "release.json")
    if (
        stat.S_IMODE(final_record_stat.st_mode) != 0o400
        or hashlib.sha256(final_record).hexdigest() != expected_digest
    ):
        state("snapshot release record changed while preparing command bundle")

    # Nothing reaches stdout before every input has passed its pinned manifest
    # check and is already retained in memory.
    token = os.urandom(32).hex().encode("ascii")
    route = command.encode("ascii")
    output = [
        b"TRELLIS_LIBS_PRELOADED=1\n",
        b"export TRELLIS_LIBS_PRELOADED\n",
        b"TRELLIS_VERIFIED_COMMAND_BUNDLE=" + route + b"\n",
        b"TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN=" + token + b"\n",
        b"trellis_command_bundle_is_verified() {\n",
        b"  [ \"$#\" -eq 2 ] || return 1\n",
        b"  [ \"$1\" = \"$TRELLIS_VERIFIED_COMMAND_BUNDLE\" ] && [ \"$2\" = \"$TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN\" ]\n",
        b"}\n",
        b"case \"${1:-}\" in\n",
        b"  " + route + b") shift ;;\n",
        b"  *) printf '%s\\n' 'trellis: verified release bundle route mismatch' >&2; exit 2 ;;\n",
        b"esac\n",
    ]

    def emit(payload):
        output.extend((b"\n", payload, b"" if payload.endswith(b"\n") else b"\n"))

    for relative in LIBRARIES:
        emit(sources[relative])
    if command == "upgrade":
        # The release body is a preloaded command surface here: it defines
        # release_command_main without running it, so the upgrade body invokes
        # install, verify, and adopt in-process instead of by pathname.
        output.append(b"\nTRELLIS_RELEASE_BUNDLE_PRELOAD=1\n")
        emit(sources[RELEASE_TARGET])
        output.append(b"unset TRELLIS_RELEASE_BUNDLE_PRELOAD\n")
        emit(upgrade_body(sources[UPGRADE_TARGET]))
    else:
        emit(sources[RELEASE_TARGET])
    sys.stdout.buffer.write(b"".join(output))
except (AttributeError, NotImplementedError):
    unavailable("descriptor-relative no-follow bundle support is unavailable")
except OSError as error:
    state("could not read verified release bundle without following links: %s" % error)
finally:
    if snapshot_fd is not None:
        os.close(snapshot_fd)
    if releases_fd is not None:
        os.close(releases_fd)
PY
}

LAUNCHER_EXECUTION_SNAPSHOT=""
LAUNCHER_EXECUTION_SNAPSHOT_STORE=""
LAUNCHER_EXECUTION_SNAPSHOT_VERSION=""

launcher_cleanup() {
  local snapshot="${LAUNCHER_EXECUTION_SNAPSHOT:-}" releases="${LAUNCHER_EXECUTION_SNAPSHOT_STORE:-}" version="${LAUNCHER_EXECUTION_SNAPSHOT_VERSION:-}" rc=0 body_rc=0
  LAUNCHER_EXECUTION_SNAPSHOT=""
  LAUNCHER_EXECUTION_SNAPSHOT_STORE=""
  LAUNCHER_EXECUTION_SNAPSHOT_VERSION=""
  if [ -n "$snapshot" ]; then
    if [ -z "$releases" ] || [ -z "$version" ] ||
      ! launcher_remove_snapshot "$releases" "$snapshot" "$version"; then
      launcher_error "could not clean release execution snapshot"
      rc="$TRELLIS_EX_UNAVAILABLE"
    fi
  elif [ -n "$releases" ] || [ -n "$version" ]; then
    if [ -z "$releases" ] || [ -z "$version" ] ||
      ! launcher_remove_owned_snapshots "$releases" "$version"; then
      launcher_error "could not clean release execution snapshot"
      rc="$TRELLIS_EX_UNAVAILABLE"
    fi
  fi
  launcher_cleanup_body
  body_rc=$?
  if [ "$body_rc" -gt "$rc" ]; then
    rc="$body_rc"
  fi
  return "$rc"
}

trap 'launcher_cleanup' EXIT
trap 'launcher_cleanup; exit 129' HUP
trap 'launcher_cleanup; exit 130' INT
trap 'launcher_cleanup; exit 143' TERM
launcher_main() {
  local home_candidate home user_home config releases release_dir version cli payload snapshot snapshot_info release_json_sha256 ssh_auth_sock child_status cleanup_status
  local -a attach_environment
  if [ "${1:-}" = "hook" ]; then
    [ -n "${TRELLIS_HOME:-}" ] ||
      launcher_die "$TRELLIS_EX_USAGE" "TRELLIS_HOME is required for SessionStart hook routes"
    [ -n "${HOME:-}" ] ||
      launcher_die "$TRELLIS_EX_USAGE" "HOME is required for SessionStart hook routes"
    launcher_absolute_path_is_clean "$HOME" ||
      launcher_die "$TRELLIS_EX_USAGE" "HOME must be an absolute canonical directory for SessionStart hook routes"
    user_home="$(launcher_real_directory "$HOME")" ||
      launcher_die "$TRELLIS_EX_STATE" "HOME is unavailable or not a real directory for SessionStart hook routes"
    [ "$user_home" = "$HOME" ] ||
      launcher_die "$TRELLIS_EX_USAGE" "HOME must be an absolute canonical directory for SessionStart hook routes"
    HOME="$user_home"
    export HOME
  fi


  if [ -n "${TRELLIS_HOME:-}" ]; then
    home_candidate="$TRELLIS_HOME"
  else
    [ -n "${HOME:-}" ] || launcher_die "$TRELLIS_EX_USAGE" "HOME is required when TRELLIS_HOME is unset"
    home_candidate="${HOME%/}/.trellis"
  fi
  while [ "${home_candidate%/}" != "$home_candidate" ] && [ "$home_candidate" != "/" ]; do
    home_candidate="${home_candidate%/}"
  done
  launcher_absolute_path_is_clean "$home_candidate" ||
    launcher_die "$TRELLIS_EX_USAGE" "TRELLIS_HOME must be an absolute, canonical path without traversal: $home_candidate"
  launcher_private_directory "$home_candidate" ||
    launcher_die "$TRELLIS_EX_STATE" "Trellis home is missing, not private, or not a real directory: $home_candidate"
  home="$(launcher_real_directory "$home_candidate")" ||
    launcher_die "$TRELLIS_EX_STATE" "could not canonicalize Trellis home: $home_candidate"

  config="$home/config.json"
  launcher_private_config "$config" ||
    launcher_die "$TRELLIS_EX_STATE" "machine config is missing, not private, or not a regular file: $config"
  command -v jq >/dev/null 2>&1 ||
    launcher_die "$TRELLIS_EX_UNAVAILABLE" "jq is required to read machine configuration"
  TRELLIS_HOME="$home"
  export TRELLIS_HOME
  command -v git >/dev/null 2>&1 ||
    launcher_die "$TRELLIS_EX_UNAVAILABLE" "git is required to verify immutable releases"
  launcher_validate_machine_config "$config" ||
    launcher_die "$TRELLIS_EX_STATE" "machine config failed validation: $config"
  version="$(jq -r '.active_cli_release' "$config")" ||
    launcher_die "$TRELLIS_EX_STATE" "could not read active_cli_release from $config"

  releases="$home/releases"
  if [ -L "$releases" ]; then
    launcher_die "$TRELLIS_EX_STATE" "release store must not be a symlink: $releases"
  fi
  [ -d "$releases" ] ||
    launcher_die "$TRELLIS_EX_UNAVAILABLE" "release store is unavailable: $releases"
  [ "$(launcher_real_directory "$releases")" = "$home/releases" ] ||
    launcher_die "$TRELLIS_EX_STATE" "release store escapes canonical Trellis home: $releases"

  release_dir="$releases/$version"
  if [ ! -e "$release_dir" ] && [ ! -L "$release_dir" ]; then
    # Before the active release exists, the fixed launcher owns precisely one
    # route. It installs the configured version without invoking a mutable
    # dispatcher or release-script pathname, then returns to the caller.
    launcher_bootstrap_release_install "$home" "$config" "$releases" "$version" "$@"
    child_status=$?
    launcher_cleanup
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    if [ "$cleanup_status" -gt "$child_status" ]; then
      child_status="$cleanup_status"
    fi
    return "$child_status"
  fi
  [ ! -L "$release_dir" ] && [ -d "$release_dir" ] ||
    launcher_die "$TRELLIS_EX_STATE" "configured release is not a real directory: $release_dir"
  [ "$(launcher_real_directory "$release_dir")" = "$releases/$version" ] ||
    launcher_die "$TRELLIS_EX_STATE" "configured release escapes release store: $release_dir"

  # Freeze a complete, independently verified payload before any executable
  # path is selected.  Never hand the just-verified installed release path to
  # a child: the only executable payload is the sealed private snapshot.
  # Arm the release-store cleanup context before command substitution starts.
  # The producer records the owning shell in its sidecar; cleanup can recover
  # that exact snapshot if the substitution returns during a signal handoff.
  LAUNCHER_EXECUTION_SNAPSHOT_STORE="$releases"
  LAUNCHER_EXECUTION_SNAPSHOT_VERSION="$version"
  snapshot_info="$(launcher_snapshot_verified_release "$releases" "$version")" || exit "$?"
  case "$snapshot_info" in
    *$'\t'*) ;;
    *) launcher_die "$TRELLIS_EX_STATE" "verified release snapshot did not return its pinned record digest" ;;
  esac
  snapshot="${snapshot_info%%$'\t'*}"
  release_json_sha256="${snapshot_info#*$'\t'}"
  case "$release_json_sha256" in ''|*[!0-9a-f]*)
    launcher_die "$TRELLIS_EX_STATE" "verified release snapshot returned an invalid record digest"
    ;;
  esac
  [ "${#release_json_sha256}" -eq 64 ] ||
    launcher_die "$TRELLIS_EX_STATE" "verified release snapshot returned an invalid record digest"
  LAUNCHER_EXECUTION_SNAPSHOT="$snapshot"
  LAUNCHER_EXECUTION_SNAPSHOT_STORE="$releases"
  LAUNCHER_EXECUTION_SNAPSHOT_VERSION="$version"
  cli="$snapshot/payload/scripts/trellis"
  payload="$snapshot/payload"
  [ -f "$cli" ] && [ ! -L "$cli" ] && [ -x "$cli" ] || {
    launcher_die "$TRELLIS_EX_STATE" "verified release snapshot has an invalid CLI path"
  }
  ssh_auth_sock="$(launcher_verified_ssh_auth_sock)"
  launcher_cleanup_body ||
    launcher_die "$TRELLIS_EX_UNAVAILABLE" "could not remove trusted launcher bootstrap"
  unset TRELLIS_LAUNCHER_BODY
  attach_environment=("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
  if [ "${1:-}" = attach ]; then
    attach_environment+=("TRELLIS_ATTACH_CALLER_PATH=$launcher_attach_caller_path")
  fi
  if [ "${1:-}" = release ] || [ "${1:-}" = upgrade ]; then
    set -o pipefail
    launcher_emit_verified_command_bundle "$snapshot" "$release_json_sha256" "$1" "$version" |
      /usr/bin/env -i \
        "HOME=$HOME" "TRELLIS_HOME=$home" \
        "TRELLIS_VERIFIED_PAYLOAD=$payload" "TRELLIS_VERIFIED_RELEASE_VERSION=$version" \
        "TRELLIS_VERIFIED_SSH_AUTH_SOCK=$ssh_auth_sock" \
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
        /bin/bash --noprofile --norc -s -- "$@"
    child_status=$?
    set +o pipefail
  else
    /usr/bin/env -i \
      "HOME=$HOME" "TRELLIS_HOME=$home" \
      "TRELLIS_VERIFIED_PAYLOAD=$payload" "TRELLIS_VERIFIED_RELEASE_VERSION=$version" \
      "TRELLIS_VERIFIED_SSH_AUTH_SOCK=$ssh_auth_sock" \
      "${attach_environment[@]}" \
      /bin/bash --noprofile --norc "$cli" "$@"
    child_status=$?
  fi
  launcher_cleanup
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if [ "$cleanup_status" -gt "$child_status" ]; then
    child_status="$cleanup_status"
  fi
  return "$child_status"
}

launcher_main "$@"
