#!/usr/bin/env bats
# A fatal awk write failure is not a row-rejection receipt.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/local-registry.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-registry-io.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  INPUT="$SANDBOX/registry.md" OUTPUT="$SANDBOX/rows" REJECTS="$SANDBOX/rejects"
  printf '%s\n' '## Active projects' '| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |' '|---|---|---|---|---|---|---|' > "$INPUT"
}

@test "awk output write failure cannot masquerade as rejected rows" {
  for i in $(seq 1 100); do
    printf '| project%s | `/fixture/project%s` | app | none | none | none | a long note to exceed the file limit |\n' "$i" "$i" >> "$INPUT"
  done
  run bash -c 'ulimit -c 0; trap "" XFSZ; ulimit -f 1; . "$1"; local_registry_parse_legacy_markdown "$2" "$3" "$4"' _ "$LIB" "$INPUT" "$OUTPUT" "$REJECTS"
  [ "$status" -ne 0 ] || { echo "partial write reported success: $output"; false; }
}

@test "real row rejection is still reported without losing valid rows" {
  printf '%s\n' '| good | `/fixture/good` | app | none | none | none | valid |' '| malformed | too few |' >> "$INPUT"
  run bash -c '. "$1"; local_registry_parse_legacy_markdown "$2" "$3" "$4"' _ "$LIB" "$INPUT" "$OUTPUT" "$REJECTS"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^good' "$OUTPUT"
  grep -q 'expected 7 cells' "$REJECTS"
}
