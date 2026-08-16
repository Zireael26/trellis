#!/usr/bin/env bash
# check-codex-plugin-surface.sh — guard the Codex plugin hook setup a plugin
# update can silently break.
#
# hooks.json commands invoke bare `node`; GUI-spawned panes carry a launchd PATH
# that may not resolve it. They need the PATH="$HOME/.local/bin:$PATH" prefix.
# A plugin update can rewrite hooks.json and remove that prefix. This script
# re-applies it idempotently on both the marketplace checkout and every cache
# copy, and refreshes the ~/.local/bin/node shim if nvm moved the real binary.
#
# Usage: check-codex-plugin-surface.sh [--quiet]
# Exit: 0 = surface as expected (patch present or re-applied); 1 = drift needing a human.

set -euo pipefail

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true
say() { $QUIET || echo "$@"; }

DRIFT=0

# --- node shim ---------------------------------------------------------------
# Resolve the REAL node with ~/.local/bin stripped from PATH, else the shim
# finds itself and we write a self-referential symlink.
mkdir -p "$HOME/.local/bin"
REAL_NODE="$(PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vFx "$HOME/.local/bin" | paste -sd: -)" command -v node || true)"
if [ -n "$REAL_NODE" ]; then
  CURRENT_TARGET="$(readlink "$HOME/.local/bin/node" 2>/dev/null || true)"
  if [ "$CURRENT_TARGET" != "$REAL_NODE" ]; then
    ln -sf "$REAL_NODE" "$HOME/.local/bin/node"
    say "node shim: refreshed ~/.local/bin/node -> $REAL_NODE"
  else
    say "node shim: OK ($REAL_NODE)"
  fi
else
  echo "node shim: no node on PATH — cannot maintain shim" >&2
  DRIFT=1
fi


# --- hooks.json PATH prefix --------------------------------------------------
for HJ in "$HOME"/.claude/plugins/marketplaces/openai-codex/plugins/codex/hooks/hooks.json \
          "$HOME"/.claude/plugins/cache/openai-codex/codex/*/hooks/hooks.json; do
  [ -f "$HJ" ] || continue
  if grep -q '"command": "node ' "$HJ"; then
    python3 - "$HJ" <<'EOF'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
patched = t.replace('"command": "node ', '"command": "PATH=\\"$HOME/.local/bin:$PATH\\" node ')
json.loads(patched)  # refuse to write invalid JSON
p.write_text(patched)
EOF
    say "hooks.json: PATH prefix RE-APPLIED to $HJ (plugin update had reverted it)"
  elif grep -q 'PATH=.*\.local/bin.*node ' "$HJ"; then
    say "hooks.json: patch present in $HJ"
  else
    say "hooks.json: no bare-node commands and no patch in $HJ — structure changed, re-verify manually"
    DRIFT=1
  fi
done

exit $DRIFT
