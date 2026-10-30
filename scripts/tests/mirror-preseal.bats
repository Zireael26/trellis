#!/usr/bin/env bats
# Exercise the real publisher projection and lint, with an offline registry.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CHECK="$REPO_ROOT/scripts/check-mirror-preseal.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$HOME/trellis"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  export TRELLIS_MIRROR_IDENTITY_SOURCE="$BATS_TEST_TMPDIR/identity.json"
  mkdir -p "$HOME" "$TMPDIR"
  printf '{"projects":{"fixture/fixtureproj":{"project_id":"fixtureproj"}}}\n' \
    > "$TRELLIS_MIRROR_IDENTITY_SOURCE"
  SOURCE="$BATS_TEST_TMPDIR/source"
  mkdir -p "$SOURCE/scripts/lib" "$SOURCE/scripts/tests" \
    "$SOURCE/core-rules/hooks/tests" "$SOURCE/docs/adr/padding" "$SOURCE/audits"
  cp "$REPO_ROOT/scripts/sync-to-template.sh" "$SOURCE/scripts/"
  cp "$REPO_ROOT/scripts/lib/mirror-lint.sh" "$SOURCE/scripts/lib/"
  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$SOURCE/core-rules/"
  # A synthetic private identifier proves this leaf is withheld without
  # depending on the real route fixture (which a public mirror cannot ship).
  printf 'fixtureproj\n' > "$SOURCE/scripts/tests/herdr-task-routing.bats"
  printf '# Public record\n' > "$SOURCE/CHANGELOG.md"
  printf '# Neutral task fixture\n' > "$SOURCE/core-rules/hooks/tests/task-state.bats"
  # A non-vacuous stage, still tiny: these are just 1,000 one-byte files.
  python3 -I - "$SOURCE/docs/adr/padding" <<'PY'
from pathlib import Path
import sys
for index in range(1000):
    (Path(sys.argv[1]) / str(index)).write_text('\n')
PY
}

assert_scratch_clean() {
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "preseal uses publisher exclusions and replaces private data with public shells" {
  local path
  for path in dependency-baseline.json audits/fleet-remediation-ledger.json trellis.config.json \
    scripts/tests/check-secrets.bats scripts/.DS_Store scripts/cache.swp \
    scripts/__pycache__/cached scripts/workflows/private scripts/full-audit-sweep-ledger.mjs \
    core-rules/pi/agents/private core-rules/usage-federation/private \
    core-rules/skills/herdr-foreman/private scripts/lib/usage_federation/private \
    scripts/tests/usage-federation.bats scripts/tests/pi-guide-parity.bats \
    core-rules/pi/extensions/tests/private docs/adr/2026-08-07-fleet-hosting-substrate-policy.md; do
    mkdir -p "$(dirname "$SOURCE/$path")"
    printf 'fixtureproj\n' > "$SOURCE/$path"
  done
  run bash "$CHECK" "$SOURCE"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [[ "$output" == *'mirror-preseal: linting '*' staged files'* ]]
  [[ "$output" == *'mirror-preseal: staged public policy clean'* ]]
  # Source bytes are never redacted in place.
  [ "$(< "$SOURCE/dependency-baseline.json")" = fixtureproj ]
  [ "$(< "$SOURCE/audits/fleet-remediation-ledger.json")" = fixtureproj ]
  [ -f "$SOURCE/scripts/tests/herdr-task-routing.bats" ]
  assert_scratch_clean
}

@test "preseal real lint refuses fleet identifiers in a published historical record" {
  printf 'fixtureproj\n' > "$SOURCE/docs/adr/public-record.md"
  run bash "$CHECK" "$SOURCE"
  [ "$status" -eq 4 ]
  [[ "$output" == *'docs/adr/public-record.md: local fleet project identifier must not publish'* ]]
  assert_scratch_clean
}

@test "preseal refuses an incomplete stage instead of certifying an empty replica" {
  rm -rf "$SOURCE/docs/adr/padding"
  run bash "$CHECK" "$SOURCE"
  [ "$status" -eq 4 ]
  [[ "$output" == *'mirror-preseal: incomplete stage ('* ]]
  assert_scratch_clean
}

@test "preseal refuses a missing sentinel even above the file-count floor" {
  rm "$SOURCE/core-rules/hooks/tests/task-state.bats"
  run bash "$CHECK" "$SOURCE"
  [ "$status" -eq 4 ]
  [[ "$output" == *'mirror-preseal: missing staged sentinel: core-rules/hooks/tests/task-state.bats'* ]]
  assert_scratch_clean
}

@test "preseal refuses a changed publisher extraction boundary" {
  python3 -I - "$SOURCE/scripts/sync-to-template.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('stage_verified_payload() {', 'renamed_stage() {'))
PY
  run bash "$CHECK" "$SOURCE"
  [ "$status" -eq 4 ]
  [[ "$output" == *'mirror-preseal: publisher extraction boundary changed: stage_verified_payload() {'* ]]
  assert_scratch_clean
}

@test "preseal refuses a no-publish leaf without its stale-copy prune pair" {
  python3 -I - "$SOURCE/scripts/sync-to-template.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace("payload_no_publish=(", "payload_no_publish=(\n  'scripts/private-fixture'"))
PY
  run bash "$CHECK" "$SOURCE"
  [ "$status" -eq 4 ]
  [[ "$output" == *'payload_no_publish entry is missing its exact delist prune pair: scripts/private-fixture'* ]]
  assert_scratch_clean
}

@test "preseal refuses unavailable identity evidence rather than certifying blind" {
  rm "$TRELLIS_MIRROR_IDENTITY_SOURCE"
  run bash "$CHECK" "$SOURCE"
  [ "$status" -eq 4 ]
  [[ "$output" == *'fleet identity source unreadable'* ]]
  assert_scratch_clean
}
