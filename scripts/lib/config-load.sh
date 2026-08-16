#!/usr/bin/env bash
# Load the tracked portable policy plus the machine-local Trellis state.
#
# Usage:
#   . "$(dirname "$0")/lib/config-load.sh"
#
# Portable policy resolution:
#   1. $TRELLIS_CONFIG, when set, names the policy file directly.
#   2. Otherwise walk upward from the calling script for trellis.config.json.
#
# Machine state is always read from $TRELLIS_HOME/config.json, where
# TRELLIS_HOME defaults to $HOME/.trellis.  Tracked policy deliberately carries
# no machine paths; legacy path variables below are compatibility bridges
# derived only from validated local state.
#
# Requires: jq.

_PGCFG_EX_USAGE=2
_PGCFG_EX_STATE=4
_PGCFG_EX_UNAVAILABLE=5
_PGCFG_LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
  printf '%s\n' "config-load: could not resolve library directory" >&2
  return "$_PGCFG_EX_UNAVAILABLE" 2>/dev/null || exit "$_PGCFG_EX_UNAVAILABLE"
}
_PGCFG_POLICY_SCHEMA="$_PGCFG_LIB_DIR/trellis.config.schema.json"
_PGCFG_HOME_LIB="$_PGCFG_LIB_DIR/trellis-home.sh"

_pgcfg_error() {
  local code
  code="$1"
  shift
  printf 'config-load: %s\n' "$*" >&2
  return "$code"
}

_pgcfg_locate_policy() {
  local caller dir

  if [ -n "${TRELLIS_CONFIG:-}" ]; then
    if [ -f "$TRELLIS_CONFIG" ]; then
      printf '%s\n' "$TRELLIS_CONFIG"
      return 0
    fi
    _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "TRELLIS_CONFIG=$TRELLIS_CONFIG does not exist"
    return "$?"
  fi

  caller="${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]:-${BASH_SOURCE[0]}}"
  dir="$(CDPATH='' cd "$(dirname "$caller")" && pwd -P)" || {
    _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "could not resolve calling script directory"
    return "$?"
  }

  while :; do
    if [ -f "$dir/trellis.config.json" ]; then
      printf '%s\n' "$dir/trellis.config.json"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done

  _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "no trellis.config.json found in any parent directory"
  return "$?"
}

_pgcfg_validate_policy_fallback() {
  local cfg schema
  cfg="$1"
  schema="$2"

  # AJV is not a runtime dependency of every compatibility caller.  The
  # fallback enforces the release-boundary invariants and every field this
  # loader consumes; AJV remains the complete schema validator when installed.
  jq -e --slurpfile schema "$schema" '
    def safe_text:
      type == "string"
      and length > 0
      and all(explode[]; . != 0 and . != 9 and . != 10 and . != 13);
    def safe_git_token:
      safe_text
      and (startswith("-") | not)
      and all(explode[]; . >= 32 and . != 127);
    def safe_git_remote:
      safe_git_token
      and test("^(https://[^/:[:space:]]+(:[0-9]+)?/[^[:space:]]+|ssh://[^/:[:space:]]+(:[0-9]+)?/[^[:space:]]+|git@[^:/[:space:]]+:[^:[:space:]]+)$");
    def safe_git_branch:
      safe_git_token
      and test("^[A-Za-z0-9][A-Za-z0-9._/-]*$")
      and (endswith("/") | not)
      and (endswith(".") | not)
      and (contains("..") | not)
      and (contains("//") | not)
      and (contains("@{") | not)
      and ([split("/")[] | length > 0 and . != "." and . != ".." and (startswith(".") | not) and (endswith(".lock") | not)] | all);
    def portable_relative_path:
      safe_git_token
      and (startswith("/") | not)
      and (contains("\\") | not)
      and (test("^[A-Za-z]:") | not)
      and (
        if endswith("/") then .[0:-1] else . end
        | split("/")
        | all(.[]; length > 0 and . != "." and . != "..")
      );
    def valid_portable_path_list:
      if type == "array" then all(.[]; portable_relative_path) else false end;
    def semver:
      safe_text
      and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$");
    def whole_number:
      type == "number" and (floor == .);
    def integer_between($min; $max):
      whole_number and . >= $min and . <= $max;
    def nonnegative_integer:
      whole_number and . >= 0;
    def positive_integer:
      whole_number and . >= 1;
    def nonnegative_number:
      type == "number" and . >= 0;
    def optional_boolean($key):
      (has($key) | not) or (.[$key] | type == "boolean");
    def optional_nonnegative_integer($key):
      (has($key) | not) or (.[$key] | nonnegative_integer);
    def optional_positive_integer($key):
      (has($key) | not) or (.[$key] | positive_integer);
    def optional_nonnegative_number($key):
      (has($key) | not) or (.[$key] | nonnegative_number);
    def valid_string_list:
      if type == "array" then
        ([.[] | type == "string" and length > 0] | all)
        and ((unique | length) == length)
      else false end;
    def valid_template:
      if type == "object" then
        ((has("remote") | not) or (.remote | safe_git_remote))
        and ((has("branch") | not) or (.branch | safe_git_branch))
        and ((has("redact_paths") | not) or (.redact_paths | valid_portable_path_list))
      else false end;
    def valid_disk_janitor:
      if type == "object" then
        optional_boolean("enabled")
        and optional_nonnegative_integer("cache_ttl_days")
        and optional_nonnegative_integer("worktree_stale_days")
        and optional_nonnegative_integer("free_space_floor_gb")
        and optional_nonnegative_integer("cache_ceiling_gb")
        and optional_boolean("reap_pushed_worktrees")
        and optional_nonnegative_integer("ephemeral_tmp_ttl_days")
        and optional_nonnegative_integer("worktree_count_ceiling")
        and optional_nonnegative_integer("worktree_total_gb_ceiling")
        and ((has("skip_projects") | not) or (.skip_projects | valid_string_list))
      else false end;
    def valid_loop_safety:
      if type == "object" then
        optional_positive_integer("max_iterations")
        and optional_positive_integer("no_progress_iterations")
        and optional_nonnegative_number("budget_ceiling_usd")
        and optional_nonnegative_number("usd_per_mtok")
        and optional_nonnegative_number("codex_usd_per_mtok")
      else false end;
    def valid_mandatory_pipeline:
      if type == "object" then
        optional_boolean("enabled")
        and optional_positive_integer("spec_required_diff_lines")
        and optional_positive_integer("surgical_max_diff_lines")
      else false end;
    def valid_aeo_gate:
      if type == "object" then
        optional_boolean("enabled")
        and ((has("marker_file") | not) or (.marker_file | portable_relative_path))
        and ((has("baseline") | not) or (.baseline | portable_relative_path))
        and (
          if .enabled == true then
            (.marker_file | portable_relative_path)
            and (.baseline | portable_relative_path)
          else true
          end
        )
      else false end;
    . as $policy
    | $schema[0] as $definition
    | type == "object"
    and (.schema_version? == 2)
    and (.maintainer_name? | safe_text)
    and (.github_user? | safe_text)
    and ((.harnesses? | type) == "array")
    and ((.harnesses | length) > 0)
    and ([.harnesses[] | . == "claude" or . == "codex" or . == "omp"] | all)
    and ((.harnesses | unique | length) == (.harnesses | length))
    and (
      [
        "trellis_root", "projects_root", "user_home", "shared_infra_root",
        "symlink_style", "fleet", "installed_release", "source_root",
        "release_remote", "active_cli_release", "default_fleet", "fleets"
      ]
      | all(. as $field | ($policy | has($field) | not))
    )
    and (
      if $definition.additionalProperties == false then
        [$policy | keys_unsorted[] as $field | ($definition.properties | has($field))] | all
      else true
      end
    )
    and (if has("template") then (.template | valid_template) else true end)
    and (
      if has("trellis_version") then
        (.trellis_version | semver)
      else true
      end
    )
    and (
      if has("sed_flavor") then
        .sed_flavor == "auto" or .sed_flavor == "gnu" or .sed_flavor == "bsd"
      else true
      end
    )
    and (
      if has("package_manager") then
        .package_manager == "auto"
        or .package_manager == "pnpm"
        or .package_manager == "npm"
        or .package_manager == "bun"
        or .package_manager == "yarn"
      else true
      end
    )
    and (
      if has("autonomy_default") then
        (.autonomy_default | integer_between(1; 5))
      else true
      end
    )
    and (
      if has("autonomy") then
        (.autonomy | integer_between(1; 5))
      else true
      end
    )
    and (if has("disk_janitor") then (.disk_janitor | valid_disk_janitor) else true end)
    and (if has("loop_safety") then (.loop_safety | valid_loop_safety) else true end)
    and (if has("mandatory_pipeline") then (.mandatory_pipeline | valid_mandatory_pipeline) else true end)
    and (if has("aeo_gate") then (.aeo_gate | valid_aeo_gate) else true end)
  ' "$cfg" >/dev/null 2>&1
}

_pgcfg_validate_policy() {
  local cfg schema
  cfg="$1"
  schema="$_PGCFG_POLICY_SCHEMA"

  if [ ! -f "$schema" ]; then
    _pgcfg_error "$_PGCFG_EX_STATE" "portable policy schema missing at $schema"
    return "$?"
  fi
  if [ ! -r "$cfg" ]; then
    _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "portable policy is not readable: $cfg"
    return "$?"
  fi
  if ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    _pgcfg_error "$_PGCFG_EX_STATE" "portable policy is not a valid JSON object: $cfg"
    return "$?"
  fi
  if ! jq -e '
    . as $policy
    | [
        "trellis_root", "projects_root", "user_home", "shared_infra_root",
        "symlink_style", "fleet", "installed_release", "source_root",
        "release_remote", "active_cli_release", "default_fleet", "fleets"
      ]
    | all(. as $field | ($policy | has($field) | not))
  ' "$cfg" >/dev/null 2>&1; then
    _pgcfg_error "$_PGCFG_EX_STATE" "portable policy contains machine-local fields: $cfg"
    return "$?"
  fi

  # Prefer an AJV executable injected by the caller (including
  # `npx -p ajv-cli`), then an installed npx package.  Compilation is the
  # capability probe: unsupported AJV versions fall back to the deterministic
  # jq validator instead of rejecting valid portable policy.
  if command -v ajv >/dev/null 2>&1 &&
     ajv compile --spec=draft2020 --strict=false -s "$schema" >/dev/null 2>&1; then
    if ajv validate --spec=draft2020 --strict=false -s "$schema" -d "$cfg" >/dev/null 2>&1; then
      return 0
    fi
    _pgcfg_error "$_PGCFG_EX_STATE" "portable policy failed schema validation: $cfg"
    return "$?"
  fi
  if command -v npx >/dev/null 2>&1 &&
     npx --no-install ajv compile --spec=draft2020 --strict=false -s "$schema" >/dev/null 2>&1; then
    if npx --no-install ajv validate --spec=draft2020 --strict=false -s "$schema" -d "$cfg" >/dev/null 2>&1; then
      return 0
    fi
    _pgcfg_error "$_PGCFG_EX_STATE" "portable policy failed schema validation: $cfg"
    return "$?"
  fi

  if ! _pgcfg_validate_policy_fallback "$cfg" "$schema"; then
    _pgcfg_error "$_PGCFG_EX_STATE" "portable policy failed schema validation: $cfg"
    return "$?"
  fi
}

_pgcfg_resolve_home() {
  (
    # Keep trellis-home's command-oriented exit helper isolated from scripts
    # that source this compatibility loader.
    # shellcheck disable=SC1090  # _PGCFG_HOME_LIB is resolved at runtime from the active release.
    . "$_PGCFG_HOME_LIB"
    trellis_home_resolve
  )
}

_pgcfg_validate_machine_config() {
  local cfg
  cfg="$1"
  (
    # trellis_home_validate_config is the shared schema/semantic authority.
    # A subshell guarantees no helper can terminate the sourcing caller.
    # shellcheck disable=SC1090  # _PGCFG_HOME_LIB is resolved at runtime from the active release.
    . "$_PGCFG_HOME_LIB"
    trellis_home_validate_config "$cfg"
  )
}

_pgcfg_resolve_fleet() {
  local cfg
  cfg="$1"
  (
    # shellcheck disable=SC1090  # _PGCFG_HOME_LIB is resolved at runtime from the active release.
    . "$_PGCFG_HOME_LIB"
    trellis_home_resolve_fleet "" "$cfg"
  )
}

_pgcfg_require_real_dir() {
  local label path resolved
  label="$1"
  path="$2"

  if [ ! -d "$path" ]; then
    _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "$label is not an available directory: $path"
    return "$?"
  fi
  resolved="$(CDPATH='' cd "$path" && pwd -P)" || {
    _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "$label could not be canonicalized: $path"
    return "$?"
  }
  printf '%s\n' "$resolved"
}
_pgcfg_available_real_dir() {
  local path
  path="$1"

  [ -d "$path" ] || return 1
  (CDPATH='' cd "$path" && pwd -P) 2>/dev/null
}


_pgcfg_require_private_home() {
  local home mode
  home="$1"

  case "$(uname -s)" in
    Darwin)
      if mode="$(stat -f '%Lp' "$home" 2>/dev/null)"; then :; else
        _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "could not read TRELLIS_HOME permissions: $home"
        return "$?"
      fi
      ;;
    *)
      if mode="$(stat -c '%a' "$home" 2>/dev/null)"; then :; else
        _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "could not read TRELLIS_HOME permissions: $home"
        return "$?"
      fi
      ;;
  esac

  case "$mode" in
    ''|*[!0-7]*)
      _pgcfg_error "$_PGCFG_EX_STATE" "TRELLIS_HOME has an invalid permission mode: $home"
      return "$?"
      ;;
    *00) return 0 ;;
    *)
      _pgcfg_error "$_PGCFG_EX_STATE" "TRELLIS_HOME must not grant group or other permissions: $home (mode $mode)"
      return "$?"
      ;;
  esac
}

_pgcfg_load() {
  local status selected root shared canonical compatibility_root root_state roots_state shared_state
  local available_count

  if ! command -v jq >/dev/null 2>&1; then
    _pgcfg_error "$_PGCFG_EX_UNAVAILABLE" "jq is required but not installed"
    return "$?"
  fi
  if [ ! -f "$_PGCFG_HOME_LIB" ]; then
    _pgcfg_error "$_PGCFG_EX_STATE" "machine configuration library missing at $_PGCFG_HOME_LIB"
    return "$?"
  fi
  if [ -z "${HOME:-}" ]; then
    _pgcfg_error "$_PGCFG_EX_USAGE" "HOME is required to export USER_HOME"
    return "$?"
  fi

  if TRELLIS_CONFIG_PATH="$(_pgcfg_locate_policy)"; then
    :
  else
    return "$?"
  fi
  export TRELLIS_CONFIG_PATH
  _pgcfg_validate_policy "$TRELLIS_CONFIG_PATH" || return "$?"

  if TRELLIS_HOME="$(_pgcfg_resolve_home)"; then
    :
  else
    return "$?"
  fi
  TRELLIS_HOME="${TRELLIS_HOME%/}"
  export TRELLIS_HOME

  if [ -L "$TRELLIS_HOME" ] || [ ! -d "$TRELLIS_HOME" ]; then
    _pgcfg_error "$_PGCFG_EX_STATE" "TRELLIS_HOME must be a real directory: $TRELLIS_HOME"
    return "$?"
  fi
  _pgcfg_require_private_home "$TRELLIS_HOME" || return "$?"
  TRELLIS_HOME_CONFIG="$TRELLIS_HOME/config.json"
  export TRELLIS_HOME_CONFIG

  if _pgcfg_validate_machine_config "$TRELLIS_HOME_CONFIG"; then
    :
  else
    status="$?"
    return "$status"
  fi

  if TRELLIS_SOURCE_ROOT="$(jq -er '.source_root' "$TRELLIS_HOME_CONFIG")"; then
    :
  else
    _pgcfg_error "$_PGCFG_EX_STATE" "could not read source_root from $TRELLIS_HOME_CONFIG"
    return "$?"
  fi
  if TRELLIS_SOURCE_ROOT="$(_pgcfg_require_real_dir "source_root" "$TRELLIS_SOURCE_ROOT")"; then
    :
  else
    return "$?"
  fi
  if [ ! -f "$TRELLIS_SOURCE_ROOT/trellis.config.json" ]; then
    _pgcfg_error "$_PGCFG_EX_STATE" "source_root is not a Trellis policy checkout: $TRELLIS_SOURCE_ROOT"
    return "$?"
  fi

  if TRELLIS_ACTIVE_RELEASE="$(jq -er '.active_cli_release' "$TRELLIS_HOME_CONFIG")"; then
    :
  else
    _pgcfg_error "$_PGCFG_EX_STATE" "could not read active_cli_release from $TRELLIS_HOME_CONFIG"
    return "$?"
  fi

  if TRELLIS_FLEET_NAME="$(_pgcfg_resolve_fleet "$TRELLIS_HOME_CONFIG")"; then
    :
  else
    status="$?"
    return "$status"
  fi
  selected="$TRELLIS_FLEET_NAME"
  if ! jq -e --arg fleet "$selected" '.fleets[$fleet] | type == "object"' "$TRELLIS_HOME_CONFIG" >/dev/null 2>&1; then
    _pgcfg_error "$_PGCFG_EX_STATE" "selected fleet is not configured: $selected"
    return "$?"
  fi

  if TRELLIS_DISCOVERY_ROOTS_JSON="$(jq -ceS --arg fleet "$selected" '.fleets[$fleet].discovery_roots' "$TRELLIS_HOME_CONFIG")"; then
    :
  else
    _pgcfg_error "$_PGCFG_EX_STATE" "could not read discovery_roots for fleet $selected"
    return "$?"
  fi

  TRELLIS_DISCOVERY_ROOTS=()
  available_count=0
  compatibility_root=""
  roots_state=""
  while IFS= read -r root; do
    TRELLIS_DISCOVERY_ROOTS+=("$root")
    if canonical="$(_pgcfg_available_real_dir "$root")"; then
      available_count=$((available_count + 1))
      compatibility_root="$canonical"
      if root_state="$(jq -cnS \
        --arg configured_path "$root" \
        --arg canonical_path "$canonical" \
        '{configured_path: $configured_path, available: true, canonical_path: $canonical_path}')"; then
        :
      else
        _pgcfg_error "$_PGCFG_EX_STATE" "could not serialize discovery root state for fleet $selected"
        return "$?"
      fi
    else
      if root_state="$(jq -cnS \
        --arg configured_path "$root" \
        '{configured_path: $configured_path, available: false, canonical_path: null}')"; then
        :
      else
        _pgcfg_error "$_PGCFG_EX_STATE" "could not serialize discovery root state for fleet $selected"
        return "$?"
      fi
    fi
    if [ -n "$roots_state" ]; then
      roots_state="${roots_state}
${root_state}"
    else
      roots_state="$root_state"
    fi
  done < <(jq -r --arg fleet "$selected" '.fleets[$fleet].discovery_roots[]' "$TRELLIS_HOME_CONFIG")

  if roots_state="$(printf '%s\n' "$roots_state" | jq -csS '.')"; then
    :
  else
    _pgcfg_error "$_PGCFG_EX_STATE" "could not serialize discovery root state for fleet $selected"
    return "$?"
  fi

  PROJECTS_ROOT=""
  if [ "$available_count" -eq 1 ]; then
    PROJECTS_ROOT="$compatibility_root"
  fi

  if shared="$(jq -r --arg fleet "$selected" '.fleets[$fleet].shared_infra_root // ""' "$TRELLIS_HOME_CONFIG")"; then
    :
  else
    _pgcfg_error "$_PGCFG_EX_STATE" "could not read shared_infra_root for fleet $selected"
    return "$?"
  fi
  SHARED_INFRA_ROOT="$shared"
  SHARED_INFRA_ROOT_AVAILABLE=0
  shared_state='null'
  if [ -n "$shared" ]; then
    if canonical="$(_pgcfg_available_real_dir "$shared")"; then
      SHARED_INFRA_ROOT_AVAILABLE=1
      if shared_state="$(jq -cnS \
        --arg configured_path "$shared" \
        --arg canonical_path "$canonical" \
        '{configured_path: $configured_path, available: true, canonical_path: $canonical_path}')"; then
        :
      else
        _pgcfg_error "$_PGCFG_EX_STATE" "could not serialize shared_infra_root state for fleet $selected"
        return "$?"
      fi
    else
      if shared_state="$(jq -cnS \
        --arg configured_path "$shared" \
        '{configured_path: $configured_path, available: false, canonical_path: null}')"; then
        :
      else
        _pgcfg_error "$_PGCFG_EX_STATE" "could not serialize shared_infra_root state for fleet $selected"
        return "$?"
      fi
    fi
  fi

  if TRELLIS_FLEET_LOCAL_JSON="$(jq -cnS \
    --arg fleet "$selected" \
    --argjson discovery_roots "$roots_state" \
    --argjson shared_infra_root "$shared_state" \
    '{fleet: $fleet, discovery_roots: $discovery_roots, shared_infra_root: $shared_infra_root}')"; then
    :
  else
    _pgcfg_error "$_PGCFG_EX_STATE" "could not serialize fleet-local state for fleet $selected"
    return "$?"
  fi

  # The block below publishes the loader's out-parameters. Every one of them is read by the
  # scripts that source this file and by none of the code in it, which is what SC2034 sees.
  # shellcheck disable=SC2034
  MAINTAINER_NAME="$(jq -er '.maintainer_name' "$TRELLIS_CONFIG_PATH")" || return "$_PGCFG_EX_STATE"
  # shellcheck disable=SC2034
  GITHUB_USER="$(jq -er '.github_user' "$TRELLIS_CONFIG_PATH")" || return "$_PGCFG_EX_STATE"
  HARNESSES=()
  while IFS= read -r root; do
    HARNESSES+=("$root")
  done <<EOF
$(jq -er '.harnesses[]' "$TRELLIS_CONFIG_PATH")
EOF
  # shellcheck disable=SC2034
  TEMPLATE_REMOTE="$(jq -r '.template.remote // empty' "$TRELLIS_CONFIG_PATH")" || return "$_PGCFG_EX_STATE"
  # shellcheck disable=SC2034
  TEMPLATE_BRANCH="$(jq -r '.template.branch // "main"' "$TRELLIS_CONFIG_PATH")" || return "$_PGCFG_EX_STATE"
  # shellcheck disable=SC2034
  TRELLIS_VERSION="$(jq -r '.trellis_version // empty' "$TRELLIS_CONFIG_PATH")" || return "$_PGCFG_EX_STATE"
  # shellcheck disable=SC2034
  SED_FLAVOR="$(jq -r '.sed_flavor // "auto"' "$TRELLIS_CONFIG_PATH")" || return "$_PGCFG_EX_STATE"

  # Explicit local state plus the remaining fleet bridges.  The sourced
  # TRELLIS_DISCOVERY_ROOTS array preserves configured order; child processes
  # receive the equivalent JSON and availability-bearing fleet-local state.
  #
  # TRELLIS_ROOT is deliberately NOT exported.  The one-release bridge that
  # published the source root under that name was removed at v1.0.0-rc.25:
  # callers that want the management/publication checkout read
  # TRELLIS_SOURCE_ROOT, and TRELLIS_ROOT now carries exactly one meaning
  # anywhere in Trellis — a project's `.trellis/runtime` anchor, set by the
  # attachment-owned hook wiring.  Exporting the source root here would put a
  # mutable checkout behind that name for every child process.
  USER_HOME="$HOME"
  SYMLINK_STYLE="relative"

  export TRELLIS_SOURCE_ROOT TRELLIS_ACTIVE_RELEASE TRELLIS_FLEET_NAME
  export TRELLIS_DISCOVERY_ROOTS_JSON TRELLIS_FLEET_LOCAL_JSON
  export PROJECTS_ROOT SHARED_INFRA_ROOT SHARED_INFRA_ROOT_AVAILABLE USER_HOME SYMLINK_STYLE

  # Usage: if pg_has_harness codex; then ...; fi
  pg_has_harness() {
    local target harness
    target="$1"
    for harness in "${HARNESSES[@]}"; do
      [ "$harness" = "$target" ] && return 0
    done
    return 1
  }
}

if _pgcfg_load; then
  :
else
  _PGCFG_STATUS="$?"
  return "$_PGCFG_STATUS" 2>/dev/null || exit "$_PGCFG_STATUS"
fi
