#!/usr/bin/env bash
# Immutable Trellis release CLI.
#
# Normal install/adoption is rooted in TRELLIS_HOME, never a mutable policy
# checkout. A release is usable only after release-store verifies its annotated
# tag payload. Managed adoption selects explicit local-registry rows and changes
# only attachment-owned runtime anchors.

# A stable launcher may feed this file as an already verified, in-memory
# command bundle. A pathname execution never accepts that mode: the internal
# bundle attestation is available only to the clean Bash that receives the
# buffered carrier, libraries, and target bytes from the launcher.
release_bundle_mode=false
release_bundle_command="${TRELLIS_VERIFIED_COMMAND_BUNDLE:-}"
case "${BASH_SOURCE[0]:-}" in
  *release.sh) ;;
  *)
    case "$release_bundle_command" in
      release|upgrade)
        if command -v trellis_command_bundle_is_verified >/dev/null 2>&1 &&
          trellis_command_bundle_is_verified "$release_bundle_command" "${TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN:-}"; then
          release_bundle_mode=true
        fi
        ;;
    esac
    ;;
esac

# The launcher crosses the pathname command boundary with only its verified
# release identity and (optionally) a verified SSH-agent socket. Re-exec into a
# small environment before loading any release helpers so Git never receives
# ambient loader, configuration, or raw SSH-agent variables.
if [ "$release_bundle_mode" != true ] && [ "${TRELLIS_RELEASE_CLEAN_ENV:-}" != 1 ]; then
  release_bootstrap_home="${HOME-}"
  release_bootstrap_trellis_home="${TRELLIS_HOME-}"
  release_bootstrap_payload="${TRELLIS_VERIFIED_PAYLOAD-}"
  release_bootstrap_version="${TRELLIS_VERIFIED_RELEASE_VERSION-}"
  release_bootstrap_socket="${TRELLIS_VERIFIED_SSH_AUTH_SOCK-}"
  # The caller's TMPDIR crosses as an UNTRUSTED CANDIDATE under its own name,
  # never as TMPDIR. Nothing here may call release_entry_gate: that function is
  # defined further down and this bootstrap runs before it exists.
  release_bootstrap_scratch="${TMPDIR-}"
  exec /usr/bin/env -i \
    "HOME=$release_bootstrap_home" "TRELLIS_HOME=$release_bootstrap_trellis_home" \
    "TRELLIS_VERIFIED_PAYLOAD=$release_bootstrap_payload" \
    "TRELLIS_VERIFIED_RELEASE_VERSION=$release_bootstrap_version" \
    "TRELLIS_VERIFIED_SSH_AUTH_SOCK=$release_bootstrap_socket" \
    "TRELLIS_RELEASE_SCRATCH_CANDIDATE=$release_bootstrap_scratch" \
    "TRELLIS_RELEASE_CLEAN_ENV=1" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash --noprofile --norc "$0" "$@"
fi
unset TRELLIS_RELEASE_CLEAN_ENV
set -u

# Bundle mode has the launcher's in-memory attestation and receives the derived
# directory as TMPDIR directly. Pathname mode has only the carrier above. Either
# way TMPDIR stays UNSET until the existing release identity gate has passed and
# the candidate has been admitted, so an ambient value can never be the answer.
if [ "${release_bundle_mode:-false}" = true ]; then
  release_scratch_candidate="${TMPDIR-}"
else
  release_scratch_candidate="${TRELLIS_RELEASE_SCRATCH_CANDIDATE-}"
fi
unset TMPDIR TRELLIS_RELEASE_SCRATCH_CANDIDATE

RELEASE_VERIFIED_SSH_AUTH_SOCK="${TRELLIS_VERIFIED_SSH_AUTH_SOCK:-}"
unset SSH_AUTH_SOCK TRELLIS_VERIFIED_SSH_AUTH_SOCK
if [ "$release_bundle_mode" = true ]; then
  SCRIPT_DIR="${TRELLIS_VERIFIED_PAYLOAD:-}/scripts"
  RELEASE_SCRIPT_PATH="$SCRIPT_DIR/release.sh"
else
  RELEASE_SOURCE_PATH="${BASH_SOURCE[0]}"
  case "$RELEASE_SOURCE_PATH" in
    */*) RELEASE_SOURCE_DIR="${RELEASE_SOURCE_PATH%/*}" ;;
    *) RELEASE_SOURCE_DIR='.' ;;
  esac
  RELEASE_SCRIPT_NAME="${RELEASE_SOURCE_PATH##*/}"
  SCRIPT_DIR="$(CDPATH='' cd "$RELEASE_SOURCE_DIR" && pwd -P)"
  RELEASE_SCRIPT_PATH="$SCRIPT_DIR/$RELEASE_SCRIPT_NAME"
fi

release_entry_path_is_clean() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\t'*|*$'\n'*|*$'\r'*|*'//'|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
}

release_entry_version_is_safe() {
  local version="${1:-}"
  case "$version" in
    ''|*/*|*$'\t'*|*$'\n'*|*$'\r'*|*[!0-9A-Za-z.+-]*) return 1 ;;
  esac
}

release_entry_private_directory() {
  local path="${1:-}" permissions private_bits listing
  [ -n "$path" ] && [ ! -L "$path" ] && [ -d "$path" ] && [ -O "$path" ] || return 1
  case "$(/usr/bin/uname -s)" in
    Darwin)
      # Extended attributes can hide the ACL marker behind @. Read ACL rows,
      # not just the mode suffix; canonical input paths contain no newlines.
      listing="$(LC_ALL=C /bin/ls -lde "$path" 2>/dev/null)" || return 1
      case "$listing" in *"
"*) return 1 ;; esac
      ;;
    *) listing="$(LC_ALL=C /bin/ls -ld "$path" 2>/dev/null)" || return 1 ;;
  esac
  permissions="${listing%% *}"
  case "$permissions" in *+*) return 1 ;; esac
  private_bits="$(/usr/bin/printf '%s' "$permissions" | /usr/bin/awk '{p=substr($0, 1, 10); print substr(p, 5, 6)}')"
  [ "$private_bits" = "------" ]
}

# Containment and ownership admission ONLY. A candidate that passes is a real,
# private, effective-user-owned directory that is a direct `.cmd.*` child of
# this home's command scratch root. It is NOT proof that the launcher created
# it and it is NOT an authentication token.
release_entry_scratch_is_admissible() {
  local candidate="${1:-}" home="${2:-}" root parent base canonical_root canonical_candidate
  release_entry_path_is_clean "$candidate" &&
    release_entry_path_is_clean "$home" || return 1
  parent="${candidate%/*}"
  base="${candidate##*/}"
  case "$base" in .cmd.?*) ;; *) return 1 ;; esac
  case "${base#.cmd.}" in *[!0-9A-Za-z._-]*) return 1 ;; esac
  root="$home/state/scratch"
  [ "$parent" = "$root" ] || return 1
  release_entry_private_directory "$home" &&
    release_entry_private_directory "$home/state" &&
    release_entry_private_directory "$root" &&
    release_entry_private_directory "$candidate" || return 1
  canonical_root="$(CDPATH='' cd "$root" && pwd -P)" || return 1
  [ "$canonical_root" = "$root" ] || return 1
  canonical_candidate="$(CDPATH='' cd "$candidate" && pwd -P)" || return 1
  [ "$canonical_candidate" = "$candidate" ]
}

# Validated once, here, and cached in RELEASE_ADMITTED_TMPDIR: every later Git
# call reads the cached value instead of re-running these validators.
RELEASE_ADMITTED_TMPDIR=""

release_admit_command_scratch() {
  local candidate="${1:-}" home
  [ -n "$candidate" ] || return 0
  home="$(CDPATH='' cd "${TRELLIS_HOME:-/}" && pwd -P)" || return 1
  release_entry_scratch_is_admissible "$candidate" "$home" || return 1
  RELEASE_ADMITTED_TMPDIR="$candidate"
  TMPDIR="$candidate"
  export TMPDIR
}

release_entry_gate() {
  local home="${TRELLIS_HOME:-}" payload="${TRELLIS_VERIFIED_PAYLOAD:-}"
  local version="${TRELLIS_VERIFIED_RELEASE_VERSION:-}" canonical_home canonical_payload expected
  release_entry_path_is_clean "$home" &&
    release_entry_path_is_clean "$payload" &&
    release_entry_version_is_safe "$version" ||
    return 1
  [ -d "$home" ] && [ ! -L "$home" ] &&
    [ -d "$payload" ] && [ ! -L "$payload" ] ||
    return 1
  canonical_home="$(CDPATH='' cd "$home" && pwd -P)" ||
    return 1
  canonical_payload="$(CDPATH='' cd "$payload" && pwd -P)" ||
    return 1
  expected="$canonical_home/releases/$version/payload"
  [ "$canonical_payload" = "$expected" ] &&
    [ "$SCRIPT_DIR" = "$canonical_payload/scripts" ] &&
    [ "$RELEASE_SCRIPT_PATH" = "$canonical_payload/scripts/release.sh" ] &&
    [ -d "$SCRIPT_DIR" ] && [ ! -L "$SCRIPT_DIR" ] &&
    [ -f "$RELEASE_SCRIPT_PATH" ] && [ ! -L "$RELEASE_SCRIPT_PATH" ]
}

if [ "$release_bundle_mode" != true ]; then
  release_entry_gate || {
    printf '%s\n' 'trellis release: direct source execution is unsupported; run trellis release from the installed stable launcher' >&2
    exit 2
  }
fi

# Only now, with the release identity established and before any helper is
# sourced. An absent candidate leaves TMPDIR unset and says so downstream by
# its absence; a candidate that is present but outside the private namespace is
# refused by name rather than silently degraded to the global temp directory.
release_admit_command_scratch "$release_scratch_candidate" || {
  printf '%s\n' "trellis release: command scratch directory is not an admissible private Trellis temp directory: $release_scratch_candidate" >&2
  exit 4
}
unset release_scratch_candidate

if [ "$release_bundle_mode" = true ]; then
  for release_bundle_function in \
    trellis_home_resolve \
    release_store_normalize_version \
    local_registry_list_json \
    attachment_verify_adoption \
    attachment_verify_detach \
    attach_detach_json_keys_detail \
    attach_detach_json_keys_match; do
    command -v "$release_bundle_function" >/dev/null 2>&1 || {
      printf '%s\n' 'trellis release: verified command bundle is incomplete' >&2
      exit 5
    }
  done
else
  # shellcheck source=lib/trellis-home.sh
  . "$SCRIPT_DIR/lib/trellis-home.sh"
  # shellcheck source=lib/release-store.sh
  . "$SCRIPT_DIR/lib/release-store.sh"
  # shellcheck source=lib/local-registry.sh
  . "$SCRIPT_DIR/lib/local-registry.sh"
  # shellcheck source=lib/attachment.sh
  . "$SCRIPT_DIR/lib/attachment.sh"
  # Share the strict exclude parser and legitimate per-root deferral planner.
  # shellcheck source=attach-project.sh
  if [ -f "$SCRIPT_DIR/attach-project.sh" ]; then
    . "$SCRIPT_DIR/attach-project.sh"
  fi
fi

release_err() {
  printf 'trellis release: %s\n' "$*" >&2
}

release_git() {
  local socket="${SSH_AUTH_SOCK:-}"
  local -a command=(
    /usr/bin/env -i
    "HOME=${HOME:-/}"
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_CONFIG_COUNT=2"
    "GIT_CONFIG_KEY_0=core.fsmonitor"
    "GIT_CONFIG_VALUE_0=false"
    "GIT_CONFIG_KEY_1=core.hooksPath"
    "GIT_CONFIG_VALUE_1=/dev/null"
  )
  if [ -n "$socket" ]; then
    command+=("SSH_AUTH_SOCK=$socket")
  fi
  # Only the already admitted value, never the caller's carrier and never an
  # arbitrary TMPDIR. Unadmitted means Git gets no TMPDIR at all.
  if [ -n "$RELEASE_ADMITTED_TMPDIR" ]; then
    command+=("TMPDIR=$RELEASE_ADMITTED_TMPDIR")
  fi
  "${command[@]}" /usr/bin/git "$@"
}

release_verified_ssh_auth_sock() {
  local socket="${1:-}" parent base canonical_parent
  [ -n "$socket" ] || {
    printf '\n'
    return 0
  }
  release_store_absolute_path_is_clean "$socket" &&
    [ -S "$socket" ] &&
    [ ! -L "$socket" ] || return 1
  parent="${socket%/*}"
  base="${socket##*/}"
  [ -n "$parent" ] && [ -n "$base" ] &&
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  canonical_parent="$(CDPATH='' cd "$parent" && pwd -P)" || return 1
  [ "$canonical_parent/$base" = "$socket" ] || return 1
  printf '%s\n' "$socket"
}

release_requires_verified_payload() {
  [ "$release_bundle_mode" = true ] && return 0
  local home="${TRELLIS_HOME:-}" payload="${TRELLIS_VERIFIED_PAYLOAD:-}"
  local version="${TRELLIS_VERIFIED_RELEASE_VERSION:-}" normalized canonical_home canonical_payload expected release canonical_release
  release_store_absolute_path_is_clean "$home" ||
    return 1
  [ -d "$home" ] && [ ! -L "$home" ] ||
    return 1
  canonical_home="$(CDPATH='' cd "$home" && pwd -P)" ||
    return 1
  normalized="$(release_store_normalize_version "$version" 2>/dev/null)" ||
    return 1
  [ "$normalized" = "$version" ] ||
    return 1
  release_store_absolute_path_is_clean "$payload" ||
    return 1
  [ -d "$payload" ] && [ ! -L "$payload" ] ||
    return 1
  canonical_payload="$(CDPATH='' cd "$payload" && pwd -P)" ||
    return 1
  expected="$canonical_home/releases/$version/payload"
  [ "$canonical_payload" = "$expected" ] ||
    return 1
  [ "$SCRIPT_DIR" = "$canonical_payload/scripts" ] &&
    [ "$RELEASE_SCRIPT_PATH" = "$canonical_payload/scripts/release.sh" ] &&
    [ -d "$SCRIPT_DIR" ] && [ ! -L "$SCRIPT_DIR" ] &&
    [ -f "$RELEASE_SCRIPT_PATH" ] && [ ! -L "$RELEASE_SCRIPT_PATH" ] ||
    return 1
  release="$(release_store_release_path "$version" 2>/dev/null)" ||
    return 1
  canonical_release="$(CDPATH='' cd "$release" && pwd -P)" ||
    return 1
  [ "$canonical_release/payload" = "$canonical_payload" ]
}
release_prepare_verified_ssh_auth_sock() {
  local socket
  socket="$(release_verified_ssh_auth_sock "$RELEASE_VERIFIED_SSH_AUTH_SOCK")" ||
    return "$TRELLIS_EX_STATE"
  [ "$socket" = "$RELEASE_VERIFIED_SSH_AUTH_SOCK" ] ||
    return "$TRELLIS_EX_STATE"
  if [ -n "$socket" ]; then
    export SSH_AUTH_SOCK="$socket"
  else
    unset SSH_AUTH_SOCK
  fi
}

usage() {
  cat <<'EOF'
Usage:
  trellis release install VERSION [--remote URL]
  trellis release list
  trellis release locate VERSION
  trellis release verify [VERSION]
  trellis release reap-tmp [--fix]
  trellis release remove VERSION [--dry-run | --apply]
  trellis release adopt VERSION --project ID [--fleet NAME]
  trellis release adopt VERSION --fleet NAME
  trellis release adopt VERSION --all

Compatibility-only:
  trellis release adopt VERSION --runtime-anchor /absolute/project/.trellis/runtime

install requires an explicit --remote or the configured release_remote in
TRELLIS_HOME/config.json. It fetches annotated vVERSION and verifies its
immutable payload. Managed adoption uses only strict local-registry rows and
attachment ownership. It never guesses project paths; unavailable rows are
reported and are never changed.

reap-tmp lists leaked .tmp.* scratch in TRELLIS_HOME/releases and writes
nothing; --fix removes the entries older than 1 h whose owner process is dead,
or older than 24 h when no owner was recorded.

remove lists what deleting an installed VERSION frees, with sizes: its release
directory, execution snapshots and their locks, and release and exec stamps.
It writes nothing; --apply deletes them. It refuses while anything still
references VERSION: the active CLI release, an attachment owner record, a
registry release pin or runtime anchor, a managed Git hook, a project
trellis_version pin, a pending attachment or adoption journal, or a running
process. A registry row
that is not available refuses when it records VERSION or records no release.
The running-process check covers the invoking user's inspectable processes
only (lsof on macOS, /proc on Linux). Other users' processes, root's included,
are skipped and counted on stderr. So is a process of this user that the
kernel will not let it inspect (EACCES or EPERM, as for systemd --user or
ssh-agent), listed by pid and name; such a process can still use VERSION
unseen. Any other error reading a process refuses with exit 4.
EOF
}

usage_error() {
  release_err "$*"
  usage >&2
  return "$TRELLIS_EX_USAGE"
}

max_status() {
  [ "$2" -gt "$1" ] && printf '%s\n' "$2" || printf '%s\n' "$1"
}

target_label() {
  local row="$1" fleet project_id
  fleet="$(printf '%s\n' "$row" | jq -r '.fleet // empty')" || return "$TRELLIS_EX_STATE"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id // empty')" || return "$TRELLIS_EX_STATE"
  [ -n "$fleet" ] && [ -n "$project_id" ] || return "$TRELLIS_EX_STATE"
  printf '%s/%s\n' "$fleet" "$project_id"
}

runtime_anchor_matches_payload() {
  local anchor="$1" payload="$2" target
  [ -L "$anchor" ] || return "$TRELLIS_EX_CONFLICT"
  target="$(readlink "$anchor")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ "$target" = "$payload" ] || return "$TRELLIS_EX_CONFLICT"
}

adoption_directory_identity() {
  local path="$1" identity
  [ -d "$path" ] && [ ! -L "$path" ] || return "$TRELLIS_EX_CONFLICT"
  identity="$(release_store_directory_identity "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
  case "$identity" in
    [0-9]*:[0-9]*) ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
  printf '%s\n' "$identity"
}



release_home() {
  trellis_home_resolve ""
}

machine_config() {
  local home="$1" config
  config="$(trellis_home_config_path "$home")" || return "$?"
  if [ ! -f "$config" ] || [ -L "$config" ]; then
    release_err "machine configuration is required at $config"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  trellis_home_validate_config "$config" || return "$?"
  printf '%s\n' "$config"
}

configured_remote() {
  local home="$1" config remote
  config="$(machine_config "$home")" || return "$?"
  remote="$(jq -r '.release_remote // empty' "$config")" || return "$TRELLIS_EX_STATE"
  trellis_home_require_safe_text 'configured release remote' "$remote" || return "$?"
  printf '%s\n' "$remote"
}

payload_for() {
  local version="$1" release payload
  release="$(release_store_locate "$version")" || return "$?"
  payload="$release/payload"
  [ -d "$payload" ] && [ ! -L "$payload" ] || return "$TRELLIS_EX_STATE"
  release_store_assert_native_payload_layout "$payload" || return "$TRELLIS_EX_STATE"
  (CDPATH='' cd "$payload" && pwd -P)
}

tracked_portable_manifest_project_id() {
  local root="$1" manifest project_id
  manifest="$root/.trellis.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || {
    release_err "project manifest must be a regular file: $manifest"
    return "$TRELLIS_EX_STATE"
  }
  project_id="$(local_registry_manifest_project_id "$manifest")" || return "$?"
  if ! release_git -C "$root" ls-files --error-unmatch -- .trellis.json >/dev/null 2>&1; then
    release_err "project manifest must be tracked by the current Git worktree: $manifest"
    return "$TRELLIS_EX_CONFLICT"
  fi
  printf '%s\n' "$project_id"
}

adoption_binding_from_row() {
  local row="$1" fleet project_id project_key expected_key root checkout_root checkout worktree attachment release common harnesses
  fleet="$(printf '%s\n' "$row" | jq -r '.fleet // empty')" || return "$TRELLIS_EX_STATE"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id // empty')" || return "$TRELLIS_EX_STATE"
  project_key="$(printf '%s\n' "$row" | jq -r '.project_key // empty')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  checkout="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')" || return "$TRELLIS_EX_STATE"
  worktree="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')" || return "$TRELLIS_EX_STATE"
  attachment="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')" || return "$TRELLIS_EX_STATE"
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$row" | jq -r '.git_common_dir // empty')" || return "$TRELLIS_EX_STATE"
  harnesses="$(printf '%s\n' "$row" | jq -c '.harnesses')" || return "$TRELLIS_EX_STATE"
  [ -n "$fleet" ] && [ -n "$project_id" ] && [ -n "$project_key" ] && [ -n "$root" ] &&
    [ -n "$checkout" ] && [ -n "$worktree" ] && [ -n "$attachment" ] && [ -n "$release" ] &&
    [ -n "$common" ] || return "$TRELLIS_EX_STATE"
  expected_key="$(local_registry_project_key "$fleet" "$project_id" 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  [ "$project_key" = "$expected_key" ] || return "$TRELLIS_EX_STATE"
  local_registry_require_absolute_safe_path 'registered worktree root' "$root" >/dev/null 2>&1 || return "$TRELLIS_EX_STATE"
  local_registry_require_absolute_safe_path 'registered Git common directory' "$common" >/dev/null 2>&1 || return "$TRELLIS_EX_STATE"
  local_registry_require_attachment_id "$attachment" >/dev/null 2>&1 || return "$TRELLIS_EX_STATE"
  release="$(local_registry_normalize_release "$release" 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  [ -n "$release" ] || return "$TRELLIS_EX_STATE"
  harnesses="$(local_registry_normalize_harnesses "$harnesses" 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  [ "$harnesses" != '[]' ] || return "$TRELLIS_EX_STATE"
  checkout_root="$(local_registry_checkout_root_for_common_dir "$common" "$root")" || return "$TRELLIS_EX_STATE"
  jq -cnS \
    --arg fleet "$fleet" --arg project_id "$project_id" --arg root "$root" --arg checkout_root "$checkout_root" \
    --arg checkout_id "$checkout" --arg worktree_id "$worktree" \
    --arg attachment_id "$attachment" --arg release "$release" --arg git_common_dir "$common" \
    --argjson harnesses "$harnesses" \
    '{fleet:$fleet,project_id:$project_id,root:$root,checkout_root:$checkout_root,
      checkout_id:$checkout_id,worktree_id:$worktree_id,attachment_id:$attachment_id,release:$release,
      harnesses:$harnesses,git_common_dir:$git_common_dir}'
}
# Per-row continuation reaches adoption here. The whole-file strict reader would
# abort the whole run on the first broken row anywhere, so one unrelated
# identity_error row used to fail every healthy adoption target. Read
# diagnostically, then apply the SAME strict validation to the target's own
# checkout and worktree rows: the target still fails class 4/5 exactly as the
# whole-file validator would have made it. The registry WRITE in
# `update_group_registry` applies the same bound-row contract under the registry
# lock, over the proposal bytes, with whole-file schema validation intact.
adoption_current_registry_binding() {
  local home="$1" identity="$2" state actual
  state="$(local_registry_read_diagnostic_state "$home")" || return "$?"
  local_registry_validate_bound_row_identity "$state" \
    "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" \
    "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" || return "$?"
  actual="$(printf '%s\n' "$state" | jq -cS --argjson identity "$identity" '
    [ .projects | to_entries[] as $entry
      | $entry.value as $project
      | ($project.checkouts[$identity.checkout_id] // null) as $checkout
      | select($checkout != null and $checkout.git_common_dir == $identity.git_common_dir
               and $checkout.root == $identity.checkout_root)
      | ($checkout.worktrees[$identity.worktree_id] // null) as $worktree
      | select($worktree != null and $worktree.root == $identity.root)
      | select($project.status == "active")
      | select(($project.metadata.legacy.blacklisted // false) == false)
      | {fleet:$project.fleet,project_id:$project.project_id,root:$worktree.root,
         checkout_root:$checkout.root,checkout_id:$identity.checkout_id,
         worktree_id:$identity.worktree_id,attachment_id:($worktree.attachment_id // ""),
         release:($checkout.release // ""),harnesses:($checkout.harnesses | unique | sort),
         git_common_dir:$checkout.git_common_dir} ]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  [ -n "$actual" ] || return "$TRELLIS_EX_CONFLICT"
  printf '%s\n' "$actual"
}

owner_matches_row() {
  local owner="$1" binding="$2" identity="$3" payload="$4" expected actual owner_root
  expected="$(printf '%s\n' "$binding" | jq -cS 'del(.git_common_dir, .checkout_root)')" || return "$TRELLIS_EX_STATE"
  actual="$(jq -cS '
    (.artifacts + (.pre_existing // [])) as $owned
    | (any($owned[]; .path | startswith(".pi/"))) as $has_pi
    |
    def harness($path):
      if ($path | startswith(".codex/")) then "codex"
      elif ($path | startswith(".pi/")) then "pi"
      elif $path | startswith(".claude/") then "claude"
      elif (($has_pi | not) and ($path == "AGENTS.md" or ($path | startswith(".agents/")))) then "codex"
      else empty end;
    {fleet,project_id,root:.worktree_root,checkout_id,worktree_id,attachment_id,release,
     harnesses:([$owned[] | harness(.path)] | unique | sort)}
  ' "$owner" 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  [ "$actual" = "$expected" ] || return "$TRELLIS_EX_CONFLICT"
  owner_root="$(jq -r '.project_root' "$owner")" || return "$TRELLIS_EX_STATE"
  printf '%s\n' "$identity" | jq -e --arg owner_root "$owner_root" '.root == $owner_root' >/dev/null 2>&1 ||
    return "$TRELLIS_EX_CONFLICT"
  jq -e --arg payload "$payload" '
    ([.artifacts[] | select(.path == ".trellis/runtime" and .kind == "symlink" and .target == $payload)] | length) == 1
  ' "$owner" >/dev/null 2>&1
}

adoption_verify_owner_base() {
  local home="$1" owner="$2" record
  attachment_verify_detach "$home" "$owner" || return "$?"
  record="$(jq -c . "$owner")" || return "$TRELLIS_EX_STATE"
  _attachment_contextual_render_context_record_valid "$record" "$home" || return "$TRELLIS_EX_CONFLICT"
  _attachment_render_pairings_valid "$record" || return "$TRELLIS_EX_CONFLICT"
  _attachment_verify_adoption_hooks "$home" "$owner"
}

resolve_verified_adoption_target() {
  local home="$1" row="$2" binding root trellis root_identity trellis_identity identity current manifest_project_id project_id checkout worktree owner release payload hook_authority status
  local identity_rc dead_fleet dead_project dead_checkout
  binding="$(adoption_binding_from_row "$row")" || return "$?"
  root="$(printf '%s\n' "$binding" | jq -r '.root')" || return "$TRELLIS_EX_STATE"
  if ! identity="$(local_registry_identity_for_root "$root")"; then
    identity_rc="$?"
    dead_fleet="$(printf '%s\n' "$binding" | jq -r '.fleet // empty')" || dead_fleet=''
    dead_project="$(printf '%s\n' "$binding" | jq -r '.project_id // empty')" || dead_project=''
    dead_checkout="$(printf '%s\n' "$binding" | jq -r '.checkout_id // empty')" || dead_checkout=''
    [ -n "$dead_fleet" ] || dead_fleet='(unknown fleet)'
    [ -n "$dead_project" ] || dead_project='(unknown project)'
    [ -n "$dead_checkout" ] || dead_checkout='(unknown checkout)'
    release_err "adopt target names a dead registry row: $dead_fleet/$dead_project root $root checkout $dead_checkout"
    return "$identity_rc"
  fi
  if ! printf '%s\n' "$identity" | jq -e --argjson binding "$binding" '
    .root == $binding.root
    and .checkout_id == $binding.checkout_id
    and .checkout_root == $binding.checkout_root
    and .worktree_id == $binding.worktree_id
    and .git_common_dir == $binding.git_common_dir
  ' >/dev/null 2>&1; then
    release_err "selected registry row no longer matches the current Git worktree: $root"
    return "$TRELLIS_EX_CONFLICT"
  fi
  current="$(adoption_current_registry_binding "$home" "$identity")"
  status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq "$TRELLIS_EX_CONFLICT" ] && release_err "selected registry row no longer resolves to one active worktree: $root"
    return "$status"
  fi
  if [ "$current" != "$binding" ]; then
    release_err "selected registry row changed before release adoption: $root"
    return "$TRELLIS_EX_CONFLICT"
  fi
  manifest_project_id="$(tracked_portable_manifest_project_id "$root")" || return "$?"
  project_id="$(printf '%s\n' "$binding" | jq -r '.project_id')" || return "$TRELLIS_EX_STATE"
  if [ "$manifest_project_id" != "$project_id" ]; then
    release_err "current project manifest ID does not match the selected registry row: $root"
    return "$TRELLIS_EX_CONFLICT"
  fi
  checkout="$(printf '%s\n' "$binding" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  worktree="$(printf '%s\n' "$binding" | jq -r '.worktree_id')" || return "$TRELLIS_EX_STATE"
  owner="$(_attachment_ownership_path "$home" "$checkout" "$worktree")" || return "$TRELLIS_EX_STATE"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return "$TRELLIS_EX_UNAVAILABLE"
  hook_authority="$(adoption_verify_owner_base "$home" "$owner")" || return "$?"
  release="$(printf '%s\n' "$binding" | jq -r '.release')" || return "$TRELLIS_EX_STATE"
  payload="$(payload_for "$release")" || return "$?"
  owner_matches_row "$owner" "$binding" "$identity" "$payload"
  status=$?
  if [ "$status" -ne 0 ]; then
    release_err "attachment owner no longer exactly matches the selected registry row: $root"
    return "$status"
  fi
  root_identity="$(adoption_directory_identity "$root")" || return "$?"
  trellis="$root/.trellis"
  trellis_identity="$(adoption_directory_identity "$trellis")" || return "$?"
  runtime_anchor_matches_payload "$trellis/runtime" "$payload" || return "$?"
  jq -cnS --argjson binding "$binding" --argjson identity "$identity" \
    --arg owner "$owner" --arg old_version "$release" --arg old_payload "$payload" \
    --arg root_identity "$root_identity" --arg trellis_identity "$trellis_identity" \
    --arg hook_authority "$hook_authority" \
    '{binding:$binding,identity:$identity,owner:$owner,old_version:$old_version,old_payload:$old_payload,
      root_identity:$root_identity,trellis_identity:$trellis_identity,hook_authority:$hook_authority}'
}

owner_replacement() {
  local original="$1" replacement="$2" version="$3" payload="$4" retired="$5" pruned="${6:-[]}"
  local render_plans="${7:-[]}" context="${8:-null}"
  jq --arg version "$version" --arg payload "$payload" --argjson retired "$retired" --argjson pruned "$pruned" \
    --argjson render_plans "$render_plans" --argjson context "$context" '
    if ([.artifacts[] | select(.path == ".trellis/runtime" and .kind == "symlink")] | length) != 1
    then error("missing owned runtime anchor")
    else .release = $version
      | .artifacts |= map(if .path == ".trellis/runtime" then .target = $payload else . end)
      | .artifacts |= map(.path as $path | select(any($retired[]; .path == $path) | not))
      | .artifacts |= map(.path as $path
          | select(.kind == "parent" and any($pruned[]; .path == $path) | not))
      | if ($render_plans | length) > 0 then
          .renders = [$render_plans[].render]
          | .artifacts |= map(.path as $path
              | [$render_plans[] | select(.path == $path) | .render] as $renders
              | if ($renders | length) == 1
                then .sha256 = $renders[0].after_sha256 | .mode = $renders[0].after_mode
                else . end)
        else . end
      | if $context != null then .render_context = $context else . end
    end
  ' "$original" > "$replacement" || return "$TRELLIS_EX_STATE"
  chmod 600 "$replacement" || return "$TRELLIS_EX_UNAVAILABLE"
  _attachment_owner_json_valid "$replacement" || return "$TRELLIS_EX_STATE"
}

# A release can retire a native leaf (1.3.12 drops grok-ro/rw). Adoption
# re-plans the exclude from the new release whenever the block changes, for a
# group or a singleton, so an owned link the new plan no longer selects would
# dangle untracked. Only exact owned symlinks retire; renders and deferred
# project files are left alone.
adoption_retired_leaves() {
  local owner="$1" payload="$2" selection="$3" surfaces harness
  local -a harnesses=()
  # Without the planner nothing retires: a single-owner adopt then keeps both
  # its leaves and its old exclude block; a group adopt refuses at exclude
  # planning.
  command -v surface_plan_emit >/dev/null 2>&1 || { printf '[]\n'; return 0; }
  while IFS= read -r harness; do harnesses+=("$harness"); done < <(printf '%s\n' "$selection" | jq -r '.[]')
  surfaces="$(surface_plan_emit "$payload" "${harnesses[@]}")" || return "$?"
  jq -c --argjson surfaces "$surfaces" '
    [$surfaces.artifacts[].destination] as $planned
    | [.artifacts[] | select(.kind == "symlink" and .path != ".trellis/runtime")
       | .path as $path | select(($planned | index($path)) == null) | {path,target}]
  ' "$owner" || return "$TRELLIS_EX_STATE"
}

# Forward unlinks only a name verified as the exact recorded link after it
# was renamed aside; rollback recreates it only where nothing else stands.
adoption_retire_leaf() (
  local root="$1" leaf="$2" direction="$3" path target parent base held
  path="$(printf '%s\n' "$leaf" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  target="$(printf '%s\n' "$leaf" | jq -r '.target')" || return "$TRELLIS_EX_STATE"
  _attachment_parent_safe "$root" "$path" || return "$TRELLIS_EX_CONFLICT"
  parent="$(dirname "$root/$path")" || return "$TRELLIS_EX_STATE"
  base="$(basename "$path")" || return "$TRELLIS_EX_STATE"
  CDPATH='' cd "$parent" || return "$TRELLIS_EX_CONFLICT"
  [ "$(pwd -P)" = "$parent" ] || return "$TRELLIS_EX_CONFLICT"
  case "$direction" in
    forward)
      _attachment_symlink_matches "./$base" "$target" || return "$TRELLIS_EX_CONFLICT"
      held="./.${base}.release-adopt.$$"
      [ ! -e "$held" ] && [ ! -L "$held" ] || return "$TRELLIS_EX_CONFLICT"
      mv -- "./$base" "$held" || return "$TRELLIS_EX_UNAVAILABLE"
      if ! { [ -L "$held" ] && _attachment_symlink_matches "$held" "$target"; }; then
        mv -- "$held" "./$base"
        return "$TRELLIS_EX_CONFLICT"
      fi
      rm -- "$held" || return "$TRELLIS_EX_UNAVAILABLE"
      ;;
    rollback)
      _attachment_symlink_matches "./$base" "$target" && return 0
      [ ! -e "./$base" ] && [ ! -L "./$base" ] || return "$TRELLIS_EX_CONFLICT"
      ln -s -- "$target" "./$base" || return "$TRELLIS_EX_UNAVAILABLE"
      ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
)

# 1.3.18 stops rendering .pi/hooks: pi treats that directory as a deprecated
# resource and holds startup on a keypress while it exists, even empty. Once
# its leaves retire, the emptied directories go too, deepest first. Anything
# Trellis does not own keeps the tree in place, with a notice naming it.
adoption_pi_hooks_prune_plan() {
  local root="$1" retired="$2" old_owner="$3" dirs others owned_dirs pruned
  if [ ! -e "$root/.pi/hooks" ] && [ ! -L "$root/.pi/hooks" ]; then
    printf '[]\n'
    return 0
  fi
  if ! _attachment_parent_safe "$root" .pi/hooks/lib || [ -L "$root/.pi/hooks" ] || [ ! -d "$root/.pi/hooks" ]; then
    printf '[]\n'
    return 0
  fi
  dirs="$(cd "$root" && find .pi/hooks -mindepth 1 -type d | jq -R . | jq -cs .)" || return "$TRELLIS_EX_UNAVAILABLE"
  others="$(cd "$root" && find .pi/hooks -mindepth 1 ! -type d | jq -R . | jq -cs .)" || return "$TRELLIS_EX_UNAVAILABLE"
  owned_dirs="$(jq -c '[.artifacts[] | select(.kind == "parent") | .path]' "$old_owner")" ||
    return "$TRELLIS_EX_STATE"
  if jq -en --argjson dirs "$dirs" --argjson others "$others" --argjson retired "$retired" '
    ($dirs - [".pi/hooks/lib"]) == [] and ($others - [$retired[].path]) == []' >/dev/null; then
    pruned="$(jq -cn --argjson dirs "$dirs" --argjson owned "$owned_dirs" \
      --arg top "$(_attachment_mode "$root/.pi/hooks")" \
      --arg lib "$( [ -d "$root/.pi/hooks/lib" ] && _attachment_mode "$root/.pi/hooks/lib")" '
      [
        ($dirs[] | select(. as $path | $owned | index($path) != null) | {path:., mode:$lib}),
        (".pi/hooks" | select(
          ($owned | index(".pi/hooks")) != null
          and all($dirs[]; . as $path | ($owned | index($path)) != null)
        ) | {path:., mode:$top})
      ]')" || return "$TRELLIS_EX_STATE"
    if jq -en --argjson dirs "$dirs" --argjson owned "$owned_dirs" \
      '((($dirs + [".pi/hooks"]) - $owned) | length) > 0' >/dev/null; then
      release_err "left in place: $root/.pi/hooks holds files Trellis does not own; move them out so pi stops warning at startup"
    fi
    printf '%s\n' "$pruned"
  else
    release_err "left in place: $root/.pi/hooks holds files Trellis does not own; move them out so pi stops warning at startup"
    printf '[]\n'
  fi
}

# Forward removes an emptied directory; a late arrival only leaves it in
# place, unowned: the owner record already dropped its parent entry, so
# detach never removes a directory that now holds a project file. Rollback
# recreates it, with its recorded mode, before leaves return.
adoption_prune_dir() {
  local root="$1" dir="$2" direction="$3" path mode
  path="$(printf '%s\n' "$dir" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  mode="$(printf '%s\n' "$dir" | jq -r '.mode')" || return "$TRELLIS_EX_STATE"
  _attachment_parent_safe "$root" "$path" || return "$TRELLIS_EX_CONFLICT"
  case "$direction" in
    forward)
      [ -d "$root/$path" ] && [ ! -L "$root/$path" ] || return 0
      rmdir -- "$root/$path" 2>/dev/null ||
        release_err "left in place: $root/$path is not empty; move its files out so pi stops warning at startup"
      ;;
    rollback)
      [ -d "$root/$path" ] && [ ! -L "$root/$path" ] && return 0
      [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ] || return "$TRELLIS_EX_CONFLICT"
      mkdir -m "$mode" -- "$root/$path" || return "$TRELLIS_EX_UNAVAILABLE"
      ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
}

# The checkout lock serializes release adoption for this group. Capture its
# holder at acquisition, then recheck the link, identity, metadata and live
# process before any optional stale-stage cleanup. A missing proof is a miss.
release_adoption_lock_valid() {
  local home="${__release_adoption_home:-}" checkout="${__release_adoption_checkout:-}"
  local common="${__release_adoption_common:-}" link="${__release_adoption_link:-}"
  local holder="${__release_adoption_holder:-}" pid="${__release_adoption_pid:-}"
  local birth="${__release_adoption_birth:-}" target current_birth
  case "$pid" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ -n "$home" ] && [ -n "$checkout" ] && [ -n "$common" ] && [ -n "$birth" ] || return 1
  [ "$link" = "$home/state/locks/attachment-checkout-$checkout.lock" ] &&
    [ "${_ATTACHMENT_CHECKOUT_LOCK_LINK:-}" = "$link" ] &&
    [ "${_ATTACHMENT_CHECKOUT_LOCK_HOLDER:-}" = "$holder" ] && [ -L "$link" ] || return 1
  target="$(readlink "$link")" || return 1
  case "$target" in ''|*/*|.|..) return 1 ;; esac
  [ "$holder" = "${link%/*}/$target" ] && release_entry_private_directory "$holder" || return 1
  [ "$(_attachment_fs_identity "$holder")" = "${__release_adoption_holder_id:-}" ] &&
    [ -f "$holder/owner.json" ] && [ ! -L "$holder/owner.json" ] && [ -O "$holder/owner.json" ] &&
    _attachment_mode_matches "$holder/owner.json" 600 &&
    [ "$(_attachment_fs_identity "$holder/owner.json")" = "${__release_adoption_owner_id:-}" ] || return 1
  jq -e --arg checkout "$checkout" --arg common "$common" --arg birth "$birth" --argjson pid "$pid" '
    type == "object" and (keys | sort) == ["checkout_id","git_common_dir","pid","process_birth"]
    and .checkout_id == $checkout and .git_common_dir == $common
    and .pid == $pid and .process_birth == $birth
  ' "$holder/owner.json" >/dev/null 2>&1 || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  current_birth="$(_attachment_process_birth "$pid")" || return 1
  [ "$current_birth" = "$birth" ]
}

# Reap only old, owned, non-symlink stages of this exact transaction target.
# The held checkout lock excludes a live publisher. The descriptor-relative
# sink rechecks that lock, entry identities, membership and ACLs before each
# unlink. A failed/indeterminate proof leaves the entry for a later run.
release_adoption_reap_stale() {
  local target="$1" kind="$2" render_root="${3:-}" shared="${4:-false}" parent base prefix candidate found=false
  local python_bin allowed='' birth_program=''
  case "$target" in /*/*) ;; *) return 0 ;; esac
  parent="${target%/*}"; [ -n "$parent" ] || parent=/
  base="${target##*/}"
  case "$base" in ''|.|..) return 0 ;; esac
  case "$kind" in
    owner|hooks) prefix=".${base}.release-adopt." ;;
    render) prefix=".${base}.release-adopt-render." ;;
    *) return 0 ;;
  esac
  for candidate in "$parent/$prefix"??????; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then found=true; break; fi
  done
  [ "$found" = true ] || return 0
  if [ "$kind" = render ]; then
    if [ -n "$render_root" ]; then
      case "$target" in "$render_root/"*) ;; *) return 0 ;; esac
      _attachment_parent_safe "$render_root" "${target#"$render_root"/}" || return 0
    else
      [ "$shared" = true ] && [ "$target" = "${__release_adoption_common:-}/info/exclude" ] || return 0
    fi
  fi
  release_adoption_lock_valid || return 0
  python_bin="$(command -v python3)" || return 0
  case "$python_bin" in /*) ;; *) return 0 ;; esac
  if [ "$kind" = hooks ]; then
    allowed="$(_attachment_hooks_passthrough_names)" || return 0
  fi
  if [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ]; then
    birth_program="$(trellis_process_birth_python)" || return 0
  fi
  "$python_bin" -I - "$parent" "$prefix" "$kind" \
    "$__release_adoption_link" "$__release_adoption_holder" "$__release_adoption_pid" \
    "$__release_adoption_birth" "$__release_adoption_checkout" "$__release_adoption_common" \
    "$__release_adoption_holder_id" "$__release_adoption_owner_id" "$allowed" "$birth_program" <<'PY' || release_err "stale adoption-stage inspection failed; leaving candidates in $parent"
import ctypes, errno, json, os, re, stat, subprocess, sys, time

(parent, prefix, kind, link, holder, pid_text, birth, checkout, common,
 holder_id, owner_id, allowed_text, birth_program) = sys.argv[1:]
uid = os.geteuid()
try:
    pid = int(pid_text)
except ValueError:
    sys.exit(0)
if pid <= 0 or str(pid) != pid_text:
    sys.exit(0)

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0)
FILE = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, 'O_CLOEXEC', 0)
allowed = set(allowed_text.splitlines()) | {
    'post-checkout', 'pre-push', 'previous-hooks-path', 'release-payload', 'pre-push-source'}
pattern = re.compile(re.escape(prefix) + r'[A-Za-z0-9]{6}\Z', re.ASCII)
cutoff = time.time_ns() - 86400 * 1000000000

def ident(st):
    return (st.st_dev, st.st_ino, st.st_uid, st.st_mode, st.st_nlink,
            st.st_size, st.st_mtime_ns, st.st_ctime_ns)

def key(st):
    return '%d:%d' % (st.st_dev, st.st_ino)

def no_acl(fd):
    if sys.platform == 'darwin':
        libc = ctypes.CDLL(None, use_errno=True)
        libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.acl_get_fd_np.restype = ctypes.c_void_p
        libc.acl_free.argtypes = [ctypes.c_void_p]
        ctypes.set_errno(0)
        acl = libc.acl_get_fd_np(fd, 0x100)
        if not acl:
            return ctypes.get_errno() == errno.ENOENT
        # A returned ACL handle is not proof of absence. In particular,
        # Darwin acl_get_entry returns 0 when an entry is present.
        libc.acl_free(acl)
        return False
    for name in ('system.posix_acl_access', 'system.posix_acl_default'):
        try:
            os.getxattr(fd, name)
        except OSError as error:
            if error.errno != errno.ENODATA:
                return False
        else:
            return False
    return True

def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError('duplicate lock metadata')
        result[name] = value
    return result

def live_birth():
    if sys.platform == 'darwin':
        if not birth_program:
            return False
        command = [sys.executable, '-I', '-c', birth_program, pid_text]
    else:
        command = ['/bin/ps', '-p', pid_text, '-o', 'lstart=']
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=5,
                            env={'LC_ALL': 'C', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'})
    return result.returncode == 0 and result.stdout.decode('utf-8').rstrip('\n') == birth

def lock_held():
    try:
        link_stat = os.lstat(link)
        if (not stat.S_ISLNK(link_stat.st_mode) or link_stat.st_uid != uid
                or os.path.dirname(holder) != os.path.dirname(link)
                or os.readlink(link) != os.path.basename(holder)):
            return False
        holder_fd = os.open(holder, DIR)
        try:
            h = os.fstat(holder_fd)
            if (not stat.S_ISDIR(h.st_mode) or h.st_uid != uid or stat.S_IMODE(h.st_mode) != 0o700
                    or key(h) != holder_id or key(os.lstat(holder)) != holder_id or not no_acl(holder_fd)):
                return False
            owner_fd = os.open('owner.json', FILE, dir_fd=holder_fd)
            try:
                o = os.fstat(owner_fd)
                if (not stat.S_ISREG(o.st_mode) or o.st_uid != uid or stat.S_IMODE(o.st_mode) != 0o600
                        or o.st_nlink != 1 or key(o) != owner_id or not no_acl(owner_fd)):
                    return False
                data = os.read(owner_fd, 4097)
                if len(data) > 4096:
                    return False
                record = json.loads(data, object_pairs_hook=unique_object)
                if (not isinstance(record, dict) or set(record) != {'checkout_id', 'git_common_dir', 'pid', 'process_birth'}
                        or type(record['pid']) is not int or record['pid'] != pid
                        or record['checkout_id'] != checkout or record['git_common_dir'] != common
                        or record['process_birth'] != birth
                        or ident(os.stat('owner.json', dir_fd=holder_fd, follow_symlinks=False)) != ident(o)):
                    return False
            finally:
                os.close(owner_fd)
            if key(os.lstat(holder)) != holder_id or os.readlink(link) != os.path.basename(holder):
                return False
        finally:
            os.close(holder_fd)
        os.kill(pid, 0)
        return live_birth()
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError, AttributeError):
        return False

def safe_file(st):
    return (stat.S_ISREG(st.st_mode) and st.st_uid == uid and st.st_nlink == 1
            and not (st.st_mode & 0o022))

try:
    parent_fd = os.open(parent, DIR)
    parent_id = os.fstat(parent_fd)
    if (not stat.S_ISDIR(parent_id.st_mode) or parent_id.st_uid != uid
            or parent_id.st_mode & 0o022 or not no_acl(parent_fd)
            or key(os.lstat(parent)) != key(parent_id)):
        sys.exit(0)
except OSError:
    sys.exit(0)

def parent_current():
    try:
        current = os.lstat(parent)
        return stat.S_ISDIR(current.st_mode) and key(current) == key(parent_id)
    except OSError:
        return False

def stage_current(name, st):
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        return (stat.S_ISDIR(current.st_mode) and current.st_uid == uid
                and stat.S_IMODE(current.st_mode) == 0o700 and key(current) == key(st))
    except OSError:
        return False

try:
    for name in os.listdir(parent_fd):
        if not pattern.fullmatch(name):
            continue
        try:
            before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if (before.st_uid != uid or before.st_dev != parent_id.st_dev
                    or before.st_mtime_ns >= cutoff):
                continue
            if kind in ('owner', 'render'):
                if not safe_file(before):
                    continue
                fd = os.open(name, FILE, dir_fd=parent_fd)
                try:
                    if (ident(os.fstat(fd)) != ident(before) or not no_acl(fd)
                            or not lock_held() or not parent_current()
                            or ident(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) != ident(before)
                            or ident(os.fstat(fd)) != ident(before)):
                        continue
                    os.unlink(name, dir_fd=parent_fd)
                finally:
                    os.close(fd)
            elif kind == 'hooks' and stat.S_ISDIR(before.st_mode) and stat.S_IMODE(before.st_mode) == 0o700:
                stage_fd = os.open(name, DIR, dir_fd=parent_fd)
                files = []
                try:
                    if (ident(os.fstat(stage_fd)) != ident(before) or not no_acl(stage_fd)):
                        continue
                    good = True
                    for child in os.listdir(stage_fd):
                        item = os.stat(child, dir_fd=stage_fd, follow_symlinks=False)
                        if child not in allowed or not safe_file(item) or item.st_dev != before.st_dev:
                            good = False
                            break
                        fd = os.open(child, FILE, dir_fd=stage_fd)
                        files.append((child, fd, item))
                        if ident(os.fstat(fd)) != ident(item) or not no_acl(fd):
                            good = False
                            break
                    if not good or not lock_held() or not parent_current() or not stage_current(name, before):
                        continue
                    for child, fd, item in files:
                        if (not lock_held() or not parent_current() or not stage_current(name, before)
                                or ident(os.fstat(fd)) != ident(item) or not no_acl(fd)
                                or ident(os.stat(child, dir_fd=stage_fd, follow_symlinks=False)) != ident(item)):
                            good = False
                            break
                        os.unlink(child, dir_fd=stage_fd)
                    if good and not os.listdir(stage_fd) and lock_held() and parent_current() and stage_current(name, before):
                        os.rmdir(name, dir_fd=parent_fd)
                finally:
                    for _, fd, _ in files:
                        os.close(fd)
                    os.close(stage_fd)
        except (OSError, ValueError, UnicodeError):
            continue
finally:
    os.close(parent_fd)
PY
}

# Sweep only destinations from validated plans for the held checkout. Render
# paths are rechecked beneath their recorded root; the shared exclude is a
# separately bound exact path. Unknown or unsafe inputs are simply retained.
release_adoption_reap_completed_stages() {
  local plans="$1" shared="${2:-}" kind target render_root
  [ -f "$plans" ] && [ ! -L "$plans" ] || return 0
  if [ -n "$shared" ] && [ "$shared" = "${__release_adoption_common:-}/info/exclude" ]; then
    release_adoption_reap_stale "$shared" render '' true
  fi
  while IFS= read -r -d '' kind && IFS= read -r -d '' target && IFS= read -r -d '' render_root; do
    release_adoption_reap_stale "$target" "$kind" "$render_root"
  done < <(jq -j --arg home "${__release_adoption_home:-}" --arg checkout "${__release_adoption_checkout:-}" \
    --arg common "${__release_adoption_common:-}" '
    select(.binding.checkout_id == $checkout and .binding.git_common_dir == $common)
    | (.binding.root // "") as $root
    | ((if .owner == ($home + "/state/attachments/" + $checkout + "/" + .binding.worktree_id + ".json")
        then ["owner", .owner, ""] else empty end),
       (.renders[]? | select((.destination | type) == "string") | ["render", .destination, $root]),
       (if .hooks == "true" and .managed == ($home + "/state/git-hooks/" + $checkout)
        then ["hooks", .managed, ""] else empty end))
    | .[] | ., "\u0000"
  ' "$plans" 2>/dev/null)
}

replace_owned_file() (
  local destination="$1" expected="$2" replacement="$3" parent base actual_parent temporary=''
  local rc
  # The handler may interrupt a callee with same-named locals; keep its
  # transaction state in uniquely named variables in this subshell.
  __rof_destination="$destination" __rof_expected="$expected" __rof_replacement="$replacement"
  __rof_temporary='' __rof_temporary_identity='' __rof_destination_identity='' __rof_committed=false

  replace_owned_file_cleanup() {
    local status="${1:-$?}" rollback=0 cleanup_status=0
    trap '' HUP INT TERM
    trap - EXIT

    if [ -n "$__rof_temporary" ]; then
      if [ "$__rof_committed" = true ]; then
        if [ -f "$__rof_temporary" ] && [ ! -L "$__rof_temporary" ] &&
          _attachment_identity_matches "$__rof_temporary" "$__rof_destination_identity" file &&
          _attachment_mode_matches "$__rof_temporary" 600 &&
          cmp -s "$__rof_expected" "$__rof_temporary"; then
          rm "${__rof_temporary:?}" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
          [ "$cleanup_status" -eq 0 ] && __rof_temporary=''
        else
          cleanup_status="$TRELLIS_EX_CONFLICT"
        fi
      elif [ -f "$__rof_destination" ] && [ ! -L "$__rof_destination" ] &&
        _attachment_identity_matches "$__rof_destination" "$__rof_temporary_identity" file &&
        _attachment_mode_matches "$__rof_destination" 600 &&
        cmp -s "$__rof_replacement" "$__rof_destination"; then
        release_store_rename_swap "$__rof_temporary" "$__rof_destination"
        rollback=$?
        if [ "$rollback" -eq 0 ]; then
          if [ -f "$__rof_temporary" ] && [ ! -L "$__rof_temporary" ] &&
            _attachment_identity_matches "$__rof_temporary" "$__rof_temporary_identity" file &&
            _attachment_mode_matches "$__rof_temporary" 600 &&
            cmp -s "$__rof_replacement" "$__rof_temporary"; then
            rm "${__rof_temporary:?}" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
            [ "$cleanup_status" -eq 0 ] && __rof_temporary=''
          else
            cleanup_status="$TRELLIS_EX_CONFLICT"
          fi
        else
          cleanup_status="$(max_status "$cleanup_status" "$rollback")"
        fi
      elif [ -f "$__rof_temporary" ] && [ ! -L "$__rof_temporary" ] &&
        _attachment_identity_matches "$__rof_temporary" "$__rof_temporary_identity" file &&
        _attachment_mode_matches "$__rof_temporary" 600 &&
        cmp -s "$__rof_replacement" "$__rof_temporary"; then
        rm "${__rof_temporary:?}" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
        [ "$cleanup_status" -eq 0 ] && __rof_temporary=''
      else
        cleanup_status="$TRELLIS_EX_CONFLICT"
      fi
    fi
    [ "$cleanup_status" -eq 0 ] || status="$(max_status "$status" "$cleanup_status")"
    exit "$status"
  }
  trap 'replace_owned_file_cleanup "$?"' EXIT
  # Bash 3.2 can discard the transaction's locals before an EXIT trap reached
  # through `exit`; roll back while the signal handler still has that scope.
  trap 'replace_owned_file_cleanup "$TRELLIS_EX_UNAVAILABLE"' HUP INT TERM

  [ -f "$expected" ] && [ ! -L "$expected" ] || return "$TRELLIS_EX_CONFLICT"
  [ -f "$replacement" ] && [ ! -L "$replacement" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_mode_matches "$expected" 600 || return "$TRELLIS_EX_CONFLICT"
  parent="$(dirname "$destination")" || return "$TRELLIS_EX_STATE"
  base="$(basename "$destination")" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$parent" || return "$TRELLIS_EX_CONFLICT"
  CDPATH='' cd "$parent" || return "$TRELLIS_EX_CONFLICT"
  actual_parent="$(pwd -P)" || return "$TRELLIS_EX_CONFLICT"
  [ "$actual_parent" = "$parent" ] || return "$TRELLIS_EX_CONFLICT"
  __rof_destination="./$base"
  destination="$__rof_destination"
  [ -f "$destination" ] && [ ! -L "$destination" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_mode_matches "$destination" 600 || return "$TRELLIS_EX_CONFLICT"
  cmp -s "$expected" "$destination" || return "$TRELLIS_EX_CONFLICT"
  __rof_destination_identity="$(_attachment_fs_identity "$destination")" || return "$TRELLIS_EX_UNAVAILABLE"
  __rof_temporary="$(mktemp "./.${base}.release-adopt.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  temporary="$__rof_temporary"
  [ -f "$temporary" ] && [ ! -L "$temporary" ] || return "$TRELLIS_EX_CONFLICT"
  chmod 600 "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  cat "$replacement" > "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 600 "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
    _attachment_mode_matches "$temporary" 600 &&
    cmp -s "$replacement" "$temporary" || return "$TRELLIS_EX_CONFLICT"
  __rof_temporary_identity="$(_attachment_fs_identity "$temporary")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -f "$destination" ] && [ ! -L "$destination" ] &&
    _attachment_identity_matches "$destination" "$__rof_destination_identity" file &&
    _attachment_mode_matches "$destination" 600 &&
    cmp -s "$expected" "$destination" || return "$TRELLIS_EX_CONFLICT"
  release_store_rename_swap "$temporary" "$destination"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! { [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
    _attachment_identity_matches "$temporary" "$__rof_destination_identity" file &&
    _attachment_mode_matches "$temporary" 600 &&
    cmp -s "$expected" "$temporary"; } ||
    ! { [ -f "$destination" ] && [ ! -L "$destination" ] &&
    _attachment_identity_matches "$destination" "$__rof_temporary_identity" file &&
    _attachment_mode_matches "$destination" 600 &&
    cmp -s "$replacement" "$destination"; }; then
    return "$TRELLIS_EX_CONFLICT"
  fi
  __rof_committed=true
  return 0
)


hook_payload_matches() {
  local managed="$1" expected="$2" root="${3:-}" sidecar mode source manifest previous post_checkout pre_push
  [ -n "$root" ] || return "$TRELLIS_EX_STATE"
  [ -d "$managed" ] && [ ! -L "$managed" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_has_only_state_files "$managed" || return "$TRELLIS_EX_CONFLICT"
  mode="$(_attachment_mode "$managed")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ "$mode" = 700 ] || return "$TRELLIS_EX_CONFLICT"
  sidecar="$managed/release-payload"
  [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || return "$TRELLIS_EX_CONFLICT"
  mode="$(_attachment_mode "$sidecar")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ "$mode" = 600 ] || return "$TRELLIS_EX_CONFLICT"
  printf '%s\n' "$expected" | cmp -s - "$sidecar" || return "$TRELLIS_EX_CONFLICT"
  source="$(_attachment_hooks_read_sidecar "$managed/pre-push-source")" || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_pre_push_source_valid "$source" || return "$TRELLIS_EX_CONFLICT"
  previous="$(_attachment_hooks_read_sidecar "$managed/previous-hooks-path" true)" || return "$TRELLIS_EX_CONFLICT"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$expected")" || return "$TRELLIS_EX_STATE"
  post_checkout="$(_attachment_hooks_post_checkout_dispatcher_body "$expected" "$manifest")" || return "$TRELLIS_EX_CONFLICT"
  pre_push="$(_attachment_hooks_pre_push_dispatcher_body "$expected" "$source" "$manifest")" || return "$TRELLIS_EX_CONFLICT"
  [ -n "$post_checkout" ] && [ -n "$pre_push" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_file_matches "$managed/post-checkout" "$post_checkout" 700 || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_file_matches "$managed/pre-push" "$pre_push" 700 || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_verify_passthrough_shims "$managed" "$root" "$previous" "$expected" ||
    return "$TRELLIS_EX_CONFLICT"
}

write_hook_state_file() {
  local path="$1" contents="$2" mode="$3"
  printf '%s\n' "$contents" > "$path" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod "$mode" "$path" || return "$TRELLIS_EX_UNAVAILABLE"
}


replace_hook_payload() (
  local managed="${1:-}" expected="${2:-}" replacement="${3:-}" root="${4:-}"
  local hooks_root base temporary='' source previous manifest rc expected_shims shim_name shim_body post_checkout pre_push memo_home
  # The handler can run inside hook_payload_matches, which has locals named
  # managed/expected/root. Keep transaction state under subshell-private names.
  __rhp_managed="$managed" __rhp_expected="$expected" __rhp_replacement="$replacement" __rhp_root="$root"
  __rhp_temporary='' __rhp_committed=false

  release_hook_transaction_cleanup() {
    local status="${1:-$?}" rollback=0 temporary_expected=''
    trap '' HUP INT TERM
    trap - EXIT

    # An interruption can land while the kernel exchange is in flight, before
    # the shell observes its return. Determine the actual pair of states rather
    # than relying on a post-exchange flag: either state keeps $managed valid.
    if [ "$__rhp_committed" != true ] && [ -n "$__rhp_temporary" ] &&
      [ -d "$__rhp_temporary" ] && [ ! -L "$__rhp_temporary" ] &&
      [ -d "$__rhp_managed" ] && [ ! -L "$__rhp_managed" ]; then
      if hook_payload_matches "$__rhp_managed" "$__rhp_expected" "$__rhp_root" &&
        hook_payload_matches "$__rhp_temporary" "$__rhp_replacement" "$__rhp_root"; then
        :
      elif hook_payload_matches "$__rhp_managed" "$__rhp_replacement" "$__rhp_root" &&
        hook_payload_matches "$__rhp_temporary" "$__rhp_expected" "$__rhp_root"; then
        release_store_rename_swap "$__rhp_temporary" "$__rhp_managed" || rollback=$?
      else
        rollback="$TRELLIS_EX_CONFLICT"
      fi
    fi

    if [ "$__rhp_committed" = true ]; then
      temporary_expected="$__rhp_expected"
    else
      temporary_expected="$__rhp_replacement"
    fi
    if [ -n "$__rhp_temporary" ] && { [ -e "$__rhp_temporary" ] || [ -L "$__rhp_temporary" ]; }; then
      if [ "$rollback" -eq 0 ] &&
        [ -d "$__rhp_temporary" ] && [ ! -L "$__rhp_temporary" ] &&
        hook_payload_matches "$__rhp_temporary" "$temporary_expected" "$__rhp_root"; then
        rm -rf "${__rhp_temporary:?}" || rollback="$TRELLIS_EX_UNAVAILABLE"
      else
        [ "$rollback" -ne 0 ] || rollback="$TRELLIS_EX_CONFLICT"
      fi
    fi
    [ "$rollback" -eq 0 ] || status="$(max_status "$status" "$rollback")"
    exit "$status"
  }

  trap 'release_hook_transaction_cleanup "$?"' EXIT
  # Run signal cleanup before Bash 3.2 unwinds the transaction's locals.
  trap 'release_hook_transaction_cleanup "$TRELLIS_EX_STATE"' HUP INT TERM

  # Returns from this subshell function retain its locals for the EXIT trap;
  # explicit exits can discard them in Bash 3.2, leaving a staged transaction.
  [ "$#" -eq 4 ] && [ -n "$managed" ] && [ -n "$expected" ] && [ -n "$replacement" ] && [ -n "$root" ] ||
    return "$TRELLIS_EX_USAGE"
  hook_payload_matches "$managed" "$expected" "$root" || return "$?"
  hooks_root="$(dirname "$managed")" || return "$TRELLIS_EX_STATE"
  base="$(basename "$managed")" || return "$TRELLIS_EX_STATE"
  [ -d "$hooks_root" ] && [ ! -L "$hooks_root" ] || return "$TRELLIS_EX_CONFLICT"
  source="$(_attachment_hooks_read_sidecar "$managed/pre-push-source")" || return "$TRELLIS_EX_CONFLICT"
  previous="$(_attachment_hooks_read_sidecar "$managed/previous-hooks-path" true)" || return "$TRELLIS_EX_CONFLICT"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$replacement")" || return "$TRELLIS_EX_STATE"
  # Validate both replacement programs before allocating or exchanging state.
  if ! post_checkout="$(_attachment_hooks_post_checkout_dispatcher_body "$replacement" "$manifest")" ||
     ! pre_push="$(_attachment_hooks_pre_push_dispatcher_body "$replacement" "$source" "$manifest")" ||
     [ -z "$post_checkout" ] || [ -z "$pre_push" ]; then
    release_err "managed hook generation failed; current dispatcher was preserved"
    return "$TRELLIS_EX_STATE"
  fi
  __rhp_temporary="$(mktemp -d "$hooks_root/.${base}.release-adopt.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  temporary="$__rhp_temporary"
  chmod 700 "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  write_hook_state_file "$temporary/post-checkout" "$post_checkout" 700 ||
    return "$?"
  write_hook_state_file "$temporary/pre-push" "$pre_push" 700 ||
    return "$?"
  write_hook_state_file "$temporary/previous-hooks-path" "$previous" 600 || return "$?"
  write_hook_state_file "$temporary/release-payload" "$replacement" 600 || return "$?"
  write_hook_state_file "$temporary/pre-push-source" "$source" 600 || return "$?"
  expected_shims=$(_attachment_hooks_expected_passthrough_names "$root" "$previous" "$replacement") || return "$TRELLIS_EX_UNAVAILABLE"
  while IFS= read -r shim_name; do
    [ -n "$shim_name" ] || continue
    shim_body=$(_attachment_hooks_shim_body_for "$shim_name" "$previous") || return "$TRELLIS_EX_STATE"
    write_hook_state_file "$temporary/$shim_name" "$shim_body" 700 || return "$?"
  done <<<"$expected_shims"

  # Both paths are siblings under $hooks_root, so the release-store primitive
  # performs one same-filesystem exchange and never unlinks core.hooksPath.
  release_store_rename_swap "$temporary" "$managed"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  hook_payload_matches "$temporary" "$expected" "$root" || return "$?"
  hook_payload_matches "$managed" "$replacement" "$root" || return "$?"
  if [ -f "$expected/core-rules/native/artifacts.json" ] || [ -f "$replacement/core-rules/native/artifacts.json" ]; then
    memo_home="${hooks_root%/state/git-hooks}"
    [ "$hooks_root" = "$memo_home/state/git-hooks" ] || return "$TRELLIS_EX_STATE"
    # Memos are shared content-addressed generator receipts, not installed-file
    # snapshots. Retain both generations on rollback; restored owner/anchor/
    # registry select the old key, whose bytes are never replaced by new data.
    _attachment_hooks_digest_memo_write "$memo_home" "$replacement" "$manifest" "$source" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  __rhp_committed=true
  rm -rf "${temporary:?}" || return "$TRELLIS_EX_UNAVAILABLE"
  __rhp_temporary=''
  return 0
)

adoption_render_owned_parents_valid() {
  local file="$1" keys="$2"
  trellis_jq -e --argjson keys "$keys" '
    def lookup($value; $path):
      reduce $path[] as $key ({value:$value,exists:true};
        if .exists and (.value | type) == "object" and (.value | has($key))
        then .value = .value[$key]
        else .exists = false
        end);
    . as $current
    | ($current | type) == "object"
    and all($keys[];
      .path as $path
      | all(range(1; $path | length);
          lookup($current; $path[0:.]) as $parent
          | ($parent.exists | not) or (($parent.value | type) == "object")))
  ' "$file" >/dev/null 2>&1
}

adoption_render_live_matches() {
  local destination="$1" source="$2" identity="$3" expected_hash="$4" expected_mode="$5"
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  [ -z "$identity" ] || _attachment_identity_matches "$destination" "$identity" file || return 1
  [ "$(_attachment_hash "$destination")" = "$expected_hash" ] || return 1
  _attachment_mode_matches "$destination" "$expected_mode" || return 1
  cmp -s "$source" "$destination"
}

adoption_private_render_file_matches() {
  local path="$1" identity="$2" expected_hash="$3" expected_mode="$4"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  _attachment_identity_matches "$path" "$identity" file || return 1
  [ "$(_attachment_hash "$path")" = "$expected_hash" ] || return 1
  _attachment_mode_matches "$path" "$expected_mode"
}

# Locates the NEW release template behind one explicit-json render
# destination and prints its leaf paths, so adoption can report owned keys the
# new template no longer carries (key-removal is add-only upstream and adopt
# replays recorded owned values, leaving dropped keys silently in place).
# Prints `{"found":true,"leaves":[...]}` (leaves as {path,value} entries in
# the owner record's owned_keys shape) or `{"found":false,"leaves":[]}`
# when no single explicit-json render entry matches or the template is not a
# readable JSON object. Total: always exits 0, never fails an adoption. The
# raw template file is diffed, not the contextually rendered one; rendering
# substitutes values, and owned-key PATHS are what this reports.
adoption_new_template_leaves() {
  local new_payload="$1" relative="$2" manifest templates count template source
  if [ -z "$new_payload" ] || [ -z "$relative" ]; then
    printf '%s\n' '{"found":false,"leaves":[]}'
    return 0
  fi
  manifest="$new_payload/core-rules/inheritance-manifest.json"
  if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
    printf '%s\n' '{"found":false,"leaves":[]}'
    return 0
  fi
  templates="$(jq -c --arg path "$relative" '[.harnesses[]?.render[]? | select(.destination == $path and .merge == "explicit-json") | .template] | unique' "$manifest" 2>/dev/null)" || templates='[]'
  count="$(printf '%s\n' "$templates" | jq -r 'length' 2>/dev/null)" || count=0
  if [ "$count" != 1 ]; then
    printf '%s\n' '{"found":false,"leaves":[]}'
    return 0
  fi
  template="$(printf '%s\n' "$templates" | jq -r '.[0]' 2>/dev/null)" || template=''
  source="$new_payload/$template"
  case "$source" in "$new_payload"/*) ;; *) printf '%s\n' '{"found":false,"leaves":[]}'; return 0 ;; esac
  if [ ! -f "$source" ] || [ -L "$source" ]; then
    printf '%s\n' '{"found":false,"leaves":[]}'
    return 0
  fi
  if ! jq -e 'type == "object"' "$source" >/dev/null 2>&1; then
    printf '%s\n' '{"found":false,"leaves":[]}'
    return 0
  fi
  jq -cn --slurpfile template "$source" '
    def leaves($value; $path):
      if ($value | type) == "object"
      then if ($value | length) == 0 then [{path:$path,value:$value}]
           else [$value | to_entries[] | leaves(.value; $path + [.key])] | add end
      else [{path:$path,value:$value}] end;
    {found:true,leaves:leaves($template[0]; [])}
  ' 2>/dev/null || printf '%s\n' '{"found":false,"leaves":[]}'
  return 0
}

adoption_snapshot_render() {
  local root="$1" render="$2" work="$3" number="$4" index="$5" new_payload="${6:-}"
  local migrate="${7:-false}" context="${8:-}" template template_file merge_plan new_keys created after64
  local before_file inverse_file before_exists before64 before_hash before_mode original_before_exists reconstructed reconstruction
  local relative destination after_mode keys path_identity source candidate source_identity source_hash source_mode
  local candidate_identity candidate_hash drift template_leaves template_dropped
  relative="$(printf '%s\n' "$render" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  after_mode="$(printf '%s\n' "$render" | jq -r '.after_mode')" || return "$TRELLIS_EX_STATE"
  keys="$(printf '%s\n' "$render" | jq -c '.owned_keys')" || return "$TRELLIS_EX_STATE"
  _attachment_parent_safe "$root" "$relative" || return "$TRELLIS_EX_CONFLICT"
  destination="$(_attachment_destination "$root" "$relative")" || return "$TRELLIS_EX_STATE"
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    release_err "explicit-json render target is absent: $relative"
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ ! -f "$destination" ] || [ -L "$destination" ]; then
    release_err "explicit-json render target is not a regular file: $relative"
    return "$TRELLIS_EX_CONFLICT"
  fi
  source_mode="0$(_attachment_mode "$destination")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ "$source_mode" = "$after_mode" ] || return "$TRELLIS_EX_CONFLICT"
  if ! jq -se 'length == 1 and (.[0] | type == "object")' "$destination" >/dev/null 2>&1; then
    release_err "explicit-json render target is invalid JSON: $relative"
    return "$TRELLIS_EX_CONFLICT"
  fi
  adoption_render_owned_parents_valid "$destination" "$keys" || return "$TRELLIS_EX_CONFLICT"
  path_identity="$(_attachment_fs_identity "$destination")" || return "$TRELLIS_EX_UNAVAILABLE"
  source_hash="$(_attachment_hash "$destination")" || return "$TRELLIS_EX_UNAVAILABLE"

  source="$work/$number.render.$index.source"
  candidate="$work/$number.render.$index.candidate"
  cat "$destination" > "$source" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod "${source_mode#0}" "$source" || return "$TRELLIS_EX_UNAVAILABLE"
  source_identity="$(_attachment_fs_identity "$source")" || return "$TRELLIS_EX_UNAVAILABLE"
  adoption_render_live_matches "$destination" "$source" "$path_identity" "$source_hash" "$source_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  drift="$(attach_detach_json_keys_detail "$source" "$keys")" || return "$TRELLIS_EX_CONFLICT"
  if [ "$migrate" = true ]; then
    # Migration removes only freshly proven old ownership; legacy add-only
    # repair below intentionally retains its historical compatibility behavior.
    [ "$(printf '%s\n' "$drift" | jq 'length')" -eq 0 ] || {
      release_err "native render migration refuses changed old owned positions: $relative"
      return "$TRELLIS_EX_CONFLICT"
    }
    template="$(jq -er --arg path "$relative" '
      [.harnesses[]?.render[]? | select(.destination == $path and .merge == "explicit-json") | .template]
      | unique | if length == 1 then .[0] else error("render template missing/ambiguous") end
    ' "$new_payload/core-rules/inheritance-manifest.json")" || return "$TRELLIS_EX_STATE"
    case "$template" in
      /*|../*|*/../*|*/..|./*|*/./*|*//*|*$'\n'*|*$'\r'*|*$'\t'*) return "$TRELLIS_EX_STATE" ;;
    esac
    _attachment_canonical_file "$new_payload/$template" || return "$TRELLIS_EX_STATE"
    template_file="$work/$number.render.$index.template"
    attachment_contextual_template_select "$new_payload/$template" "$template" "$context" "$root" > "$template_file" || return "$?"
    chmod 600 "$template_file" || return "$TRELLIS_EX_UNAVAILABLE"
    created="$(printf '%s\n' "$render" | jq -c '.created_paths')" || return "$TRELLIS_EX_STATE"
    merge_plan="$(settings_owned_json merge "$source" "$keys" "$template_file" '' "$created")" || return "$TRELLIS_EX_CONFLICT"
    printf '%s\n' "$merge_plan" | jq -S '.after' > "$candidate" || return "$TRELLIS_EX_STATE"
    new_keys="$(printf '%s\n' "$merge_plan" | jq -c '.owned_keys')" || return "$TRELLIS_EX_STATE"
    created="$(printf '%s\n' "$merge_plan" | jq -c '.created_paths')" || return "$TRELLIS_EX_STATE"
    chmod "${after_mode#0}" "$candidate" || return "$TRELLIS_EX_UNAVAILABLE"
    candidate_identity="$(_attachment_fs_identity "$candidate")" || return "$TRELLIS_EX_UNAVAILABLE"
    candidate_hash="$(_attachment_hash "$candidate")" || return "$TRELLIS_EX_UNAVAILABLE"
    after64="$(base64 < "$candidate" | tr -d '\n')" || return "$TRELLIS_EX_UNAVAILABLE"
    if [ "$source_hash" != "$(printf '%s\n' "$render" | jq -r '.after_sha256')" ]; then
      # The new exact-after snapshot includes project edits made since attach.
      # Its corresponding before snapshot must include those edits too, or the
      # exact detach fast path would restore an older file and delete them.
      before_file="$work/$number.render.$index.before"
      inverse_file="$work/$number.render.$index.inverse"
      original_before_exists="$(printf '%s\n' "$render" | jq -r '.before_exists')" || return 4
      if [ "$original_before_exists" = true ]; then
        attach_decode_base64 "$(printf '%s\n' "$render" | jq -r '.before_base64')" > "$before_file" || return 4
        [ "$(_attachment_hash "$before_file")" = "$(printf '%s\n' "$render" | jq -r '.before_sha256')" ] || return 4
      else
        printf '{}\n' > "$before_file" || return 5
      fi
      settings_owned_json inverse "$source" "$keys" '' "$before_file" \
        "$(printf '%s\n' "$render" | jq -c '.created_paths')" > "$inverse_file" || return 3
      chmod 600 "$before_file" "$inverse_file" || return 5
      if [ "$original_before_exists" = false ] && jq -e 'type == "object" and length == 0' "$inverse_file" >/dev/null; then
        before_exists=false; before64=''; before_mode=null
        before_hash=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      else
        before_exists=true
        before64="$(base64 < "$inverse_file" | tr -d '\n')" || return 5
        before_hash="$(_attachment_hash "$inverse_file")" || return 5
        before_mode="$(printf '%s\n' "$render" | jq -r --arg mode "$source_mode" '.before_mode // $mode')" || return 4
      fi
      render="$(printf '%s\n' "$render" | jq -c --argjson exists "$before_exists" --arg bytes "$before64" \
        --arg hash "$before_hash" --argjson mode "$(if [ "$before_mode" = null ]; then printf null; else jq -cn --arg mode "$before_mode" '$mode'; fi)" \
        '.before_exists=$exists | .before_base64=$bytes | .before_sha256=$hash | .before_mode=$mode')" || return 4
    fi
    # Derive created paths from the preserved project before-image, not from
    # retired ownership. Reconstructing it with the selected template must be
    # byte-exactly the same candidate before any publication is permitted.
    before_file="$work/$number.render.$index.before"
    if [ "$(printf '%s\n' "$render" | jq -r '.before_exists')" = true ]; then
      attach_decode_base64 "$(printf '%s\n' "$render" | jq -r '.before_base64')" > "$before_file" || return 4
      [ "$(_attachment_hash "$before_file")" = "$(printf '%s\n' "$render" | jq -r '.before_sha256')" ] || return 4
    else
      printf '{}\n' > "$before_file" || return 5
    fi
    chmod 600 "$before_file" || return 5
    reconstruction="$(settings_owned_json reconstruct "$before_file" '[]' "$template_file")" || return 3
    reconstructed="$work/$number.render.$index.reconstructed"
    printf '%s\n' "$reconstruction" | jq -S '.after' > "$reconstructed" || return 4
    chmod 600 "$reconstructed" || return 5
    cmp -s "$candidate" "$reconstructed" || {
      release_err "native render before-image reconstruction disagrees at $relative; preserve settings and owner evidence, restore a coherent owned-prefix snapshot, and retry adoption"
      return "$TRELLIS_EX_STATE"
    }
    created="$(printf '%s\n' "$reconstruction" | jq -c '.created_paths')" || return 4
    # Use the existing changed/missing publication predicate, including retired
    # keys. No owner or private-journal schema field/type is introduced.
    drift="$(attach_detach_json_keys_detail "$source" "$new_keys")" || return "$TRELLIS_EX_CONFLICT"
    if [ "$candidate_hash" != "$source_hash" ] && [ "$(printf '%s\n' "$drift" | jq 'length')" -eq 0 ]; then
      drift="$(printf '%s\n' "$keys" | jq -c '[.[] | {path:.path,state:"changed"}]')" || return "$TRELLIS_EX_STATE"
      [ "$(printf '%s\n' "$drift" | jq 'length')" -gt 0 ] || drift='[{"path":["hooks"],"state":"changed"}]'
    fi
    render="$(printf '%s\n' "$render" | jq -c --argjson keys "$new_keys" --argjson created "$created" \
      --arg after64 "$after64" --arg hash "$candidate_hash" \
      '.owned_keys=$keys | .created_paths=$created | .after_base64=$after64 | .after_sha256=$hash')" || return "$TRELLIS_EX_STATE"
    trellis_jq -cn --argjson render "$render" --arg path "$relative" --arg destination "$destination" \
      --arg path_identity "$path_identity" --arg source "$source" --arg source_identity "$source_identity" \
      --arg source_sha256 "$source_hash" --arg source_mode "$source_mode" \
      --arg candidate "$candidate" --arg candidate_identity "$candidate_identity" \
      --arg candidate_sha256 "$candidate_hash" --arg candidate_mode "$after_mode" --argjson drift "$drift" \
      '{render:$render,path:$path,destination:$destination,path_identity:$path_identity,
        source:$source,source_identity:$source_identity,source_sha256:$source_sha256,source_mode:$source_mode,
        candidate:$candidate,candidate_identity:$candidate_identity,candidate_sha256:$candidate_sha256,
        candidate_mode:$candidate_mode,drift:$drift,template_dropped:[]}'
    return "$?"
  fi
  # Owned keys the new template no longer carries are replayed back into the
  # candidate below (add-only by design); record them so the adoption summary
  # can say they were left in place instead of reporting silent no-drift.
  # An owned path counts as present when it equals a template leaf or is a
  # strict prefix of one (the template nested a subtree beneath it).
  template_dropped='[]'
  if [ -n "$new_payload" ]; then
    template_leaves="$(adoption_new_template_leaves "$new_payload" "$relative")" || template_leaves='{"found":false,"leaves":[]}'
    if [ "$(printf '%s\n' "$template_leaves" | jq -r '.found // false' 2>/dev/null)" = true ]; then
      template_dropped="$(trellis_jq -cn --argjson keys "$keys" --argjson template "$template_leaves" '
        ($template.leaves | map(.path)) as $tpaths
        | [($keys | map(.path))[]
           | select(. as $owned
             | (([$tpaths[] | select(. == $owned or (.[0:($owned | length)] == $owned))] | length) == 0))]
      ' 2>/dev/null)" || template_dropped='[]'
    fi
  fi

  trellis_jq --argjson keys "$keys" '
    reduce $keys[] as $owned (. ; setpath($owned.path; $owned.value))
  ' "$source" > "$candidate" || return "$TRELLIS_EX_CONFLICT"
  chmod "${after_mode#0}" "$candidate" || return "$TRELLIS_EX_UNAVAILABLE"
  jq -e 'type == "object"' "$candidate" >/dev/null 2>&1 || return "$TRELLIS_EX_CONFLICT"
  attach_detach_json_keys_match "$candidate" "$keys" || return "$TRELLIS_EX_CONFLICT"
  candidate_identity="$(_attachment_fs_identity "$candidate")" || return "$TRELLIS_EX_UNAVAILABLE"
  candidate_hash="$(_attachment_hash "$candidate")" || return "$TRELLIS_EX_UNAVAILABLE"

  trellis_jq -cn --argjson render "$render" --arg path "$relative" --arg destination "$destination" \
    --arg path_identity "$path_identity" --arg source "$source" --arg source_identity "$source_identity" \
    --arg source_sha256 "$source_hash" --arg source_mode "$source_mode" \
    --arg candidate "$candidate" --arg candidate_identity "$candidate_identity" \
    --arg candidate_sha256 "$candidate_hash" --arg candidate_mode "$after_mode" --argjson drift "$drift" \
    --argjson template_dropped "$template_dropped" \
    '{render:$render,path:$path,destination:$destination,path_identity:$path_identity,
      source:$source,source_identity:$source_identity,source_sha256:$source_sha256,source_mode:$source_mode,
      candidate:$candidate,candidate_identity:$candidate_identity,candidate_sha256:$candidate_sha256,
      candidate_mode:$candidate_mode,drift:$drift,template_dropped:$template_dropped}'
}

adoption_render_plan_matches_source() {
  local root="$1" planned="$2" relative destination expected source source_identity source_hash source_mode
  local candidate candidate_identity candidate_hash candidate_mode keys
  relative="$(printf '%s\n' "$planned" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  _attachment_parent_safe "$root" "$relative" || return "$TRELLIS_EX_CONFLICT"
  destination="$(_attachment_destination "$root" "$relative")" || return "$TRELLIS_EX_STATE"
  expected="$(printf '%s\n' "$planned" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
  [ "$destination" = "$expected" ] || return "$TRELLIS_EX_CONFLICT"
  source="$(printf '%s\n' "$planned" | jq -r '.source')" || return "$TRELLIS_EX_STATE"
  source_identity="$(printf '%s\n' "$planned" | jq -r '.source_identity')" || return "$TRELLIS_EX_STATE"
  source_hash="$(printf '%s\n' "$planned" | jq -r '.source_sha256')" || return "$TRELLIS_EX_STATE"
  source_mode="$(printf '%s\n' "$planned" | jq -r '.source_mode')" || return "$TRELLIS_EX_STATE"
  candidate="$(printf '%s\n' "$planned" | jq -r '.candidate')" || return "$TRELLIS_EX_STATE"
  candidate_identity="$(printf '%s\n' "$planned" | jq -r '.candidate_identity')" || return "$TRELLIS_EX_STATE"
  candidate_hash="$(printf '%s\n' "$planned" | jq -r '.candidate_sha256')" || return "$TRELLIS_EX_STATE"
  candidate_mode="$(printf '%s\n' "$planned" | jq -r '.candidate_mode')" || return "$TRELLIS_EX_STATE"
  keys="$(printf '%s\n' "$planned" | jq -c '.render.owned_keys')" || return "$TRELLIS_EX_STATE"
  adoption_private_render_file_matches "$source" "$source_identity" "$source_hash" "$source_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  adoption_private_render_file_matches "$candidate" "$candidate_identity" "$candidate_hash" "$candidate_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  attach_detach_json_keys_match "$candidate" "$keys" || return "$TRELLIS_EX_CONFLICT"
  adoption_render_live_matches "$destination" "$source" \
    "$(printf '%s\n' "$planned" | jq -r '.path_identity')" "$source_hash" "$source_mode" ||
    return "$TRELLIS_EX_CONFLICT"
}

adoption_publish_render() (
  local planned="$1" direction="$2" destination expected expected_identity expected_file_identity expected_hash expected_mode
  local replacement replacement_file_identity replacement_hash replacement_mode parent base actual_parent temporary='' destination_identity=''
  local rc
  # These names cannot be shadowed by adoption_render_live_matches or its
  # callees when a signal arrives mid-verification. They are subshell-scoped.
  __apr_temporary='' __apr_temporary_identity='' __apr_committed=false
  __apr_destination='' __apr_expected='' __apr_expected_identity='' __apr_expected_hash='' __apr_expected_mode=''
  __apr_replacement='' __apr_replacement_hash='' __apr_replacement_mode=''

  adoption_publish_render_cleanup() {
    local status="${1:-$?}" rollback=0 cleanup_status=0
    trap '' HUP INT TERM
    trap - EXIT

    if [ -n "$__apr_temporary" ]; then
      if [ "$__apr_committed" = true ]; then
        if adoption_render_live_matches "$__apr_temporary" "$__apr_expected" "$__apr_expected_identity" "$__apr_expected_hash" "$__apr_expected_mode"; then
          rm "${__apr_temporary:?}" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
          [ "$cleanup_status" -eq 0 ] && __apr_temporary=''
        else
          cleanup_status="$TRELLIS_EX_CONFLICT"
        fi
      elif adoption_render_live_matches "$__apr_destination" "$__apr_replacement" '' "$__apr_replacement_hash" "$__apr_replacement_mode" &&
        _attachment_identity_matches "$__apr_destination" "$__apr_temporary_identity" file; then
        release_store_rename_swap "$__apr_temporary" "$__apr_destination"
        rollback=$?
        if [ "$rollback" -eq 0 ]; then
          if _attachment_identity_matches "$__apr_temporary" "$__apr_temporary_identity" file &&
            adoption_render_live_matches "$__apr_temporary" "$__apr_replacement" '' "$__apr_replacement_hash" "$__apr_replacement_mode"; then
            rm "${__apr_temporary:?}" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
            [ "$cleanup_status" -eq 0 ] && __apr_temporary=''
          else
            cleanup_status="$TRELLIS_EX_CONFLICT"
          fi
        else
          cleanup_status="$(max_status "$cleanup_status" "$rollback")"
        fi
      elif _attachment_identity_matches "$__apr_temporary" "$__apr_temporary_identity" file &&
        adoption_render_live_matches "$__apr_temporary" "$__apr_replacement" '' "$__apr_replacement_hash" "$__apr_replacement_mode"; then
        rm "${__apr_temporary:?}" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
        [ "$cleanup_status" -eq 0 ] && __apr_temporary=''
      else
        cleanup_status="$TRELLIS_EX_CONFLICT"
      fi
    fi
    [ "$cleanup_status" -eq 0 ] || status="$(max_status "$status" "$cleanup_status")"
    exit "$status"
  }

  trap 'adoption_publish_render_cleanup "$?"' EXIT
  # The handler must see the staged identities before Bash 3.2 unwinds locals.
  trap 'adoption_publish_render_cleanup "$TRELLIS_EX_UNAVAILABLE"' HUP INT TERM

  case "$direction" in
    forward)
      expected="$(printf '%s\n' "$planned" | jq -r '.source')" || return "$TRELLIS_EX_STATE"
      expected_identity="$(printf '%s\n' "$planned" | jq -r '.path_identity')" || return "$TRELLIS_EX_STATE"
      expected_file_identity="$(printf '%s\n' "$planned" | jq -r '.source_identity')" || return "$TRELLIS_EX_STATE"
      expected_hash="$(printf '%s\n' "$planned" | jq -r '.source_sha256')" || return "$TRELLIS_EX_STATE"
      expected_mode="$(printf '%s\n' "$planned" | jq -r '.source_mode')" || return "$TRELLIS_EX_STATE"
      replacement="$(printf '%s\n' "$planned" | jq -r '.candidate')" || return "$TRELLIS_EX_STATE"
      replacement_file_identity="$(printf '%s\n' "$planned" | jq -r '.candidate_identity')" || return "$TRELLIS_EX_STATE"
      replacement_hash="$(printf '%s\n' "$planned" | jq -r '.candidate_sha256')" || return "$TRELLIS_EX_STATE"
      replacement_mode="$(printf '%s\n' "$planned" | jq -r '.candidate_mode')" || return "$TRELLIS_EX_STATE"
      ;;
    rollback)
      expected="$(printf '%s\n' "$planned" | jq -r '.candidate')" || return "$TRELLIS_EX_STATE"
      expected_identity=''
      expected_file_identity="$(printf '%s\n' "$planned" | jq -r '.candidate_identity')" || return "$TRELLIS_EX_STATE"
      expected_hash="$(printf '%s\n' "$planned" | jq -r '.candidate_sha256')" || return "$TRELLIS_EX_STATE"
      expected_mode="$(printf '%s\n' "$planned" | jq -r '.candidate_mode')" || return "$TRELLIS_EX_STATE"
      replacement="$(printf '%s\n' "$planned" | jq -r '.source')" || return "$TRELLIS_EX_STATE"
      replacement_file_identity="$(printf '%s\n' "$planned" | jq -r '.source_identity')" || return "$TRELLIS_EX_STATE"
      replacement_hash="$(printf '%s\n' "$planned" | jq -r '.source_sha256')" || return "$TRELLIS_EX_STATE"
      replacement_mode="$(printf '%s\n' "$planned" | jq -r '.source_mode')" || return "$TRELLIS_EX_STATE"
      ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
  destination="$(printf '%s\n' "$planned" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
  adoption_private_render_file_matches "$expected" "$expected_file_identity" "$expected_hash" "$expected_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  adoption_private_render_file_matches "$replacement" "$replacement_file_identity" "$replacement_hash" "$replacement_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  parent="$(dirname "$destination")" || return "$TRELLIS_EX_STATE"
  base="$(basename "$destination")" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$parent" || return "$TRELLIS_EX_CONFLICT"
  CDPATH='' cd "$parent" || return "$TRELLIS_EX_CONFLICT"
  actual_parent="$(pwd -P)" || return "$TRELLIS_EX_CONFLICT"
  [ "$actual_parent" = "$parent" ] || return "$TRELLIS_EX_CONFLICT"
  destination="./$base"
  destination_identity="$(_attachment_fs_identity "$destination")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -n "$expected_identity" ] || expected_identity="$destination_identity"
  adoption_render_live_matches "$destination" "$expected" "$expected_identity" "$expected_hash" "$expected_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  __apr_destination="$destination" __apr_expected="$expected" __apr_expected_identity="$expected_identity"
  __apr_expected_hash="$expected_hash" __apr_expected_mode="$expected_mode"
  __apr_replacement="$replacement" __apr_replacement_hash="$replacement_hash" __apr_replacement_mode="$replacement_mode"
  __apr_temporary="$(mktemp "./.${base}.release-adopt-render.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  temporary="$__apr_temporary"
  [ -f "$temporary" ] && [ ! -L "$temporary" ] || return "$TRELLIS_EX_CONFLICT"
  cat "$replacement" > "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod "${replacement_mode#0}" "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  adoption_render_live_matches "$temporary" "$replacement" '' "$replacement_hash" "$replacement_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  __apr_temporary_identity="$(_attachment_fs_identity "$temporary")" || return "$TRELLIS_EX_UNAVAILABLE"
  adoption_render_live_matches "$destination" "$expected" "$expected_identity" "$expected_hash" "$expected_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  release_store_rename_swap "$temporary" "$destination"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! adoption_render_live_matches "$temporary" "$expected" "$expected_identity" "$expected_hash" "$expected_mode" ||
    ! { _attachment_identity_matches "$destination" "$__apr_temporary_identity" file &&
    adoption_render_live_matches "$destination" "$replacement" '' "$replacement_hash" "$replacement_mode"; }; then
    return "$TRELLIS_EX_CONFLICT"
  fi
  __apr_committed=true
  return 0
)

preflight_target() {
  # trellis-release-capability: native-render-migration
  local home="$1" new_version="$2" new_payload="$3" row="$4" work="$5" number="$6"
  local target binding identity root root_identity trellis_identity checkout owner old_version old_payload old_owner new_owner hooks managed source reconcile carrier hook_authority
  local renders='[]' render render_plan index=0 retired pruned='[]' migrate=false context='null'
  local pi_hooks_required pi_hooks_owned checkout_root fleet recovery_roots recovery_root recovery_harnesses

  target="$(resolve_verified_adoption_target "$home" "$row")" || return "$?"
  binding="$(printf '%s\n' "$target" | jq -cS '.binding')" || return "$TRELLIS_EX_STATE"
  identity="$(printf '%s\n' "$target" | jq -cS '.identity')" || return "$TRELLIS_EX_STATE"
  checkout="$(printf '%s\n' "$binding" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$binding" | jq -r '.root')" || return "$TRELLIS_EX_STATE"
  owner="$(printf '%s\n' "$target" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
  old_version="$(printf '%s\n' "$target" | jq -r '.old_version')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$target" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  root_identity="$(printf '%s\n' "$target" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  trellis_identity="$(printf '%s\n' "$target" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  hook_authority="$(printf '%s\n' "$target" | jq -r '.hook_authority')" || return "$TRELLIS_EX_STATE"

  # Adoption does not add newly declared leaves. Refuse only a legacy Pi
  # target whose entire owned hook-symlink inventory is absent.
  pi_hooks_required="$(jq -r '
    any(.harnesses.pi.links[]?;
      (.destination // .destination_dir // "")
      | . == ".pi/hooks" or startswith(".pi/hooks/"))
  ' "$new_payload/core-rules/inheritance-manifest.json")" || return "$TRELLIS_EX_STATE"
  if printf '%s\n' "$binding" | jq -e '.harnesses | index("pi")' >/dev/null &&
    [ "$pi_hooks_required" = true ]; then
    pi_hooks_owned="$(jq -r '
      any(.artifacts[];
        .kind == "symlink"
        and (.path | . == ".pi/hooks" or startswith(".pi/hooks/")))
    ' "$owner")" || return "$TRELLIS_EX_STATE"
    if [ "$pi_hooks_owned" = false ]; then
      checkout_root="$(printf '%s\n' "$binding" | jq -r '.checkout_root')" || return "$TRELLIS_EX_STATE"
      fleet="$(printf '%s\n' "$binding" | jq -r '.fleet')" || return "$TRELLIS_EX_STATE"
      recovery_harnesses="$(printf '%s\n' "$binding" | jq -r '.harnesses | map("--harness " + .) | join(" ")')" || return "$TRELLIS_EX_STATE"
      recovery_roots="$(jq -r '.worktree_root' "${owner%/*}"/*.json)" || return "$TRELLIS_EX_STATE"
      release_err "cannot adopt $new_version for checkout $checkout_root: target release requires .pi/hooks links but attachment at $root owns none; detach the whole checkout and reattach every worktree at the target release:"
      printf '  trellis detach --home %q --all-worktrees %q\n' "$home" "$checkout_root" >&2
      while IFS= read -r recovery_root; do
        printf '  trellis attach --home %q --fleet %q --release %q %s %q\n' \
          "$home" "$fleet" "$new_version" "$recovery_harnesses" "$recovery_root" >&2
      done <<< "$recovery_roots"
      return "$TRELLIS_EX_CONFLICT"
    fi
  fi

  old_owner="$work/$number.old.json"
  new_owner="$work/$number.new.json"
  cp "$owner" "$old_owner" && chmod 600 "$old_owner" || return "$TRELLIS_EX_UNAVAILABLE"
  retired="$(adoption_retired_leaves "$old_owner" "$new_payload" "$(printf '%s\n' "$binding" | jq -c '.harnesses')")" || return "$?"
  if printf '%s\n' "$binding" | jq -e '.harnesses | index("pi")' >/dev/null &&
    [ "$pi_hooks_required" = false ]; then
    pruned="$(adoption_pi_hooks_prune_plan "$root" "$retired" "$old_owner")" || return "$?"
  fi
  if [ -f "$old_payload/core-rules/native/artifacts.json" ] || [ -f "$new_payload/core-rules/native/artifacts.json" ]; then
    migrate=true
    if [ "$(jq '(.renders // []) | length' "$old_owner")" -gt 0 ]; then
      context="$(attachment_contextual_render_context "$home")" || return "$?"
    fi
  fi
  while IFS= read -r render; do
    index=$((index + 1))
    render_plan="$(adoption_snapshot_render "$root" "$render" "$work" "$number" "$index" "$new_payload" "$migrate" "$context")" || return "$?"
    renders="$(trellis_jq -cn --argjson current "$renders" --argjson planned "$render_plan" '$current + [$planned]')" ||
      return "$TRELLIS_EX_STATE"
  done < <(jq -c '(.renders // [])[]' "$old_owner")
  if [ "$migrate" = true ]; then
    owner_replacement "$old_owner" "$new_owner" "$new_version" "$new_payload" "$retired" "$pruned" "$renders" "$context" || return "$?"
  else
    owner_replacement "$old_owner" "$new_owner" "$new_version" "$new_payload" "$retired" "$pruned" || return "$?"
  fi

  hooks="$(jq -r '.git_hooks.enabled // false' "$owner")" || return "$TRELLIS_EX_STATE"
  managed=""
  case "$hooks" in
    true)
      managed="$(jq -r '.git_hooks.managed_hooks_path // empty' "$owner")" || return "$TRELLIS_EX_STATE"
      [ "$managed" = "$home/state/git-hooks/$checkout" ] || return "$TRELLIS_EX_CONFLICT"
      hook_payload_matches "$managed" "$old_payload" "$root" || return "$?"
      source="$(_attachment_hooks_read_sidecar "$managed/pre-push-source")" || return "$TRELLIS_EX_CONFLICT"
      reconcile="$new_payload/scripts/seed-inheritance-symlinks.sh"
      carrier="$new_payload/$source"
      _attachment_canonical_file "$reconcile" && [ -x "$reconcile" ] || return "$TRELLIS_EX_STATE"
      _attachment_canonical_file "$carrier" && [ -x "$carrier" ] || return "$TRELLIS_EX_STATE"
      ;;
    false) ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac

  trellis_jq -cn \
    --argjson row "$row" --argjson binding "$binding" --argjson identity "$identity" \
    --arg owner "$owner" --arg old_owner "$old_owner" --arg new_owner "$new_owner" \
    --arg old_version "$old_version" --arg old_payload "$old_payload" \
    --arg new_version "$new_version" --arg new_payload "$new_payload" \
    --arg root_identity "$root_identity" --arg trellis_identity "$trellis_identity" \
    --arg hooks "$hooks" --arg managed "$managed" --arg hook_authority "$hook_authority" \
    --argjson renders "$renders" --argjson retired "$retired" --argjson pruned "$pruned" \
    '{row:$row,binding:$binding,identity:$identity,owner:$owner,old_owner:$old_owner,new_owner:$new_owner,
      old_version:$old_version,old_payload:$old_payload,new_version:$new_version,new_payload:$new_payload,
      root_identity:$root_identity,trellis_identity:$trellis_identity,hooks:$hooks,managed:$managed,
      hook_authority:$hook_authority,renders:$renders,retired:$retired,pruned:$pruned}'
}

plan_matches_old() {
  local home="$1" plan="$2" row binding planned_identity planned_root_identity planned_trellis_identity planned_hook_authority target current_binding current_identity current_root_identity current_trellis_identity current_hook_authority owner old_owner old_payload old_version new_version new_payload verified_new_payload root planned_render status
  row="$(printf '%s\n' "$plan" | jq -c '.row')" || return "$TRELLIS_EX_STATE"
  binding="$(printf '%s\n' "$plan" | jq -cS '.binding')" || return "$TRELLIS_EX_STATE"
  planned_identity="$(printf '%s\n' "$plan" | jq -cS '.identity')" || return "$TRELLIS_EX_STATE"
  planned_root_identity="$(printf '%s\n' "$plan" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  planned_trellis_identity="$(printf '%s\n' "$plan" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  planned_hook_authority="$(printf '%s\n' "$plan" | jq -r '.hook_authority')" || return "$TRELLIS_EX_STATE"
  target="$(resolve_verified_adoption_target "$home" "$row")" || return "$?"
  current_binding="$(printf '%s\n' "$target" | jq -cS '.binding')" || return "$TRELLIS_EX_STATE"
  current_identity="$(printf '%s\n' "$target" | jq -cS '.identity')" || return "$TRELLIS_EX_STATE"
  current_root_identity="$(printf '%s\n' "$target" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  current_trellis_identity="$(printf '%s\n' "$target" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  current_hook_authority="$(printf '%s\n' "$target" | jq -r '.hook_authority')" || return "$TRELLIS_EX_STATE"
  if [ "$current_binding" != "$binding" ] ||
    [ "$current_identity" != "$planned_identity" ] ||
    [ "$current_root_identity" != "$planned_root_identity" ] ||
    [ "$current_trellis_identity" != "$planned_trellis_identity" ]; then
    release_err 'release adoption target drifted after plan validation'
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ "$current_hook_authority" != "$planned_hook_authority" ]; then
    release_err 'release adoption hook authority drifted after plan validation'
    return "$TRELLIS_EX_CONFLICT"
  fi
  owner="$(printf '%s\n' "$plan" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
  if [ "$owner" != "$(printf '%s\n' "$target" | jq -r '.owner')" ]; then
    release_err 'release adoption attachment owner path drifted after plan validation'
    return "$TRELLIS_EX_CONFLICT"
  fi
  old_owner="$(printf '%s\n' "$plan" | jq -r '.old_owner')" || return "$TRELLIS_EX_STATE"
  old_version="$(printf '%s\n' "$plan" | jq -r '.old_version')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  [ "$old_version" = "$(printf '%s\n' "$target" | jq -r '.old_version')" ] ||
    return "$TRELLIS_EX_CONFLICT"
  [ "$old_payload" = "$(printf '%s\n' "$target" | jq -r '.old_payload')" ] ||
    return "$TRELLIS_EX_CONFLICT"
  new_version="$(printf '%s\n' "$plan" | jq -r '.new_version')" || return "$TRELLIS_EX_STATE"
  new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"
  verified_new_payload="$(payload_for "$new_version")" || return "$?"
  [ "$verified_new_payload" = "$new_payload" ] || return "$TRELLIS_EX_CONFLICT"
  if ! cmp -s "$old_owner" "$owner"; then
    release_err 'release adoption attachment owner changed after plan validation'
    return "$TRELLIS_EX_CONFLICT"
  fi
  root="$(printf '%s\n' "$plan" | jq -r '.row.root')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r planned_render; do
    adoption_render_plan_matches_source "$root" "$planned_render"
    status=$?
    if [ "$status" -ne 0 ]; then
      release_err 'release adoption render source changed after plan validation'
      return "$status"
    fi
  done < <(printf '%s\n' "$plan" | jq -c '.renders[]')
}

apply_plan() {
  local plan="$1" root root_identity trellis_identity owner old_owner new_owner new_version old_payload new_payload verified_new_payload
  local planned_render drift_count leaf
  root="$(printf '%s\n' "$plan" | jq -r '.row.root')" || return "$TRELLIS_EX_STATE"
  root_identity="$(printf '%s\n' "$plan" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  trellis_identity="$(printf '%s\n' "$plan" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  owner="$(printf '%s\n' "$plan" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
  old_owner="$(printf '%s\n' "$plan" | jq -r '.old_owner')" || return "$TRELLIS_EX_STATE"
  new_owner="$(printf '%s\n' "$plan" | jq -r '.new_owner')" || return "$TRELLIS_EX_STATE"
  new_version="$(printf '%s\n' "$plan" | jq -r '.new_version')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"
  verified_new_payload="$(payload_for "$new_version")" || return "$?"
  [ "$verified_new_payload" = "$new_payload" ] || return "$TRELLIS_EX_CONFLICT"

  while IFS= read -r planned_render; do
    drift_count="$(printf '%s\n' "$planned_render" | jq '.drift | length')" || return "$TRELLIS_EX_STATE"
    [ "$drift_count" -gt 0 ] || continue
    adoption_publish_render "$planned_render" forward || return "$?"
  done < <(printf '%s\n' "$plan" | jq -c '.renders[]')

  runtime_anchor_matches_payload "$root/.trellis/runtime" "$old_payload" || return "$?"
  release_store_adopt_runtime_anchor_pinned \
    "$new_version" "$root" "$root_identity" "$trellis_identity" "$old_payload" >/dev/null || return "$?"
  replace_owned_file "$owner" "$old_owner" "$new_owner" || return "$?"
  while IFS= read -r leaf; do
    adoption_retire_leaf "$root" "$leaf" forward || return "$?"
  done < <(printf '%s\n' "$plan" | jq -c '(.retired // [])[]')
  while IFS= read -r leaf; do
    adoption_prune_dir "$root" "$leaf" forward || return "$?"
  done < <(printf '%s\n' "$plan" | jq -c '(.pruned // [])[]')
}

rollback_plan() {
  local plan="$1" root root_identity trellis_identity owner old_owner new_owner old_version old_payload new_payload
  local planned_render destination source source_hash source_mode candidate candidate_hash candidate_mode leaf
  local rc=0 one index
  local -a render_lines=()
  root="$(printf '%s\n' "$plan" | jq -r '.row.root')" || return "$TRELLIS_EX_STATE"
  root_identity="$(printf '%s\n' "$plan" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  trellis_identity="$(printf '%s\n' "$plan" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  owner="$(printf '%s\n' "$plan" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
  old_owner="$(printf '%s\n' "$plan" | jq -r '.old_owner')" || return "$TRELLIS_EX_STATE"
  new_owner="$(printf '%s\n' "$plan" | jq -r '.new_owner')" || return "$TRELLIS_EX_STATE"
  old_version="$(printf '%s\n' "$plan" | jq -r '.old_version')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"

  if cmp -s "$old_owner" "$owner"; then
    :
  elif cmp -s "$new_owner" "$owner"; then
    replace_owned_file "$owner" "$new_owner" "$old_owner"
    one=$?
    [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
  else
    rc="$(max_status "$rc" "$TRELLIS_EX_CONFLICT")"
  fi

  if runtime_anchor_matches_payload "$root/.trellis/runtime" "$old_payload"; then
    :
  elif runtime_anchor_matches_payload "$root/.trellis/runtime" "$new_payload"; then
    release_store_adopt_runtime_anchor_pinned \
      "$old_version" "$root" "$root_identity" "$trellis_identity" "$new_payload" >/dev/null
    one=$?
    [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
  else
    rc="$(max_status "$rc" "$TRELLIS_EX_CONFLICT")"
  fi

  while IFS= read -r leaf; do
    adoption_prune_dir "$root" "$leaf" rollback
    one=$?
    [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
  done < <(printf '%s\n' "$plan" | jq -c '(.pruned // []) | reverse[]')
  while IFS= read -r leaf; do
    adoption_retire_leaf "$root" "$leaf" rollback
    one=$?
    [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
  done < <(printf '%s\n' "$plan" | jq -c '(.retired // [])[]')

  while IFS= read -r planned_render; do
    [ -n "$planned_render" ] && render_lines+=("$planned_render")
  done < <(printf '%s\n' "$plan" | jq -c '.renders[] | select((.drift | length) > 0)')
  for ((index=${#render_lines[@]} - 1; index >= 0; index--)); do
    planned_render="${render_lines[$index]}"
    destination="$(printf '%s\n' "$planned_render" | jq -r '.destination')" || {
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
      continue
    }
    source="$(printf '%s\n' "$planned_render" | jq -r '.source')" || {
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
      continue
    }
    source_hash="$(printf '%s\n' "$planned_render" | jq -r '.source_sha256')" || {
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
      continue
    }
    source_mode="$(printf '%s\n' "$planned_render" | jq -r '.source_mode')" || {
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
      continue
    }
    candidate="$(printf '%s\n' "$planned_render" | jq -r '.candidate')" || {
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
      continue
    }
    candidate_hash="$(printf '%s\n' "$planned_render" | jq -r '.candidate_sha256')" || {
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
      continue
    }
    candidate_mode="$(printf '%s\n' "$planned_render" | jq -r '.candidate_mode')" || {
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
      continue
    }
    if adoption_render_live_matches "$destination" "$source" '' "$source_hash" "$source_mode"; then
      :
    elif adoption_render_live_matches "$destination" "$candidate" '' "$candidate_hash" "$candidate_mode"; then
      adoption_publish_render "$planned_render" rollback
      one=$?
      [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
    else
      rc="$(max_status "$rc" "$TRELLIS_EX_CONFLICT")"
    fi
  done

  if [ "$rc" -eq 0 ]; then
    cmp -s "$old_owner" "$owner" || rc="$TRELLIS_EX_CONFLICT"
    runtime_anchor_matches_payload "$root/.trellis/runtime" "$old_payload" || rc="$(max_status "$rc" "$TRELLIS_EX_CONFLICT")"
  fi
  return "$rc"
}

rollback_plans() {
  local changed="$1" plan rc=0 one index
  local -a plan_lines=()
  while IFS= read -r plan; do [ -n "$plan" ] && plan_lines+=("$plan"); done < "$changed"
  for ((index=${#plan_lines[@]} - 1; index >= 0; index--)); do
    rollback_plan "${plan_lines[$index]}"
    one=$?
    [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
  done
  return "$rc"
}

apply_group_hooks() {
  local plans="$1" changed="$2" plan hooks managed old_payload new_payload root seen='|'
  : > "$changed" || return "$TRELLIS_EX_UNAVAILABLE"
  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    hooks="$(printf '%s\n' "$plan" | jq -r '.hooks')" || return "$TRELLIS_EX_STATE"
    [ "$hooks" = true ] || continue
    managed="$(printf '%s\n' "$plan" | jq -r '.managed')" || return "$TRELLIS_EX_STATE"
    case "$seen" in *"|$managed|"*) continue ;; esac
    seen="${seen}${managed}|"
    old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
    new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"
    root="$(printf '%s\n' "$plan" | jq -r '.binding.root')" || return "$TRELLIS_EX_STATE"
    active_hook_plan="$plan"
    replace_hook_payload "$managed" "$old_payload" "$new_payload" "$root" || return "$?"
    printf '%s\n' "$plan" >> "$changed" || return "$TRELLIS_EX_UNAVAILABLE"
    active_hook_plan=''
  done < "$plans"
}

rollback_hook_plan() {
  local plan="$1" managed old_payload new_payload root
  managed="$(printf '%s\n' "$plan" | jq -r '.managed')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$plan" | jq -r '.binding.root')" || return "$TRELLIS_EX_STATE"
  if hook_payload_matches "$managed" "$old_payload" "$root"; then
    return 0
  fi
  hook_payload_matches "$managed" "$new_payload" "$root" || return "$TRELLIS_EX_CONFLICT"
  replace_hook_payload "$managed" "$new_payload" "$old_payload" "$root"
}

rollback_group_hooks() {
  local changed="$1" plan managed old_payload new_payload rc=0 one index
  local -a plan_lines=()
  while IFS= read -r plan; do [ -n "$plan" ] && plan_lines+=("$plan"); done < "$changed"
  for ((index=${#plan_lines[@]} - 1; index >= 0; index--)); do
    plan="${plan_lines[$index]}"
    rollback_hook_plan "$plan"
    one=$?
    [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
  done
  return "$rc"
}

# The commit step of a per-row-continuation adoption. The strict whole-file
# reader and writer would abort on the first broken row ANYWHERE in the
# registry — but by this point the group's runtime anchors have already moved,
# so a broken sibling stopped being a pre-abort and became an abort-and-roll-back
# of healthy targets. Read diagnostically and write with bound-row identity
# validation instead: whole-file SCHEMA/structural validation is unchanged, and
# the rows this commit writes — the adoption targets' checkout and worktree rows
# — are validated with exactly the strictness the whole-file validator applied,
# both after the locked read and again over the proposal bytes. A target whose
# own row is broken still fails class 4 and is never adopted onto.
update_group_registry() (
  local home="$1" plans="$2" version="$3" base proposal bindings pairs state checkout worktree rc=0
  trellis_home_prepare_home "$home" || return "$?"
  trellis_home_lock_acquire "$home" registry 30 || return "$?"
  trap 'trellis_home_lock_release >/dev/null 2>&1 || true' EXIT INT TERM
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.release.registry.base.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.release.registry.proposal.XXXXXX")" || { rm -f "$base"; return "$TRELLIS_EX_UNAVAILABLE"; }
  bindings="$(jq -sc '[.[] | {checkout_id: .binding.checkout_id, worktree_id: .binding.worktree_id}] | unique' "$plans")" ||
    { rm -f "$base" "$proposal"; return "$TRELLIS_EX_STATE"; }
  pairs="$(printf '%s\n' "$bindings" | jq -r '.[] | .checkout_id + " " + (.worktree_id // "")')" ||
    { rm -f "$base" "$proposal"; return "$TRELLIS_EX_STATE"; }
  local_registry_read_diagnostic_state "$home" > "$base" || rc=$?
  if [ "$rc" -eq 0 ]; then
    state="$(jq -c . "$base")" || rc="$TRELLIS_EX_STATE"
  fi
  if [ "$rc" -eq 0 ]; then
    # Under-lock identity revalidation of exactly the rows about to be mutated.
    while read -r checkout worktree; do
      [ -n "$checkout" ] || continue
      local_registry_validate_bound_row_identity "$state" "$checkout" "$worktree" || { rc=$?; break; }
    done <<EOF
$pairs
EOF
  fi
  if [ "$rc" -eq 0 ]; then
    jq --arg version "$version" --slurpfile plans "$plans" '
      . as $state
      | def matches($plan):
          ($plan.row.project_key) as $key
          | $plan.binding as $binding
          | ($state.projects[$key] // null) as $project
          | ($project.checkouts[$binding.checkout_id] // null) as $checkout
          | ($checkout.worktrees[$binding.worktree_id] // null) as $worktree
          | if $project == null or $checkout == null or $worktree == null then false
            else [
              ($key == ($binding.fleet + "/" + $binding.project_id)),
              ($project.fleet == $binding.fleet),
              ($project.project_id == $binding.project_id),
              ($project.status == "active"),
              ($checkout.root == $binding.checkout_root),
              ($checkout.git_common_dir == $binding.git_common_dir),
              ($checkout.release == $binding.release),
              (($checkout.harnesses | unique | sort) == $binding.harnesses),
              ($worktree.root == $binding.root),
              (($worktree.attachment_id // "") == $binding.attachment_id),
              ($plan.new_version == $version)
            ] | all
            end;
        if all($plans[]; matches(.)) then
          reduce ($plans | map({key:.row.project_key, checkout:.binding.checkout_id}) | unique[]) as $target
            (. ; .projects[$target.key].checkouts[$target.checkout].release = $version)
        else error("registry changed during release adoption") end
    ' "$base" > "$proposal" || rc="$TRELLIS_EX_CONFLICT"
  fi
  if [ "$rc" -eq 0 ]; then
    local_registry_write_locked_bound_rows "$home" "$proposal" "$bindings" || rc=$?
  fi
  rm -f "$base" "$proposal"
  return "$rc"
)

# Checkout-group uniformity gate for adoption. Every plan in the group must
# share one old_version and (for hook-managed rows) one managed hooks path.
# Silent when the group is uniform; on failure each row is named with its
# target label, old_version and managed value plus a hint, before returning
# EX_CONFLICT. Purely diagnostic: exit classes are unchanged.
adopt_group_require_uniform() {
  local plans="$1" plan row label old_version managed hint_fleet hint_project
  if jq -se '([.[].old_version] | unique | length) == 1 and ([.[] | select(.hooks == "true") | .managed] | unique | length) <= 1' "$plans" >/dev/null 2>&1; then
    return 0
  fi
  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    row="$(printf '%s\n' "$plan" | jq -c '.row')" || row=''
    if [ -n "$row" ]; then label="$(target_label "$row" 2>/dev/null)" || label='(unreadable row)'; else label='(unreadable row)'; fi
    old_version="$(printf '%s\n' "$plan" | jq -r '.old_version // "(unknown version)"')" || old_version='(unreadable plan)'
    managed="$(printf '%s\n' "$plan" | jq -r '.managed // empty')" || managed=''
    [ -n "$managed" ] || managed='(unmanaged)'
    release_err "non-uniform adoption row: $label old_version=$old_version managed=$managed"
  done < "$plans"
  hint_fleet="$(jq -r -s '.[0].row.fleet // empty' "$plans" 2>/dev/null)" || hint_fleet=''
  hint_project="$(jq -r -s '.[0].row.project_id // empty' "$plans" 2>/dev/null)" || hint_project=''
  if [ -n "$hint_fleet" ] && [ -n "$hint_project" ]; then
    release_err "hint: adopt the whole checkout group together, or detach every worktree (trellis detach --all-worktrees <root>), or deregister dead rows and retry: trellis registry deregister --fleet $hint_fleet --project $hint_project"
  else
    release_err "hint: adopt the whole checkout group together, or detach every worktree (trellis detach --all-worktrees <root>), or deregister dead rows (trellis registry deregister --fleet FLEET --project ID) and retry"
  fi
  return "$TRELLIS_EX_CONFLICT"
}

# Plan one common-file CAS and update every replacement owner, not just the
# manager. The snapshots keep original pre-attach restoration bytes untouched.
adoption_exclude_plan() {
  local home="$1" plans="$2" payload="$3" work="$4" common="$5" checkout="$6"
  local plan owner surfaces first='' selection block="$work/exclude.block" path="$common/info/exclude" mode
  command -v attach_owner_surface_plan >/dev/null 2>&1 || {
    release_err 'group exclude planner unavailable; use the verified 1.3.10 CLI to adopt'
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  while IFS= read -r plan; do
    owner="$(printf '%s\n' "$plan" | jq -r '.old_owner')" || return "$TRELLIS_EX_STATE"
    selection="$(printf '%s\n' "$plan" | jq -c '.binding.harnesses')" || return "$TRELLIS_EX_STATE"
    surfaces="$(attach_owner_surface_plan "$owner" "$payload" "$selection")" || return "$?"
    attach_exclude_effective_preflight "$(jq -r '.worktree_root' "$owner")" "$surfaces" || return "$?"
    attach_exclude_block "$surfaces" > "$work/exclude.next" || return "$?"
    if [ -n "$first" ] && ! cmp -s "$block" "$work/exclude.next"; then
      release_err 'divergent group exclude deferrals; align project-authored leaves or whole-group detach/fresh attach'
      return "$TRELLIS_EX_CONFLICT"
    fi
    cp "$work/exclude.next" "$block" || return "$TRELLIS_EX_UNAVAILABLE"
    first=true
  done < "$plans"
  # Exact recorded/live block and complete owner coverage are checked before
  # deriving replacements; a manifest/version equality never skips this step.
  owner="$(jq -rs '.[0].old_owner' "$plans")" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_file "$path" || return "$TRELLIS_EX_CONFLICT"
  cp "$path" "$work/exclude.source" || return "$TRELLIS_EX_UNAVAILABLE"
  attach_decode_base64 "$(jq -r '.exclude.managed_block_base64' "$owner")" > "$work/exclude.old-block" || return "$?"
  attach_shared_exclude_state "$home" "$checkout" "$common" "$work/exclude.old-block" \
    "$work/exclude.source" "$work/exclude.candidate" adoption >/dev/null || return "$?"
  mode="0$(_attachment_mode "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
  python3 -I - "$plans" "$home/state/attachments/$checkout" "$work" <<'PY'
import base64, hashlib, json, pathlib, sys
plans_path, owners_dir, work = map(pathlib.Path, sys.argv[1:])
plans = [json.loads(line) for line in plans_path.read_text().splitlines()]
expected = {p['owner'] for p in plans}
if expected != {str(p) for p in owners_dir.glob('*.json')}:
    sys.exit('trellis release: every committed group owner must participate; restore unavailable siblings first')
old = (work / 'exclude.old-block').read_bytes()
new = (work / 'exclude.block').read_bytes()
live = (work / 'exclude.source').read_bytes()
if sum(json.loads(pathlib.Path(p['old_owner']).read_text())['exclude']['managed_by_attachment'] for p in plans) != 1:
    sys.exit('trellis release: shared exclude requires exactly one manager')
# The strict parser above establishes the unique exact old block boundaries.
candidate = live.replace(old, new, 1)
(work / 'exclude.candidate').write_bytes(candidate)
sha = lambda b: hashlib.sha256(b).hexdigest()
b64 = lambda b: base64.b64encode(b).decode()
for p in plans:
    path = pathlib.Path(p['new_owner'])
    owner = json.loads(path.read_text())
    # Ownership derives from the preserved restoration snapshot, not live drift.
    after = base64.b64decode(owner['exclude']['before_base64'], validate=True)
    if owner['exclude']['managed_by_attachment']:
        if after and not after.endswith(b'\n'):
            after += b'\n'
        after += new
    owner['exclude'].update(managed_block_base64=b64(new), managed_block_sha256=sha(new),
                           after_base64=b64(after), after_sha256=sha(after), after_exists=True)
    owner['exclude_block_hash'] = sha(new)
    path.write_text(json.dumps(owner, sort_keys=True) + '\n')
PY
  [ "$?" -eq 0 ] || return "$TRELLIS_EX_CONFLICT"
  chmod "${mode#0}" "$work/exclude.source" "$work/exclude.candidate" || return "$TRELLIS_EX_UNAVAILABLE"
  jq -cn --arg destination "$path" --arg path_identity "$(_attachment_fs_identity "$path")" \
    --arg source "$work/exclude.source" --arg candidate "$work/exclude.candidate" \
    --arg source_identity "$(_attachment_fs_identity "$work/exclude.source")" \
    --arg candidate_identity "$(_attachment_fs_identity "$work/exclude.candidate")" \
    --arg source_sha256 "$(_attachment_hash "$work/exclude.source")" \
    --arg candidate_sha256 "$(_attachment_hash "$work/exclude.candidate")" \
    --arg source_mode "$mode" --arg candidate_mode "$mode" '$ARGS.named' > "$work/exclude.json"
}

# The strict health check derives the expected block from the owner's release,
# so a singleton whose block the new release changes must re-plan it. An
# unchanged block keeps its exact attach-time record, and without the planner
# a singleton adopts as before. Status 0 means stale, 1 unchanged.
adoption_singleton_exclude_stale() {
  local owner="$1" payload="$2" selection="$3" work="$4" surfaces recorded
  command -v attach_owner_surface_plan >/dev/null 2>&1 || return 1
  surfaces="$(attach_owner_surface_plan "$owner" "$payload" "$selection")" || return "$?"
  attach_exclude_block "$surfaces" > "$work/exclude.singleton" || return "$?"
  recorded="$(jq -r '.exclude.managed_block_sha256' "$owner")" || return "$TRELLIS_EX_STATE"
  [ "$(_attachment_hash "$work/exclude.singleton")" != "$recorded" ]
}

adoption_exclude_rollback() {
  local work="$1" plan path source candidate
  [ -f "$work/exclude.json" ] || return 0
  plan="$(jq -c . "$work/exclude.json")" || return "$TRELLIS_EX_STATE"
  path="$(printf '%s\n' "$plan" | jq -r '.destination')"
  source="$(printf '%s\n' "$plan" | jq -r '.source')"
  candidate="$(printf '%s\n' "$plan" | jq -r '.candidate')"
  cmp -s "$path" "$source" && return 0
  cmp -s "$path" "$candidate" || return "$TRELLIS_EX_CONFLICT"
  adoption_publish_render "$plan" rollback
}

# The detached post-attach job holds the checkout lock for brief steps right
# after every attach; an adopt landing in that window waits it out and refuses,
# naming the lock, only when the bounded wait runs out.
adoption_checkout_lock_wait() {
  local common="$3" rc
  __release_adoption_home='' __release_adoption_checkout='' __release_adoption_common=''
  __release_adoption_link='' __release_adoption_holder='' __release_adoption_pid=''
  __release_adoption_birth='' __release_adoption_holder_id='' __release_adoption_owner_id=''
  if attachment_checkout_lock_wait "$@"; then
    __release_adoption_home="$1" __release_adoption_checkout="$2" __release_adoption_common="$3"
    __release_adoption_link="${_ATTACHMENT_CHECKOUT_LOCK_LINK:-}"
    __release_adoption_holder="${_ATTACHMENT_CHECKOUT_LOCK_HOLDER:-}"
    __release_adoption_pid="${_ATTACHMENT_PROCESS_PID:-}"
    if [ -n "$__release_adoption_holder" ] && [ -n "$__release_adoption_pid" ]; then
      __release_adoption_holder_id="$(_attachment_fs_identity "$__release_adoption_holder")" || __release_adoption_holder_id=''
      __release_adoption_owner_id="$(_attachment_fs_identity "$__release_adoption_holder/owner.json")" || __release_adoption_owner_id=''
      __release_adoption_birth="$(_attachment_process_birth "$__release_adoption_pid")" || __release_adoption_birth=''
    fi
    return 0
  else
    rc=$?
  fi
  [ "$rc" -ne "$TRELLIS_EX_CONFLICT" ] ||
    release_err "another Trellis operation still holds the checkout lock for $common; retry adoption when it finishes"
  return "$rc"
}

# A durable private plan survives SIGKILL. Registry CAS is the commit record:
# retry adoption finishes a fully published group, otherwise rolls it back.
# No registry snapshot is replayed, so unrelated concurrent writes survive.
recover_adoptions() (
  local home="$1" selector="$2" fleet="$3" project="$4" work first checkout common plan owner version current all_new snapshot
  [ -e "$home/state/release-adoptions" ] || [ -L "$home/state/release-adoptions" ] || return 0
  _attachment_canonical_dir "$home/state/release-adoptions" &&
    release_entry_private_directory "$home/state/release-adoptions" || return "$TRELLIS_EX_STATE"
  for work in "$home"/state/release-adoptions/*; do
    [ -d "$work" ] && [ ! -L "$work" ] || continue
    _attachment_canonical_dir "$work" && release_entry_private_directory "$work" || return "$TRELLIS_EX_STATE"
    [ -z "$(find "$work" -type l -print)" ] || return "$TRELLIS_EX_STATE"
    [ -f "$work/binding.json" ] && [ ! -L "$work/binding.json" ] || {
      release_err "incomplete adoption plan: $work; preserve it for inspection"
      return "$TRELLIS_EX_STATE"
    }
    first="$(jq -c '{row:.,binding:.}' "$work/binding.json")" || return "$TRELLIS_EX_STATE"
    case "$selector" in
      project) [ "$(printf '%s\n' "$first" | jq -r '.row.project_id')" = "$project" ] || continue ;;
    esac
    if [ "$selector" != all ]; then
      [ "$(printf '%s\n' "$first" | jq -r '.row.fleet')" = "$fleet" ] || continue
    fi
    checkout="$(printf '%s\n' "$first" | jq -r '.binding.checkout_id')"
    common="$(printf '%s\n' "$first" | jq -r '.binding.git_common_dir')"
    [ "$work" = "$home/state/release-adoptions/$checkout" ] || return "$TRELLIS_EX_STATE"
    adoption_checkout_lock_wait "$home" "$checkout" "$common" || return "$?"
    trap '_attachment_checkout_lock_release >/dev/null 2>&1 || true' EXIT
    if [ ! -f "$work/ready" ]; then
      rm -rf "$work" || return "$TRELLIS_EX_UNAVAILABLE"
      _attachment_checkout_lock_release || return "$?"
      trap - EXIT
      continue
    fi
    jq -e --arg common "$common" --arg work "$work" '
      .destination == ($common + "/info/exclude") and .source == ($work + "/exclude.source")
      and .candidate == ($work + "/exclude.candidate")' "$work/exclude.json" >/dev/null || return "$TRELLIS_EX_STATE"
    first="$(jq -cs '.[0]' "$work/plans.jsonl")" || return "$TRELLIS_EX_STATE"
    version="$(printf '%s\n' "$first" | jq -r '.new_version')"
    current="$(jq -r --arg key "$(printf '%s\n' "$first" | jq -r '.row.project_key')" --arg id "$checkout" \
      '.projects[$key].checkouts[$id].release' "$home/registry.json")" || return "$TRELLIS_EX_STATE"
    jq -e --slurpfile plans "$work/plans.jsonl" '
      . as $state | all($plans[]; . as $p | .binding as $b
        | $state.projects[$p.row.project_key].checkouts[$b.checkout_id] as $c
        | $c.git_common_dir == $b.git_common_dir and $c.root == $b.checkout_root
          and ($c.harnesses | sort) == $b.harnesses
          and $c.worktrees[$b.worktree_id].root == $b.root
          and $c.worktrees[$b.worktree_id].attachment_id == $b.attachment_id)
    ' "$home/registry.json" >/dev/null || return "$TRELLIS_EX_CONFLICT"
    all_new=true
    while IFS= read -r plan; do
      owner="$(printf '%s\n' "$plan" | jq -r '.owner')"
      [ "$owner" = "$home/state/attachments/$checkout/$(printf '%s\n' "$plan" | jq -r '.binding.worktree_id').json" ] || return "$TRELLIS_EX_STATE"
      for snapshot in old_owner new_owner; do
        snapshot="$(printf '%s\n' "$plan" | jq -r --arg key "$snapshot" '.[$key]')"
        [ "$(dirname "$snapshot")" = "$work" ] && _attachment_canonical_file "$snapshot" || return "$TRELLIS_EX_STATE"
      done
      _attachment_owner_json_valid "$(printf '%s\n' "$plan" | jq -r '.old_owner')" &&
        _attachment_owner_json_valid "$(printf '%s\n' "$plan" | jq -r '.new_owner')" || return "$TRELLIS_EX_STATE"
      [ "$(payload_for "$(printf '%s\n' "$plan" | jq -r '.old_version')")" = "$(printf '%s\n' "$plan" | jq -r '.old_payload')" ] &&
        [ "$(payload_for "$(printf '%s\n' "$plan" | jq -r '.new_version')")" = "$(printf '%s\n' "$plan" | jq -r '.new_payload')" ] || return "$TRELLIS_EX_STATE"
      cmp -s "$owner" "$(printf '%s\n' "$plan" | jq -r '.new_owner')" &&
        attachment_verify_adoption "$home" "$owner" >/dev/null &&
        runtime_anchor_matches_payload "$(jq -r '.worktree_root' "$owner")/.trellis/runtime" \
          "$(printf '%s\n' "$plan" | jq -r '.new_payload')" || all_new=false
      if [ "$(printf '%s\n' "$plan" | jq -r '.hooks')" = true ]; then
        hook_payload_matches "$(printf '%s\n' "$plan" | jq -r '.managed')" \
          "$(printf '%s\n' "$plan" | jq -r '.new_payload')" "$(jq -r '.worktree_root' "$owner")" || all_new=false
      fi
    done < "$work/plans.jsonl"
    if [ "$current" = "$version" ] && [ "$all_new" = true ] &&
      cmp -s "$common/info/exclude" "$work/exclude.candidate"; then
      : # Fully published, including the same-version reconciliation case.
    else
      [ "$current" = "$(printf '%s\n' "$first" | jq -r '.old_version')" ] || {
        release_err "adoption recovery binding drift: $work; preserve journal and restore exact state"
        return "$TRELLIS_EX_CONFLICT"
      }
      jq -c 'select(.hooks == "true")' "$work/plans.jsonl" > "$work/recovery-hooks"
      rollback_group_hooks "$work/recovery-hooks" && rollback_plans "$work/plans.jsonl" &&
        adoption_exclude_rollback "$work" || return "$?"
    fi
    rm -rf "$work" || return "$TRELLIS_EX_UNAVAILABLE"
    _attachment_checkout_lock_release || return "$?"
    trap - EXIT
  done
)

adopt_group() (
  local home="$1" version="$2" payload="$3" rows="$4" work="$5"
  local plans="$work/plans.jsonl" changed="$work/changed.jsonl" changed_hooks="$work/changed-hooks.jsonl"
  local row plan first checkout common rc=0 number=0 label planned_render repair render_path json_path repair_state dropped_key
  local owner planned_hook_authority current_hook_authority
  local lock_held=false committed=false cleanup_started=false active_plan='' active_hook_plan=''
  local durable=false exclude_applied=false replan=false
  local -a group_owners=()

  adopt_group_cleanup() {
    local status="${1:-$?}" cleanup_rc=0 one
    trap '' HUP INT TERM
    trap - EXIT
    [ "$cleanup_started" = true ] && return "$status"
    cleanup_started=true

    if [ "$committed" != true ] && [ "$lock_held" = true ] && [ -f "$work/ready" ]; then
      if [ -n "$active_hook_plan" ]; then
        rollback_hook_plan "$active_hook_plan"
        one=$?
        [ "$one" -eq 0 ] || cleanup_rc="$(max_status "$cleanup_rc" "$one")"
      fi
      rollback_group_hooks "$changed_hooks"
      one=$?
      [ "$one" -eq 0 ] || cleanup_rc="$(max_status "$cleanup_rc" "$one")"

      if [ -n "$active_plan" ]; then
        rollback_plan "$active_plan"
        one=$?
        [ "$one" -eq 0 ] || cleanup_rc="$(max_status "$cleanup_rc" "$one")"
      fi
      rollback_plans "$changed"
      one=$?
      [ "$one" -eq 0 ] || cleanup_rc="$(max_status "$cleanup_rc" "$one")"
      # A signal can arrive after CAS publication but before its caller records
      # success. Recognize the exact candidate, as crash recovery does; never
      # roll back competing external bytes after an unsuccessful CAS.
      if [ "$exclude_applied" = true ] ||
        cmp -s "$common/info/exclude" "$work/exclude.candidate"; then
        adoption_exclude_rollback "$work"
        one=$?
        [ "$one" -eq 0 ] || cleanup_rc="$(max_status "$cleanup_rc" "$one")"
      fi
    fi
    if [ "$durable" = true ] && [ "$cleanup_rc" -eq 0 ]; then
      rm -rf "$work" || cleanup_rc="$TRELLIS_EX_UNAVAILABLE"
    fi

    if [ "$lock_held" = true ]; then
      _attachment_checkout_lock_release >/dev/null 2>&1 ||
        cleanup_rc="$(max_status "$cleanup_rc" "$TRELLIS_EX_UNAVAILABLE")"
      lock_held=false
    fi
    [ "$cleanup_rc" -eq 0 ] || status="$(max_status "$status" "$cleanup_rc")"
    return "$status"
  }

  adopt_group_exit() {
    adopt_group_cleanup "$1"
    exit "$?"
  }

  adopt_group_signal() {
    adopt_group_cleanup "$TRELLIS_EX_UNAVAILABLE"
    exit "$?"
  }

  IFS= read -r first < "$rows" || return "$TRELLIS_EX_STATE"
  checkout="$(printf '%s\n' "$first" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$first" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  adoption_checkout_lock_wait "$home" "$checkout" "$common" || return "$?"
  lock_held=true
  trap 'adopt_group_exit "$?"' EXIT
  trap 'adopt_group_signal' HUP INT TERM
  # Spec 066 (u) migrates shared excludes for a group. A singleton takes the
  # same durable re-plan only when the new release changes its block.
  # Count all owner records under the checkout lock, not just selected rows:
  # an unavailable sibling must not turn a real group into a singleton bypass.
  group_owners=("$home/state/attachments/$checkout"/*.json)
  # Native-bearing generations always use a durable adoption journal, even
  # for one owner whose shared exclude block does not otherwise change.
  if [ "${#group_owners[@]}" -gt 1 ] ||
    [ -f "$payload/core-rules/native/artifacts.json" ] ||
    { [ -f "${group_owners[0]}" ] && _attachment_owner_json_valid "${group_owners[0]}" &&
      [ -f "$home/releases/$(jq -r '.release' "${group_owners[0]}")/payload/core-rules/native/artifacts.json" ]; }; then
    replan=true
  elif [ -f "${group_owners[0]}" ]; then
    adoption_singleton_exclude_stale "${group_owners[0]}" "$payload" \
      "$(printf '%s\n' "$first" | jq -c '.harnesses')" "$work"
    rc=$?
    case "$rc" in
      0) replan=true; rc=0 ;;
      1) rc=0 ;;
      *) return "$rc" ;;
    esac
  fi
  if [ "$replan" = true ]; then
    work="$home/state/release-adoptions/$checkout"
    mkdir -p "$home/state/release-adoptions" || return "$TRELLIS_EX_UNAVAILABLE"
    _attachment_canonical_dir "$home/state/release-adoptions" || return "$TRELLIS_EX_STATE"
    chmod 700 "$home/state/release-adoptions" || return "$TRELLIS_EX_UNAVAILABLE"
    mkdir -m 700 "$work" || { release_err "pending adoption: retry release adopt to recover $work"; return "$TRELLIS_EX_CONFLICT"; }
    durable=true
    printf '%s\n' "$first" > "$work/binding.json" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  plans="$work/plans.jsonl"; changed="$work/changed.jsonl"; changed_hooks="$work/changed-hooks.jsonl"
  : > "$changed"; : > "$changed_hooks"
  : > "$plans" || return "$TRELLIS_EX_UNAVAILABLE"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    number=$((number + 1))
    label="$(target_label "$row")" || return "$TRELLIS_EX_STATE"
    preflight_target "$home" "$version" "$payload" "$row" "$work" "$number" >> "$plans"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      release_err "attachment ownership/runtime preflight failed for $label"
      return "$rc"
    fi
  done < "$rows"
  [ -s "$plans" ] || return "$TRELLIS_EX_UNAVAILABLE"
  adopt_group_require_uniform "$plans" || return "$?"
  : > "$changed" || return "$TRELLIS_EX_UNAVAILABLE"
  : > "$changed_hooks" || return "$TRELLIS_EX_UNAVAILABLE"

  if [ "$durable" = true ]; then
    adoption_exclude_plan "$home" "$plans" "$payload" "$work" "$common" "$checkout" || {
      rc=$?
      release_err "group exclude planning refused for checkout $checkout ($common/info/exclude); remedy: restore exact committed exclude ownership and compatible root deferrals before retrying"
      return "$rc"
    }
  fi
  : > "$work/ready" || return "$TRELLIS_EX_UNAVAILABLE"

  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    plan_matches_old "$home" "$plan" || return "$?"
  done < "$plans"

  # Re-resolve every exact target immediately before the first checkout
  # mutation. This closes the small window after group-wide validation.
  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    plan_matches_old "$home" "$plan" || return "$?"
  done < "$plans"

  if [ "$durable" = true ]; then
    adoption_publish_render "$(jq -c . "$work/exclude.json")" forward || {
      rc=$?
      release_err "shared exclude CAS refused for $common/info/exclude; remedy: preserve concurrent bytes and retry adoption from verified state"
      return "$rc"
    }
    exclude_applied=true
  fi

  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    active_plan="$plan"
    apply_plan "$plan" || return "$?"
    printf '%s\n' "$plan" >> "$changed" || return "$TRELLIS_EX_UNAVAILABLE"
    active_plan=''
  done < "$plans"

  apply_group_hooks "$plans" "$changed_hooks" || return "$?"

  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    owner="$(printf '%s\n' "$plan" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
    planned_hook_authority="$(printf '%s\n' "$plan" | jq -r '.hook_authority')" || return "$TRELLIS_EX_STATE"
    current_hook_authority="$(attachment_verify_adoption "$home" "$owner")"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ "$current_hook_authority" != "$planned_hook_authority" ]; then
      release_err 'release adoption hook authority drifted after apply'
      return "$TRELLIS_EX_CONFLICT"
    fi
  done < "$plans"

  # Do not let a catchable signal roll back owners after registry publication.
  # SIGKILL still leaves the durable plan and registry CAS commit record.
  trap '' HUP INT TERM
  update_group_registry "$home" "$plans" "$version"
  rc=$?
  [ "$rc" -ne 0 ] || committed=true
  trap 'adopt_group_signal' HUP INT TERM
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    while IFS= read -r planned_render; do
      render_path="$(printf '%s\n' "$planned_render" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
      while IFS= read -r repair; do
        json_path="$(printf '%s\n' "$repair" | jq -r '.path | @json')" || return "$TRELLIS_EX_STATE"
        repair_state="$(printf '%s\n' "$repair" | jq -r '.state')" || return "$TRELLIS_EX_STATE"
        printf 're-rendered owned JSON key: %s %s (%s)\n' "$render_path" "$json_path" "$repair_state"
      done < <(printf '%s\n' "$planned_render" | jq -c '.drift[]')
      while IFS= read -r dropped_key; do
        [ -n "$dropped_key" ] || continue
        printf 'left in place (no longer in template): %s %s\n' "$render_path" "$dropped_key"
      done < <(printf '%s\n' "$planned_render" | jq -c '(.template_dropped // [])[]')
    done < <(printf '%s\n' "$plan" | jq -c '.renders[]')
    label="$(target_label "$(printf '%s\n' "$plan" | jq -c '.row')")" || return "$TRELLIS_EX_STATE"
    planned_hook_authority="$(printf '%s\n' "$plan" | jq -r '.hook_authority')" || return "$TRELLIS_EX_STATE"
    if [ "$planned_hook_authority" = operator-owned ]; then
      printf 'hook authority: operator-owned; core.hooksPath was left unchanged: %s\n' "$label"
    fi
    printf 'adopted: %s\n' "$label"
  done < "$plans"
  if [ "$durable" = true ]; then
    release_adoption_reap_completed_stages "$plans" "$common/info/exclude"
  else
    release_adoption_reap_completed_stages "$plans" ''
  fi
  adopt_group_cleanup 0
  return "$?"
)

# Writes the selected rows to OUTPUT and, when REJECTED is supplied, the exact
# complement to REJECTED. The complement is built from the same predicate as the
# selection so the two can never drift apart: a registry state error outside the
# selection still has to be reported, and the only reliable way to know which
# rows those are is to partition the listing rather than re-derive it.
select_rows() {
  local inventory="$1" selector="$2" fleet="$3" project="$4" output="$5" rejected="${6:-}" predicate
  case "$selector" in
    all) predicate='true' ;;
    fleet) predicate='(.fleet == $fleet)' ;;
    project) predicate='(.fleet == $fleet and .project_id == $project)' ;;
    *) return "$TRELLIS_EX_USAGE" ;;
  esac
  jq -c --arg fleet "$fleet" --arg project "$project" \
    ".entries[]? | select($predicate)" "$inventory" > "$output" || return "$TRELLIS_EX_STATE"
  [ -n "$rejected" ] || return 0
  jq -c --arg fleet "$fleet" --arg project "$project" \
    ".entries[]? | select(($predicate) | not)" "$inventory" > "$rejected" || return "$TRELLIS_EX_STATE"
}

adopt_registry() (
  local version="$1" selector="$2" fleet="$3" project="$4" home release payload inventory selected rejected groups group_rows work row label kind availability status excluded rc=0 one
  local row_root row_checkout
  home="$(release_home)" || return "$?"
  export TRELLIS_HOME="$home"
  version="$(release_store_normalize_version "$version")" || return "$?"
  release="$(release_store_locate "$version")" || return "$?"
  payload="$(CDPATH='' cd "$release/payload" && pwd -P)" || return "$TRELLIS_EX_STATE"
  inventory="$(mktemp "${TMPDIR:-/tmp}/trellis.release.inventory.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  selected="$(mktemp "${TMPDIR:-/tmp}/trellis.release.rows.XXXXXX")" || { rm -f "$inventory"; return "$TRELLIS_EX_UNAVAILABLE"; }
  rejected="$(mktemp "${TMPDIR:-/tmp}/trellis.release.unselected.XXXXXX")" || { rm -f "$inventory" "$selected"; return "$TRELLIS_EX_UNAVAILABLE"; }
  groups="$(mktemp "${TMPDIR:-/tmp}/trellis.release.groups.XXXXXX")" || { rm -f "$inventory" "$selected" "$rejected"; return "$TRELLIS_EX_UNAVAILABLE"; }
  trap 'rm -f "$inventory" "$selected" "$rejected" "$groups"' EXIT INT TERM

  if [ "$selector" = project ] && [ -z "$fleet" ]; then
    local_registry_list_json "$home" > "$inventory" || return "$?"
    local fleet_count
    fleet_count="$(jq -r --arg project "$project" '[.entries[]? | select(.project_id == $project) | .fleet] | unique | length' "$inventory")" || return "$TRELLIS_EX_STATE"
    case "$fleet_count" in
      0) ;;
      1) fleet="$(jq -r --arg project "$project" '[.entries[]? | select(.project_id == $project) | .fleet] | unique[0]' "$inventory")" || return "$TRELLIS_EX_STATE" ;;
      *) release_err "project selector is ambiguous across fleets: $project"; return "$TRELLIS_EX_CONFLICT" ;;
    esac
  fi
  # Recovery must use the resolved fleet, just like row selection. Refuse an
  # ambiguous project before touching its journals, then list post-recovery state.
  recover_adoptions "$home" "$selector" "$fleet" "$project" || return "$?"
  local_registry_list_json "$home" > "$inventory" || return "$?"
  select_rows "$inventory" "$selector" "$fleet" "$project" "$selected" "$rejected" || return "$?"

  # A registry state error is a property of the REGISTRY, not of the adoption
  # selector. The row loop below reports the drifted rows this adoption would
  # have touched; the rows the selector removed are reported here, from the FULL
  # machine listing, so an adopt scoped to one healthy project cannot succeed
  # over a registry it has just been shown to be corrupt. `--all` selects
  # everything, so this reports nothing.
  local unselected_rc=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(printf '%s\n' "$row" | jq -r '.availability')" = identity_error ] || continue
    label="$(target_label "$row")" || return "$TRELLIS_EX_STATE"
    release_err "registry row outside the adoption selector failed local registry identity validation: $label"
    unselected_rc="$TRELLIS_EX_STATE"
  done < "$rejected"
  rc="$(max_status "$rc" "$unselected_rc")"

  [ -s "$selected" ] || {
    release_err 'no registered worktrees matched the requested adoption selector'
    return "$(max_status "$rc" "$TRELLIS_EX_UNAVAILABLE")"
  }

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    kind="$(printf '%s\n' "$row" | jq -r '.kind')" || return "$TRELLIS_EX_STATE"
    availability="$(printf '%s\n' "$row" | jq -r '.availability')" || return "$TRELLIS_EX_STATE"
    status="$(printf '%s\n' "$row" | jq -r '.status')" || return "$TRELLIS_EX_STATE"
    excluded="$(printf '%s\n' "$row" | jq -r '.excluded // false')" || return "$TRELLIS_EX_STATE"
    label="$(target_label "$row")" || return "$TRELLIS_EX_STATE"
    if [ "$availability" = identity_error ]; then
      release_err "adoption target failed local registry identity validation: $label"
      rc="$(max_status "$rc" "$TRELLIS_EX_STATE")"
    elif [ "$kind" = checkout ] && { [ "$selector" = all ] || [ "$selector" = fleet ]; }; then
      # A `checkout` row is a VISIBILITY row: the listing emits it only for a
      # checkout that currently registers no worktree, so it names inventory,
      # not an adoption target. A bulk selector sweeps the whole machine or the
      # whole fleet, and treating that inventory row as an explicitly requested
      # target made `adopt --all` fail class 5 on a healthy registry that merely
      # contained one empty-worktrees checkout. Explicit `--project` targeting
      # is unchanged: naming a project whose only row is a checkout still falls
      # through to the unavailable-target report below, which is the honest
      # answer to "adopt this project" when it has no worktree to adopt.
      #
      # Bulk selectors report rows that cannot be adopted, but those inventory
      # rows are not attempted targets and therefore do not contribute to the
      # command status. The predicate mirrors the worktree branch so detached
      # and excluded checkout rows remain visible instead of being mislabeled
      # as benign empty-checkout skips. `identity_error` is registry corruption,
      # is handled above, and still contributes class 4.
      if [ "$availability" != available ] || [ "$status" != active ] || [ "$excluded" = true ]; then
        release_err "unavailable checkout inventory row swept by the adoption selector: $label"
      else
        release_err "skipping checkout inventory row with no registered worktree: $label"
      fi
    elif [ "$kind" != worktree ] || [ "$availability" != available ] || [ "$status" != active ] || [ "$excluded" = true ]; then
      row_root="$(printf '%s\n' "$row" | jq -r '.root // "(no recorded root)"')" || return "$TRELLIS_EX_STATE"
      row_checkout="$(printf '%s\n' "$row" | jq -r '.checkout_id // "(no checkout)"')" || return "$TRELLIS_EX_STATE"
      release_err "unavailable adoption target remains explicit: $label (root: $row_root, checkout: $row_checkout)"
    fi
  done < "$selected"

  # Every exit path after the row loop preserves `rc`. It carries registry
  # identity errors; unavailable rows are report-only whenever an eligible
  # worktree exists. Empty scoped selections still return class 5 below.
  jq -r 'select(.kind == "worktree" and .availability == "available" and .status == "active" and (.excluded // false | not)) | [.fleet,.project_id,.checkout_id] | @tsv' "$selected" | sort -u > "$groups" ||
    return "$(max_status "$rc" "$TRELLIS_EX_STATE")"
  if [ ! -s "$groups" ]; then
    # NOTHING ADOPTABLE. This is the same condition as an empty selection — the
    # selector matched rows, but not one of them is a target this command can
    # adopt — and it gets the same class-5 answer, floored over whatever the
    # rows already proved. The old `${rc:-...}` fallback could never fire: `rc`
    # is initialised to 0 and reassigned by `max_status` before this point, so
    # it is never unset, and a `--all`/`--fleet` selection consisting entirely
    # of skipped checkout inventory rows returned 0 having adopted nothing.
    release_err 'no adoptable registered worktree matched the requested adoption selector'
    return "$(max_status "$rc" "$TRELLIS_EX_UNAVAILABLE")"
  fi

  local group_fleet group_project group_checkout
  while IFS=$'\t' read -r group_fleet group_project group_checkout; do
    group_rows="$(mktemp "${TMPDIR:-/tmp}/trellis.release.group.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    work="$(mktemp -d "${TMPDIR:-/tmp}/trellis.release.adopt.XXXXXX")" || { rm -f "$group_rows"; return "$TRELLIS_EX_UNAVAILABLE"; }
    jq -c --arg fleet "$group_fleet" --arg project "$group_project" --arg checkout "$group_checkout" '
      select(.fleet == $fleet and .project_id == $project and .checkout_id == $checkout
             and .kind == "worktree" and .availability == "available" and .status == "active"
             and (.excluded // false | not))
    ' "$selected" > "$group_rows" || { rm -f "$group_rows"; rm -rf "$work"; return "$(max_status "$rc" "$TRELLIS_EX_STATE")"; }
    adopt_group "$home" "$version" "$payload" "$group_rows" "$work"
    one=$?
    rm -f "$group_rows"
    rm -rf "$work"
    [ "$one" -eq 0 ] || rc="$(max_status "$rc" "$one")"
  done < "$groups"
  return "$rc"
)

# Does PATH lie inside VERSION's release directory, its removal STAGE (when one
# is given), or one of its execution snapshots (releases/.exec/VERSION-<sha256>)?
# Matched whole, so 1.0.0 never claims a 1.0.0-rc.1 snapshot. HOME is canonical.
# Matched ignoring case: on a case-insensitive volume (the macOS default)
# Releases/1.0.0 is the release, and a spelling must never rule a path out.
remove_path_names_release() (
  local home="$1" version="$2" path="$3" stage="${4:-}" rest
  shopt -s nocasematch
  if [ -n "$stage" ]; then
    case "$path" in "$stage"|"$stage"/*) return 0 ;; esac
  fi
  case "$path" in
    "$home/releases/$version"|"$home/releases/$version"/*) return 0 ;;
    "$home/releases/.exec/$version"-*)
      # Strip by length: prefix removal is case-sensitive even under nocasematch.
      rest="$home/releases/.exec/$version-"
      rest="${path:${#rest}}"
      rest="${rest%%/*}"
      case "$rest" in *[!0-9a-f]*) return 1 ;; esac
      [ "${#rest}" -eq 64 ]
      return
      ;;
  esac
  return 1
)

# remove_same_version A B: are A and B one version, ignoring case? On a
# case-insensitive volume releases/1.0.0-RC.1 is releases/1.0.0-rc.1.
remove_same_version() (
  shopt -s nocasematch
  case "$1" in "$2") ;; *) false ;; esac
)

# Does link TARGET, read from a link in directory BASE, name VERSION? Both the
# literal target and its realpath are matched. realpath resolves a relative
# target, symlinked parents (/var -> /private/var), ".", "..", "//" and a
# trailing slash, and still answers once the release has moved to its stage,
# because a missing tail is kept as written.
remove_target_names_release() {
  local home="$1" version="$2" stage="$3" base="$4" target="$5" resolved
  remove_path_names_release "$home" "$version" "$target" "$stage" && return 0
  resolved="$(python3 -I - "$base" "$target" <<'PY'
import os
import stat
import sys

# Unlike realpath(strict=False), preserve only ENOENT tails, never permission,
# I/O or symlink-loop errors. Missing tails are needed after staging a release.
pending = os.path.join(*sys.argv[1:]).split("/")
resolved = "/"
links = 0
try:
    while pending:
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            resolved = os.path.dirname(resolved)
            continue
        path = os.path.join(resolved, part)
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            resolved = path
            continue
        if stat.S_ISLNK(info.st_mode):
            links += 1
            if links > 40:
                raise OSError("too many symlinks: " + path)
            link = os.readlink(path)
            if os.path.isabs(link):
                resolved = "/"
            pending = link.split("/") + pending
        else:
            resolved = path
except OSError as error:
    sys.stderr.write("trellis release: cannot resolve reference: %s\n" % error)
    raise SystemExit(2)
print(resolved)
PY
  )" || return 2
  remove_path_names_release "$home" "$version" "$resolved" "$stage"
}

# remove_json_reference HOME VERSION LABEL FILE prints a refusal row when FILE
# (JSON, or JSON lines) names VERSION as a release, old_version or new_version,
# or holds a path into its release or snapshots, ignoring ASCII case like
# remove_path_names_release. A file that is not a regular file or does not
# parse is a reference this command cannot rule out.
remove_json_reference() {
  local home="$1" version="$2" label="$3" file="$4" rc=0
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    printf '4\t%s is not a regular file\t%s\n' "$label" "$file"
    return 0
  fi
  jq -e -s --arg v "$version" --arg r "$home/releases" '
    if length == 0 then error("empty") else . end
    | ($v | ascii_downcase) as $v | ($r | ascii_downcase) as $r
    | any(.. | objects | to_entries[];
        (.key == "release" or .key == "old_version" or .key == "new_version")
        and (.value | type) == "string" and (.value | ascii_downcase) == $v)
      or any(.. | strings | ascii_downcase;
        . == ($r + "/" + $v) or startswith($r + "/" + $v + "/")
        or (startswith($r + "/.exec/" + $v + "-")
          and (.[($r + "/.exec/" + $v + "-" | length):] | test("^[0-9a-f]{64}(/|$)"))))
  ' "$file" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf '3\t%s\t%s\n' "$label" "$file" ;;
    1) ;;
    *) printf '4\t%s is unreadable\t%s\n' "$label" "$file" ;;
  esac
}

# An unavailable row's runtime anchor cannot be read, so the row is judged by
# what it records: its checkout's registry release pin and its owner record.
# It blocks VERSION when either names VERSION, and when it records no release
# at all (unknown). Only a genuinely absent root may use this fallback; an
# existing or inaccessible root whose identity cannot be checked refuses.
remove_unavailable_row() {
  local home="$1" version="$2" label="$3" root="$4" pin="$5" checkout="$6" worktree="$7" owner paths recorded=''
  if [ "$root" != '(no recorded root)' ]; then
    if ! paths="$(remove_reference_paths "$root" 0 '')" || [ -n "$paths" ]; then
      printf '4\tunavailable registry row of %s cannot be inspected\t%s\n' "$label" "$root"
      return 0
    fi
  fi
  [ "$pin" = - ] || recorded="$pin"
  owner="$home/state/attachments/$checkout/$worktree.json"
  if [ "$checkout" != - ] && [ "$worktree" != - ]; then
    if ! paths="$(remove_reference_paths "$owner" 0 '')"; then
      printf '4\tunavailable registry row of %s has an unreadable owner record %s\t%s\n' "$label" "$owner" "$root"
      return 0
    fi
  else
    paths=''
  fi
  if [ -n "$paths" ]; then
    if [ -L "$owner" ] || [ ! -f "$owner" ] || ! pin="$(jq -er '.release | strings' "$owner" 2>/dev/null)"; then
      printf '4\tunavailable registry row of %s has an unreadable owner record %s\t%s\n' "$label" "$owner" "$root"
      return 0
    fi
    recorded="$recorded $pin"
  fi
  case " $recorded " in
    "  ") printf '3\tunavailable registry row of %s records no release, so it may still use it\t%s\n' "$label" "$root" ;;
    *" $version "*) printf '3\tunavailable registry row of %s records this release\t%s\n' "$label" "$root" ;;
  esac
}

# Checked optional lookup or namespace traversal. Only ENOENT is absence.
# Buffer results until traversal succeeds so a partial listing is never usable.
# On failure stdout is the offending path, status 4 (not an empty namespace).
remove_reference_paths() {
  python3 -I - "$@" <<'PY'
import os
import stat
import sys

path, depth, suffix = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = []
current = path


def visit(path, depth, optional=True):
    global current
    current = path
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        if optional:
            return
        raise
    if depth == 0:
        rows.append(path)
        return
    if not stat.S_ISDIR(info.st_mode):
        raise OSError("reference namespace is not a directory")
    if not os.access(path, os.X_OK):
        raise PermissionError("reference namespace is not searchable")
    with os.scandir(path) as entries:
        names = sorted(entry.name for entry in entries)
    for name in names:
        child = os.path.join(path, name)
        if depth > 1 and suffix and not name.endswith(suffix):
            # A stray file beside the record directories (.DS_Store) holds no
            # record; anything else, or an entry lstat cannot read, is walked.
            try:
                if stat.S_ISREG(os.lstat(child).st_mode):
                    continue
            except OSError:
                pass
        if depth > 1 or not suffix or name.endswith(suffix):
            visit(child, depth - 1, optional=False)


try:
    visit(path, depth)
except OSError as error:
    sys.stderr.write("trellis release: cannot inspect %s: %s\n" % (current, error))
    print(current)
    raise SystemExit(4)
print("\n".join(rows), end="\n" if rows else "")
PY
}

# remove_release_references HOME VERSION STAGE [HELD_PATH...] prints one
# CLASS<TAB>REASON<TAB>PATH row for every reason VERSION must stay installed.
# CLASS 3 is a reference and 4 is one this command cannot rule out: a probe
# that cannot answer is reported, never skipped. A registry row that is not
# available cannot have its runtime anchor read; remove_unavailable_row judges
# it by what it records, and a row failing identity validation always refuses.
# STAGE is the release's removal stage once it has been renamed, else empty.
# HELD_PATHs are the directories no running process may be using.
remove_release_references() {
  local home="$1" version="$2" stage="$3" config active owner journal work inventory row label availability root anchor target file pin handles pid path checkout worktree sidecar rc namespace paths records pins
  shift 3
  config="$home/config.json"
  if [ -f "$config" ] && [ ! -L "$config" ] &&
    active="$(jq -ers 'if length == 1 and (.[0] | type) == "object" then .[0].active_cli_release | strings else error("not one object") end' "$config" 2>/dev/null)"; then
    ! remove_same_version "$active" "$version" ||
      printf '3\t%s\t%s\n' 'it is the active CLI release (active_cli_release)' "$config"
  else
    printf '4\t%s\t%s\n' 'the active CLI release is unreadable' "$config"
  fi

  for namespace in "$home/state/attachments" "$home/attachments"; do
    if [ "$namespace" = "$home/state/attachments" ]; then
      paths="$(remove_reference_paths "$namespace" 2 .json)"; rc=$?
    else
      paths="$(remove_reference_paths "$namespace" 1 .json)"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf '4\t%s\t%s\n' 'reference namespace could not be checked' "${paths:-$namespace}"
      continue
    fi
    while IFS= read -r owner; do
      [ -n "$owner" ] || continue
      remove_json_reference "$home" "$version" 'attachment owner record' "$owner"
    done <<< "$paths"
  done

  # A managed Git hook runs the payload its release-payload sidecar names.
  if paths="$(remove_reference_paths "$home/state/git-hooks" 2 release-payload)"; then
  while IFS= read -r sidecar; do
    [ -n "$sidecar" ] || continue
    if [ -L "$sidecar" ] || [ ! -f "$sidecar" ] || [ ! -s "$sidecar" ]; then
      printf '4\t%s\t%s\n' 'managed Git hook release-payload sidecar is not a non-empty regular file' "$sidecar"
      continue
    fi
    if ! target="$(python3 -I -c 'import sys; print(open(sys.argv[1], encoding="utf-8").read(), end="")' "$sidecar")"; then
      printf '4\t%s\t%s\n' 'managed Git hook release-payload sidecar is unreadable' "$sidecar"
      continue
    fi
    while IFS= read -r path || [ -n "$path" ]; do
      rc=0
      remove_target_names_release "$home" "$version" "$stage" "${sidecar%/*}" "$path" || rc=$?
      case "$rc" in
        0) printf '3\t%s\t%s\n' 'managed Git hook release-payload sidecar' "$sidecar" ;;
        1) ;;
        *) printf '4\t%s\t%s\n' 'managed Git hook release-payload sidecar could not be resolved' "$sidecar" ;;
      esac
    done <<< "$target"
  done <<< "$paths"
  else
    printf '4\t%s\t%s\n' 'reference namespace could not be checked' "${paths:-$home/state/git-hooks}"
  fi

  inventory="$(mktemp "${TMPDIR:-/tmp}/trellis.release.remove.XXXXXX")" || {
    printf '4\t%s\t%s\n' 'the local registry could not be listed' "$home/registry.json"
    return 0
  }
  if local_registry_list_json "$home" > "$inventory" 2>/dev/null; then
    if pins="$(jq -r --arg v "$version" '
      [.entries[]? | select((.release | strings | ascii_downcase) == ($v | ascii_downcase))
        | "\(.fleet)/\(.project_id) checkout \(.checkout_id)"]
      | unique[] | "3\tregistry release pin of \(.)"' "$inventory")" &&
      records="$(jq -r '.entries[]? | ["\(.fleet)/\(.project_id)", .availability, (.root // "-"),
      (.release // "-"), (.checkout_id // "-"), (.worktree_id // "-")] | @tsv' "$inventory")"; then
    while IFS= read -r row; do
      [ -z "$row" ] || printf '%s\t%s\n' "$row" "$home/registry.json"
    done <<< "$pins"
    while IFS=$'\t' read -r label availability root pin checkout worktree; do
      [ -n "$label" ] || continue
      [ "$root" != - ] || root=''
      if [ "$availability" = identity_error ]; then
        printf '4\tregistry row of %s failed identity validation\t%s\n' "$label" "${root:-(no recorded root)}"
        continue
      elif [ "$availability" != available ]; then
        remove_unavailable_row "$home" "$version" "$label" "${root:-(no recorded root)}" "$pin" "$checkout" "$worktree"
        continue
      fi
      [ -n "$root" ] || continue
      anchor="$root/.trellis/runtime"
      if ! paths="$(remove_reference_paths "$anchor" 0 '')"; then
        printf '4\truntime anchor of %s is unreadable\t%s\n' "$label" "$anchor"
      elif [ -z "$paths" ]; then
        : # An absent anchor, not an inaccessible parent.
      elif [ -L "$anchor" ]; then
        rc=0
        if target="$(readlink "$anchor")"; then
          remove_target_names_release "$home" "$version" "$stage" "$root/.trellis" "$target" || rc=$?
        else
          rc=2
        fi
        case "$rc" in
          0) printf '3\truntime anchor of %s\t%s\n' "$label" "$anchor" ;;
          1) ;;
          *) printf '4\truntime anchor of %s is unreadable\t%s\n' "$label" "$anchor" ;;
        esac
      else
        printf '4\truntime anchor of %s is not a symlink\t%s\n' "$label" "$anchor"
      fi
      for file in "$root/.trellis.config.json" "$root/trellis.config.json"; do
        if ! paths="$(remove_reference_paths "$file" 0 '')"; then
          printf '4\tproject config of %s is unreadable\t%s\n' "$label" "$file"
          continue
        fi
        [ -n "$paths" ] || continue
        if [ -L "$file" ] || [ ! -f "$file" ]; then
          printf '4\tproject config of %s is not a regular file\t%s\n' "$label" "$file"
        elif pin="$(jq -e -r -s 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end
            | if has("trellis_version") then .trellis_version | strings else "" end' "$file" 2>/dev/null)"; then
          ! remove_same_version "${pin#v}" "$version" ||
            printf '3\tproject config trellis_version pin of %s\t%s\n' "$label" "$file"
        else
          printf '4\tproject config of %s is unreadable\t%s\n' "$label" "$file"
        fi
      done
    done <<< "$records"
    else
      printf '4\t%s\t%s\n' 'the local registry could not be decoded' "$home/registry.json"
    fi
  else
    printf '4\t%s\t%s\n' 'the local registry could not be listed' "$home/registry.json"
  fi
  rm -f "${inventory:?}"

  for namespace in "$home/state/attachment-journals" "$home/state/user-attachment-journals"; do
    if ! paths="$(remove_reference_paths "$namespace" 1 .json)"; then
      printf '4\t%s\t%s\n' 'reference namespace could not be checked' "${paths:-$namespace}"
      continue
    fi
    while IFS= read -r journal; do
      [ -n "$journal" ] || continue
      remove_json_reference "$home" "$version" 'pending attachment journal' "$journal"
    done <<< "$paths"
  done
  if paths="$(remove_reference_paths "$home/state/release-adoptions" 1 '')"; then
  while IFS= read -r work; do
    [ -n "$work" ] || continue
    if ! records="$(remove_reference_paths "$work" 1 '')"; then
      printf '4\t%s\t%s\n' 'reference namespace could not be checked' "${records:-$work}"
      continue
    fi
    if [ -L "$work" ] || [ ! -d "$work" ] || [ ! -f "$work/plans.jsonl" ]; then
      printf '4\t%s\t%s\n' 'pending adoption journal has no readable plan' "$work"
      continue
    fi
    remove_json_reference "$home" "$version" 'pending adoption journal' "$work/plans.jsonl"
  done <<< "$paths"
  else
    printf '4\t%s\t%s\n' 'reference namespace could not be checked' "${paths:-$home/state/release-adoptions}"
  fi

  [ "$#" -gt 0 ] || return 0
  if handles="$(release_store_live_handles "$@")"; then
    printf '%s\n' "$handles" | while IFS=$'\t' read -r pid path; do
      [ -z "$pid" ] || printf '3\trunning process %s uses it\t%s\n' "$pid" "$path"
    done
  else
    printf '4\t%s\t%s\n' 'running processes could not be checked' "$1"
  fi
}

remove_report_refusals() {
  local version="$1" refusals="$2" class reason path rc=0
  while IFS=$'\t' read -r class reason path; do
    release_err "refusing to remove $version: $reason: $path"
    rc="$(max_status "$rc" "$class")"
  done < "$refusals"
  printf 'remove: %s kept; nothing removed\n' "$version"
  return "$rc"
}

remove_report_rows() {
  local version="$1" rows="$2" verb="$3" kind path bytes total=0 count=0
  while IFS=$'\t' read -r kind path bytes; do
    printf 'remove: %s %s %s (%s)\n' "$verb" "$kind" "$path" "$(remove_size "$bytes")"
    total=$((total + bytes))
    count=$((count + 1))
  done < "$rows"
  printf 'remove: %s total entries=%s bytes=%s (%s)\n' "$version" "$count" "$total" "$(remove_size "$total")"
}

remove_size() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f MiB", bytes / 1048576 }'
}

# Is LOCK a removal lock (holding only remove.owner.json) whose owner exited?
# An install lock is empty and is never stale here; anything that cannot be
# read counts as live. A pid another user now owns cannot be our remover.
remove_lock_is_stale() {
  local lock="$1" owner="$1/remove.owner.json" pid birth now
  [ -d "$lock" ] && [ ! -L "$lock" ] && [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  [ "$(ls -A "$lock")" = remove.owner.json ] || return 1
  pid="$(jq -er 'select(type == "object" and (keys | sort) == ["pid","process_birth","schema_version"]
    and .schema_version == 1 and (.process_birth | type == "string")) | .pid | numbers' "$owner" 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ "${#pid}" -le 10 ] && [ "$pid" -le 2147483647 ] || return 1
  birth="$(jq -r '.process_birth' "$owner" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" &&
    [ -n "$birth" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 0
  now="$(release_store_process_birth "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" &&
    [ -n "$now" ] || return 1
  [ "$now" != "$birth" ]
}

# `trellis release remove VERSION [--dry-run|--apply]`. Nothing is removed while
# anything still references VERSION (remove_release_references). Apply holds
# the release-store lock install uses, with an owner record so a later remove
# can clear it once this process has died. It renames the release to a
# `.tmp.remove.*` stage with an owner record, checks the references again against the staged
# path (an adoption may have bound VERSION meanwhile, and puts the release back
# if so), then hands the stage to release_store_remove_entries finish.
remove_release() (
  local home version="$2" mode="$3" releases lock='' lock_stage='' rows='' refusals='' stage='' how=created rc kind path bytes
  local installed=false stale=false
  local -a held=()
  cleanup_remove() {
    [ -z "${rows:-}" ] || rm -f "$rows"
    [ -z "${refusals:-}" ] || rm -f "$refusals"
    [ -z "${lock:-}" ] || { rm -f "$lock/remove.owner.json"; rmdir "$lock"; } 2>/dev/null
    [ -z "${lock_stage:-}" ] || { rm -f "$lock_stage/remove.owner.json"; rmdir "$lock_stage"; } 2>/dev/null
  }
  trap cleanup_remove EXIT INT TERM
  releases="$(release_store_canonical_releases_dir)" || return "$?"
  # Every path comparison below is against the canonical home.
  home="${releases%/releases}"
  rows="$(mktemp "${TMPDIR:-/tmp}/trellis.release.remove.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  refusals="$(mktemp "${TMPDIR:-/tmp}/trellis.release.refusals.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  ! remove_lock_is_stale "$releases/$version.lock" || stale=true
  if [ "$stale" = true ] && [ "$mode" = apply ]; then
    release_err "clearing the removal lock a dead process left: $releases/$version.lock"
    rm -f "$releases/$version.lock/remove.owner.json" && rmdir "$releases/$version.lock" ||
      return "$TRELLIS_EX_UNAVAILABLE"
  elif [ "$stale" = true ]; then
    printf 'remove: --apply clears the removal lock a dead process left: %s\n' "$releases/$version.lock"
  fi
  rc=0
  if [ "$mode" = apply ]; then
    # Publish the lock whole: it appears already holding its owner record, so
    # no crash leaves an empty lock that reads as an install's. An unpublished
    # .tmp.lock.* stage is collected by reap-tmp.
    lock_stage="$(release_store_mktemp_dir "$releases/.tmp.lock.$version.XXXXXX")" &&
      release_store_write_snapshot_owner "$lock_stage/remove" || {
      release_err "could not prepare the release store lock: $releases/$version.lock"
      return "$TRELLIS_EX_UNAVAILABLE"
    }
    release_store_rename_no_clobber "$lock_stage" "$releases/$version.lock" 2>/dev/null || rc=$?
    case "$rc" in
      0) lock="$releases/$version.lock"; lock_stage='' ;;
      3) ;;
      *)
        release_err "could not create release store lock: $releases/$version.lock"
        return "$TRELLIS_EX_UNAVAILABLE"
        ;;
    esac
  fi
  if { [ "$mode" = apply ] && [ -z "$lock" ]; } ||
    { [ "$mode" != apply ] && [ "$stale" = false ] &&
      { [ -e "$releases/$version.lock" ] || [ -L "$releases/$version.lock" ]; }; }; then
    printf '3\t%s\t%s\n' 'the release store lock is held (an install or removal is in progress)' \
      "$releases/$version.lock" > "$refusals"
    remove_report_refusals "$version" "$refusals"
    return "$?"
  fi
  release_store_remove_entries plan "$version" > "$rows" || return "$?"
  [ -s "$rows" ] || {
    release_err "release not installed: $version"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  while IFS=$'\t' read -r kind path bytes; do
    case "$kind" in
      release) installed=true; held[${#held[@]}]="$path" ;;
      remove-stage) stage="$path"; how=resumed; held[${#held[@]}]="$path" ;;
      exec-snapshot|exec-lock) held[${#held[@]}]="$path" ;;
    esac
  done < "$rows"
  remove_release_references "$home" "$version" "$stage" ${held[@]+"${held[@]}"} > "$refusals"
  if [ -s "$refusals" ]; then
    remove_report_refusals "$version" "$refusals"
    return "$?"
  fi
  if [ "$mode" = dry-run ]; then
    remove_report_rows "$version" "$rows" 'would remove'
    printf 'remove: dry-run: nothing removed; --apply removes these entries\n'
    return 0
  fi

  if [ -z "$stage" ]; then
    stage="$(mktemp -u "$releases/.tmp.remove.$version.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    release_store_write_snapshot_owner "$stage" || return "$?"
  fi
  if [ "$installed" = true ]; then
    release_store_rename_no_clobber "$releases/$version" "$stage" || {
      rc=$?
      rm -f "$stage.owner.json"
      return "$rc"
    }
    how=staged
    held[0]="$stage"
    remove_release_references "$home" "$version" "$stage" "${held[@]}" > "$refusals"
    if [ -s "$refusals" ]; then
      if release_store_rename_no_clobber "$stage" "$releases/$version"; then
        rm -f "$stage.owner.json"
      else
        release_err "could not restore $version from its removal stage $stage"
      fi
      remove_report_refusals "$version" "$refusals"
      return "$?"
    fi
  elif [ "$how" = resumed ]; then
    # A resumed stage may already be partly deleted: never publish it again.
    remove_release_references "$home" "$version" "$stage" "${held[@]}" > "$refusals"
    if [ -s "$refusals" ]; then
      remove_report_refusals "$version" "$refusals"
      return "$?"
    fi
  fi
  release_store_remove_entries finish "$version" "${stage##*/}" "$how" > "$rows" || return "$?"
  remove_report_rows "$version" "$rows" removed
  { rm -f "$lock/remove.owner.json" && rmdir "$lock"; } || {
    release_err "could not release the release store lock: $lock"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  lock=''
)


run_install() {
  local version='' remote='' remote_seen=false arg home
  [ "$#" -ge 1 ] || { usage_error 'install requires VERSION'; return $?; }
  version="$1"; shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --remote)
        [ "$remote_seen" = false ] || { usage_error 'install accepts one --remote'; return $?; }
        shift
        [ "$#" -gt 0 ] || { usage_error '--remote requires URL'; return $?; }
        [ -n "$1" ] || { usage_error '--remote requires a non-empty URL'; return $?; }
        remote="$1"
        remote_seen=true
        ;;
      --remote=*)
        [ "$remote_seen" = false ] || { usage_error 'install accepts one --remote'; return $?; }
        remote="${arg#--remote=}"
        [ -n "$remote" ] || { usage_error '--remote requires a non-empty URL'; return $?; }
        remote_seen=true
        ;;
      *) usage_error "unknown install option: $arg"; return $? ;;
    esac
    shift
  done
  release_store_normalize_version "$version" >/dev/null || return "$?"
  home="$(release_home)" || return "$?"
  export TRELLIS_HOME="$home"
  if [ "$remote_seen" = false ]; then
    remote="$(configured_remote "$home")" || return "$?"
  else
    trellis_home_require_safe_text 'release remote' "$remote" || return "$?"
  fi
  release_store_install "$version" "$remote" ''
}

run_verify() {
  local home
  [ "$#" -le 1 ] || { usage_error 'verify accepts at most VERSION'; return $?; }
  home="$(release_home)" || return "$?"
  export TRELLIS_HOME="$home"
  if [ "$#" -eq 1 ]; then release_store_verify "$1"; else release_store_verify; fi
}

run_locate() {
  local home
  [ "$#" -eq 1 ] || { usage_error 'locate requires VERSION'; return $?; }
  home="$(release_home)" || return "$?"
  export TRELLIS_HOME="$home"
  release_store_locate "$1"
}

run_list() {
  local home
  [ "$#" -eq 0 ] || { usage_error 'list accepts no arguments'; return $?; }
  home="$(release_home)" || return "$?"
  export TRELLIS_HOME="$home"
  release_store_list
}

run_reap_tmp() {
  local mode=dry-run home
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fix)
        [ "$mode" = dry-run ] || { usage_error 'reap-tmp accepts one --fix'; return $?; }
        mode=fix
        ;;
      *) usage_error "unknown reap-tmp option: $1"; return $? ;;
    esac
    shift
  done
  home="$(release_home)" || return "$?"
  export TRELLIS_HOME="$home"
  release_store_reap_tmp "$mode"
}

run_remove() {
  local version='' mode='' arg home
  [ "$#" -ge 1 ] || { usage_error 'remove requires VERSION'; return $?; }
  version="$1"; shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --dry-run|--apply)
        [ -z "$mode" ] || { usage_error 'remove accepts one of --dry-run or --apply'; return $?; }
        mode="${arg#--}"
        ;;
      *) usage_error "unknown remove option: $arg"; return $? ;;
    esac
    shift
  done
  version="$(release_store_normalize_version "$version")" || return "$?"
  home="$(release_home)" || return "$?"
  export TRELLIS_HOME="$home"
  remove_release "$home" "$version" "${mode:-dry-run}"
}

run_adopt() {
  local version='' project='' fleet='' anchor='' all=false selector='' arg home
  local project_seen=false fleet_seen=false anchor_seen=false
  [ "$#" -ge 1 ] || { usage_error 'adopt requires VERSION'; return $?; }
  version="$1"; shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --project)
        [ "$project_seen" = false ] || { usage_error 'adopt accepts one --project'; return $?; }
        shift
        [ "$#" -gt 0 ] || { usage_error '--project requires ID'; return $?; }
        [ -n "$1" ] || { usage_error '--project requires a non-empty ID'; return $?; }
        project="$1"
        project_seen=true
        ;;
      --project=*)
        [ "$project_seen" = false ] || { usage_error 'adopt accepts one --project'; return $?; }
        project="${arg#--project=}"
        [ -n "$project" ] || { usage_error '--project requires a non-empty ID'; return $?; }
        project_seen=true
        ;;
      --fleet)
        [ "$fleet_seen" = false ] || { usage_error 'adopt accepts one --fleet'; return $?; }
        shift
        [ "$#" -gt 0 ] || { usage_error '--fleet requires NAME'; return $?; }
        [ -n "$1" ] || { usage_error '--fleet requires a non-empty NAME'; return $?; }
        fleet="$1"
        fleet_seen=true
        ;;
      --fleet=*)
        [ "$fleet_seen" = false ] || { usage_error 'adopt accepts one --fleet'; return $?; }
        fleet="${arg#--fleet=}"
        [ -n "$fleet" ] || { usage_error '--fleet requires a non-empty NAME'; return $?; }
        fleet_seen=true
        ;;
      --all)
        [ "$all" = false ] || { usage_error 'adopt accepts one selector'; return $?; }
        all=true
        ;;
      --runtime-anchor)
        [ "$anchor_seen" = false ] || { usage_error 'adopt accepts one --runtime-anchor'; return $?; }
        shift
        [ "$#" -gt 0 ] || { usage_error '--runtime-anchor requires PATH'; return $?; }
        [ -n "$1" ] || { usage_error '--runtime-anchor requires a non-empty PATH'; return $?; }
        anchor="$1"
        anchor_seen=true
        ;;
      --runtime-anchor=*)
        [ "$anchor_seen" = false ] || { usage_error 'adopt accepts one --runtime-anchor'; return $?; }
        anchor="${arg#--runtime-anchor=}"
        [ -n "$anchor" ] || { usage_error '--runtime-anchor requires a non-empty PATH'; return $?; }
        anchor_seen=true
        ;;
      *) usage_error "unknown adopt option: $arg"; return $? ;;
    esac
    shift
  done
  release_store_normalize_version "$version" >/dev/null || return "$?"
  # Names this command in the attachment library's refusal lines.
  # shellcheck disable=SC2034  # Read by scripts/lib/attachment.sh.
  ATTACHMENT_ACTION=adopt
  if [ "$anchor_seen" = true ]; then
    [ "$project_seen" = false ] && [ "$fleet_seen" = false ] && [ "$all" = false ] || { usage_error '--runtime-anchor cannot be combined with registry selectors'; return $?; }
    home="$(release_home)" || return "$?"
    export TRELLIS_HOME="$home"
    release_err 'WARNING: --runtime-anchor is compatibility-only; use --project, --fleet, or --all for managed adoption'
    release_store_adopt_runtime_anchor "$version" "$anchor"
    return "$?"
  fi
  if [ "$project_seen" = true ]; then
    local_registry_require_project_id "$project" || return "$?"
    if [ "$fleet_seen" = true ]; then trellis_home_require_fleet_name "$fleet" || return "$?"; fi
    [ "$all" = false ] || { usage_error '--all cannot be combined with --project'; return $?; }
    selector=project
  elif [ "$fleet_seen" = true ]; then
    trellis_home_require_fleet_name "$fleet" || return "$?"
    [ "$all" = false ] || { usage_error '--all cannot be combined with --fleet'; return $?; }
    selector=fleet
  elif [ "$all" = true ]; then
    selector=all
  else
    usage_error 'adopt requires --project, --fleet, --all, or compatibility --runtime-anchor'
    return $?
  fi
  adopt_registry "$version" "$selector" "$fleet" "$project"
}

release_command_main() {
  release_requires_verified_payload || {
    release_err 'direct source execution is unsupported; run trellis release from the installed stable launcher'
    return "$TRELLIS_EX_USAGE"
  }
  release_prepare_verified_ssh_auth_sock || {
    release_err 'verified SSH_AUTH_SOCK marker is invalid or unavailable'
    return "$TRELLIS_EX_STATE"
  }

  case "${1:-help}" in
    install) shift; run_install "$@" ;;
    list) shift; run_list "$@" ;;
    locate) shift; run_locate "$@" ;;
    verify) shift; run_verify "$@" ;;
    reap-tmp) shift; run_reap_tmp "$@" ;;
    remove) shift; run_remove "$@" ;;
    adopt) shift; run_adopt "$@" ;;
    help|--help|-h) usage ;;
    *) usage_error "unknown command: $1" ;;
  esac
}

# Upgrade bundles preload this command's helpers and functions, then invoke the
# command function without ever reopening a release-script pathname.
if [ "${TRELLIS_RELEASE_BUNDLE_PRELOAD:-}" != 1 ]; then
  release_command_main "$@"
  exit $?
fi
