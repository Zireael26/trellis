#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
FANOUT="$REPO/core-rules/skills/orchestrate/recipes/fanout-verify.wf.js"
VERIFY_PANEL="$REPO/core-rules/skills/orchestrate/recipes/verify-panel.wf.js"
EXECUTOR="$REPO/core-rules/skills/orchestrate/recipes/codex-executor.wf.js"
CODEX_FANOUT="$REPO/core-rules/skills/orchestrate/recipes/codex-fanout.wf.js"
DRIFT="$REPO/core-rules/skills/orchestrate/recipes/drift-holdpr.wf.js"
DIGEST="$REPO/core-rules/skills/orchestrate/recipes/digest-adopt.wf.js"
CONDUCTOR="$REPO/core-rules/skills/orchestrate/recipes/conductor.wf.js"
FLEET="$REPO/scripts/workflows/fleet-audit-remediation.wf.js"

setup() {
  TEST_TMPDIR="$BATS_TEST_TMPDIR/workflow-stage-integrity"
  mkdir -p "$TEST_TMPDIR"
}

run_recipe() {
  run node "$STUB" "$1" "$2"
  [ "$status" -eq 0 ]
}

json_assert() {
  JSON_ASSERT="$1" CAPTURED_JSON="$output" node <<'NODE'
const r = JSON.parse(process.env.CAPTURED_JSON)
const expression = process.env.JSON_ASSERT
const passed = Function('r', `return Boolean(${expression})`)(r)
if (!passed) {
  console.error(JSON.stringify(r, null, 2))
  process.exit(1)
}
NODE
}

@test "all failed required fanout units fail closed with preserved identities" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"}],"__agentThrowByLabel":{"fanout:alpha":"alpha failed","fanout:beta":"beta failed"}}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.event==="workflow_stage_gate" && row.stage==="Fan-out"); return gate && gate.expected_count===2 && gate.success_count===0 && gate.failure_count===2 && gate.failure_ids.join(",")==="alpha,beta"; })()'
}

@test "one null in a strict fanout fails instead of shrinking the result" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"}],"__agentNullByLabel":["fanout:beta"],"__agentOutputByLabel":{"fanout:alpha":{"target":"alpha","branch":"a","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"held"}}}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.expected_ids.join(",")==="alpha,beta" && gate.success_ids.join(",")==="alpha" && gate.failure_ids.join(",")==="beta"; })()'
}

@test "optional Codex reviewer failure degrades visibly while Claude remains required" {
  run_recipe "$VERIFY_PANEL" '{"targetCwd":"/tmp/repo","effort":"xhigh","codexAvailable":true,"findings":[{"id":"F1","claim":"claim","file":"a.js","severity":"critical"}],"__agentThrowByLabel":{"codex-verify:F1":"codex unavailable"},"__agentOutputByLabel":{"claude-verify:F1":{"real":false,"confidence":0.9,"reason":"not reproducible"}}}'
  json_assert '!r.error && r.result.verdicts.length===1 && r.result.verdicts[0].claude.real===false && r.result.verdicts[0].codex===null && r.result.verdicts[0].consensus==="single-model" && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Panel:Codex"); return gate && gate.min_success===0 && gate.failure_ids.join(",")==="F1"; })()'
}

@test "unavailable or malformed Codex review text degrades instead of becoming real false" {
  local base='{"targetCwd":"/tmp/repo","effort":"xhigh","codexAvailable":true,"findings":[{"id":"F1","claim":"claim","file":"a.js","severity":"critical"}],"__agentOutputByLabel":{"claude-verify:F1":{"real":false,"confidence":0.9,"reason":"not reproducible"},"codex-verify:F1":"STATUS: UNAVAILABLE\nCODE: CODEX_UNAVAILABLE"}}'
  run_recipe "$VERIFY_PANEL" "$base"
  json_assert '!r.error && r.result.verdicts[0].codex===null && r.result.verdicts[0].consensus==="single-model"'

  run_recipe "$VERIFY_PANEL" '{"targetCwd":"/tmp/repo","effort":"xhigh","codexAvailable":true,"findings":[{"id":"F1","claim":"claim","file":"a.js","severity":"critical"}],"__agentOutputByLabel":{"claude-verify:F1":{"real":false,"confidence":0.9,"reason":"not reproducible"},"codex-verify:F1":"review completed without structured fields"}}'
  json_assert '!r.error && r.result.verdicts[0].codex===null && r.result.verdicts[0].consensus==="single-model"'
}

@test "bare Codex unavailable followed by failed Claude fallback fails the unit" {
  run_recipe "$EXECUTOR" '{"codexAvailable":true,"units":[{"name":"alpha","kind":"execute","task":"change it","effort":"xhigh","targetCwd":"/tmp/alpha"}],"__agentOutputByLabel":{"codex:alpha":"STATUS: UNAVAILABLE\nCODE: CODEX_UNAVAILABLE"},"__agentThrowByLabel":{"claude:alpha":"fallback failed"}}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && r.prompts.some((p)=>p.opts.label==="codex:alpha") && r.prompts.some((p)=>p.opts.label==="claude:alpha") && !r.prompts.some((p)=>p.opts.label==="verify:alpha")'
}

@test "bare Codex failure followed by failed fanout fallback closes the wave" {
  run_recipe "$CODEX_FANOUT" '{"codexAvailable":true,"codexCap":1,"units":[{"name":"alpha","leg":"codex","task":"change it","effort":"xhigh","paths":["a.js"],"proofCmd":"node --check a.js"}],"__agentOutputByLabel":{"codex:generate:alpha":"STATUS: FAILURE\nCODE: SETUP_FAILED"},"__agentNullByLabel":["claude(degraded):generate:alpha"]}'
  json_assert 'r.error && /Fan-out:wave-1/.test(r.error.message) && r.prompts.some((p)=>p.opts.label==="codex:generate:alpha") && r.prompts.some((p)=>p.opts.label==="claude(degraded):generate:alpha") && !r.prompts.some((p)=>p.opts.label==="verify:alpha")'
}

@test "bare fleet Codex failure plus failed fallback nulls the pipeline item and skips review" {
  # The fleet workflow is private-only and is not synced to the public mirror, so this
  # assertion cannot run there. Without the guard the suite fails with ENOENT for anyone
  # who clones the mirror — found 2026-07-30 by running the mirror's own tests in a
  # throwaway apply rather than trusting the private run. Same guard the other fleet
  # assertions already use.
  [ -f "$FLEET" ] || skip "private fleet workflow is not shipped in the public mirror"
  run_recipe "$FLEET" '{"codexAvailable":true,"supportedEfforts":["xhigh"],"repoLanes":[{"repo":"alpha","path":"/tmp/alpha","base":"main","harness":"codex","effort":"xhigh","rows":[]}],"__agentOutputByLabel":{"impl:codex:alpha":"STATUS: FAILURE\nCODE: SETUP_FAILED"},"__agentNullByLabel":["impl:claude(degraded):alpha"]}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && r.prompts.some((p)=>p.opts.label==="impl:codex:alpha") && r.prompts.some((p)=>p.opts.label==="impl:claude(degraded):alpha") && !r.prompts.some((p)=>p.opts.label==="verify:alpha") && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.failure_ids.join(",")==="alpha"; })()'
}

@test "mismatched output identity fails closed" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"}],"__agentOutputByLabel":{"fanout:alpha":{"target":"other","branch":"a","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"wrong identity"}}}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.failure_ids.join(",")==="alpha"; })()'
}

@test "null final synthesizer judgment is a required-stage failure" {
  run_recipe "$EXECUTOR" '{"codexAvailable":false,"units":[{"name":"final","kind":"synthesize","task":"produce final synthesis"}],"__agentNullByLabel":["claude:final"]}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.expected_ids.join(",")==="final" && gate.failure_ids.join(",")==="final"; })()'
}

@test "stub pipeline nulls a failed item skips later stages and passes original item plus index" {
  local recipe="$TEST_TMPDIR/pipeline-parity.wf.js"
  cat > "$recipe" <<'EOF'
export const meta = { name: 'pipeline-parity', description: 'test', phases: [] }
const items = [{ id: 'a' }, { id: 'b' }]
const results = await pipeline(
  items,
  async (previous, original, index) => {
    log(JSON.stringify({ stage: 1, previous: previous.id, original: original.id, index }))
    if (original.id === 'a') throw new Error('failed first stage')
    return { id: previous.id, step: 1 }
  },
  async (previous, original, index) => {
    log(JSON.stringify({ stage: 2, previous: previous.id, original: original.id, index }))
    return { id: previous.id, step: 2, index }
  },
)
return { results }
EOF
  run_recipe "$recipe" '{}'
  json_assert '!r.error && r.result.results[0]===null && r.result.results[1].id==="b" && r.result.results[1].step===2 && r.result.results[1].index===1 && r.logs.filter((line)=>JSON.parse(line).stage===2).length===1 && JSON.parse(r.logs.find((line)=>JSON.parse(line).stage===2)).original==="b"'
}

@test "valid negative verdict remains a successful receipt" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"}],"__agentOutputByLabel":{"fanout:alpha":{"target":"alpha","branch":"","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"held for review"}}}'
  json_assert '!r.error && r.result.verdicts.length===1 && r.result.verdicts[0].target==="alpha" && r.result.verdicts[0].green===false && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.success_ids.join(",")==="alpha" && gate.failure_count===0; })()'
}

@test "optional teardown transport failure remains visible without failing fanout" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"}],"__agentOutputByLabel":{"fanout:alpha":{"target":"alpha","branch":"feat/a","pushed":true,"green":true,"pr_url":"https://example.test/pr/1","worktree_path":"/tmp/alpha-worktree","notes":"ready"}},"__agentNullByLabel":["reap:alpha"]}'
  json_assert '!r.error && r.result.verdicts.length===1 && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Teardown"); return gate && gate.min_success===0 && gate.success_count===0 && gate.failure_ids.join(",")==="alpha" && gate.ok===true; })()'
}

@test "representative mutation recipes carry the bounded wave checkpoint contract" {
  run node - "$FANOUT" "$DRIFT" "$DIGEST" "$CONDUCTOR" "$EXECUTOR" "$CODEX_FANOUT" <<'NODE'
const fs = require('node:fs')
for (const file of process.argv.slice(2)) {
  const source = fs.readFileSync(file, 'utf8')
  if (!source.includes('resolveMutationParallelism')) process.exit(1)
  if (!source.includes("event: 'workflow_checkpoint'")) process.exit(2)
  if (!source.includes('return 2')) process.exit(3)
}
NODE
  [ "$status" -eq 0 ]
}

@test "mutation fanout defaults to waves capped at two with checkpoints" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"},{"name":"gamma","path":"/tmp/gamma"},{"name":"delta","path":"/tmp/delta"},{"name":"epsilon","path":"/tmp/epsilon"}]}'
  json_assert '!r.error && (() => { const checkpoints=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).filter((row)=>row?.event==="workflow_checkpoint" && row.stage==="Fan-out"); return checkpoints.length===3 && checkpoints.map((row)=>row.expected_ids.join(",")).join("|")==="alpha,beta|gamma,delta|epsilon" && checkpoints.every((row)=>row.expected_ids.length<=2 && row.ok===true); })()'
}

@test "larger mutation wave accepts only current-run exact-target scoped pilot evidence" {
  local args_json
  args_json="$(node <<'NODE'
const targets = [
  { name: 'alpha', path: '/tmp/alpha' },
  { name: 'beta', path: '/tmp/beta' },
  { name: 'gamma', path: '/tmp/gamma' },
]
const task = 'apply the requested change'
const scope = JSON.stringify({ task, targets: targets.map((t) => ({ id: t.name, path: t.path })) })
process.stdout.write(JSON.stringify({
  maxParallel: 3,
  parallelJustification: 'three isolated repositories fit the measured budget',
  runId: 'run-current',
  pilotReceipt: {
    completed: true,
    recipe: 'fanout-verify',
    run_id: 'run-current',
    target_ids: ['alpha', 'beta'],
    success_ids: ['alpha', 'beta'],
    scope_fingerprint: scope,
  },
  loopSafety: { budget_ceiling_usd: 40 },
  targets,
}))
NODE
)"
  run_recipe "$FANOUT" "$args_json"
  json_assert '!r.error && (() => { const checkpoints=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).filter((row)=>row?.event==="workflow_checkpoint" && row.stage==="Fan-out"); return checkpoints.length===1 && checkpoints[0].expected_ids.join(",")==="alpha,beta,gamma"; })()'
}

@test "reordered pilot successes cannot authorize a larger mutation wave" {
  local args_json
  args_json="$(node <<'NODE'
const targets = [
  { name: 'alpha', path: '/tmp/alpha' },
  { name: 'beta', path: '/tmp/beta' },
  { name: 'gamma', path: '/tmp/gamma' },
]
const task = 'apply the requested change'
const scope = JSON.stringify({ task, targets: targets.map((t) => ({ id: t.name, path: t.path })) })
process.stdout.write(JSON.stringify({
  maxParallel: 3,
  parallelJustification: 'ordering is part of the pilot identity',
  runId: 'run-current',
  pilotReceipt: {
    completed: true,
    recipe: 'fanout-verify',
    run_id: 'run-current',
    target_ids: ['alpha', 'beta'],
    success_ids: ['beta', 'alpha'],
    scope_fingerprint: scope,
  },
  loopSafety: { budget_ceiling_usd: 40 },
  targets,
}))
NODE
)"
  run_recipe "$FANOUT" "$args_json"
  json_assert 'r.error && /pilotReceipt/.test(r.error.message) && r.prompts.length===0'
}

@test "larger mutation wave fails closed without complete override evidence" {
  run_recipe "$FANOUT" '{"maxParallel":3,"parallelJustification":"missing pilot and budget","targets":[{"name":"alpha","path":"/tmp/alpha"}]}'
  json_assert 'r.error && /pilotReceipt/.test(r.error.message) && r.prompts.length===0'
}

@test "failed first mutation wave emits no checkpoint and never starts the next wave" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"},{"name":"gamma","path":"/tmp/gamma"}],"__agentNullByLabel":["fanout:beta"]}'
  json_assert 'r.error && r.prompts.some((p)=>p.opts.label==="fanout:alpha") && r.prompts.some((p)=>p.opts.label==="fanout:beta") && !r.prompts.some((p)=>p.opts.label==="fanout:gamma") && !r.logs.some((line)=>{try{return JSON.parse(line)?.event==="workflow_checkpoint"}catch{return false}})'
}

@test "mutation waves preserve original result ordering" {
  run_recipe "$FANOUT" '{"targets":[{"name":"gamma","path":"/tmp/gamma"},{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"}],"__agentOutputByLabel":{"fanout:gamma":{"target":"gamma","branch":"g","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"g"},"fanout:alpha":{"target":"alpha","branch":"a","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"a"},"fanout:beta":{"target":"beta","branch":"b","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"b"}}}'
  json_assert '!r.error && r.result.verdicts.map((row)=>row.target).join(",")==="gamma,alpha,beta"'
}

@test "codex-executor rejects normalized targetCwd reuse across different waves before dispatch" {
  run_recipe "$EXECUTOR" '{"codexAvailable":false,"units":[{"name":"alpha","kind":"execute","task":"a","effort":"xhigh","targetCwd":"/tmp/shared/./"},{"name":"beta","kind":"execute","task":"b","effort":"xhigh","targetCwd":"/tmp/beta"},{"name":"gamma","kind":"execute","task":"c","effort":"xhigh","targetCwd":"/tmp/other/../shared"}]}'
  json_assert 'r.error && /share normalized targetCwd/.test(r.error.message) && /across the mutation run/.test(r.error.message) && r.prompts.length===0'
}

@test "unrelated old pilot evidence fails closed before mutation dispatch" {
  run_recipe "$FANOUT" '{"maxParallel":3,"parallelJustification":"old evidence must not authorize this run","runId":"run-current","pilotReceipt":{"completed":true,"recipe":"other-recipe","run_id":"run-old","target_ids":["alpha","beta"],"success_ids":["alpha","beta"],"scope_fingerprint":"old-scope"},"loopSafety":{"budget_ceiling_usd":40},"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"},{"name":"gamma","path":"/tmp/gamma"}]}'
  json_assert 'r.error && /current-run/.test(r.error.message) && /exact first two target IDs/.test(r.error.message) && r.prompts.length===0'
}

@test "duplicate mutation target IDs are rejected before first dispatch" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"alpha","path":"/tmp/alpha-duplicate"}]}'
  json_assert 'r.error && /duplicate expected id/.test(r.error.message) && /before Fan-out dispatch/.test(r.error.message) && r.prompts.length===0'
}

@test "fanout teardown uses the same bounded waves as mutation" {
  local args_json
  args_json="$(node <<'NODE'
const targets = ['alpha', 'beta', 'gamma', 'delta', 'epsilon'].map((name) => ({ name, path: '/tmp/' + name }))
const outputs = Object.fromEntries(targets.map(({ name }) => ['fanout:' + name, {
  target: name,
  branch: 'feat/' + name,
  pushed: true,
  green: true,
  pr_url: 'https://example.test/pr/' + name,
  worktree_path: '/tmp/' + name + '-worktree',
  notes: 'ready',
}]))
process.stdout.write(JSON.stringify({ targets, __agentOutputByLabel: outputs }))
NODE
)"
  run_recipe "$FANOUT" "$args_json"
  json_assert '!r.error && (() => { const checkpoints=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).filter((row)=>row?.event==="workflow_checkpoint" && row.stage==="Teardown"); return checkpoints.length===3 && checkpoints.map((row)=>row.expected_ids.join(",")).join("|")==="alpha,beta|gamma,delta|epsilon" && checkpoints.every((row)=>row.expected_ids.length<=2); })()'
}

@test "pure judgment executor run ignores mutation override evidence requirements" {
  run_recipe "$EXECUTOR" '{"maxParallel":8,"codexAvailable":true,"units":[{"name":"plan","kind":"plan","task":"plan only"},{"name":"review","kind":"review","task":"review only"}]}'
  json_assert '!r.error && r.result.judgments.map((row)=>row.unit).join(",")==="plan,review" && r.prompts.every((entry)=>!entry.opts.agentType)'
}

@test "codex-executor rejects unknown kinds before dispatch" {
  run_recipe "$EXECUTOR" '{"codexAvailable":true,"units":[{"name":"typo","kind":"execute-typo","task":"must not bypass mutation guards"}]}'
  json_assert 'r.error && /kind must be one of execute, plan, review, synthesize/.test(r.error.message) && r.prompts.length===0'
}

@test "zero-mutation runs ignore mutation-only override evidence across recipes" {
  run_recipe "$FANOUT" '{"maxParallel":8,"__agentOutputByLabel":{"resolve-targets":{"targets":[]}}}'
  json_assert '!r.error && r.result.verdicts.length===0'

  run_recipe "$DRIFT" '{"maxParallel":8,"drifts":[{"project":"alpha","path":"hooks/a.sh","fix":"intentional divergence","mechanical":false}]}'
  json_assert '!r.error && r.result.verdicts.length===0'

  run_recipe "$DIGEST" '{"maxParallel":8,"digestPath":"digest.md","approved":[{"id":"P1","route":"validation-only"}],"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"already present","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"already present","route":"validation-only","rationale":"no mutation","skeptic_upheld":true}}}'
  json_assert '!r.error && r.result.verdicts.length===0'

  run_recipe "$CONDUCTOR" '{"maxParallel":8,"today":"2026-07-28","__agentOutputByLabel":{"refresh-refs":{"complete":true,"refs":[],"notes":"none"},"rank":{"generated_for":"2026-07-28","ranked":[]}}}'
  json_assert '!r.error && r.result.specs.length===0'
}

@test "codex-fanout pilot scope binds dependency routing effort conflicts and cap" {
  local args_json
  args_json="$(node <<'NODE'
const units = [
  { name: 'alpha', leg: 'claude', task: 'a', paths: ['a.js'], proofCmd: 'node --check a.js', targetCwd: '/tmp/alpha', dependsOn: [], conflicts: false },
  { name: 'beta', leg: 'claude', task: 'b', paths: ['b.js'], proofCmd: 'node --check b.js', targetCwd: '/tmp/beta', dependsOn: ['alpha'], conflicts: false },
  { name: 'gamma', leg: 'claude', task: 'c', paths: ['c.js'], proofCmd: 'node --check c.js', targetCwd: '/tmp/gamma', dependsOn: ['beta'], conflicts: false },
]
const staleScope = JSON.stringify(units.map((unit) => ({
  id: unit.name,
  task: unit.task,
  paths: unit.paths,
  proofCmd: unit.proofCmd,
  targetCwd: unit.targetCwd,
})))
process.stdout.write(JSON.stringify({
  maxParallel: 3,
  parallelJustification: 'stale scope must not unlock changed execution semantics',
  runId: 'run-current',
  pilotReceipt: {
    completed: true,
    recipe: 'codex-fanout',
    run_id: 'run-current',
    target_ids: ['alpha', 'beta'],
    success_ids: ['alpha', 'beta'],
    scope_fingerprint: staleScope,
  },
  loopSafety: { budget_ceiling_usd: 40 },
  codexCap: 1,
  codexAvailable: false,
  units,
}))
NODE
)"
  run_recipe "$CODEX_FANOUT" "$args_json"
  json_assert 'r.error && /pilotReceipt/.test(r.error.message) && r.prompts.length===0'
}

@test "all copied mutation helpers enforce unique IDs and current-run pilot binding" {
  run node - "$FANOUT" "$DRIFT" "$DIGEST" "$CONDUCTOR" "$EXECUTOR" "$CODEX_FANOUT" <<'NODE'
const fs = require('node:fs')
for (const file of process.argv.slice(2)) {
  const source = fs.readFileSync(file, 'utf8')
  if (!source.includes('assertUniqueExpectedIds')) process.exit(1)
  if (!source.includes("pilot?.recipe === meta.name")) process.exit(2)
  if (!source.includes('pilot?.run_id === runId')) process.exit(3)
  if (!source.includes('exact first two target IDs')) process.exit(4)
}
NODE
  [ "$status" -eq 0 ]
}
