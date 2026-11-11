// Stub ExtensionAPI boundary regressions; not native execution or trust/loading proof.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync, renameSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import extension from '../extensions/trellis.ts';
import { mockDispatchExec } from './dispatch-test-transport.mjs';
import { deliveredFixture } from './delivered-fixture.mjs';

function fixture(t) {
  const base = mkdtempSync(resolve(tmpdir(), 'trellis-boundaries-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const attach = (name, policy = true) => {
    const root = resolve(base, name);
    mkdirSync(resolve(root, '.trellis/runtime/core-rules/pi/hooks'), { recursive: true });
    writeFileSync(resolve(root, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh'), 'fixture', { mode: 0o755 });
    writeFileSync(resolve(root, '.trellis/runtime/trellis.config.json'), '{}');
    if (policy) {
      mkdirSync(resolve(root, '.agents/rules'), { recursive: true });
      writeFileSync(resolve(root, '.agents/rules/trellis.md'), `${name} policy`);
    }
    return root;
  };
  const cwd = attach('attached');
  const handlers = new Map(), messages = [], notifications = [], calls = [];
  const f = { base, cwd, attach, handlers, messages, notifications, calls,
    decision: { schema_version: 1, capability_status: 'enforced', decision: 'allow' } };
  const pi = {
    on: (name, handler) => handlers.set(name, name === 'before_agent_start' ? (event, ctx) => handler({ messageType: 'user', ...event }, ctx) : handler),
    // Pi 0.85 agent-session/source-info builtin metadata; loader local extension metadata.
    getAllTools: () => [
      ...['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'].map(name => ({
        name, sourceInfo: { path: `<builtin:${name}>`, source: 'builtin', scope: 'temporary', origin: 'top-level', baseDir: undefined },
      })),
      ...['Agent', 'SubagentWorkflow'].map(name => ({
        name, sourceInfo: { path: '/fixture/pi-subagents/dist/index.js', source: 'local', scope: 'temporary', origin: 'top-level', baseDir: '/fixture/pi-subagents/dist' },
      })),
    ],
    sendMessage: (...args) => messages.push(args),
    exec: mockDispatchExec(async (script, args, options) => {
      const event = args[0] === '--event-file' ? JSON.parse(readFileSync(args[1], 'utf8')) : JSON.parse(Buffer.from(args[1], 'base64').toString());
      calls.push({ script, options, event });
      return { stdout: JSON.stringify(f.decision), stderr: '', code: 0 };
    }),
  };
  extension(pi);
  f.ctx = { cwd, signal: new AbortController().signal, ui: { notify: (...args) => notifications.push(args) },
    sessionManager: { getSessionId: () => 'session', getSessionFile: () => '/fixture/session.jsonl' } };
  f.fire = (name, event = {}, ctx = f.ctx) => handlers.get(name)(event, ctx);
  f.turn = () => f.fire('before_agent_start', { systemPrompt: 'parent' });
  f.bash = (extra = {}) => f.fire('user_bash', { command: 'gh pr create --title fixture', cwd, excludeFromContext: false, ...extra });
  return f;
}
const response = context => ({ stdout: JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision: 'allow', ...(context ? { context } : {}) }), stderr: '', code: 0, killed: false });

for (const native_event of ['session_start', 'session_compact', 'agent_settled']) {
  test(`${native_event} output survives a prompt while its dispatcher is pending`, async t => {
    const f = await deliveredFixture(t);
    let release;
    f.pi.exec = mockDispatchExec(() => new Promise(done => { release = done; }));
    const pending = f.fire(native_event, { reason: 'resume' });
    f.fire('before_agent_start', { systemPrompt: 'parent' });
    release({ ...response(), stdout: JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision: 'warn', context: `${native_event} context sentinel`, reason: `${native_event} warning sentinel` }) });
    await pending;
    assert.deepEqual(f.notifications.at(-1), [`${native_event} warning sentinel`, 'warning']);
    const context = native_event === 'agent_settled' ? f.messages.at(-1)[0].content : f.fire('before_agent_start', { systemPrompt: 'parent' }).message.content;
    assert.match(context, new RegExp(`${native_event} context sentinel`));
    assert.match(context, new RegExp(`${native_event} warning sentinel`));
    if (native_event === 'agent_settled') assert.deepEqual(f.messages.at(-1)[1], { deliverAs: 'nextTurn' });
  });
}

test('compact task context survives an intervening settlement', async t => {
  const f = await deliveredFixture(t);
  let release;
  f.pi.exec = mockDispatchExec(() => new Promise(done => { release = done; }));
  const pending = f.fire('session_compact', { reason: 'manual' });
  f.pi.exec = mockDispatchExec(async () => response());
  await f.fire('agent_settled', {});
  release(response('task-context v1: compact sentinel'));
  await pending;
  assert.match(f.fire('before_agent_start', { systemPrompt: 'parent' }).message.content, /task-context v1: compact sentinel/);
});

test('prompt policy still binds when session identity initialization throws', async t => {
  const f = await deliveredFixture(t);
  const ctx = { ...f.ctx, sessionManager: { getSessionId() { throw new Error('prompt identity sentinel'); } } };
  const start = f.fire('before_agent_start', { systemPrompt: 'parent' }, ctx);
  assert.match(start.systemPrompt, /<trellis_parent_policy>[\s\S]*Fixture parent policy/);
  assert.match(start.message.content, /session identity unavailable/);
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'echo ok' }), ctx)).block, true);
});

test('stale startup replies cannot replace the current session context', async t => {
  const f = await deliveredFixture(t);
  let release;
  f.pi.exec = mockDispatchExec(() => new Promise(done => { release = done; }));
  const previous = f.fire('session_start', { reason: 'startup' });
  f.pi.exec = mockDispatchExec(async () => response('current-session sentinel'));
  await f.fire('session_start', { reason: 'resume' });
  release(response('stale-session sentinel'));
  await previous;
  const start = f.fire('before_agent_start', { systemPrompt: 'parent' });
  assert.match(start.message.content, /current-session sentinel/);
  assert.doesNotMatch(start.message.content, /stale-session sentinel/);
});

test('queued context binds the session, root and physical runtime before prompt assembly', async t => {
  const f = await deliveredFixture(t), other = await deliveredFixture(t);
  f.pi.exec = mockDispatchExec(async () => response('foreign-context sentinel'));
  await f.fire('session_start', { reason: 'startup' });
  writeFileSync(resolve(other.cwd, '.agents/rules/trellis.md'), 'Other policy');
  const start = f.fire('before_agent_start', { systemPrompt: 'parent' }, other.ctx);
  assert.equal(start.message, undefined);
  assert.match(start.systemPrompt, /Other policy/);
  await f.fire('session_start', { reason: 'resume' });
  rmSync(resolve(f.cwd, '.trellis/runtime'));
  symlinkSync(other.runtime, resolve(f.cwd, '.trellis/runtime'));
  assert.equal(f.fire('before_agent_start', { systemPrompt: 'parent' }).message, undefined);
});

test('shutdown joins and cleans up exactly once for repeated callbacks', async t => {
  const f = await deliveredFixture(t);
  const releases = [];
  f.pi.exec = mockDispatchExec(() => new Promise(done => releases.push(done)));
  const first = f.fire('session_shutdown', { reason: 'exit' });
  const repeated = f.fire('session_shutdown', { reason: 'exit' });
  const count = releases.length;
  for (const release of releases) release(response());
  await Promise.all([first, repeated]);
  assert.equal(count, 1);
  f.pi.exec = mockDispatchExec(async () => { throw new Error('shutdown ran twice'); });
  await f.fire('session_shutdown', { reason: 'exit' });
  assert.equal(f.notifications.length, 0);
});

test('late compact reply cannot repopulate context or publish warnings after shutdown', async t => {
  const f = await deliveredFixture(t);
  let release;
  f.pi.exec = mockDispatchExec(() => new Promise(done => { release = done; }));
  const compact = f.fire('session_compact', { reason: 'manual' });
  f.pi.exec = mockDispatchExec(async () => response());
  await f.fire('session_shutdown', { reason: 'exit' });
  release({ ...response('late-compact sentinel'), stdout: JSON.stringify({ schema_version: 1, capability_status: 'unknown', decision: 'warn', reason: 'late-compact warning', context: 'late-compact sentinel' }) });
  await compact;
  assert.equal(f.fire('before_agent_start', { systemPrompt: 'parent' }).message, undefined);
  assert.equal(f.messages.length, 0);
  assert.equal(f.notifications.length, 0);
});

const call = (id = 'r', input = { path: 'file' }) => ({ toolCallId: id, toolName: 'read', input });
const result = (event = call()) => ({ ...event, content: [], isError: false });

// Probe read state through pre-action verdicts only; do not depend on mutation dispatch.
async function assertWriteCredit(f, path, credited, ctx = f.ctx) {
  const notices = f.notifications.length;
  const dispatches = f.calls.length;
  for (let i = 0; i < 3; i++) {
    const verdict = await f.fire('tool_call', { toolCallId: `write:${path}:${i}`, toolName: 'write', input: { path, content: 'replacement' } }, ctx);
    if (credited || i < 2) assert.equal(verdict, undefined);
    else {
      assert.equal(verdict.block, true);
      assert.match(verdict.reason, /reread-guard: BLOCKED/);
    }
  }
  assert.equal(f.notifications.length, notices + (credited ? 0 : 3));
  if (!credited) {
    assert.match(f.notifications[notices][0], /warn 1\/2/);
    assert.match(f.notifications[notices + 1][0], /warn 2\/2/);
    assert.equal(f.notifications[notices + 2][1], 'error');
  }
  assert.equal(f.calls.length, dispatches, 'write guard probes must stay local');
}

test('ambient unrelated root is ignored; ancestor attachment still discovers policy, skills and prompts', async t => {
  const f = fixture(t);
  const previous = process.env.TRELLIS_PI_ATTACHED_ROOT;
  process.env.TRELLIS_PI_ATTACHED_ROOT = f.cwd;
  t.after(() => { if (previous === undefined) delete process.env.TRELLIS_PI_ATTACHED_ROOT; else process.env.TRELLIS_PI_ATTACHED_ROOT = previous; });
  const unrelated = resolve(f.base, 'unrelated');
  mkdirSync(unrelated);
  const ctx = { ...f.ctx, cwd: unrelated };
  assert.equal(f.fire('resources_discover', { cwd: unrelated }), undefined);
  assert.equal((await f.fire('tool_call', { ...call(), toolName: 'bash' }, ctx)).block, true);
  assert.doesNotMatch(f.fire('before_agent_start', { systemPrompt: 'parent' }, ctx).systemPrompt, /attached policy/);
  const nested = resolve(f.cwd, 'nested');
  mkdirSync(nested);
  assert.deepEqual(f.fire('resources_discover', { cwd: nested }), { skillPaths: [resolve(f.cwd, '.agents/skills')], promptPaths: [resolve(f.cwd, '.agents/commands')] });
  assert.match(f.fire('before_agent_start', { systemPrompt: 'parent' }, { ...f.ctx, cwd: nested }).systemPrompt, /attached policy/);
});

for (const kind of ['file-anchor', 'dangling', 'config-missing', 'config-directory']) {
  test(`invalid nearer ${kind} anchor cannot inherit a valid parent`, async t => {
    const f = fixture(t);
    const nested = f.attach('attached/nested');
    const runtime = resolve(nested, '.trellis/runtime');
    if (kind === 'file-anchor' || kind === 'dangling') {
      rmSync(runtime, { recursive: true });
      if (kind === 'file-anchor') writeFileSync(runtime, 'not a runtime directory');
      else symlinkSync(resolve(f.base, 'absent-runtime'), runtime);
    } else {
      rmSync(resolve(runtime, 'trellis.config.json'));
      if (kind === 'config-directory') mkdirSync(resolve(runtime, 'trellis.config.json'));
    }
    const cwd = resolve(nested, 'child');
    mkdirSync(cwd);
    const ctx = { ...f.ctx, cwd };
    assert.equal(f.fire('resources_discover', { cwd }), undefined);
    const start = f.fire('before_agent_start', { systemPrompt: 'parent' }, ctx);
    assert.equal(start.systemPrompt, 'parent');
    assert.match(start.message.content, /runtime.*unknown/i);
    for (const toolName of ['read', 'write', 'bash', 'Agent', 'SubagentWorkflow']) {
      const blocked = await f.fire('tool_call', { ...call(), toolName }, ctx);
      assert.equal(blocked.block, true);
      assert.match(blocked.reason, /runtime.*unknown/i);
    }
    const bash = await f.bash({ cwd });
    assert.equal(bash.result.exitCode, 1);
    assert.match(bash.result.output, /runtime.*unknown/i);
    const post = await f.fire('tool_result', result(), ctx);
    assert.match(post.content[0].text, /capability: unknown/);
    assert.equal(f.calls.length, 0);
  });
}

test('valid nested symlink runtime selects its own root instead of the parent', async t => {
  const f = fixture(t);
  const nested = f.attach('attached/nested');
  const runtime = resolve(nested, '.trellis/runtime');
  const release = resolve(f.base, 'scratch-release');
  renameSync(runtime, release);
  symlinkSync(release, runtime);
  const cwd = resolve(nested, 'child');
  mkdirSync(cwd);
  const ctx = { ...f.ctx, cwd };
  assert.deepEqual(f.fire('resources_discover', { cwd }), { skillPaths: [resolve(nested, '.agents/skills')], promptPaths: [resolve(nested, '.agents/commands')] });
  assert.match(f.fire('before_agent_start', { systemPrompt: 'parent' }, ctx).systemPrompt, /attached\/nested policy/);
  const read = call('nested-read');
  writeFileSync(resolve(cwd, 'file'), 'nested target');
  assert.equal(await f.fire('tool_call', read, ctx), undefined);
  assert.equal(f.calls.length, 0); // Read pre-action is entirely in-process.
  await f.fire('tool_result', result(read), ctx);
  await assertWriteCredit(f, 'file', true, ctx);
  assert.equal(f.calls.length, 0, 'read pre/post and credited writes stay local');
  await f.fire('tool_call', { toolCallId: 'nested-pr', toolName: 'bash', input: { command: 'gh pr create' } }, ctx);
  assert.equal(f.calls[0].options.cwd, nested);
  assert.equal(f.calls[0].script, resolve(runtime, 'core-rules/pi/hooks/dispatch.sh'));
});

for (const toolName of ['Agent', 'SubagentWorkflow']) {
  test(`exact ${toolName} requires parent policy`, async t => {
    const f = fixture(t);
    const ctx = { ...f.ctx, cwd: f.attach('missing', false) };
    const blocked = await f.fire('tool_call', { ...call(), toolName }, ctx);
    assert.equal(blocked?.block, true);
    assert.match(blocked.reason, /parent policy is missing/);
    assert.equal(f.calls.length, 0);
    const diagnostic = f.fire('before_agent_start', { systemPrompt: 'parent' }, ctx).message.content;
    assert.match(diagnostic, /Agent/);
    assert.match(diagnostic, /SubagentWorkflow/);
  });

  test(`${toolName} with policy exposes unsupported mediation without dispatch`, async t => {
    const f = fixture(t);
    f.decision = { schema_version: 1, capability_status: 'unsupported', decision: 'allow', reason: `${toolName} child mediation unsupported` };
    const event = { ...call(toolName), toolName };
    assert.equal(await f.fire('tool_call', event), undefined);
    const post = await f.fire('tool_result', result(event));
    assert.match(post.content[0].text, /capability: unsupported/);
    assert.match(post.content[0].text, /pre_action\/local_tool: unsupported — no pre-action handler/);
    assert.match(post.content[0].text, /post_action\/local_tool: unsupported — no post-action handler/);
    assert.equal(f.calls.length, 0);
  });
}

test('pure builtin searches pass without policy; unknown tools refuse without file read credit', async t => {
  const f = fixture(t);
  const ctx = { ...f.ctx, cwd: f.attach('missing', false) };
  for (const toolName of ['grep', 'find', 'ls']) {
    const event = { ...call(toolName), toolName };
    assert.equal(await f.fire('tool_call', event, ctx), undefined);
    const post = await f.fire('tool_result', result(event), ctx);
    assert.match(post?.content?.[0]?.text ?? '', /capability: unsupported|^$/);
  }
  for (const toolName of ['agent', 'custom']) assert.equal((await f.fire('tool_call', { ...call(toolName), toolName }, ctx)).block, true);
  assert.equal(f.calls.length, 0);
});

test('read credit retains the captured pre-action target after trusted handler mutation', async t => {
  const f = fixture(t);
  for (const path of ['original', 'changed']) writeFileSync(resolve(f.cwd, path), path);
  const event = call('snapshot', { path: 'original', nested: { values: ['original'] } });
  await f.fire('tool_call', event);
  event.input.path = 'changed';
  event.input.nested.values[0] = 'changed';
  await f.fire('tool_result', result(event));
  await assertWriteCredit(f, 'original', true);
  await assertWriteCredit(f, 'changed', false);
  assert.equal(f.calls.length, 0);
});

test('allow inventory dedupes by capability and reason; every context and warning survives', async t => {
  const f = fixture(t);
  for (const capability_status of ['unsupported', 'advisory']) {
    f.decision = { schema_version: 1, capability_status, decision: 'allow', reason: 'inventory', context: 'context' };
    for (let i = 0; i < 2; i++) await f.fire('agent_settled');
    assert.match(f.messages.at(-2)[0].content, /inventory/);
    assert.doesNotMatch(f.messages.at(-1)[0].content, /inventory/);
    assert.match(f.messages.at(-1)[0].content, /context/);
  }
  for (const [capability_status, decision] of [['unsupported', 'warn'], ['unsupported', 'deny'], ['unknown', 'allow']]) {
    f.decision = { schema_version: 1, capability_status, decision, reason: 'inventory', context: 'context' };
    for (let i = 0; i < 2; i++) await f.fire('agent_settled');
    for (const message of f.messages.slice(-2)) assert.match(message[0].content, /context\n\ninventory/);
  }
  assert.equal(f.notifications.length, 4);
});

test('startup and compact preserve undelivered contexts; session start resets pending actions and inventory', async t => {
  const f = fixture(t);
  f.decision = { schema_version: 1, capability_status: 'unsupported', decision: 'allow', reason: 'inventory', context: 'startup' };
  await f.fire('session_start');
  f.decision.context = 'compact';
  await f.fire('session_compact');
  assert.match(f.turn().message.content, /startup[\s\S]*compact/);
  for (const path of ['old', 'new']) writeFileSync(resolve(f.cwd, path), path);
  const old = call('old', { path: 'old' });
  await f.fire('tool_call', old);
  f.decision.context = 'replacement';
  await f.fire('session_start');
  const next = f.turn().message.content;
  assert.match(next, /inventory/);
  assert.doesNotMatch(next, /startup|compact/);
  f.decision = { schema_version: 1, capability_status: 'enforced', decision: 'allow' };
  const dispatches = f.calls.length;
  const fresh = call('old', { path: 'new' });
  await f.fire('tool_call', fresh);
  assert.equal(await f.fire('tool_result', result(old)), undefined);
  await assertWriteCredit(f, 'old', false);
  await assertWriteCredit(f, 'new', false);
  await f.fire('tool_result', result(fresh));
  await assertWriteCredit(f, 'new', true);
  assert.equal(f.calls.length, dispatches, 'late old-generation results neither dispatch nor consume the fresh read');
});

test('shutdown clears pending context/actions/sequence without enqueueing next-session messages', async t => {
  const f = fixture(t);
  await f.bash();
  f.decision = { schema_version: 1, capability_status: 'advisory', decision: 'warn', reason: 'old warning' };
  await f.fire('session_compact');
  for (const path of ['old', 'new']) writeFileSync(resolve(f.cwd, path), path);
  const old = call('old', { path: 'old' });
  await f.fire('tool_call', old);
  await f.fire('session_shutdown');
  assert.equal(f.messages.length, 0);
  assert.equal(f.turn().message, undefined);
  f.decision = { schema_version: 1, capability_status: 'enforced', decision: 'allow' };
  const dispatches = f.calls.length;
  assert.equal(await f.fire('tool_result', result(old)), undefined);
  assert.equal(await f.fire('tool_result', result(call('orphan', { path: 'new' }))), undefined);
  await assertWriteCredit(f, 'old', false);
  await assertWriteCredit(f, 'new', false);
  assert.equal(f.calls.length, dispatches);
  await f.bash();
  assert.equal(f.calls.at(-1).event.action.id, 'user-bash:1');
});

test('user bash chooses event cwd attachment, envelope and dispatcher while retaining session and signal', async t => {
  const f = fixture(t);
  const other = f.attach('other');
  await f.bash({ cwd: other });
  const observed = f.calls.at(-1);
  assert.equal(observed.event.cwd, other);
  assert.equal(observed.options.cwd, other);
  assert.equal(observed.script, resolve(other, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh'));
  assert.equal(observed.options.signal, f.ctx.signal);
  assert.equal(observed.event.session_id, 'session');
  assert.equal(observed.event.session_file, '/fixture/session.jsonl');
  assert.equal((await f.bash({ cwd: f.attach('absent-policy', false) })).result.exitCode, 1);
  assert.equal(f.calls.length, 1);
});

test('excluded user bash neither messages nor consumes inventory delivery; denies still enforce and notify', async t => {
  const f = fixture(t);
  f.decision = { schema_version: 1, capability_status: 'unsupported', decision: 'allow', reason: 'inventory', context: 'private context' };
  assert.equal(await f.bash({ excludeFromContext: true }), undefined);
  assert.equal(f.messages.length, 0);
  await f.bash();
  assert.match(f.messages[0][0].content, /inventory/);
  f.decision.decision = 'deny';
  assert.equal((await f.bash({ excludeFromContext: true })).result.exitCode, 1);
  assert.equal(f.messages.length, 1);
  assert.equal(f.notifications.length, 1);
});
