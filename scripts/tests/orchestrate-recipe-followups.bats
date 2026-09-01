#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
DRIFT_RECIPE="$REPO/core-rules/skills/orchestrate/recipes/drift-holdpr.wf.js"
CONDUCTOR_RECIPE="$REPO/core-rules/skills/orchestrate/recipes/conductor.wf.js"
FLEET_RECIPE="$REPO/scripts/workflows/fleet-audit-remediation.wf.js"
CONFIG_SCHEMA="$REPO/scripts/lib/trellis.config.schema.json"
CONFIG_EXAMPLE="$REPO/core-rules/templates/trellis.config.json.example"
CONFIG="$REPO/trellis.config.json"

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
  _run_recipe "$CONDUCTOR_RECIPE" '{"today":"2026-07-14","backlogPath":"/private/tasks/personal/conductor/backlog.json","registryPath":"/private/tasks/personal/conductor/snapshot.json","autoSpecTopN":3,"weights":{"deadline":0.7,"impact":0.3,"unblock":0,"effort":0,"staleness":0},"__agentOutputByLabel":{"rank":{"generated_for":"2026-07-14","ranked":[{"id":"normal","project":"repo","title":"normal","score":0.99,"reasons":"ranked first","eligible_auto_spec":true,"auto_spec":null,"delivered_on_main":false,"existing_spec_path":"","auto_spec_exclusions":[]},{"id":"exempt","project":"repo","title":"exempt","score":0.98,"reasons":"explicit exemption","eligible_auto_spec":false,"auto_spec":false,"delivered_on_main":false,"existing_spec_path":"","auto_spec_exclusions":["auto-spec-exempt"]},{"id":"delivered","project":"repo","title":"delivered","score":0.97,"reasons":"already done","eligible_auto_spec":false,"auto_spec":true,"delivered_on_main":true,"existing_spec_path":"","auto_spec_exclusions":["delivered-on-main"]},{"id":"existing","project":"repo","title":"existing","score":0.96,"reasons":"already specced","eligible_auto_spec":false,"auto_spec":null,"delivered_on_main":false,"existing_spec_path":"specs/123-existing","auto_spec_exclusions":["existing-spec:specs/123-existing"]},{"id":"forced","project":"repo","title":"forced","score":0.1,"reasons":"operator force","eligible_auto_spec":true,"auto_spec":true,"delivered_on_main":false,"existing_spec_path":"","auto_spec_exclusions":[]}]}}}'
  _json_assert "!r.error && (() => { const rank = r.prompts.find((entry) => entry.opts.label === 'rank'); const specs = r.prompts.filter((entry) => (entry.opts.label || '').startsWith('spec:')); return rank.prompt.includes('WEIGHTS_OVERRIDE_JSON: {\"deadline\":0.7,\"impact\":0.3,\"unblock\":0,\"effort\":0,\"staleness\":0}') && rank.prompt.includes('delivered-on-main') && rank.prompt.includes('existing-spec:<path>') && specs.map((entry) => entry.opts.label).join(',') === 'spec:forced,spec:normal' && !specs.some((entry) => /exempt|delivered|existing/.test(entry.opts.label)) && r.logs.some((line) => line.includes('forced=1') && line.includes('exempt=1') && line.includes('hard-excluded=2') && line.includes('duplicate=0')); })()"
}

@test "M12 fleet workflow uses the inherited orchestrator model for every stage" {
  [ -f "$FLEET_RECIPE" ] || skip "private fleet workflow is not shipped in the public mirror"
  _run_recipe "$FLEET_RECIPE" '{"repoLanes":[{"repo":"repo-alpha","path":"/tmp/repo-alpha","base":"main","rows":[]}]}'
  _json_assert "!r.error && r.result && r.result.verdicts.length === 1 && r.result.verdicts[0].repo === 'repo-alpha' && r.prompts.map((entry) => entry.opts.label).join(',') === 'impl:repo-alpha,verify:repo-alpha' && r.prompts.every((entry) => entry.opts.agent === undefined)"
}

@test "M13 schema and public example omit retired codex_fanout configuration" {
  run node - "$CONFIG_SCHEMA" "$CONFIG_EXAMPLE" <<'NODE'
const fs = require('node:fs')
const schema = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const example = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))
if (Object.prototype.hasOwnProperty.call(schema.properties ?? {}, 'codex_fanout')) process.exit(1)
if (Object.prototype.hasOwnProperty.call(example, 'codex_fanout')) process.exit(2)
if (Object.prototype.hasOwnProperty.call(example, 'comment_codex_fanout')) process.exit(3)
NODE
  [ "$status" -eq 0 ]
}

@test "Spec 005 conductor config defaults off and gates reviewed-ready execution to HOLD PR" {
  local args enabled held
  args="$(jq -nc '{
    today: "2026-08-23",
    backlogPath: "/private/tasks/personal/conductor/backlog.json",
    registryPath: "/private/tasks/personal/conductor/snapshot.json",
    autoSpecTopN: 1,
    __agentOutputByLabel: {
      "refresh-refs": {
        complete: true,
        refs: [{project: "repo", repo_path: "/tmp/repo", main_sha: "1111111111111111111111111111111111111111"}],
        notes: "ok"
      },
      rank: {
        generated_for: "2026-08-23",
        ranked: [{
          id: "alpha",
          project: "repo",
          title: "alpha",
          score: 1,
          reasons: "top",
          eligible_auto_spec: true,
          auto_spec: null,
          safe: null,
          surgical: false,
          status: "todo",
          delivered_on_main: false,
          existing_spec_path: "",
          auto_spec_exclusions: []
        }]
      },
      "spec:alpha": {
        id: "alpha",
        branch: "feature/alpha",
        spec_path: "specs/001-alpha/",
        ready: true,
        notes: "ready"
      }
    }
  }')"

  _run_recipe "$CONDUCTOR_RECIPE" "$args"
  _json_assert "!r.error && r.result.reviews.length === 0 && r.result.executions.length === 0 && !r.prompts.some((entry) => /^review:|^execute:/.test(entry.opts.label || ''))"

  enabled="$(printf '%s\n' "$args" | jq -c '
    .autoExecuteTopN = 1
    | .authorAgent = "sol"
    | .reviewerAgent = "grok"
    | .__agentOutputByLabel["review:alpha"] = {id:"alpha", reviewed:true, ready:true, notes:"approved"}
    | .__agentOutputByLabel["execute:alpha"] = {
        id:"alpha",
        branch:"feature/alpha",
        pr_url:"https://github.com/example/repo/pull/7",
        gate_green:true,
        notes:"green"
      }
  ')"
  _run_recipe "$CONDUCTOR_RECIPE" "$enabled"
  _json_assert "!r.error && (() => { const spec = r.prompts.find((entry) => entry.opts.label === 'spec:alpha'); const review = r.prompts.find((entry) => entry.opts.label === 'review:alpha'); const execute = r.prompts.find((entry) => entry.opts.label === 'execute:alpha'); return r.result.reviews.length === 1 && r.result.executions.length === 1 && r.result.executions[0].pr_url.endsWith('/pull/7') && spec.opts.agentType === 'sol' && review.opts.agentType === 'grok' && execute.opts.agentType === 'sol' && review.prompt.includes('independent CONDUCTOR spec reviewer') && execute.prompt.includes('Run the Trellis execute pipeline') && execute.prompt.includes('[HOLD]') && execute.prompt.includes('Never merge') && execute.prompt.includes('normal permission mode') && execute.prompt.includes('Do not request or enable a scheduler-wide permission bypass') && !r.prompts.some((entry) => 'agent' in entry.opts || 'permissionMode' in entry.opts || 'permission_mode' in entry.opts); })()"

  held="$(printf '%s\n' "$enabled" | jq -c '.__agentOutputByLabel.rank.ranked[0].safe = "manual"')"
  _run_recipe "$CONDUCTOR_RECIPE" "$held"
  _json_assert "!r.error && r.result.reviews.length === 0 && r.result.executions.length === 0 && !r.prompts.some((entry) => (entry.opts.label || '').startsWith('execute:'))"
}

@test "shared config materializes Spec 005 and Spec 016 knobs with fleet-only report tuning" {
  run node - "$CONFIG_SCHEMA" "$CONFIG" "$CONFIG_EXAMPLE" <<'NODE'
const fs = require('node:fs')
const schema = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const fleet = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))
const template = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'))
const conductor = schema.properties?.conductor?.properties?.auto_execute_top_n
if (conductor?.type !== 'integer' || conductor?.minimum !== 0) process.exit(1)
if (fleet.conductor?.auto_execute_top_n !== 0 || template.conductor?.auto_execute_top_n !== 0) process.exit(2)
const lifecycleKeys = ['reap_pushed_worktrees', 'ephemeral_tmp_ttl_days', 'worktree_count_ceiling', 'worktree_total_gb_ceiling']
if (!lifecycleKeys.every((key) => Object.prototype.hasOwnProperty.call(fleet.disk_janitor ?? {}, key))) process.exit(3)
if (!lifecycleKeys.every((key) => Object.prototype.hasOwnProperty.call(template.disk_janitor ?? {}, key))) process.exit(4)
if (fleet.disk_janitor.worktree_count_ceiling !== 50 || fleet.disk_janitor.worktree_total_gb_ceiling !== 100) process.exit(5)
if (template.disk_janitor.worktree_count_ceiling !== 25 || template.disk_janitor.worktree_total_gb_ceiling !== 80) process.exit(6)
NODE
  [ "$status" -eq 0 ]
}
