// Headless pi host for scripts/bench/trellis-latency.py (spec 072 T0).
//
// Loads the attached fixture's own trellis.ts and times its handlers at the
// extension boundary, the boundary spec 072 C1 judges: from the moment pi would
// call the handler until its promise settles. Whatever the handler does inside
// (today: pi.exec of dispatch.sh; after U6: in-process guards) is inside the
// measurement, so before and after compare the same boundary.
//
// node pi-handler-runner.mjs --project DIR --session-file FILE --runs N --warmup N
//                            (--tool read|bash|edit|write|grep | --event session_start|agent_settled)
// Prints one JSON line: {boundary, tool|event, pre_ms[], post_ms[] | ms[], blocked, exec_calls}.
// pi.exec mirrors pi's: no shell, the given cwd, this process's environment.
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
const project = args.get('project');
const runs = Number(args.get('runs'));
const warmup = Number(args.get('warmup') ?? 0);
const tool = args.get('tool');
const lifecycle = args.get('event');

let execCalls = 0;
const handlers = new Map();
const pi = {
  on: (name, handler) => handlers.set(name, handler),
  getAllTools: () => ['read', 'write', 'edit', 'bash', 'grep', 'find', 'ls'].map(name => ({ name, sourceInfo: { source: 'builtin' } })),
  getCommands: () => [],
  sendMessage: () => {},
  exec: (command, argv, options) => new Promise((done, fail) => {
    execCalls++;
    const child = spawn(command, argv, { cwd: options.cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', fail);
    child.on('close', (code, signal) => done({ stdout, stderr, code: code ?? 1, killed: !!signal }));
  }),
};
// Exit 3 means this node cannot load trellis.ts at all (for example, no type
// stripping), so the caller records the boundary as unmeasured. Any failure
// after the load is the handler's and exits non-zero some other way.
let extension;
try {
  ({ default: extension } = await import(pathToFileURL(resolve(project, '.trellis/runtime/core-rules/pi/extensions/trellis.ts'))));
} catch (error) {
  process.stderr.write(`cannot load trellis.ts: ${error?.message ?? error}\n`);
  process.exit(3);
}
extension(pi);
const ctx = {
  cwd: project, signal: new AbortController().signal, ui: { notify: () => {} },
  sessionManager: { getSessionId: () => 'bench-session-0001', getSessionFile: () => args.get('session-file') },
};
const fire = (name, event) => handlers.get(name)(event, ctx);

const inputs = {
  read: { path: 'src/a.ts' },
  bash: { command: 'git status --short' },
  edit: { path: 'src/a.ts', edits: [{ oldText: 'return a + b;', newText: 'return a + b; // checked' }] },
  write: { path: 'src/new.ts', content: 'export const x = 1;\n' },
  grep: { pattern: 'add', path: '.' },
};
const outputs = {
  read: 'export function add(a: number, b: number): number {\n  return a + b;\n}\n',
  bash: '', edit: 'Successfully replaced text in src/a.ts.', write: 'Successfully wrote 20 bytes to src/new.ts', grep: 'src/a.ts',
};
let sequence = 0;
const call = (name) => ({ toolCallId: `bench-call-${++sequence}`, toolName: name, input: inputs[name] });
const result = (event) => ({ ...event, content: [{ type: 'text', text: outputs[event.toolName] }], isError: false, details: undefined });

const report = { boundary: 'trellis.ts handler', runs, warmup, blocked: 0 };
if (tool) {
  // An edit follows a read in a real turn; one untimed read lets reread-guard allow it.
  if (tool === 'edit') { const seed = call('read'); await fire('tool_call', seed); await fire('tool_result', result(seed)); }
  const pre = [], post = [];
  for (let i = 0; i < warmup + runs; i++) {
    const event = call(tool);
    const start = performance.now();
    const decision = await fire('tool_call', event);
    const mid = performance.now();
    await fire('tool_result', result(event));
    const end = performance.now();
    if (i < warmup) continue;
    if (decision?.block) report.blocked++;
    pre.push(mid - start); post.push(end - mid);
  }
  Object.assign(report, { tool, pre_ms: pre, post_ms: post });
} else {
  const ms = [];
  for (let i = 0; i < warmup + runs; i++) {
    const start = performance.now();
    await fire(lifecycle, lifecycle === 'session_start' ? { reason: 'startup' } : {});
    if (i >= warmup) ms.push(performance.now() - start);
  }
  Object.assign(report, { event: lifecycle, ms });
}
report.exec_calls = execCalls;
console.log(JSON.stringify(report));
