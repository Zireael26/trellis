// Stub ExtensionAPI boundary regressions; not native execution or trust/loading proof.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync, renameSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import extension from '../extensions/trellis.ts';

function fixture(t) {
  const base = mkdtempSync(resolve(tmpdir(), 'trellis-boundaries-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const attach = (name, policy = true) => {
    const root = resolve(base, name);
    mkdirSync(resolve(root, '.trellis/runtime/core-rules/pi/hooks'), { recursive: true });
    writeFileSync(resolve(root, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh'), 'fixture');
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
    on: (name, handler) => handlers.set(name, handler),
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
    exec: async (script, args, options) => {
      calls.push({ script, options, event: JSON.parse(Buffer.from(args[1], 'base64').toString()) });
      return { stdout: JSON.stringify(f.decision), stderr: '', code: 0 };
    },
  };
  extension(pi);
  f.ctx = { cwd, signal: new AbortController().signal, ui: { notify: (...args) => notifications.push(args) },
    sessionManager: { getSessionId: () => 'session', getSessionFile: () => '/fixture/session.jsonl' } };
  f.fire = (name, event = {}, ctx = f.ctx) => handlers.get(name)(event, ctx);
  f.turn = () => f.fire('before_agent_start', { systemPrompt: 'parent' });
  f.bash = (extra = {}) => f.fire('user_bash', { command: 'pwd', cwd, excludeFromContext: false, ...extra });
  return f;
}
const call = (id = 'r', input = { path: 'file' }) => ({ toolCallId: id, toolName: 'read', input });
const result = (event = call()) => ({ ...event, content: [], isError: false });

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
  assert.equal(await f.fire('tool_call', call(), ctx), undefined);
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

  test(`${toolName} with policy dispatches and exposes unsupported mediation`, async t => {
    const f = fixture(t);
    f.decision = { schema_version: 1, capability_status: 'unsupported', decision: 'allow', reason: `${toolName} child mediation unsupported` };
    const event = { ...call(toolName), toolName };
    assert.equal(await f.fire('tool_call', event), undefined);
    const action = f.calls.at(-1).event.action;
    assert.equal(action.family, 'local_tool');
    assert.equal(action.target_coverage, 'none');
    assert.deepEqual(action.targets, []);
    const post = await f.fire('tool_result', result(event));
    assert.match(post.content[0].text, /capability: unsupported/);
    assert.match(post.content[0].text, /child mediation unsupported/);
  });
}

test('builtin searches and unknown tools bypass only the policy guard without file read credit', async t => {
  const f = fixture(t);
  const ctx = { ...f.ctx, cwd: f.attach('missing', false) };
  for (const toolName of ['grep', 'find', 'ls', 'agent', 'custom']) {
    assert.equal(await f.fire('tool_call', { ...call(toolName), toolName }, ctx), undefined);
    const action = f.calls.at(-1).event.action;
    assert.equal(action.tool_name, toolName);
    assert.equal(action.family, ['grep', 'find', 'ls'].includes(toolName) ? 'local_tool' : 'unknown');
    assert.equal(action.target_coverage, 'none');
    assert.deepEqual(action.targets, []);
  }
  assert.equal(f.calls.length, 5);
});

test('post envelope retains deep pre-input snapshot after trusted handler mutation', async t => {
  const f = fixture(t);
  const event = call('snapshot', { path: 'original', nested: { values: ['original'] } });
  await f.fire('tool_call', event);
  event.input.path = 'changed';
  event.input.nested.values[0] = 'changed';
  await f.fire('tool_result', result(event));
  assert.deepEqual(f.calls.at(-1).event.action.input, { path: 'original', nested: { values: ['original'] } });
  assert.equal(f.calls.at(-1).event.action.targets[0].path, 'original');
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
  await f.fire('tool_call', call('old', { path: 'old' }));
  f.decision.context = 'replacement';
  await f.fire('session_start');
  const next = f.turn().message.content;
  assert.match(next, /inventory/);
  assert.doesNotMatch(next, /startup|compact/);
  f.decision = { schema_version: 1, capability_status: 'enforced', decision: 'allow' };
  assert.equal(await f.fire('tool_result', result(call('old', { path: 'new' }))), undefined);
  assert.equal(f.calls.at(-1).event.action.input.path, 'new');
});

test('shutdown clears pending context/actions/sequence without enqueueing next-session messages', async t => {
  const f = fixture(t);
  await f.bash();
  f.decision = { schema_version: 1, capability_status: 'advisory', decision: 'warn', reason: 'old warning' };
  await f.fire('session_compact');
  await f.fire('tool_call', call('old', { path: 'old' }));
  await f.fire('session_shutdown');
  assert.equal(f.messages.length, 0);
  assert.equal(f.turn().message, undefined);
  f.decision = { schema_version: 1, capability_status: 'enforced', decision: 'allow' };
  assert.equal(await f.fire('tool_result', result(call('old', { path: 'new' }))), undefined);
  assert.equal(f.calls.at(-1).event.action.input.path, 'new');
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
