#!/usr/bin/env node
'use strict';

const assert = require('assert');
const http = require('http');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');

const HOST = '127.0.0.1';
const ROUTER_PORT = 18318;
const UPSTREAM_PORT = 18317;
const ROUTER_PATH = path.join(__dirname, '..', 'gptx', 'router.js');
const MODEL = 'gpt-5.6-sol';
const REQUEST_PATH = '/v1/messages';
const OP_TIMEOUT_MS = 5_000;

// These fixed guards make it impossible for an edit to silently point this test at
// the live router (8318) or its live upstream (8317).
assert.notStrictEqual(ROUTER_PORT, 8318, 'test router port must not be production port 8318');
assert.notStrictEqual(UPSTREAM_PORT, 8317, 'fake upstream port must not be production port 8317');

const MESSAGE_START =
  'event: message_start\n' +
  'data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","model":"gpt-5.6-sol","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0}}}\n\n';

const ERROR_FRAME =
  '\nevent: error\n' +
  'data: {"type":"error","error":{"type":"api_error","message":"stream error: stream ID 1; INTERNAL_ERROR; received from peer"}}\n\n';

const MESSAGE_STOP =
  'event: message_stop\n' +
  'data: {"type":"message_stop"}\n\n';

const PROSE_DELTA =
  'event: content_block_delta\n' +
  `data: ${JSON.stringify({
    type: 'content_block_delta',
    index: 0,
    delta: {
      type: 'text_delta',
      text: 'A model may literally emit event: error or {"type":"error"} while explaining SSE.',
    },
  })}\n\n`;

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let activeChild = null;
let activeFake = null;

const emergencyCleanup = () => {
  if (activeChild && activeChild.exitCode === null && activeChild.signalCode === null) {
    try { activeChild.kill('SIGKILL'); } catch {}
  }
  if (activeFake) {
    for (const socket of activeFake.sockets) {
      try { socket.destroy(); } catch {}
    }
  }
};

process.on('exit', emergencyCleanup);
process.on('SIGINT', () => {
  emergencyCleanup();
  process.exit(130);
});
process.on('SIGTERM', () => {
  emergencyCleanup();
  process.exit(143);
});

const assertPortFree = (port) => new Promise((resolve, reject) => {
  const probe = net.createServer();
  probe.unref();
  probe.once('error', (error) => {
    reject(new Error(`refusing to run: ${HOST}:${port} is not free (${error.code || error.message})`));
  });
  probe.listen(port, HOST, () => {
    probe.close((error) => error ? reject(error) : resolve());
  });
});

const createFakeUpstream = async (behavior) => {
  const sockets = new Set();
  const state = { error: null };

  const server = http.createServer((req, res) => {
    req.on('error', () => {});
    res.on('error', () => {});

    if (req.url === '/v1/models') {
      req.resume();
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"data":[]}');
      return;
    }

    if (req.url !== REQUEST_PATH || req.method !== 'POST') {
      req.resume();
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{"error":"unexpected fake-upstream request"}');
      return;
    }

    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        assert.strictEqual(body.model, MODEL, 'router sent the wrong model to the codex upstream');
      } catch (error) {
        state.error = error;
        res.destroy();
        return;
      }

      Promise.resolve(behavior(res)).catch((error) => {
        state.error = error;
        try { res.destroy(); } catch {}
      });
    });
  });

  server.on('connection', (socket) => {
    socket.setNoDelay(true);
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => {});
  });
  server.on('clientError', (_error, socket) => socket.destroy());

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(UPSTREAM_PORT, HOST, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });

  return { server, sockets, state };
};

const closeFakeUpstream = async (fake) => {
  if (!fake) return;
  if (typeof fake.server.closeAllConnections === 'function') fake.server.closeAllConnections();
  for (const socket of fake.sockets) socket.destroy();
  if (!fake.server.listening) return;
  await new Promise((resolve) => fake.server.close(() => resolve()));
};

const startRouter = async () => {
  const child = spawn(process.execPath, [ROUTER_PATH], {
    env: {
      ...process.env,
      GPTX_PORT: String(ROUTER_PORT),
      GPTX_UPSTREAM_HOST: HOST,
      GPTX_UPSTREAM_PORT: String(UPSTREAM_PORT),
      GPTX_DEBUG: '1',
      GPTX_PROXY_KEY: 'test-only-proxy-key',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
  const logs = () => [stdout.trim(), stderr.trim()].filter(Boolean).join('\n');

  activeChild = child;
  try {
    await new Promise((resolve, reject) => {
      let finished = false;
      const finish = (fn, value) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        fn(value);
      };
      const timer = setTimeout(() => {
        finish(reject, new Error(`isolated router did not become ready within ${OP_TIMEOUT_MS}ms\n${logs()}`));
      }, OP_TIMEOUT_MS);

      child.on('error', (error) => finish(reject, error));
      child.on('exit', (code, signal) => {
        finish(reject, new Error(`isolated router exited before readiness (code=${code}, signal=${signal})\n${logs()}`));
      });
      child.stderr.on('data', () => {
        if (stderr.includes(`gptx-router listening on ${HOST}:${ROUTER_PORT}`)) finish(resolve);
      });
    });
  } catch (error) {
    // A startup failure must not leave an isolated child behind to poison later cases.
    if (child.exitCode === null && child.signalCode === null) {
      const exited = new Promise((resolve) => child.once('exit', resolve));
      child.kill('SIGKILL');
      try {
        await Promise.race([
          exited,
          delay(2_000).then(() => { throw new Error(`PID ${child.pid} did not exit after SIGKILL`); }),
        ]);
      } catch (cleanupError) {
        error.message += `\n--- startup cleanup error ---\n${cleanupError.message}`;
      }
    }
    if (activeChild === child) activeChild = null;
    throw error;
  }

  return { child, logs };
};

const stopRouter = async (router) => {
  if (!router) return;
  const { child } = router;
  if (child.exitCode !== null || child.signalCode !== null) return;

  const exited = new Promise((resolve) => child.once('exit', resolve));
  child.kill('SIGKILL');
  await Promise.race([
    exited,
    delay(2_000).then(() => { throw new Error(`isolated router PID ${child.pid} did not exit after SIGKILL`); }),
  ]);
};

const requestStream = ({ abortOnError = false } = {}) => new Promise((resolve, reject) => {
  const body = JSON.stringify({ model: MODEL, stream: true, max_tokens: 16, messages: [] });
  let responseBody = '';
  let intentionallyAborted = false;
  let finished = false;

  const finish = (error, value) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    if (error) reject(error);
    else resolve(value);
  };

  const req = http.request({
    hostname: HOST,
    port: ROUTER_PORT,
    path: REQUEST_PATH,
    method: 'POST',
    agent: false,
    headers: {
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    },
  }, (res) => {
    if (res.statusCode !== 200) {
      finish(new Error(`isolated router returned HTTP ${res.statusCode}`));
      res.resume();
      return;
    }

    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      responseBody += chunk;
      if (abortOnError && !intentionallyAborted &&
          (responseBody.includes('\nevent: error') || responseBody.includes('data: {"type":"error"'))) {
        intentionallyAborted = true;
        res.destroy();
      }
    });
    res.on('end', () => {
      if (abortOnError) {
        finish(new Error('client never saw the error frame before the stream ended'));
      } else {
        finish(null, responseBody);
      }
    });
    res.on('close', () => {
      if (intentionallyAborted) finish(null, responseBody);
      else if (!finished && !res.complete) finish(new Error('stream response closed before end'));
    });
    res.on('error', (error) => {
      if (intentionallyAborted) finish(null, responseBody);
      else finish(error);
    });
  });

  const timer = setTimeout(() => {
    req.destroy();
    finish(new Error(`stream request timed out after ${OP_TIMEOUT_MS}ms`));
  }, OP_TIMEOUT_MS);

  req.on('error', (error) => {
    if (intentionallyAborted) finish(null, responseBody);
    else finish(error);
  });
  req.end(body);
});

const getStatus = () => new Promise((resolve, reject) => {
  const req = http.get({
    hostname: HOST,
    port: ROUTER_PORT,
    path: '/__gptx/status',
    agent: false,
  }, (res) => {
    const chunks = [];
    res.on('data', (chunk) => chunks.push(chunk));
    res.on('end', () => {
      clearTimeout(timer);
      if (res.statusCode !== 200) {
        reject(new Error(`status endpoint returned HTTP ${res.statusCode}`));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch (error) {
        reject(new Error(`status endpoint returned invalid JSON: ${error.message}`));
      }
    });
  });

  const timer = setTimeout(() => {
    req.destroy();
    reject(new Error(`status request timed out after ${OP_TIMEOUT_MS}ms`));
  }, OP_TIMEOUT_MS);
  req.on('error', (error) => {
    clearTimeout(timer);
    reject(error);
  });
});

const waitForRouterToSettle = async () => {
  const deadline = Date.now() + OP_TIMEOUT_MS;
  let last = null;

  while (Date.now() < deadline) {
    last = await getStatus();
    const codex = last.lanes.codex;
    if (codex.requests === 1 && codex.inflight === 0) return getStatus();
    await delay(25);
  }

  const observed = last && last.lanes && last.lanes.codex;
  throw new Error(`router never settled the request; last codex stats: ${JSON.stringify(observed)}`);
};

const pickCounters = (status) => {
  const lane = status.lanes.codex;
  return {
    requests: lane.requests,
    errors: lane.errors,
    cut: lane.cut,
    streamErr: lane.streamErr,
    aborted: lane.aborted,
  };
};

const runCase = async (testCase) => {
  let fake = null;
  let router = null;
  let primaryError = null;

  try {
    await assertPortFree(ROUTER_PORT);
    fake = await createFakeUpstream(testCase.upstream);
    activeFake = fake;

    router = await startRouter();
    activeChild = router.child;

    const responseBody = await requestStream({ abortOnError: testCase.abortOnError });
    assert.ok(responseBody.includes(testCase.expectedClientMarker),
      `client did not receive expected marker ${JSON.stringify(testCase.expectedClientMarker)}`);

    const status = await waitForRouterToSettle();
    assert.strictEqual(status.port, ROUTER_PORT, 'status came from a router on the wrong port');
    assert.deepStrictEqual(pickCounters(status), testCase.expectedCounters);
    assert.strictEqual(
      status.upstream.codexConsecutiveErrors,
      testCase.expectedConsecutiveErrors,
      'unexpected codexConsecutiveErrors value',
    );

    if (fake.state.error) throw fake.state.error;
  } catch (error) {
    primaryError = error;
    if (router && router.logs()) {
      error.message += `\n--- isolated router log ---\n${router.logs()}`;
    }
    throw error;
  } finally {
    let cleanupError = null;
    try {
      await stopRouter(router);
    } catch (error) {
      cleanupError = error;
    } finally {
      if (activeChild === (router && router.child)) activeChild = null;
    }

    try {
      await closeFakeUpstream(fake);
    } catch (error) {
      if (cleanupError) cleanupError.message += `\n--- fake-upstream cleanup error ---\n${error.message}`;
      else cleanupError = error;
    } finally {
      if (activeFake === fake) activeFake = null;
    }

    if (cleanupError) {
      if (primaryError) primaryError.message += `\n--- cleanup error ---\n${cleanupError.message}`;
      else throw cleanupError;
    }
  }
};

const sseHeaders = (res) => {
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  });
  res.flushHeaders();
};

const CASES = [
  {
    name: 'mid-stream error, upstream ends normally',
    abortOnError: false,
    expectedClientMarker: 'event: error',
    expectedCounters: { requests: 1, errors: 1, cut: 0, streamErr: 1, aborted: 0 },
    expectedConsecutiveErrors: 1,
    upstream: async (res) => {
      sseHeaders(res);
      res.write(MESSAGE_START);
      await delay(10);
      res.write(ERROR_FRAME);
      res.end();
    },
  },
  {
    name: 'mid-stream error, client hangs up first',
    abortOnError: true,
    expectedClientMarker: 'event: error',
    expectedCounters: { requests: 1, errors: 1, cut: 0, streamErr: 1, aborted: 0 },
    expectedConsecutiveErrors: 1,
    upstream: async (res) => {
      sseHeaders(res);
      res.write(MESSAGE_START);
      await delay(10);
      // Deliberately leave the upstream open after this frame. The downstream client
      // destroys its socket, so res.on('close') in the router must attribute the close
      // using sawErr instead of counting it as an abort.
      res.write(ERROR_FRAME);
    },
  },
  {
    name: 'clean stream',
    abortOnError: false,
    expectedClientMarker: 'message_stop',
    expectedCounters: { requests: 1, errors: 0, cut: 0, streamErr: 0, aborted: 0 },
    expectedConsecutiveErrors: 0,
    upstream: async (res) => {
      sseHeaders(res);
      res.write(MESSAGE_START);
      await delay(10);
      res.write(MESSAGE_STOP);
      res.end();
    },
  },
  {
    name: 'error marker split across chunks',
    abortOnError: false,
    expectedClientMarker: 'event: error',
    expectedCounters: { requests: 1, errors: 1, cut: 0, streamErr: 1, aborted: 0 },
    expectedConsecutiveErrors: 1,
    upstream: async (res) => {
      sseHeaders(res);
      // Put the raw LF and the first half of the framed marker in the earlier chunk.
      res.write(MESSAGE_START + 'eve');
      await delay(50);
      // Do not include the alternate `data: {"type":"error"` marker here: this case
      // must pass specifically because the carry buffer rejoins "\nevent: error".
      res.write('nt: error\ndata: {"error":{"type":"api_error","message":"split marker"}}\n\n');
      res.end();
    },
  },
  {
    name: 'escaped error text in assistant prose is clean',
    abortOnError: false,
    expectedClientMarker: 'event: error',
    expectedCounters: { requests: 1, errors: 0, cut: 0, streamErr: 0, aborted: 0 },
    expectedConsecutiveErrors: 0,
    upstream: async (res) => {
      sseHeaders(res);
      res.write(MESSAGE_START);
      await delay(10);
      // JSON.stringify keeps both apparent markers inside the text_delta JSON string:
      // there is no raw LF before `event: error`, and the quoted type is escaped.
      res.write(PROSE_DELTA);
      res.write(MESSAGE_STOP);
      res.end();
    },
  },
];

const main = async () => {
  await assertPortFree(UPSTREAM_PORT);
  await assertPortFree(ROUTER_PORT);

  let failures = 0;
  for (let index = 0; index < CASES.length; index++) {
    const testCase = CASES[index];
    try {
      await runCase(testCase);
      console.log(`PASS ${index + 1}/${CASES.length} - ${testCase.name}`);
    } catch (error) {
      failures++;
      console.error(`FAIL ${index + 1}/${CASES.length} - ${testCase.name}`);
      console.error(String(error && error.stack || error));
    }
  }

  if (failures) {
    console.error(`FAIL ${failures}/${CASES.length} case(s) failed`);
    process.exitCode = 1;
  } else {
    console.log(`PASS all ${CASES.length} stream error acceptance cases`);
  }
};

main().catch((error) => {
  console.error(`FAIL test harness - ${error && error.stack || error}`);
  process.exitCode = 1;
});
