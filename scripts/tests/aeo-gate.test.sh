#!/usr/bin/env bash
set -euo pipefail
export AEO_GATE_ALLOW_FIXTURES=1

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
SKILL="$ROOT/core-rules/skills/aeo-gate"
FIXTURES="$SKILL/tests/fixtures"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/aeo-gate-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/checkout"
printf '%s\n' 'AEO_MAPPING_MARKER_2026_08' >"$TMP/checkout/site.html"

if env -u AEO_GATE_ALLOW_FIXTURES "$SKILL/scripts/run-baseline.sh" \
  --project fixture \
  --url https://example.test \
  --checkout "$TMP/checkout" \
  --output "$TMP/rejected-fixture" \
  --marker-file site.html \
  --marker AEO_MAPPING_MARKER_2026_08 \
  --html-file "$FIXTURES/valid.html" \
  --scanner-json "$FIXTURES/scanner.json" >"$TMP/fixture-guard.out" 2>&1; then
  echo "fixture input unexpectedly accepted without AEO_GATE_ALLOW_FIXTURES=1" >&2
  exit 1
fi
grep -q 'fixture inputs are test-only' "$TMP/fixture-guard.out"

"$SKILL/scripts/run-baseline.sh" \
  --project fixture \
  --url https://example.test \
  --checkout "$TMP/checkout" \
  --output "$TMP/baseline" \
  --marker-file site.html \
  --marker AEO_MAPPING_MARKER_2026_08 \
  --html-file "$FIXTURES/valid.html" \
  --scanner-json "$FIXTURES/scanner.json"

python3 "$SKILL/scripts/aeo_gate.py" verify-manifest "$TMP/baseline/manifest.json"
jq -e '.fixture == true' "$TMP/baseline/baseline.json" >/dev/null
TRIAGE_FP=$(jq -r '.findings[] | select(.disposition == "no-llm-pass") | .fingerprint' "$TMP/baseline/baseline.json")
cat >"$TMP/triage-response.json" <<EOF
{"findings":[{"fingerprint":"$TRIAGE_FP","disposition":"dropped","rationale":"Not actionable."}]}
EOF
"$SKILL/scripts/run-baseline.sh" \
  --project fixture \
  --url https://example.test \
  --checkout "$TMP/checkout" \
  --output "$TMP/triaged" \
  --marker-file site.html \
  --marker AEO_MAPPING_MARKER_2026_08 \
  --html-file "$FIXTURES/valid.html" \
  --scanner-json "$FIXTURES/scanner.json" \
  --triage \
  --triage-provider local \
  --triage-model fixture \
  --triage-response-file "$TMP/triage-response.json"
python3 "$SKILL/scripts/aeo_gate.py" verify-manifest "$TMP/triaged/manifest.json"
jq -e --arg fp "$TRIAGE_FP" \
  '.findings[] | select(.fingerprint == $fp and .disposition == "dropped")' \
  "$TMP/triaged/baseline.json" >/dev/null

"$SKILL/scripts/run-deep.sh" \
  --html "$FIXTURES/valid.html" \
  --baseline "$TMP/baseline/baseline.json" \
  --output "$TMP/deep" \
  --provider local \
  --model fixture \
  --response-file "$FIXTURES/deep-response.json"

python3 "$SKILL/scripts/aeo_gate.py" verify-manifest "$TMP/deep/manifest.json"

cat >"$TMP/targets.md" <<EOF
## Active targets
| Project | URL | Checkout | Marker file | Marker |
|---|---|---|---|---|
| fixture | https://example.test | $TMP/checkout | site.html | AEO_MAPPING_MARKER_2026_08 |
## Explicit skips
| Project | Reason |
|---|---|
EOF
cat >"$TMP/registry.md" <<'EOF'
## Active projects
| Project | Path |
|---|---|
| fixture | /fixture |
EOF
cat >"$TMP/blacklist.md" <<'EOF'
## 1. Temporarily excluded (registered projects)
| Project | Reason |
|---|---|
## 2. Permanently excluded from management
| Path | Reason |
|---|---|
EOF
mkdir -p "$TMP/html" "$TMP/scanner"
cp "$FIXTURES/valid.html" "$TMP/html/fixture.html"
cp "$FIXTURES/scanner.json" "$TMP/scanner/fixture.json"
"$SKILL/scripts/run-fleet.sh" \
  --targets "$TMP/targets.md" \
  --registry "$TMP/registry.md" \
  --blacklist "$TMP/blacklist.md" \
  --output "$TMP/fleet" \
  --html-fixture-dir "$TMP/html" \
  --scanner-fixture-dir "$TMP/scanner"
python3 "$SKILL/scripts/aeo_gate.py" verify-manifest "$TMP/fleet/manifest.json"
jq -e '.status == "PASS" and .counts.active == 1' "$TMP/fleet/fleet-rollup.json" >/dev/null
printf '%s\n' 'aeo-gate shell smoke: ok'
