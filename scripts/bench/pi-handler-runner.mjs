// Independent, headless Pi handler observations (I-A4, spec 074 T2).
// The coordinator never loads the extension: its watchdog covers synchronous
// hangs as well as unresolved promises in the worker. Node startup is NOT part
// of the handler boundary. Every warmup is retained, but excluded from stats.
import { spawn, fork } from 'node:child_process';
import { mkdtempSync, writeFileSync, unlinkSync, rmdirSync } from 'node:fs';
import { constants, tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
const project = args.get('project');
const runs = Number(args.get('runs'));
const warmup = Number(args.get('warmup') ?? 0);
const tool = args.get('tool');
const lifecycle = args.get('event');
const shape = args.get('result-shape') ?? 'text';
const cap = Number(args.get('timeout-ms') ?? 30000);
if (!project || !Number.isInteger(runs) || runs < 1 || !Number.isInteger(warmup) || warmup < 0 ||
    !Number.isFinite(cap) || cap <= 0 || (!!tool === !!lifecycle) || !['text', 'failed', 'native'].includes(shape)) throw new Error('invalid runner arguments');

if (!args.has('worker')) {
  const observations = [];
  const worker = fork(fileURLToPath(import.meta.url), [...process.argv.slice(2), '--worker', '1'], {
    detached: true, stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
  });
  let active, timer, stderr = '', finished = false;
  const kill = () => { try { process.kill(-worker.pid, 'SIGKILL'); } catch {} };
  const finish = (report, code = 0) => {
    if (finished) return;
    finished = true; clearTimeout(timer); kill();
    process.stdout.write(JSON.stringify({ ...report, observations }) + '\n');
    process.exitCode = code;
  };
  const arm = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (active) {
        const { started, ...base } = active;
        observations.push({ ...base, exit: 124, member_exits: [124], readiness: false,
          readiness_kind: 'no-denial', readiness_ms: 0, exec_error: false, timeout: true, callback_timeout: false,
          wall_ms: performance.now() - started, error: 'independent handler watchdog' });
      }
      finish({ failed: true, error_kind: 'timeout', error: 'independent handler watchdog', stderr }, 1);
    }, cap);
  };
  worker.stderr.on('data', data => { stderr = (stderr + data).slice(-4000); });
  worker.on('message', message => {
    if (message.type === 'begin') { active = { ...message.observation, started: performance.now() }; arm(); }
    if (message.type === 'observation') { observations.push(message.observation); active = undefined; arm(); }
    if (message.type === 'report') finish(message.report, message.code ?? 0);
  });
  worker.on('error', error => finish({ failed: true, error_kind: 'worker', exec_error: true, error: error.message }, 1));
  worker.on('exit', (code, signal) => {
    if (!finished) finish({ failed: true, error_kind: 'worker', error: `worker exited ${code} (signal ${signal})`, stderr }, 1);
  });
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { kill(); process.exit(128); });
  arm();
} else {
  try { await runWorker(); }
  catch (error) {
    process.send({ type: 'report', code: 1, report: { failed: true, error_kind: 'worker', error: String(error?.stack ?? error) } });
  }
}

async function runWorker() {
  const sendReport = (report, code = 0) => process.send({ type: 'report', report, code });
  // Probe the host with independent, valid TypeScript. An error importing the
  // shipped extension is NEVER evidence that this host lacks TypeScript support.
  const probeDirectory = mkdtempSync(resolve(tmpdir(), 'trellis-pi-ts-probe-'));
  const probeFile = resolve(probeDirectory, 'probe.ts');
  let unsupportedRuntime = false;
  try {
    writeFileSync(probeFile, 'export const supported: number = 1;\n', { flag: 'wx', mode: 0o600 });
    try { await import(pathToFileURL(probeFile)); }
    catch (error) {
      if (error?.code !== 'ERR_UNKNOWN_FILE_EXTENSION') throw error;
      unsupportedRuntime = true;
    }
  } finally {
    // Only the known leaf in the fresh private directory is removed.
    try { unlinkSync(probeFile); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    rmdirSync(probeDirectory);
  }
  if (unsupportedRuntime) {
    sendReport({ runtime_supported: false, error_kind: 'unsupported-typescript-runtime',
      error: 'host cannot load an independent .ts module' }, 3);
    return;
  }

  let execCalls = 0;
  const handlers = new Map();
  let transport = [];
  const policyMembers = new WeakSet();
  const dispatcherPath = resolve(project, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh');
  const validVerdict = value => value && typeof value === 'object' && !Array.isArray(value) &&
    value.schema_version === 1 && ['allow', 'warn', 'deny'].includes(value.decision) &&
    ['enforced', 'advisory', 'unsupported', 'disabled', 'unknown'].includes(value.capability_status);
  const transportFailed = () => transport.some(value => value.exec_error || value.signal || value.exit === null ||
    (policyMembers.has(value) && (value.exit !== 0 || !validVerdict(value.verdict) ||
      ['unknown', 'disabled'].includes(value.verdict.capability_status) ||
      (value.verdict.capability_status === 'unsupported' && value.verdict.decision !== 'allow'))));
  const pi = {
    on: (name, handler) => {
      const list = handlers.get(name) ?? []; list.push(handler); handlers.set(name, list);
    },
    getAllTools: () => ['read', 'write', 'edit', 'bash', 'grep', 'find', 'ls'].map(name => ({ name, sourceInfo: { source: 'builtin' } })),
    getCommands: () => [{ name: 'skill:bench-known', source: 'skill', sourceInfo: { path: args.get('skill-path') } }],
    sendMessage: () => {},
    exec: (command, argv, options) => new Promise((done, fail) => {
      execCalls++;
      const entry = { exit: null, exec_error: false, signal: null, verdict: null };
      // Contract, not stdout shape, decides whether a child emits policy JSON.
      // Local-post Git/linter commands emit text and may return a domain-status
      // code that the handler consumes; those are not broken transports.
      const expectsPolicy = argv.some(value => value.startsWith('TRELLIS_PI_DISPATCH_NONCE=')) ||
        command === dispatcherPath ||
        (['bash', '/bin/bash', 'sh', '/bin/sh'].includes(command) && argv[0] === dispatcherPath);
      if (expectsPolicy) policyMembers.add(entry);
      transport.push(entry);
      let child;
      try { child = spawn(command, argv, { cwd: options.cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] }); }
      catch (error) { entry.exec_error = true; entry.exit = 127; entry.error = error.message; fail(error); return; }
      let stdout = '', stderr = '';
      child.stdout.on('data', chunk => { stdout += chunk; });
      child.stderr.on('data', chunk => { stderr += chunk; });
      child.on('error', error => { entry.exec_error = true; entry.exit = 127; entry.error = error.message; fail(error); });
      child.on('close', (code, signal) => {
        entry.signal = signal;
        if (!entry.exec_error) entry.exit = code ?? (signal ? 128 + (constants.signals[signal] ?? 0) : 1);
        if (!expectsPolicy) {
          entry.stdout = stdout;
          entry.stderr = stderr;
        } else try {
          const nonceArgs = argv.filter(value => value.startsWith('TRELLIS_PI_DISPATCH_NONCE='));
          if (nonceArgs.length) {
            // The current dispatcher emits decision + nonce-bound completion.
            // Never mistake the terminal marker for the policy decision, or
            // accept a partial/wrong-nonce response as positive readiness.
            const nonce = nonceArgs[0].slice('TRELLIS_PI_DISPATCH_NONCE='.length);
            const records = /^([^\r\n]+)\n([^\r\n]+)\n$/.exec(stdout);
            const terminal = JSON.parse(records?.[2] ?? '');
            if (nonceArgs.length === 1 && /^[0-9a-f]{64}$/.test(nonce) &&
                terminal && typeof terminal === 'object' && !Array.isArray(terminal) &&
                Object.keys(terminal).length === 4 && terminal.schema_version === 1 &&
                terminal.type === 'trellis_dispatch_complete' && terminal.complete === true && terminal.nonce === nonce) {
              entry.verdict = JSON.parse(records[1]);
            }
          } else {
            // Older releases and the existing single-record fixture protocol.
            entry.verdict = JSON.parse(stdout.trim().split('\n').at(-1));
          }
        } catch {}
        done({ stdout, stderr, code: entry.exit, killed: !!signal });
      });
    }),
  };
  let extension;
  try {
    ({ default: extension } = await import(pathToFileURL(resolve(project, '.trellis/runtime/core-rules/pi/extensions/trellis.ts'))));
  } catch (error) {
    sendReport({ failed: true, runtime_supported: true, error_kind: 'extension-import',
      error: `cannot load trellis.ts: ${error?.stack ?? error}` }, 1);
    return;
  }
  try { extension(pi); }
  catch (error) {
    sendReport({ failed: true, runtime_supported: true, error_kind: 'extension-initialization', error: String(error?.stack ?? error) }, 1);
    return;
  }
  const ctx = {
    cwd: project, signal: new AbortController().signal, ui: { notify: () => {} },
    sessionManager: { getSessionId: () => 'bench-session-0001', getSessionFile: () => args.get('session-file') },
  };
  const fire = async (name, event) => {
    if (!handlers.has(name)) throw new Error(`unregistered handler ${name}`);
    let value;
    for (const handler of handlers.get(name)) {
      const next = await handler(event, ctx);
      if (next?.block || next?.continue || next?.result?.exitCode || next?.action === 'handled') value = next;
      else if (value === undefined) value = next;
    }
    return value;
  };
  const inputs = {
    read: { path: 'src/a.ts' }, bash: { command: 'git status --short' },
    edit: { path: 'src/a.ts', edits: [{ oldText: 'return a + b;', newText: 'return a + b; // checked' }] },
    write: { path: 'src/new.ts', content: 'export const x = 1;\n' }, grep: { pattern: 'add', path: '.' },
  };
  const outputs = { read: 'export function add(a, b) { return a + b; }', bash: '',
    edit: 'Successfully replaced text in src/a.ts.', write: 'Successfully wrote 20 bytes to src/new.ts', grep: 'src/a.ts' };
  let sequence = 0;
  const call = name => ({ toolCallId: `bench-call-${++sequence}`, toolName: name, input: { ...inputs[name] } });
  const result = (event, resultShape = shape) => ({ ...event,
    content: [{ type: 'text', text: resultShape === 'failed' ? 'Tool failed; file unchanged' : outputs[event.toolName] }],
    isError: resultShape === 'failed', details: resultShape === 'native' ? { status: 'succeeded', success: true } : undefined });
  const report = { boundary: 'trellis.ts handler', runs, warmup, blocked: 0, registered: true, runtime_supported: true,
    fixture_id: shape === 'text' ? 'clean' : `result-${shape}`, boundary_id: 'pi-handler', exec_calls: 0 };
  const events = tool ? ['tool_call', 'tool_result'] : [lifecycle];
  const missing = events.filter(event => !handlers.has(event));
  if (missing.length) {
    const optional = missing.every(event => event === 'agent_before_settle');
    sendReport({ ...report, registered: false, missing_handlers: missing, failed: !optional,
      error: `unregistered ${optional ? 'optional' : 'required'} handlers: ${missing.join(', ')}`,
      error_kind: optional ? 'optional-handler-absent' : 'required-handler-absent' }, optional ? 0 : 1);
    return;
  }
  const observations = [];
  async function observe(eventName, event, iteration) {
    const canonicalId = tool ? `pi ${eventName} ${tool}` : `pi ${eventName}`;
    const caseId = canonicalId + (shape === 'text' ? '' : ` ${shape}`);
    const base = { case_id: caseId, fixture_id: report.fixture_id, boundary_id: 'pi-handler',
      warmup: iteration < warmup, iteration, event: eventName,
      ...(tool && shape !== 'text' && eventName === 'tool_call' ? { alias_of: canonicalId } : {}) };
    process.send({ type: 'begin', observation: base });
    transport = [];
    const exec0 = execCalls, start = performance.now();
    let decision, error;
    try { decision = await fire(eventName, event); } catch (caught) { error = String(caught?.message ?? caught); }
    const wall = performance.now() - start;
    const readinessStart = performance.now();
    const blocked = !!(decision?.block || decision?.continue || decision?.result?.exitCode || decision?.action === 'handled' ||
      transport.some(value => value.verdict?.decision === 'deny'));
    const unsupported = transport.some(value => value.verdict?.capability_status === 'unsupported');
    const failedTransport = transportFailed();
    const execError = transport.some(value => value.exec_error);
    const transportExit = transport.find(value => value.exit !== 0 &&
      (policyMembers.has(value) || value.exec_error || value.signal))?.exit;
    const exit = execError ? 127 : transportExit ?? (error || failedTransport ? 1 : blocked ? 2 : 0);
    const ready = !error && !blocked && !unsupported && !failedTransport;
    // Local handlers do not expose their allow decision: no-denial is not
    // positive proof. Supported, validated child verdicts are retained below.
    const policyTransport = transport.filter(value => policyMembers.has(value));
    const proven = ready && policyTransport.length > 0 && policyTransport.every(value =>
      ['enforced', 'advisory'].includes(value.verdict.capability_status) && ['allow', 'warn'].includes(value.verdict.decision));
    const observation = { ...base, exit, member_exits: transport.length ? transport.map(value => value.exit) : [exit],
      readiness: ready, readiness_kind: proven ? 'proven' : 'no-denial',
      readiness_ms: performance.now() - readinessStart, exec_error: execError,
      timeout: false, callback_timeout: false, wall_ms: wall, exec_calls: execCalls - exec0, blocked, unsupported,
      transport_failed: failedTransport, transport_results: transport, decision: decision ?? null, ...(error ? { error } : {}) };
    observations.push(observation); process.send({ type: 'observation', observation });
    if (blocked) report.blocked++;
    return exit;
  }
  for (let i = 0; i < warmup + runs; i++) {
    if (tool) {
      // Independent pre/post observations. The successful read is setup only.
      if (tool === 'edit') {
        transport = [];
        const seed = call('read');
        const decision = await fire('tool_call', seed);
        if (decision?.block) throw new Error('read seed blocked');
        await fire('tool_result', result(seed, 'text'));
        if (transportFailed() || transport.some(value => value.verdict?.decision === 'deny')) throw new Error('read seed transport failed');
      }
      const event = call(tool);
      const exit = await observe('tool_call', event, i);
      // Never invent a successful post after a denied/failed pre-action.
      if (exit !== 0) break;
      if (await observe('tool_result', result(event), i) !== 0) break;
    } else {
      const event = lifecycle === 'user_bash' ? { command: 'git status --short', cwd: project } :
        lifecycle === 'before_agent_start' ? { messageType: 'user', prompt: 'Fix add', systemPrompt: '' } :
        lifecycle === 'input' ? { text: '/skill:bench-known', source: 'interactive' } :
        lifecycle === 'agent_before_settle' ? { context: { canContinue: true }, reason: 'completed' } :
        { reason: lifecycle === 'session_start' ? 'startup' : 'manual', willRetry: false };
      if (await observe(lifecycle, event, i) !== 0) break;
    }
  }
  report.exec_calls = execCalls;
  // Legacy arrays stay available for readers of bench schema /1.
  const values = name => observations.filter(o => o.event === name && !o.warmup && o.readiness).map(o => o.wall_ms);
  if (tool) Object.assign(report, { tool, pre_ms: values('tool_call'), post_ms: values('tool_result') });
  else Object.assign(report, { event: lifecycle, ms: values(lifecycle) });
  const failed = observations.some(row => row.exit !== 0 || row.exec_error || row.transport_failed || row.blocked);
  sendReport({ ...report, failed }, failed ? 1 : 0);
}
