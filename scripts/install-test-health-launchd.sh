#!/usr/bin/env bash
# Install (or uninstall) the Darwin-arm64 host LaunchAgent for test-health.
#
# The installer renders the plist with the canonical Trellis root and a
# durable, non-interactive launchd PATH; it also installs an executable runner
# snapshot beside the plist so deleting an implementation worktree cannot break
# an already bootstrapped job. Re-running is idempotent: boot out the prior job,
# replace both artifacts atomically, then bootstrap the label again.
#
# Usage:
#   install-test-health-launchd.sh             # install + bootstrap
#   install-test-health-launchd.sh --uninstall # boot out + remove artifacts
#   install-test-health-launchd.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/sed-portable.sh
. "$SCRIPT_DIR/lib/sed-portable.sh"

LABEL="com.trellis.test-health"
TEMPLATE="$SOURCE_ROOT/core-rules/templates/$LABEL.plist"
RUNNER_SOURCE="$SOURCE_ROOT/scripts/run-test-health-host.sh"
LAUNCH_AGENTS_DIR="$USER_HOME/Library/LaunchAgents"
PLIST_DEST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
RUNNER_DEST="$LAUNCH_AGENTS_DIR/$LABEL.runner.sh"
LOCK_FILE="$USER_HOME/Library/Caches/$LABEL.lock"
LAUNCH_DOMAIN="gui/$(id -u)"
DURABLE_CLAUDE_BIN="$USER_HOME/.local/bin/claude"
# launchd starts with only system directories. Bake stable host tool roots rather
# than the installing terminal's session-specific PATH: test-health needs the
# NVM default Node/pnpm toolchain and pyenv shims as well as Homebrew, Bun, Go,
# and Cargo locations.
DURABLE_PATH="$USER_HOME/.local/bin:$USER_HOME/.nvm/default-node/bin:$USER_HOME/.pyenv/shims:$USER_HOME/.bun/bin:$USER_HOME/.cargo/bin:$USER_HOME/go/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

UNINSTALL=false
RUNNER_TMP=""
PLIST_TMP=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
}

cleanup() {
  [ -z "$RUNNER_TMP" ] || rm -f "$RUNNER_TMP"
  [ -z "$PLIST_TMP" ] || rm -f "$PLIST_TMP"
}
trap cleanup EXIT

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      printf 'unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
    *)
      printf 'unexpected argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

remove_agent() {
  launchctl bootout "$LAUNCH_DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_DEST" "$RUNNER_DEST" "$LOCK_FILE"
  printf 'removed: %s\n' "$PLIST_DEST"
  printf 'removed: %s\n' "$RUNNER_DEST"
  printf 'booted out LaunchAgent: %s\n' "$LABEL"
}

render_plist() {
  cp "$TEMPLATE" "$PLIST_TMP"
  # Paths use '/' heavily, so retain the disk-janitor installer's portable
  # delimiter and render only values owned by this installer.
  sed_inplace -e "s|__TRELLIS_ROOT__|$TRELLIS_SOURCE_ROOT|g" "$PLIST_TMP"
  sed_inplace -e "s|__USER_HOME__|$USER_HOME|g" "$PLIST_TMP"
  sed_inplace -e "s|__CLAUDE_BIN__|$DURABLE_CLAUDE_BIN|g" "$PLIST_TMP"
  sed_inplace -e "s|__PATH__|$DURABLE_PATH|g" "$PLIST_TMP"
  /usr/bin/plutil -lint "$PLIST_TMP" >/dev/null
}

preflight_install() {
  [ -f "$TEMPLATE" ] || { printf 'template missing: %s\n' "$TEMPLATE" >&2; exit 1; }
  [ -x "$RUNNER_SOURCE" ] || { printf 'runner missing or not executable: %s\n' "$RUNNER_SOURCE" >&2; exit 1; }

  # Reuse the runner's exact host/root/prompt/Claude preflight before this
  # installer creates either host artifacts or the canonical log directory.
  TRELLIS_ROOT="$TRELLIS_SOURCE_ROOT" CLAUDE_BIN="$DURABLE_CLAUDE_BIN" \
    "$RUNNER_SOURCE" --smoke >/dev/null
}

install_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$USER_HOME/Library/Caches" "$TRELLIS_SOURCE_ROOT/logs"
  RUNNER_TMP="$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.runner.XXXXXX")"
  PLIST_TMP="$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.plist.XXXXXX")"

  cp "$RUNNER_SOURCE" "$RUNNER_TMP"
  chmod 700 "$RUNNER_TMP"
  render_plist

  # bootout by service target works whether the old plist was rendered from a
  # different worktree or has already been removed. Failure means "not loaded".
  launchctl bootout "$LAUNCH_DOMAIN/$LABEL" 2>/dev/null || true
  mv "$RUNNER_TMP" "$RUNNER_DEST"
  RUNNER_TMP=""
  mv "$PLIST_TMP" "$PLIST_DEST"
  PLIST_TMP=""
  launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST_DEST"

  printf 'installed: %s\n' "$PLIST_DEST"
  printf 'installed runner: %s\n' "$RUNNER_DEST"
  printf 'bootstrapped LaunchAgent: %s\n' "$LABEL"
  printf '  runs: %s -p <canonical test-health prompt> (Monday 11:00 local)\n' "$DURABLE_CLAUDE_BIN"
  printf '  logs: %s/logs/test-health.out.log and %s/logs/test-health.err.log\n' "$TRELLIS_SOURCE_ROOT" "$TRELLIS_SOURCE_ROOT"
}

if $UNINSTALL; then
  remove_agent
  exit 0
fi
preflight_install

install_agent
