#!/usr/bin/env bats
# P4-01 lane freshness poller and writer tests.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
POLLER="$REPO_ROOT/scripts/lane-freshness.py"
FIXTURE="$REPO_ROOT/scripts/tests/fixtures/openusage-limits.json"

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/lane-freshness.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -p "$TRELLIS_HOME/state"
  chmod 700 "$TRELLIS_HOME" "$TRELLIS_HOME/state"
  # Mock only the HTTP opener; parsing, normalization and atomic writes are real.
  cat > "$SANDBOX/fetch.py" <<'PY'
import importlib.util
from io import BytesIO
from pathlib import Path
import sys
from unittest.mock import patch
from urllib.error import URLError

poller, fixture, home, mode = sys.argv[1:]
spec = importlib.util.spec_from_file_location("lane_freshness", poller)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
argv = ["--home", home]
url, timeout = "http://127.0.0.1:6736/v1/limits", 10.0
if mode != "default":
    url, timeout = "http://fixture.invalid/v1/limits", 1.25
    argv += ["--url", url, "--timeout", str(timeout)]
response = BytesIO(Path(fixture).read_bytes())
with patch.object(module, "urlopen", return_value=response,
                  side_effect=URLError("fixture unavailable") if mode == "failure" else None) as opener:
    result = module.main(argv)
    # A string URL selects urllib's implicit GET; it has no Request.method.
    opener.assert_called_once_with(url, timeout=timeout)
assert result == 0, result
PY
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then chmod -R u+w "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"; fi
}

refresh() {
  run python3 "$SANDBOX/fetch.py" "$POLLER" "$FIXTURE" "$TRELLIS_HOME" "$1"
  [ "$status" -eq 0 ]
}

assert_private_snapshot() {
  python3 - "$TRELLIS_HOME/state" <<'PY'
import json
from pathlib import Path
import stat
import sys
state = Path(sys.argv[1])
snapshot = state / "lane-availability.json"
assert stat.S_IMODE(snapshot.stat().st_mode) == 0o600
assert not list(state.glob(".lane-availability.*")), "residual atomic-write temporary file"
json.loads(snapshot.read_text())
PY
}

assert_normalized() {
  snapshot="$TRELLIS_HOME/state/lane-availability.json"
  jq -e '.fetchedAt and (.lanes | type == "object") and (.errors | type == "array")' "$snapshot" >/dev/null
  jq -e '.lanes["codex"].remaining == 0.2 and .lanes["codex"].utilization == 0.8' "$snapshot" >/dev/null
  jq -e '.lanes["antigravity"].remaining == 0.75 and .lanes["copilot"].remaining == 1' "$snapshot" >/dev/null
  jq -e '.stale == false and .errors == [] and (.lanes.codex.resetsAt == "2026-09-03T01:00:00Z") and (.lanes.codex.fetchedAt == .fetchedAt)' "$snapshot" >/dev/null
  assert_private_snapshot
}

@test "fixture-driven GET normalization writes atomically with per-provider fields" {
  refresh success
  assert_normalized
}

@test "failed refresh keeps old snapshot and marks it stale" {
  refresh success
  snapshot="$TRELLIS_HOME/state/lane-availability.json"
  # Nonempty prior errors ensure preservation cannot pass by replacing with [].
  python3 - "$snapshot" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["errors"] = [{"provider": "prior", "message": "retained error"}]
path.write_text(json.dumps(data))
PY
  before="$(jq -Sc '{lanes, errors, fetchedAt}' "$snapshot")"
  for attempt in 1 2; do
    refresh failure
    jq -e '.stale == true and (.lastErrorAt | type == "string")' "$snapshot" >/dev/null
    [ "$(jq -Sc '{lanes, errors, fetchedAt}' "$snapshot")" = "$before" ]
    assert_private_snapshot
  done
}

@test "stale snapshot is preserved and never deleted on repeated failures" {
  refresh failure
  snapshot="$TRELLIS_HOME/state/lane-availability.json"
  jq -e '.stale == true and .lanes == {} and .errors == [] and .fetchedAt' "$snapshot" >/dev/null
  before="$(jq -c '{lanes, errors, fetchedAt}' "$snapshot")"
  refresh failure
  jq -e '.stale == true and (.lastErrorAt | type == "string")' "$snapshot" >/dev/null
  [ "$(jq -c '{lanes, errors, fetchedAt}' "$snapshot")" = "$before" ]
  assert_private_snapshot
}

@test "second successful refresh clears stale flag" {
  refresh failure
  jq -e '.stale == true' "$TRELLIS_HOME/state/lane-availability.json" >/dev/null
  refresh success
  assert_normalized
  jq -e 'has("lastErrorAt") | not' "$TRELLIS_HOME/state/lane-availability.json" >/dev/null
}

@test "default opener URL and timeout use the same fixture boundary" {
  refresh default
  assert_normalized
}
