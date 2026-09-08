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
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","loopSafety":{"usd_per_mtok":17.5},"usdPerMTok":10,"__budgetSpentTokens":200000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test proposal","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test proposal","route":"surgical","rationale":"small"},"skeptic:P1":{"id":"P1","skeptic_upheld":true}}}'
  json_assert "!r.error && r.result.note.startsWith('PROPOSE-ONLY') && r.result.costLine === 'spent_usd 2.000000 / budget_ceiling_usd 60.00 (200000 output tokens at usd_per_mtok 10.00)' && r.logs.some((line) => line.includes(r.result.costLine))"
}

@test "execution report converts output tokens with the exact fractional rate" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","approved":[{"id":"P1","route":"surgical"}],"usdPerMTok":12.5,"__budgetSpentTokens":400000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test proposal","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test proposal","route":"surgical","rationale":"small"},"skeptic:P1":{"id":"P1","skeptic_upheld":true},"build:P1":{"id":"P1","route":"surgical","branch":"feat/adopt-p1","pr_number":1,"pr_state":"OPEN","pr_url":"https://github.com/example/repo/pull/1","gate_green":true,"notes":"ok"}}}'
  json_assert "!r.error && r.result.verdicts.length === 1 && r.result.costLine === 'spent_usd 5.000000 / budget_ceiling_usd 60.00 (400000 output tokens at usd_per_mtok 12.5)' && r.logs.some((line) => line.includes('1/1 HOLD PRs opened')) && r.logs.some((line) => line.includes(r.result.costLine))"
}

@test "URL-only verdict fails closed instead of counting a HOLD PR as opened" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","approved":[{"id":"P1","route":"surgical"}],"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test proposal","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test proposal","route":"surgical","rationale":"small"},"skeptic:P1":{"id":"P1","skeptic_upheld":true},"build:P1":{"id":"P1","route":"surgical","branch":"feat/adopt-p1","pr_url":"https://github.com/example/repo/pull/1","gate_green":true,"notes":"URL without opened-state or PR-number receipt"}}}'
  json_assert "!r.error && r.result.verdicts.length === 1 && r.logs.some((line) => line.includes('0/1 HOLD PRs opened'))"
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

@test "triage splits generator and verifier into distinct agent invocations per candidate" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"A","effort":"S","risk":"lo"},{"id":"P2","title":"B","effort":"M","risk":"med"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"A","route":"surgical","rationale":"small"},"triage:P2":{"id":"P2","title":"B","route":"feature","rationale":"needs design"},"skeptic:P1":{"id":"P1","skeptic_upheld":true},"skeptic:P2":{"id":"P2","skeptic_upheld":false}}}'
  json_assert "!r.error && r.result.triage.length===2 && r.result.triage.find(t=>t.id==='P1').skeptic_upheld===true && r.result.triage.find(t=>t.id==='P2').skeptic_upheld===false && r.result.triage.find(t=>t.id==='P1').route==='surgical' && r.result.triage.find(t=>t.id==='P2').route==='feature' && r.prompts.filter(p=>p.opts.label.startsWith('triage:')).length===2 && r.prompts.filter(p=>p.opts.label.startsWith('skeptic:')).length===2"
}

@test "generator schema cannot set skeptic_upheld and verifier alone emits it" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"A","effort":"S","risk":"lo"},{"id":"P2","title":"B","effort":"M","risk":"med"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"A","route":"surgical","rationale":"small"},"triage:P2":{"id":"P2","title":"B","route":"feature","rationale":"needs design"},"skeptic:P1":{"id":"P1","skeptic_upheld":true},"skeptic:P2":{"id":"P2","skeptic_upheld":false}}}'
  json_assert "(() => { const gen=r.prompts.find(p=>p.opts.label==='triage:P1'); const sk=r.prompts.find(p=>p.opts.label==='skeptic:P1'); return gen && sk && gen.opts.schema.required.includes('rationale') && !gen.opts.schema.required.includes('skeptic_upheld') && gen.opts.schema.additionalProperties===false && sk.opts.schema.required.includes('skeptic_upheld') && !sk.opts.schema.required.includes('route') && !sk.opts.schema.required.includes('rationale') && sk.opts.schema.additionalProperties===false; })() && r.prompts.find(p=>p.opts.label==='skeptic:P1').prompt.includes('CANDIDATE') && r.prompts.find(p=>p.opts.label==='skeptic:P1').prompt.includes('GENERATOR CLASSIFICATION') && r.prompts.find(p=>p.opts.label==='skeptic:P1').prompt.includes('skeptical-evaluator')"
}

@test "generator output cannot self-uphold — smuggled skeptic_upheld fails closed" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test","route":"surgical","rationale":"small","skeptic_upheld":true},"skeptic:P1":{"id":"P1","skeptic_upheld":false}}}'
  json_assert "r.error && /Triage/.test(r.error.message)"
}

@test "missing skeptic verifier receipt fails closed" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test","route":"surgical","rationale":"small"}}}'
  json_assert "r.error && /Triage/.test(r.error.message)"
}

@test "mismatched skeptic ID fails closed" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test","route":"surgical","rationale":"small"},"skeptic:P1":{"id":"P2","skeptic_upheld":true}}}'
  json_assert "r.error && /Triage/.test(r.error.message)"
}

@test "parallelism across candidates preserved — all generators and verifiers fan out" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"A","effort":"S","risk":"lo"},{"id":"P2","title":"B","effort":"S","risk":"lo"},{"id":"P3","title":"C","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"A","route":"surgical","rationale":"a"},"triage:P2":{"id":"P2","title":"B","route":"surgical","rationale":"b"},"triage:P3":{"id":"P3","title":"C","route":"surgical","rationale":"c"},"skeptic:P1":{"id":"P1","skeptic_upheld":true},"skeptic:P2":{"id":"P2","skeptic_upheld":true},"skeptic:P3":{"id":"P3","skeptic_upheld":false}}}'
  json_assert "!r.error && r.result.triage.length===3 && r.prompts.filter(p=>p.opts.label.startsWith('triage:')).length===3 && r.prompts.filter(p=>p.opts.label.startsWith('skeptic:')).length===3 && r.result.triage.map(t=>t.id).join(',')==='P1,P2,P3'"
}

# Disclosure coverage note (evidence only, never product output): wf-stub injects
# budget.spent() output-token counts and propagates stage/transport failures; it
# does not prove real host budget/no-progress halts. The disclosure's
# "actual host budget/no-progress enforcement unverified" wording marks exactly
# that boundary without naming test infrastructure in the product log line.
@test "no-candidate disclosure is one adjacent line with required semantics and configured rate" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","loopSafety":{"usd_per_mtok":17.5},"__budgetSpentTokens":200000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[],"skipped_settled":2}}}'
  json_assert "!r.error && r.result.costLine === 'spent_usd 3.500000 / budget_ceiling_usd 60.00 (200000 output tokens at usd_per_mtok 17.5)' && r.logs.filter((l)=>l.startsWith('digest-adopt report: ')).length===1 && r.logs.filter((l)=>l.startsWith('digest-adopt cost disclosure: ')).length===1 && r.logs.findIndex((l)=>l.startsWith('digest-adopt cost disclosure: '))===r.logs.findIndex((l)=>l.startsWith('digest-adopt report: '))+1 && r.logs.some((line)=>line==='digest-adopt report: no fresh candidates; '+r.result.costLine)"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')); return d.includes('is an output-only modeled subtotal') && d.includes('output-only') && d.includes('modeled') && d.includes('subtotal') && d.includes('usd_per_mtok 17.5') && d.includes('workflow-reported') && d.includes('output tokens') && d.includes('report time') && d.includes('input') && d.includes('cache') && d.includes('child') && d.includes('unknown') && d.includes('recorded') && d.includes('real/notional') && d.includes('unavailable') && d.includes('max_iterations=12') && d.includes('recipe-capped') && d.includes('execute-item cap') && d.includes('actual host') && d.includes('budget') && d.includes('no-progress') && d.includes('unverified');})()"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')).toLowerCase(); return !d.includes('total spend') && !d.includes('bill') && !d.includes('money owed') && !d.includes('owed') && !d.includes('lower bound') && !d.includes('quota') && !d.includes('headroom') && !d.includes('authority') && !d.includes('stub') && !d.includes('fixture') && !d.includes('test');})()"
}

@test "propose-only disclosure reports the explicit configured rate override" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","loopSafety":{"usd_per_mtok":17.5},"usdPerMTok":10,"__budgetSpentTokens":200000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test proposal","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test proposal","route":"surgical","rationale":"small"},"skeptic:P1":{"id":"P1","skeptic_upheld":true}}}'
  json_assert "!r.error && r.result.note.startsWith('PROPOSE-ONLY') && r.result.costLine === 'spent_usd 2.000000 / budget_ceiling_usd 60.00 (200000 output tokens at usd_per_mtok 10.00)' && r.logs.filter((l)=>l.startsWith('digest-adopt report: ')).length===1 && r.logs.filter((l)=>l.startsWith('digest-adopt cost disclosure: ')).length===1 && r.logs.findIndex((l)=>l.startsWith('digest-adopt cost disclosure: '))===r.logs.findIndex((l)=>l.startsWith('digest-adopt report: '))+1"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')); return d.includes('is an output-only modeled subtotal') && d.includes('usd_per_mtok 10.00') && d.includes('workflow-reported') && d.includes('output tokens') && d.includes('report time') && d.includes('input/cache/child attribution unknown') && d.includes('recorded real/notional cost unavailable') && d.includes('max_iterations=12') && d.includes('recipe-capped') && d.includes('execute-item cap') && d.includes('actual host') && d.includes('budget') && d.includes('no-progress') && d.includes('unverified');})()"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')).toLowerCase(); return !d.includes('total spend') && !d.includes('bill') && !d.includes('money owed') && !d.includes('owed') && !d.includes('lower bound') && !d.includes('quota') && !d.includes('headroom') && !d.includes('authority') && !d.includes('stub') && !d.includes('fixture') && !d.includes('test');})()"
}

@test "execute disclosure keeps exact fractional spend and HOLD-PR summary" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","approved":[{"id":"P1","route":"surgical"}],"usdPerMTok":12.5,"__budgetSpentTokens":400000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"Test proposal","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"Test proposal","route":"surgical","rationale":"small"},"skeptic:P1":{"id":"P1","skeptic_upheld":true},"build:P1":{"id":"P1","route":"surgical","branch":"feat/adopt-p1","pr_number":1,"pr_state":"OPEN","pr_url":"https://github.com/example/repo/pull/1","gate_green":true,"notes":"ok"}}}'
  json_assert "!r.error && r.result.verdicts.length === 1 && r.result.costLine === 'spent_usd 5.000000 / budget_ceiling_usd 60.00 (400000 output tokens at usd_per_mtok 12.5)' && r.logs.some((line)=>line.includes('1/1 HOLD PRs opened')) && r.logs.filter((l)=>l.startsWith('digest-adopt report: ')).length===1 && r.logs.filter((l)=>l.startsWith('digest-adopt cost disclosure: ')).length===1 && r.logs.findIndex((l)=>l.startsWith('digest-adopt cost disclosure: '))===r.logs.findIndex((l)=>l.startsWith('digest-adopt report: '))+1"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')); return d.includes('is an output-only modeled subtotal') && d.includes('usd_per_mtok 12.5') && d.includes('workflow-reported') && d.includes('report time') && d.includes('input/cache/child attribution unknown') && d.includes('recorded real/notional cost unavailable') && d.includes('max_iterations=12') && d.includes('recipe-capped') && d.includes('execute-item cap') && d.includes('actual host') && d.includes('budget') && d.includes('no-progress') && d.includes('unverified');})()"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')).toLowerCase(); return !d.includes('total spend') && !d.includes('bill') && !d.includes('money owed') && !d.includes('owed') && !d.includes('lower bound') && !d.includes('quota') && !d.includes('headroom') && !d.includes('authority') && !d.includes('stub') && !d.includes('fixture') && !d.includes('test');})()"
}

@test "missing meter disclosure keeps unavailable grammar and manufactures no zero or completeness" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","loopSafety":{"usd_per_mtok":17.5},"__agentOutputByLabel":{"ingest-digest":{"candidates":[],"skipped_settled":0}}}'
  json_assert "!r.error && r.result.costLine === 'spent_usd unavailable / budget_ceiling_usd 60.00 (output-token metering unavailable; usd_per_mtok 17.5)' && r.logs.filter((l)=>l.startsWith('digest-adopt report: ')).length===1 && r.logs.filter((l)=>l.startsWith('digest-adopt cost disclosure: ')).length===1 && r.logs.findIndex((l)=>l.startsWith('digest-adopt cost disclosure: '))===r.logs.findIndex((l)=>l.startsWith('digest-adopt report: '))+1"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')); return d.includes('spent_usd unavailable') && d.includes('no output-only modeled subtotal') && !d.includes('is an output-only modeled subtotal') && d.includes('usd_per_mtok 17.5') && d.includes('workflow-reported') && d.includes('report time') && d.includes('input/cache/child attribution unknown') && d.includes('recorded real/notional cost unavailable') && d.includes('max_iterations=12') && d.includes('recipe-capped') && d.includes('execute-item cap') && d.includes('actual host') && d.includes('budget') && d.includes('no-progress') && d.includes('unverified') && !d.includes('spent_usd 0') && !d.toLowerCase().includes('complete');})()"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')).toLowerCase(); return !d.includes('total spend') && !d.includes('bill') && !d.includes('money owed') && !d.includes('owed') && !d.includes('lower bound') && !d.includes('quota') && !d.includes('headroom') && !d.includes('authority') && !d.includes('stub') && !d.includes('fixture') && !d.includes('test');})()"
}

@test "missing rate disclosure keeps unavailable grammar and manufactures no zero or completeness" {
  run_recipe '{"digestPath":"research/ai-dev-trends/digests/test.md","__budgetSpentTokens":200000,"__agentOutputByLabel":{"ingest-digest":{"candidates":[],"skipped_settled":0}}}'
  json_assert "!r.error && r.result.costLine === 'spent_usd unavailable / budget_ceiling_usd 60.00 (200000 output tokens metered; usd_per_mtok unavailable)' && r.logs.filter((l)=>l.startsWith('digest-adopt report: ')).length===1 && r.logs.filter((l)=>l.startsWith('digest-adopt cost disclosure: ')).length===1 && r.logs.findIndex((l)=>l.startsWith('digest-adopt cost disclosure: '))===r.logs.findIndex((l)=>l.startsWith('digest-adopt report: '))+1"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')); return d.includes('spent_usd unavailable') && d.includes('no output-only modeled subtotal') && !d.includes('is an output-only modeled subtotal') && d.includes('usd_per_mtok unavailable') && d.includes('workflow-reported') && d.includes('report time') && d.includes('input/cache/child attribution unknown') && d.includes('recorded real/notional cost unavailable') && d.includes('max_iterations=12') && d.includes('recipe-capped') && d.includes('execute-item cap') && d.includes('actual host') && d.includes('budget') && d.includes('no-progress') && d.includes('unverified') && !d.includes('spent_usd 0') && !d.toLowerCase().includes('complete');})()"
  json_assert "(()=>{const d=r.logs.find((l)=>l.startsWith('digest-adopt cost disclosure: ')).toLowerCase(); return !d.includes('total spend') && !d.includes('bill') && !d.includes('money owed') && !d.includes('owed') && !d.includes('lower bound') && !d.includes('quota') && !d.includes('headroom') && !d.includes('authority') && !d.includes('stub') && !d.includes('fixture') && !d.includes('test');})()"
}
