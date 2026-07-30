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

const openRequest = (port, requestPath, options = {}) => {
  const body = options.body ? Buffer.from(JSON.stringify(options.body)) : Buffer.alloc(0);
  let req;
  const promise = new Promise((resolve, reject) => {
    req = http.request({
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
  return { req, promise };
};

const request = (port, requestPath, options = {}) => openRequest(
  port,
  requestPath,
  options,
).promise;

const requestAndDisconnect = async (port, requestPath, options = {}) => {
  const opened = openRequest(port, requestPath, options);
  const disconnected = opened.promise.then(
    () => undefined,
    (error) => {
      if (!['ECONNRESET', 'ECONNREFUSED'].includes(error.code)) throw error;
    },
  );
  setTimeout(() => opened.req.destroy(), 15);
  await disconnected;
};

const proxyRequests = [];
const pendingMainResponses = [];
const advisorBehaviors = [];
const continuationBehaviors = [];
const activeChildResponses = new Set();
let canceledChildResponses = 0;
let failNextAdvisor = false;

const childResponse = (res, behavior, successBody) => {
  activeChildResponses.add(res);
  res.once('close', () => {
    activeChildResponses.delete(res);
    if (!res.writableEnded) canceledChildResponses++;
  });
  if (behavior?.type === 'hang') return;
  const send = () => {
    if (res.destroyed || res.writableEnded) return;
    if (behavior?.type === 'failure') {
      res.writeHead(behavior.status || 502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        type: 'error',
        error: { message: behavior.message || 'synthetic advisor failure' },
      }));
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(successBody));
  };
  if (behavior?.delayMs) setTimeout(send, behavior.delayMs);
  else send();
};

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
      childResponse(res, continuationBehaviors.shift(), {
        content: [{ type: 'text', text: 'Continued after advice.' }],
        stop_reason: 'end_turn',
        usage: { input_tokens: 40, output_tokens: 5 },
      });
      return;
    }
    if (req.headers['user-agent'] === 'trellis-gptx-advisor/1') {
      const behavior = failNextAdvisor
        ? { type: 'failure', status: 502 }
        : advisorBehaviors.shift();
      failNextAdvisor = false;
      childResponse(res, behavior, {
        content: [{ type: 'text', text: 'Use the narrow implementation.' }],
      });
      return;
    }
    if (req.headers['x-trellis-advisor-callback']) {
      pendingMainResponses.push(res);
      return;
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('event: message_stop\ndata: {"type":"message_stop"}\n\n');
  });
});

const finishPendingMains = () => {
  for (const response of pendingMainResponses.splice(0)) {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.end('event: message_stop\ndata: {"type":"message_stop"}\n\n');
  }
};

const waitFor = async (predicate, label) => {
  const deadline = Date.now() + 5000;
  while (!(await predicate())) {
    if (Date.now() >= deadline) throw new Error(`timeout waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
};

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
      GPTX_ADVISOR_TRANSACTION_DEADLINE_MS: '350',
      GPTX_ADVISOR_CONCURRENCY: '2',
      GPTX_ADVISOR_BREAKER_THRESHOLD: '3',
      GPTX_ADVISOR_BREAKER_WINDOW_MS: '2000',
      GPTX_ADVISOR_BREAKER_OPEN_MS: '150',
      TRELLIS_GPT_CONTEXT_WINDOW: '272000',
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });

  try {
    await waitForReady(child);
    const mainBody = {
      model: 'gpt-5.6-terra',
      stream: true,
      max_tokens: 8192,
      metadata: {
        user_id: JSON.stringify({ session_id: 'session-test-advisor' }),
      },
      system: [{
        type: 'text',
        text: `private-system-marker ${'system-catalog '.repeat(8000)}`,
      }],
      tools: [{ type: 'advisor_20260301', name: 'advisor' }],
      messages: [
        {
          role: 'user',
          content: `<system-reminder>private-reminder-marker ${'catalog '.repeat(8000)}</system-reminder>
Implement the bounded recovery.`,
        },
        {
          role: 'assistant',
          content: [
            { type: 'text', text: 'I inspected the router.' },
            { type: 'tool_use', name: 'Read', input: { file_path: 'scripts/gptx/router.js' } },
          ],
        },
        {
          role: 'user',
          content: [{ type: 'tool_result', content: 'The advisor timeout is 120 seconds.' }],
        },
      ],
    };
    const mainBodyFor = (sessionId) => ({
      ...mainBody,
      metadata: {
        user_id: JSON.stringify({ session_id: sessionId }),
      },
    });
    const openMain = (sessionId, headers = { 'x-trellis-advisor': 'sol' }) => openRequest(
      ROUTER_PORT,
      '/v1/messages',
      { method: 'POST', headers, body: mainBodyFor(sessionId) },
    );

    const mainPromise = request(ROUTER_PORT, '/v1/messages', {
      method: 'POST',
      headers: {
        authorization: 'Bearer anthropic-subscription-secret',
        'x-api-key': 'anthropic-api-secret',
        'x-trellis-mode': 'codex',
        'x-trellis-advisor': 'sol',
      },
      body: mainBody,
    });
    void mainPromise.catch(() => {});
    await waitFor(() => proxyRequests.length === 1, 'initial main request');
    assert.strictEqual(proxyRequests.length, 1);

    const callback = proxyRequests[0].headers['x-trellis-advisor-callback'];
    assert.match(callback, new RegExp(`^http://${HOST}:${ROUTER_PORT}/__gptx/advisor/`));
    assert.strictEqual(proxyRequests[0].headers.authorization, 'Bearer proxy-only-secret');
    assert.strictEqual(proxyRequests[0].headers['x-api-key'], undefined);
    assert.strictEqual(proxyRequests[0].headers['x-trellis-mode'], undefined);
    assert.strictEqual(proxyRequests[0].headers['x-trellis-advisor'], undefined);

    const callbackURL = new URL(callback);
    advisorBehaviors.push({ delayMs: 60 });
    const advisorRequestCount = proxyRequests.length;
    const [advisorResponse, concurrentDuplicate] = await Promise.all([
      request(ROUTER_PORT, callbackURL.pathname, {
        method: 'POST',
        body: { tool_use_id: 'srvtoolu_test', input: {} },
      }),
      request(ROUTER_PORT, callbackURL.pathname, {
        method: 'POST',
        body: { tool_use_id: 'srvtoolu_test_duplicate', input: {} },
      }),
    ]);
    assert.strictEqual(advisorResponse.status, 200, advisorResponse.body);
    assert.strictEqual(concurrentDuplicate.status, advisorResponse.status);
    assert.strictEqual(concurrentDuplicate.body, advisorResponse.body);
    assert.strictEqual(
      proxyRequests.length,
      advisorRequestCount + 2,
      'concurrent callback duplicate must share one advice and continuation',
    );
    assert.deepStrictEqual(JSON.parse(advisorResponse.body), {
      advisor_model: 'gpt-5.6-sol',
      content: [
        'Trellis advisor model: gpt-5.6-sol',
        'Trellis advisor selection: session-policy:sol',
        '',
        'Use the narrow implementation.',
      ].join('\n'),
      continuation: {
        content: [{ type: 'text', text: 'Continued after advice.' }],
        stop_reason: 'end_turn',
        usage: { input_tokens: 40, output_tokens: 5 },
      },
    });
    assert.strictEqual(proxyRequests.length, 3);
    assert.strictEqual(proxyRequests[1].body.model, 'gpt-5.6-sol');
    assert.strictEqual(proxyRequests[1].body.stream, false);
    assert.strictEqual(proxyRequests[1].body.max_tokens, 2048);
    assert(Buffer.byteLength(JSON.stringify(proxyRequests[1].body)) <= 64 * 1024);
    assert(JSON.stringify(proxyRequests[1].body).includes('Implement the bounded recovery.'));
    assert(JSON.stringify(proxyRequests[1].body).includes('The advisor timeout is 120 seconds.'));
    assert(!JSON.stringify(proxyRequests[1].body).includes('private-system-marker'));
    assert(!JSON.stringify(proxyRequests[1].body).includes('private-reminder-marker'));
    assert.strictEqual(proxyRequests[1].body.tools, undefined);
    assert.strictEqual(proxyRequests[1].headers.authorization, 'Bearer proxy-only-secret');
    assert.strictEqual(proxyRequests[2].body.model, 'gpt-5.6-terra');
    assert.strictEqual(proxyRequests[2].body.stream, false);
    assert(JSON.stringify(proxyRequests[2].body).includes('Trellis advisor model: gpt-5.6-sol'));
    assert.strictEqual(proxyRequests[2].headers.authorization, 'Bearer proxy-only-secret');
    assert(!JSON.stringify(proxyRequests[1].headers).includes('anthropic-subscription-secret'));
    assert(!JSON.stringify(proxyRequests[1].headers).includes('anthropic-api-secret'));
    assert(!JSON.stringify(proxyRequests[2].headers).includes('anthropic-subscription-secret'));
    assert(!JSON.stringify(proxyRequests[2].headers).includes('anthropic-api-secret'));

    const cachedRequestCount = proxyRequests.length;
    const cachedSuccess = await request(
      ROUTER_PORT,
      callbackURL.pathname,
      { method: 'POST', body: { tool_use_id: 'srvtoolu_cached_success', input: {} } },
    );
    assert.strictEqual(cachedSuccess.status, advisorResponse.status);
    assert.strictEqual(cachedSuccess.body, advisorResponse.body);
    assert.strictEqual(proxyRequests.length, cachedRequestCount, 'cached success must not rerun work');
    let status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    assert.strictEqual(status.advisor.transactions.deadlineMs, 350);
    assert.strictEqual(status.advisor.transactions.concurrency, 2);
    assert.strictEqual(status.advisor.transactions.succeeded, 1);
    assert.strictEqual(status.advisor.transactions.replayed, 2);

    finishPendingMains();
    const mainResponse = await mainPromise;
    assert.strictEqual(mainResponse.status, 200);

    const replay = await request(ROUTER_PORT, callbackURL.pathname, { method: 'POST' });
    assert.strictEqual(replay.status, 404, 'cache must drop when the original parent settles');

    const duplicateStart = proxyRequests.length;
    const duplicateOne = request(ROUTER_PORT, '/v1/messages', {
      method: 'POST',
      headers: { 'x-trellis-advisor': 'sol' },
      body: mainBody,
    });
    const duplicateTwo = request(ROUTER_PORT, '/v1/messages', {
      method: 'POST',
      headers: { 'x-trellis-advisor': 'sol' },
      body: mainBody,
    });
    void duplicateOne.catch(() => {});
    void duplicateTwo.catch(() => {});
    await waitFor(
      () => proxyRequests.length === duplicateStart + 2,
      'duplicate main requests',
    );
    const duplicateCallback = proxyRequests[duplicateStart].headers['x-trellis-advisor-callback'];
    assert.strictEqual(
      proxyRequests[duplicateStart + 1].headers['x-trellis-advisor-callback'],
      duplicateCallback,
      'same session retry must reuse one callback',
    );
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    assert.strictEqual(status.advisor.pendingCallbacks, 1);

    failNextAdvisor = true;
    const failedAdvisor = await request(
      ROUTER_PORT,
      new URL(duplicateCallback).pathname,
      { method: 'POST', body: { tool_use_id: 'srvtoolu_failure', input: {} } },
    );
    assert.strictEqual(failedAdvisor.status, 503);
    assert.match(failedAdvisor.body, /advisor upstream returned HTTP 502/);
    const failedRequestCount = proxyRequests.length;
    const cachedFailure = await request(
      ROUTER_PORT,
      new URL(duplicateCallback).pathname,
      { method: 'POST', body: { tool_use_id: 'srvtoolu_failure_replay', input: {} } },
    );
    assert.strictEqual(cachedFailure.status, failedAdvisor.status);
    assert.strictEqual(cachedFailure.body, failedAdvisor.body);
    assert.strictEqual(proxyRequests.length, failedRequestCount, 'cached failure must not rerun work');
    finishPendingMains();
    assert.strictEqual((await duplicateOne).status, 200);
    assert.strictEqual((await duplicateTwo).status, 200);
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    assert.strictEqual(status.advisor.pendingCallbacks, 0);

    const missingHeaderStart = proxyRequests.length;
    const missingHeaderMain = request(ROUTER_PORT, '/v1/messages', {
      method: 'POST',
      body: {
        ...mainBody,
        metadata: {
          user_id: JSON.stringify({ session_id: 'session-missing-advisor-header' }),
        },
      },
    });
    void missingHeaderMain.catch(() => {});
    await waitFor(
      () => proxyRequests.length === missingHeaderStart + 1,
      'headerless main request',
    );
    const missingHeaderCallback = proxyRequests[missingHeaderStart]
      .headers['x-trellis-advisor-callback'];
    assert.match(
      missingHeaderCallback,
      new RegExp(`^http://${HOST}:${ROUTER_PORT}/__gptx/advisor/`),
      'a GPT child that loses the advisor header must still receive a local callback',
    );
    const missingHeaderAdvisor = await request(
      ROUTER_PORT,
      new URL(missingHeaderCallback).pathname,
      { method: 'POST', body: { tool_use_id: 'srvtoolu_missing_header', input: {} } },
    );
    assert.strictEqual(missingHeaderAdvisor.status, 200, missingHeaderAdvisor.body);
    const missingHeaderResult = JSON.parse(missingHeaderAdvisor.body);
    assert.strictEqual(missingHeaderResult.advisor_model, 'gpt-5.6-sol');
    assert.match(missingHeaderResult.content, /^Trellis advisor model: gpt-5\.6-sol/m);
    assert.match(
      missingHeaderResult.content,
      /^Trellis advisor selection: missing-header-safe-default:sol/m,
    );
    assert.strictEqual(proxyRequests[missingHeaderStart + 1].body.model, 'gpt-5.6-sol');
    assert(JSON.stringify(proxyRequests[missingHeaderStart + 2].body)
      .includes('Trellis advisor selection: missing-header-safe-default:sol'));
    finishPendingMains();
    assert.strictEqual((await missingHeaderMain).status, 200);
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    assert.strictEqual(status.advisor.pendingCallbacks, 0);
    assert.strictEqual(status.advisor.missingHeaderSolDefaults, 1);
    assert.deepStrictEqual(
      {
        model: status.advisor.lastReceipt.model,
        selection: status.advisor.lastReceipt.selection,
      },
      {
        model: 'gpt-5.6-sol',
        selection: 'missing-header-safe-default:sol',
      },
    );

    const disabledStart = proxyRequests.length;
    const disabledMain = request(ROUTER_PORT, '/v1/messages', {
      method: 'POST',
      headers: { 'x-trellis-advisor': 'none' },
      body: {
        ...mainBody,
        metadata: {
          user_id: JSON.stringify({ session_id: 'session-explicit-advisor-none' }),
        },
      },
    });
    void disabledMain.catch(() => {});
    await waitFor(
      () => proxyRequests.length === disabledStart + 1,
      'explicit-none main request',
    );
    const disabledCallback = proxyRequests[disabledStart].headers['x-trellis-advisor-callback'];
    const disabledAdvisor = await request(
      ROUTER_PORT,
      new URL(disabledCallback).pathname,
      { method: 'POST', body: { tool_use_id: 'srvtoolu_disabled', input: {} } },
    );
    assert.strictEqual(disabledAdvisor.status, 503);
    assert.match(disabledAdvisor.body, /advisor disabled by explicit session policy/);
    assert.strictEqual(
      proxyRequests.length,
      disabledStart + 1,
      'explicit none must not execute an advisor or continuation upstream',
    );
    finishPendingMains();
    assert.strictEqual((await disabledMain).status, 200);
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    assert.strictEqual(
      status.advisor.pendingCallbacks,
      0,
      'the fail-closed explicit-none callback must be removed after use',
    );

    // A lost callback response is not authority to cancel work. The transaction
    // completes once, caches the exact response, and replays it on redelivery.
    const lossStart = proxyRequests.length;
    const lossMain = openMain('session-callback-response-loss');
    void lossMain.promise.catch(() => {});
    await waitFor(() => proxyRequests.length === lossStart + 1, 'response-loss main request');
    const lossCallback = new URL(
      proxyRequests[lossStart].headers['x-trellis-advisor-callback'],
    ).pathname;
    advisorBehaviors.push({ delayMs: 60 });
    const lossChildStart = proxyRequests.length;
    await requestAndDisconnect(ROUTER_PORT, lossCallback, {
      method: 'POST',
      body: { tool_use_id: 'srvtoolu_lost_response', input: {} },
    });
    await waitFor(
      () => proxyRequests.length === lossChildStart + 2 && activeChildResponses.size === 0,
      'lost callback transaction completion',
    );
    const recoveredDelivery = await request(ROUTER_PORT, lossCallback, {
      method: 'POST',
      body: { tool_use_id: 'srvtoolu_lost_response_retry', input: {} },
    });
    assert.strictEqual(recoveredDelivery.status, 200, recoveredDelivery.body);
    assert.match(recoveredDelivery.body, /Continued after advice/);
    assert.strictEqual(
      proxyRequests.length,
      lossChildStart + 2,
      'redelivery after response loss must replay cached work',
    );
    finishPendingMains();
    assert.strictEqual((await lossMain.promise).status, 200);

    // With concurrency two, the third callback waits in FIFO order. Its original
    // wall-clock deadline expires while queued, so it never reaches the provider.
    const queueMainStart = proxyRequests.length;
    const queueTarget = openMain('session-queue-target');
    void queueTarget.promise.catch(() => {});
    await waitFor(
      () => proxyRequests.length === queueMainStart + 1,
      'queue-expiry target main request',
    );
    // Give the queued target an earlier absolute deadline than both blockers.
    await new Promise((resolve) => setTimeout(resolve, 80));
    const queueBlockerOne = openMain('session-queue-blocker-one');
    const queueBlockerTwo = openMain('session-queue-blocker-two');
    const queuedMains = [queueTarget, queueBlockerOne, queueBlockerTwo];
    void queueBlockerOne.promise.catch(() => {});
    void queueBlockerTwo.promise.catch(() => {});
    await waitFor(
      () => proxyRequests.length === queueMainStart + 3,
      'three queued-transaction main requests',
    );
    const queuedCallbacks = proxyRequests
      .slice(queueMainStart, queueMainStart + 3)
      .map((entry) => new URL(entry.headers['x-trellis-advisor-callback']).pathname);
    advisorBehaviors.push({ type: 'hang' }, { type: 'hang' });
    const queuedChildStart = proxyRequests.length;
    const queuedOne = request(ROUTER_PORT, queuedCallbacks[1], {
      method: 'POST', body: { tool_use_id: 'srvtoolu_queue_blocker_one', input: {} },
    });
    await waitFor(() => proxyRequests.length === queuedChildStart + 1, 'first inflight advisor');
    const queuedTwo = request(ROUTER_PORT, queuedCallbacks[2], {
      method: 'POST', body: { tool_use_id: 'srvtoolu_queue_blocker_two', input: {} },
    });
    await waitFor(() => proxyRequests.length === queuedChildStart + 2, 'second inflight advisor');
    const queuedThree = request(ROUTER_PORT, queuedCallbacks[0], {
      method: 'POST', body: { tool_use_id: 'srvtoolu_queue_target', input: {} },
    });
    await waitFor(async () => {
      const current = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
      return current.advisor.transactions.queued === 1;
    }, 'third advisor queued');
    const queuedResults = await Promise.all([queuedOne, queuedTwo, queuedThree]);
    for (const result of queuedResults) assert.strictEqual(result.status, 503, result.body);
    assert.strictEqual(JSON.parse(queuedResults[2].body).error.stage, 'queue');
    assert.strictEqual(
      proxyRequests.length,
      queuedChildStart + 2,
      'queue-expired callback must not reach the provider',
    );
    await waitFor(() => activeChildResponses.size === 0, 'timed-out child sockets destroyed');
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    assert.strictEqual(status.advisor.transactions.queued, 0);
    assert.strictEqual(status.advisor.transactions.inflight, 0);
    assert(status.advisor.transactions.timedOut >= 3);
    finishPendingMains();
    for (const opened of queuedMains) assert.strictEqual((await opened.promise).status, 200);

    // Advice and continuation share one absolute deadline. The continuation gets
    // only the remainder and is destroyed rather than receiving a fresh timer.
    const spanStart = proxyRequests.length;
    const spanMain = openMain('session-deadline-spans-stages');
    void spanMain.promise.catch(() => {});
    await waitFor(() => proxyRequests.length === spanStart + 1, 'spanning-deadline main');
    advisorBehaviors.push({ delayMs: 225 });
    continuationBehaviors.push({ delayMs: 225 });
    const spanCallback = new URL(
      proxyRequests[spanStart].headers['x-trellis-advisor-callback'],
    ).pathname;
    const spanResult = await request(ROUTER_PORT, spanCallback, {
      method: 'POST', body: { tool_use_id: 'srvtoolu_span', input: {} },
    });
    assert.strictEqual(spanResult.status, 503, spanResult.body);
    const spanError = JSON.parse(spanResult.body).error;
    assert.strictEqual(spanError.code, 'ADVISOR_TRANSACTION_TIMEOUT');
    assert.strictEqual(spanError.stage, 'continuation');
    await waitFor(() => activeChildResponses.size === 0, 'continuation deadline socket cleanup');
    finishPendingMains();
    assert.strictEqual((await spanMain.promise).status, 200);

    // Only the original outer request can cancel. Its disconnect aborts a running
    // child request and removes the callback; callback-delivery disconnects above did not.
    const cancelStart = proxyRequests.length;
    const canceledMain = openMain('session-parent-cancel');
    void canceledMain.promise.catch(() => {});
    await waitFor(() => proxyRequests.length === cancelStart + 1, 'cancelable parent request');
    advisorBehaviors.push({ type: 'hang' });
    const cancelCallback = new URL(
      proxyRequests[cancelStart].headers['x-trellis-advisor-callback'],
    ).pathname;
    const canceledChildrenBefore = canceledChildResponses;
    const canceledDelivery = request(ROUTER_PORT, cancelCallback, {
      method: 'POST', body: { tool_use_id: 'srvtoolu_parent_cancel', input: {} },
    });
    await waitFor(() => activeChildResponses.size === 1, 'running child before parent cancel');
    canceledMain.req.destroy();
    const canceledResult = await canceledDelivery;
    assert.strictEqual(canceledResult.status, 503, canceledResult.body);
    assert.strictEqual(JSON.parse(canceledResult.body).error.code, 'ADVISOR_PARENT_CANCELED');
    await waitFor(
      () => activeChildResponses.size === 0 && canceledChildResponses > canceledChildrenBefore,
      'parent cancellation child cleanup',
    );
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    assert.strictEqual(status.advisor.pendingCallbacks, 0);
    assert(status.advisor.transactions.canceled >= 1);
    const breakerAfterCancellation = status.advisor.breakers.entries.find(
      (entry) => entry.provider === 'sol' && entry.stage === 'advice',
    );
    assert.notStrictEqual(
      breakerAfterCancellation?.state,
      'open',
      'local cancellation/deadline must not count as provider transport failure',
    );

    // Three matching explicit-Sol 503s open only the sol+advice breaker. The
    // fourth explicit call fails before provider admission. After the open window,
    // exactly one half-open probe runs; a concurrent probe fast-fails.
    for (let index = 0; index < 3; index++) {
      const breakerStart = proxyRequests.length;
      const breakerMain = openMain(`session-breaker-failure-${index}`);
      void breakerMain.promise.catch(() => {});
      await waitFor(
        () => proxyRequests.length === breakerStart + 1,
        `breaker failure main ${index}`,
      );
      advisorBehaviors.push({ type: 'failure', status: 503, message: 'matching breaker failure' });
      const breakerCallback = new URL(
        proxyRequests[breakerStart].headers['x-trellis-advisor-callback'],
      ).pathname;
      const breakerFailure = await request(ROUTER_PORT, breakerCallback, {
        method: 'POST', body: { tool_use_id: `srvtoolu_breaker_${index}`, input: {} },
      });
      assert.strictEqual(breakerFailure.status, 503, breakerFailure.body);
      finishPendingMains();
      assert.strictEqual((await breakerMain.promise).status, 200);
    }
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    let solBreaker = status.advisor.breakers.entries.find(
      (entry) => entry.provider === 'sol' && entry.stage === 'advice',
    );
    assert.strictEqual(solBreaker.state, 'open');

    const openCircuitStart = proxyRequests.length;
    const openCircuitMain = openMain('session-breaker-open-fast-fail');
    void openCircuitMain.promise.catch(() => {});
    await waitFor(
      () => proxyRequests.length === openCircuitStart + 1,
      'open-circuit main request',
    );
    const openCircuitCallback = new URL(
      proxyRequests[openCircuitStart].headers['x-trellis-advisor-callback'],
    ).pathname;
    const requestsBeforeFastFail = proxyRequests.length;
    const openCircuitResult = await request(ROUTER_PORT, openCircuitCallback, {
      method: 'POST', body: { tool_use_id: 'srvtoolu_breaker_open', input: {} },
    });
    assert.strictEqual(openCircuitResult.status, 503, openCircuitResult.body);
    assert.strictEqual(JSON.parse(openCircuitResult.body).error.code, 'ADVISOR_CIRCUIT_OPEN');
    assert.strictEqual(proxyRequests.length, requestsBeforeFastFail);
    const cachedOpenCircuit = await request(ROUTER_PORT, openCircuitCallback, {
      method: 'POST', body: { tool_use_id: 'srvtoolu_breaker_open_replay', input: {} },
    });
    assert.strictEqual(cachedOpenCircuit.status, openCircuitResult.status);
    assert.strictEqual(cachedOpenCircuit.body, openCircuitResult.body);
    assert.strictEqual(proxyRequests.length, requestsBeforeFastFail);
    finishPendingMains();
    assert.strictEqual((await openCircuitMain.promise).status, 200);

    await new Promise((resolve) => setTimeout(resolve, 180));
    const halfOpenStart = proxyRequests.length;
    const halfOpenProbe = openMain('session-breaker-half-open-probe');
    const halfOpenDuplicate = openMain('session-breaker-half-open-duplicate');
    void halfOpenProbe.promise.catch(() => {});
    void halfOpenDuplicate.promise.catch(() => {});
    await waitFor(
      () => proxyRequests.length === halfOpenStart + 2,
      'half-open parent requests',
    );
    const halfOpenCallbacks = proxyRequests
      .slice(halfOpenStart, halfOpenStart + 2)
      .map((entry) => new URL(entry.headers['x-trellis-advisor-callback']).pathname);
    advisorBehaviors.push({ delayMs: 60 });
    const halfOpenChildStart = proxyRequests.length;
    const probeResultPromise = request(ROUTER_PORT, halfOpenCallbacks[0], {
      method: 'POST', body: { tool_use_id: 'srvtoolu_half_open_probe', input: {} },
    });
    await waitFor(
      () => proxyRequests.length === halfOpenChildStart + 1,
      'half-open provider probe',
    );
    const rejectedProbe = await request(ROUTER_PORT, halfOpenCallbacks[1], {
      method: 'POST', body: { tool_use_id: 'srvtoolu_half_open_duplicate', input: {} },
    });
    assert.strictEqual(rejectedProbe.status, 503, rejectedProbe.body);
    assert.strictEqual(JSON.parse(rejectedProbe.body).error.code, 'ADVISOR_CIRCUIT_OPEN');
    assert.strictEqual(proxyRequests.length, halfOpenChildStart + 1);
    const probeResult = await probeResultPromise;
    assert.strictEqual(probeResult.status, 200, probeResult.body);
    finishPendingMains();
    assert.strictEqual((await halfOpenProbe.promise).status, 200);
    assert.strictEqual((await halfOpenDuplicate.promise).status, 200);
    status = JSON.parse((await request(ROUTER_PORT, '/__gptx/status')).body);
    solBreaker = status.advisor.breakers.entries.find(
      (entry) => entry.provider === 'sol' && entry.stage === 'advice',
    );
    assert.strictEqual(solBreaker.state, 'closed');
    assert.strictEqual(status.advisor.pendingCallbacks, 0);
    assert.strictEqual(status.advisor.transactions.queued, 0);
    assert.strictEqual(status.advisor.transactions.inflight, 0);
    const sanitizedStatus = JSON.stringify({
      transactions: status.advisor.transactions,
      breakers: status.advisor.breakers,
    });
    assert(!sanitizedStatus.includes('private-system-marker'));
    assert(!sanitizedStatus.includes('Use the narrow implementation.'));
    assert.strictEqual(activeChildResponses.size, 0, 'no advisor child response may remain orphaned');

    const ordinary = await request(ROUTER_PORT, '/v1/messages', {
      method: 'POST',
      body: {
        model: 'gpt-5.6-sol',
        stream: true,
        max_tokens: 16,
        messages: [{ role: 'user', content: 'Reply OK.' }],
      },
    });
    assert.strictEqual(ordinary.status, 200, ordinary.body);

    process.stdout.write('gptx-advisor-router: bounded context, child fallback, identity, cleanup, and recovery passed\n');
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
