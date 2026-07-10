#!/usr/bin/env bats
# SC3/SC4 executable contract matrix for the three real spec-011 recipes.
# Recipe code is always loaded by path through fixtures/wf-stub.mjs; no recipe
# implementation is copied into this suite.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
STUB="$BATS_TEST_DIRNAME/fixtures/wf-stub.mjs"
CODEX_RECIPE="$REPO/core-rules/skills/orchestrate/recipes/codex-executor.wf.js"
PANEL_RECIPE="$REPO/core-rules/skills/orchestrate/recipes/verify-panel.wf.js"
FLEET_RECIPE="$REPO/scripts/workflows/fleet-audit-remediation.wf.js"
RECIPES=("$CODEX_RECIPE" "$PANEL_RECIPE" "$FLEET_RECIPE")
HONEST="Report failures as failures. Never claim completion without the proof command's actual output. A claimed-complete unit without receipts is treated as failed."

_args_for() {
  local recipe="$1" matrix_case="$2"
  local effort="high" justification="bounded test justification"

  case "$matrix_case" in
    omitted) effort="__OMITTED__" ;;
    turbo) effort="turbo" ;;
    max-no-justification) effort="max"; justification="" ;;
    ultra) effort="ultra" ;;
    unsupported) effort="max" ;;
    happy|sc4) effort="high" ;;
  esac

  case "$(basename "$recipe")" in
    codex-executor.wf.js)
      if [ "$effort" = "__OMITTED__" ]; then
        printf '%s' '{"codexAvailable":true,"units":[{"name":"unit-alpha","kind":"execute","task":"apply bounded change"}]}'
      else
        printf '{"codexAvailable":true,"supportedEfforts":["medium","high","xhigh"],"units":[{"name":"unit-alpha","kind":"execute","task":"apply bounded change","effort":"%s","justification":"%s","paths":"src/alpha.js","constraints":"touch one file","nonGoals":"unrelated cleanup","proof":"node --check src/alpha.js"}]}' "$effort" "$justification"
      fi
      ;;
    verify-panel.wf.js)
      if [ "$effort" = "__OMITTED__" ]; then
        printf '%s' '{"codexAvailable":true,"findings":[{"id":"finding-alpha","claim":"bounded claim","file":"src/alpha.js","line":1,"severity":"high"}],"context":"fixture context"}'
      else
        printf '{"codexAvailable":true,"supportedEfforts":["medium","high","xhigh"],"effort":"%s","justification":"%s","findings":[{"id":"finding-alpha","claim":"bounded claim","file":"src/alpha.js","line":1,"severity":"high"}],"context":"fixture context"}' "$effort" "$justification"
      fi
      ;;
    fleet-audit-remediation.wf.js)
      if [ "$effort" = "__OMITTED__" ]; then
        printf '%s' '{"codexAvailable":true,"repoLanes":[{"repo":"repo-alpha","path":"/tmp/repo-alpha","base":"main","harness":"codex","rows":[{"id":"row-alpha","lane":"mechanical","tier":"patch","fix":"apply bounded fix","verifyCmd":"node --check src/alpha.js","autoMergeable":true,"kind":"fix"}]}]}'
      else
        printf '{"codexAvailable":true,"supportedEfforts":["medium","high","xhigh"],"repoLanes":[{"repo":"repo-alpha","path":"/tmp/repo-alpha","base":"main","harness":"codex","effort":"%s","justification":"%s","rows":[{"id":"row-alpha","lane":"mechanical","tier":"patch","fix":"apply bounded fix","verifyCmd":"node --check src/alpha.js","autoMergeable":true,"kind":"fix"}]}]}' "$effort" "$justification"
      fi
      ;;
  esac
}

_run_recipe() {
  local recipe="$1" matrix_case="$2"
  run node "$STUB" "$recipe" "$(_args_for "$recipe" "$matrix_case")"
  [ "$status" -eq 0 ]
}

_json_assert() {
  local expression="$1"
  CAPTURED_JSON="$output" HONEST="$HONEST" node -e "const r = JSON.parse(process.env.CAPTURED_JSON); if (!($expression)) { console.error(JSON.stringify(r, null, 2)); process.exit(1) }"
}

@test "SC3(a): omitted effort throws before dispatch for every recipe" {
  local recipe identity
  for recipe in "${RECIPES[@]}"; do
    _run_recipe "$recipe" omitted
    case "$(basename "$recipe")" in
      codex-executor.wf.js) identity="unit-alpha" ;;
      verify-panel.wf.js) identity="verify-panel" ;;
      fleet-audit-remediation.wf.js) identity="repo-alpha" ;;
    esac
    _json_assert "r.error && r.error.message.includes('$identity') && r.error.message.includes('effort') && r.error.message.includes('no default') && r.prompts.length === 0"
  done
}

@test "SC3(b): turbo and max without justification throw for every recipe" {
  local recipe matrix_case
  for recipe in "${RECIPES[@]}"; do
    for matrix_case in turbo max-no-justification; do
      _run_recipe "$recipe" "$matrix_case"
      if [ "$matrix_case" = turbo ]; then
        _json_assert "r.error && r.error.message.includes('turbo') && r.error.message.includes('enum') && r.prompts.length === 0"
      else
        _json_assert "r.error && r.error.message.includes('max') && r.error.message.includes('justification') && r.prompts.length === 0"
      fi
    done
  done
}

@test "SC3(c): ultra hard-rejects with a D4a log for every recipe" {
  local recipe
  for recipe in "${RECIPES[@]}"; do
    _run_recipe "$recipe" ultra
    _json_assert "r.error && /ultra/i.test(r.error.message) && /D4a/i.test(r.error.message) && r.logs.some((line) => /ultra/i.test(line) && /D4a/i.test(line)) && r.prompts.length === 0"
  done
}

@test "SC3(d): unsupported max fails closed to Claude without clamping for every recipe" {
  local recipe
  for recipe in "${RECIPES[@]}"; do
    _run_recipe "$recipe" unsupported
    _json_assert "!r.error && r.logs.some((line) => /FAIL-CLOSED/i.test(line) && /max/i.test(line) && /no clamp/i.test(line)) && r.prompts.some((entry) => /claude/i.test(entry.opts.label || '')) && !r.prompts.some((entry) => /codex/i.test(entry.opts.label || '') && entry.opts.label !== 'codex-presence') && !r.prompts.some((entry) => entry.prompt.includes('--effort xhigh'))"
  done
}

@test "SC3(e): happy-path receipts echo effort and justification for every recipe" {
  local recipe
  for recipe in "${RECIPES[@]}"; do
    _run_recipe "$recipe" happy
    _json_assert "!r.error && r.result && r.result.verdicts.length === 1 && r.result.verdicts[0].effort === 'high' && r.result.verdicts[0].justification === 'bounded test justification'"
  done
}

@test "SC4: executor prompts carry the six fields and honest clause; panel carries declared tier" {
  local recipe
  for recipe in "$CODEX_RECIPE" "$FLEET_RECIPE"; do
    _run_recipe "$recipe" sc4
    _json_assert "!r.error && r.prompts.some((entry) => /codex/i.test(entry.opts.label || '') && ['GOAL:', 'REPO/PATHS:', 'CONSTRAINTS:', 'NON-GOALS:', 'PROOF:', 'OUTPUT:'].every((label) => entry.prompt.includes(label)) && entry.prompt.includes(process.env.HONEST))"
  done

  _run_recipe "$PANEL_RECIPE" sc4
  _json_assert "!r.error && r.prompts.some((entry) => /codex-verify/.test(entry.opts.label || '') && entry.prompt.includes('--effort high'))"
}
