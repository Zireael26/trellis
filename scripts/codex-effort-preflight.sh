#!/usr/bin/env bash
# codex-effort-preflight.sh — the spec 011 D6 surface preflight (SC6).
#
# Probes the INSTALLED Codex surface and reports what it actually accepts —
# never assumes. Three probes, all fail-closed:
#
#   (a) model pin  — parse `model = "…"` from the Codex config and compare to
#       the expected pin ($1, default gpt-5.6-sol). Missing file / missing key
#       / wrong value → pin_ok: false.
#   (b) effort enum — extract the accepted --effort values from the installed
#       companion plugin's validator SOURCE (the search pattern is hardcoded;
#       the resulting tier set never is — verified-surface rule, spec 011 §4).
#       Missing plugin / no validator match → supported_efforts: [] (fail-closed).
#   (c) CLI version — `codex --version`; cli_ok = semver >= 0.144 (the floor
#       for per-dispatch --model pinning, 013 handoff). Missing binary /
#       unparsable output → cli_ok: false.
#
# THE SCRIPT ONLY REPORTS; CALLERS DECIDE. It always exits 0 with a JSON
# report on stdout — a Claude-only host (no plugin, no CLI) gets a fully
# fail-closed report, never an error exit. The main loop threads
# `supported_efforts` into recipes as `args.supportedEfforts` and refuses
# exception-tier dispatch when pin_ok/cli_ok gate it, logging the refusal.
#
# Output JSON shape (exactly these five fields):
#   { "model_pin": "<value|absent>", "pin_ok": bool,
#     "supported_efforts": [...], "cli_version": "<v|absent>", "cli_ok": bool }
#
# Env overrides (for tests — bats fixtures point these at fakes):
#   CODEX_CONFIG  path to config.toml   (default: $HOME/.codex/config.toml)
#   CODEX_PLUGIN  companion plugin root (default: the installed-plugin cache,
#                 $HOME/.claude/plugins/cache/openai-codex/codex — searched
#                 recursively, so versioned subdirs are fine)
#   CODEX_BIN     codex binary          (default: codex, resolved via PATH)
#
# bash 3.2 / macOS compatible. No jq, no bash-4isms.

set -u

EXPECTED_PIN="${1:-gpt-5.6-sol}"
CONFIG_PATH="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
PLUGIN_ROOT="${CODEX_PLUGIN:-$HOME/.claude/plugins/cache/openai-codex/codex}"
CODEX_BIN="${CODEX_BIN:-codex}"

# The CLI-version floor for per-dispatch --model pinning (013 handoff item 5).
CLI_FLOOR_MAJOR=0
CLI_FLOOR_MINOR=144

# Minimal JSON string escaping (backslash + double quote) — the probed values
# are model names / versions, but never trust input to a report format.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# --- Probe (a): model pin ---------------------------------------------------
model_pin="absent"
pin_ok=false
if [ -f "$CONFIG_PATH" ]; then
  # First top-level `model = "…"` assignment wins (host-global, unversioned —
  # verify per the 009 network-preflight pattern).
  parsed_pin="$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" 2>/dev/null | head -n 1)"
  if [ -n "$parsed_pin" ]; then
    model_pin="$parsed_pin"
    if [ "$model_pin" = "$EXPECTED_PIN" ]; then
      pin_ok=true
    fi
  fi
fi

# --- Probe (b): companion effort enum ----------------------------------------
# Search pattern for the companion's validator site (companion v1.0.5 keeps it
# in scripts/codex-companion.mjs as VALID_REASONING_EFFORTS; the location may
# move across upgrades, so we search every .mjs under the plugin root). If the
# validator moves beyond this pattern, the report degrades to [] — fail-closed,
# and the pattern gets updated (spec 011 plan, Risks).
ENUM_PATTERN='VALID_REASONING_EFFORTS[[:space:]]*=[[:space:]]*new Set\(\['
supported_efforts=""
if [ -d "$PLUGIN_ROOT" ]; then
  # Newest matching file wins (multiple cached plugin versions may match).
  newest=""
  match_list="$(grep -rlE "$ENUM_PATTERN" "$PLUGIN_ROOT" 2>/dev/null || true)"
  if [ -n "$match_list" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
        newest="$f"
      fi
    done <<EOF
$match_list
EOF
  fi
  if [ -n "$newest" ]; then
    enum_line="$(grep -E "$ENUM_PATTERN" "$newest" 2>/dev/null | head -n 1)"
    # The quoted lowercase tokens inside the Set literal ARE the accepted set.
    supported_efforts="$(printf '%s\n' "$enum_line" | grep -oE '"[a-z]+"' | tr -d '"' || true)"
  fi
fi

# Build the JSON array (fail-closed default: empty).
efforts_json=""
if [ -n "$supported_efforts" ]; then
  while IFS= read -r tier; do
    [ -z "$tier" ] && continue
    if [ -n "$efforts_json" ]; then
      efforts_json="$efforts_json, "
    fi
    efforts_json="$efforts_json\"$(json_escape "$tier")\""
  done <<EOF
$supported_efforts
EOF
fi

# --- Probe (c): CLI version ---------------------------------------------------
cli_version="absent"
cli_ok=false
if command -v "$CODEX_BIN" >/dev/null 2>&1; then
  version_out="$("$CODEX_BIN" --version 2>/dev/null || true)"
  parsed_version="$(printf '%s\n' "$version_out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)"
  if [ -n "$parsed_version" ]; then
    cli_version="$parsed_version"
    v_major="$(printf '%s' "$parsed_version" | cut -d. -f1)"
    v_minor="$(printf '%s' "$parsed_version" | cut -d. -f2)"
    case "$v_major$v_minor" in
      *[!0-9]*) : ;; # non-numeric — stay fail-closed
      *)
        if [ "$v_major" -gt "$CLI_FLOOR_MAJOR" ] 2>/dev/null; then
          cli_ok=true
        elif [ "$v_major" -eq "$CLI_FLOOR_MAJOR" ] 2>/dev/null && [ "$v_minor" -ge "$CLI_FLOOR_MINOR" ] 2>/dev/null; then
          cli_ok=true
        fi
        ;;
    esac
  fi
fi

# --- Report ------------------------------------------------------------------
printf '{ "model_pin": "%s", "pin_ok": %s, "supported_efforts": [%s], "cli_version": "%s", "cli_ok": %s }\n' \
  "$(json_escape "$model_pin")" \
  "$pin_ok" \
  "$efforts_json" \
  "$(json_escape "$cli_version")" \
  "$cli_ok"

exit 0
