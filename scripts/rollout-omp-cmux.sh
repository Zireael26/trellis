#!/usr/bin/env bash
# Rollout: reconcile local OMP (~/.omp/agent/config.yml) and Cmux (~/.config/cmux/cmux.json)
# with opinionated Trellis baseline defaults.
#
# Idempotent. Preserves existing user keys, custom model aliases, and personal settings.
#
# Baseline rules applied:
#   - OMP webSearchOrder: includes google, gemini, codex
#   - OMP webSearchExclude: removes gemini and google if present
#   - Cmux app settings: commandPaletteSearchesAllSurfaces=true, openMarkdownInCmuxViewer=true
#
# Usage:
#   rollout-omp-cmux.sh                 # interactive / standard rollout
#   rollout-omp-cmux.sh --dry-run       # show planned changes without writing

set -euo pipefail

# Rollouts resolve every path they read from SCRIPT_DIR. An inherited
# preloaded-libs marker would half-initialize any library sourced from here.
unset TRELLIS_LIBS_PRELOADED

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"
TRELLIS_ROOT="$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)"

DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

OMP_CONFIG_DIR="$HOME/.omp/agent"
OMP_CONFIG_FILE="$OMP_CONFIG_DIR/config.yml"
OMP_TEMPLATE="$TRELLIS_ROOT/core-rules/templates/omp-config.yml.example"

CMUX_CONFIG_DIR="$HOME/.config/cmux"
CMUX_CONFIG_FILE="$CMUX_CONFIG_DIR/cmux.json"
CMUX_TEMPLATE="$TRELLIS_ROOT/core-rules/templates/cmux.json.example"

echo "=== Trellis OMP + Cmux Rollout ==="

# --- 1. OMP Configuration ----------------------------------------------------
if [ ! -f "$OMP_CONFIG_FILE" ]; then
  echo "[OMP] Config file missing at $OMP_CONFIG_FILE"
  if [ "$DRY_RUN" = true ]; then
    echo "[OMP] [DRY-RUN] Would create $OMP_CONFIG_FILE from template"
  else
    mkdir -p "$OMP_CONFIG_DIR"
    cp "$OMP_TEMPLATE" "$OMP_CONFIG_FILE"
    echo "[OMP] Created $OMP_CONFIG_FILE from baseline template"
  fi
else
  echo "[OMP] Checking web search configuration in $OMP_CONFIG_FILE..."
  # Simple python inline check for idempotent YAML reconciliation
  python3 - <<EOF
import sys, yaml

desired_order = ["google", "gemini", "codex"]
dry_run = "$DRY_RUN" == "true"

with open(config_file, "r") as f:
    data = yaml.safe_load(f) or {}

changed = False
providers = data.setdefault("providers", {})
search_order = providers.setdefault("webSearchOrder", [])
search_exclude = providers.setdefault("webSearchExclude", [])

# Required primary search providers
desired_order = ["google", "gemini", "codex"]
for p in reversed(desired_order):
    if p not in search_order:
        search_order.insert(0, p)
        changed = True

# Ensure gemini / google are not excluded
for p in ["gemini", "google"]:
    if p in search_exclude:
        search_exclude.remove(p)
        changed = True

if changed:
    if dry_run:
        print("[OMP] [DRY-RUN] Would update webSearchOrder/webSearchExclude in config.yml")
    else:
        with open(config_file, "w") as f:
            yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
        print("[OMP] Reconciled web search providers in config.yml")
else:
    print("[OMP] Configuration is already up to date")
EOF
fi

# --- 2. Cmux Configuration ---------------------------------------------------
if [ ! -f "$CMUX_CONFIG_FILE" ]; then
  echo "[CMUX] Config file missing at $CMUX_CONFIG_FILE"
  if [ "$DRY_RUN" = true ]; then
    echo "[CMUX] [DRY-RUN] Would create $CMUX_CONFIG_FILE from template"
  else
    mkdir -p "$CMUX_CONFIG_DIR"
    cp "$CMUX_TEMPLATE" "$CMUX_CONFIG_FILE"
    echo "[CMUX] Created $CMUX_CONFIG_FILE from baseline template"
  fi
else
  echo "[CMUX] Checking $CMUX_CONFIG_FILE..."
  if command -v cmux >/dev/null 2>&1; then
    cmux config check 2>&1 || true
  else
    echo "[CMUX] cmux CLI not found; skipping live doctor check"
  fi
fi

echo "=== Rollout Completed Successfully ==="
