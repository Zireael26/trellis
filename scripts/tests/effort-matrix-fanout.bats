#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
RECIPE="$REPO/core-rules/skills/orchestrate/recipes/codex-fanout.wf.js"

_run_fanout() {
  local args="$1"
  run node "$STUB" "$RECIPE" "$args"
  [ "$status" -eq 0 ]
}

_json_assert() {
  local expression="$1"
  CAPTURED_JSON="$output" node -e "const r = JSON.parse(process.env.CAPTURED_JSON); if (!($expression)) { console.error(JSON.stringify(r, null, 2)); process.exit(1) }"
}

@test "loop safety allows the first stall retry and halts on the second no-progress event" {
  run node - "$RECIPE" <<'NODE'
const fs = require('node:fs')
const source = fs.readFileSync(process.argv[2], 'utf8')
const threshold = source.match(/no_progress_iterations:\s*(\d+)/)
if (!threshold || Number(threshold[1]) !== 2) process.exit(1)
if (!source.includes('First worker stall retries; a second no-progress iteration halts.')) process.exit(2)
const manifest = fs.readFileSync(process.argv[2].replace(/codex-fanout\.wf\.js$/, 'MANIFEST.md'), 'utf8')
const row = manifest.split('\n').find((line) => line.startsWith('| `codex-fanout` |')) || ''
if (!row.includes('`no_progress_iterations: 2`') || !row.includes('halts on the second consecutive no-progress event')) process.exit(3)
NODE
  [ "$status" -eq 0 ]
}

@test "omitted Codex effort throws before dispatch" {
  _run_fanout '{"codexAvailable":true,"codexCap":2,"units":[{"name":"codex-a","leg":"codex","task":"bounded change","paths":["src/a.js"],"proofCmd":"node --check src/a.js"}]}'
  _json_assert "r.error && r.error.message.includes('codex-a') && r.error.message.includes('effort') && r.error.message.includes('no default') && r.prompts.length === 0"
}

@test "ultra hard-rejects with D4a log before dispatch" {
  _run_fanout '{"codexAvailable":true,"codexCap":2,"units":[{"name":"codex-a","leg":"codex","task":"bounded change","effort":"ultra","paths":["src/a.js"],"proofCmd":"node --check src/a.js"}]}'
  _json_assert "r.error && /ultra/i.test(r.error.message) && /D4a/i.test(r.error.message) && r.logs.some((line) => /ultra/i.test(line) && /D4a/i.test(line)) && r.prompts.length === 0"
}

@test "unknown effort and max without justification throw before dispatch" {
  _run_fanout '{"codexAvailable":true,"codexCap":2,"units":[{"name":"codex-a","leg":"codex","task":"bounded change","effort":"turbo","paths":["src/a.js"],"proofCmd":"node --check src/a.js"}]}'
  _json_assert "r.error && r.error.message.includes('turbo') && r.error.message.includes('enum') && r.prompts.length === 0"

  _run_fanout '{"codexAvailable":true,"codexCap":2,"units":[{"name":"codex-a","leg":"codex","task":"bounded change","effort":"max","paths":["src/a.js"],"proofCmd":"node --check src/a.js"}]}'
  _json_assert "r.error && r.error.message.includes('max') && r.error.message.includes('justification') && r.prompts.length === 0"
}

@test "Codex generation never exceeds codexCap before the wave completes" {
  _run_fanout '{"codexAvailable":true,"codexCap":2,"units":[{"name":"codex-a","leg":"codex","task":"change a","effort":"xhigh","paths":["src/a.js"],"proofCmd":"node --check src/a.js"},{"name":"codex-b","leg":"codex","task":"change b","effort":"xhigh","paths":["src/b.js"],"proofCmd":"node --check src/b.js"},{"name":"claude-a","leg":"claude","task":"change c","paths":["src/c.js"],"proofCmd":"node --check src/c.js"},{"name":"codex-c","leg":"codex","task":"change d","effort":"xhigh","paths":["src/d.js"],"proofCmd":"node --check src/d.js"}]}'
  _json_assert "!r.error && (() => { const labels = r.prompts.map((entry) => entry.opts.label || ''); const thirdCodex = labels.indexOf('codex:generate:codex-c'); const firstVerify = labels.findIndex((label) => label.startsWith('verify:')); const beforeBarrier = labels.slice(0, firstVerify).filter((label) => label.startsWith('codex:generate:')); return labels.filter((label) => label.startsWith('codex:generate:')).length === 3 && beforeBarrier.length === 2 && thirdCodex > firstVerify && r.prompts.filter((entry) => (entry.opts.label || '').startsWith('codex:generate:')).every((entry) => entry.opts.agentType === 'codex-worker'); })()"
}

@test "Claude units bypass the Codex cap and stay in the current wave" {
  _run_fanout '{"codexAvailable":true,"codexCap":1,"units":[{"name":"codex-a","leg":"codex","task":"change a","effort":"xhigh","paths":["src/a.js"],"proofCmd":"node --check src/a.js"},{"name":"claude-a","leg":"claude","task":"change b","paths":["src/b.js"],"proofCmd":"node --check src/b.js"},{"name":"claude-b","leg":"claude","task":"change c","paths":["src/c.js"],"proofCmd":"node --check src/c.js"},{"name":"codex-b","leg":"codex","task":"change d","effort":"xhigh","paths":["src/d.js"],"proofCmd":"node --check src/d.js"}]}'
  _json_assert "!r.error && (() => { const labels = r.prompts.map((entry) => entry.opts.label || ''); const nextCodex = labels.indexOf('codex:generate:codex-b'); return labels.indexOf('claude:generate:claude-a') < nextCodex && labels.indexOf('claude:generate:claude-b') < nextCodex && r.prompts.filter((entry) => (entry.opts.label || '').startsWith('claude:generate:')).every((entry) => !('agentType' in entry.opts)); })()"
}

@test "receipts are green and returned in dependency merge order" {
  _run_fanout '{"codexAvailable":true,"codexCap":2,"units":[{"name":"leaf","leg":"claude","task":"change leaf","paths":["src/leaf.js"],"proofCmd":"node --check src/leaf.js","dependsOn":["root"]},{"name":"root","leg":"codex","task":"change root","effort":"max","justification":"critical dependency root","paths":["src/root.js"],"proofCmd":"node --check src/root.js","conflicts":true,"targetCwd":"/tmp/root-worktree"},{"name":"independent","leg":"claude","task":"change independent","paths":["src/independent.js"],"proofCmd":"node --check src/independent.js"}]}'
  _json_assert "!r.error && r.result && (() => { const receipts = r.result.receipts; const root = receipts.find((receipt) => receipt.name === 'root'); const labels = r.prompts.map((entry) => entry.opts.label || ''); const producer = r.prompts.find((entry) => entry.opts.label === 'codex:generate:root'); const verifier = r.prompts.find((entry) => entry.opts.label === 'verify:root'); return receipts.map((receipt) => receipt.name).join(',') === 'root,independent,leaf' && receipts.every((receipt) => receipt.green && receipt.reviewed) && root.effort === 'max' && root.justification === 'critical dependency root' && root.branch === 'unit/root' && root.targetCwd === '/tmp/root-worktree' && producer.prompt.includes('TARGET_CWD: /tmp/root-worktree') && verifier.prompt.includes('TARGET_CWD: /tmp/root-worktree') && !('isolation' in producer.opts) && !('isolation' in verifier.opts) && !producer.prompt.includes('commit only') && labels.indexOf('claude:generate:leaf') > labels.indexOf('verify:root'); })()"
}

@test "M8 conflicting units require one targetCwd and reuse it through generate verify and fix" {
  _run_fanout '{"codexAvailable":true,"codexCap":1,"units":[{"name":"root","leg":"codex","task":"change root","effort":"xhigh","paths":["src/root.js"],"proofCmd":"node --check src/root.js","conflicts":true}]}'
  _json_assert "r.error && /targetCwd/.test(r.error.message) && /stable worktree/.test(r.error.message) && r.prompts.length === 0"

  _run_fanout '{"codexAvailable":true,"codexCap":1,"__agentOutputByLabel":{"verify:root":{"unit":"root","green":false,"reviewed":true,"notes":"repair required"}},"units":[{"name":"root","leg":"codex","task":"change root","effort":"xhigh","paths":["src/root.js"],"proofCmd":"node --check src/root.js","conflicts":true,"targetCwd":"/tmp/root-stable"}]}'
  _json_assert "!r.error && (() => { const stages = r.prompts.filter((entry) => ['codex:generate:root', 'verify:root', 'codex:fix:root'].includes(entry.opts.label)); return stages.length === 4 && stages.every((entry) => entry.prompt.includes('/tmp/root-stable') && !('isolation' in entry.opts)) && r.prompts.filter((entry) => entry.opts.label === 'verify:root').length === 2 && !stages.some((entry) => entry.prompt.includes('commit only') || entry.prompt.includes('commit it to')); })()"
}

@test "codexCap is caller-required and fails before dispatch when omitted" {
  _run_fanout '{"codexAvailable":true,"units":[{"name":"codex-a","leg":"codex","task":"change a","effort":"xhigh","paths":["src/a.js"],"proofCmd":"node --check src/a.js"}]}'
  _json_assert "r.error && /codexCap/.test(r.error.message) && /required/.test(r.error.message) && /positive integer/.test(r.error.message) && r.prompts.length === 0"
}

@test "receipt STATUS parsing ignores failure literals outside the receipt block" {
  _run_fanout '{"codexAvailable":true,"codexCap":1,"__agentOutputByLabel":{"codex:generate:codex-a":"diff fixture: STATUS: FAILURE\n--- CODEX-WORKER RECEIPT ---\nSTATUS: SUCCESS\n--- END RECEIPT ---"},"units":[{"name":"codex-a","leg":"codex","task":"change a","effort":"xhigh","paths":["src/a.js"],"proofCmd":"node --check src/a.js"}]}'
  _json_assert "!r.error && r.result.receipts[0].leg === 'codex' && !r.prompts.some((entry) => (entry.opts.label || '').startsWith('claude(degraded):'))"
}

@test "leaked Codex handle is cancelled before Claude degradation" {
  _run_fanout '{"codexAvailable":true,"codexCap":1,"__agentOutputByLabel":{"codex:generate:codex-a":"{\"jobId\":\"job-abcdef12\"}"},"units":[{"name":"codex-a","leg":"codex","task":"change a","effort":"xhigh","paths":["src/a.js"],"proofCmd":"node --check src/a.js"}]}'
  _json_assert "!r.error && r.logs.some((line) => /leaked a job handle/.test(line)) && r.prompts.some((entry) => entry.opts.label === 'cancel-leaked:codex-a' && entry.prompt.includes('cancel job-abcdef12 --json')) && r.prompts.some((entry) => entry.opts.label === 'claude(degraded):generate:codex-a')"
}

@test "dependsOn cycle throws before dispatch" {
  _run_fanout '{"codexAvailable":false,"codexCap":1,"units":[{"name":"a","leg":"claude","task":"a","paths":["a"],"proofCmd":"true","dependsOn":["b"]},{"name":"b","leg":"claude","task":"b","paths":["b"],"proofCmd":"true","dependsOn":["a"]}]}'
  _json_assert "r.error && /cycle/.test(r.error.message) && r.prompts.length === 0"
}
