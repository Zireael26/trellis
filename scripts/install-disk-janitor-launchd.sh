#!/usr/bin/env bash
# Install (or uninstall) the Trellis disk-janitor LaunchAgent.
#
# Renders core-rules/templates/org.trellis.disk-janitor.plist with the real
# TRELLIS_ROOT / user home / PATH substituted, writes it to
# ~/Library/LaunchAgents/, and (re)loads it via launchctl. The agent runs
# `trellis disk-janitor --report` daily off-peak — report-only, never --apply.
#
# Idempotent: re-running unloads the existing agent first, so it is safe to run
# after a path change or a template update.
#
# Usage:
#   install-disk-janitor-launchd.sh             # install / refresh + load
#   install-disk-janitor-launchd.sh --uninstall # unload + remove the plist
#   install-disk-janitor-launchd.sh --help
#
# launchd runs with a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) and no shell
# rc, so the installing shell's $PATH is baked into the plist's
# EnvironmentVariables — that is where jq / git / gh / du / find resolve. Run
# this from your normal interactive shell so that PATH is complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/sed-portable.sh
. "$SCRIPT_DIR/lib/sed-portable.sh"

LABEL="org.trellis.disk-janitor"
TEMPLATE="$SOURCE_ROOT/core-rules/templates/$LABEL.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEST="$LAUNCH_AGENTS_DIR/$LABEL.plist"

UNINSTALL=false

for arg in "$@"; do
  case "$arg" in
    --uninstall)  UNINSTALL=true ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
    *)
      echo "unexpected argument: $arg" >&2
      exit 2
      ;;
  esac
done

if $UNINSTALL; then
  if [ -f "$DEST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    echo "removed: $DEST"
    echo "unloaded LaunchAgent: $LABEL"
  else
    echo "nothing to do: $DEST not present"
  fi
  exit 0
fi

[ -f "$TEMPLATE" ] || { echo "template missing: $TEMPLATE" >&2; exit 1; }

# Render the template into a temp copy, then move into place. Path values are
# full of slashes, so the sed delimiter is '|' not '/'.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$TEMPLATE" "$tmp"
sed_inplace -e "s|__TRELLIS_ROOT__|$TRELLIS_ROOT|g" "$tmp"
sed_inplace -e "s|__USER_HOME__|$USER_HOME|g" "$tmp"
sed_inplace -e "s|__PATH__|$PATH|g" "$tmp"

mkdir -p "$LAUNCH_AGENTS_DIR"
mkdir -p "$USER_HOME/Library/Logs"

# Reload: unload any prior copy (ignore "not loaded"), install, load.
launchctl unload "$DEST" 2>/dev/null || true
cp "$tmp" "$DEST"
launchctl load "$DEST"

echo "installed: $DEST"
echo "loaded LaunchAgent: $LABEL"
echo "  runs: $TRELLIS_ROOT/scripts/trellis disk-janitor --report (daily 03:30, report-only)"
echo "  logs: $USER_HOME/Library/Logs/$LABEL.log"
