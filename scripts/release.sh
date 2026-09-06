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
  local original="$1" replacement="$2" version="$3" payload="$4"
  jq --arg version "$version" --arg payload "$payload" '
    if ([.artifacts[] | select(.path == ".trellis/runtime" and .kind == "symlink")] | length) != 1
    then error("missing owned runtime anchor")
    else .release = $version
      | .artifacts |= map(if .path == ".trellis/runtime" then .target = $payload else . end)
    end
  ' "$original" > "$replacement" || return "$TRELLIS_EX_STATE"
  chmod 600 "$replacement" || return "$TRELLIS_EX_UNAVAILABLE"
  _attachment_owner_json_valid "$replacement" || return "$TRELLIS_EX_STATE"
}

replace_owned_file() (
  local destination="$1" expected="$2" replacement="$3" parent base actual_parent temporary=''
  local temporary_identity='' destination_identity='' committed=false rc

  replace_owned_file_cleanup() {
    local status="${1:-$?}" rollback=0 cleanup_status=0
    trap - EXIT
    trap '' HUP INT TERM

    if [ -n "$temporary" ]; then
      if [ "$committed" = true ]; then
        if [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
          _attachment_identity_matches "$temporary" "$destination_identity" file &&
          _attachment_mode_matches "$temporary" 600 &&
          cmp -s "$expected" "$temporary"; then
          rm "$temporary" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
          [ "$cleanup_status" -eq 0 ] && temporary=''
        else
          cleanup_status="$TRELLIS_EX_CONFLICT"
        fi
      elif [ -f "$destination" ] && [ ! -L "$destination" ] &&
        _attachment_identity_matches "$destination" "$temporary_identity" file &&
        _attachment_mode_matches "$destination" 600 &&
        cmp -s "$replacement" "$destination"; then
        release_store_rename_swap "$temporary" "$destination"
        rollback=$?
        if [ "$rollback" -eq 0 ]; then
          if [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
            _attachment_identity_matches "$temporary" "$temporary_identity" file &&
            _attachment_mode_matches "$temporary" 600 &&
            cmp -s "$replacement" "$temporary"; then
            rm "$temporary" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
            [ "$cleanup_status" -eq 0 ] && temporary=''
          else
            cleanup_status="$TRELLIS_EX_CONFLICT"
          fi
        else
          cleanup_status="$(max_status "$cleanup_status" "$rollback")"
        fi
      elif [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
        _attachment_identity_matches "$temporary" "$temporary_identity" file &&
        _attachment_mode_matches "$temporary" 600 &&
        cmp -s "$replacement" "$temporary"; then
        rm "$temporary" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
        [ "$cleanup_status" -eq 0 ] && temporary=''
      else
        cleanup_status="$TRELLIS_EX_CONFLICT"
      fi
    fi
    [ "$cleanup_status" -eq 0 ] || status="$(max_status "$status" "$cleanup_status")"
    exit "$status"
  }
  trap 'replace_owned_file_cleanup "$?"' EXIT
  trap 'exit "$TRELLIS_EX_UNAVAILABLE"' HUP INT TERM

  [ -f "$expected" ] && [ ! -L "$expected" ] || return "$TRELLIS_EX_CONFLICT"
  [ -f "$replacement" ] && [ ! -L "$replacement" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_mode_matches "$expected" 600 || return "$TRELLIS_EX_CONFLICT"
  parent="$(dirname "$destination")" || return "$TRELLIS_EX_STATE"
  base="$(basename "$destination")" || return "$TRELLIS_EX_STATE"
  _attachment_canonical_dir "$parent" || return "$TRELLIS_EX_CONFLICT"
  CDPATH='' cd "$parent" || return "$TRELLIS_EX_CONFLICT"
  actual_parent="$(pwd -P)" || return "$TRELLIS_EX_CONFLICT"
  [ "$actual_parent" = "$parent" ] || return "$TRELLIS_EX_CONFLICT"
  destination="./$base"
  [ -f "$destination" ] && [ ! -L "$destination" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_mode_matches "$destination" 600 || return "$TRELLIS_EX_CONFLICT"
  cmp -s "$expected" "$destination" || return "$TRELLIS_EX_CONFLICT"
  destination_identity="$(_attachment_fs_identity "$destination")" || return "$TRELLIS_EX_UNAVAILABLE"
  temporary="$(mktemp "./.${base}.release-adopt.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -f "$temporary" ] && [ ! -L "$temporary" ] || return "$TRELLIS_EX_CONFLICT"
  chmod 600 "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  cat "$replacement" > "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 600 "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
    _attachment_mode_matches "$temporary" 600 &&
    cmp -s "$replacement" "$temporary" || return "$TRELLIS_EX_CONFLICT"
  temporary_identity="$(_attachment_fs_identity "$temporary")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -f "$destination" ] && [ ! -L "$destination" ] &&
    _attachment_identity_matches "$destination" "$destination_identity" file &&
    _attachment_mode_matches "$destination" 600 &&
    cmp -s "$expected" "$destination" || return "$TRELLIS_EX_CONFLICT"
  release_store_rename_swap "$temporary" "$destination"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! { [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
    _attachment_identity_matches "$temporary" "$destination_identity" file &&
    _attachment_mode_matches "$temporary" 600 &&
    cmp -s "$expected" "$temporary"; } ||
    ! { [ -f "$destination" ] && [ ! -L "$destination" ] &&
    _attachment_identity_matches "$destination" "$temporary_identity" file &&
    _attachment_mode_matches "$destination" 600 &&
    cmp -s "$replacement" "$destination"; }; then
    return "$TRELLIS_EX_CONFLICT"
  fi
  committed=true
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
  _attachment_hooks_verify_passthrough_shims "$managed" "$root" "$previous" ||
    return "$TRELLIS_EX_CONFLICT"
}

write_hook_state_file() {
  local path="$1" contents="$2" mode="$3"
  printf '%s\n' "$contents" > "$path" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod "$mode" "$path" || return "$TRELLIS_EX_UNAVAILABLE"
}


replace_hook_payload() (
  local managed="${1:-}" expected="${2:-}" replacement="${3:-}" root="${4:-}"
  local hooks_root base temporary='' source previous manifest rc committed=false expected_shims shim_name shim_body post_checkout pre_push

  release_hook_transaction_cleanup() {
    local status="${1:-$?}" rollback=0 temporary_expected=''
    trap - EXIT
    trap '' HUP INT TERM

    # An interruption can land while the kernel exchange is in flight, before
    # the shell observes its return. Determine the actual pair of states rather
    # than relying on a post-exchange flag: either state keeps $managed valid.
    if [ "$committed" != true ] && [ -n "$temporary" ] &&
      [ -d "$temporary" ] && [ ! -L "$temporary" ] &&
      [ -d "$managed" ] && [ ! -L "$managed" ]; then
      if hook_payload_matches "$managed" "$expected" "$root" &&
        hook_payload_matches "$temporary" "$replacement" "$root"; then
        :
      elif hook_payload_matches "$managed" "$replacement" "$root" &&
        hook_payload_matches "$temporary" "$expected" "$root"; then
        release_store_rename_swap "$temporary" "$managed" || rollback=$?
      else
        rollback="$TRELLIS_EX_CONFLICT"
      fi
    fi

    if [ "$committed" = true ]; then
      temporary_expected="$expected"
    else
      temporary_expected="$replacement"
    fi
    if [ -n "$temporary" ] && { [ -e "$temporary" ] || [ -L "$temporary" ]; }; then
      if [ "$rollback" -eq 0 ] &&
        [ -d "$temporary" ] && [ ! -L "$temporary" ] &&
        hook_payload_matches "$temporary" "$temporary_expected" "$root"; then
        rm -rf "$temporary" || rollback="$TRELLIS_EX_UNAVAILABLE"
      else
        [ "$rollback" -ne 0 ] || rollback="$TRELLIS_EX_CONFLICT"
      fi
    fi
    [ "$rollback" -eq 0 ] || status="$(max_status "$status" "$rollback")"
    exit "$status"
  }

  trap 'release_hook_transaction_cleanup "$?"' EXIT
  trap 'exit "$TRELLIS_EX_STATE"' HUP INT TERM

  [ "$#" -eq 4 ] && [ -n "$managed" ] && [ -n "$expected" ] && [ -n "$replacement" ] && [ -n "$root" ] ||
    exit "$TRELLIS_EX_USAGE"
  hook_payload_matches "$managed" "$expected" "$root" || exit "$?"
  hooks_root="$(dirname "$managed")" || exit "$TRELLIS_EX_STATE"
  base="$(basename "$managed")" || exit "$TRELLIS_EX_STATE"
  [ -d "$hooks_root" ] && [ ! -L "$hooks_root" ] || exit "$TRELLIS_EX_CONFLICT"
  source="$(_attachment_hooks_read_sidecar "$managed/pre-push-source")" || exit "$TRELLIS_EX_CONFLICT"
  previous="$(_attachment_hooks_read_sidecar "$managed/previous-hooks-path" true)" || exit "$TRELLIS_EX_CONFLICT"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$replacement")" || exit "$TRELLIS_EX_STATE"
  # Validate both replacement programs before allocating or exchanging state.
  if ! post_checkout="$(_attachment_hooks_post_checkout_dispatcher_body "$replacement" "$manifest")" ||
     ! pre_push="$(_attachment_hooks_pre_push_dispatcher_body "$replacement" "$source" "$manifest")" ||
     [ -z "$post_checkout" ] || [ -z "$pre_push" ]; then
    release_err "managed hook generation failed; current dispatcher was preserved"
    exit "$TRELLIS_EX_STATE"
  fi
  temporary="$(mktemp -d "$hooks_root/.${base}.release-adopt.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  chmod 700 "$temporary" || exit "$TRELLIS_EX_UNAVAILABLE"
  write_hook_state_file "$temporary/post-checkout" "$post_checkout" 700 ||
    exit "$?"
  write_hook_state_file "$temporary/pre-push" "$pre_push" 700 ||
    exit "$?"
  write_hook_state_file "$temporary/previous-hooks-path" "$previous" 600 || exit "$?"
  write_hook_state_file "$temporary/release-payload" "$replacement" 600 || exit "$?"
  write_hook_state_file "$temporary/pre-push-source" "$source" 600 || exit "$?"
  expected_shims=$(_attachment_hooks_expected_passthrough_names "$root" "$previous") || exit "$TRELLIS_EX_UNAVAILABLE"
  while IFS= read -r shim_name; do
    [ -n "$shim_name" ] || continue
    shim_body=$(_attachment_hooks_passthrough_shim_body "$shim_name") || exit "$TRELLIS_EX_STATE"
    write_hook_state_file "$temporary/$shim_name" "$shim_body" 700 || exit "$?"
  done <<<"$expected_shims"

  # Both paths are siblings under $hooks_root, so the release-store primitive
  # performs one same-filesystem exchange and never unlinks core.hooksPath.
  release_store_rename_swap "$temporary" "$managed"
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  hook_payload_matches "$temporary" "$expected" "$root" || exit "$?"
  hook_payload_matches "$managed" "$replacement" "$root" || exit "$?"
  committed=true
  rm -rf "$temporary" || exit "$TRELLIS_EX_UNAVAILABLE"
  temporary=''
  exit 0
)

adoption_render_owned_parents_valid() {
  local file="$1" keys="$2"
  jq -e --argjson keys "$keys" '
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
  # Owned keys the new template no longer carries are replayed back into the
  # candidate below (add-only by design); record them so the adoption summary
  # can say they were left in place instead of reporting silent no-drift.
  # An owned path counts as present when it equals a template leaf or is a
  # strict prefix of one (the template nested a subtree beneath it).
  template_dropped='[]'
  if [ -n "$new_payload" ]; then
    template_leaves="$(adoption_new_template_leaves "$new_payload" "$relative")" || template_leaves='{"found":false,"leaves":[]}'
    if [ "$(printf '%s\n' "$template_leaves" | jq -r '.found // false' 2>/dev/null)" = true ]; then
      template_dropped="$(jq -cn --argjson keys "$keys" --argjson template "$template_leaves" '
        ($template.leaves | map(.path)) as $tpaths
        | [($keys | map(.path))[]
           | select(. as $owned
             | (([$tpaths[] | select(. == $owned or (.[0:($owned | length)] == $owned))] | length) == 0))]
      ' 2>/dev/null)" || template_dropped='[]'
    fi
  fi

  jq --argjson keys "$keys" '
    reduce $keys[] as $owned (. ; setpath($owned.path; $owned.value))
  ' "$source" > "$candidate" || return "$TRELLIS_EX_CONFLICT"
  chmod "${after_mode#0}" "$candidate" || return "$TRELLIS_EX_UNAVAILABLE"
  jq -e 'type == "object"' "$candidate" >/dev/null 2>&1 || return "$TRELLIS_EX_CONFLICT"
  attach_detach_json_keys_match "$candidate" "$keys" || return "$TRELLIS_EX_CONFLICT"
  candidate_identity="$(_attachment_fs_identity "$candidate")" || return "$TRELLIS_EX_UNAVAILABLE"
  candidate_hash="$(_attachment_hash "$candidate")" || return "$TRELLIS_EX_UNAVAILABLE"

  jq -cn --argjson render "$render" --arg path "$relative" --arg destination "$destination" \
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
  local temporary_identity='' committed=false rc

  adoption_publish_render_cleanup() {
    local status="${1:-$?}" rollback=0 cleanup_status=0
    trap - EXIT
    trap '' HUP INT TERM

    if [ -n "$temporary" ]; then
      if [ "$committed" = true ]; then
        if adoption_render_live_matches "$temporary" "$expected" "$expected_identity" "$expected_hash" "$expected_mode"; then
          rm "$temporary" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
          [ "$cleanup_status" -eq 0 ] && temporary=''
        else
          cleanup_status="$TRELLIS_EX_CONFLICT"
        fi
      elif adoption_render_live_matches "$destination" "$replacement" '' "$replacement_hash" "$replacement_mode" &&
        _attachment_identity_matches "$destination" "$temporary_identity" file; then
        release_store_rename_swap "$temporary" "$destination"
        rollback=$?
        if [ "$rollback" -eq 0 ]; then
          if _attachment_identity_matches "$temporary" "$temporary_identity" file &&
            adoption_render_live_matches "$temporary" "$replacement" '' "$replacement_hash" "$replacement_mode"; then
            rm "$temporary" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
            [ "$cleanup_status" -eq 0 ] && temporary=''
          else
            cleanup_status="$TRELLIS_EX_CONFLICT"
          fi
        else
          cleanup_status="$(max_status "$cleanup_status" "$rollback")"
        fi
      elif _attachment_identity_matches "$temporary" "$temporary_identity" file &&
        adoption_render_live_matches "$temporary" "$replacement" '' "$replacement_hash" "$replacement_mode"; then
        rm "$temporary" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
        [ "$cleanup_status" -eq 0 ] && temporary=''
      else
        cleanup_status="$TRELLIS_EX_CONFLICT"
      fi
    fi
    [ "$cleanup_status" -eq 0 ] || status="$(max_status "$status" "$cleanup_status")"
    exit "$status"
  }

  trap 'adoption_publish_render_cleanup "$?"' EXIT
  trap 'exit "$TRELLIS_EX_UNAVAILABLE"' HUP INT TERM

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
  temporary="$(mktemp "./.${base}.release-adopt-render.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -f "$temporary" ] && [ ! -L "$temporary" ] || return "$TRELLIS_EX_CONFLICT"
  cat "$replacement" > "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod "${replacement_mode#0}" "$temporary" || return "$TRELLIS_EX_UNAVAILABLE"
  adoption_render_live_matches "$temporary" "$replacement" '' "$replacement_hash" "$replacement_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  temporary_identity="$(_attachment_fs_identity "$temporary")" || return "$TRELLIS_EX_UNAVAILABLE"
  adoption_render_live_matches "$destination" "$expected" "$expected_identity" "$expected_hash" "$expected_mode" ||
    return "$TRELLIS_EX_CONFLICT"
  release_store_rename_swap "$temporary" "$destination"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! adoption_render_live_matches "$temporary" "$expected" "$expected_identity" "$expected_hash" "$expected_mode" ||
    ! { _attachment_identity_matches "$destination" "$temporary_identity" file &&
    adoption_render_live_matches "$destination" "$replacement" '' "$replacement_hash" "$replacement_mode"; }; then
    return "$TRELLIS_EX_CONFLICT"
  fi
  committed=true
  return 0
)

preflight_target() {
  local home="$1" new_version="$2" new_payload="$3" row="$4" work="$5" number="$6"
  local target binding identity root root_identity trellis_identity checkout owner old_version old_payload old_owner new_owner hooks managed source reconcile carrier hook_authority
  local renders='[]' render render_plan index=0

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

  old_owner="$work/$number.old.json"
  new_owner="$work/$number.new.json"
  cp "$owner" "$old_owner" && chmod 600 "$old_owner" || return "$TRELLIS_EX_UNAVAILABLE"
  owner_replacement "$old_owner" "$new_owner" "$new_version" "$new_payload" || return "$?"
  while IFS= read -r render; do
    index=$((index + 1))
    render_plan="$(adoption_snapshot_render "$root" "$render" "$work" "$number" "$index" "$new_payload")" || return "$?"
    renders="$(jq -cn --argjson current "$renders" --argjson planned "$render_plan" '$current + [$planned]')" ||
      return "$TRELLIS_EX_STATE"
  done < <(jq -c '(.renders // [])[]' "$old_owner")

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

  jq -cn \
    --argjson row "$row" --argjson binding "$binding" --argjson identity "$identity" \
    --arg owner "$owner" --arg old_owner "$old_owner" --arg new_owner "$new_owner" \
    --arg old_version "$old_version" --arg old_payload "$old_payload" \
    --arg new_version "$new_version" --arg new_payload "$new_payload" \
    --arg root_identity "$root_identity" --arg trellis_identity "$trellis_identity" \
    --arg hooks "$hooks" --arg managed "$managed" --arg hook_authority "$hook_authority" \
    --argjson renders "$renders" \
    '{row:$row,binding:$binding,identity:$identity,owner:$owner,old_owner:$old_owner,new_owner:$new_owner,
      old_version:$old_version,old_payload:$old_payload,new_version:$new_version,new_payload:$new_payload,
      root_identity:$root_identity,trellis_identity:$trellis_identity,hooks:$hooks,managed:$managed,
      hook_authority:$hook_authority,renders:$renders}'
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
  local planned_render drift_count
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
  replace_owned_file "$owner" "$old_owner" "$new_owner"
}

rollback_plan() {
  local plan="$1" root root_identity trellis_identity owner old_owner new_owner old_version old_payload new_payload
  local planned_render destination source source_hash source_mode candidate candidate_hash candidate_mode
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

adopt_group() (
  local home="$1" version="$2" payload="$3" rows="$4" work="$5"
  local plans="$work/plans.jsonl" changed="$work/changed.jsonl" changed_hooks="$work/changed-hooks.jsonl"
  local row plan first checkout common rc=0 number=0 label planned_render repair render_path json_path repair_state dropped_key
  local owner planned_hook_authority current_hook_authority
  local lock_held=false committed=false cleanup_started=false active_plan='' active_hook_plan=''

  adopt_group_cleanup() {
    local status="${1:-$?}" cleanup_rc=0 one
    trap - EXIT
    trap '' HUP INT TERM
    [ "$cleanup_started" = true ] && return "$status"
    cleanup_started=true

    if [ "$committed" != true ] && [ "$lock_held" = true ]; then
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

  IFS= read -r first < "$plans" || return "$TRELLIS_EX_STATE"
  checkout="$(printf '%s\n' "$first" | jq -r '.binding.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$first" | jq -r '.binding.git_common_dir')" || return "$TRELLIS_EX_STATE"
  attachment_checkout_lock_reclaim "$home" "$checkout" "$common" || return "$?"
  attachment_checkout_lock_acquire "$home" "$checkout" "$common" || return "$?"
  lock_held=true
  trap 'adopt_group_exit "$?"' EXIT
  trap 'adopt_group_signal' HUP INT TERM

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

  update_group_registry "$home" "$plans" "$version" || return "$?"
  committed=true
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

  local_registry_list_json "$home" > "$inventory" || return "$?"
  if [ "$selector" = project ] && [ -z "$fleet" ]; then
    local fleet_count
    fleet_count="$(jq -r --arg project "$project" '[.entries[]? | select(.project_id == $project) | .fleet] | unique | length' "$inventory")" || return "$TRELLIS_EX_STATE"
    case "$fleet_count" in
      0) ;;
      1) fleet="$(jq -r --arg project "$project" '[.entries[]? | select(.project_id == $project) | .fleet] | unique[0]' "$inventory")" || return "$TRELLIS_EX_STATE" ;;
      *) release_err "project selector is ambiguous across fleets: $project"; return "$TRELLIS_EX_CONFLICT" ;;
    esac
  fi
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
