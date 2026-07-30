#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { executionModelFor } = require('./effort-alias');

const DEFAULT_EFFECTIVE_PERCENT = 95;
const CODEX_COMPACT_PERCENT = 90;
const CLAUDE_OUTPUT_RESERVE = 20_000;
const CLAUDE_COMPACT_RESERVE = 13_000;

const positiveInteger = (value, label) => {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${label} must be a positive integer`);
  }
  return parsed;
};

const defaultCachePath = () => path.join(
  process.env.CODEX_HOME || path.join(os.homedir(), '.codex'),
  'models_cache.json',
);

const readCatalog = (cachePath) => {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read Codex model catalog at ${cachePath}: ${error.message}`);
  }
  if (!Array.isArray(parsed.models)) {
    throw new Error(`Codex model catalog at ${cachePath} has no models array`);
  }
  return parsed;
};

const resolveModelContext = ({
  model,
  cachePath = defaultCachePath(),
  contextWindow = process.env.TRELLIS_GPT_CONTEXT_WINDOW,
} = {}) => {
  if (!model || typeof model !== 'string') {
    throw new Error('model is required');
  }

  const executionModel = executionModelFor(model);
  let catalog = null;
  let entry = null;
  let raw;
  let source;

  if (contextWindow !== undefined && contextWindow !== '') {
    raw = positiveInteger(contextWindow, 'context window override');
    source = 'override';
  } else {
    catalog = readCatalog(cachePath);
    entry = catalog.models.find((candidate) => candidate.slug === executionModel);
    if (!entry) {
      throw new Error(
        `model ${executionModel} is absent from ${cachePath}; run Codex once to refresh its catalog `
        + 'or set TRELLIS_GPT_CONTEXT_WINDOW explicitly',
      );
    }
    raw = positiveInteger(
      entry.context_window || entry.max_context_window,
      `${model} context window`,
    );
    source = 'codex-catalog';
  }

  const effectivePercent = entry?.effective_context_window_percent
    ?? DEFAULT_EFFECTIVE_PERCENT;
  const effective = Math.floor(raw * positiveInteger(
    effectivePercent,
    `${model} effective context percent`,
  ) / 100);
  const codexDefaultCompact = Math.floor(raw * CODEX_COMPACT_PERCENT / 100);
  const nativeCompact = entry?.auto_compact_token_limit == null
    ? codexDefaultCompact
    : Math.min(
      positiveInteger(entry.auto_compact_token_limit, `${model} auto compact limit`),
      codexDefaultCompact,
    );

  return {
    model,
    execution_model: executionModel,
    source,
    catalog_path: source === 'codex-catalog' ? cachePath : null,
    catalog_fetched_at: catalog?.fetched_at ?? null,
    raw_context_tokens: raw,
    effective_context_percent: effectivePercent,
    effective_context_tokens: effective,
    codex_auto_compact_tokens: nativeCompact,
    claude_code_max_context_tokens: raw,
    claude_code_estimated_compact_tokens:
      Math.max(0, raw - CLAUDE_OUTPUT_RESERVE - CLAUDE_COMPACT_RESERVE),
  };
};

const parseArgs = (argv) => {
  const args = {
    model: null,
    cachePath: defaultCachePath(),
    contextWindow: process.env.TRELLIS_GPT_CONTEXT_WINDOW,
    format: 'json',
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--model') args.model = argv[++index];
    else if (arg.startsWith('--model=')) args.model = arg.slice('--model='.length);
    else if (arg === '--cache') args.cachePath = argv[++index];
    else if (arg.startsWith('--cache=')) args.cachePath = arg.slice('--cache='.length);
    else if (arg === '--context-window') args.contextWindow = argv[++index];
    else if (arg.startsWith('--context-window=')) {
      args.contextWindow = arg.slice('--context-window='.length);
    } else if (arg === '--claude-env') args.format = 'claude-env';
    else if (arg === '--help' || arg === '-h') args.format = 'help';
    else if (!arg.startsWith('-') && !args.model) args.model = arg;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return args;
};

const usage = `Usage: trellis model-context MODEL [options]

Resolve the context window exposed by the current Codex subscription catalog.

Options:
  --cache PATH             Read a specific models_cache.json
  --context-window TOKENS  Explicit visible override when no catalog is available
  --claude-env             Print only the Claude Code env overlay as JSON
  -h, --help               Show this help`;

const main = () => {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (args.format === 'help') {
      process.stdout.write(`${usage}\n`);
      return;
    }
    const resolved = resolveModelContext(args);
    const output = args.format === 'claude-env'
      ? { CLAUDE_CODE_MAX_CONTEXT_TOKENS: String(resolved.claude_code_max_context_tokens) }
      : resolved;
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`model-context: ${error.message}\n`);
    process.exitCode = 1;
  }
};

if (require.main === module) main();

module.exports = {
  resolveModelContext,
  readCatalog,
  defaultCachePath,
  parseArgs,
  DEFAULT_EFFECTIVE_PERCENT,
  CODEX_COMPACT_PERCENT,
  CLAUDE_OUTPUT_RESERVE,
  CLAUDE_COMPACT_RESERVE,
};

