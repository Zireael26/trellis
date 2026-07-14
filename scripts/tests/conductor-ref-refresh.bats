#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
RECIPE="$REPO/core-rules/skills/orchestrate/recipes/conductor.wf.js"
SHA="2222222222222222222222222222222222222222"

run_recipe() {
  run node "$STUB" "$RECIPE" "$1"
  [ "$status" -eq 0 ]
}

json_assert() {
  CAPTURED_JSON="$output" node -e 'const r=JSON.parse(process.env.CAPTURED_JSON); if (!('"$1"')) { console.error(JSON.stringify(r,null,2)); process.exit(1) }'
}

@test "incomplete ref refresh aborts before ranking" {
  run_recipe '{"today":"2026-07-14","__agentOutputByLabel":{"refresh-refs":{"complete":false,"refs":[],"notes":"fetch timed out"}}}'
  json_assert "r.error && /ref refresh incomplete/.test(r.error.message) && r.prompts.map((p) => p.opts.label).join(',') === 'refresh-refs'"
}

@test "ranking and spec creation bind to the immutable refreshed main SHA" {
  local args
  args="$(jq -nc --arg sha "$SHA" '{today:"2026-07-14",backlogPath:"backlog.yml",registryPath:"registry.md",__agentOutputByLabel:{"refresh-refs":{complete:true,refs:[{project:"repo",repo_path:"/tmp/repo",main_sha:$sha}],notes:"ok"},rank:{generated_for:"2026-07-14",ranked:[{id:"alpha",project:"repo",title:"alpha",score:1,reasons:"top",eligible_auto_spec:true,auto_spec:null,delivered_on_main:false,existing_spec_path:"",auto_spec_exclusions:[]}]}}}')"
  run_recipe "$args"
  json_assert "!r.error && (() => { const rank=r.prompts.find((p)=>p.opts.label==='rank'); const spec=r.prompts.find((p)=>p.opts.label==='spec:alpha'); return rank.prompt.includes(process.env.SHA || '$SHA') && rank.prompt.includes('Never read mutable origin/main') && spec.prompt.includes('git worktree add <tmp> -b feature/alpha $SHA') && !spec.prompt.includes('git fetch origin'); })()"
}
