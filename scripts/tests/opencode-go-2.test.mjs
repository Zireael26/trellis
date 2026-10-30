import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const root = resolve(import.meta.dirname, '../..');
const sourcePath = join(root, 'core-rules/pi/extensions/opencode-go-2.ts');
let loadSequence = 0;

async function loadFixture() {
  const agentDir = mkdtempSync(join(tmpdir(), 'trellis-go2-test-'));
  const catalogue = ['muse-spark-1.3-contributor', 'gemini-4-argon-contributor', 'glm-5.3-flash']
    .map(id => ({ id, name: id, api: 'openai-completions', baseUrl: 'https://opencode.ai/inference/go/v1',
      contextWindow: 100000, maxTokens: 8000, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }));
  writeFileSync(join(agentDir, 'models-store.json'), JSON.stringify({ providers: { 'opencode-go': { models: catalogue } } }));
  process.env.PI_CODING_AGENT_DIR = agentDir;
  process.env.OPENCODE_GO_2_API_KEY = 'fake-test-key';
  let sent;
  globalThis.__go2TestStreamSimple = (model, context, options) => { sent = { model, context, options }; return 'stream'; };
  const original = readFileSync(sourcePath, 'utf8');
  const mocked = original.replace(/import\s*\{\s*streamSimple\s*\}\s*from\s*["']@earendil-works\/pi-ai\/compat["'];?/,
    'const streamSimple = globalThis.__go2TestStreamSimple;');
  const js = stripTypeScriptTypes(mocked, { mode: 'strip' });
  const { default: extension } = await import('data:text/javascript,' + encodeURIComponent(js) + '#' + ++loadSequence);
  let registration;
  await extension({ registerProvider: (id, config) => { registration = { id, config }; } });
  assert.equal(registration?.id, 'opencode-go-2');
  return { registration, getSent: () => sent };
}

test('Go 2 catalog clones Muse, Argon and GLM with their distinct wires and endpoints', async () => {
  const { registration: { config } } = await loadFixture();
  const models = Object.fromEntries(config.models.map(model => [model.id, model]));
  assert.deepEqual(Object.keys(models).sort(),
    ['muse-spark-1.3-contributor', 'gemini-4-argon-contributor', 'glm-5.3-flash'].sort());
  assert.equal(models['muse-spark-1.3-contributor'].api, 'openai-responses');
  assert.equal(models['gemini-4-argon-contributor'].api, 'google-generative-ai');
  assert.equal(models['glm-5.3-flash'].api, 'openai-completions');
  for (const id of ['gemini-4-argon-contributor', 'glm-5.3-flash']) {
    assert.equal(models[id].baseUrl, 'https://opencode.ai/inference/go/v1');
    assert.equal(models[id].provider, 'opencode-go-2');
  }
});

test('Go 2 request forwards current session as x-opencode-session, not a static model header', async () => {
  const { registration: { config }, getSent } = await loadFixture();
  assert.equal(typeof config.streamSimple, 'function');
  for (const id of ['gemini-4-argon-contributor', 'glm-5.3-flash']) {
    const model = config.models.find(model => model.id === id);
    config.streamSimple(model, { messages: [] }, { sessionId: 'live-session-123', apiKey: 'fake-test-key', headers: { 'x-custom': 'kept' } });
    assert.equal(getSent().options.headers['x-opencode-session'], 'live-session-123');
    assert.equal(getSent().options.headers['x-custom'], 'kept');
    assert.equal(model.headers?.['x-opencode-session'], undefined);
  }
});
