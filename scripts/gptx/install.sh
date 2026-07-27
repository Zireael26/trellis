#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" = /* ]] || SOURCE="$SOURCE_DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")/../.." && pwd)"

DRY_RUN=false
UNINSTALL=false
START_SERVICES=true
REPLACE_PROXY=false
PROXY_SOURCE=
PROXY_CONFIG=
MANIFEST="${TRELLIS_GPTX_MANIFEST:-$HOME/.trellis/gptx-install.json}"

usage() {
  cat <<'EOF'
Usage: scripts/gptx/install.sh [options]

Install the public Trellis GPTX launcher, agents, settings overlay, and services.

  --proxy-bin PATH          Trellis CLIProxyAPI fork binary to install
  --proxy-config PATH       Existing CLIProxyAPI YAML config
  --replace-running-proxy   Stop Homebrew cliproxyapi and start the fork service
  --no-start                Write files but do not bootstrap services
  --dry-run                 Validate and print actions without changing files
  --uninstall               Revert the recorded installation
  -h, --help                Show this help
EOF
}

die() {
  printf 'gptx-install: %s\n' "$*" >&2
  exit 2
}

bootstrap_launch_agent() {
  local plist="$1"
  if launchctl bootstrap "$GUI_DOMAIN" "$plist"; then
    return 0
  fi
  # launchd can report EIO for a short interval after bootout even though the
  # label is already gone. One bounded retry handles that observed reload race.
  sleep 1
  launchctl bootstrap "$GUI_DOMAIN" "$plist"
}

while (($#)); do
  case "$1" in
    --proxy-bin)
      (($# >= 2)) || die "--proxy-bin requires a path"
      PROXY_SOURCE=$2
      shift 2
      ;;
    --proxy-bin=*)
      PROXY_SOURCE=${1#*=}
      shift
      ;;
    --proxy-config)
      (($# >= 2)) || die "--proxy-config requires a path"
      PROXY_CONFIG=$2
      shift 2
      ;;
    --proxy-config=*)
      PROXY_CONFIG=${1#*=}
      shift
      ;;
    --replace-running-proxy)
      REPLACE_PROXY=true
      shift
      ;;
    --no-start)
      START_SERVICES=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

for command_name in node jq; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing dependency: $command_name"
done

SETTINGS="$HOME/.claude/settings.json"
BIN_DIR="$HOME/.local/bin"
LIBEXEC_DIR="$HOME/.local/libexec"
AGENTS_DIR="$HOME/.claude/agents"
BACKUP_DIR="$HOME/.trellis/backups/gptx"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
STATE_DIR="$HOME/.cli-proxy-api"
ROUTER_PLIST="$LAUNCH_DIR/dev.trellis.gptx-router.plist"
PROXY_PLIST="$LAUNCH_DIR/dev.trellis.cliproxyapi.plist"
INSTALLED_PROXY="$LIBEXEC_DIR/trellis-cliproxyapi"
NODE_BIN="$(command -v node)"
GUI_DOMAIN="gui/$(id -u)"

if [[ "$UNINSTALL" == true ]]; then
  [[ -f "$MANIFEST" ]] || die "no install manifest at $MANIFEST"
  if [[ "$DRY_RUN" == true ]]; then
    jq '{action:"uninstall", manifest:input_filename, recorded:.}' "$MANIFEST"
    exit 0
  fi

  launchctl bootout "$GUI_DOMAIN/dev.trellis.gptx-router" 2>/dev/null || true
  launchctl bootout "$GUI_DOMAIN/dev.trellis.cliproxyapi" 2>/dev/null || true
  settings_backup="$(jq -r '.settings_backup // empty' "$MANIFEST")"
  if [[ -n "$settings_backup" && -f "$settings_backup" ]]; then
    cp "$settings_backup" "$SETTINGS"
  fi
  for link in cmux-trellis-teams gptx-doctor; do
    [[ -L "$BIN_DIR/$link" ]] && rm -f "$BIN_DIR/$link"
  done
  while IFS= read -r agent; do
    [[ -L "$agent" ]] && rm -f "$agent"
  done < <(jq -r '.agent_links[]? // empty' "$MANIFEST")
  rm -f "$ROUTER_PLIST" "$PROXY_PLIST"
  if [[ "$(jq -r '.installed_proxy // false' "$MANIFEST")" == true ]]; then
    rm -f "$INSTALLED_PROXY"
  fi
  if [[ "$(jq -r '.homebrew_proxy_was_running // false' "$MANIFEST")" == true ]]; then
    brew services start cliproxyapi >/dev/null
  fi
  rm -f "$MANIFEST"
  printf 'gptx-install: reverted settings, launch agents, command links, and installed fork binary\n'
  exit 0
fi

[[ "$(uname -s)" == Darwin ]] || die "service installation currently supports macOS"
[[ -f "$ROOT/scripts/gptx/router.js" ]] || die "run this script from a complete Trellis checkout"
[[ -f "$SETTINGS" ]] || die "Claude Code settings not found at $SETTINGS"
jq -e . "$SETTINGS" >/dev/null || die "Claude Code settings is not valid JSON: $SETTINGS"

if [[ -z "$PROXY_CONFIG" ]]; then
  if [[ -f /opt/homebrew/etc/cliproxyapi.conf ]]; then
    PROXY_CONFIG=/opt/homebrew/etc/cliproxyapi.conf
  else
    PROXY_CONFIG="$HOME/.cli-proxy-api/config.yaml"
  fi
fi
[[ -f "$PROXY_CONFIG" ]] || die "CLIProxyAPI config not found: $PROXY_CONFIG"

if [[ -n "$PROXY_SOURCE" ]]; then
  [[ -x "$PROXY_SOURCE" ]] || die "fork binary is not executable: $PROXY_SOURCE"
fi
if [[ "$REPLACE_PROXY" == true && -z "$PROXY_SOURCE" ]]; then
  die "--replace-running-proxy requires --proxy-bin"
fi

CONTEXT_JSON="$(node "$ROOT/scripts/gptx/model-context.js" --model gpt-5.6-sol)"
CONTEXT="$(jq -er '.claude_code_max_context_tokens' <<<"$CONTEXT_JSON")"
HOME_BREW_RUNNING=false
if command -v brew >/dev/null 2>&1 \
  && brew services list 2>/dev/null | awk '$1=="cliproxyapi" && $2=="started" {found=1} END {exit !found}'; then
  HOME_BREW_RUNNING=true
fi
if [[ -f "$MANIFEST" ]] && jq -e . "$MANIFEST" >/dev/null 2>&1; then
  # An update must preserve the first install's rollback target. Re-basing the
  # backup and service state on an already-modified installation would make
  # `--uninstall` restore GPTX to itself and forget the prior Homebrew service.
  prior_homebrew="$(jq -r '.homebrew_proxy_was_running // false' "$MANIFEST")"
  [[ "$prior_homebrew" == true ]] && HOME_BREW_RUNNING=true
fi

if [[ "$DRY_RUN" == true ]]; then
  jq -n \
    --arg root "$ROOT" \
    --arg settings "$SETTINGS" \
    --arg context "$CONTEXT" \
    --arg proxy_source "$PROXY_SOURCE" \
    --arg proxy_config "$PROXY_CONFIG" \
    --argjson replace "$REPLACE_PROXY" \
    --argjson start "$START_SERVICES" \
    '{
      action:"install",
      trellis_root:$root,
      settings:$settings,
      claude_code_max_context_tokens:$context,
      auto_compact_window:"unset",
      proxy_source:(if ($proxy_source | length) > 0 then $proxy_source else null end),
      proxy_config:$proxy_config,
      replace_running_proxy:$replace,
      start_services:$start
    }'
  exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BIN_DIR" "$LIBEXEC_DIR" "$AGENTS_DIR" "$BACKUP_DIR" "$LAUNCH_DIR" "$STATE_DIR" "$(dirname "$MANIFEST")"
chmod 700 "$STATE_DIR"
installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
settings_backup=
if [[ -f "$MANIFEST" ]] && jq -e . "$MANIFEST" >/dev/null 2>&1; then
  settings_backup="$(jq -r '.settings_backup // empty' "$MANIFEST")"
  installed_at="$(jq -r '.installed_at // empty' "$MANIFEST")"
fi
if [[ -z "$settings_backup" || ! -f "$settings_backup" ]]; then
  settings_backup="$BACKUP_DIR/settings.$timestamp.json"
  cp "$SETTINGS" "$settings_backup"
fi

temporary_settings="$(mktemp "${TMPDIR:-/tmp}/trellis-gptx-settings.XXXXXX")"
jq \
  --arg context "$CONTEXT" \
  '.env = (.env // {})
   | .env.ANTHROPIC_BASE_URL = "http://127.0.0.1:8318"
   | .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = $context
   | del(.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW)' \
  "$SETTINGS" > "$temporary_settings"
mv "$temporary_settings" "$SETTINGS"

ln -sfn "$ROOT/scripts/cmux-trellis-teams" "$BIN_DIR/cmux-trellis-teams"
ln -sfn "$ROOT/scripts/gptx/doctor.sh" "$BIN_DIR/gptx-doctor"

agent_links=()
for agent in gpt-mid gpt-high gpt-sol gpt-terra gpt-sol-advisor; do
  target="$AGENTS_DIR/$agent.md"
  ln -sfn "$ROOT/core-rules/agents/$agent.md" "$target"
  agent_links+=("$target")
done

cat > "$ROUTER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.trellis.gptx-router</string>
  <key>ProgramArguments</key><array>
    <string>$NODE_BIN</string><string>$ROOT/scripts/gptx/router.js</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$STATE_DIR/gptx-router.out.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/gptx-router.err.log</string>
</dict></plist>
EOF

installed_proxy=false
if [[ -n "$PROXY_SOURCE" ]]; then
  install -m 0755 "$PROXY_SOURCE" "$INSTALLED_PROXY"
  installed_proxy=true
  cat > "$PROXY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.trellis.cliproxyapi</string>
  <key>ProgramArguments</key><array>
    <string>$INSTALLED_PROXY</string><string>-config</string><string>$PROXY_CONFIG</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/trellis-cliproxyapi.out.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/trellis-cliproxyapi.err.log</string>
</dict></plist>
EOF
fi

agent_links_json="$(printf '%s\n' "${agent_links[@]}" | jq -Rsc 'split("\n")[:-1]')"
jq -n \
  --arg installed_at "$installed_at" \
  --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg root "$ROOT" \
  --arg settings_backup "$settings_backup" \
  --arg proxy_config "$PROXY_CONFIG" \
  --argjson agent_links "$agent_links_json" \
  --argjson installed_proxy "$installed_proxy" \
  --argjson homebrew_proxy_was_running "$HOME_BREW_RUNNING" \
  '{
    installed_at:$installed_at,
    updated_at:$updated_at,
    trellis_root:$root,
    settings_backup:$settings_backup,
    proxy_config:$proxy_config,
    agent_links:$agent_links,
    installed_proxy:$installed_proxy,
    homebrew_proxy_was_running:$homebrew_proxy_was_running
  }' > "$MANIFEST"

if [[ "$START_SERVICES" == true ]]; then
  if [[ "$REPLACE_PROXY" == true ]]; then
    brew services stop cliproxyapi >/dev/null
    launchctl bootout "$GUI_DOMAIN/dev.trellis.cliproxyapi" 2>/dev/null || true
    bootstrap_launch_agent "$PROXY_PLIST"
  fi
  launchctl bootout "$GUI_DOMAIN/dev.gptx.router" 2>/dev/null || true
  launchctl bootout "$GUI_DOMAIN/dev.trellis.gptx-router" 2>/dev/null || true
  bootstrap_launch_agent "$ROUTER_PLIST"
fi

printf 'gptx-install: installed context=%s, AUTO_COMPACT_WINDOW unset\n' "$CONTEXT"
printf 'gptx-install: launch with cmux-trellis-teams --mode hybrid --dangerously-skip-permissions\n'
printf 'gptx-install: revert with %s --uninstall\n' "$ROOT/scripts/gptx/install.sh"
