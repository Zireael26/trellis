// Installed-style fixture: runtime-owned bytes and native .pi links, no live home.
import { cpSync, mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

export async function deliveredFixture(t, source = process.env.B10_SOURCE_ROOT ?? resolve(new URL('../../../', import.meta.url).pathname)) {
  const base = mkdtempSync(resolve(tmpdir(), 'b10-delivered-'));
  t?.after(() => rmSync(base, { recursive: true, force: true }));
  const cwd = resolve(base, 'project'), runtime = resolve(base, 'release');
  for (const dir of ['.trellis', '.pi/extensions', '.agents/rules', 'tmp']) mkdirSync(resolve(cwd, dir), { recursive: true });
  for (const dir of ['pi', 'codex/hooks', 'hooks/lib']) cpSync(resolve(source, 'core-rules', dir), resolve(runtime, 'core-rules', dir), { recursive: true });
  writeFileSync(resolve(runtime, 'trellis.config.json'), '{}');
  symlinkSync(runtime, resolve(cwd, '.trellis/runtime'));
  symlinkSync(resolve(runtime, 'core-rules/pi/extensions/trellis.ts'), resolve(cwd, '.pi/extensions/trellis.ts'));
  // The dispatcher runs the Codex hook set straight from the runtime payload;
  // nothing is rendered under .pi/hooks, which pi reserves.
  writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Fixture parent policy');
  const handlers = new Map(), calls = [], messages = [], notifications = [], commands = [];
  const pi = {
    on: (name, handler) => handlers.set(name, handler),
    getAllTools: () => ['read', 'write', 'edit', 'bash', 'grep', 'find', 'ls', 'powershell'].map(name => ({ name, sourceInfo: { source: 'builtin' } })),
    getCommands: () => commands,
    sendMessage: (...args) => messages.push(args),
    exec: async (script, args, options) => {
      calls.push({ script, args, options });
      const r = spawnSync('bash', [script, ...args], { cwd: options.cwd, encoding: 'utf8', timeout: 30_000,
        env: { PATH: process.env.PATH, HOME: cwd, TMPDIR: resolve(cwd, 'tmp') } });
      if (r.error) throw r.error;
      return { stdout: r.stdout, stderr: r.stderr, code: r.status, killed: !!r.signal };
    },
  };
  const { default: extension } = await import(pathToFileURL(resolve(cwd, '.pi/extensions/trellis.ts')));
  extension(pi);
  const ctx = { cwd, signal: new AbortController().signal, ui: { notify: (...args) => notifications.push(args) },
    sessionManager: { getSessionId: () => 'fixture-session', getSessionFile: () => undefined } };
  const fire = (name, event, context = ctx) => handlers.get(name)(event, context);
  let sequence = 0;
  const call = (toolName, input) => ({ toolCallId: `call-${++sequence}`, toolName, input });
  const result = (event, isError = false) => fire('tool_result', { ...event, content: [{ type: 'text', text: 'fixture result' }], isError });
  const skill = (name, bytes = 30) => {
    const path = resolve(cwd, `.agents/skills/${name}/SKILL.md`);
    mkdirSync(resolve(path, '..'), { recursive: true });
    writeFileSync(path, 'x'.repeat(bytes));
    commands.push({ name: `skill:${name}`, source: 'skill', sourceInfo: { path } });
    return path;
  };
  return { cwd, runtime, base, pi, ctx, calls, handlers, messages, notifications, commands, fire, call, result, skill };
}
