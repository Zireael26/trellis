#!/usr/bin/env bash
# Shared autonomy resolution for Codex hooks.
#
# Contract (core-rules/autonomy.md):
#   hard L3 -> fleet autonomy_default -> first active preset default when no
#   project override -> project autonomy -> session override -> lowest active
#   preset ceiling.
#
# Call `_se_resolve_autonomy <canonical-repo-root>`. It sets:
#   AUTONOMY_LEVEL, AUTONOMY_NAME, AUTONOMY_REQUESTED_LEVEL,
#   AUTONOMY_CEILING, AUTONOMY_CLAMPED, AUTONOMY_LIMITING_PRESET.
#
# Requires jq. Callers source lib/deps.sh and enforce jq before calling this.
# Bash 3.2 compatible; sourcing this file has no side effects.
# shellcheck disable=SC2034 # Resolver outputs are globals consumed by callers.

_se_valid_autonomy_level() {
  case "${1:-}" in
    1|2|3|4|5) return 0 ;;
    *) return 1 ;;
  esac
}

_se_autonomy_frontmatter_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v wanted="$key" '
    NR == 1 {
      sub(/\r$/, "")
      if ($0 != "---") exit
      in_frontmatter = 1
      next
    }
    in_frontmatter {
      sub(/\r$/, "")
      if ($0 == "---") exit
      line = $0
      if (line ~ "^[[:space:]]*" wanted ":[[:space:]]*") {
        sub("^[[:space:]]*" wanted ":[[:space:]]*", "", line)
        sub(/[[:space:]]*$/, "", line)
        print line
        exit
      }
    }
  ' "$file" 2>/dev/null
}

_se_resolve_autonomy() {
  local repo_root="$1"
  local project_cfg="" trellis_root="" fleet_cfg=""
  local fleet_level="" project_level="" preset_default="" session_level=""
  local project_cfg_candidate="" preset="" preset_file="" value="" session_file=""

  AUTONOMY_LEVEL=3
  AUTONOMY_NAME="Standard"
  AUTONOMY_REQUESTED_LEVEL=3
  AUTONOMY_CEILING=5
  AUTONOMY_CLAMPED=0
  AUTONOMY_LIMITING_PRESET=""

  # Project-local config selects active presets and may carry the project
  # override. `.trellis.config.json` wins over the compatibility filename.
  for project_cfg_candidate in \
    "$repo_root/.trellis.config.json" \
    "$repo_root/trellis.config.json"; do
    if [ -f "$project_cfg_candidate" ]; then
      project_cfg="$project_cfg_candidate"
      break
    fi
  done

  # TRELLIS_ROOT is authoritative when supplied by the deployed environment.
  # Otherwise, resolve it from project config; a canonical clone can fall back
  # to its own root when it carries trellis.config.json directly.
  if [ -n "${TRELLIS_ROOT:-}" ]; then
    trellis_root="$TRELLIS_ROOT"
  elif [ -n "$project_cfg" ]; then
    trellis_root=$(jq -r '(.trellis_root // empty) | strings' "$project_cfg" 2>/dev/null || true)
  fi
  if [ -z "$trellis_root" ] && [ -f "$repo_root/trellis.config.json" ]; then
    trellis_root="$repo_root"
  fi
  if [ -n "$trellis_root" ] && [ -f "$trellis_root/trellis.config.json" ]; then
    fleet_cfg="$trellis_root/trellis.config.json"
  fi

  if [ -n "$fleet_cfg" ]; then
    value=$(jq -r '.autonomy_default // empty' "$fleet_cfg" 2>/dev/null || true)
    if _se_valid_autonomy_level "$value"; then
      fleet_level="$value"
      AUTONOMY_LEVEL="$fleet_level"
    fi
  fi

  if [ -n "$project_cfg" ]; then
    value=$(jq -r '.autonomy // empty' "$project_cfg" 2>/dev/null || true)
    if _se_valid_autonomy_level "$value"; then
      project_level="$value"
    fi

    # Preset order is the declared config order. The first valid preset default
    # wins; ceiling conflicts always resolve to the lowest (most restrictive).
    while IFS= read -r preset; do
      [ -n "$preset" ] || continue
      preset_file="$trellis_root/core-rules/presets/$preset.md"
      [ -f "$preset_file" ] || continue

      value=$(_se_autonomy_frontmatter_value "$preset_file" autonomy_default)
      if [ -z "$preset_default" ] && _se_valid_autonomy_level "$value"; then
        preset_default="$value"
      fi

      value=$(_se_autonomy_frontmatter_value "$preset_file" autonomy_ceiling)
      if _se_valid_autonomy_level "$value" && [ "$value" -lt "$AUTONOMY_CEILING" ]; then
        AUTONOMY_CEILING="$value"
        AUTONOMY_LIMITING_PRESET="$preset"
      fi
    done < <(jq -r '(.presets // [])[]? | strings' "$project_cfg" 2>/dev/null || true)
  fi

  # Canonical pick precedence. A preset default applies only when there is no
  # valid project-local override, and it comes after the fleet default.
  if [ -n "$preset_default" ] && [ -z "$project_level" ]; then
    AUTONOMY_LEVEL="$preset_default"
  fi
  if [ -n "$project_level" ]; then
    AUTONOMY_LEVEL="$project_level"
  fi

  session_file="$repo_root/.claude/session-autonomy"
  if [ -f "$session_file" ]; then
    value=$(head -1 "$session_file" 2>/dev/null | tr -d '[:space:]')
    if _se_valid_autonomy_level "$value"; then
      session_level="$value"
      AUTONOMY_LEVEL="$session_level"
    fi
  fi

  AUTONOMY_REQUESTED_LEVEL="$AUTONOMY_LEVEL"
  if [ "$AUTONOMY_LEVEL" -gt "$AUTONOMY_CEILING" ]; then
    AUTONOMY_LEVEL="$AUTONOMY_CEILING"
    AUTONOMY_CLAMPED=1
  fi

  case "$AUTONOMY_LEVEL" in
    1) AUTONOMY_NAME="Pedagogical" ;;
    2) AUTONOMY_NAME="Cautious" ;;
    3) AUTONOMY_NAME="Standard" ;;
    4) AUTONOMY_NAME="Initiative" ;;
    5) AUTONOMY_NAME="Autonomous" ;;
  esac
}
