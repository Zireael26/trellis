#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
DRIFT_RECIPE="$REPO/core-rules/skills/orchestrate/recipes/drift-holdpr.wf.js"
CONDUCTOR_RECIPE="$REPO/core-rules/skills/orchestrate/recipes/conductor.wf.js"
FLEET_RECIPE="$REPO/scripts/workflows/fleet-audit-remediation.wf.js"
CONFIG_SCHEMA="$REPO/scripts/lib/trellis.config.schema.json"
CONFIG_EXAMPLE="$REPO/core-rules/templates/trellis.config.json.example"

_run_recipe() {
  local recipe="$1" args="$2"
  run node "$STUB" "$recipe" "$args"
  [ "$status" -eq 0 ]
}

_json_assert() {
  local expression="$1"
  CAPTURED_JSON="$output" node -e "const r = JSON.parse(process.env.CAPTURED_JSON); if (!($expression)) { console.error(JSON.stringify(r, null, 2)); process.exit(1) }"
}

@test "M10 groups every mechanical drift file into one remediation unit per project" {
  _run_recipe "$DRIFT_RECIPE" '{"drifts":[{"project":"alpha","path":"hooks/a.sh","canonical":"core/a.sh","fix":"sync a","mechanical":true},{"project":"alpha","path":"hooks/b.sh","canonical":"core/b.sh","fix":"sync b","mechanical":true},{"project":"beta","path":"hooks/c.sh","canonical":"core/c.sh","fix":"sync c","mechanical":true},{"project":"alpha","path":"hooks/manual.sh","fix":"intentional divergence","mechanical":false}]}'
  _json_assert "!r.error && (() => { const alpha = r.prompts.filter((entry) => entry.opts.label === 'drift:alpha'); const beta = r.prompts.filter((entry) => entry.opts.label === 'drift:beta'); return alpha.length === 1 && beta.length === 1 && alpha[0].prompt.includes('hooks/a.sh') && alpha[0].prompt.includes('hooks/b.sh') && !alpha[0].prompt.includes('hooks/manual.sh') && r.logs.some((line) => line.includes('3 mechanical drift file(s) grouped into 2 project HOLD PR(s)')); })()"
}

@test "M11 conductor applies force exempt anti-dup controls and serializes args.weights" {
  _run_recipe "$CONDUCTOR_RECIPE" '{"today":"2026-07-14","backlogPath":"backlog.yml","registryPath":"registry.md","autoSpecTopN":3,"weights":{"deadline":0.7,"impact":0.3},"__agentOutputByLabel":{"rank":{"generated_for":"2026-07-14","ranked":[{"id":"normal","project":"repo","title":"normal","score":0.99,"reasons":"ranked first","eligible_auto_spec":true,"auto_spec":null,"delivered_on_main":false,"existing_spec_path":"","auto_spec_exclusions":[]},{"id":"exempt","project":"repo","title":"exempt","score":0.98,"reasons":"explicit exemption","eligible_auto_spec":false,"auto_spec":false,"delivered_on_main":false,"existing_spec_path":"","auto_spec_exclusions":["auto-spec-exempt"]},{"id":"delivered","project":"repo","title":"delivered","score":0.97,"reasons":"already done","eligible_auto_spec":false,"auto_spec":true,"delivered_on_main":true,"existing_spec_path":"","auto_spec_exclusions":["delivered-on-main"]},{"id":"existing","project":"repo","title":"existing","score":0.96,"reasons":"already specced","eligible_auto_spec":false,"auto_spec":null,"delivered_on_main":false,"existing_spec_path":"specs/123-existing","auto_spec_exclusions":["existing-spec:specs/123-existing"]},{"id":"forced","project":"repo","title":"forced","score":0.1,"reasons":"operator force","eligible_auto_spec":true,"auto_spec":true,"delivered_on_main":false,"existing_spec_path":"","auto_spec_exclusions":[]},{"id":"forced","project":"repo","title":"forced duplicate","score":0.05,"reasons":"duplicate row","eligible_auto_spec":true,"auto_spec":true,"delivered_on_main":false,"existing_spec_path":"","auto_spec_exclusions":[]}]}}}'
  _json_assert "!r.error && (() => { const rank = r.prompts.find((entry) => entry.opts.label === 'rank'); const specs = r.prompts.filter((entry) => (entry.opts.label || '').startsWith('spec:')); return rank.prompt.includes('WEIGHTS_OVERRIDE_JSON: {\"deadline\":0.7,\"impact\":0.3}') && rank.prompt.includes('delivered-on-main') && rank.prompt.includes('existing-spec:<path>') && specs.map((entry) => entry.opts.label).join(',') === 'spec:forced,spec:normal' && !specs.some((entry) => /exempt|delivered|existing/.test(entry.opts.label)) && r.logs.some((line) => line.includes('forced=2') && line.includes('exempt=1') && line.includes('hard-excluded=2') && line.includes('duplicate=1')); })()"
}

@test "M12 fleet workflow accepts only xhigh and max" {
  [ -f "$FLEET_RECIPE" ] || skip "private fleet workflow is not shipped in the public mirror"
  local effort
  for effort in medium high; do
    _run_recipe "$FLEET_RECIPE" "{\"codexAvailable\":true,\"repoLanes\":[{\"repo\":\"repo-alpha\",\"path\":\"/tmp/repo-alpha\",\"base\":\"main\",\"harness\":\"codex\",\"effort\":\"$effort\",\"rows\":[]}]}"
    _json_assert "r.error && r.error.message.includes('$effort') && r.error.message.includes('enum [xhigh, max]') && r.prompts.length === 0"
  done

  _run_recipe "$FLEET_RECIPE" '{"codexAvailable":true,"supportedEfforts":["xhigh"],"repoLanes":[{"repo":"repo-alpha","path":"/tmp/repo-alpha","base":"main","harness":"codex","effort":"xhigh","rows":[]}]}'
  _json_assert "!r.error && r.result && r.result.verdicts.length === 1"

  _run_recipe "$FLEET_RECIPE" '{"codexAvailable":true,"supportedEfforts":["max"],"repoLanes":[{"repo":"repo-alpha","path":"/tmp/repo-alpha","base":"main","harness":"codex","effort":"max","justification":"bounded exception","rows":[]}]}'
  _json_assert "!r.error && r.result && r.result.verdicts.length === 1 && r.result.verdicts[0].effort === 'max'"
}

@test "M13 schema and public example define positive codex_fanout concurrency" {
  run node - "$CONFIG_SCHEMA" "$CONFIG_EXAMPLE" <<'NODE'
const fs = require('node:fs')
const schema = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const example = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))
const block = schema.properties?.codex_fanout
const concurrency = block?.properties?.concurrency
if (!block || block.type !== 'object' || block.additionalProperties !== false) process.exit(1)
if (!block.required?.includes('concurrency')) process.exit(2)
if (concurrency?.type !== 'integer' || concurrency.minimum !== 1) process.exit(3)
if (example.codex_fanout?.concurrency !== 4) process.exit(4)
NODE
  [ "$status" -eq 0 ]
}
