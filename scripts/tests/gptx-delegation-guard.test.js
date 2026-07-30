#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { POLICY_VERSION } = require('../gptx/session-policy');
const { evaluateAgentCall, modelAliasesFromEnv } = require('../gptx/delegation-guard');

const root = path.resolve(__dirname, '../..');
const guard = path.join(root, 'scripts/gptx/delegation-guard.js');
const launcher = path.join(root, 'scripts/cmux-trellis-teams');
const claudeAliases = {
  opus: 'claude-opus-5',
  sonnet: 'claude-sonnet-5',
  haiku: 'claude-haiku-4-5-20251001',
  fable: 'claude-fable-5',
};
const claudeDefaults = {
  opus: claudeAliases.opus,
  sonnet: claudeAliases.sonnet,
  haiku: claudeAliases.haiku,
};
const policyEnv = (
  policy,
  version = String(POLICY_VERSION),
  aliases = claudeAliases,
  defaults = claudeDefaults,
) => ({
  TRELLIS_GPTX_DELEGATES: policy,
  TRELLIS_GPTX_POLICY_VERSION: version,
  TRELLIS_GPTX_MODEL_ALIASES: JSON.stringify(aliases),
  ANTHROPIC_DEFAULT_OPUS_MODEL: defaults.opus ?? '',
  ANTHROPIC_DEFAULT_SONNET_MODEL: defaults.sonnet ?? '',
  ANTHROPIC_DEFAULT_HAIKU_MODEL: defaults.haiku ?? '',
});
const codexAliases = { ...claudeAliases, opus: 'gpt-5.6-sol' };
const codexEnv = (policy) => policyEnv(policy, undefined, codexAliases, {
  ...claudeDefaults,
  opus: 'gpt-5.6-sol',
});
const runGuard = (input, env) => spawnSync(process.execPath, [guard], {
  input: JSON.stringify(input),
  encoding: 'utf8',
  env: { ...process.env, ...env },
});
const agent = (toolInput) => ({ tool_name: 'Agent', tool_input: toolInput });

for (const [policy, provider, allowed] of [
  ['auto', 'gpt-mid', true],
  ['auto', 'Explore', true],
  ['auto', 'unknown-plugin', true],
  ['gpt', 'gpt-mid', true],
  ['gpt', 'Explore', false],
  ['gpt', 'unknown-plugin', false],
  ['claude', 'gpt-mid', false],
  ['claude', 'Explore', true],
  ['claude', 'unknown-plugin', false],
  ['none', 'gpt-mid', false],
  ['none', 'Explore', false],
  ['none', 'unknown-plugin', false],
]) {
  const result = runGuard(agent({ subagent_type: provider }), policyEnv(policy));
  assert.strictEqual(result.status, 0, result.stderr);
  if (allowed) {
    assert.strictEqual(result.stdout, '', `${policy} should allow ${provider}`);
  } else {
    const payload = JSON.parse(result.stdout);
    assert.strictEqual(payload.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(payload.hookSpecificOutput.permissionDecisionReason, new RegExp(`policy '${policy}'`));
    assert.strictEqual(Object.hasOwn(payload.hookSpecificOutput, 'updatedInput'), false);
  }
}

let result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid', model: 'opus' }), codexEnv('gpt'));
assert.strictEqual(result.allowed, true);
assert.strictEqual(result.classification.provider, 'gpt');
assert.strictEqual(result.classification.requested_model, 'opus');
assert.strictEqual(result.classification.resolved_model, 'gpt-5.6-sol');
assert.strictEqual(result.receipt.effective_provider, 'gpt');
assert.strictEqual(result.receipt.policy_version, POLICY_VERSION);

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid', model: 'opus' }), codexEnv('claude'));
assert.strictEqual(result.allowed, false);
assert.strictEqual(result.classification.provider, 'gpt');
assert.match(result.reason, /Requested model 'opus' resolved to 'gpt-5\.6-sol'/);

result = evaluateAgentCall(
  agent({ subagent_type: 'gpt-mid', model: 'claude-opus-5' }),
  codexEnv('claude'),
);
assert.strictEqual(result.allowed, true);
assert.strictEqual(result.classification.provider, 'claude');
assert.strictEqual(result.classification.resolved_model, 'claude-opus-5');

result = evaluateAgentCall(
  agent({ subagent_type: 'gpt-mid', model: 'claude-opus-5' }),
  codexEnv('gpt'),
);
assert.strictEqual(result.allowed, false);
assert.strictEqual(result.classification.provider, 'claude');
assert.match(result.reason, /Remove the Agent model override/);

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid', model: 'sonnet' }), policyEnv('gpt'));
assert.strictEqual(result.allowed, false);
assert.strictEqual(result.classification.provider, 'claude');
assert.strictEqual(result.classification.source, 'explicit-model');

result = evaluateAgentCall(agent({ subagent_type: 'Explore', model: 'sol' }), policyEnv('gpt'));
assert.strictEqual(result.allowed, true);
assert.strictEqual(result.classification.provider, 'gpt');

result = evaluateAgentCall(
  agent({ subagent_type: 'Explore', model: 'gpt-5.6-sol-medium' }),
  policyEnv('gpt'),
);
assert.strictEqual(result.allowed, true);
assert.strictEqual(result.classification.provider, 'gpt');
assert.strictEqual(result.classification.family, 'sol');
assert.strictEqual(result.classification.resolved_model, 'gpt-5.6-sol-medium');

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid', model: 'unknown-model' }), policyEnv('gpt'));
assert.strictEqual(result.allowed, false);
assert.strictEqual(result.classification.provider, 'unknown');
assert.strictEqual(result.classification.source, 'explicit-model');

result = evaluateAgentCall({
  tool_name: 'Agent',
  session_id: 'nested-session',
  agent_depth: 2,
  tool_input: { subagent_type: 'gpt-mid', model: 'inherit' },
}, policyEnv('gpt'));
assert.strictEqual(result.allowed, true);
assert.strictEqual(result.classification.source, 'agent-type');

result = evaluateAgentCall(
  { tool_name: 'Bash', tool_input: { command: 'true' } },
  policyEnv('none'),
);
assert.deepStrictEqual(result, { allowed: true, passthrough: true });

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid' }), policyEnv('invalid'));
assert.strictEqual(result.allowed, false);
assert.match(result.reason, /Set TRELLIS_GPTX_DELEGATES/);

for (const agentType of ['lane-worker', 'code-reviewer']) {
  result = evaluateAgentCall(agent({ subagent_type: agentType }), policyEnv('claude'));
  assert.strictEqual(result.allowed, true, `${agentType} should classify as Claude`);
  assert.strictEqual(result.classification.provider, 'claude');
}

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid' }), {
  ...policyEnv('gpt'),
  TRELLIS_GPTX_POLICY_VERSION: '',
});
assert.strictEqual(result.allowed, false);
assert.match(result.reason, /session policy environment is missing/);

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid' }), policyEnv('gpt', '1'));
assert.strictEqual(result.allowed, false);
assert.match(result.reason, /requires policy version 2/);

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid' }), {
  ...policyEnv('gpt'),
  TRELLIS_GPTX_MODEL_ALIASES: '',
});
assert.strictEqual(result.allowed, false);
assert.match(result.reason, /model-alias policy is missing/);

result = evaluateAgentCall(agent({ subagent_type: 'gpt-mid' }), {
  ...codexEnv('gpt'),
  ANTHROPIC_DEFAULT_OPUS_MODEL: 'claude-opus-5',
});
assert.strictEqual(result.allowed, false);
assert.match(result.reason, /locked alias policy resolves 'gpt-5\.6-sol'/);

assert.strictEqual(modelAliasesFromEnv(policyEnv('auto')).valid, true);
assert.strictEqual(modelAliasesFromEnv(codexEnv('auto')).aliases.opus, 'gpt-5.6-sol');

for (const slot of Object.keys(claudeAliases)) {
  const incomplete = { ...claudeAliases };
  delete incomplete[slot];
  result = evaluateAgentCall(agent({ model: slot }), policyEnv('auto', undefined, incomplete));
  assert.strictEqual(result.allowed, false, `missing ${slot} alias should fail closed`);
  assert.match(result.reason, new RegExp(`missing:.*${slot}`));
}

for (const [slot, envKey] of [
  ['opus', 'ANTHROPIC_DEFAULT_OPUS_MODEL'],
  ['sonnet', 'ANTHROPIC_DEFAULT_SONNET_MODEL'],
  ['haiku', 'ANTHROPIC_DEFAULT_HAIKU_MODEL'],
]) {
  const mismatched = { ...policyEnv('auto'), [envKey]: `wrong-${slot}-model` };
  result = evaluateAgentCall(agent({ model: slot }), mismatched);
  assert.strictEqual(result.allowed, false, `${slot} environment mismatch should fail closed`);
  assert.match(result.reason, new RegExp(`${envKey} resolves 'wrong-${slot}-model'`));
}

result = evaluateAgentCall(agent({ model: 'fable' }), policyEnv(
  'auto',
  undefined,
  { ...claudeAliases, fable: 'gpt-5.6-sol' },
));
assert.strictEqual(result.allowed, false);
assert.match(result.reason, /locked alias 'fable' must resolve 'claude-fable-5'/);

result = evaluateAgentCall(agent({ model: 'opus' }), {
  ...policyEnv('auto'),
  TRELLIS_GPTX_MODEL_ALIASES: '{not-json',
});
assert.strictEqual(result.allowed, false);
assert.match(result.reason, /model-alias policy is invalid JSON/);

const temporaryBase = process.env.TRELLIS_TEST_TMPDIR || os.tmpdir();
const temporary = fs.mkdtempSync(path.join(temporaryBase, 'gptx-alias-attestation-'));
try {
  const fakeBin = path.join(temporary, 'bin');
  const codexHome = path.join(temporary, 'codex');
  const forbiddenLog = path.join(temporary, 'forbidden-service-command.log');
  fs.mkdirSync(fakeBin, { recursive: true });
  fs.mkdirSync(codexHome, { recursive: true });
  fs.copyFileSync(
    path.join(__dirname, 'fixtures/models-cache-272k.json'),
    path.join(codexHome, 'models_cache.json'),
  );

  const forbiddenCommand = [
    '#!/usr/bin/env bash',
    'printf "%s %s\\n" "$(basename "$0")" "$*" >> "${FORBIDDEN_COMMAND_LOG:?}"',
    'exit 97',
    '',
  ].join('\n');
  for (const name of ['launchctl', 'curl', 'brew', 'uname']) {
    const commandPath = path.join(fakeBin, name);
    fs.writeFileSync(commandPath, forbiddenCommand, { mode: 0o755 });
  }

  const launchContract = (mode, delegates, model = null) => {
    const launchArgs = ['--dry-run', '--mode', mode, '--delegates', delegates];
    if (model != null) launchArgs.push('--model', model);
    const launched = spawnSync(
      launcher,
      launchArgs,
      {
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${fakeBin}${path.delimiter}${process.env.PATH}`,
          CMUX_BIN: '/usr/bin/true',
          CODEX_HOME: codexHome,
          FORBIDDEN_COMMAND_LOG: forbiddenLog,
        },
      },
    );
    assert.strictEqual(launched.status, 0, `${mode}/${delegates}/${model ?? 'default'}: ${launched.stderr}`);
    return JSON.parse(launched.stdout);
  };

  const aliasRequests = [
    ['opus', 'opus'],
    ['opus[1m]', 'opus'],
    ['sonnet', 'sonnet'],
    ['haiku', 'haiku'],
    ['fable', 'fable'],
  ];
  const policies = ['auto', 'gpt', 'claude', 'none'];
  for (const mode of ['gptx', 'codex', 'hybrid', 'claude']) {
    for (const policy of policies) {
      const contract = launchContract(mode, policy);
      const childEnv = contract.settings.env;
      const aliases = JSON.parse(childEnv.TRELLIS_GPTX_MODEL_ALIASES);
      const expectedAliases = ['codex', 'hybrid'].includes(mode)
        ? codexAliases
        : claudeAliases;
      assert.deepStrictEqual(aliases, expectedAliases, `${mode} alias map`);
      assert.strictEqual(childEnv.TRELLIS_GPTX_POLICY_VERSION, String(POLICY_VERSION));
      assert.strictEqual(childEnv.TRELLIS_GPTX_DELEGATES, policy);

      for (const [requestedModel, slot] of aliasRequests) {
        const expectedModel = expectedAliases[slot];
        const expectedProvider = expectedModel.startsWith('gpt-') ? 'gpt' : 'claude';
        const evaluation = evaluateAgentCall(agent({
          subagent_type: expectedProvider === 'gpt' ? 'gpt-mid' : 'Explore',
          model: requestedModel,
        }), childEnv);
        const shouldAllow = policy === 'auto' || policy === expectedProvider;
        assert.strictEqual(
          evaluation.allowed,
          shouldAllow,
          `${mode}/${policy}/${requestedModel} should ${shouldAllow ? 'allow' : 'deny'}`,
        );
        assert.strictEqual(evaluation.classification.requested_model, requestedModel);
        assert.strictEqual(evaluation.classification.resolved_model, expectedModel);
        assert.strictEqual(evaluation.classification.provider, expectedProvider);
        assert.strictEqual(evaluation.receipt.effective_provider, expectedProvider);
        assert.strictEqual(evaluation.receipt.classification_source, 'explicit-model');
        assert.strictEqual(evaluation.receipt.resolution_source, `effective-${slot}-alias`);
      }

      for (const [requestedModel, expectedProvider, resolutionSource] of [
        ['claude-opus-5', 'claude', 'literal-model'],
        ['gpt-5.6-sol', 'gpt', 'literal-model'],
        ['sol', 'gpt', 'trellis-model-alias'],
      ]) {
        const evaluation = evaluateAgentCall(agent({ model: requestedModel }), childEnv);
        const shouldAllow = policy === 'auto' || policy === expectedProvider;
        assert.strictEqual(evaluation.allowed, shouldAllow);
        assert.strictEqual(evaluation.classification.provider, expectedProvider);
        assert.strictEqual(evaluation.receipt.resolution_source, resolutionSource);
      }
    }
  }

  for (const [mode, model, expectedOpus] of [
    ['gptx', 'sol', 'gpt-5.6-sol'],
    ['gptx', 'terra', 'gpt-5.6-terra'],
    ['gptx', 'luna', 'gpt-5.6-luna'],
    ['gptx', 'gpt-5.6-sol', 'gpt-5.6-sol'],
    ['codex', 'terra', 'gpt-5.6-terra'],
    ['codex', 'luna', 'gpt-5.6-luna'],
    ['hybrid', 'terra', 'gpt-5.6-terra'],
    ['hybrid', 'luna', 'gpt-5.6-luna'],
    ['claude', 'claude-opus-5', 'claude-opus-5'],
  ]) {
    const contract = launchContract(mode, 'auto', model);
    const childEnv = contract.settings.env;
    const aliases = JSON.parse(childEnv.TRELLIS_GPTX_MODEL_ALIASES);
    assert.strictEqual(aliases.opus, expectedOpus, `${mode}/${model} Opus remap`);
    assert.strictEqual(childEnv.ANTHROPIC_DEFAULT_OPUS_MODEL, expectedOpus);
    const evaluation = evaluateAgentCall(agent({ model: 'opus' }), childEnv);
    assert.strictEqual(evaluation.allowed, true);
    assert.strictEqual(evaluation.classification.resolved_model, expectedOpus);
    assert.strictEqual(
      evaluation.classification.provider,
      expectedOpus.startsWith('gpt-') ? 'gpt' : 'claude',
    );
  }

  const capturedCodexEnv = launchContract('codex', 'auto').settings.env;
  for (const staleVersion of ['', '1']) {
    const evaluation = evaluateAgentCall(agent({ model: 'opus' }), {
      ...capturedCodexEnv,
      TRELLIS_GPTX_POLICY_VERSION: staleVersion,
    });
    assert.strictEqual(evaluation.allowed, false, `policy version '${staleVersion}' should fail closed`);
    assert.match(evaluation.reason, /requires policy version 2/);
  }
  const capturedAliases = JSON.parse(capturedCodexEnv.TRELLIS_GPTX_MODEL_ALIASES);
  delete capturedAliases.sonnet;
  result = evaluateAgentCall(agent({ model: 'sonnet' }), {
    ...capturedCodexEnv,
    TRELLIS_GPTX_MODEL_ALIASES: JSON.stringify(capturedAliases),
  });
  assert.strictEqual(result.allowed, false);
  assert.match(result.reason, /model-alias policy is missing: sonnet/);

  result = evaluateAgentCall(agent({ model: 'opus' }), {
    ...capturedCodexEnv,
    ANTHROPIC_DEFAULT_OPUS_MODEL: 'claude-opus-5',
  });
  assert.strictEqual(result.allowed, false);
  assert.match(result.reason, /locked alias policy resolves 'gpt-5\.6-sol'/);

  assert.strictEqual(
    fs.existsSync(forbiddenLog) ? fs.readFileSync(forbiddenLog, 'utf8') : '',
    '',
    'dry-run alias attestation must not call launchctl, curl, brew, or uname',
  );
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

const malformed = spawnSync(process.execPath, [guard], {
  input: '{not-json',
  encoding: 'utf8',
  env: { ...process.env, ...policyEnv('auto') },
});
assert.strictEqual(malformed.status, 0);
assert.strictEqual(JSON.parse(malformed.stdout).hookSpecificOutput.permissionDecision, 'deny');

console.log('gptx-delegation-guard: ok (alias matrix=4x4, model remaps=9, service commands=0)');
