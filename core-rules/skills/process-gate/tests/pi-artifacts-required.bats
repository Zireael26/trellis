#!/usr/bin/env bats
# pi-artifacts.py keeps a required Pi leaf only where the checkout's pinned
# release declares it: releases before 1.3.18 render .pi/hooks/dispatch.sh,
# later ones render nothing under .pi/hooks.

setup() {
  VALIDATOR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/pi-artifacts.py"
  ROOT="$BATS_TEST_TMPDIR/project"
  PAYLOAD="$BATS_TEST_TMPDIR/release/payload"
  mkdir -p "$ROOT" "$PAYLOAD/core-rules"
  OWNER='{"artifacts":[],"pre_existing":[]}'
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.." && pwd -P)"
}

payload_declares() {
  jq -n --argjson links "$1" '{schema_version:1,harnesses:{pi:{links:$links,render:[]}}}' \
    > "$PAYLOAD/core-rules/inheritance-manifest.json"
}

@test "an older release that declares the dispatcher still requires it" {
  payload_declares '[{"source":"core-rules/pi/hooks/dispatch.sh","destination":".pi/hooks/dispatch.sh"}]'
  run python3 -I "$VALIDATOR" "$ROOT" "$PAYLOAD" .pi/hooks/dispatch.sh <<< "$OWNER"
  [ "$status" -eq 1 ]
  [[ "$output" == ".pi/hooks/dispatch.sh: native Pi hook artifact missing"* ]] || { echo "$output"; false; }
}

@test "a release that renders nothing under .pi/hooks drops the dispatcher requirement" {
  payload_declares '[{"source":"core-rules/pi/extensions/trellis.ts","destination":".pi/extensions/trellis.ts"}]'
  run python3 -I "$VALIDATOR" "$ROOT" "$PAYLOAD" .pi/hooks/dispatch.sh <<< "$OWNER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
  # The extension the same release declares stays required.
  run python3 -I "$VALIDATOR" "$ROOT" "$PAYLOAD" .pi/extensions/trellis.ts <<< "$OWNER"
  [ "$status" -eq 1 ]
  [[ "$output" == ".pi/extensions/trellis.ts: native Pi hook artifact missing"* ]] || { echo "$output"; false; }
}

# A current attachment links exactly one extension. Shared JSON remains runtime
# data in the pinned payload, not another linked extension or static TS import.
single_entry_fixture() {
  ROOT="$(cd "$ROOT" && pwd -P)"
  PAYLOAD="$(cd "$PAYLOAD" && pwd -P)"
  mkdir -p "$ROOT/.pi/extensions" "$ROOT/.trellis" "$PAYLOAD/core-rules/pi/extensions" \
    "$PAYLOAD/core-rules/hooks/rules"
  printf 'export default function () {}\n' > "$PAYLOAD/core-rules/pi/extensions/trellis.ts"
  cp "$REPO/core-rules/hooks/rules/"{destructive,reread}.json "$PAYLOAD/core-rules/hooks/rules/"
  payload_declares '[{"source":"core-rules/pi/extensions/trellis.ts","destination":".pi/extensions/trellis.ts"}]'
  ln -s "$PAYLOAD" "$ROOT/.trellis/runtime"
  ln -s '../../.trellis/runtime/core-rules/pi/extensions/trellis.ts' "$ROOT/.pi/extensions/trellis.ts"
  OWNER='{"artifacts":[{"kind":"symlink","path":".pi/extensions/trellis.ts","target":"../../.trellis/runtime/core-rules/pi/extensions/trellis.ts"}],"pre_existing":[]}'
  printf '%s\n' "$OWNER" > "$BATS_TEST_TMPDIR/owner.json"
  python3 -I - "$PAYLOAD" <<'PY'
import hashlib, json, pathlib, sys
payload = pathlib.Path(sys.argv[1])
tree = []
for path in payload.rglob("*"):
    if path.is_file():
        content = path.read_bytes()
        tree.append({"path": str(path.relative_to(payload)),
                     "mode": "100755" if path.stat().st_mode & 0o111 else "100644",
                     "oid": hashlib.sha1(("blob %d\0" % len(content)).encode() + content).hexdigest()})
(payload.parent / "release.json").write_text(json.dumps({"tree": tree}))
PY
}

validate_single_entry() {
  run python3 -I "$VALIDATOR" "$ROOT" "$PAYLOAD" .pi/extensions/trellis.ts .pi/hooks/dispatch.sh <<< "$OWNER"
}

@test "sole manifest-linked trellis.ts is sufficient with sealed runtime rules" {
  single_entry_fixture
  validate_single_entry
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ]
  [ ! -e "$ROOT/.pi/hooks" ]
  [ ! -e "$PAYLOAD/core-rules/pi/extensions/hook-runtime.ts" ]
  [ "$(find "$ROOT/.pi/extensions" -type l | wc -l | tr -d ' ')" -eq 1 ]
}

@test "sole entry still requires both runtime rule files even though neither is owner-linked" {
  single_entry_fixture
  validate_single_entry
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for rule in destructive reread; do
    mv "$PAYLOAD/core-rules/hooks/rules/$rule.json" "$BATS_TEST_TMPDIR/rule-backup"
    validate_single_entry
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qF ".trellis/runtime/core-rules/hooks/rules/$rule.json: native Pi hook artifact" <<< "$output"
    mv "$BATS_TEST_TMPDIR/rule-backup" "$PAYLOAD/core-rules/hooks/rules/$rule.json"
  done
}

@test "sole entry rejects changed and redirected runtime rules against the sealed tree" {
  single_entry_fixture
  for rule in destructive reread; do
    file="$PAYLOAD/core-rules/hooks/rules/$rule.json"
    mv "$file" "$BATS_TEST_TMPDIR/rule-backup"
    printf '{}\n' > "$file"
    validate_single_entry
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qF 'payload content hash or mode mismatch' <<< "$output"
    rm "${file:?}"
    ln -s "$BATS_TEST_TMPDIR/rule-backup" "$file"
    validate_single_entry
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qF ".trellis/runtime/core-rules/hooks/rules/$rule.json: native Pi hook artifact" <<< "$output"
    rm "${file:?}"
    mv "$BATS_TEST_TMPDIR/rule-backup" "$file"
  done
}

@test "doctor and show-config shared Pi health accepts sole entry but rejects missing runtime rules" {
  single_entry_fixture
  run bash -c '. "$1"; hc_portable_pi_artifacts "$2" "$3" "$4"' \
    _ "$REPO/scripts/lib/health-checks.sh" "$BATS_TEST_TMPDIR/owner.json" "$ROOT" "$PAYLOAD"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  rm "${PAYLOAD:?}/core-rules/hooks/rules/reread.json"
  run bash -c '. "$1"; hc_portable_pi_artifacts "$2" "$3" "$4"' \
    _ "$REPO/scripts/lib/health-checks.sh" "$BATS_TEST_TMPDIR/owner.json" "$ROOT" "$PAYLOAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  grep -qF '.trellis/runtime/core-rules/hooks/rules/reread.json: native Pi hook artifact' <<< "$output"
}

@test "an unreadable payload manifest keeps every requirement" {
  run python3 -I "$VALIDATOR" "$ROOT" "$PAYLOAD" .pi/hooks/dispatch.sh <<< "$OWNER"
  [ "$status" -eq 1 ]
  [[ "$output" == ".pi/hooks/dispatch.sh: native Pi hook artifact missing"* ]] || { echo "$output"; false; }
}
