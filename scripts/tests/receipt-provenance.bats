#!/usr/bin/env bats
# Spec 066 (process): one hermetic suite, also runnable directly without Bats.
# All bash/bats/jq/git/node/pnpm probes use private stubs; no Trellis invocation.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

@test "release receipts capture START before planning, setup and every test outcome" {
  run env PYTHONDONTWRITEBYTECODE=1 TRELLIS_PROVENANCE_TEST_ROOT="$BATS_TEST_TMPDIR" \
    python3 "$REPO_ROOT/scripts/tests/test_receipt_provenance.py" -v
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}
