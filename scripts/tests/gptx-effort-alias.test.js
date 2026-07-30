#!/usr/bin/env node
'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const {
  EXECUTION_MODEL,
  ALIAS_TABLE,
  EFFORT_BY_ALIAS,
  executionModelFor,
  prepareForwardBody,
} = require('../gptx/effort-alias');

const ROOT = path.resolve(__dirname, '..', '..');
const ROUTER = path.join(ROOT, 'scripts', 'gptx', 'router.js');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'gptx-effort-alias-'));

const listen = (server, port = 0) => new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(port, '127.0.0.1', () => {
    server.removeListener('error', reject);
    resolve(server.address().port);
  });
});

const closeServer = (server) => new Promise((resolve, reject) => {
  if (!server.listening) {
    resolve();
    return;
  }
  server.close((error) => {
    if (error) reject(error);
    else resolve();
  });
});

const freePort = async () => {
  const server = http.createServer();
  const port = await listen(server);
  await closeServer(server);
  return port;
};

const request = ({ port, method = 'POST', requestPath = '/v1/messages', body = null }) => (
  new Promise((resolve, reject) => {
    const encoded = body == null ? null : Buffer.from(JSON.stringify(body));
    const headers = encoded
      ? {
        'content-type': 'application/json',
        'content-length': String(encoded.length),
        'anthropic-version': '2023-06-01',
      }
      : {};
    const outgoing = http.request({
      hostname: '127.0.0.1',
      port,
      path: requestPath,
      method,
      headers,
    }, (incoming) => {
      const chunks = [];
      incoming.on('data', (chunk) => chunks.push(chunk));
      incoming.once('error', reject);
      incoming.once('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let parsed = null;
        try { parsed = raw ? JSON.parse(raw) : null; } catch {}
        resolve({ status: incoming.statusCode, raw, body: parsed });
      });
    });
    outgoing.once('error', reject);
    if (encoded) outgoing.write(encoded);
    outgoing.end();
  })
);

const startRouter = async (routerPort, upstreamPort) => {
  const child = spawn(process.execPath, [ROUTER], {
    cwd: ROOT,
    env: {
      ...process.env,
      HOME: temporary,
      GPTX_PORT: String(routerPort),
      GPTX_UPSTREAM_HOST: '127.0.0.1',
      GPTX_UPSTREAM_PORT: String(upstreamPort),
      GPTX_PROXY_KEY: 'effort-alias-test-key',
      GPTX_ADVISOR_STATE_FILE: path.join(temporary, 'advisor-state.json'),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`router readiness timeout\n${stderr}`));
    }, 5_000);
    const finish = (error = null) => {
      clearTimeout(timer);
      child.stderr.removeListener('data', onData);
      child.removeListener('exit', onExit);
      if (error) reject(error);
      else resolve();
    };
    const onData = () => {
      if (stderr.includes(`gptx-router listening on 127.0.0.1:${routerPort}`)) finish();
    };
    const onExit = (code, signal) => finish(new Error(
      `router exited before readiness (code=${code}, signal=${signal})\n${stderr}`,
    ));
    child.stderr.on('data', onData);
    child.once('exit', onExit);
  });

  return { child, logs: () => stderr };
};

const childExited = (child) => child.exitCode !== null || child.signalCode !== null;

const stopRouter = async (router) => {
  if (!router || childExited(router.child)) return;
  router.child.kill('SIGTERM');
  await Promise.race([
    new Promise((resolve) => router.child.once('exit', resolve)),
    new Promise((resolve) => setTimeout(resolve, 2_000)),
  ]);
  if (!childExited(router.child)) {
    router.child.kill('SIGKILL');
    await new Promise((resolve) => router.child.once('exit', resolve));
  }
};

const original = Buffer.from('{"model":"gpt-5.6-sol-medium", "messages":[]}');
const originalParsed = JSON.parse(original.toString('utf8'));
const anthropic = prepareForwardBody({
  lane: 'anthropic',
  parsedBody: originalParsed,
  body: original,
});
assert.strictEqual(anthropic.body, original);
assert.equal(anthropic.rewritten, false);
assert.equal(anthropic.executionModel, 'gpt-5.6-sol-medium');
assert.equal(anthropic.effort, null);
assert.equal(anthropic.effortSource, null);

const unknown = prepareForwardBody({
  lane: 'codex',
  parsedBody: { model: 'gpt-5.6-sol-ultra' },
  body: original,
});
assert.strictEqual(unknown.body, original);
assert.equal(unknown.rewritten, false);
assert.equal(executionModelFor('gpt-5.6-sol-medium'), EXECUTION_MODEL);
assert.equal(executionModelFor('gpt-5.6-sol'), 'gpt-5.6-sol');
// Terra aliases must resolve to terra, not to Sol. This is the assertion whose absence
// let a single hardcoded execution model stand.
assert.equal(executionModelFor('gpt-5.6-terra-xhigh'), 'gpt-5.6-terra');
assert.equal(executionModelFor('gpt-5.6-terra'), 'gpt-5.6-terra');
assert.notEqual(executionModelFor('gpt-5.6-terra-xhigh'), EXECUTION_MODEL);
// EFFORT_BY_ALIAS is derived from ALIAS_TABLE; assert it cannot drift out of step.
assert.deepEqual(
  EFFORT_BY_ALIAS,
  Object.fromEntries(Object.entries(ALIAS_TABLE).map(([a, e]) => [a, e.effort])),
);
// Every GPT agent's declared model must be an alias, and its frontmatter `effort:` must
// match what the router would inject. Read from the agent files rather than a hardcoded
// list, because the defect this guards against IS the two drifting apart: `gpt-terra`
// declared `effort: xhigh` against an unaliased model for as long as the alias table
// assumed one execution model.
{
  const agentsDir = path.join(ROOT, 'core-rules', 'agents');
  const agentFiles = fs.readdirSync(agentsDir).filter((name) => /^gpt-.*\.md$/.test(name));
  assert.ok(agentFiles.length >= 5, 'expected the GPT agent set to be present');
  for (const file of agentFiles) {
    const text = fs.readFileSync(path.join(agentsDir, file), 'utf8');
    const model = text.match(/^model:\s*(\S+)\s*$/m)?.[1];
    const effort = text.match(/^effort:\s*(\S+)\s*$/m)?.[1];
    assert.ok(model, `${file} declares no model`);
    assert.ok(
      Object.hasOwn(ALIAS_TABLE, model),
      `${file} declares model ${model}, which is not an alias — its effort would be cosmetic`,
    );
    if (effort) {
      assert.equal(
        ALIAS_TABLE[model].effort,
        effort,
        `${file} declares effort ${effort} but alias ${model} injects ${ALIAS_TABLE[model].effort}`,
      );
    }
    assert.notEqual(effort, 'max', `${file} must not declare max — xhigh is the ceiling`);
  }
}

for (const [profile, model, effort] of [
  ['gpt-mid', 'gpt-5.6-sol-medium', 'medium'],
  ['gpt-high', 'gpt-5.6-sol-high', 'high'],
  ['gpt-sol', 'gpt-5.6-sol-xhigh', 'xhigh'],
  ['gpt-sol-advisor', 'gpt-5.6-sol-xhigh', 'xhigh'],
]) {
  const source = fs.readFileSync(
    path.join(ROOT, 'core-rules', 'agents', `${profile}.md`),
    'utf8',
  );
  assert.match(source, new RegExp(`^model: ${model}$`, 'm'));
  assert.match(source, new RegExp(`^effort: ${effort}$`, 'm'));
}

let upstream = null;
let router = null;
const observed = [];

(async () => {
  try {
    upstream = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/v1/models') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ data: [] }));
        return;
      }
      const chunks = [];
      req.on('data', (chunk) => chunks.push(chunk));
      req.on('end', () => {
        const raw = Buffer.concat(chunks);
        observed.push({
          headers: { ...req.headers },
          raw,
          body: JSON.parse(raw.toString('utf8')),
        });
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          id: 'msg_effort_alias',
          type: 'message',
          role: 'assistant',
          content: [{ type: 'text', text: 'ok' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 1, output_tokens: 1 },
        }));
      });
    });
    const upstreamPort = await listen(upstream);
    const routerPort = await freePort();
    assert.notEqual(upstreamPort, 8317);
    assert.notEqual(routerPort, 8318);
    router = await startRouter(routerPort, upstreamPort);

    // Each alias must forward its OWN execution model. Asserting a single shared
    // constant here is what let the Sol-only assumption survive: a terra alias would
    // have passed a test that only checked "some rewrite happened".
    for (const [alias, entry] of Object.entries(ALIAS_TABLE)) {
      const payload = {
        model: alias,
        max_tokens: 32,
        output_config: { effort: 'xhigh', verbosity: 'low' },
        messages: [{ role: 'user', content: 'test' }],
      };
      const response = await request({ port: routerPort, body: payload });
      assert.equal(response.status, 200, response.raw);
      const capture = observed.shift();
      assert.ok(capture);
      assert.equal(capture.body.model, entry.executionModel);
      assert.notEqual(capture.body.model, alias, `alias ${alias} must be rewritten`);
      assert.equal(capture.body.output_config.effort, entry.effort);
      assert.equal(capture.body.output_config.verbosity, 'low');
      assert.equal(Number(capture.headers['content-length']), capture.raw.length);
    }

    for (const model of ['gpt-5.6-sol', 'gpt-5.6-sol-ultra']) {
      const payload = {
        model,
        max_tokens: 32,
        output_config: { effort: 'xhigh' },
        messages: [{ role: 'user', content: 'explicit override' }],
      };
      const expected = Buffer.from(JSON.stringify(payload));
      const response = await request({ port: routerPort, body: payload });
      assert.equal(response.status, 200, response.raw);
      const capture = observed.shift();
      assert.ok(capture);
      assert.equal(capture.raw.toString('utf8'), expected.toString('utf8'));
      assert.equal(Number(capture.headers['content-length']), expected.length);
    }

    const statusResponse = await request({
      port: routerPort,
      method: 'GET',
      requestPath: '/__gptx/status',
    });
    assert.equal(statusResponse.status, 200, statusResponse.raw);
    assert.equal(
      statusResponse.body.lanes.codex.effortAliases,
      Object.keys(ALIAS_TABLE).length,
    );
    // The last alias exercised above is the final ALIAS_TABLE key, so the receipt must
    // name a terra execution model — the case the single-constant version could not produce.
    const lastAlias = Object.keys(ALIAS_TABLE).at(-1);
    assert.deepEqual(statusResponse.body.lanes.codex.lastEffortReceipt, {
      at: statusResponse.body.lanes.codex.lastEffortReceipt.at,
      requested_model: lastAlias,
      execution_model: ALIAS_TABLE[lastAlias].executionModel,
      effective_effort: ALIAS_TABLE[lastAlias].effort,
      effort_source: 'profile-alias',
    });
    assert.match(statusResponse.body.lanes.codex.lastEffortReceipt.at, /^\d{4}-/);

    process.stdout.write('gptx-effort-alias: exact aliases, lengths, passthrough, and receipts passed\n');
  } catch (error) {
    if (router?.logs()) error.message += `\n--- isolated router log ---\n${router.logs()}`;
    throw error;
  } finally {
    await stopRouter(router);
    await closeServer(upstream);
    fs.rmSync(temporary, { recursive: true, force: true });
  }
})().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
