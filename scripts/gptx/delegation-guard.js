#!/usr/bin/env node
'use strict';

const fs = require('fs');
const {
  POLICY_VERSION,
  DELEGATE_INPUTS,
  AGENT_MODEL_SLOT_ALIASES,
  normalizeAgentModelAliases,
  classifyAgentRequest,
  evaluateDelegation,
} = require('./session-policy');

const normalizedEnvValue = (value) => String(value ?? '').normalize('NFKC').trim();
const policyFromEnv = (env = process.env) => normalizedEnvValue(
  env.TRELLIS_GPTX_DELEGATES,
).toLowerCase();
const policyVersionFromEnv = (env = process.env) => normalizedEnvValue(
  env.TRELLIS_GPTX_POLICY_VERSION,
);

const DEFAULT_MODEL_ENV_KEYS = Object.freeze({
  opus: 'ANTHROPIC_DEFAULT_OPUS_MODEL',
  sonnet: 'ANTHROPIC_DEFAULT_SONNET_MODEL',
  haiku: 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
});
const FIXED_AGENT_MODEL_ALIASES = Object.freeze({
  fable: 'claude-fable-5',
});

const modelAliasesFromEnv = (env = process.env) => {
  const raw = normalizedEnvValue(env.TRELLIS_GPTX_MODEL_ALIASES);
  if (!raw) {
    return {
      valid: false,
      aliases: {},
      error: 'the effective Agent model-alias policy is missing',
    };
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return {
      valid: false,
      aliases: {},
      error: `the effective Agent model-alias policy is invalid JSON: ${error.message}`,
    };
  }
  const aliases = normalizeAgentModelAliases(parsed);
  const missing = AGENT_MODEL_SLOT_ALIASES.filter((slot) => !aliases[slot]);
  if (missing.length > 0) {
    return {
      valid: false,
      aliases,
      error: `the effective Agent model-alias policy is missing: ${missing.join(', ')}`,
    };
  }

  for (const [slot, envKey] of Object.entries(DEFAULT_MODEL_ENV_KEYS)) {
    const effective = normalizedEnvValue(env[envKey]);
    if (effective && effective !== aliases[slot]) {
      return {
        valid: false,
        aliases,
        error: `${envKey} resolves '${effective}' but the locked alias policy resolves '${aliases[slot]}'`,
      };
    }
    if (!effective && aliases[slot].toLowerCase() !== slot) {
      return {
        valid: false,
        aliases,
        error: `${envKey} is missing for locked alias '${slot}' -> '${aliases[slot]}'`,
      };
    }
  }
  for (const [slot, expected] of Object.entries(FIXED_AGENT_MODEL_ALIASES)) {
    if (aliases[slot] !== expected) {
      return {
        valid: false,
        aliases,
        error: `locked alias '${slot}' must resolve '${expected}', received '${aliases[slot]}'`,
      };
    }
  }
  return { valid: true, aliases, error: null };
};

const correctionFor = (policy, classification, reason) => {
  if (reason === 'disabled') {
    return 'Relaunch with --delegates auto, gpt, or claude to enable Agent calls.';
  }
  if (reason === 'invalid-policy') {
    return `Set TRELLIS_GPTX_DELEGATES to one of: ${DELEGATE_INPUTS.join(', ')}.`;
  }
  if (classification.source === 'explicit-model') {
    return 'Remove the Agent model override, choose a permitted Agent type, or relaunch with another --delegates value.';
  }
  return 'Choose a permitted Agent type or relaunch with another --delegates value.';
};

const evaluateAgentCall = (hookInput, env = process.env) => {
  if (hookInput?.tool_name !== 'Agent') return { allowed: true, passthrough: true };

  const policy = policyFromEnv(env);
  const policyVersion = policyVersionFromEnv(env);
  if (policyVersion !== String(POLICY_VERSION)) {
    return {
      allowed: false,
      passthrough: false,
      policy,
      classification: null,
      reason: [
        `Trellis delegate guard requires policy version ${POLICY_VERSION};`,
        policyVersion ? `received '${policyVersion}'.` : 'the session policy environment is missing.',
        'Relaunch through cmux-trellis-teams so nested Agent calls inherit the locked policy.',
      ].join(' '),
    };
  }

  const aliasPolicy = modelAliasesFromEnv(env);
  if (!aliasPolicy.valid) {
    return {
      allowed: false,
      passthrough: false,
      policy,
      classification: null,
      reason: [
        `Trellis delegate guard rejected stale model-alias policy: ${aliasPolicy.error}.`,
        'Relaunch through cmux-trellis-teams so Agent aliases match the effective runtime model mapping.',
      ].join(' '),
    };
  }

  const classification = classifyAgentRequest(hookInput.tool_input || {}, aliasPolicy.aliases);
  const decision = evaluateDelegation(policy, classification);
  const receipt = {
    policy_version: POLICY_VERSION,
    delegates: policy,
    requested_model: classification.requested_model,
    resolved_model: classification.resolved_model,
    effective_provider: classification.provider,
    classification_source: classification.source,
    resolution_source: classification.resolution_source,
    decision: decision.reason,
  };
  if (decision.allowed) {
    return { allowed: true, passthrough: false, policy, classification, receipt };
  }

  const provider = classification.provider === 'unknown'
    ? 'unknown'
    : `'${classification.provider}'`;
  const value = classification.value == null ? '' : ` from '${classification.value}'`;
  const resolution = classification.requested_model == null
    ? ''
    : ` Requested model '${classification.requested_model}' resolved to '${classification.resolved_model}' via ${classification.resolution_source}.`;
  const reason = [
    `Trellis delegate policy '${policy}' rejected Agent provider ${provider}`,
    `(classification source: ${classification.source}${value}).${resolution}`,
    correctionFor(policy, classification, decision.reason),
  ].join(' ');

  return {
    allowed: false,
    passthrough: false,
    policy,
    classification,
    receipt,
    reason,
  };
};

const denyPayload = (reason) => ({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason: reason,
  },
});

const main = () => {
  let hookInput;
  try {
    hookInput = JSON.parse(fs.readFileSync(0, 'utf8'));
  } catch (error) {
    process.stdout.write(`${JSON.stringify(denyPayload(
      `Trellis delegate guard could not parse PreToolUse input: ${error.message}`,
    ))}\n`);
    return;
  }

  const result = evaluateAgentCall(hookInput);
  if (!result.allowed) process.stdout.write(`${JSON.stringify(denyPayload(result.reason))}\n`);
};

if (require.main === module) main();

module.exports = {
  policyFromEnv,
  policyVersionFromEnv,
  modelAliasesFromEnv,
  correctionFor,
  evaluateAgentCall,
  denyPayload,
};
