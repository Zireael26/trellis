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
  exec /usr/bin/env -i \
    "HOME=$release_bootstrap_home" "TRELLIS_HOME=$release_bootstrap_trellis_home" \
    "TRELLIS_VERIFIED_PAYLOAD=$release_bootstrap_payload" \
    "TRELLIS_VERIFIED_RELEASE_VERSION=$release_bootstrap_version" \
    "TRELLIS_VERIFIED_SSH_AUTH_SOCK=$release_bootstrap_socket" \
    "TRELLIS_RELEASE_CLEAN_ENV=1" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash --noprofile --norc "$0" "$@"
fi
unset TRELLIS_RELEASE_CLEAN_ENV
set -u

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

if [ "$release_bundle_mode" = true ]; then
  for release_bundle_function in \
    trellis_home_resolve \
    release_store_normalize_version \
    local_registry_list_json \
    attachment_verify; do
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
    def harness($path):
      if $path == "AGENTS.md" or ($path | startswith(".agents/")) or ($path | startswith(".codex/")) then "codex"
      elif $path | startswith(".claude/") then "claude"
      elif $path | startswith(".omp/") then "omp"
      else empty end;
    {fleet,project_id,root:.worktree_root,checkout_id,worktree_id,attachment_id,release,
     harnesses:([.artifacts[] | harness(.path)] | unique | sort)}
  ' "$owner" 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  [ "$actual" = "$expected" ] || return "$TRELLIS_EX_CONFLICT"
  owner_root="$(jq -r '.project_root' "$owner")" || return "$TRELLIS_EX_STATE"
  printf '%s\n' "$identity" | jq -e --arg owner_root "$owner_root" '.root == $owner_root' >/dev/null 2>&1 ||
    return "$TRELLIS_EX_CONFLICT"
  jq -e --arg payload "$payload" '
    ([.artifacts[] | select(.path == ".trellis/runtime" and .kind == "symlink" and .target == $payload)] | length) == 1
  ' "$owner" >/dev/null 2>&1
}

resolve_verified_adoption_target() {
  local home="$1" row="$2" binding root trellis root_identity trellis_identity identity current manifest_project_id project_id checkout worktree owner release payload status
  binding="$(adoption_binding_from_row "$row")" || return "$?"
  root="$(printf '%s\n' "$binding" | jq -r '.root')" || return "$TRELLIS_EX_STATE"
  identity="$(local_registry_identity_for_root "$root")" || return "$?"
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
  attachment_verify "$home" "$owner" || return "$?"
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
    '{binding:$binding,identity:$identity,owner:$owner,old_version:$old_version,old_payload:$old_payload,
      root_identity:$root_identity,trellis_identity:$trellis_identity}'
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

replace_owned_file() {
  local destination="$1" expected="$2" replacement="$3" parent base temporary
  [ -f "$destination" ] && [ ! -L "$destination" ] || return "$TRELLIS_EX_CONFLICT"
  cmp -s "$expected" "$destination" || return "$TRELLIS_EX_CONFLICT"
  parent="$(dirname "$destination")" || return "$TRELLIS_EX_STATE"
  base="$(basename "$destination")" || return "$TRELLIS_EX_STATE"
  [ -d "$parent" ] && [ ! -L "$parent" ] || return "$TRELLIS_EX_CONFLICT"
  temporary="$(mktemp "$parent/.${base}.release-adopt.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 600 "$temporary" || { rm -f "$temporary"; return "$TRELLIS_EX_UNAVAILABLE"; }
  cat "$replacement" > "$temporary" || { rm -f "$temporary"; return "$TRELLIS_EX_UNAVAILABLE"; }
  mv -f "$temporary" "$destination" || { rm -f "$temporary"; return "$TRELLIS_EX_UNAVAILABLE"; }
}

hook_payload_matches() {
  local managed="$1" expected="$2" sidecar mode source manifest previous
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
  _attachment_hooks_file_matches "$managed/post-checkout" \
    "$(_attachment_hooks_post_checkout_dispatcher_body "$expected" "$manifest")" 700 ||
    return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_file_matches "$managed/pre-push" \
    "$(_attachment_hooks_pre_push_dispatcher_body "$expected" "$source" "$manifest")" 700 ||
    return "$TRELLIS_EX_CONFLICT"
}

write_hook_state_file() {
  local path="$1" contents="$2" mode="$3"
  printf '%s\n' "$contents" > "$path" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod "$mode" "$path" || return "$TRELLIS_EX_UNAVAILABLE"
}


replace_hook_payload() (
  local managed="${1:-}" expected="${2:-}" replacement="${3:-}"
  local hooks_root base temporary='' source previous manifest rc committed=false

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
      if hook_payload_matches "$managed" "$expected" &&
        hook_payload_matches "$temporary" "$replacement"; then
        :
      elif hook_payload_matches "$managed" "$replacement" &&
        hook_payload_matches "$temporary" "$expected"; then
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
        hook_payload_matches "$temporary" "$temporary_expected"; then
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

  [ "$#" -eq 3 ] && [ -n "$managed" ] && [ -n "$expected" ] && [ -n "$replacement" ] ||
    exit "$TRELLIS_EX_USAGE"
  hook_payload_matches "$managed" "$expected" || exit "$?"
  hooks_root="$(dirname "$managed")" || exit "$TRELLIS_EX_STATE"
  base="$(basename "$managed")" || exit "$TRELLIS_EX_STATE"
  [ -d "$hooks_root" ] && [ ! -L "$hooks_root" ] || exit "$TRELLIS_EX_CONFLICT"
  source="$(_attachment_hooks_read_sidecar "$managed/pre-push-source")" || exit "$TRELLIS_EX_CONFLICT"
  previous="$(_attachment_hooks_read_sidecar "$managed/previous-hooks-path" true)" || exit "$TRELLIS_EX_CONFLICT"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$replacement")" || exit "$TRELLIS_EX_STATE"
  temporary="$(mktemp -d "$hooks_root/.${base}.release-adopt.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  chmod 700 "$temporary" || exit "$TRELLIS_EX_UNAVAILABLE"
  write_hook_state_file "$temporary/post-checkout" \
    "$(_attachment_hooks_post_checkout_dispatcher_body "$replacement" "$manifest")" 700 ||
    exit "$?"
  write_hook_state_file "$temporary/pre-push" \
    "$(_attachment_hooks_pre_push_dispatcher_body "$replacement" "$source" "$manifest")" 700 ||
    exit "$?"
  write_hook_state_file "$temporary/previous-hooks-path" "$previous" 600 || exit "$?"
  write_hook_state_file "$temporary/release-payload" "$replacement" 600 || exit "$?"
  write_hook_state_file "$temporary/pre-push-source" "$source" 600 || exit "$?"

  # Both paths are siblings under $hooks_root, so the release-store primitive
  # performs one same-filesystem exchange and never unlinks core.hooksPath.
  release_store_rename_swap "$temporary" "$managed"
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  hook_payload_matches "$temporary" "$expected" || exit "$?"
  hook_payload_matches "$managed" "$replacement" || exit "$?"
  committed=true
  rm -rf "$temporary" || exit "$TRELLIS_EX_UNAVAILABLE"
  temporary=''
  exit 0
)

preflight_target() {
  local home="$1" new_version="$2" new_payload="$3" row="$4" work="$5" number="$6"
  local target binding identity root_identity trellis_identity checkout owner old_version old_payload old_owner new_owner hooks managed source reconcile carrier

  target="$(resolve_verified_adoption_target "$home" "$row")" || return "$?"
  binding="$(printf '%s\n' "$target" | jq -cS '.binding')" || return "$TRELLIS_EX_STATE"
  identity="$(printf '%s\n' "$target" | jq -cS '.identity')" || return "$TRELLIS_EX_STATE"
  checkout="$(printf '%s\n' "$binding" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  owner="$(printf '%s\n' "$target" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
  old_version="$(printf '%s\n' "$target" | jq -r '.old_version')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$target" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  root_identity="$(printf '%s\n' "$target" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  trellis_identity="$(printf '%s\n' "$target" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"

  old_owner="$work/$number.old.json"
  new_owner="$work/$number.new.json"
  cp "$owner" "$old_owner" && chmod 600 "$old_owner" || return "$TRELLIS_EX_UNAVAILABLE"
  owner_replacement "$old_owner" "$new_owner" "$new_version" "$new_payload" || return "$?"

  hooks="$(jq -r '.git_hooks.enabled // false' "$owner")" || return "$TRELLIS_EX_STATE"
  managed=""
  case "$hooks" in
    true)
      managed="$(jq -r '.git_hooks.managed_hooks_path // empty' "$owner")" || return "$TRELLIS_EX_STATE"
      [ "$managed" = "$home/state/git-hooks/$checkout" ] || return "$TRELLIS_EX_CONFLICT"
      hook_payload_matches "$managed" "$old_payload" || return "$?"
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
    --arg hooks "$hooks" --arg managed "$managed" \
    '{row:$row,binding:$binding,identity:$identity,owner:$owner,old_owner:$old_owner,new_owner:$new_owner,
      old_version:$old_version,old_payload:$old_payload,new_version:$new_version,new_payload:$new_payload,
      root_identity:$root_identity,trellis_identity:$trellis_identity,hooks:$hooks,managed:$managed}'
}

plan_matches_old() {
  local home="$1" plan="$2" row binding planned_identity planned_root_identity planned_trellis_identity target current_binding current_identity current_root_identity current_trellis_identity owner old_owner old_payload old_version new_version new_payload verified_new_payload
  row="$(printf '%s\n' "$plan" | jq -c '.row')" || return "$TRELLIS_EX_STATE"
  binding="$(printf '%s\n' "$plan" | jq -cS '.binding')" || return "$TRELLIS_EX_STATE"
  planned_identity="$(printf '%s\n' "$plan" | jq -cS '.identity')" || return "$TRELLIS_EX_STATE"
  planned_root_identity="$(printf '%s\n' "$plan" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  planned_trellis_identity="$(printf '%s\n' "$plan" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  target="$(resolve_verified_adoption_target "$home" "$row")" || return "$?"
  current_binding="$(printf '%s\n' "$target" | jq -cS '.binding')" || return "$TRELLIS_EX_STATE"
  current_identity="$(printf '%s\n' "$target" | jq -cS '.identity')" || return "$TRELLIS_EX_STATE"
  current_root_identity="$(printf '%s\n' "$target" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  current_trellis_identity="$(printf '%s\n' "$target" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  if [ "$current_binding" != "$binding" ] ||
    [ "$current_identity" != "$planned_identity" ] ||
    [ "$current_root_identity" != "$planned_root_identity" ] ||
    [ "$current_trellis_identity" != "$planned_trellis_identity" ]; then
    release_err 'release adoption target drifted after plan validation'
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
  cmp -s "$old_owner" "$owner"
}

apply_plan() {
  local plan="$1" root root_identity trellis_identity owner old_owner new_owner old_version old_payload new_version new_payload verified_new_payload rc rollback=0
  root="$(printf '%s\n' "$plan" | jq -r '.row.root')" || return "$TRELLIS_EX_STATE"
  root_identity="$(printf '%s\n' "$plan" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  trellis_identity="$(printf '%s\n' "$plan" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  owner="$(printf '%s\n' "$plan" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
  old_owner="$(printf '%s\n' "$plan" | jq -r '.old_owner')" || return "$TRELLIS_EX_STATE"
  new_owner="$(printf '%s\n' "$plan" | jq -r '.new_owner')" || return "$TRELLIS_EX_STATE"
  old_version="$(printf '%s\n' "$plan" | jq -r '.old_version')" || return "$TRELLIS_EX_STATE"
  new_version="$(printf '%s\n' "$plan" | jq -r '.new_version')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"
  verified_new_payload="$(payload_for "$new_version")" || return "$?"
  [ "$verified_new_payload" = "$new_payload" ] || return "$TRELLIS_EX_CONFLICT"
  runtime_anchor_matches_payload "$root/.trellis/runtime" "$old_payload" || return "$?"
  release_store_adopt_runtime_anchor_pinned \
    "$new_version" "$root" "$root_identity" "$trellis_identity" "$old_payload" >/dev/null || return "$?"
  replace_owned_file "$owner" "$old_owner" "$new_owner"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    release_store_adopt_runtime_anchor_pinned \
      "$old_version" "$root" "$root_identity" "$trellis_identity" "$new_payload" >/dev/null || rollback=$?
    return "$(max_status "$rc" "$rollback")"
  fi
}

rollback_plan() {
  local plan="$1" root root_identity trellis_identity owner old_owner new_owner old_version new_version old_payload new_payload
  local owner_state='' anchor_state='' owner_reverted=false rc=0 restore=0
  root="$(printf '%s\n' "$plan" | jq -r '.row.root')" || return "$TRELLIS_EX_STATE"
  root_identity="$(printf '%s\n' "$plan" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  trellis_identity="$(printf '%s\n' "$plan" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  owner="$(printf '%s\n' "$plan" | jq -r '.owner')" || return "$TRELLIS_EX_STATE"
  old_owner="$(printf '%s\n' "$plan" | jq -r '.old_owner')" || return "$TRELLIS_EX_STATE"
  new_owner="$(printf '%s\n' "$plan" | jq -r '.new_owner')" || return "$TRELLIS_EX_STATE"
  old_version="$(printf '%s\n' "$plan" | jq -r '.old_version')" || return "$TRELLIS_EX_STATE"
  new_version="$(printf '%s\n' "$plan" | jq -r '.new_version')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"

  if cmp -s "$old_owner" "$owner"; then owner_state=old
  elif cmp -s "$new_owner" "$owner"; then owner_state=new
  else return "$TRELLIS_EX_CONFLICT"
  fi
  if runtime_anchor_matches_payload "$root/.trellis/runtime" "$old_payload"; then anchor_state=old
  elif runtime_anchor_matches_payload "$root/.trellis/runtime" "$new_payload"; then anchor_state=new
  else return "$TRELLIS_EX_CONFLICT"
  fi
  [ "$owner_state" = old ] && [ "$anchor_state" = old ] && return 0

  # Apply changes runtime then owner, so restore the owner before the runtime.
  if [ "$owner_state" = new ]; then
    replace_owned_file "$owner" "$new_owner" "$old_owner" || return "$?"
    owner_state=old
    owner_reverted=true
  fi
  if [ "$anchor_state" = new ]; then
    release_store_adopt_runtime_anchor_pinned \
      "$old_version" "$root" "$root_identity" "$trellis_identity" "$new_payload" >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$owner_reverted" = true ]; then
        replace_owned_file "$owner" "$old_owner" "$new_owner" || restore=$?
      fi
      return "$(max_status "$rc" "$restore")"
    fi
  fi
  cmp -s "$old_owner" "$owner" &&
    runtime_anchor_matches_payload "$root/.trellis/runtime" "$old_payload"
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
  local plans="$1" changed="$2" plan hooks managed old_payload new_payload seen='|'
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
    active_hook_plan="$plan"
    replace_hook_payload "$managed" "$old_payload" "$new_payload" || return "$?"
    printf '%s\n' "$plan" >> "$changed" || return "$TRELLIS_EX_UNAVAILABLE"
    active_hook_plan=''
  done < "$plans"
}

rollback_hook_plan() {
  local plan="$1" managed old_payload new_payload
  managed="$(printf '%s\n' "$plan" | jq -r '.managed')" || return "$TRELLIS_EX_STATE"
  old_payload="$(printf '%s\n' "$plan" | jq -r '.old_payload')" || return "$TRELLIS_EX_STATE"
  new_payload="$(printf '%s\n' "$plan" | jq -r '.new_payload')" || return "$TRELLIS_EX_STATE"
  if hook_payload_matches "$managed" "$old_payload"; then
    return 0
  fi
  hook_payload_matches "$managed" "$new_payload" || return "$TRELLIS_EX_CONFLICT"
  replace_hook_payload "$managed" "$new_payload" "$old_payload"
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

adopt_group() (
  local home="$1" version="$2" payload="$3" rows="$4" work="$5"
  local plans="$work/plans.jsonl" changed="$work/changed.jsonl" changed_hooks="$work/changed-hooks.jsonl"
  local row plan first checkout common rc=0 number=0 label
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
  jq -se '([.[].old_version] | unique | length) == 1 and ([.[] | select(.hooks == "true") | .managed] | unique | length) <= 1' "$plans" >/dev/null || return "$TRELLIS_EX_CONFLICT"
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

  # Re-resolve every exact target immediately before the first runtime mutation.
  # This closes the small window after the group-wide validation pass.
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
    attachment_verify "$home" "$(printf '%s\n' "$plan" | jq -r '.owner')" || return "$?"
  done < "$plans"

  update_group_registry "$home" "$plans" "$version" || return "$?"
  committed=true
  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    printf 'adopted: %s\n' "$(target_label "$(printf '%s\n' "$plan" | jq -c '.row')")"
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
      # SKIPPING IS NOT SWALLOWING. "This row is not an adoption target" says
      # nothing about the row's own class, and an unhealthy checkout row swept
      # by a bulk selector was exiting through this branch with no report and no
      # class at all. The floor below is the WORKTREE branch's predicate
      # verbatim — availability, status AND exclusion — because those three are
      # what make a row unusable, and testing only `status = unavailable`
      # readmitted the two cases the worktree branch refuses: a `detached`
      # project's empty checkout, and an excluded one. Both were swept by
      # `--all`, reported as a benign skip, and returned 0. Only after the floor
      # is the row skipped. (`identity_error` is already floored class 4 by the
      # branch above and never reaches here.)
      if [ "$availability" != available ] || [ "$status" != active ] || [ "$excluded" = true ]; then
        release_err "unavailable checkout inventory row swept by the adoption selector: $label"
        rc="$(max_status "$rc" "$TRELLIS_EX_UNAVAILABLE")"
      else
        release_err "skipping checkout inventory row with no registered worktree: $label"
      fi
    elif [ "$kind" != worktree ] || [ "$availability" != available ] || [ "$status" != active ] || [ "$excluded" = true ]; then
      release_err "unavailable adoption target remains explicit: $label"
      rc="$(max_status "$rc" "$TRELLIS_EX_UNAVAILABLE")"
    fi
  done < "$selected"

  # Every exit path AFTER the row loop must be floored with `rc`. The loop has
  # already proven rows unusable — a class-5 finding outranks class 4 — so a
  # fixed `return "$TRELLIS_EX_STATE"` here silently DOWNGRADED an adopt that had
  # just reported unavailable targets, reporting registry corruption instead of
  # the higher class the rows established.
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
