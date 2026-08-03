'use strict';

// Sol's execution model. Retained as a named export because it is Sol's, not "the"
// execution model — see ALIAS_TABLE.
const EXECUTION_MODEL = 'gpt-5.6-sol';

// Each alias carries its OWN execution model. This used to be a single hardcoded
// constant applied to every alias, which silently capped the mechanism at one model
// family: `gpt-terra` declared `effort: xhigh` in frontmatter and requested the
// unaliased `gpt-5.6-terra`, so the router found no alias entry, injected no effort,
// and reported `effort: null` / `effortSource: null`. The declared rung was never
// enforced. Adding a terra key to the old map would have been worse than the gap —
// it would have executed Sol under a terra name.
const ALIAS_TABLE = Object.freeze({
  'gpt-5.6-sol-medium': Object.freeze({ effort: 'medium', executionModel: 'gpt-5.6-sol' }),
  'gpt-5.6-sol-high': Object.freeze({ effort: 'high', executionModel: 'gpt-5.6-sol' }),
  'gpt-5.6-sol-xhigh': Object.freeze({ effort: 'xhigh', executionModel: 'gpt-5.6-sol' }),
  'gpt-5.6-terra-medium': Object.freeze({ effort: 'medium', executionModel: 'gpt-5.6-terra' }),
  'gpt-5.6-terra-high': Object.freeze({ effort: 'high', executionModel: 'gpt-5.6-terra' }),
  'gpt-5.6-terra-xhigh': Object.freeze({ effort: 'xhigh', executionModel: 'gpt-5.6-terra' }),
  'gpt-5.6-luna-xhigh': Object.freeze({ effort: 'xhigh', executionModel: 'gpt-5.6-luna' }),
});

// Kept as alias -> effort for existing consumers; derived so the two cannot drift.
const EFFORT_BY_ALIAS = Object.freeze(Object.fromEntries(
  Object.entries(ALIAS_TABLE).map(([alias, entry]) => [alias, entry.effort]),
));

/**
 * Prepare the body forwarded across the router boundary.
 *
 * Only the exact allowlisted GPT aliases are reserialized. Anthropic requests and
 * every other model retain the original bytes so the Claude lane stays a dumb pipe.
 * The caller must keep using its original parsed body for policy and receipts.
 *
 * @param {{lane: 'anthropic'|'codex', parsedBody: object|null, body: Buffer}} input
 * @returns {{body: Buffer, rewritten: boolean, executionModel: string|null, effort: string|null, effortSource: string|null}}
 */
const prepareForwardBody = ({ lane, parsedBody, body }) => {
  const requestedModel = parsedBody?.model;
  const alias = lane === 'codex' && typeof requestedModel === 'string'
    ? ALIAS_TABLE[requestedModel]
    : null;
  const effort = alias?.effort ?? null;

  if (!effort) {
    return {
      body,
      rewritten: false,
      executionModel: typeof requestedModel === 'string' ? requestedModel : null,
      effort: null,
      effortSource: null,
    };
  }

  const outputConfig = parsedBody.output_config
    && typeof parsedBody.output_config === 'object'
    && !Array.isArray(parsedBody.output_config)
    ? parsedBody.output_config
    : {};
  const forwarded = {
    ...parsedBody,
    model: alias.executionModel,
    output_config: {
      ...outputConfig,
      effort,
    },
  };

  return {
    body: Buffer.from(JSON.stringify(forwarded)),
    rewritten: true,
    executionModel: alias.executionModel,
    effort,
    effortSource: 'profile-alias',
  };
};

const executionModelFor = (model) => (Object.hasOwn(ALIAS_TABLE, model)
  ? ALIAS_TABLE[model].executionModel
  : model);

module.exports = {
  EXECUTION_MODEL,
  ALIAS_TABLE,
  EFFORT_BY_ALIAS,
  executionModelFor,
  prepareForwardBody,
};
