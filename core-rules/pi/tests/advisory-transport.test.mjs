// Scratch dispatcher + stub ExtensionAPI contract tests; not a native SDK/session proof.
// Run with Node >=24: node --test core-rules/pi/tests/advisory-transport.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import extension, { decisionContext, deliverPostResult } from '../extensions/trellis.ts';
import { realDispatchExec, mockDispatchExec } from './dispatch-test-transport.mjs';

const dispatcher = new URL('../hooks/dispatch.sh', import.meta.url);
function fixture(t) {
  const cwd = mkdtempSync(resolve(tmpdir(), 'trellis-advisory-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  for (const dir of ['.trellis/runtime/core-rules/pi/hooks', '.agents/rules', '.trellis/runtime/core-rules/codex/hooks']) mkdirSync(resolve(cwd, dir), { recursive: true });
  copyFileSync(dispatcher, resolve(cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh'));
  writeFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), '{}');
  writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Scratch policy');
  const hook = (name, body) => writeFileSync(resolve(cwd, '.trellis/runtime/core-rules/codex/hooks', name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  const event = (phase, native_event, family = 'file_read') => ({ schema_version: 1, harness: 'pi', cwd, session_id: 'scratch', phase, native_event, action: { family, tool_name: family === 'shell' ? 'bash' : 'read', input: { path: 'file' }, targets: [] }, result: phase === 'post_action' ? { status: 'succeeded', is_error: false, output: [] } : null });
  const run = (event, env = {}) => {
    const result = spawnSync('bash', [dispatcher.pathname, '--base64', Buffer.from(JSON.stringify(event)).toString('base64')], { cwd, env: { ...process.env, ...env }, encoding: 'utf8' });
    return { ...result, decision: JSON.parse(result.stdout.split('\n')[0]) };
  };
  const handlers = new Map();
  const messages = [];
  const notifications = [];
  const pi = {
    on: (name, handler) => handlers.set(name, name === 'before_agent_start' ? (event, ctx) => handler({ messageType: 'user', ...event }, ctx) : handler),
    // Pi 0.85 builtin metadata: the extension refuses read/edit/write/bash
    // whose provenance is not a single builtin (ccbe6a0c7).
    getAllTools: () => ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'].map(name => ({
      name, sourceInfo: { path: `<builtin:${name}>`, source: 'builtin', scope: 'temporary', origin: 'top-level', baseDir: undefined },
    })),
    sendMessage: (...args) => messages.push(args),
    exec: realDispatchExec(async (_script, args, options) => {
      const event = args[0] === '--event-file' ? JSON.parse(readFileSync(args[1], 'utf8')) : JSON.parse(Buffer.from(args[1], 'base64').toString());
      const result = run(event, options.env);
      return { stdout: result.stdout, stderr: result.stderr, code: result.status, killed: false };
    }),
  };
  extension(pi);
  const ctx = { cwd, ui: { notify: (...args) => notifications.push(args) }, sessionManager: { getSessionId: () => 'scratch', getSessionFile: () => undefined } };
  // Synthetic compatibility decisions exercise delivery, not the local evaluator.
  const deliveredReasons = new Set();
  const deliver = (event, decision, pre) => deliverPostResult(pi, { notify: ctx.ui.notify }, event, pre, decision, deliveredReasons);
  const readPreContext = () => {
    const context = decisionContext({ schema_version: 1, capability_status: 'unsupported', decision: 'allow', reason: 'pre_action/file_read: unsupported — no pre-action handler' }, deliveredReasons);
    return { context: context ? `[Trellis pre-action advisory; capability: unsupported]\n${context}` : '', capabilityOnly: true };
  };
  return { cwd, hook, event, run, pi, handlers, messages, notifications, ctx, deliver, readPreContext };
}

test('mixed streams retain structured context and reason, including in tool-result patch', async t => {
  const f = fixture(t);
  f.hook('truncation-check.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"context sentinel"},"reason":"reason sentinel"}'\nprintf '%s\\n' 'stderr sentinel' >&2`);
  f.hook('track-read.sh', 'exit 0');
  const result = f.run(f.event('post_action', 'tool_result'));
  assert.equal(result.status, 0);
  assert.equal(result.decision.context, 'context sentinel');
  assert.match(result.decision.reason, /reason sentinel/);
  assert.match(result.decision.reason, /stderr sentinel/);
  assert.equal(result.decision.decision, 'warn');
  const original = [{ type: 'text', text: 'original result' }, { type: 'image', data: 'AA==', mimeType: 'image/png' }];
  const patch = f.deliver({ toolCallId: 'read-1', toolName: 'read', input: { path: 'file' }, content: original, details: { retained: true }, isError: true }, result.decision);
  assert.deepEqual(patch.content.slice(0, 2), original);
  assert.match(patch.content[2].text, /context sentinel/);
  assert.match(patch.content[2].text, /reason sentinel/);
  assert.match(patch.content[2].text, /stderr sentinel/);
  assert.deepEqual(Object.keys(patch), ['content']); // SDK partial patch preserves details/isError/usage.
  assert.equal(original.length, 2);
});

test('allow plus pure context reaches the model-visible tool result', async t => {
  const f = fixture(t);
  f.hook('truncation-check.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"pure context"}}'`);
  f.hook('track-read.sh', 'exit 0');
  const { decision } = f.run(f.event('post_action', 'tool_result'));
  assert.equal(decision.decision, 'allow');
  const patch = f.deliver({ toolCallId: 'x', toolName: 'read', input: {}, content: [], isError: false }, decision);
  assert.match(patch.content[0].text, /pure context/);
});

test('managed denying hook wins over inherited allowing override', t => {
  const f = fixture(t);
  const alternate = resolve(f.cwd, 'alternate');
  mkdirSync(alternate);
  writeFileSync(resolve(alternate, 'block-destructive.sh'), '#!/bin/bash\nexit 0\n', { mode: 0o755 });
  f.hook('block-destructive.sh', `printf '%s\\n' '{"decision":"block","reason":"managed deny"}'`);
  const result = f.run(f.event('pre_action', 'tool_call', 'shell'), { TRELLIS_PI_HOOKS: alternate });
  assert.equal(result.status, 1);
  assert.equal(result.decision.decision, 'deny');
  assert.equal(result.decision.capability_status, 'enforced');
  assert.match(result.decision.reason, /managed deny/);
});

test('missing dispatcher never cancels compaction but blocks mutation', async t => {
  const f = fixture(t);
  rmSync(resolve(f.cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh'));
  const compact = await f.handlers.get('session_before_compact')({ reason: 'manual', willRetry: false }, f.ctx);
  assert.equal(compact, undefined);
  assert.match(f.messages[0][0].content, /dispatcher is missing/);
  assert.equal(f.messages[0][1].deliverAs, 'nextTurn');
  const call = await f.handlers.get('tool_call')({ toolCallId: 'w', toolName: 'write', input: { path: 'file' } }, f.ctx);
  assert.equal(call.block, true);
});

test('malformed optional fields and execution failure stay visible and advisory after action', async t => {
  const f = fixture(t);
  for (const response of [
    { stdout: '{"schema_version":1,"capability_status":"advisory","decision":"allow","context":{}}', stderr: '', code: 0 },
    { stdout: '', stderr: 'bridge failed', code: 2 },
  ]) {
    f.pi.exec = mockDispatchExec(async () => response);
    const compact = await f.handlers.get('session_before_compact')({ reason: 'manual' }, f.ctx);
    assert.equal(compact, undefined);
    const reason = response.stderr || `Trellis Pi dispatcher failed completion or decision validation (status ${response.code})`;
    assert.ok(f.messages.at(-1)[0].content.includes(reason));
    assert.deepEqual(f.notifications.at(-1), [reason, 'warning']);
    const patch = f.deliver({ toolCallId: 'x', toolName: 'read', input: {}, content: [], isError: false }, { schema_version: 1, capability_status: 'unknown', decision: 'deny', reason });
    assert.match(patch.content[0].text, /capability: unknown/);
    assert.ok(patch.content[0].text.includes(reason));
    assert.deepEqual(f.notifications.at(-1), [reason, 'warning']);
  }
});

test('unwired required checks are named unsupported and no-handler events do not claim enforcement', async t => {
  const f = fixture(t);
  for (const name of ['spec-gate.sh', 'decision-receipt.sh', 'primer-capture-nudge.sh', 'ui-verify.sh', 'stamp-turn.sh']) f.hook(name, 'exit 0');
  const result = f.run(f.event('lifecycle', 'agent_settled'));
  assert.equal(result.status, 0);
  for (const name of ['save-context-log.sh', 'stop-verify.sh', 'code-review-subagent.sh', 'propose-rules.sh']) assert.ok(result.decision.reason.includes(`${name}: unsupported`));
  await f.handlers.get('agent_settled')({}, f.ctx);
  assert.match(f.messages[0][0].content, /stop-verify.sh: unsupported/);
  const pre = f.run(f.event('pre_action', 'tool_call'));
  assert.equal(pre.decision.capability_status, 'unsupported');
});

test('unhandled post families, failed mutation, and shutdown report explicit unsupported reasons', t => {
  const f = fixture(t);
  for (const family of ['mcp', 'local_tool', 'unknown']) {
    const result = f.run(f.event('post_action', 'tool_result', family));
    assert.equal(result.decision.capability_status, 'unsupported');
    assert.match(result.decision.reason, /no post-action handler/);
  }
  const failed = f.event('post_action', 'tool_result', 'file_mutation');
  failed.result.status = 'failed';
  failed.result.is_error = true;
  const result = f.run(failed);
  assert.equal(result.decision.capability_status, 'unsupported');
  assert.match(result.decision.reason, /skipped.*failed result/);
  const shutdown = f.run(f.event('lifecycle', 'session_shutdown'));
  assert.equal(shutdown.decision.capability_status, 'unsupported');
  assert.match(shutdown.decision.reason, /no shutdown handler/);
});

test('startup names unwired inventory without running it or raising routine UI warnings', async t => {
  const f = fixture(t);
  for (const name of ['session-context.sh', 'post-compact-context.sh', 'inject-primer-index.sh']) f.hook(name, 'exit 0');
  const names = ['skill-preload-guard.sh', 'skill-slash-guard.sh', 'skill-size-preflight.sh', 'env-echo.sh'];
  for (const name of names) f.hook(name, 'exit 99');
  await f.handlers.get('session_start')({ reason: 'startup' }, f.ctx);
  const start = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
  for (const name of names) assert.ok(start.message.content.includes(`${name}: unsupported`));
  assert.equal(f.notifications.length, 0);
});

test('policy dedupe compares exact current block and preserves other parent text', t => {
  const f = fixture(t);
  const old = 'parent\n<trellis_parent_policy>\nOther project policy\n</trellis_parent_policy>';
  const start = f.handlers.get('before_agent_start');
  const first = start({ systemPrompt: old }, f.ctx).systemPrompt;
  assert.ok(first.startsWith(old));
  assert.match(first, /Scratch policy/);
  assert.equal(start({ systemPrompt: first }, f.ctx).systemPrompt, first);
  writeFileSync(resolve(f.cwd, '.agents/rules/trellis.md'), 'Changed policy');
  const changed = start({ systemPrompt: first }, f.ctx).systemPrompt;
  assert.ok(changed.startsWith(first));
  assert.match(changed, /Changed policy/);
  assert.equal(start({ systemPrompt: changed }, f.ctx).systemPrompt, changed);
});

test('pre-action context survives tool result and user bash queues next-turn context', async t => {
  const f = fixture(t);
  f.hook('block-destructive.sh', 'exit 0');
  f.hook('pr-gate-shiftleft.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"pre sentinel"}}'`);
  f.hook('truncation-check.sh', 'exit 0');
  const call = { toolCallId: 'shell', toolName: 'bash', input: { command: 'gh pr create' } };
  assert.equal(await f.handlers.get('tool_call')(call, f.ctx), undefined);
  const result = await f.handlers.get('tool_result')({ ...call, content: [], isError: false }, f.ctx);
  assert.match(result.content[0].text, /pre sentinel/);
  await f.handlers.get('user_bash')({ command: 'gh pr create', cwd: f.cwd, excludeFromContext: false }, f.ctx);
  assert.match(f.messages[0][0].content, /pre sentinel/);
  assert.equal(f.messages[0][1].deliverAs, 'nextTurn');
  f.hook('block-destructive.sh', `printf '%s\\n' '{"decision":"block","reason":"deny sentinel"}'`);
  assert.equal((await f.handlers.get('tool_call')(call, f.ctx)).block, true);
  assert.equal((await f.handlers.get('user_bash')({ command: 'gh pr create', cwd: f.cwd, excludeFromContext: false }, f.ctx)).result.exitCode, 1);
});

test('unsupported reads stay model visible without UI fatigue; genuine errors stay visible', async t => {
  const f = fixture(t);
  f.hook('truncation-check.sh', 'exit 0');
  f.hook('track-read.sh', 'exit 0');
  const call = { toolCallId: 'r', toolName: 'read', input: { path: 'file' } };
  await f.handlers.get('tool_call')(call, f.ctx);
  assert.equal(f.notifications.length, 0);
  const result = await f.handlers.get('tool_result')({ ...call, content: [], isError: false }, f.ctx);
  assert.equal(result, undefined); // Capability-only notices must not alter read content.
  assert.equal(f.messages[0][0].customType, 'trellis-context');
  assert.match(f.messages[0][0].content, /unsupported.*no pre-action handler/);
  assert.deepEqual(f.messages[0][1], { triggerTurn: false });
  for (const response of [
    { capability_status: 'unknown', decision: 'warn', reason: 'unknown sentinel' },
    { capability_status: 'unsupported', decision: 'deny', reason: 'deny sentinel' },
    { capability_status: 'unsupported', decision: 'warn', reason: 'unsupported observation' },
  ]) {
    f.pi.exec = mockDispatchExec(async () => ({ stdout: JSON.stringify({ schema_version: 1, ...response }), stderr: 'stderr sentinel', code: 0 }));
    // Reads no longer cross the process boundary; exercise its errors on shell.
    await f.handlers.get('tool_call')({ toolCallId: 'shell-errors', toolName: 'bash', input: { command: 'gh pr create' } }, f.ctx);
  }
  assert.equal(f.notifications.length, 3);
});

test('capability-only successful reads remain byte-exact, dedupe across turns, and reset per session', async t => {
  const f = fixture(t);
  f.pi.exec = mockDispatchExec(async (_script, args) => {
    const event = JSON.parse(readFileSync(args[1], 'utf8'));
    assert.equal(event.phase, 'lifecycle', 'ordinary read pre/post must not dispatch');
    return { stdout: JSON.stringify({ schema_version: 1, capability_status: 'enforced', decision: 'allow' }), stderr: '', code: 0 };
  });
  const content = [
    { type: 'text', text: 'first\r\n\u0000é e\u0301\n' },
    { type: 'image', data: 'AAECA/8=', mimeType: 'image/png' },
    { type: 'text', text: 'last\t  \n' },
  ];
  const bytes = Buffer.from(JSON.stringify(content));
  async function read(id, ctx = f.ctx) {
    const call = { toolCallId: id, toolName: 'read', input: { path: 'file' } };
    const before = f.messages.length;
    assert.equal(await f.handlers.get('tool_call')(call, ctx), undefined);
    assert.equal(f.messages.length, before, 'wait for a successful result before separate delivery');
    const event = { ...call, content, details: { retained: true }, isError: false };
    const patch = await f.handlers.get('tool_result')(event, ctx);
    assert.equal(patch, undefined, 'pure capability notices must not patch a successful read');
    assert.strictEqual(event.content, content);
    assert.deepEqual(Buffer.from(JSON.stringify(patch?.content ?? event.content)), bytes);
  }
  await read('first');
  assert.equal(f.messages.length, 1);
  assert.equal(f.messages[0][0].customType, 'trellis-context');
  assert.equal(f.messages[0][0].display, false);
  assert.match(f.messages[0][0].content, /pre-action advisory.*capability: unsupported/);
  assert.match(f.messages[0][0].content, /no pre-action handler/);
  assert.deepEqual(f.messages[0][1], { triggerTurn: false }); // Not steering, nextTurn, or followUp.
  await read('repeat');
  f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
  await read('next-turn');
  assert.equal(f.messages.length, 1);
  const nextCtx = { ...f.ctx, sessionManager: { getSessionId: () => 'new', getSessionFile: () => undefined } };
  await f.handlers.get('session_start')({ reason: 'new' }, nextCtx);
  await read('new-session', nextCtx);
  assert.equal(f.messages.length, 2);
  assert.deepEqual(f.messages[1], f.messages[0]);
  assert.equal(f.notifications.length, 0);
});

for (const capability_status of ['unsupported', 'advisory']) {
  test(`capability-only ${capability_status} post-read notices go out-of-band once`, async t => {
    const f = fixture(t);
    const decision = { schema_version: 1, capability_status, decision: 'allow', reason: 'post capability sentinel' };
    const content = [{ type: 'text', text: 'exact\r\n' }, { type: 'image', data: 'AA==', mimeType: 'image/png' }];
    const bytes = Buffer.from(JSON.stringify(content));
    for (const toolCallId of ['first', 'repeat']) {
      // No pre entry also exercises post classification independently.
      const event = { toolCallId, toolName: 'read', input: {}, content, isError: false };
      assert.equal(f.deliver(event, decision), undefined);
      assert.strictEqual(event.content, content);
      assert.deepEqual(Buffer.from(JSON.stringify(content)), bytes);
    }
    assert.equal(f.messages.length, 1);
    assert.equal(f.messages[0][0].customType, 'trellis-context');
    assert.match(f.messages[0][0].content, /post capability sentinel/);
    assert.equal(f.messages[0][0].display, false);
    assert.deepEqual(f.messages[0][1], { triggerTurn: false });
    assert.equal(f.notifications.length, 0);
  });
}

test('pure pre/post read capability notices share one context-only message without result pollution', async t => {
  const f = fixture(t);
  const decision = { schema_version: 1, capability_status: 'advisory', decision: 'allow', reason: 'post sentinel' };
  const content = [{ type: 'text', text: 'exact\r\n' }, { type: 'image', data: 'AA==', mimeType: 'image/png' }];
  const bytes = Buffer.from(JSON.stringify(content));
  for (const toolCallId of ['first', 'repeat']) {
    const call = { toolCallId, toolName: 'read', input: { path: 'file' } };
    assert.equal(f.deliver({ ...call, content, isError: false }, decision, f.readPreContext()), undefined);
    assert.deepEqual(Buffer.from(JSON.stringify(content)), bytes);
  }
  assert.equal(f.messages.length, 1);
  assert.equal(f.messages[0][0].customType, 'trellis-context');
  assert.match(f.messages[0][0].content, /no pre-action handler/);
  assert.match(f.messages[0][0].content, /post sentinel/);
  assert.deepEqual(f.messages[0][1], { triggerTurn: false });
});

for (const response of [
  { capability_status: 'advisory', decision: 'allow', context: 'real context sentinel', reason: 'real context reason' },
  { capability_status: 'unsupported', decision: 'warn', reason: 'warn sentinel' },
  { capability_status: 'unsupported', decision: 'deny', reason: 'deny sentinel' },
]) {
  test(`read ${response.decision} with ${response.context ? 'real context' : 'non-allow reason'} stays inline`, async t => {
    const f = fixture(t);
    const decision = { schema_version: 1, ...response };
    const call = { toolCallId: 'read-control', toolName: 'read', input: { path: 'file' } };
    const original = [{ type: 'text', text: 'original' }, { type: 'image', data: 'AA==', mimeType: 'image/png' }];
    const bytes = Buffer.from(JSON.stringify(original));
    const patch = f.deliver({ ...call, content: original, isError: false }, decision, f.readPreContext());
    assert.deepEqual(patch.content.slice(0, original.length), original);
    assert.match(patch.content.at(-1).text, new RegExp(response.reason));
    if (response.context) assert.match(patch.content.at(-1).text, new RegExp(response.context));
    assert.doesNotMatch(patch.content.at(-1).text, /no pre-action handler/);
    assert.equal(f.messages.length, 1); // Only the pure pre-read capability moves out-of-band.
    assert.doesNotMatch(f.messages[0][0].content, /sentinel|real context reason/);
    assert.deepEqual(Object.keys(patch), ['content']);
    assert.deepEqual(Buffer.from(JSON.stringify(original)), bytes);
    assert.equal(f.notifications.length, response.decision === 'allow' ? 0 : 1);
    if (response.decision !== 'allow') assert.deepEqual(f.notifications[0], [response.reason, 'warning']);
  });
}

test('failed read capability notices retain existing inline behavior', async t => {
  const f = fixture(t);
  const decision = { schema_version: 1, capability_status: 'unsupported', decision: 'allow', reason: 'failed post sentinel' };
  const call = { toolCallId: 'failed', toolName: 'read', input: { path: 'file' } };
  const original = [{ type: 'text', text: 'read failure' }];
  const patch = f.deliver({ ...call, content: original, isError: true }, decision, f.readPreContext());
  assert.deepEqual(patch.content.slice(0, original.length), original);
  assert.match(patch.content.at(-1).text, /no pre-action handler/);
  assert.match(patch.content.at(-1).text, /failed post sentinel/);
  assert.equal(f.messages.length, 0);
});

for (const reason of ['startup', 'resume']) {
  test(`${reason} retains labelled previous-session history but repeated compact never rereads it`, async t => {
    const f = fixture(t);
    writeFileSync(resolve(f.cwd, 'context-log.md'), 'stale context sentinel');
    f.hook('session-context.sh', `jq --rawfile history "$CODEX_PROJECT_DIR/context-log.md" '{hookSpecificOutput:{additionalContext:("context-log.md (previous session) — " + .source + "\\n" + $history)}}'`);
    f.hook('post-compact-context.sh', `jq -n --rawfile history "$CODEX_PROJECT_DIR/context-log.md" '{hookSpecificOutput:{additionalContext:("WRONG portable recovery: " + $history)}}'`);
    f.hook('inject-primer-index.sh', `case "$(jq -r '.source')" in startup|resume) printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"applicable primer sentinel"}}' ;; esac`);
    await f.handlers.get('session_start')({ reason }, f.ctx);
    const start = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
    assert.match(start.message.content, new RegExp('context-log.md \\(previous session\\) — ' + reason));
    assert.match(start.message.content, /stale context sentinel/);
    assert.match(start.message.content, /applicable primer sentinel/);
    assert.doesNotMatch(start.message.content, /WRONG portable recovery/);
    for (let i = 0; i < 2; i++) {
      const observed = f.run(f.event('lifecycle', 'session_compact'));
      assert.equal(observed.status, 0);
      assert.match(observed.decision.reason, /unsupported.*portable.*recovery.*not wired/);
      await f.handlers.get('session_compact')({ reason: 'manual' }, f.ctx);
      const next = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
      assert.doesNotMatch(next.message.content, /stale context sentinel|previous session|WRONG portable recovery/);
      assert.doesNotMatch(next.message.content, /applicable primer sentinel/);
      assert.match(next.message.content, /task-context v1:/);
      // Machine observations persist; routine model notices dedupe per session.
      if (i === 0) assert.match(next.message.content, /unsupported.*portable.*recovery.*not wired/);
      else assert.doesNotMatch(next.message.content, /unsupported.*portable.*recovery.*not wired/);
    }
  });
}

test('session compact preserves both reason and context for the next agent start', async t => {
  const f = fixture(t);
  f.pi.exec = mockDispatchExec(async () => ({ stdout: JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision: 'warn', context: 'compact context', reason: 'compact reason' }), stderr: '', code: 0 }));
  await f.handlers.get('session_compact')({ reason: 'manual' }, f.ctx);
  const next = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
  assert.match(next.message.content, /compact context/);
  assert.match(next.message.content, /compact reason/);
});
