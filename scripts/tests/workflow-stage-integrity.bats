#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
FANOUT="$REPO/core-rules/skills/orchestrate/recipes/fanout-verify.wf.js"
DRIFT="$REPO/core-rules/skills/orchestrate/recipes/drift-holdpr.wf.js"
DIGEST="$REPO/core-rules/skills/orchestrate/recipes/digest-adopt.wf.js"
CONDUCTOR="$REPO/core-rules/skills/orchestrate/recipes/conductor.wf.js"
TEMPLATE="$REPO/core-rules/skills/orchestrate/recipes/template.wf.js"

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

@test "generic recipe dispatch inherits the main loop model at every site except conductor's routed auto-execution" {
  run bash "$REPO/scripts/lint-recipe-routing.sh" --list "$FANOUT" "$DRIFT" "$DIGEST" "$CONDUCTOR" "$TEMPLATE"
  [ "$status" -eq 0 ]
  # conductor now routes Auto-spec + Review specs + Auto-execute via explicit agentType (distinct-family);
  # Refresh/Rank and all other recipes remain inherited. Digest now has triage + skeptic (4 sites).
  [ "$(printf '%s\n' "$output" | grep -c ':inherit$')" -eq 12 ]
  [ "$(printf '%s\n' "$output" | grep -c ':agentType$')" -eq 3 ]
  run bash "$REPO/scripts/lint-recipe-routing.sh" --list "$CONDUCTOR"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c ':inherit$')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c ':agentType$')" -eq 3 ]

  run node --input-type=module - "$STUB" "$FANOUT" "$DRIFT" "$DIGEST" "$CONDUCTOR" "$TEMPLATE" <<'NODE'
import { pathToFileURL } from 'node:url'

const [stub, fanout, drift, digest, conductor, template] = process.argv.slice(2)
const { runWorkflow } = await import(pathToFileURL(stub).href)
const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key)
const fail = (message, run) => {
  console.error(message)
  if (run) console.error(JSON.stringify({ error: run.error, opts: run.prompts.map((entry) => entry.opts) }, null, 2))
  process.exit(1)
}

const cases = [
  {
    name: 'fanout-verify',
    path: fanout,
    args: {
      __agentOutputByLabel: {
        'resolve-targets': { targets: [{ name: 'alpha', path: '/tmp/alpha' }] },
        'fanout:alpha': { target: 'alpha', branch: 'feat/a', pushed: true, green: true, pr_url: 'https://example.test/pr/1', worktree_path: '/tmp/alpha-worktree', notes: 'ready' },
      },
    },
    expected: ['resolve-targets', 'fanout:alpha', 'reap:alpha'],
  },
  {
    name: 'drift-holdpr',
    path: drift,
    args: {
      __agentOutputByLabel: {
        'discover-drift': { drifts: [{ project: 'alpha', path: 'hooks/a.sh', canonical: 'core/a.sh', fix: 'sync a', mechanical: true }] },
      },
    },
    expected: ['discover-drift', 'drift:alpha'],
  },
  {
    name: 'digest-adopt',
    path: digest,
    args: {
      digestPath: 'digest.md',
      approved: [{ id: 'P1', route: 'surgical' }],
      __agentOutputByLabel: {
        'ingest-digest': { candidates: [{ id: 'P1', title: 'probe', effort: 'S', risk: 'lo' }], skipped_settled: 0 },
        'triage:P1': { id: 'P1', title: 'probe', route: 'surgical', rationale: 'ok' },
        'skeptic:P1': { id: 'P1', skeptic_upheld: true },
      },
    },
    expected: ['ingest-digest', 'triage:P1', 'skeptic:P1', 'build:P1'],
  },
  {
    name: 'conductor',
    path: conductor,
    args: {
      today: '2026-08-03',
      backlogPath: '/private/tasks/personal/conductor/backlog.json',
      registryPath: '/private/tasks/personal/conductor/snapshot.json',
      __agentOutputByLabel: {
        rank: { generated_for: '2026-08-03', ranked: [{ id: 's1', project: 'repo', title: 'probe', score: 1, reasons: 'top', eligible_auto_spec: true, auto_spec: null, delivered_on_main: false, existing_spec_path: '', auto_spec_exclusions: [] }] },
      },
    },
    expected: ['refresh-refs', 'rank'],
  },
  {
    // The authoring template is executable under the stub so its live helper stays covered.
    name: 'template',
    path: template,
    args: {},
    expected: ['work'],
  },
]

for (const item of cases) {
  const run = await runWorkflow(item.path, item.args)
  if (run.error) fail(`${item.name} threw`, run)
  for (const label of item.expected) {
    const matches = run.prompts.filter((entry) => entry.opts.label === label)
    if (matches.length !== 1) fail(`${item.name}:${label} dispatched ${matches.length} times`, run)
    if (hasOwn(matches[0].opts, 'agentType')) {
      fail(`${item.name}:${label} owns agentType — generic dispatch must inherit the main loop's model`, run)
    }
  }
}
// Conductor auto-execution must be typed with distinct-family agents, not inherited.
{
  const sha = '2222222222222222222222222222222222222222'
  const run = await runWorkflow(conductor, {
    today: '2026-08-03',
    backlogPath: '/private/tasks/personal/conductor/backlog.json',
    registryPath: '/private/tasks/personal/conductor/snapshot.json',
    autoSpecTopN: 1,
    autoExecuteTopN: 1,
    authorAgent: 'sol',
    reviewerAgent: 'grok',
    __agentOutputByLabel: {
      'refresh-refs': { complete: true, refs: [{ project: 'repo', repo_path: '/tmp/repo', main_sha: sha }], notes: 'ok' },
      rank: { generated_for: '2026-08-03', ranked: [{ id: 'alpha', project: 'repo', title: 'alpha', score: 1, reasons: 'top', eligible_auto_spec: true, auto_spec: null, delivered_on_main: false, existing_spec_path: '', auto_spec_exclusions: [], safe: null, surgical: false, status: 'todo' }] },
      'spec:alpha': { id: 'alpha', branch: 'feature/alpha', spec_path: 'specs/001-alpha/', ready: true, notes: 'ready' },
      'review:alpha': { id: 'alpha', reviewed: true, ready: true, notes: 'approved' },
      'execute:alpha': { id: 'alpha', branch: 'feature/alpha', pr_url: 'https://github.com/example/repo/pull/7', gate_green: true, notes: 'green' },
    },
  })
  if (run.error) fail('conductor routed auto-execution threw', run)
  const spec = run.prompts.find((p) => p.opts.label === 'spec:alpha')
  const rev = run.prompts.find((p) => p.opts.label === 'review:alpha')
  const exe = run.prompts.find((p) => p.opts.label === 'execute:alpha')
  if (!spec || !rev || !exe) fail('conductor routed auto-execution did not dispatch spec+review+execute', run)
  if (spec.opts.agentType !== 'sol') fail('conductor spec must carry author agentType sol when autoExecute', run)
  if (rev.opts.agentType !== 'grok') fail('conductor review must carry reviewer agentType grok', run)
  if (exe.opts.agentType !== 'sol') fail('conductor execute must carry author agentType sol', run)
  if (hasOwn(spec.opts, 'agent') || hasOwn(rev.opts, 'agent') || hasOwn(exe.opts, 'agent')) fail('conductor routed stages must use agentType only, not agent', run)
  if (run.result.routing_status !== 'routed' || run.result.auto_execute_hold !== false) fail('conductor routed run must be routing_status routed and not held', run)
}
NODE
  [ "$status" -eq 0 ]
}

@test "all failed required fanout units fail closed with preserved identities" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"}],"__agentThrowByLabel":{"fanout:alpha":"alpha failed","fanout:beta":"beta failed"}}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.event==="workflow_stage_gate" && row.stage==="Fan-out"); return gate && gate.expected_count===2 && gate.success_count===0 && gate.failure_count===2 && gate.failure_ids.join(",")==="alpha,beta"; })()'
}

@test "one null in a strict fanout fails instead of shrinking the result" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"},{"name":"beta","path":"/tmp/beta"}],"__agentNullByLabel":["fanout:beta"],"__agentOutputByLabel":{"fanout:alpha":{"target":"alpha","branch":"a","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"held"}}}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.expected_ids.join(",")==="alpha,beta" && gate.success_ids.join(",")==="alpha" && gate.failure_ids.join(",")==="beta"; })()'
}

@test "mismatched output identity fails closed" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"}],"__agentOutputByLabel":{"fanout:alpha":{"target":"other","branch":"a","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"wrong identity"}}}'
  json_assert 'r.error && /Fan-out/.test(r.error.message) && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.failure_ids.join(",")==="alpha"; })()'
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

@test "CODEX_UNAVAILABLE receipts fail the selected lane without provider fallback" {
  run_recipe "$TEMPLATE" '{"__agentOutputByLabel":{"work":"CODEX_UNAVAILABLE"}}'
  json_assert 'r.error && /Work/.test(r.error.message) && r.prompts.length===1 && r.prompts[0].opts.label==="work" && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Work"); return gate && gate.success_count===0 && gate.failure_ids.join(",")==="work" && gate.ok===false; })()'

  run_recipe "$TEMPLATE" '{"__agentOutputByLabel":{"work":{"error":{"code":"CODEX_UNAVAILABLE"}}}}'
  json_assert 'r.error && /Work/.test(r.error.message) && r.prompts.length===1 && r.prompts[0].opts.label==="work" && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Work"); return gate && gate.success_count===0 && gate.failure_ids.join(",")==="work" && gate.ok===false; })()'
}

@test "valid business HOLD remains a successful receipt" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"}],"__agentOutputByLabel":{"fanout:alpha":{"target":"alpha","branch":"","pushed":false,"green":false,"pr_url":"","worktree_path":"","notes":"HOLD: awaiting review"}}}'
  json_assert '!r.error && r.result.verdicts.length===1 && r.result.verdicts[0].target==="alpha" && r.result.verdicts[0].green===false && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Fan-out"); return gate && gate.success_ids.join(",")==="alpha" && gate.failure_count===0; })()'
}

@test "optional teardown transport failure remains visible without failing fanout" {
  run_recipe "$FANOUT" '{"targets":[{"name":"alpha","path":"/tmp/alpha"}],"__agentOutputByLabel":{"fanout:alpha":{"target":"alpha","branch":"feat/a","pushed":true,"green":true,"pr_url":"https://example.test/pr/1","worktree_path":"/tmp/alpha-worktree","notes":"ready"}},"__agentNullByLabel":["reap:alpha"]}'
  json_assert '!r.error && r.result.verdicts.length===1 && (() => { const gate=r.logs.map((line)=>{try{return JSON.parse(line)}catch{return null}}).find((row)=>row?.stage==="Teardown"); return gate && gate.min_success===0 && gate.success_count===0 && gate.failure_ids.join(",")==="alpha" && gate.ok===true; })()'
}

@test "representative mutation recipes carry the bounded wave checkpoint contract" {
  run node - "$FANOUT" "$DRIFT" "$DIGEST" "$CONDUCTOR" <<'NODE'
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

@test "zero-mutation runs ignore mutation-only override evidence across recipes" {
  run_recipe "$FANOUT" '{"maxParallel":8,"__agentOutputByLabel":{"resolve-targets":{"targets":[]}}}'
  json_assert '!r.error && r.result.verdicts.length===0'

  run_recipe "$DRIFT" '{"maxParallel":8,"drifts":[{"project":"alpha","path":"hooks/a.sh","fix":"intentional divergence","mechanical":false}]}'
  json_assert '!r.error && r.result.verdicts.length===0'

  run_recipe "$DIGEST" '{"maxParallel":8,"digestPath":"digest.md","approved":[{"id":"P1","route":"validation-only"}],"__agentOutputByLabel":{"ingest-digest":{"candidates":[{"id":"P1","title":"already present","effort":"S","risk":"lo"}],"skipped_settled":0},"triage:P1":{"id":"P1","title":"already present","route":"validation-only","rationale":"no mutation"},"skeptic:P1":{"id":"P1","skeptic_upheld":true}}}'
  json_assert '!r.error && r.result.verdicts.length===0'

  run_recipe "$CONDUCTOR" '{"maxParallel":8,"today":"2026-07-28","backlogPath":"/private/tasks/personal/conductor/backlog.json","registryPath":"/private/tasks/personal/conductor/snapshot.json","__agentOutputByLabel":{"refresh-refs":{"complete":true,"refs":[],"notes":"none"},"rank":{"generated_for":"2026-07-28","ranked":[]}}}'
  json_assert '!r.error && r.result.specs.length===0'
}

@test "all copied mutation helpers enforce unique IDs and current-run pilot binding" {
  run node - "$FANOUT" "$DRIFT" "$DIGEST" "$CONDUCTOR" <<'NODE'
const fs = require('node:fs')
for (const file of process.argv.slice(2)) {
  const source = fs.readFileSync(file, 'utf8')
  if (!source.includes('assertUniqueExpectedIds')) process.exit(1)
  if (!source.includes("pilot?.recipe === RECIPE_NAME")) process.exit(2)
  if (!source.includes('pilot?.run_id === runId')) process.exit(3)
  if (!source.includes('exact first two target IDs')) process.exit(4)
}
NODE
  [ "$status" -eq 0 ]
}
