#!/usr/bin/env bash
# check-codex-plugin-surface.sh — guard the two things a codex plugin update silently breaks.
#
# 1. Companion effort enum: v1.0.5 rejects everything above xhigh
#    (VALID_REASONING_EFFORTS in codex-companion.mjs). When an update widens it,
#    recipe-side `max` becomes unblockable (ultra additionally needs per-subagent
#    visibility) — see follow-ups.md + docs/adr/2026-07-10-sol-ultra-capability-reground.md.
#    This script REPORTS the change; it never edits doctrine.
# 2. Teammate node/PATH fix: hooks.json commands need the
#    PATH="$HOME/.local/bin:$PATH" prefix on bare `node` invocations (GUI-spawned
#    panes carry launchd PATH — gotchas.md 2026-07-10). A plugin update rewrites
#    hooks.json and reverts the patch. This script RE-APPLIES it idempotently,
#    on both the marketplace checkout and every cache copy. It also refreshes
#    the ~/.local/bin/node shim if nvm moved the real binary.
#
# Usage: check-codex-plugin-surface.sh [--quiet]
# Exit: 0 = surface as expected (patch present or re-applied); 1 = drift needing a human.

set -euo pipefail

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true
say() { $QUIET || echo "$@"; }

DRIFT=0
BASELINE_ENUM='"none", "minimal", "low", "medium", "high", "xhigh"'

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

# --- companion enum ----------------------------------------------------------
for MJS in "$HOME"/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs \
           "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs; do
  [ -f "$MJS" ] || continue
  LINE="$(grep -m1 'VALID_REASONING_EFFORTS' "$MJS" || true)"
  if [ -z "$LINE" ]; then
    say "companion enum: validator not found in $MJS — companion structure changed, re-verify manually"
    DRIFT=1
  elif printf '%s' "$LINE" | grep -q '"max"\|"ultra"'; then
    say "companion enum: WIDENED in $MJS -> $LINE"
    say "  ACTION: companion now accepts exception tiers — recipe-side max unblock candidate."
    say "  See follow-ups.md row 'ultra capability re-ground' + ADR 2026-07-10-sol-ultra-capability-reground.md."
    DRIFT=1
  elif printf '%s' "$LINE" | grep -qF "$BASELINE_ENUM"; then
    say "companion enum: baseline (caps at xhigh) in $MJS"
  else
    say "companion enum: CHANGED (non-baseline, no max/ultra) in $MJS -> $LINE"
    DRIFT=1
  fi
done

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
