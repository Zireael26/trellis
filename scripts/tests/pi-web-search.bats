#!/usr/bin/env bats
# Coverage for the Pi web-search adapter's deterministic Node tests through the
# fenced runner scripts/pi-web-search-tests.sh. Before this suite existed the
# adapter's tests (core-rules/pi/web-search/tests/*.test.ts) were outside the
# run-tests.sh inventory: their only evidence was the Spec 047 T18–T20 fenced
# receipts. This suite makes the normal local gate cover them.
#
# The runner copies the adapter into a fresh private fence under TMPDIR, proves
# the copy is hash-identical, strips provider/proxy/config environment, runs
# `node --experimental-strip-types --test tests/*.test.ts` inside the fence and
# removes the fence. No network, credentials or product modification.

REPO="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RUNNER="$REPO/scripts/pi-web-search-tests.sh"
SOURCE="$REPO/core-rules/pi/web-search"

setup() {
  SANDBOX="$(mktemp -d)"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

_sha() { shasum -a 256 "$1" | cut -c1-64; }

# Full run: the real adapter tests pass inside the fence, the fence matched the
# source file by file, and the fence is gone afterwards. This is the case that
# carries the gate's coverage; it takes about 90 s because the deadline tests
# use real timers.
@test "adapter tests pass in a fresh fence and the fence is removed" {
  command -v node >/dev/null || skip "node not on PATH"
  run bash "$RUNNER" --receipt "$SANDBOX/receipt.json"
  echo "$output" | tail -n 8
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/receipt.json" ]
  local tests pass fail fence
  tests="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tests"])' "$SANDBOX/receipt.json")"
  pass="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pass"])' "$SANDBOX/receipt.json")"
  fail="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["fail"])' "$SANDBOX/receipt.json")"
  fence="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["fence"])' "$SANDBOX/receipt.json")"
  [ "$fail" = "0" ]
  [ "$pass" = "$tests" ]
  [ "$pass" -ge 100 ]
  [ ! -d "$fence" ]
  # Receipt hashes are the working-tree source hashes: the fence tested this tree.
  for rel in index.ts antigravity.ts result.ts NOTICE; do
    local recorded
    recorded="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["fence_sha256"][sys.argv[2]])' "$SANDBOX/receipt.json" "$rel")"
    [ "$recorded" = "$(_sha "$SOURCE/$rel")" ]
  done
}

# A failing adapter test must fail the runner (no summary-only green), and the
# fence must still be cleaned up. Uses a tiny synthetic adapter so it is fast.
@test "a failing test fails the runner and the fence is still removed" {
  command -v node >/dev/null || skip "node not on PATH"
  mkdir -p "$SANDBOX/adapter/tests"
  printf '// synthetic\nexport const x = 1;\n' > "$SANDBOX/adapter/index.ts"
  printf 'MIT\n' > "$SANDBOX/adapter/NOTICE"
  cat > "$SANDBOX/adapter/tests/broken.test.ts" <<'TS'
import test from "node:test";
import assert from "node:assert/strict";
test("deliberately failing", () => { assert.equal(1, 2); });
TS
  run bash "$RUNNER" --source "$SANDBOX/adapter" --receipt "$SANDBOX/r.json"
  [ "$status" -eq 1 ]
  local fence
  fence="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["fence"])' "$SANDBOX/r.json")"
  [ ! -d "$fence" ]
  echo "$output" | grep -q 'fail=1'
}

@test "a source tree with no tests is unavailable, not green" {
  command -v node >/dev/null || skip "node not on PATH"
  mkdir -p "$SANDBOX/empty/tests"
  printf 'export const x = 1;\n' > "$SANDBOX/empty/index.ts"
  run bash "$RUNNER" --source "$SANDBOX/empty"
  [ "$status" -eq 5 ]
}

@test "missing node is reported as unavailable (exit 5), not as a pass" {
  run env TRELLIS_NODE_BIN=/nonexistent/node bash "$RUNNER"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'node is not available'
}

@test "unknown arguments are rejected with exit 2" {
  run bash "$RUNNER" --bogus
  [ "$status" -eq 2 ]
}

# An unparseable summary must be a reported failure with a receipt, not a silent
# abort. Before the fix the summary parse ran `grep | tail | awk` under `set -e`
# with `pipefail`, so a log with no summary killed the script at the assignment:
# no diagnostic line, no receipt, and the documented exit-1 contract unproven.
# A stub node produces exactly that log without needing a broken adapter.
@test "an unparseable summary fails with a receipt, not a silent abort" {
  mkdir -p "$SANDBOX/adapter/tests"
  printf 'export const x = 1;\n' > "$SANDBOX/adapter/index.ts"
  printf 'MIT\n' > "$SANDBOX/adapter/NOTICE"
  printf 'import test from "node:test";\ntest("t", () => {});\n' > "$SANDBOX/adapter/tests/a.test.ts"
  cat > "$SANDBOX/fakenode" <<'SH'
#!/usr/bin/env bash
case "$1" in --version) echo v0.0.0-stub ;; *) echo "reporter produced no summary" ;; esac
exit 0
SH
  chmod +x "$SANDBOX/fakenode"
  run env TRELLIS_NODE_BIN="$SANDBOX/fakenode" bash "$RUNNER" --source "$SANDBOX/adapter" --receipt "$SANDBOX/n.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'tests=? pass=? fail=? '
  echo "$output" | grep -q 'result=1'
  [ -f "$SANDBOX/n.json" ]
  # The receipt records the unparseable counts as null and still parses as JSON.
  python3 -c 'import json,sys
r = json.load(open(sys.argv[1]))
assert r["tests"] is None and r["pass"] is None and r["fail"] is None, r
assert r["result_exit"] == 1, r
assert "--test-reporter=spec" in r["command"], r["command"]' "$SANDBOX/n.json"
}

# Adapter paths and file names are caller-supplied. A quote or backslash in one
# used to be emitted raw into the receipt, producing a receipt no consumer —
# including the first test in this file — can parse.
@test "quotes and backslashes in paths still produce a parseable receipt" {
  command -v node >/dev/null || skip "node not on PATH"
  local src="$SANDBOX/od\"d dir"
  mkdir -p "$src/tests"
  printf 'export const x = 1;\n' > "$src/index.ts"
  printf 'MIT\n' > "$src/NOTICE"
  printf 'export const y = 2;\n' > "$src/we\"ird\\name.ts"
  printf 'import test from "node:test";\ntest("t", () => {});\n' > "$src/tests/a.test.ts"
  run bash "$RUNNER" --source "$src" --receipt "$SANDBOX/q.json"
  [ "$status" -eq 0 ]
  # The digest must be the real digest of that file: `shasum <name>` escapes a
  # backslashed name and prefixes the line with `\`, which silently shifted the
  # recorded hash by one character and voided the fence-matches-source proof.
  python3 -c 'import hashlib, json, os, sys
r = json.load(open(sys.argv[1]))
assert r["source"].endswith("od\"d dir"), r["source"]
rel = "we\"ird\\name.ts"
assert rel in r["fence_sha256"], sorted(r["fence_sha256"])
got = r["fence_sha256"][rel]
want = hashlib.sha256(open(os.path.join(sys.argv[2], rel), "rb").read()).hexdigest()
assert got == want, (got, want)
assert r["pass"] == r["tests"] == 1, r' "$SANDBOX/q.json" "$src"
}
