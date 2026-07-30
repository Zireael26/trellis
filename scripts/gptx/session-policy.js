#!/usr/bin/env node
'use strict';

const POLICY_VERSION = 2;
const MODES = Object.freeze(['gptx', 'codex', 'hybrid', 'claude']);
const ADVISOR_INPUTS = Object.freeze(['auto', 'opus', 'fable', 'sol', 'none']);
const DELEGATE_INPUTS = Object.freeze(['auto', 'gpt', 'claude', 'none']);
const MODEL_INPUT_CLASSES = Object.freeze([
  'omitted',
  'claude-family',
  'sol-family',
  'terra-family',
  'luna-family',
  'unrecognized-explicit',
]);

const MODE_DEFAULTS = Object.freeze({
  gptx: Object.freeze({ model: 'opus[1m]', advisor: 'auto' }),
  codex: Object.freeze({ model: 'sol', advisor: 'sol' }),
  hybrid: Object.freeze({ model: 'sol', advisor: 'auto' }),
  claude: Object.freeze({ model: 'opus[1m]', advisor: 'opus' }),
});

const MODEL_CLASS_EXAMPLES = Object.freeze({
  omitted: null,
  'claude-family': 'opus[1m]',
  'sol-family': 'sol',
  'terra-family': 'terra',
  'luna-family': 'luna',
  'unrecognized-explicit': 'unrecognized-model',
});

const MODEL_ALIASES = Object.freeze({
  sol: 'gpt-5.6-sol',
  terra: 'gpt-5.6-terra',
  luna: 'gpt-5.6-luna',
});

const AGENT_MODEL_SLOT_ALIASES = Object.freeze(['opus', 'sonnet', 'haiku', 'fable']);
const DEFAULT_AGENT_MODEL_ALIASES = Object.freeze(Object.fromEntries(
  AGENT_MODEL_SLOT_ALIASES.map((slot) => [slot, slot]),
));

const AGENT_TYPE_PROVIDERS = Object.freeze({
  'gpt-mid': 'gpt',
  'gpt-high': 'gpt',
  'gpt-sol': 'gpt',
  'gpt-terra': 'gpt',
  'gpt-sol-advisor': 'gpt',
  'gpt-sol-reviewer': 'gpt',
  claude: 'claude',
  'claude-code-guide': 'claude',
  'code-reviewer': 'claude',
  'general-purpose': 'claude',
  'lane-worker': 'claude',
  explore: 'claude',
  plan: 'claude',
  'codex-worker': 'claude',
  'codex:codex-rescue': 'claude',
  'feature-dev:code-architect': 'claude',
  'feature-dev:code-explorer': 'claude',
  'feature-dev:code-reviewer': 'claude',
  'opus-advisor': 'claude',
  'statusline-setup': 'claude',
});

const normalize = (value) => String(value ?? '').normalize('NFKC').trim();
const normalizeLower = (value) => normalize(value).toLowerCase();

const resolveModelAlias = (model) => {
  const normalized = normalize(model);
  return MODEL_ALIASES[normalized.toLowerCase()] || normalized;
};

const normalizeAgentModelAliases = (aliases = DEFAULT_AGENT_MODEL_ALIASES) => {
  if (!aliases || typeof aliases !== 'object' || Array.isArray(aliases)) return {};
  const normalized = {};
  for (const slot of AGENT_MODEL_SLOT_ALIASES) {
    const value = normalize(aliases[slot]);
    if (value) normalized[slot] = value;
  }
  return normalized;
};

const resolveAgentModelAlias = (model, aliases = DEFAULT_AGENT_MODEL_ALIASES) => {
  const requested = normalize(model);
  const match = /^(opus|sonnet|haiku|fable)(\[1m\])?$/i.exec(requested);
  if (!match) {
    return {
      requested,
      resolved: resolveModelAlias(requested),
      source: Object.hasOwn(MODEL_ALIASES, requested.toLowerCase())
        ? 'trellis-model-alias'
        : 'literal-model',
      slot: null,
    };
  }

  const slot = match[1].toLowerCase();
  const normalizedAliases = normalizeAgentModelAliases(aliases);
  const target = normalizedAliases[slot] || slot;
  const selfMapped = target.toLowerCase() === slot;
  return {
    requested,
    resolved: selfMapped ? requested : resolveModelAlias(target),
    source: selfMapped ? 'claude-slot-default' : `effective-${slot}-alias`,
    slot,
  };
};

const classifyModel = (model) => {
  const requested = normalize(model);
  const normalized = requested.toLowerCase();
  if (!normalized) {
    return { provider: 'unknown', family: 'unknown', model: requested };
  }

  if (/^claude[-.]/i.test(requested)
    || /^(opus|sonnet|haiku|fable)(?:\[1m\])?$/i.test(requested)) {
    return { provider: 'claude', family: 'claude', model: requested };
  }

  const gpt = /^(gpt-|codex-|o\d)/i.test(requested)
    || /-(sol|terra|luna)(?:-|$)/i.test(requested)
    || Object.hasOwn(MODEL_ALIASES, normalized);
  if (!gpt) {
    return { provider: 'unknown', family: 'unknown', model: requested };
  }

  let family = 'gpt';
  if (normalized === 'terra' || /(?:^|[-.])terra(?:[-.]|$)/i.test(requested)) family = 'terra';
  else if (normalized === 'luna' || /(?:^|[-.])luna(?:[-.]|$)/i.test(requested)) family = 'luna';
  else if (normalized === 'sol' || /(?:^|[-.])sol(?:[-.]|$)/i.test(requested)) family = 'sol';

  return { provider: 'gpt', family, model: requested };
};

const classifyAgentRequest = (toolInput = {}, modelAliases = DEFAULT_AGENT_MODEL_ALIASES) => {
  const explicitModel = normalize(toolInput.model);
  if (explicitModel && explicitModel.toLowerCase() !== 'inherit') {
    const resolution = resolveAgentModelAlias(explicitModel, modelAliases);
    const classified = classifyModel(resolution.resolved);
    return {
      provider: classified.provider,
      source: 'explicit-model',
      value: explicitModel,
      family: classified.family,
      requested_model: explicitModel,
      resolved_model: resolution.resolved,
      resolution_source: resolution.source,
    };
  }

  const agentType = normalizeLower(toolInput.subagent_type);
  if (agentType && Object.hasOwn(AGENT_TYPE_PROVIDERS, agentType)) {
    return {
      provider: AGENT_TYPE_PROVIDERS[agentType],
      source: 'agent-type',
      value: normalize(toolInput.subagent_type),
      family: null,
      requested_model: null,
      resolved_model: null,
      resolution_source: 'agent-type',
    };
  }

  return {
    provider: 'unknown',
    source: 'unknown',
    value: agentType || null,
    family: null,
    requested_model: explicitModel || null,
    resolved_model: explicitModel || null,
    resolution_source: 'unknown',
  };
};

const allowedAgentProviders = (delegates) => {
  if (delegates === 'auto') return ['gpt', 'claude'];
  if (delegates === 'gpt') return ['gpt'];
  if (delegates === 'claude') return ['claude'];
  return [];
};

const evaluateDelegation = (delegates, classification) => {
  if (!DELEGATE_INPUTS.includes(delegates)) {
    return { allowed: false, reason: 'invalid-policy' };
  }
  if (delegates === 'auto') return { allowed: true, reason: 'auto' };
  if (delegates === 'none') return { allowed: false, reason: 'disabled' };
  if (classification.provider === delegates) return { allowed: true, reason: 'provider-match' };
  if (classification.provider === 'unknown') return { allowed: false, reason: 'unknown-provider' };
  return { allowed: false, reason: 'provider-mismatch' };
};

const invalidResolution = (requested, error) => ({
  policy_version: POLICY_VERSION,
  requested,
  valid: false,
  error,
  effective: null,
});

const resolveLaunch = ({
  mode = 'gptx',
  model = null,
  advisor = null,
  delegates = null,
} = {}) => {
  const requested = {
    mode: normalizeLower(mode) || 'gptx',
    model: model == null ? null : normalize(model),
    advisor: advisor == null ? null : normalizeLower(advisor),
    delegates: delegates == null ? null : normalizeLower(delegates),
  };

  if (!MODES.includes(requested.mode)) {
    return invalidResolution(
      requested,
      `unknown mode '${requested.mode}' (expected ${MODES.slice(0, -1).join(', ')}, or ${MODES.at(-1)})`,
    );
  }

  if (requested.advisor != null && !ADVISOR_INPUTS.includes(requested.advisor)) {
    return invalidResolution(
      requested,
      `unknown advisor '${requested.advisor}' (expected ${ADVISOR_INPUTS.slice(0, -1).join(', ')}, or ${ADVISOR_INPUTS.at(-1)})`,
    );
  }

  if (requested.delegates != null && !DELEGATE_INPUTS.includes(requested.delegates)) {
    return invalidResolution(
      requested,
      `unknown delegates policy '${requested.delegates}' (expected ${DELEGATE_INPUTS.slice(0, -1).join(', ')}, or ${DELEGATE_INPUTS.at(-1)})`,
    );
  }

  const defaults = MODE_DEFAULTS[requested.mode];
  const requestedMainModel = requested.model ?? defaults.model;
  const mainModel = resolveModelAlias(requestedMainModel);
  const modelClassification = classifyModel(mainModel);
  const effectiveAdvisor = requested.advisor ?? defaults.advisor;
  const effectiveDelegates = requested.delegates ?? 'auto';

  if (modelClassification.provider === 'unknown') {
    return invalidResolution(
      requested,
      `unknown model '${requestedMainModel}' (expected a Claude model, GPT/Codex model, sol, terra, or luna)`,
    );
  }

  if (['codex', 'hybrid'].includes(requested.mode) && modelClassification.provider !== 'gpt') {
    return invalidResolution(requested, `${requested.mode} mode requires a GPT/Codex main model`);
  }
  if (requested.mode === 'claude' && modelClassification.provider !== 'claude') {
    return invalidResolution(requested, 'claude mode requires a Claude main model');
  }

  const topology = modelClassification.provider === 'gpt'
    || requested.mode === 'gptx'
    || (requested.mode === 'claude' && effectiveAdvisor === 'sol')
    ? 'routed'
    : 'direct';
  const advisorTransport = effectiveAdvisor === 'none'
    ? 'disabled'
    : modelClassification.provider === 'claude' && effectiveAdvisor === 'sol'
      ? 'nested-agent'
      : 'server-tool';
  const allowedProviders = allowedAgentProviders(effectiveDelegates);
  let capabilityNote = 'Policy permission does not guarantee provider quota or availability.';
  if (effectiveDelegates === 'none') {
    capabilityNote = 'Agent calls are rejected before spawn by delegate policy.';
  } else if (topology === 'direct' && allowedProviders.includes('gpt')) {
    capabilityNote = 'GPT Agents are policy-permitted, but this direct Claude topology has no local GPT route.';
  }

  // Terra's per-unit advice-before-mutation invariant was retired 2026-07-30 because a
  // blocking round-trip cancels the throughput advantage that is the only reason to pick
  // Terra, and because a DELEGATED Terra unit already passes the orchestrator's review
  // gate. That reasoning holds only while an orchestrator of another family actually
  // exists above it. When Terra is the MAIN model it *is* the top of the loop, so
  // "the orchestrator reviews the diff" names a reviewer that is not there.
  //
  // Cross-model review caught this: `--mode codex --model terra --advisor none
  // --delegates none` resolved valid with agent_usable false and zero allowed
  // providers — unadvised, self-reviewing, and structurally unable to spawn a reviewer.
  //
  // So the gate is restored only for the case whose premise failed, and it is stricter
  // than the one it replaces: the retired gate accepted `--advisor sol`, which is
  // GPT reviewing GPT and is forbidden outright by model-routing.md stage 1 rule 2.
  // A Terra main loop must be able to reach a CLAUDE-family oracle — as its advisor,
  // or as a delegate it is permitted to spawn.
  const terraIsMainLoop = modelClassification.family === 'terra';
  const claudeOracleReachable = ['auto', 'opus', 'fable'].includes(effectiveAdvisor)
    || allowedProviders.includes('claude');
  if (terraIsMainLoop && !claudeOracleReachable) {
    return invalidResolution(
      requested,
      'Terra as the main model has no orchestrator above it, so it needs a reachable '
      + 'cross-family oracle: use --advisor auto, opus, or fable, or permit Claude '
      + "delegates (--delegates claude or auto). --advisor sol does not qualify — "
      + 'GPT reviewing GPT is not independent review. Delegated Terra under a '
      + 'Claude orchestrator is unaffected and needs no advisor.',
    );
  }

  return {
    policy_version: POLICY_VERSION,
    requested,
    valid: true,
    error: null,
    effective: {
      mode: requested.mode,
      default_model: resolveModelAlias(defaults.model),
      main_model: mainModel,
      main_provider: modelClassification.provider,
      model_family: modelClassification.family,
      model_source: requested.model == null ? 'mode-default' : 'explicit-model',
      advisor: effectiveAdvisor,
      advisor_source: requested.advisor == null ? 'mode-default' : 'explicit',
      delegates: effectiveDelegates,
      delegates_source: requested.delegates == null ? 'default' : 'explicit',
      topology,
      advisor_transport: advisorTransport,
      agent_usable: effectiveDelegates !== 'none',
      allowed_agent_providers: allowedProviders,
      capability_note: capabilityNote,
      // Terra's advisor pairing is recommended, not required, for a DELEGATED unit:
      // Terra is a throughput tier at ~90% of the frontier capability index, and a
      // delegated unit already passes the orchestrator's review gate
      // (core-rules/references/delegation.md) — a post-hoc check on a finished diff
      // rather than pre-hoc advice on a proposed approach. Note the limit of that
      // substitution: reviewing a diff cannot undo an irreversible side effect the
      // unit already caused, so it is weaker than the retired gate for destructive
      // or externally-visible work, not merely different. Weigh that per unit.
      terra_advisor_recommended: modelClassification.family === 'terra',
      notices: terraIsMainLoop && effectiveAdvisor === 'none'
        ? ['Terra is the main model with no advisor. It is permitted here only because '
          + 'Claude delegates are available: an independent reviewer exists but is not '
          + 'automatic, so you must actually spawn one. Reviewing a finished diff cannot '
          + 'undo an irreversible side effect, so bound this session away from '
          + 'destructive and externally-visible work, or pair an advisor.']
        : [],
    },
  };
};

const parseCliArgs = (argv) => {
  const args = { command: null, mode: 'gptx', model: null, advisor: null, delegates: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--resolve-launch') args.command = 'resolve-launch';
    else if (arg === '--mode') args.mode = argv[++index];
    else if (arg.startsWith('--mode=')) args.mode = arg.slice('--mode='.length);
    else if (arg === '--model') args.model = argv[++index];
    else if (arg.startsWith('--model=')) args.model = arg.slice('--model='.length);
    else if (arg === '--advisor') args.advisor = argv[++index];
    else if (arg.startsWith('--advisor=')) args.advisor = arg.slice('--advisor='.length);
    else if (arg === '--delegates') args.delegates = argv[++index];
    else if (arg.startsWith('--delegates=')) args.delegates = arg.slice('--delegates='.length);
    else throw new Error(`unknown argument: ${arg}`);
  }
  return args;
};

const main = () => {
  try {
    const args = parseCliArgs(process.argv.slice(2));
    if (args.command !== 'resolve-launch') {
      throw new Error('expected --resolve-launch');
    }
    process.stdout.write(`${JSON.stringify(resolveLaunch(args))}\n`);
  } catch (error) {
    process.stderr.write(`session-policy: ${error.message}\n`);
    process.exitCode = 2;
  }
};

if (require.main === module) main();

module.exports = {
  POLICY_VERSION,
  MODES,
  ADVISOR_INPUTS,
  DELEGATE_INPUTS,
  MODEL_INPUT_CLASSES,
  MODE_DEFAULTS,
  MODEL_CLASS_EXAMPLES,
  MODEL_ALIASES,
  AGENT_MODEL_SLOT_ALIASES,
  DEFAULT_AGENT_MODEL_ALIASES,
  AGENT_TYPE_PROVIDERS,
  resolveModelAlias,
  normalizeAgentModelAliases,
  resolveAgentModelAlias,
  classifyModel,
  classifyAgentRequest,
  allowedAgentProviders,
  evaluateDelegation,
  resolveLaunch,
  parseCliArgs,
};
