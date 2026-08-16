#!/usr/bin/env bash
# Reconcile Codex's attachment-managed local surface.
#
# Codex and Claude hooks have the same strict registry, immutable release, and
# attachment lifecycle. Keep one reconciliation implementation so neither path
# can fall back to copying mutable canonical files into a project.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TRELLIS_SYNC_HARNESS=codex
TRELLIS_SYNC_NAME=sync-codex-hooks.sh
export TRELLIS_SYNC_HARNESS TRELLIS_SYNC_NAME
exec "$SCRIPT_DIR/sync-hooks.sh" "$@"
