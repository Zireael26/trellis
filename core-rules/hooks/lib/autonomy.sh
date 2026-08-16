#!/usr/bin/env bash
# Shared autonomy resolution for hook runtimes.
#
# Contract (core-rules/autonomy.md):
#   built-in L3 -> runtime fleet autonomy_default -> first active preset
#   default (only without a project override) -> canonical project autonomy
#   or legacy fallback -> session override -> lowest active preset ceiling.

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
  local canonical_cfg="$repo_root/.trellis.json"
  # DEPRECATED read-only fallback. Retained past v1.0.0-rc.25 only for checkouts
  # still held on the legacy layout; `trellis migrate --prepare` replaces it.
  local legacy_cfg="$repo_root/.trellis.config.json"
  local runtime_cfg="" project_level="" preset_default="" session_level=""
  local project_override_present=0
  local project_cfg_candidate="" preset_cfg="" preset="" preset_file="" value="" session_file=""

  AUTONOMY_LEVEL=3
  AUTONOMY_NAME="Standard"
  AUTONOMY_REQUESTED_LEVEL=3
  AUTONOMY_CEILING=5
  AUTONOMY_CLAMPED=0
  AUTONOMY_LIMITING_PRESET=""

  # The installed payload is the only fleet policy source. Do not resolve a
  # source checkout or consult machine-local configuration here.
  if [ -n "${TRELLIS_ROOT:-}" ] && [ -f "$TRELLIS_ROOT/trellis.config.json" ]; then
    runtime_cfg="$TRELLIS_ROOT/trellis.config.json"
  fi

  if [ -n "$runtime_cfg" ]; then
    value=$(jq -r '.autonomy_default // empty' "$runtime_cfg" 2>/dev/null || true)
    if _se_valid_autonomy_level "$value"; then
      AUTONOMY_LEVEL="$value"
    fi
  fi

  # Resolve autonomy per field: canonical project policy wins, the legacy
  # compatibility file fills only an absent canonical value. A present but
  # malformed higher-precedence value suppresses lower-precedence overrides.
  for project_cfg_candidate in "$canonical_cfg" "$legacy_cfg"; do
    [ -f "$project_cfg_candidate" ] || continue
    if ! jq -e 'type == "object"' "$project_cfg_candidate" >/dev/null 2>&1; then
      project_override_present=1
      break
    fi
    if jq -e 'has("autonomy")' "$project_cfg_candidate" >/dev/null 2>&1; then
      project_override_present=1
      value=$(jq -r '.autonomy' "$project_cfg_candidate" 2>/dev/null || true)
      if _se_valid_autonomy_level "$value"; then
        project_level="$value"
      fi
      break
    fi
  done

  # Active preset names use the same canonical-then-legacy field precedence,
  # while every preset definition is loaded solely from the immutable runtime.
  for project_cfg_candidate in "$canonical_cfg" "$legacy_cfg"; do
    [ -f "$project_cfg_candidate" ] || continue
    if ! jq -e 'type == "object"' "$project_cfg_candidate" >/dev/null 2>&1; then
      break
    fi
    if jq -e 'has("presets")' "$project_cfg_candidate" >/dev/null 2>&1; then
      if jq -e '.presets | type == "array"' "$project_cfg_candidate" >/dev/null 2>&1; then
        preset_cfg="$project_cfg_candidate"
      fi
      break
    fi
  done

  if [ -n "$preset_cfg" ] && [ -n "${TRELLIS_ROOT:-}" ]; then
    # Preset order is the declared config order. The first valid preset default
    # wins; ceiling conflicts always resolve to the lowest (most restrictive).
    while IFS= read -r preset; do
      case "$preset" in
        ''|*[!A-Za-z0-9._-]*) continue ;;
      esac
      preset_file="$TRELLIS_ROOT/core-rules/presets/$preset.md"
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
    done < <(jq -r '.presets[]? | strings' "$preset_cfg" 2>/dev/null || true)
  fi

  if [ -n "$preset_default" ] && [ "$project_override_present" -eq 0 ]; then
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
