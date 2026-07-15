#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
RECIPE="$REPO/core-rules/skills/orchestrate/recipes/digest-adopt.wf.js"
MANIFEST="$REPO/core-rules/skills/orchestrate/recipes/MANIFEST.md"

run_recipe() {
  run node "$STUB" "$RECIPE" "$1"
  [ "$status" -eq 0 ]
}

json_assert() {
  CAPTURED_JSON="$output" node -e 'const r=JSON.parse(process.env.CAPTURED_JSON); if (!('"$1"')) { console.error(JSON.stringify(r,null,2)); process.exit(1) }'
}

@test "no-candidates return uses the caller-resolved canonical loop-safety rate" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","loopSafety":{"usd_per_mtok":17.5},"__budgetSpentTokens":200000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[],"skipped_settled":2}}}'
  json_assert "!r.error && r.result.costLine === 'spent_usd 3.500000 / budget_ceiling_usd 60.00 (200000 output tokens at usd_per_mtok 17.5)' && r.logs.some((line) => line.includes(r.result.costLine))"
}

@test "manifest requires callers to thread the resolved loop-safety rate" {
  run awk '
    /^\| `digest-adopt` \|/ {
      rows++
      if (index($0, "caller-resolved `loopSafety` (for canonical `usd_per_mtok` reporting)") > 0) corrected++
    }
    END { exit(rows == 1 && corrected == 1 ? 0 : 1) }
  ' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "propose-only return reports spend using an explicit rate override" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","loopSafety":{"usd_per_mtok":17.5},"usdPerMTok":10,"__budgetSpentTokens":200000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test proposal","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test proposal","route":"surgical","rationale":"small","skeptic_upheld":true}}}'
  json_assert "!r.error && r.result.note.startsWith('PROPOSE-ONLY') && r.result.costLine === 'spent_usd 2.000000 / budget_ceiling_usd 60.00 (200000 output tokens at usd_per_mtok 10.00)' && r.logs.some((line) => line.includes(r.result.costLine))"
}

@test "execution report converts output tokens with the exact fractional rate" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","approved":[{"id":"P1","route":"surgical"}],"usdPerMTok":12.5,"__budgetSpentTokens":400000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test proposal","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test proposal","route":"surgical","rationale":"small","skeptic_upheld":true},"build:P1":{"id":"P1","route":"surgical","branch":"feat/adopt-p1","pr_url":"https://example.test/pr/1","gate_green":true,"notes":"ok"}}}'
  json_assert "!r.error && r.result.verdicts.length === 1 && r.result.costLine === 'spent_usd 5.000000 / budget_ceiling_usd 60.00 (400000 output tokens at usd_per_mtok 12.5)' && r.logs.some((line) => line.includes(r.result.costLine))"
}

@test "early return reports unavailable output-token metering honestly" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","loopSafety":{"usd_per_mtok":17.5},"__agentOutputByLabel":{"ingest-digest":{"candidates":[],"skipped_settled":0}}}'
  json_assert "!r.error && r.result.costLine === 'spent_usd unavailable / budget_ceiling_usd 60.00 (output-token metering unavailable; usd_per_mtok 17.5)' && r.logs.some((line) => line.includes(r.result.costLine))"
}

@test "missing canonical rate reports unavailable instead of inventing a fallback" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__budgetSpentTokens":200000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[],"skipped_settled":0}}}'
  json_assert "!r.error && r.result.costLine === 'spent_usd unavailable / budget_ceiling_usd 60.00 (200000 output tokens metered; usd_per_mtok unavailable)' && r.logs.some((line) => line.includes(r.result.costLine))"
}

@test "invalid USD-per-MTok overrides fail before agent work" {
  local rate
  for rate in 0 -1 '"25"' null; do
    run_recipe "{\"digestPath\":\"research/ai-dev-trends/digests/test.md\",\"usdPerMTok\":$rate}"
    json_assert "r.error && r.error.message.includes('args.usdPerMTok must be a finite number greater than 0') && r.prompts.length === 0"
  done
}
