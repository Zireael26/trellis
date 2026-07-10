#!/usr/bin/env bash
# Diagnostic-only Codex worker environment preflight. Bash 3.2 compatible.

set -u

MIN_CLI_VERSION="0.144.0"
DEFAULT_MODEL="gpt-5.6-sol"
EFFORT=""
MODEL="$DEFAULT_MODEL"
JSON_MODE=false

usage() {
  echo "Usage: $0 --effort <tier> [--model <model>] [--json]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --effort)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      EFFORT="$2"
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MODEL="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$EFFORT" ]; then
  echo "--effort is required" >&2
  usage
  exit 2
fi

json_quote() {
  # JSON strings used here are single-line probe values. Escape the JSON metacharacters.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolve_path() {
  _rp_path="$1"
  case "$_rp_path" in
    */*) ;;
    *) _rp_path="$(command -v "$_rp_path" 2>/dev/null || true)" ;;
  esac
  [ -n "$_rp_path" ] || return 1

  while [ -L "$_rp_path" ]; do
    _rp_link="$(readlink "$_rp_path" 2>/dev/null)" || return 1
    case "$_rp_link" in
      /*) _rp_path="$_rp_link" ;;
      *) _rp_path="$(dirname "$_rp_path")/$_rp_link" ;;
    esac
  done

  _rp_dir="$(cd -P "$(dirname "$_rp_path")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$_rp_dir" "$(basename "$_rp_path")"
}

version_at_least() {
  awk -v have="$1" -v need="$2" 'BEGIN {
    split(have, h, "."); split(need, n, ".");
    for (i = 1; i <= 3; i++) {
      hv = h[i] + 0; nv = n[i] + 0;
      if (hv > nv) exit 0;
      if (hv < nv) exit 1;
    }
    exit 0;
  }'
}

run_with_timeout() {
  _rwt_seconds="$1"
  shift
  "$@" &
  _rwt_pid=$!
  _rwt_started="$(date +%s)"

  while kill -0 "$_rwt_pid" 2>/dev/null; do
    _rwt_now="$(date +%s)"
    if [ $((_rwt_now - _rwt_started)) -ge "$_rwt_seconds" ]; then
      kill "$_rwt_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$_rwt_pid" 2>/dev/null || true
      wait "$_rwt_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done

  wait "$_rwt_pid"
}

bool_or_null() {
  case "$1" in
    true|false) printf '%s' "$1" ;;
    *) printf 'null' ;;
  esac
}

CLI_OK=false
CLI_VERSION=""
CLI_PATH=""
SHADOWED=unknown
STALE_APP_SERVERS=unknown
COMPANION_PRESENT=false
COMPANION_READY=false
COMPANION_VERSION=""
SUPPORTED_EFFORTS=""
EFFORT_OK=false
PIN_OK=unknown
FINDINGS=""

add_finding() {
  if [ -z "$FINDINGS" ]; then
    FINDINGS="$1"
  else
    FINDINGS="$FINDINGS
$1"
  fi
}

# CLI presence and minimum version.
if [ -n "${CODEX_BIN:-}" ]; then
  CLI_CANDIDATE="$CODEX_BIN"
else
  CLI_CANDIDATE="$(command -v codex 2>/dev/null || true)"
fi

if [ -n "$CLI_CANDIDATE" ] && [ -x "$CLI_CANDIDATE" ]; then
  CLI_PATH="$(resolve_path "$CLI_CANDIDATE" 2>/dev/null || true)"
  CLI_VERSION_OUTPUT="$("$CLI_CANDIDATE" --version 2>&1)"
  CLI_VERSION="$(printf '%s\n' "$CLI_VERSION_OUTPUT" | awk '{
    for (i = 1; i <= NF; i++) {
      value = $i
      sub(/^[^0-9]*/, "", value)
      sub(/[^0-9.].*$/, "", value)
      if (value ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) { print value; exit }
    }
  }')"
  if [ -n "$CLI_PATH" ] && [ -n "$CLI_VERSION" ] && version_at_least "$CLI_VERSION" "$MIN_CLI_VERSION"; then
    CLI_OK=true
  else
    add_finding "Codex CLI must report a parseable version >= $MIN_CLI_VERSION (found: ${CLI_VERSION:-unknown})."
  fi
else
  add_finding "Codex CLI is not executable or is absent."
fi

# Shadowing inventory. Tests may inject the literal output of `which -a codex`.
WHICH_OK=true
if [ -n "${CODEX_WHICH_FILE:-}" ]; then
  if [ -r "$CODEX_WHICH_FILE" ]; then
    WHICH_OUTPUT="$(sed '/^[[:space:]]*$/d' "$CODEX_WHICH_FILE")"
  else
    WHICH_OK=false
    WHICH_OUTPUT=""
  fi
else
  WHICH_OUTPUT="$(which -a codex 2>/dev/null)" || WHICH_OK=false
fi

if [ "$WHICH_OK" = true ]; then
  DISTINCT_PATHS=""
  DISTINCT_COUNT=0
  while IFS= read -r _which_path; do
    [ -n "$_which_path" ] || continue
    _which_resolved="$(resolve_path "$_which_path" 2>/dev/null || true)"
    if [ -z "$_which_resolved" ]; then
      WHICH_OK=false
      break
    fi
    if ! printf '%s\n' "$DISTINCT_PATHS" | grep -Fqx "$_which_resolved"; then
      if [ -z "$DISTINCT_PATHS" ]; then
        DISTINCT_PATHS="$_which_resolved"
      else
        DISTINCT_PATHS="$DISTINCT_PATHS
$_which_resolved"
      fi
      DISTINCT_COUNT=$((DISTINCT_COUNT + 1))
    fi
  done <<EOF
$WHICH_OUTPUT
EOF

  if [ "$WHICH_OK" = true ]; then
    if [ "$DISTINCT_COUNT" -gt 1 ]; then
      SHADOWED=true
      add_finding "Multiple distinct Codex binaries are reported by which -a codex; reconcile PATH/symlinks."
    else
      SHADOWED=false
    fi
  fi
fi

if [ "$WHICH_OK" != true ]; then
  SHADOWED=unknown
  add_finding "Could not inventory Codex installs with which -a codex."
fi

# App-server inventory. Fixture format is the same as `ps -axo pid=,command=`.
PROCESS_OK=true
if [ -n "${PREFLIGHT_PROCESS_FILE:-}" ]; then
  if [ -r "$PREFLIGHT_PROCESS_FILE" ]; then
    PROCESS_OUTPUT="$(sed -n '1,$p' "$PREFLIGHT_PROCESS_FILE")"
  else
    PROCESS_OK=false
    PROCESS_OUTPUT=""
  fi
else
  PROCESS_OUTPUT="$(ps -axo pid=,command= 2>/dev/null)" || PROCESS_OK=false
fi

if [ "$PROCESS_OK" = true ]; then
  STALE_COUNT=0
  while IFS= read -r _process_line; do
    case "$_process_line" in
      *codex*app-server*) ;;
      *) continue ;;
    esac

    _process_trimmed="$(printf '%s' "$_process_line" | sed 's/^[[:space:]]*//')"
    _process_command="${_process_trimmed#* }"
    _process_binary="${_process_command%% *}"
    _process_rest="${_process_command#* }"
    _process_second="${_process_rest%% *}"
    case "$(basename "$_process_binary")" in
      node|nodejs)
        case "$(basename "$_process_second")" in
          codex|codex.js) _process_binary="$_process_second" ;;
        esac
        ;;
    esac
    _process_resolved="$(resolve_path "$_process_binary" 2>/dev/null || true)"
    if [ -z "$_process_resolved" ] || [ -z "$CLI_PATH" ]; then
      PROCESS_OK=false
      break
    fi
    if [ "$_process_resolved" != "$CLI_PATH" ]; then
      STALE_COUNT=$((STALE_COUNT + 1))
    fi
  done <<EOF
$PROCESS_OUTPUT
EOF

  if [ "$PROCESS_OK" = true ]; then
    STALE_APP_SERVERS="$STALE_COUNT"
    if [ "$STALE_COUNT" -gt 0 ]; then
      add_finding "$STALE_COUNT stale Codex app-server process(es) use a different binary; restart them outside this script."
    fi
  fi
fi

if [ "$PROCESS_OK" != true ]; then
  STALE_APP_SERVERS=unknown
  add_finding "Could not determine Codex app-server binary paths."
fi

# Resolve the companion without changing plugin state.
if [ -n "${COMPANION_PATH:-}" ]; then
  COMPANION="$COMPANION_PATH"
elif [ -n "${CODEX_PLUGIN:-}" ]; then
  COMPANION="$CODEX_PLUGIN/scripts/codex-companion.mjs"
else
  COMPANION=""
  for _candidate in "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs; do
    [ -f "$_candidate" ] && COMPANION="$_candidate"
  done
fi

NODE_COMMAND="${NODE_BIN:-$(command -v node 2>/dev/null || true)}"
TIMEOUT_SECONDS="${PREFLIGHT_TIMEOUT_SECONDS:-15}"
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*|0) TIMEOUT_SECONDS=15 ;;
esac

if [ -n "$COMPANION" ] && [ -r "$COMPANION" ]; then
  COMPANION_PRESENT=true
  COMPANION_ROOT="$(cd "$(dirname "$COMPANION")/.." 2>/dev/null && pwd -P || true)"
  PLUGIN_MANIFEST="$COMPANION_ROOT/.claude-plugin/plugin.json"
  if [ -r "$PLUGIN_MANIFEST" ]; then
    COMPANION_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_MANIFEST" | head -1)"
  fi

  if [ -n "$NODE_COMMAND" ] && [ -x "$NODE_COMMAND" ]; then
    HELP_OUTPUT="$(run_with_timeout "$TIMEOUT_SECONDS" "$NODE_COMMAND" "$COMPANION" help 2>&1)"
    HELP_STATUS=$?
    if [ "$HELP_STATUS" -eq 0 ]; then
      EFFORT_ENUM="$(printf '%s\n' "$HELP_OUTPUT" | sed -n 's/.*--effort <\([^>]*\)>.*/\1/p' | head -1)"
      if [ -n "$EFFORT_ENUM" ]; then
        SUPPORTED_EFFORTS="$(printf '%s' "$EFFORT_ENUM" | tr '|' '\n' | sed '/^$/d')"
        if printf '%s\n' "$SUPPORTED_EFFORTS" | grep -Fqx "$EFFORT"; then
          EFFORT_OK=true
        else
          add_finding "Requested effort '$EFFORT' is not supported by the companion."
        fi
      else
        add_finding "Companion help did not expose a parseable --effort enum."
      fi
    else
      add_finding "Companion help probe failed or timed out."
    fi

    SETUP_OUTPUT="$(run_with_timeout "$TIMEOUT_SECONDS" "$NODE_COMMAND" "$COMPANION" setup --json 2>&1)"
    SETUP_STATUS=$?
    JQ_COMMAND="${JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
    if [ "$SETUP_STATUS" -eq 0 ] && [ -n "$JQ_COMMAND" ] && [ -x "$JQ_COMMAND" ]; then
      if printf '%s\n' "$SETUP_OUTPUT" | "$JQ_COMMAND" -e '.ready == true and .codex.available == true and .auth.loggedIn == true' >/dev/null 2>&1; then
        COMPANION_READY=true
      else
        add_finding "Companion setup is not ready (requires ready, codex.available, and auth.loggedIn)."
      fi
    else
      add_finding "Companion setup --json probe failed, timed out, or could not be parsed."
    fi
  else
    add_finding "Node is unavailable, so companion probes cannot run."
  fi

  if [ -z "$COMPANION_VERSION" ]; then
    add_finding "Companion version could not be read from .claude-plugin/plugin.json."
  fi
fi

# The Sol model is pinned by config; other explicitly requested models do not use this pin.
if [ "$MODEL" = "$DEFAULT_MODEL" ]; then
  CONFIG_PATH="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
  if [ -r "$CONFIG_PATH" ]; then
    if grep -Eq '^model[[:space:]]*=[[:space:]]*"gpt-5\.6-sol"' "$CONFIG_PATH"; then
      PIN_OK=true
    else
      PIN_OK=false
      add_finding "Model pin is missing or wrong in $CONFIG_PATH (expected gpt-5.6-sol)."
    fi
  else
    PIN_OK=false
    add_finding "Codex config is missing or unreadable at $CONFIG_PATH."
  fi
else
  PIN_OK=true
fi

ENVIRONMENT_RED=false
[ "$CLI_OK" = true ] || ENVIRONMENT_RED=true
[ "$SHADOWED" = false ] || ENVIRONMENT_RED=true
case "$STALE_APP_SERVERS" in
  0) ;;
  *) ENVIRONMENT_RED=true ;;
esac
[ "$PIN_OK" = true ] || ENVIRONMENT_RED=true

if [ "$COMPANION_PRESENT" = true ]; then
  [ -n "$COMPANION_VERSION" ] || ENVIRONMENT_RED=true
  [ "$EFFORT_OK" = true ] || ENVIRONMENT_RED=true
  [ "$COMPANION_READY" = true ] || ENVIRONMENT_RED=true
fi

if [ "$ENVIRONMENT_RED" = true ]; then
  VERDICT="environment-red"
  EXIT_STATUS=1
elif [ "$COMPANION_PRESENT" != true ]; then
  VERDICT="companion-absent"
  EXIT_STATUS=0
else
  VERDICT="green"
  EXIT_STATUS=0
fi

if [ "$JSON_MODE" = true ]; then
  printf '{'
  printf '"cli_ok":%s,' "$CLI_OK"
  if [ -n "$CLI_VERSION" ]; then
    printf '"cli_version":"%s",' "$(json_quote "$CLI_VERSION")"
  else
    printf '"cli_version":null,'
  fi
  printf '"shadowed":%s,' "$(bool_or_null "$SHADOWED")"
  case "$STALE_APP_SERVERS" in
    unknown) printf '"stale_app_servers":null,' ;;
    *) printf '"stale_app_servers":%s,' "$STALE_APP_SERVERS" ;;
  esac
  printf '"companion_present":%s,' "$COMPANION_PRESENT"
  printf '"companion_ready":%s,' "$COMPANION_READY"
  printf '"supported_efforts":['
  _first=true
  while IFS= read -r _effort; do
    [ -n "$_effort" ] || continue
    if [ "$_first" = true ]; then _first=false; else printf ','; fi
    printf '"%s"' "$(json_quote "$_effort")"
  done <<EOF
$SUPPORTED_EFFORTS
EOF
  printf '],'
  printf '"pin_ok":%s,' "$(bool_or_null "$PIN_OK")"
  printf '"verdict":"%s"}\n' "$VERDICT"
else
  echo "Codex worker preflight (diagnostic only)"
  echo "  cli:               $CLI_OK (${CLI_VERSION:-unknown}; ${CLI_PATH:-unresolved})"
  echo "  shadowed:          $SHADOWED"
  echo "  stale_app_servers: $STALE_APP_SERVERS"
  echo "  companion_present: $COMPANION_PRESENT (${COMPANION_VERSION:-unknown}; ${COMPANION:-unresolved})"
  echo "  companion_ready:   $COMPANION_READY"
  echo "  supported_efforts: $(printf '%s' "$SUPPORTED_EFFORTS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  echo "  requested_effort:  $EFFORT"
  echo "  model_pin:         $PIN_OK ($MODEL)"
  if [ -n "$FINDINGS" ]; then
    echo "Findings:"
    while IFS= read -r _finding; do
      [ -n "$_finding" ] && echo "  - $_finding"
    done <<EOF
$FINDINGS
EOF
  fi
  echo "Verdict: $VERDICT"
fi

exit "$EXIT_STATUS"
