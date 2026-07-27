#!/usr/bin/env node
'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  resolveModelContext,
} = require('../gptx/model-context');

const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'gptx-model-context-'));
const catalogPath = path.join(temporaryDirectory, 'models_cache.json');
const scriptPath = path.resolve(__dirname, '../gptx/model-context.js');

const writeCatalog = (models) => fs.writeFileSync(catalogPath, JSON.stringify({
  fetched_at: '2026-07-27T15:51:52Z',
  models,
}));

try {
  writeCatalog([
    {
      slug: 'gpt-5.6-sol',
      context_window: 272000,
      max_context_window: 272000,
      effective_context_window_percent: 95,
      auto_compact_token_limit: null,
    },
    {
      slug: 'gpt-5.6-terra',
      context_window: 300000,
      effective_context_window_percent: 92,
      auto_compact_token_limit: 250000,
    },
  ]);

  const sol = resolveModelContext({ model: 'gpt-5.6-sol', cachePath: catalogPath });
  assert.equal(sol.raw_context_tokens, 272000);
  assert.equal(sol.effective_context_tokens, 258400);
  assert.equal(sol.codex_auto_compact_tokens, 244800);
  assert.equal(sol.claude_code_max_context_tokens, 272000);
  assert.equal(sol.claude_code_estimated_compact_tokens, 239000);
  assert.equal(sol.source, 'codex-catalog');

  const terra = resolveModelContext({ model: 'gpt-5.6-terra', cachePath: catalogPath });
  assert.equal(terra.raw_context_tokens, 300000);
  assert.equal(terra.effective_context_tokens, 276000);
  assert.equal(terra.codex_auto_compact_tokens, 250000);
  assert.equal(terra.claude_code_estimated_compact_tokens, 267000);

  const override = resolveModelContext({
    model: 'gpt-5.6-luna',
    cachePath: path.join(temporaryDirectory, 'missing.json'),
    contextWindow: '280000',
  });
  assert.equal(override.source, 'override');
  assert.equal(override.raw_context_tokens, 280000);
  assert.equal(override.codex_auto_compact_tokens, 252000);

  assert.throws(
    () => resolveModelContext({ model: 'missing-model', cachePath: catalogPath }),
    /absent from/,
  );
  assert.throws(
    () => resolveModelContext({
      model: 'gpt-5.6-sol',
      cachePath: catalogPath,
      contextWindow: 'not-a-number',
    }),
    /positive integer/,
  );

  const cli = spawnSync(process.execPath, [
    scriptPath,
    '--model', 'gpt-5.6-sol',
    '--cache', catalogPath,
    '--claude-env',
  ], { encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr);
  assert.deepEqual(JSON.parse(cli.stdout), {
    CLAUDE_CODE_MAX_CONTEXT_TOKENS: '272000',
  });

  const missing = spawnSync(process.execPath, [
    scriptPath,
    '--model', 'missing-model',
    '--cache', catalogPath,
  ], { encoding: 'utf8' });
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /absent from/);

  process.stdout.write('gptx-model-context: 12 assertions passed\n');
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}

