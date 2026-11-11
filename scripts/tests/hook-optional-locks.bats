#!/usr/bin/env bats
# Owned fixtures only; see helper for the narrowly confined real Git control.
setup() {
  SOURCE="$(CDPATH='' cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  ROOT="$(CDPATH='' cd -- "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$ROOT/home" "$ROOT/th" "$ROOT/tmp"
  chmod 700 "$ROOT/home" "$ROOT/th" "$ROOT/tmp"
  export HOME="$ROOT/home" TRELLIS_HOME="$ROOT/th" TMPDIR="$ROOT/tmp"
  export GIT_CONFIG_GLOBAL="$ROOT/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
}

check_index() {
  run python3 -I "$SOURCE/scripts/tests/helpers/hook-optional-locks.py" "$SOURCE" "$ROOT" "$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "optional locks: Claude Stop UI preserves index entries and object IDs" { check_index claude; }
@test "optional locks: Codex Stop UI preserves index entries and object IDs" { check_index codex; }
@test "optional locks: pi agent_settled real UI preserves index entries and object IDs" { check_index pi; }

@test "optional locks: Claude status preserves index bytes and mtime" { check_index claude-status; }
@test "optional locks: Codex status preserves index bytes and mtime" { check_index codex-status; }
@test "optional locks: pi session_start status preserves index bytes and mtime" { check_index pi-status; }

@test "optional locks: every shell hook and standalone entry suppresses optional writes" {
  run python3 -I - "$SOURCE" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
paths = [*root.glob('core-rules/hooks/*.sh'), *root.glob('core-rules/codex/hooks/*.sh'),
         root / 'core-rules/pi/hooks/dispatch.sh', root / 'core-rules/hooks/lib/aeo-gate-warn.sh']
assert len(paths) == 60, len(paths)
for path in paths:
    assert path.read_text().splitlines()[1] == 'export GIT_OPTIONAL_LOCKS=0', path
for name in ('ui-verify-core', 'code-reviewer'):
    path = root / ('core-rules/hooks/lib/' + name + '.sh')
    assert 'if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then\n  export GIT_OPTIONAL_LOCKS=0\n' in path.read_text(), path
assert (root / 'scripts/trellis').read_text().count('"GIT_OPTIONAL_LOCKS=0" "GIT_CONFIG_NOSYSTEM=1"') == 2
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}
