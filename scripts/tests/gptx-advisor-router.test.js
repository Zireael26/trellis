#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HOST = '127.0.0.1';
const ROUTER_PORT = 19318;
const PROXY_PORT = 19317;
const ROUTER = path.join(__dirname, '..', 'gptx', 'router.js');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'trellis-advisor-router-'));

const request = (port, requestPath, options = {}) => new Promise((resolve, reject) => {
  const body = options.body ? Buffer.from(JSON.stringify(options.body)) : Buffer.alloc(0);
  const req = http.request({
    hostname: HOST,
    port,
    path: requestPath,
    method: options.method || 'GET',
    headers: {
      ...(body.length ? {
        'content-type': 'application/json',
        'content-length': body.length,
      } : {}),
      ...(options.headers || {}),
    },
  }, (res) => {
    const chunks = [];
    res.on('data', (chunk) => chunks.push(chunk));
    res.on('end', () => resolve({
      status: res.statusCode,
      headers: res.headers,
      body: Buffer.concat(chunks).toString('utf8'),
    }));
  });
  req.on('error', reject);
  req.end(body);
});

const proxyRequests = [];
const proxy = http.createServer((req, res) => {
  if (req.url === '/v1/models') {
    req.resume();
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"data":[]}');
    return;
  }
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    proxyRequests.push({ headers: req.headers, body });
    if (req.headers['user-agent'] === 'trellis-gptx-advisor-continuation/1') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        content: [{ type: 'text', text: 'Continued after advice.' }],
        stop_reason: 'end_turn',
        usage: { input_tokens: 40, output_tokens: 5 },
      }));
      return;
    }
    if (body.stream === false) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        content: [{ type: 'text', text: 'Use the narrow implementation.' }],
      }));
      return;
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('event: message_stop\ndata: {"type":"message_stop"}\n\n');
  });
});

const waitForReady = (child) => new Promise((resolve, reject) => {
  let stderr = '';
  const timer = setTimeout(() => reject(new Error(`router readiness timeout\n${stderr}`)), 5000);
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
    if (stderr.includes(`listening on 127.0.0.1:${ROUTER_PORT}`)) {
      clearTimeout(timer);
      resolve();
    }
  });
  child.on('exit', (code) => {
    clearTimeout(timer);
    reject(new Error(`router exited ${code}\n${stderr}`));
  });
});

const main = async () => {
  await new Promise((resolve) => proxy.listen(PROXY_PORT, HOST, resolve));
  const child = spawn(process.execPath, [ROUTER], {
    env: {
      ...process.env,
      GPTX_PORT: String(ROUTER_PORT),
      GPTX_UPSTREAM_HOST: HOST,
      GPTX_UPSTREAM_PORT: String(PROXY_PORT),
      GPTX_PROXY_KEY: 'proxy-only-secret',
      GPTX_ADVISOR_STATE_FILE: path.join(temporary, 'advisor-state.json'),
      TRELLIS_GPT_CONTEXT_WINDOW: '272000',
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });

  try {
    await waitForReady(child);
    const mainResponse = await request(ROUTER_PORT, '/v1/messages', {
      method: 'POST',
      headers: {
        authorization: 'Bearer anthropic-subscription-secret',
        'x-api-key': 'anthropic-api-secret',
        'x-trellis-mode': 'codex',
        'x-trellis-advisor': 'sol',
      },
      body: {
        model: 'gpt-5.6-terra',
        stream: true,
        max_tokens: 128,
        tools: [{ type: 'advisor_20260301', name: 'advisor' }],
        messages: [{ role: 'user', content: 'Advise once.' }],
      },
    });
    assert.strictEqual(mainResponse.status, 200);
    assert.strictEqual(proxyRequests.length, 1);

    const callback = proxyRequests[0].headers['x-trellis-advisor-callback'];
    assert.match(callback, new RegExp(`^http://${HOST}:${ROUTER_PORT}/__gptx/advisor/`));
    assert.strictEqual(proxyRequests[0].headers.authorization, 'Bearer proxy-only-secret');
    assert.strictEqual(proxyRequests[0].headers['x-api-key'], undefined);
    assert.strictEqual(proxyRequests[0].headers['x-trellis-mode'], undefined);
    assert.strictEqual(proxyRequests[0].headers['x-trellis-advisor'], undefined);

    const callbackURL = new URL(callback);
    const advisorResponse = await request(ROUTER_PORT, callbackURL.pathname, {
      method: 'POST',
      body: { tool_use_id: 'srvtoolu_test', input: {} },
    });
    assert.strictEqual(advisorResponse.status, 200, advisorResponse.body);
    assert.deepStrictEqual(JSON.parse(advisorResponse.body), {
      advisor_model: 'gpt-5.6-sol',
      content: 'Use the narrow implementation.',
      continuation: {
        content: [{ type: 'text', text: 'Continued after advice.' }],
        stop_reason: 'end_turn',
        usage: { input_tokens: 40, output_tokens: 5 },
      },
    });
    assert.strictEqual(proxyRequests.length, 3);
    assert.strictEqual(proxyRequests[1].body.model, 'gpt-5.6-sol');
    assert.strictEqual(proxyRequests[1].body.stream, false);
    assert.strictEqual(proxyRequests[1].headers.authorization, 'Bearer proxy-only-secret');
    assert.strictEqual(proxyRequests[2].body.model, 'gpt-5.6-terra');
    assert.strictEqual(proxyRequests[2].body.stream, false);
    assert.strictEqual(proxyRequests[2].headers.authorization, 'Bearer proxy-only-secret');
    assert(!JSON.stringify(proxyRequests[1].headers).includes('anthropic-subscription-secret'));
    assert(!JSON.stringify(proxyRequests[1].headers).includes('anthropic-api-secret'));
    assert(!JSON.stringify(proxyRequests[2].headers).includes('anthropic-subscription-secret'));
    assert(!JSON.stringify(proxyRequests[2].headers).includes('anthropic-api-secret'));

    const replay = await request(ROUTER_PORT, callbackURL.pathname, { method: 'POST' });
    assert.strictEqual(replay.status, 404, 'advisor callback must be single use');
    process.stdout.write('gptx-advisor-router: credential boundary and Sol callback passed\n');
  } finally {
    child.kill('SIGKILL');
    await new Promise((resolve) => proxy.close(resolve));
    fs.rmSync(temporary, { recursive: true, force: true });
  }
};

main().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exitCode = 1;
});
