#!/usr/bin/env bash
# Install (or uninstall) the Trellis disk-janitor LaunchAgents.
#
# By default installs ONE agent: the daily report (`trellis disk-janitor
# --report`, off-peak, report-only, never deletes). With --with-apply it ALSO
# installs the nightly apply agent (`disk-janitor --apply --scopes worktrees
# --yes --safe-only`), which DELETES — but only the unattended-safe set (merged,
# clean, non-detached, non-secret worktrees; pushed-but-unmerged and ephemeral
# /private/tmp trees are never touched by it). The apply agent is opt-in; enable
# it only once the --safe-only predicate is on the host.
#
# Each agent's template is rendered with the real TRELLIS_ROOT / user home / PATH
# substituted, written to ~/Library/LaunchAgents/, and (re)loaded via launchctl.
#
# Idempotent: re-running unloads the existing agent(s) first, so it is safe to
# run after a path change or a template update.
#
# Usage:
#   install-disk-janitor-launchd.sh              # report agent only + load
#   install-disk-janitor-launchd.sh --with-apply # report + nightly apply agent
#   install-disk-janitor-launchd.sh --uninstall  # unload + remove both agents
#   install-disk-janitor-launchd.sh --help
#
# launchd runs with a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) and no shell
# rc, so the installing shell's $PATH is baked into each plist's
# EnvironmentVariables — that is where jq / git / gh / du / find resolve. Run
# this from your normal interactive shell so that PATH is complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/sed-portable.sh
. "$SCRIPT_DIR/lib/sed-portable.sh"

REPORT_LABEL="org.trellis.disk-janitor"
APPLY_LABEL="org.trellis.disk-janitor-apply"
TEMPLATE_DIR="$SOURCE_ROOT/core-rules/templates"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

UNINSTALL=false
WITH_APPLY=false

for arg in "$@"; do
  case "$arg" in
    --uninstall)   UNINSTALL=true ;;
    --with-apply)  WITH_APPLY=true ;;
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

# remove_agent <label> — unload + delete a rendered plist if present.
remove_agent() {
  local label="$1"
  local dest="$LAUNCH_AGENTS_DIR/$label.plist"
  if [ -f "$dest" ]; then
    launchctl unload "$dest" 2>/dev/null || true
    rm -f "$dest"
    echo "removed: $dest"
    echo "unloaded LaunchAgent: $label"
  else
    echo "nothing to do: $dest not present"
  fi
}

# install_agent <label> — render the label's template with real paths and load it.
install_agent() {
  local label="$1"
  local template="$TEMPLATE_DIR/$label.plist"
  local dest="$LAUNCH_AGENTS_DIR/$label.plist"
  [ -f "$template" ] || { echo "template missing: $template" >&2; exit 1; }

  # Path values are full of slashes, so the sed delimiter is '|' not '/'.
  local tmp
  tmp="$(mktemp)"
  cp "$template" "$tmp"
  sed_inplace -e "s|__TRELLIS_ROOT__|$TRELLIS_ROOT|g" "$tmp"
  sed_inplace -e "s|__USER_HOME__|$USER_HOME|g" "$tmp"
  sed_inplace -e "s|__PATH__|$PATH|g" "$tmp"

  launchctl unload "$dest" 2>/dev/null || true
  cp "$tmp" "$dest"
  rm -f "$tmp"
  launchctl load "$dest"
  echo "installed: $dest"
  echo "loaded LaunchAgent: $label"
}

if $UNINSTALL; then
  remove_agent "$APPLY_LABEL"
  remove_agent "$REPORT_LABEL"
  exit 0
fi

mkdir -p "$LAUNCH_AGENTS_DIR"
mkdir -p "$USER_HOME/Library/Logs"

install_agent "$REPORT_LABEL"
echo "  runs: $TRELLIS_ROOT/scripts/trellis disk-janitor --report (daily 03:30, report-only)"
echo "  logs: $USER_HOME/Library/Logs/$REPORT_LABEL.log"

if $WITH_APPLY; then
  echo ""
  echo "!! installing the NIGHTLY APPLY agent — this one DELETES worktrees."
  install_agent "$APPLY_LABEL"
  echo "  runs: $TRELLIS_ROOT/scripts/trellis disk-janitor --apply --scopes worktrees --yes --safe-only (daily 04:00)"
  echo "  reaps ONLY: merged + porcelain-clean + non-detached + non-secret worktrees"
  echo "  NEVER reaps: pushed-but-unmerged, dirty, secret-bearing, or ephemeral /private/tmp trees"
  echo "  logs: $USER_HOME/Library/Logs/$APPLY_LABEL.log"
  echo "  preview what it will reap:  trellis disk-janitor --dry-run --scopes worktrees --safe-only"
fi
