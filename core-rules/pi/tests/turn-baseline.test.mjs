// Pi prompt-to-settle wiring. A fake dispatcher makes failures deterministic;
// native/trellis-hooks tests cover actual fingerprinting and Stop execution.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import extension from '../extensions/trellis.ts';
import { mockDispatchExec } from './dispatch-test-transport.mjs';

function fixture(t) {
  const base = mkdtempSync(resolve(tmpdir(), 'trellis-pi-prompt-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const cwd = resolve(base, 'project'), runtime = resolve(base, 'runtime');
  mkdirSync(resolve(cwd, '.trellis'), { recursive: true });
  mkdirSync(resolve(cwd, '.agents/rules'), { recursive: true });
  mkdirSync(resolve(runtime, 'core-rules/pi/hooks'), { recursive: true });
  writeFileSync(resolve(runtime, 'core-rules/pi/hooks/dispatch.sh'), 'fixture', { mode: 0o755 });
  writeFileSync(resolve(runtime, 'trellis.config.json'), '{}');
  symlinkSync(runtime, resolve(cwd, '.trellis/runtime'));
  writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'fixture policy');
  writeFileSync(resolve(cwd, 'dirty.ts'), 'pre-existing edit');
  const events = [], notifications = [];
  let promptDecision = { schema_version: 1, capability_status: 'enforced', decision: 'allow' };
  let settleDecision = { schema_version: 1, capability_status: 'enforced', decision: 'allow' };
  function session(id) {
    const handlers = new Map();
    const pi = {
      on(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); },
      appendEntry() {}, getAllTools: () => [], getCommands: () => [], sendMessage() {},
      exec: mockDispatchExec(async (_script, args) => {
        const event = JSON.parse(readFileSync(args[1], 'utf8'));
        events.push(event);
        const decision = event.native_event === 'before_agent_start' ? promptDecision : settleDecision;
        return { stdout: JSON.stringify(decision), stderr: '', code: 0, killed: false };
      }),
    };
    extension(pi);
    const ctx = { cwd, signal: new AbortController().signal, ui: { notify: (...args) => notifications.push(args) },
      sessionManager: { getSessionId: () => id, getSessionFile: () => undefined } };
    const fire = async (name, event) => {
      let result;
      for (const handler of handlers.get(name) ?? []) result = (await handler(event, ctx)) ?? result;
      return result;
    };
    const prompt = () => fire('before_agent_start', { messageType: 'user', systemPrompt: '' });
    const settle = () => fire('agent_before_settle', { entries: [], context: { canContinue: false,
      contextMessages: [{ role: 'assistant', content: 'done' }] } });
    return { prompt, settle, fire };
  }
  return { session, events, notifications,
    failPrompt() { promptDecision = { schema_version: 1, capability_status: 'unknown', decision: 'deny', reason: 'baseline failure' }; },
    failSettle() { settleDecision = { schema_version: 1, capability_status: 'enforced', decision: 'deny', reason: 'check failed' }; },
  };
}

test('concurrent Pi sessions publish their own fresh prompt baseline before settle', async t => {
  const f = fixture(t), a = f.session('session-a'), b = f.session('session-b');
  await Promise.all([a.prompt(), b.prompt()]);
  const prompts = f.events.filter(e => e.native_event === 'before_agent_start');
  assert.deepEqual(prompts.map(e => e.session_id).sort(), ['session-a', 'session-b']);
  await Promise.all([a.settle(), b.settle()]);
  const stops = f.events.filter(e => e.phase === 'agent_before_settle');
  assert.deepEqual(stops.map(e => [e.session_id, e.allow_turn_baseline]).sort(), [['session-a', true], ['session-b', true]]);
});

test('a failed prompt publication cannot reuse an earlier carry', async t => {
  const f = fixture(t), s = f.session('session-a');
  f.failPrompt();
  await s.prompt();
  await s.settle();
  assert.equal(f.events.find(e => e.phase === 'agent_before_settle').allow_turn_baseline, false);
  assert.ok(f.notifications.length, 'prompt publication failure is visible');
});

test('a new prompt cannot launder a previous failed completion', async t => {
  const f = fixture(t), s = f.session('session-a');
  await s.prompt();
  f.failSettle();
  await s.settle();
  await s.prompt();
  await s.settle();
  assert.equal(f.events.filter(e => e.native_event === 'before_agent_start').length, 1);
  assert.equal(f.events.filter(e => e.phase === 'agent_before_settle').at(-1).allow_turn_baseline, false);
});
