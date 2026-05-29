#!/usr/bin/env bash
# show-config.sh — Pretty-print resolved Trellis configuration.
# Source: Trellis / scripts
#
# Surfaces (1) fleet config from trellis.config.json, (2) project-local
# override (if running inside a registered project), (3) active presets +
# their declared autonomy_ceiling / autonomy_default, (4) resolved
# autonomy level (after all overrides + clamping), (5) approved_mcps if
# configured.
#
# Dependencies: jq (required), git (optional — for canonical-root).

set -u

__SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRELLIS_ROOT="${__SCRIPT_DIR%/scripts}"

if ! command -v jq >/dev/null 2>&1; then
  echo "show-config: jq is required" >&2
  exit 1
fi

CFG="$TRELLIS_ROOT/trellis.config.json"
if [ ! -f "$CFG" ]; then
  echo "show-config: $CFG not found" >&2
  exit 1
fi

echo "=== Trellis fleet config ==="
echo "  trellis_root:       $(jq -r '.trellis_root' "$CFG")"
echo "  projects_root:      $(jq -r '.projects_root' "$CFG")"
echo "  harnesses:          $(jq -r '.harnesses | join(", ")' "$CFG")"
echo "  trellis_version:    $(jq -r '.trellis_version // "(unpinned)"' "$CFG")"
echo "  autonomy_default:   $(jq -r '.autonomy_default // 3' "$CFG")  (hard default = 3)"
echo "  approved_mcps:      $(jq -r '(.approved_mcps // []) | length') entries"
echo ""

# --- Project-local override + active level ---
PROJECT_ROOT=""
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PROJECT_ROOT=$(dirname "$(git rev-parse --git-common-dir)")
fi

PROJECT_CFG=""
PROJECT_AUTONOMY=""
PROJECT_PRESETS=""
SESSION_LEVEL=""
CEILING=""
PRESET_DEFAULT=""
LIMITING_PRESET=""

if [ -n "$PROJECT_ROOT" ] && [ "$PROJECT_ROOT" != "$TRELLIS_ROOT" ]; then
  for cand in "$PROJECT_ROOT/.trellis.config.json" "$PROJECT_ROOT/trellis.config.json"; do
    if [ -f "$cand" ]; then PROJECT_CFG="$cand"; break; fi
  done

  echo "=== Project context ==="
  echo "  project_root:       $PROJECT_ROOT"
  if [ -n "$PROJECT_CFG" ]; then
    echo "  project_config:     $PROJECT_CFG"
    PROJECT_AUTONOMY=$(jq -r '.autonomy // empty' "$PROJECT_CFG")
    PROJECT_PRESETS=$(jq -r '(.presets // []) | join(", ")' "$PROJECT_CFG")
    [ -n "$PROJECT_AUTONOMY" ] && echo "  autonomy override:  $PROJECT_AUTONOMY"
    [ -n "$PROJECT_PRESETS" ] && echo "  presets:            $PROJECT_PRESETS"
  else
    echo "  project_config:     (none — using fleet defaults)"
  fi

  # Session-override file (gitignored)
  SESSION_FILE="$PROJECT_ROOT/.claude/session-autonomy"
  if [ -f "$SESSION_FILE" ]; then
    SESSION_LEVEL=$(head -1 "$SESSION_FILE" | tr -d '[:space:]')
    echo "  session-autonomy:   L$SESSION_LEVEL  ($SESSION_FILE)"
  else
    echo "  session-autonomy:   (unset — no /autonomy run yet this session)"
  fi
  echo ""

  # --- Preset ceiling + resolution ---
  if [ -n "$PROJECT_PRESETS" ]; then
    echo "=== Active preset autonomy ==="
    CEILING=5
    for p in $(jq -r '.presets[]?' "$PROJECT_CFG"); do
      preset_file="$TRELLIS_ROOT/core-rules/presets/$p.md"
      if [ ! -f "$preset_file" ]; then
        echo "  $p: (preset file missing)"
        continue
      fi
      FM_CEIL=$(awk '/^---$/{c++; next} c==1{print}' "$preset_file" | awk '/^autonomy_ceiling:/{print $2}')
      FM_DEF=$(awk '/^---$/{c++; next} c==1{print}' "$preset_file" | awk '/^autonomy_default:/{print $2}')
      echo "  $p:  ceiling=${FM_CEIL:-(none)}  default=${FM_DEF:-(none)}"
      if [ -n "$FM_CEIL" ] && [ "$FM_CEIL" -lt "$CEILING" ] 2>/dev/null; then
        CEILING=$FM_CEIL
        LIMITING_PRESET=$p
      fi
      [ -z "$PRESET_DEFAULT" ] && [ -n "$FM_DEF" ] && PRESET_DEFAULT=$FM_DEF
    done
    echo ""
    echo "  Effective ceiling:  L$CEILING${LIMITING_PRESET:+ (from preset $LIMITING_PRESET)}"
  fi
fi

# --- Resolved active level ---
echo "=== Resolved autonomy level (this turn) ==="
LEVEL=3
[ "$(jq -r '.autonomy_default // empty' "$CFG")" != "" ] && LEVEL=$(jq -r '.autonomy_default' "$CFG")
if [ -n "$PRESET_DEFAULT" ] && [ -z "$PROJECT_AUTONOMY" ]; then LEVEL=$PRESET_DEFAULT; fi
[ -n "$PROJECT_AUTONOMY" ] && LEVEL=$PROJECT_AUTONOMY
[ -n "$SESSION_LEVEL" ] && LEVEL=$SESSION_LEVEL
if [ -n "$CEILING" ] && [ "$LEVEL" -gt "$CEILING" ] 2>/dev/null; then
  echo "  Picked L$LEVEL, clamped to L$CEILING (preset $LIMITING_PRESET)"
  LEVEL=$CEILING
else
  echo "  Active level:       L$LEVEL"
fi

echo ""
echo "Edit fleet defaults: \$EDITOR $CFG"
echo "Edit project config: \$EDITOR ${PROJECT_CFG:-<run inside a registered project>}"
echo "Set session level:   /autonomy N"
echo "See full matrix:     less $TRELLIS_ROOT/core-rules/autonomy.md"
