#!/usr/bin/env bash
# Load trellis.config.json into bash variables.
#
# Usage:
#   . "$(dirname "$0")/lib/config-load.sh"
#   echo "$TRELLIS_ROOT"     # /Users/.../projects/trellis-instance
#   echo "$PROJECTS_ROOT"    # /Users/.../projects/personal
#   echo "${HARNESSES[@]}"   # claude codex
#
# Resolves the config file by:
#   1. Walking up from the calling script until trellis.config.json is found.
#   2. If $TRELLIS_CONFIG is set, that path wins.
#
# Requires: jq.

set -euo pipefail

_pgcfg_locate() {
  if [ -n "${TRELLIS_CONFIG:-}" ]; then
    if [ -f "$TRELLIS_CONFIG" ]; then
      printf "%s" "$TRELLIS_CONFIG"
      return 0
    fi
    echo "config-load: TRELLIS_CONFIG=$TRELLIS_CONFIG does not exist" >&2
    return 1
  fi
  # Walk up from invoking script's dir
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/trellis.config.json" ]; then
      printf "%s" "$dir/trellis.config.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "config-load: no trellis.config.json found in any parent directory" >&2
  return 1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "config-load: jq is required but not installed" >&2
  echo "  macOS:   brew install jq" >&2
  echo "  Debian:  apt-get install jq" >&2
  return 1 2>/dev/null || exit 1
fi

_PGCFG_PATH="$(_pgcfg_locate)" || return 1
TRELLIS_CONFIG_PATH="$_PGCFG_PATH"
export TRELLIS_CONFIG_PATH

# --- Schema validation (plan task P3.3 / audit §4.1 third bullet) -----------
# Use ajv via npx if available, else fall back to a jq-based check that
# enforces the schema's `required` + non-empty-string contract. The fallback
# satisfies the plan's acceptance ("missing/empty required fields error
# loudly") without forcing a Node toolchain dependency on every consumer.
_pgcfg_validate() {
  local cfg="$1" schema_path
  schema_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trellis.config.schema.json"
  [ -f "$schema_path" ] || { echo "config-load: schema missing at $schema_path" >&2; return 1; }

  if command -v npx >/dev/null 2>&1 && npx --no-install ajv --help >/dev/null 2>&1; then
    if ! npx --no-install ajv validate -s "$schema_path" -d "$cfg" >/dev/null 2>&1; then
      echo "config-load: ajv schema validation failed for $cfg" >&2
      npx --no-install ajv validate -s "$schema_path" -d "$cfg" >&2 || true
      return 1
    fi
    return 0
  fi

  # jq fallback: enforce `required` (presence + non-empty-string for string
  # types). Reads the schema's required[] and properties.<name>.minLength.
  local required missing=()
  required="$(jq -r '.required[]' "$schema_path" 2>/dev/null)"
  for field in $required; do
    local val
    val="$(jq -r --arg f "$field" '.[$f] // empty' "$cfg" 2>/dev/null)"
    if [ -z "$val" ] || [ "$val" = "null" ]; then
      missing+=("$field")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "config-load: missing required field(s) in $cfg:" >&2
    for f in "${missing[@]}"; do echo "  - $f" >&2; done
    return 1
  fi
  # Harnesses array minItems=1 check (the only non-presence schema rule
  # the fallback enforces).
  if [ "$(jq '.harnesses | if type == "array" then length else 0 end' "$cfg")" -lt 1 ]; then
    echo "config-load: missing required field(s) in $cfg:" >&2
    echo "  - harnesses (must contain at least one of: claude, codex, antigravity)" >&2
    return 1
  fi
  # Optional-field pattern check: trellis_version, if present, must be
  # strict semver. The schema's `pattern` is not honored by the jq
  # fallback otherwise — see scripts/upgrade.sh's post-write tripwire.
  local tv
  tv="$(jq -r '.trellis_version // empty' "$cfg" 2>/dev/null)"
  if [ -n "$tv" ]; then
    if ! printf '%s' "$tv" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
      echo "config-load: trellis_version '$tv' in $cfg does not match semver pattern" >&2
      return 1
    fi
  fi
  return 0
}

if ! _pgcfg_validate "$_PGCFG_PATH"; then
  return 1 2>/dev/null || exit 1
fi

TRELLIS_ROOT="$(jq -r '.trellis_root' "$_PGCFG_PATH")"
PROJECTS_ROOT="$(jq -r '.projects_root' "$_PGCFG_PATH")"
USER_HOME="$(jq -r '.user_home' "$_PGCFG_PATH")"
MAINTAINER_NAME="$(jq -r '.maintainer_name' "$_PGCFG_PATH")"
GITHUB_USER="$(jq -r '.github_user' "$_PGCFG_PATH")"

# HARNESSES as a bash array
HARNESSES=()
while IFS= read -r h; do
  HARNESSES+=("$h")
done < <(jq -r '.harnesses[]' "$_PGCFG_PATH")

# Template config
TEMPLATE_REMOTE="$(jq -r '.template.remote // empty' "$_PGCFG_PATH")"
TEMPLATE_BRANCH="$(jq -r '.template.branch // "main"' "$_PGCFG_PATH")"

# Optional pinned canonical core-rules version. Empty if the consumer hasn't pinned.
TRELLIS_VERSION="$(jq -r '.trellis_version // empty' "$_PGCFG_PATH")"

# Note: per-project preset selection is read directly by onboard-project.sh
# and scripts/rollout-presets.sh from each project's own
# <project>/.trellis.config.json — not from this parent config and not via
# this loader. Presets are a per-project concept; the parent config's
# `presets` field (if present) only describes presets the control-plane
# repo itself wants applied to its own rules, which has no current consumer.

SED_FLAVOR="$(jq -r '.sed_flavor // "auto"' "$_PGCFG_PATH")"

export TRELLIS_ROOT PROJECTS_ROOT USER_HOME MAINTAINER_NAME GITHUB_USER
export TEMPLATE_REMOTE TEMPLATE_BRANCH TRELLIS_VERSION SED_FLAVOR

# Validation
[ -d "$TRELLIS_ROOT" ]    || { echo "config-load: trellis_root not a directory: $TRELLIS_ROOT" >&2; return 1; }
[ -d "$PROJECTS_ROOT" ]   || echo "config-load: warning — projects_root not a directory: $PROJECTS_ROOT" >&2

# Convenience: is harness X enabled?
# Usage:  if pg_has_harness codex; then ...; fi
pg_has_harness() {
  local target="$1" h
  for h in "${HARNESSES[@]}"; do
    [ "$h" = "$target" ] && return 0
  done
  return 1
}
