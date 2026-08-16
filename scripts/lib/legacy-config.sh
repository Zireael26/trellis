#!/usr/bin/env bash
# The ONE validating reader for the historic machine-local Trellis config.
#
# Usage:
#   . "$(dirname "$0")/lib/legacy-config.sh"
#
# The portable loader (lib/config-load.sh) deliberately REFUSES machine-local
# keys, so it cannot read a legacy config at all. This library exists so the
# legacy shape still has exactly one schema and one set of preconditions
# governing it.
#
# Since v1.0.0-rc.25 there is exactly ONE consumer: doctor.sh's legacy diagnosis
# mode. The other one, onboard-project.sh --legacy, was the direct-link WRITER
# and the cutover removed it. That asymmetry is the point of keeping this file:
# an operator holding a pre-cutover checkout can still get a validated,
# read-only account of what it is and what migrating it requires. Nothing here
# creates, repairs, or re-seeds a direct link, and nothing should be added that
# does — a writer belongs on the attachment path, against a release.
#
# Diagnostics take the caller's program name as $1 so each command names
# itself; the CONDITIONS and their exit classes are identical everywhere.
#
# Requires: jq.

LEGACY_CONFIG_EX_USAGE=2
LEGACY_CONFIG_EX_STATE=4
LEGACY_CONFIG_EX_UNAVAILABLE=5

# An explicit config path is operator-supplied text that ends up in
# diagnostics and in `cd`/`jq` arguments. Reject control bytes before any
# consumer touches it.
legacy_config_path_is_safe() {
  printf '%s' "${1:-}" | jq -eRs '
    type == "string"
    and length > 0
    and all(explode[]; . >= 32 and (. < 127 or . > 159))
  ' >/dev/null 2>&1
}

# Preconditions every consumer must apply BEFORE the machine-local
# discriminator below is even meaningful. Do not fall through to portable
# resolution when one of these fails: a malformed explicit config must be a
# deterministic refusal, never a silent switch to another source of truth.
legacy_config_preconditions() {
  local prefix="$1" cfg="$2"

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s: jq is required\n' "$prefix" >&2
    return "$LEGACY_CONFIG_EX_UNAVAILABLE"
  fi
  if ! legacy_config_path_is_safe "$cfg"; then
    printf '%s: TRELLIS_CONFIG is not a safe explicit path\n' "$prefix" >&2
    return "$LEGACY_CONFIG_EX_STATE"
  fi
  if [ -L "$cfg" ] || [ ! -f "$cfg" ] || [ ! -r "$cfg" ]; then
    printf '%s: TRELLIS_CONFIG is not a readable regular file\n' "$prefix" >&2
    return "$LEGACY_CONFIG_EX_UNAVAILABLE"
  fi
  if ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    printf '%s: TRELLIS_CONFIG is not a JSON object\n' "$prefix" >&2
    return "$LEGACY_CONFIG_EX_STATE"
  fi
  return 0
}

# The compatibility discriminator: any historic machine-local key. Callers MUST
# have run legacy_config_preconditions first — this predicate answers only
# "which shape is this", never "is this usable".
legacy_config_has_machine_local_key() {
  jq -e '
    has("trellis_root") or has("projects_root") or has("user_home")
    or has("shared_infra_root") or has("symlink_style") or has("fleet")
    or has("installed_release")
  ' "$1" >/dev/null 2>&1
}

# Schema + semantic validation. Every field the loader below consumes is
# checked here, so no unvalidated value can reach a consumer.
legacy_config_validate() {
  local prefix="$1" cfg="$2"

  if ! jq -e '
    def safe_text:
      type == "string" and length > 0
      and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def absolute_path:
      safe_text and startswith("/") and (startswith("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    def harnesses:
      type == "array" and length > 0
      and all(.[]; . == "claude" or . == "codex" or . == "omp")
      and (unique | length == length);
    type == "object"
    and (.trellis_root | absolute_path)
    and (.projects_root | absolute_path)
    and (.user_home | absolute_path)
    and (.maintainer_name | safe_text)
    and (.github_user | safe_text)
    and (.harnesses | harnesses)
    and ((has("shared_infra_root") | not) or (.shared_infra_root | safe_text))
    and ((has("trellis_version") | not) or
         (.trellis_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$")))
    and ((has("sed_flavor") | not) or (.sed_flavor == "auto" or .sed_flavor == "gnu" or .sed_flavor == "bsd"))
    and ((has("symlink_style") | not) or (.symlink_style == "absolute" or .symlink_style == "relative"))
  ' "$cfg" >/dev/null 2>&1; then
    printf '%s: explicit legacy TRELLIS_CONFIG failed validation\n' "$prefix" >&2
    return "$LEGACY_CONFIG_EX_STATE"
  fi
  return 0
}

# Export the validated legacy view. Callers run legacy_config_preconditions and
# legacy_config_validate first; this function assumes both passed.
legacy_config_load() {
  local prefix="$1" cfg="$2" cfg_dir raw_shared shared_candidate h

  [ -n "$cfg" ] || {
    printf '%s: legacy mode requires explicit TRELLIS_CONFIG\n' "$prefix" >&2
    return "$LEGACY_CONFIG_EX_USAGE"
  }
  TRELLIS_CONFIG_PATH="$cfg"
  TRELLIS_ROOT="$(jq -r '.trellis_root' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  PROJECTS_ROOT="$(jq -r '.projects_root' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  USER_HOME="$(jq -r '.user_home' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  MAINTAINER_NAME="$(jq -r '.maintainer_name' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  GITHUB_USER="$(jq -r '.github_user' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  TEMPLATE_REMOTE="$(jq -r '.template.remote // empty' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  TEMPLATE_BRANCH="$(jq -r '.template.branch // "main"' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  TRELLIS_VERSION="$(jq -r '.trellis_version // empty' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  SED_FLAVOR="$(jq -r '.sed_flavor // "auto"' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  SYMLINK_STYLE="$(jq -r '.symlink_style // "absolute"' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"

  [ -d "$TRELLIS_ROOT" ] || {
    printf '%s: configured trellis_root is unavailable: %s\n' "$prefix" "$TRELLIS_ROOT" >&2
    return "$LEGACY_CONFIG_EX_UNAVAILABLE"
  }
  TRELLIS_ROOT="$(CDPATH='' cd "$TRELLIS_ROOT" && pwd -P)" || return "$LEGACY_CONFIG_EX_UNAVAILABLE"
  # Reported, not fatal: a compatibility diagnosis of ONE project still works
  # when the historic projects_root is not mounted on this machine.
  if [ ! -d "$PROJECTS_ROOT" ]; then
    printf '%s: configured projects_root is unavailable: %s\n' "$prefix" "$PROJECTS_ROOT" >&2
  fi

  SHARED_INFRA_ROOT=""
  raw_shared="$(jq -r '.shared_infra_root // empty' "$cfg")" || return "$LEGACY_CONFIG_EX_STATE"
  if [ -n "$raw_shared" ]; then
    # Both spellings a legacy config can carry resolve to a real directory —
    # consumers (doctor's shared-infra rows, onboard's `make -C`) need one:
    #   absolute "$HOME/infra"  -> the /* branch, used verbatim. This is what
    #                              every real legacy config actually holds.
    #   literal  "~/infra"      -> expanded against user_home.
    # The historic doctor.sh spelled the tilde branch `${raw_shared#~/}`
    # UNQUOTED, so bash tilde-expanded the word and it stripped a "$HOME/"
    # prefix instead — which a value beginning with a literal `~/` can never
    # carry. The strip was therefore a silent no-op and `~/infra` resolved to
    # "$USER_HOME/~/infra", which is not a directory, so the guard below turned
    # every tilde-form config into EX_UNAVAILABLE. Strip the literal prefix the
    # branch is matching on; the absolute form is byte-for-byte unchanged.
    # shellcheck disable=SC2088  # The tildes below are case PATTERNS matching a literal leading
    # tilde in untrusted config text. Expanding them here would defeat the match.
    case "$raw_shared" in
      '~') shared_candidate="$USER_HOME" ;;
      '~/'*) shared_candidate="$USER_HOME/${raw_shared#\~/}" ;;
      /*) shared_candidate="$raw_shared" ;;
      *)
        cfg_dir="$(CDPATH='' cd "$(dirname "$cfg")" && pwd -P)" || return "$LEGACY_CONFIG_EX_UNAVAILABLE"
        shared_candidate="$cfg_dir/$raw_shared"
        ;;
    esac
    [ -d "$shared_candidate" ] || {
      printf '%s: configured shared_infra_root is unavailable: %s\n' "$prefix" "$shared_candidate" >&2
      return "$LEGACY_CONFIG_EX_UNAVAILABLE"
    }
    SHARED_INFRA_ROOT="$(CDPATH='' cd "$shared_candidate" && pwd -P)" || return "$LEGACY_CONFIG_EX_UNAVAILABLE"
  fi

  HARNESSES=()
  while IFS= read -r h; do
    HARNESSES+=("$h")
  done < <(jq -r '.harnesses[]' "$cfg")

  export TRELLIS_CONFIG_PATH TRELLIS_ROOT PROJECTS_ROOT USER_HOME MAINTAINER_NAME GITHUB_USER
  export SHARED_INFRA_ROOT TEMPLATE_REMOTE TEMPLATE_BRANCH TRELLIS_VERSION SED_FLAVOR SYMLINK_STYLE

  # Usage: if pg_has_harness codex; then ...; fi
  pg_has_harness() {
    local target="$1" harness
    for harness in "${HARNESSES[@]}"; do
      [ "$harness" = "$target" ] && return 0
    done
    return 1
  }
}

# Convenience for a consumer that already knows it is in legacy mode.
legacy_config_read() {
  local prefix="$1" cfg="$2"
  legacy_config_preconditions "$prefix" "$cfg" || return "$?"
  legacy_config_validate "$prefix" "$cfg" || return "$?"
  legacy_config_load "$prefix" "$cfg" || return "$?"
}
