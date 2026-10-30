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

@test "an unreadable payload manifest keeps every requirement" {
  run python3 -I "$VALIDATOR" "$ROOT" "$PAYLOAD" .pi/hooks/dispatch.sh <<< "$OWNER"
  [ "$status" -eq 1 ]
  [[ "$output" == ".pi/hooks/dispatch.sh: native Pi hook artifact missing"* ]] || { echo "$output"; false; }
}
