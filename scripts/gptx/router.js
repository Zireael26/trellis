#!/usr/bin/env node
/*
 * gptx-router — model-name router for Claude Code (spec 020).
 *
 *   model = gpt-* | codex-* | *-sol|terra|luna  ->  CLIProxyAPI (127.0.0.1:8317)
 *                                                   Keychain key injected
 *   everything else                             ->  api.anthropic.com, byte-for-byte
 *
 * The Anthropic lane is a dumb pipe on purpose: Claude Code sends its subscription
 * OAuth bearer through a custom base URL (verified), and passing the request through
 * untouched preserves cache_control blocks, the context-1m beta, and effort
 * passthrough — all of which a re-serializing provider drops silently.
 *
 * The GPT list is closed and the Anthropic list is open. Unknown models, unresolved
 * aliases, and unknown paths all default to Anthropic; that asymmetry is what keeps
 * Claude-pinned internals (security-review, code-review) working in a session that
 * also runs GPT agents.
 *
 * Public transport implementation. Provider credentials are loaded only at runtime
 * and are never written to Trellis files or forwarded across provider lanes.
 */
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

const PORT = Number(process.env.GPTX_PORT || 8318);
const GPT_HOST = process.env.GPTX_UPSTREAM_HOST || '127.0.0.1';
const GPT_PORT = Number(process.env.GPTX_UPSTREAM_PORT || 8317);
const AUTH_DIR = path.join(os.homedir(), '.cli-proxy-api');
const BASELINE = path.join(AUTH_DIR, 'gptx-baseline.json');
const ADVISOR_STATE_FILE = process.env.GPTX_ADVISOR_STATE_FILE
  || path.join(AUTH_DIR, 'gptx-advisor-state.json');
const ADVISOR_OPUS_MODEL = process.env.GPTX_ADVISOR_OPUS_MODEL || 'claude-opus-5';
const ADVISOR_FABLE_MODEL = process.env.GPTX_ADVISOR_FABLE_MODEL || 'claude-fable-5';
const ADVISOR_SOL_MODEL = process.env.GPTX_ADVISOR_SOL_MODEL || 'gpt-5.6-sol';
const ADVISOR_TTL_MS = 10 * 60_000;
const ADVISOR_DEFAULT_RETRY_MS = 15 * 60_000;
const DEBUG = process.env.GPTX_DEBUG === '1';

const { laneFor } = require('./lanes');
const { resolveModelContext } = require('./model-context');
const HEALTH_TTL_MS = 30_000;

const log = (...a) => DEBUG && console.error('[gptx]', ...a);

// --- credentials -----------------------------------------------------------
// Read once at boot. Environment/file inputs make the public router portable; the
// macOS Keychain remains the zero-config default for existing installations.
const readProxyKey = () => {
  if (process.env.GPTX_PROXY_KEY) return process.env.GPTX_PROXY_KEY.trim();
  if (process.env.GPTX_PROXY_KEY_FILE) {
    return fs.readFileSync(process.env.GPTX_PROXY_KEY_FILE, 'utf8').trim();
  }
  if (process.platform === 'darwin' && fs.existsSync('/usr/bin/security')) {
    return execFileSync(
      '/usr/bin/security',
      ['find-generic-password', '-a', process.env.USER || os.userInfo().username, '-s', 'cliproxyapi-key', '-w'],
      { encoding: 'utf8' },
    ).trim();
  }
  throw new Error(
    'set GPTX_PROXY_KEY or GPTX_PROXY_KEY_FILE (macOS may use Keychain service cliproxyapi-key)',
  );
};

let PROXY_KEY;
try {
  PROXY_KEY = readProxyKey();
  if (!PROXY_KEY) throw new Error('proxy key is empty');
} catch (error) {
  console.error(`gptx-router: cannot load CLIProxyAPI key: ${error.message}`);
  process.exit(1);
}

// Node's global agent pools sockets on defaults meant for requests that finish in
// milliseconds. Between turns the socket to Anthropic sits idle long enough for the far
// end to drop it, and the next POST is then written into a connection that is already
// gone — which arrives as ETIMEDOUT/ECONNRESET rather than anything the client can read.
// Recycle idle sockets well before that, and never let one linger past a few minutes.
const upstreamAgent = new https.Agent({
  keepAlive: true,
  keepAliveMsecs: 15_000,
  maxSockets: 64,
  scheduling: 'lifo',   // reuse the most recently active socket, the least likely to be dead
  // NO socket `timeout` here, deliberately. An earlier revision set it to 5 minutes, which
  // is a socket-inactivity timer, and a model thinking silently for five minutes is exactly
  // that. It would have cut the longest turns on purpose — the same symptom being chased.
  // The idle sockets this agent needs to reap are handled by keepAliveMsecs, which only
  // applies between requests.
});

// --- state -----------------------------------------------------------------
const started = Date.now();
const stats = {
  // `errors` only ever counted status>=400 and socket errors. Both are blind to the
  // failure the client calls "Connection closed mid-response": upstream sending a clean
  // FIN partway through an SSE body. Nothing throws, the status was 200, and the counter
  // reads zero — which is how a live truncation problem looked like a healthy router.
  // `cut` counts streams that ended without their terminal event; `aborted`, clients that
  // hung up first.
  anthropic: { requests: 0, errors: 0, inflight: 0, cut: 0, streamErr: 0, aborted: 0, retried: 0, maxGapMs: 0 },
  codex: { requests: 0, errors: 0, inflight: 0, cut: 0, streamErr: 0, aborted: 0, retried: 0, maxGapMs: 0 },
  failures: [],           // last 10 {t, lane, status, model}
  cliVersion: null,
  cliVersionPrev: null,
  betas: [],
  betaHash: null,
  betaCount: 0,
  codexAuthCooling: false,
  codexConsecutiveErrors: 0,
  codexMaxOkBytes: 0,
  // Does the GPT lane carry the 1m-context beta? Load-bearing: Claude Code resolves a
  // model's context window client-side, and for a model absent from its catalog the
  // `context-1m` beta + a firstParty provider makes it assume 1e6. The agent then never
  // reaches its compaction threshold and runs until upstream rejects it near 272K. The
  // bundle says sdkBetas is session-global; this counts what actually goes out.
  codex1mBeta: 0,
  codexNo1mBeta: 0,
};

const recordFailure = (lane, status, model, detail, bytes, who) => {
  stats.failures.unshift({
    t: new Date().toISOString(), lane, status, model: model || null,
    detail: detail || null, bytes: bytes ?? null, who: who || null,
  });
  stats.failures.length = Math.min(stats.failures.length, 10);
};

// Baseline: written only by `gptx-doctor --certify`. Absent => never certified.
let baseline = null;
const loadBaseline = () => {
  try { baseline = JSON.parse(fs.readFileSync(BASELINE, 'utf8')); }
  catch { baseline = null; }
};
loadBaseline();
try { fs.watch(AUTH_DIR, (_e, f) => { if (f === 'gptx-baseline.json') loadBaseline(); }); } catch {}

// --- advisor bridge --------------------------------------------------------
// CLIProxyAPI sees only a high-entropy loopback callback. The original Claude Code
// credential stays in this process and is used only when this process talks directly
// to api.anthropic.com. A Sol advisor request is built with a fresh proxy-only header
// set, so Anthropic OAuth cannot cross into the GPT translator.
const advisorCallbacks = new Map();
let advisorState = {
  fallback: false,
  active: 'opus',
  retryAfter: null,
  switchedAt: null,
  reason: null,
};

const loadAdvisorState = () => {
  try {
    const parsed = JSON.parse(fs.readFileSync(ADVISOR_STATE_FILE, 'utf8'));
    advisorState = {
      fallback: parsed.fallback === true,
      active: parsed.fallback === true ? 'sol' : 'opus',
      retryAfter: Number.isFinite(Number(parsed.retryAfter)) ? Number(parsed.retryAfter) : null,
      switchedAt: parsed.switchedAt || null,
      reason: parsed.reason || null,
    };
  } catch {
    // Absence is the normal first-run state.
  }
};

const persistAdvisorState = () => {
  fs.mkdirSync(path.dirname(ADVISOR_STATE_FILE), { recursive: true, mode: 0o700 });
  const temporary = `${ADVISOR_STATE_FILE}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(advisorState, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, ADVISOR_STATE_FILE);
};

loadAdvisorState();

const advisorContext = () => {
  const result = {};
  for (const model of [ADVISOR_SOL_MODEL, 'gpt-5.6-terra']) {
    try { result[model] = resolveModelContext({ model }); }
    catch (error) { result[model] = { error: error.message }; }
  }
  return result;
};

const pruneAdvisorCallbacks = () => {
  const now = Date.now();
  for (const [id, callback] of advisorCallbacks) {
    if (callback.expiresAt <= now) advisorCallbacks.delete(id);
  }
};

const declaresAdvisor = (parsedBody) => Array.isArray(parsedBody?.tools)
  && parsedBody.tools.some((tool) => tool?.type === 'advisor_20260301' || tool?.name === 'advisor');

const callbackId = () => crypto.randomBytes(24).toString('base64url');

const stripInternalHeaders = (headers) => {
  const clean = { ...headers };
  for (const name of Object.keys(clean)) {
    if (name.toLowerCase().startsWith('x-trellis-')) delete clean[name];
  }
  return clean;
};

const advisorRequestBody = (original, model) => {
  const body = JSON.parse(JSON.stringify(original));
  body.model = model;
  body.stream = false;
  body.max_tokens = Math.min(Number(body.max_tokens) || 4096, 8192);
  delete body.tools;
  delete body.tool_choice;

  const instruction = [
    'You are the read-only advisor for an implementation agent.',
    'Inspect the conversation and give one concrete recommendation.',
    'Lead with material risks or defects, then the next action and missing evidence.',
    'Do not claim to edit files or delegate work.',
  ].join(' ');
  if (Array.isArray(body.system)) {
    body.system = [{ type: 'text', text: instruction }, ...body.system];
  } else {
    body.system = `${instruction}${body.system ? `\n\n${body.system}` : ''}`;
  }
  return Buffer.from(JSON.stringify(body));
};

class AdvisorUpstreamError extends Error {
  constructor(status, body, headers) {
    super(`advisor upstream returned HTTP ${status}`);
    this.status = status;
    this.body = body;
    this.headers = headers;
  }
}

const requestJson = ({ transport, options, body }) => new Promise((resolve, reject) => {
  const request = transport.request(options, (response) => {
    const chunks = [];
    let length = 0;
    response.on('data', (chunk) => {
      if (length < 2 * 1024 * 1024) {
        chunks.push(chunk);
        length += chunk.length;
      }
    });
    response.on('end', () => {
      const responseBody = Buffer.concat(chunks).toString('utf8');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        reject(new AdvisorUpstreamError(response.statusCode, responseBody, response.headers));
        return;
      }
      try { resolve(JSON.parse(responseBody)); }
      catch (error) { reject(new Error(`advisor upstream returned invalid JSON: ${error.message}`)); }
    });
  });
  request.setTimeout(2 * 60_000, () => request.destroy(new Error('advisor upstream timed out')));
  request.on('error', reject);
  request.end(body);
});

const advisorText = (response) => {
  const text = Array.isArray(response?.content)
    ? response.content.filter((block) => block?.type === 'text').map((block) => block.text).join('\n')
    : '';
  if (!text.trim()) throw new Error('advisor upstream returned no text');
  return text.trim();
};

const retryAfterMs = (error) => {
  const raw = error?.headers?.['retry-after'];
  if (raw) {
    const seconds = Number(raw);
    if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1000;
    const date = Date.parse(raw);
    if (Number.isFinite(date)) return Math.max(0, date - Date.now());
  }
  return ADVISOR_DEFAULT_RETRY_MS;
};

const isClaudeLimit = (error) => error instanceof AdvisorUpstreamError
  && (error.status === 429 || /usage.?limit|rate.?limit|weekly.?limit|credit.?balance/i.test(error.body));

const callClaudeAdvisor = async (callback, kind) => {
  const model = kind === 'fable' ? ADVISOR_FABLE_MODEL : ADVISOR_OPUS_MODEL;
  const body = advisorRequestBody(callback.body, model);
  const headers = stripInternalHeaders(callback.headers);
  delete headers.host;
  delete headers['content-length'];
  delete headers['accept-encoding'];
  headers['content-type'] = 'application/json';
  const response = await requestJson({
    transport: https,
    options: {
      hostname: 'api.anthropic.com',
      port: 443,
      path: '/v1/messages',
      method: 'POST',
      headers,
      agent: upstreamAgent,
    },
    body,
  });
  return { advisor_model: model, content: advisorText(response) };
};

const callSolAdvisor = async (callback) => {
  const body = advisorRequestBody(callback.body, ADVISOR_SOL_MODEL);
  const response = await requestJson({
    transport: http,
    options: {
      hostname: GPT_HOST,
      port: GPT_PORT,
      path: '/v1/messages',
      method: 'POST',
      headers: {
        authorization: `Bearer ${PROXY_KEY}`,
        'content-type': 'application/json',
        'content-length': body.length,
        'user-agent': 'trellis-gptx-advisor/1',
      },
    },
    body,
  });
  return { advisor_model: ADVISOR_SOL_MODEL, content: advisorText(response) };
};

const continuationRequestBody = (callback, advice) => {
  const body = JSON.parse(JSON.stringify(callback.body));
  body.stream = false;
  body.tools = Array.isArray(body.tools)
    ? body.tools.filter((tool) => tool?.type !== 'advisor_20260301' && tool?.name !== 'advisor')
    : body.tools;
  if (!body.tools?.length) delete body.tools;
  if (body.tool_choice?.name === 'advisor') delete body.tool_choice;
  body.messages = Array.isArray(body.messages) ? body.messages : [];
  body.messages.push({
    role: 'user',
    content: [
      {
        type: 'text',
        text: [
          'The read-only advisor returned the following recommendation:',
          '',
          advice.content,
          '',
          'Continue the original task now. Do not call the advisor again. Follow the',
          'original output constraints and use any other available tools normally.',
        ].join('\n'),
      },
    ],
  });
  return Buffer.from(JSON.stringify(body));
};

const callMainContinuation = async (callback, advice) => {
  const body = continuationRequestBody(callback, advice);
  const response = await requestJson({
    transport: http,
    options: {
      hostname: GPT_HOST,
      port: GPT_PORT,
      path: '/v1/messages',
      method: 'POST',
      headers: {
        authorization: `Bearer ${PROXY_KEY}`,
        'content-type': 'application/json',
        'content-length': body.length,
        'user-agent': 'trellis-gptx-advisor-continuation/1',
      },
    },
    body,
  });
  if (!Array.isArray(response?.content)) {
    throw new Error('main-model continuation returned no content blocks');
  }
  return {
    content: response.content,
    stop_reason: response.stop_reason || 'end_turn',
    usage: response.usage || {},
  };
};

const executeAdvisor = async (callback) => {
  const requested = callback.advisor;
  let advice;
  if (requested === 'sol') advice = await callSolAdvisor(callback);
  else if (requested === 'opus' || requested === 'fable') {
    advice = await callClaudeAdvisor(callback, requested);
  }
  if (advice) {
    advice.continuation = await callMainContinuation(callback, advice);
    return advice;
  }
  if (requested !== 'auto') throw new Error(`unsupported advisor selection: ${requested}`);

  const now = Date.now();
  if (advisorState.fallback && advisorState.retryAfter && now < advisorState.retryAfter) {
    advice = await callSolAdvisor(callback);
    advice.continuation = await callMainContinuation(callback, advice);
    return advice;
  }

  try {
    const response = await callClaudeAdvisor(callback, 'opus');
    if (advisorState.fallback) {
      advisorState = {
        fallback: false,
        active: 'opus',
        retryAfter: null,
        switchedAt: new Date().toISOString(),
        reason: null,
      };
      persistAdvisorState();
      response.content = `Trellis advisor restored: Opus is available again.\n\n${response.content}`;
      console.error('gptx-router: advisor auto-restored from Sol to Opus');
    }
    response.continuation = await callMainContinuation(callback, response);
    return response;
  } catch (error) {
    if (!isClaudeLimit(error)) throw error;

    const firstSwitch = !advisorState.fallback;
    advisorState = {
      fallback: true,
      active: 'sol',
      retryAfter: Date.now() + retryAfterMs(error),
      switchedAt: new Date().toISOString(),
      reason: `Claude advisor HTTP ${error.status}`,
    };
    persistAdvisorState();
    if (firstSwitch) {
      console.error(
        'gptx-router: Claude advisor limit reached; switched to gpt-5.6-sol. '
        + 'Revert/probe now: curl -X POST http://127.0.0.1:8318/__gptx/advisor/retry',
      );
    }
    const response = await callSolAdvisor(callback);
    if (firstSwitch) {
      response.content = [
        'Trellis advisor fallback active: Opus reached its limit, so this and later advice',
        'use gpt-5.6-sol. Trellis will probe Opus after the retry time. To probe now:',
        'curl -X POST http://127.0.0.1:8318/__gptx/advisor/retry',
        '',
        response.content,
      ].join('\n');
    }
    response.continuation = await callMainContinuation(callback, response);
    return response;
  }
};

const handleAdvisorCallback = (req, res) => {
  let id;
  try { id = decodeURIComponent(req.url.slice('/__gptx/advisor/'.length)); }
  catch { id = ''; }
  if (!/^[A-Za-z0-9_-]{32,64}$/.test(id)) {
    req.resume();
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'unknown advisor callback' }));
    return;
  }
  pruneAdvisorCallbacks();
  const callback = advisorCallbacks.get(id);
  advisorCallbacks.delete(id); // single use even when execution fails
  if (!callback || callback.expiresAt <= Date.now()) {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'unknown or expired advisor callback' }));
    return;
  }

  const callbackBody = [];
  let callbackBytes = 0;
  req.on('data', (chunk) => {
    callbackBytes += chunk.length;
    if (callbackBytes <= 64 * 1024) callbackBody.push(chunk);
  });
  req.on('end', async () => {
    try {
      if (callbackBytes > 64 * 1024) throw new Error('advisor callback body is too large');
      if (callbackBody.length) JSON.parse(Buffer.concat(callbackBody).toString('utf8'));
      const result = await executeAdvisor(callback);
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify(result));
    } catch (error) {
      recordFailure('codex', 'advisor', callback.body?.model, error.message, null, callback.who);
      res.writeHead(503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify({ error: error.message }));
    }
  });
};

// --- drift detection -------------------------------------------------------
// The Claude lane cannot break; it is a pipe. The only upgrade-sensitive surface is
// CLIProxyAPI's translation of a new request field or beta flag on the GPT lane, so
// that is exactly what we watch — at the first request that carries it.
const noteVersion = (ua) => {
  const m = /claude-cli\/([0-9][^\s(]*)/.exec(ua || '');
  if (!m || m[1] === stats.cliVersion) return;
  stats.cliVersionPrev = stats.cliVersion;
  stats.cliVersion = m[1];
  log('claude-cli version now', stats.cliVersion, 'was', stats.cliVersionPrev);
};

// The beta list is per-request, not per-install: a sonnet headless session sends 10
// flags where an opus TUI session sends 13. Hashing each request's list would flag
// drift on every session-type change. Accumulate the UNION instead and compare that —
// monotonic, so drift means "a flag we have never seen before appeared", which is
// exactly the upgrade signal worth acting on.
const betaSeen = new Set();

const noteBetas = (hdr) => {
  if (!hdr) return;
  let added = false;
  for (const f of String(hdr).split(',').map((s) => s.trim()).filter(Boolean)) {
    if (!betaSeen.has(f)) { betaSeen.add(f); added = true; }
  }
  if (!added) return;
  const list = [...betaSeen].sort();
  stats.betas = list;
  stats.betaCount = list.length;
  stats.betaHash = crypto.createHash('sha256').update(list.join(',')).digest('hex').slice(0, 16);
  log('anthropic-beta union now', stats.betaHash, `(${list.length} flags)`);
};

// --- upstream health (lazy, so /status cannot be used to hammer the proxy) --
let health = { checked: 0, proxyUp: null, token: null };

const refreshHealth = () => {
  if (Date.now() - health.checked < HEALTH_TTL_MS) return;
  health.checked = Date.now();

  const req = http.request(
    { hostname: GPT_HOST, port: GPT_PORT, path: '/v1/models', method: 'GET',
      headers: { authorization: `Bearer ${PROXY_KEY}` }, timeout: 3000 },
    (res) => { health.proxyUp = res.statusCode === 200; res.resume(); }
  );
  req.on('error', () => { health.proxyUp = false; });
  req.on('timeout', () => { health.proxyUp = false; req.destroy(); });
  req.end();

  try {
    const f = fs.readdirSync(AUTH_DIR).find((n) => /^codex-.*\.json$/.test(n));
    if (!f) { health.token = { state: 'missing' }; return; }
    const d = JSON.parse(fs.readFileSync(path.join(AUTH_DIR, f), 'utf8'));
    if (d.disabled) { health.token = { state: 'disabled' }; return; }
    const hoursLeft = (new Date(d.expired).getTime() - Date.now()) / 3_600_000;
    health.token = {
      state: hoursLeft <= 0 ? 'expired' : hoursLeft < 48 ? 'closing' : 'fresh',
      hoursLeft: Math.round(hoursLeft),
    };
  } catch (e) {
    health.token = { state: 'unreadable', error: e.message };
  }
};

// --- status ----------------------------------------------------------------
const statusPayload = () => {
  refreshHealth();
  const newBetas = baseline?.betas ? stats.betas.filter((b) => !baseline.betas.includes(b)) : [];
  const drift =
    !baseline ? 'never-certified'
    : baseline.cliVersion !== stats.cliVersion && stats.cliVersion ? `claude-cli ${baseline.cliVersion} -> ${stats.cliVersion}`
    : newBetas.length ? `new anthropic-beta flag(s) since certification: ${newBetas.join(', ')}`
    : null;

  // A run of consecutive GPT-lane failures is the honest signal: the upstream can
  // return a generic 503 with no auth marker at all (seen during an OpenAI-side
  // outage), and Claude Code retries silently, so error COUNT is what distinguishes
  // "one blip" from "nothing is getting through".
  const gptBroken = health.proxyUp === false
    || stats.codexAuthCooling
    || stats.codexConsecutiveErrors >= 3
    || ['expired', 'disabled', 'missing'].includes(health.token?.state);

  // `degraded` outranks `unverified`: an uncertified-but-working setup is a chore,
  // a GPT lane that is failing every request is happening right now. Ordering these
  // the other way hid a 10/10 failing lane behind "never-certified".
  const state = gptBroken ? 'degraded' : drift ? 'unverified' : 'ok';

  return {
    state,
    drift,
    uptimeSeconds: Math.round((Date.now() - started) / 1000),
    port: PORT,
    lanes: { anthropic: stats.anthropic, codex: stats.codex },
    failures: stats.failures,
    cliVersion: stats.cliVersion,
    cliVersionPrev: stats.cliVersionPrev,
    betaHash: stats.betaHash,
    betaCount: stats.betaCount,
    betas: stats.betas,
    baseline,
    upstream: {
      cliproxyapi: health.proxyUp,
      codexToken: health.token,
      codexAuth: stats.codexAuthCooling ? 'cooling / rate-limited' : 'available',
      codexConsecutiveErrors: stats.codexConsecutiveErrors,
      codexMaxOkBytes: stats.codexMaxOkBytes,
      codex1mBeta: stats.codex1mBeta,
      codexNo1mBeta: stats.codexNo1mBeta,
    },
    advisor: {
      requestedDefault: 'auto',
      active: advisorState.fallback ? 'sol' : 'opus',
      fallback: advisorState.fallback,
      retryAfter: advisorState.retryAfter
        ? new Date(advisorState.retryAfter).toISOString()
        : null,
      retryDue: Boolean(advisorState.fallback && advisorState.retryAfter <= Date.now()),
      switchedAt: advisorState.switchedAt,
      reason: advisorState.reason,
      pendingCallbacks: advisorCallbacks.size,
      context: advisorContext(),
    },
  };
};

const STATE_COLOR = { ok: '#3fb950', unverified: '#d29922', degraded: '#f85149' };

// Everything interpolated into the dashboard is attacker-influenced: `model` and the
// upstream error `detail` both come from request bodies and third-party responses. The
// old stripping of `[<&]` covered detail only and left model raw. Escape all of it —
// this page is loaded in a browser with localhost privileges.
const esc = (v) => String(v ?? '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

const statusHtml = () => {
  const s = statusPayload();
  const rows = (o) => Object.entries(o)
    .map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(typeof v === 'object' && v !== null ? JSON.stringify(v) : v)}</td></tr>`)
    .join('');
  const fails = s.failures.length
    ? s.failures.map((f) => `<tr><td>${esc(f.t)}</td><td>${esc(f.lane)}</td><td>${esc(f.status)}</td><td>${esc(f.model || '—')}</td><td>${esc(f.who || '—')}</td><td>${esc(f.detail || '—')}</td></tr>`).join('')
    : '<tr><td colspan="5">none</td></tr>';
  return `<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="5">
<title>gptx-router</title>
<style>
  :root { color-scheme: light dark; --fg:#e6edf3; --bg:#0d1117; --dim:#8b949e; --line:#30363d; }
  @media (prefers-color-scheme: light) { :root { --fg:#1f2328; --bg:#fff; --dim:#656d76; --line:#d0d7de; } }
  body { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--bg); color: var(--fg); margin: 24px; }
  h1 { font-size: 15px; margin: 0 0 4px; font-weight: 600; }
  .state { display:inline-block; padding:2px 10px; border-radius:99px; color:#0d1117; font-weight:700; background:${STATE_COLOR[s.state]}; }
  .drift { color:${STATE_COLOR.unverified}; margin:10px 0; }
  table { border-collapse: collapse; margin: 8px 0 20px; width: 100%; max-width: 760px; }
  td, th { border-bottom: 1px solid var(--line); padding: 4px 10px 4px 0; text-align: left; vertical-align: top; }
  th { color: var(--dim); font-weight: 500; }
  h2 { font-size: 12px; color: var(--dim); text-transform: uppercase; letter-spacing: .06em; margin: 18px 0 2px; font-weight: 600; }
</style>
<h1>gptx-router <span class="state">${s.state}</span></h1>
<div style="color:var(--dim)">127.0.0.1:${s.port} · up ${s.uptimeSeconds}s · claude-cli ${s.cliVersion || '—'} · beta ${s.betaHash || '—'} (${s.betaCount})</div>
${s.drift ? `<div class="drift">⚠ ${s.drift} — run <code>gptx-doctor --certify</code></div>` : ''}
<h2>Lanes</h2><table><tr><th>lane</th><th>requests</th><th>errors</th><th>in-flight</th></tr>
<tr><td>anthropic</td><td>${s.lanes.anthropic.requests}</td><td>${s.lanes.anthropic.errors}</td><td>${s.lanes.anthropic.inflight}</td></tr>
<tr><td>codex</td><td>${s.lanes.codex.requests}</td><td>${s.lanes.codex.errors}</td><td>${s.lanes.codex.inflight}</td></tr></table>
<h2>Upstream</h2><table>${rows(s.upstream)}</table>
<h2>Advisor</h2><table>${rows(s.advisor)}</table>
<h2>Baseline</h2><table>${s.baseline ? rows(s.baseline) : '<tr><td>never certified</td></tr>'}</table>
<h2>Recent failures</h2><table><tr><th>when</th><th>lane</th><th>status</th><th>model</th><th>who</th><th>detail</th></tr>${fails}</table>`;
};

// --- server ----------------------------------------------------------------
const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/__gptx/advisor/retry') {
    advisorState = {
      fallback: false,
      active: 'opus',
      retryAfter: null,
      switchedAt: new Date().toISOString(),
      reason: null,
    };
    persistAdvisorState();
    req.resume();
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    return res.end(JSON.stringify({
      ok: true,
      message: 'the next auto advisor call will probe Opus immediately',
    }));
  }
  if (req.method === 'POST' && req.url.startsWith('/__gptx/advisor/')) {
    return handleAdvisorCallback(req, res);
  }
  if (req.url === '/__gptx/status') {
    const body = JSON.stringify(statusPayload(), null, 2);
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    return res.end(body);
  }
  if (req.url === '/__gptx' || req.url === '/__gptx/') {
    const body = statusHtml();
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    return res.end(body);
  }

  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    let model = '';
    let parsedBody = null;
    // `who` exists to answer one question the failure ring could not: WHICH caller.
    // A two-hour storm of client-side 400s was observed with the ring recording model,
    // status and detail — and no way to attribute any of it to a session, so the only
    // remedy was to guess and start killing agents. A short prefix of the request's own
    // metadata.user_id is enough to group a burst by origin without keeping the full id.
    let who = '';
    if (body.length) {
      try {
        parsedBody = JSON.parse(body.toString());
        model = parsedBody.model || '';
        // metadata.user_id is NOT a flat id — Claude Code sends a JSON-encoded object
        // (`{"device_id":…,"session_id":…}`), so a naive prefix yields `{"device_id"` and
        // identifies nothing. Unwrap it and prefer session_id, which is what actually
        // distinguishes one looping session from another. Tolerate a plain string too;
        // other clients may send one.
        const raw = parsedBody?.metadata?.user_id;
        if (typeof raw === 'string') {
          let inner = null;
          try { inner = JSON.parse(raw); } catch { /* plain string id */ }
          who = String(inner?.session_id || inner?.account_uuid || raw).slice(0, 8);
        }
      } catch { /* not JSON: Anthropic lane */ }
    }

    noteVersion(req.headers['user-agent']);
    noteBetas(req.headers['anthropic-beta']);

    const lane = laneFor(model);
    const toGpt = lane === 'codex';
    stats[lane].requests++;
    stats[lane].inflight++;
    log(req.method, req.url, 'model=' + (model || '-'), '->', lane);

    if (toGpt) {
      if (/context-1m/.test(req.headers['anthropic-beta'] || '')) stats.codex1mBeta++;
      else stats.codexNo1mBeta++;
    }

    const done = () => { stats[lane].inflight = Math.max(0, stats[lane].inflight - 1); };

    let opts, transport;
    if (toGpt) {
      pruneAdvisorCallbacks();
      const h = {
        ...stripInternalHeaders(req.headers),
        host: `${GPT_HOST}:${GPT_PORT}`,
        authorization: `Bearer ${PROXY_KEY}`,
      };
      delete h['x-api-key'];
      delete h['accept-encoding'];   // the proxy re-encodes
      const advisor = String(req.headers['x-trellis-advisor'] || '').toLowerCase();
      if (['auto', 'opus', 'fable', 'sol'].includes(advisor) && declaresAdvisor(parsedBody)) {
        const id = callbackId();
        advisorCallbacks.set(id, {
          advisor,
          body: parsedBody,
          headers: { ...req.headers },
          who,
          expiresAt: Date.now() + ADVISOR_TTL_MS,
        });
        h['x-trellis-advisor-callback'] = `http://127.0.0.1:${PORT}/__gptx/advisor/${id}`;
      }
      opts = { hostname: GPT_HOST, port: GPT_PORT, path: req.url, method: req.method, headers: h };
      transport = http;
    } else {
      opts = {
        hostname: 'api.anthropic.com', port: 443, path: req.url, method: req.method,
        headers: { ...stripInternalHeaders(req.headers), host: 'api.anthropic.com' },
        agent: upstreamAgent,
      };
      transport = https;
    }

    // One retry, and only while nothing has been written to the client yet. A connect-time
    // ETIMEDOUT or a reset on a pooled socket is invisible to the model — no tokens were
    // produced — so replaying it is free. Observed live: `upstream:ETIMEDOUT` on 1 of 43
    // Anthropic requests, each of which surfaced to the operator as a failed turn.
    // Once bytes are out this is off limits: replaying would duplicate a partial answer.
    const attempt = (n) => {
    const up = transport.request(opts, (ur) => {
      if (ur.statusCode >= 400) {
        stats[lane].errors++;
        // Tee a slice of the error body alongside the pipe. Claude Code retries GPT-lane
        // failures, so without this an auth cooldown looks like "slow" rather than
        // "every request is failing" — the exact condition this catches in practice.
        //
        // Buffer BYTES, not a utf8 string, and decompress before matching. The GPT lane
        // arrives as plain JSON (we strip accept-encoding for it), but the Anthropic lane
        // is a byte pipe that keeps the client's accept-encoding — so its error bodies are
        // gzip/br and every Anthropic failure recorded `detail: null`, which is precisely
        // the lane where there is no upstream to ask instead.
        const errChunks = [];
        let errLen = 0;
        ur.on('data', (c) => { if (errLen < 8192) { errChunks.push(c); errLen += c.length; } });
        ur.on('end', () => {
          let head = '';
          try {
            let buf = Buffer.concat(errChunks);
            const enc = String(ur.headers['content-encoding'] || '').toLowerCase();
            // A truncated stream throws; take whatever decoded before the cut.
            if (enc.includes('br')) buf = zlib.brotliDecompressSync(buf, { finishFlush: zlib.constants.BROTLI_OPERATION_FLUSH });
            else if (enc.includes('gzip')) buf = zlib.gunzipSync(buf, { finishFlush: zlib.constants.Z_SYNC_FLUSH });
            else if (enc.includes('deflate')) buf = zlib.inflateSync(buf, { finishFlush: zlib.constants.Z_SYNC_FLUSH });
            head = buf.toString('utf8');
          } catch { head = Buffer.concat(errChunks).toString('utf8'); }

          const detail = /"message":\s*"([^"]{0,180})/.exec(head)?.[1] || null;
          if (lane === 'codex') {
            stats.codexAuthCooling = /auth_unavailable|no auth available/.test(head);
            stats.codexConsecutiveErrors++;
          }
          recordFailure(lane, ur.statusCode, model, detail, body.length, who);
        });
      } else if (lane === 'codex') {
        stats.codexAuthCooling = false;
        stats.codexConsecutiveErrors = 0;
        // Largest request the GPT lane has actually ACCEPTED. Paired with the bytes on a
        // context-overflow failure this brackets the real ceiling, which is the only way
        // to tell "we genuinely sent too much" from "upstream's window is smaller than
        // the model's advertised one".
        if (body.length > stats.codexMaxOkBytes) stats.codexMaxOkBytes = body.length;
      }
      // Watch the stream go past rather than only its start and its error. An SSE body is
      // complete when it carries `message_stop`; anything else that reaches `end` was cut
      // upstream, and that is the event the client reports and the router used to swallow.
      // Only assert this on an identity-encoded stream — a gzip'd body never matches the
      // marker in raw bytes, and guessing there would manufacture false truncations.
      const isStream = /text\/event-stream/.test(String(ur.headers['content-type'] || ''));
      const canSniff = isStream && !ur.headers['content-encoding'];
      let fwd = 0, sawStop = false, sawErr = false, settled = false, maxGap = 0, tail = '';
      const settle = (kind, detail) => {
        if (settled) return;
        settled = true;
        if (kind) {
          stats[lane][kind]++;
          // A mid-stream error is an UPSTREAM failure, so count it where a human looks for
          // failures. Left out of `errors`, an injected 500 settles as `aborted` and reads
          // as the client's fault — the same blind spot that once made "102 requests, 0
          // errors" look like health while streams were dying.
          if (kind === 'streamErr') {
            stats[lane].errors++;
            if (lane === 'codex') stats.codexConsecutiveErrors++;
          }
          recordFailure(lane, `stream:${kind}`, model, detail, body.length, who);
        }
        done();
      };
      // Upstream failed mid-body if it says so in-band. CLIProxyAPI turns an HTTP/2
      // RST_STREAM into an SSE `event: error` frame on an already-200 response, which is
      // correct protocol but invisible to a status-code check. Whichever side closes
      // first, this flag decides the attribution.
      const markers = (s) => {
        if (!sawStop && s.includes('message_stop')) sawStop = true;
        // Anchor to SSE FRAMING, not to the substring. A model answering a question about
        // streaming will happily emit the text `event: error` inside a content delta —
        // where it is JSON-escaped and never preceded by a raw LF. Matching the bare
        // substring would let the model's own prose mark its turn as an upstream failure.
        if (!sawErr && (s.includes('\nevent: error') || s.includes('data: {"type":"error"'))) sawErr = true;
      };
      // Carry a short tail so a marker split across a chunk boundary is still matched.
      // Longest marker is 21 bytes; 24 is slack.
      const feed = (c) => {
        const s = tail + c.toString('latin1');
        markers(s);
        tail = s.slice(-24);
      };
      const classify = () => (sawErr ? 'streamErr' : (canSniff && !sawStop ? 'cut' : null));

      // The client declares "Response stalled mid-stream" off an idle timer, so the useful
      // measurement is the largest silence between chunks, not the total duration. If that
      // approaches the client's threshold the model really did go quiet and the timer is
      // the thing to raise; if it stays small while turns still fail, the silence is being
      // introduced somewhere after this point and raising it would fix nothing.
      let lastChunk = Date.now();
      ur.on('data', (c) => {
        const gap = Date.now() - lastChunk;
        lastChunk = Date.now();
        if (gap > maxGap) maxGap = gap;
        if (gap > stats[lane].maxGapMs) stats[lane].maxGapMs = gap;
        fwd += c.length;
        if (canSniff) feed(c);
      });

      res.writeHead(ur.statusCode, ur.headers);
      // Long thinking means the first event can be minutes away; get the headers out now so
      // the client's watchdog is measuring the model, not our buffering.
      if (isStream) {
        if (typeof res.flushHeaders === 'function') res.flushHeaders();
        if (res.socket && res.socket.setNoDelay) res.socket.setNoDelay(true);
      }
      ur.pipe(res);

      ur.on('end', () => settle(classify(), `forwarded ${fwd}B, maxGap ${maxGap}ms`));
      ur.on('error', (e) => settle('cut', `${e.code || e.message} after ${fwd}B`));
      // Upstream socket destroyed without `end`: a truncation that emits no error event.
      ur.on('close', () => settle(classify(), `closed after ${fwd}B`));
      // Client gave up first (its own watchdog fired). Distinct from us being cut — unless
      // upstream already errored in-band, in which case the hangup is the CONSEQUENCE and
      // blaming the client would bury the cause.
      res.on('close', () => {
        if (!settled) settle(sawErr ? 'streamErr' : 'aborted', `client hung up after ${fwd}B, maxGap ${maxGap}ms`);
      });
    });

    up.on('error', (e) => {
      const transient = ['ETIMEDOUT', 'ECONNRESET', 'ECONNREFUSED', 'EPIPE', 'EHOSTUNREACH', 'ENETUNREACH', 'EAI_AGAIN']
        .includes(e.code);
      if (n === 0 && transient && !res.headersSent) {
        stats[lane].retried++;
        log('upstream', lane, e.code, '- retrying once (nothing sent yet)');
        return attempt(1);
      }

      stats[lane].errors++;
      recordFailure(lane, `upstream:${e.code || e.message}`, model, null, body.length, who);
      done();
      log('upstream error', lane, e.message);

      // Once headers are out we are mid-SSE, and a JSON object appended to an event stream
      // is not an error the client can read — it is a malformed event followed by EOF,
      // which is one way to manufacture "Connection closed mid-response". Drop the
      // connection instead: a clean transport failure is a shape the client already knows,
      // and it has its own retry for it (tengu_streaming_stale_connection_retry).
      if (res.headersSent) return res.destroy();

      // A 502 says "the thing behind me is broken" and stops there, which is why a lane
      // outage used to END a delegated unit: the agent got an opaque api_error, died, and
      // the orchestrator reported a failure of the work rather than of the transport.
      //
      // 503 + a machine-readable reason is the difference between detection and continuity.
      // The caller can now tell "this lane is down, run the identical unit on the
      // first-party model" apart from "your request was malformed", without parsing prose.
      // The router deliberately does NOT substitute a model itself — that would spend the
      // subscription this whole split exists to conserve, invisibly. See
      // docs/adr/2026-07-26-multi-model-lane-continuity.md.
      const code = e.code === 'ECONNREFUSED' ? 'LANE_DOWN' : 'LANE_UNREACHABLE';
      res.writeHead(503, {
        'content-type': 'application/json',
        'x-lane': lane,
        'x-lane-status': 'unavailable',
        'x-lane-reason': code,
        // Advisory only. The caller should degrade now, not sleep and hope.
        'retry-after': '30',
      });
      res.end(JSON.stringify({
        type: 'error',
        error: {
          type: 'overloaded_error',
          code,
          lane,
          message: `${lane} lane unavailable (${e.code || e.message}) — `
            + 'degrade this unit to the first-party model; do not retry on this lane',
        },
      }));
    });

    if (body.length) up.write(body);
    up.end();
    };
    attempt(0);
  });
});

// Node's defaults are tuned for a web server answering in milliseconds, not for a proxy
// in front of a model that thinks for minutes. Left alone they truncate long responses:
//
//   keepAliveTimeout 5s  — the killer. Claude Code pools connections; when the router
//     closes an idle socket the client still believes is good, the next request races
//     the FIN and surfaces as "Connection closed mid-response". api.anthropic.com holds
//     sockets far longer, so this only appears once a proxy is in the path.
//   headersTimeout    — must exceed keepAliveTimeout or it re-introduces the same cut.
//   requestTimeout 300s — a hard 5-minute cap on a single request/response.
//
// The Claude lane is supposed to be a dumb pipe. A pipe that hangs up on its own is not
// one, and every symptom lands on Anthropic traffic, where there is no upstream to blame.
server.keepAliveTimeout = 10 * 60_000;
server.headersTimeout = 11 * 60_000;
server.requestTimeout = 0;
server.timeout = 0;

server.listen(PORT, '127.0.0.1', () => {
  console.error(`gptx-router listening on 127.0.0.1:${PORT} -> anthropic | ${GPT_HOST}:${GPT_PORT}`);
});
