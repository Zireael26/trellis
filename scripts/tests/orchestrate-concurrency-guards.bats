#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
EXECUTOR="$REPO/core-rules/skills/orchestrate/recipes/codex-executor.wf.js"
FANOUT="$REPO/core-rules/skills/orchestrate/recipes/codex-fanout.wf.js"

run_recipe() {
  run node "$STUB" "$1" "$2"
  [ "$status" -eq 0 ]
}

json_assert() {
  CAPTURED_JSON="$output" node -e 'const r=JSON.parse(process.env.CAPTURED_JSON); if (!('"$1"')) { console.error(JSON.stringify(r,null,2)); process.exit(1) }'
}

@test "executor rejects lexically equivalent target worktrees before dispatch" {
  run_recipe "$EXECUTOR" '{"codexAvailable":false,"units":[{"name":"alpha","kind":"execute","task":"a","effort":"xhigh","targetCwd":"/tmp/shared"},{"name":"beta","kind":"execute","task":"b","effort":"xhigh","targetCwd":"/tmp/work/../shared/"}]}'
  json_assert "r.error && /share normalized targetCwd/.test(r.error.message) && /alpha/.test(r.error.message) && /beta/.test(r.error.message) && r.prompts.length === 0"
}

@test "fanout rejects duplicate target worktrees inside one actual wave" {
  run_recipe "$FANOUT" '{"codexAvailable":false,"codexCap":2,"units":[{"name":"alpha","leg":"claude","task":"a","paths":"a","proofCmd":"true","targetCwd":"/tmp/shared"},{"name":"beta","leg":"claude","task":"b","paths":"b","proofCmd":"true","targetCwd":"/tmp/work/../shared/"}]}'
  json_assert "r.error && /share normalized targetCwd/.test(r.error.message) && /concurrent wave 1/.test(r.error.message) && r.prompts.length === 0"
}

@test "fanout allows one target worktree across dependency-serialized waves" {
  run_recipe "$FANOUT" '{"codexAvailable":false,"codexCap":2,"units":[{"name":"alpha","leg":"claude","task":"a","paths":"a","proofCmd":"true","targetCwd":"/tmp/shared"},{"name":"beta","leg":"claude","task":"b","paths":"b","proofCmd":"true","targetCwd":"/tmp/work/../shared/","dependsOn":["alpha"]}]}'
  json_assert "!r.error && r.result && r.result.receipts.map((row) => row.name).join(',') === 'alpha,beta'"
}
