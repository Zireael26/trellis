#!/usr/bin/env node
'use strict';

const assert = require('assert');
const {
  POLICY_VERSION,
  MODES,
  ADVISOR_INPUTS,
  DELEGATE_INPUTS,
  MODE_DEFAULTS,
  DEFAULT_AGENT_MODEL_ALIASES,
  AGENT_TYPE_PROVIDERS,
  resolveAgentModelAlias,
  classifyModel,
  classifyAgentRequest,
  evaluateDelegation,
  resolveLaunch,
} = require('../gptx/session-policy');

assert.strictEqual(POLICY_VERSION, 2);
assert.deepStrictEqual(MODES, ['gptx', 'codex', 'hybrid', 'claude']);
assert.deepStrictEqual(ADVISOR_INPUTS, ['auto', 'opus', 'fable', 'sol', 'none']);
assert.deepStrictEqual(DELEGATE_INPUTS, ['auto', 'gpt', 'claude', 'none']);
assert.deepStrictEqual(DEFAULT_AGENT_MODEL_ALIASES, {
  opus: 'opus', sonnet: 'sonnet', haiku: 'haiku', fable: 'fable',
});
assert.strictEqual(AGENT_TYPE_PROVIDERS['gpt-terra'], 'gpt');
assert.strictEqual(AGENT_TYPE_PROVIDERS['gpt-luna'], 'gpt');
assert.strictEqual(AGENT_TYPE_PROVIDERS['opus-advisor'], 'claude');
assert.strictEqual(AGENT_TYPE_PROVIDERS['lane-worker'], 'claude');
assert.strictEqual(AGENT_TYPE_PROVIDERS['code-reviewer'], 'claude');

for (const mode of MODES) {
  const resolved = resolveLaunch({ mode });
  assert.strictEqual(resolved.valid, true, resolved.error);
  assert.strictEqual(resolved.effective.advisor, MODE_DEFAULTS[mode].advisor);
  assert.strictEqual(resolved.effective.advisor_source, 'mode-default');
  assert.strictEqual(resolved.effective.delegates, 'auto');
  assert.strictEqual(resolved.effective.delegates_source, 'default');

  const explicitAuto = resolveLaunch({ mode, advisor: 'auto', delegates: 'auto' });
  assert.strictEqual(explicitAuto.valid, true, explicitAuto.error);
  assert.strictEqual(explicitAuto.effective.advisor, 'auto');
  assert.strictEqual(explicitAuto.effective.advisor_source, 'explicit');
  assert.strictEqual(explicitAuto.effective.delegates, 'auto');
  assert.strictEqual(explicitAuto.effective.delegates_source, 'explicit');

  for (const delegates of DELEGATE_INPUTS) {
    const withDelegates = resolveLaunch({ mode, delegates });
    assert.strictEqual(withDelegates.valid, true, withDelegates.error);
    assert.strictEqual(withDelegates.effective.main_model, resolved.effective.main_model);
    assert.strictEqual(withDelegates.effective.advisor, resolved.effective.advisor);
    assert.strictEqual(withDelegates.effective.delegates, delegates);
  }
}

assert.match(resolveLaunch({ mode: 'nope' }).error, /unknown mode/);
assert.match(resolveLaunch({ advisor: 'nope' }).error, /unknown advisor/);
assert.match(resolveLaunch({ delegates: 'nope' }).error, /unknown delegates policy/);
assert.match(resolveLaunch({ mode: 'gptx', model: 'mystery' }).error, /unknown model/);
assert.match(resolveLaunch({ mode: 'codex', model: 'opus' }).error, /requires a GPT\/Codex/);
assert.match(resolveLaunch({ mode: 'claude', model: 'terra' }).error, /requires a Claude/);
// Terra's per-unit advice-before-mutation gate was retired 2026-07-30 for DELEGATED
// units, where the orchestrator's review of the finished diff stands in for pre-hoc
// advice. Cross-model review then showed the retirement had been applied one step too
// far: with Terra as the MAIN model there is no orchestrator above it, so a session
// could resolve valid while being unadvised, self-reviewing, and — with delegates
// none — structurally unable to spawn any reviewer at all.
//
// A Terra main loop must therefore be able to REACH a Claude-family oracle. This is
// stricter than the gate it replaces, which accepted `advisor: 'sol'` — GPT reviewing
// GPT, forbidden outright by model-routing.md stage 1 rule 2.
{
  // Rejected: no cross-family oracle reachable by either route.
  for (const advisor of ['none', 'sol']) {
    for (const delegates of ['none', 'gpt']) {
      const blocked = resolveLaunch({ mode: 'codex', model: 'terra', advisor, delegates });
      assert.strictEqual(blocked.valid, false, `terra/${advisor}/${delegates} should reject`);
      assert.match(blocked.error, /cross-family oracle/);
      assert.strictEqual(blocked.effective, null);
    }
  }
  // `advisor: 'sol'` must be named as insufficient, not silently lumped in with none.
  assert.match(
    resolveLaunch({ mode: 'codex', model: 'terra', advisor: 'sol', delegates: 'none' }).error,
    /GPT reviewing GPT is not independent review/,
  );

  // Permitted via a Claude-family advisor.
  for (const advisor of ['auto', 'opus', 'fable']) {
    const ok = resolveLaunch({ mode: 'codex', model: 'terra', advisor, delegates: 'none' });
    assert.strictEqual(ok.valid, true, ok.error);
    assert.strictEqual(ok.effective.terra_advisor_recommended, true);
    assert.deepStrictEqual(ok.effective.notices, []);
  }

  // Permitted via a spawnable Claude reviewer, even with no advisor — but the notice
  // must say the reviewer is available rather than automatic, because nothing forces
  // the operator to actually spawn it.
  for (const delegates of ['claude', 'auto']) {
    const ok = resolveLaunch({ mode: 'codex', model: 'terra', advisor: 'none', delegates });
    assert.strictEqual(ok.valid, true, ok.error);
    assert.strictEqual(ok.effective.terra_advisor_recommended, true);
    assert.match(ok.effective.notices[0], /not automatic/);
    assert.match(ok.effective.notices[0], /irreversible side effect/);
  }

  // A GPT main model that is not Terra is untouched by this gate.
  const solUnadvised = resolveLaunch({ mode: 'codex', advisor: 'none', delegates: 'none' });
  assert.strictEqual(solUnadvised.valid, true, solUnadvised.error);
  assert.strictEqual(solUnadvised.effective.main_model, 'gpt-5.6-sol');
}

{
  // Luna remains a valid main model, but warns because the orchestrator accumulates the
  // session's largest context surface. Advisor and delegate state do not change that risk.
  for (const advisor of ADVISOR_INPUTS) {
    for (const delegates of DELEGATE_INPUTS) {
      const lunaMain = resolveLaunch({ mode: 'codex', model: 'luna', advisor, delegates });
      assert.strictEqual(lunaMain.valid, true, lunaMain.error);
      assert.strictEqual(lunaMain.effective.notices.length, 1);
      assert.match(lunaMain.effective.notices[0], /largest context surface/);
      assert.match(lunaMain.effective.notices[0], /MRCR long-context recall degrades sharply/);
      assert.match(lunaMain.effective.notices[0], /bounded delegated units/);
    }
  }

  // With the same advisor state, a non-Luna main loop has no Luna notice even when the
  // policy permits Luna as a delegated GPT agent. The distinction is the orchestrator seat.
  const delegatedLuna = classifyAgentRequest({ subagent_type: 'gpt-luna' });
  for (const advisor of ADVISOR_INPUTS) {
    for (const delegates of ['auto', 'gpt']) {
      const delegatedLunaSession = resolveLaunch({
        mode: 'codex', model: 'sol', advisor, delegates,
      });
      assert.strictEqual(delegatedLunaSession.valid, true, delegatedLunaSession.error);
      assert.deepStrictEqual(delegatedLunaSession.effective.notices, []);
      assert.strictEqual(evaluateDelegation(delegates, delegatedLuna).allowed, true);
    }
  }
}

assert.deepStrictEqual(classifyModel(' claude-opus-5 '), {
  provider: 'claude', family: 'claude', model: 'claude-opus-5',
});
assert.strictEqual(classifyModel('gpt-5.6-sol').provider, 'gpt');
for (const alias of [
  'gpt-5.6-sol-medium',
  'gpt-5.6-sol-high',
  'gpt-5.6-sol-xhigh',
]) {
  assert.deepStrictEqual(classifyModel(alias), {
    provider: 'gpt', family: 'sol', model: alias,
  });
}
assert.strictEqual(classifyModel('gpt-5.6-terra').family, 'terra');
assert.strictEqual(classifyModel('gpt-5.6-luna').family, 'luna');
assert.strictEqual(classifyModel('unknown').provider, 'unknown');

const codexAliases = {
  ...DEFAULT_AGENT_MODEL_ALIASES,
  opus: 'gpt-5.6-sol',
};
assert.deepStrictEqual(resolveAgentModelAlias('opus', codexAliases), {
  requested: 'opus',
  resolved: 'gpt-5.6-sol',
  source: 'effective-opus-alias',
  slot: 'opus',
});
assert.deepStrictEqual(resolveAgentModelAlias('opus[1m]', codexAliases), {
  requested: 'opus[1m]',
  resolved: 'gpt-5.6-sol',
  source: 'effective-opus-alias',
  slot: 'opus',
});
assert.deepStrictEqual(resolveAgentModelAlias('claude-opus-5', codexAliases), {
  requested: 'claude-opus-5',
  resolved: 'claude-opus-5',
  source: 'literal-model',
  slot: null,
});

assert.deepStrictEqual(classifyAgentRequest({ subagent_type: 'gpt-mid' }), {
  provider: 'gpt', source: 'agent-type', value: 'gpt-mid', family: null,
  requested_model: null, resolved_model: null, resolution_source: 'agent-type',
});
assert.deepStrictEqual(classifyAgentRequest({ model: 'inherit', subagent_type: 'Explore' }), {
  provider: 'claude', source: 'agent-type', value: 'Explore', family: null,
  requested_model: null, resolved_model: null, resolution_source: 'agent-type',
});
assert.deepStrictEqual(classifyAgentRequest(
  { model: 'opus', subagent_type: 'Explore' },
  codexAliases,
), {
  provider: 'gpt', source: 'explicit-model', value: 'opus', family: 'sol',
  requested_model: 'opus', resolved_model: 'gpt-5.6-sol',
  resolution_source: 'effective-opus-alias',
});
assert.deepStrictEqual(classifyAgentRequest(
  { model: 'claude-opus-5', subagent_type: 'gpt-mid' },
  codexAliases,
), {
  provider: 'claude', source: 'explicit-model', value: 'claude-opus-5', family: 'claude',
  requested_model: 'claude-opus-5', resolved_model: 'claude-opus-5',
  resolution_source: 'literal-model',
});
assert.deepStrictEqual(classifyAgentRequest({ model: 'sonnet', subagent_type: 'gpt-mid' }), {
  provider: 'claude', source: 'explicit-model', value: 'sonnet', family: 'claude',
  requested_model: 'sonnet', resolved_model: 'sonnet',
  resolution_source: 'claude-slot-default',
});
assert.deepStrictEqual(classifyAgentRequest({ model: 'sol', subagent_type: 'claude' }), {
  provider: 'gpt', source: 'explicit-model', value: 'sol', family: 'sol',
  requested_model: 'sol', resolved_model: 'gpt-5.6-sol',
  resolution_source: 'trellis-model-alias',
});
assert.deepStrictEqual(classifyAgentRequest({ model: 'unknown', subagent_type: 'gpt-mid' }), {
  provider: 'unknown', source: 'explicit-model', value: 'unknown', family: 'unknown',
  requested_model: 'unknown', resolved_model: 'unknown',
  resolution_source: 'literal-model',
});
assert.strictEqual(classifyAgentRequest({ subagent_type: 'new-plugin-agent' }).source, 'unknown');

const providers = ['gpt', 'claude', 'unknown'];
for (const delegates of DELEGATE_INPUTS) {
  for (const provider of providers) {
    const result = evaluateDelegation(delegates, { provider });
    const expected = delegates === 'auto' || delegates === provider;
    assert.strictEqual(result.allowed, expected, `${delegates} with ${provider}`);
  }
}
assert.strictEqual(evaluateDelegation('invalid', { provider: 'gpt' }).allowed, false);

// Delegate policy is orthogonal to the Terra main-loop oracle gate, so this sweep pairs
// Terra with a Claude-family advisor: that keeps the oracle reachable for every value of
// `delegates` and leaves delegation itself as the only variable under test. Pairing it
// with `advisor: 'sol'` here would conflate the two and reject at delegates none/gpt.
for (const delegates of DELEGATE_INPUTS) {
  const terra = resolveLaunch({ mode: 'hybrid', model: 'terra', advisor: 'opus', delegates });
  assert.strictEqual(terra.valid, true, terra.error);
  assert.strictEqual(terra.effective.terra_advisor_recommended, true);
  assert.deepStrictEqual(terra.effective.notices, []);
  assert.strictEqual(terra.effective.delegates, delegates);
  const spawn = evaluateDelegation(delegates, classifyAgentRequest({ subagent_type: 'gpt-terra' }));
  assert.strictEqual(spawn.allowed, ['auto', 'gpt'].includes(delegates));
}

console.log('gptx-session-policy: ok');
