// Scratch dispatcher + stub ExtensionAPI contract tests; not a native SDK/session proof.
// Run with Node >=24: node --test core-rules/pi/tests/advisory-transport.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import extension from '../extensions/trellis.ts';

const dispatcher = new URL('../hooks/dispatch.sh', import.meta.url);
function fixture(t) {
  const cwd = mkdtempSync(resolve(tmpdir(), 'trellis-advisory-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  for (const dir of ['.trellis/runtime/core-rules/pi/hooks', '.agents/rules', '.pi/hooks']) mkdirSync(resolve(cwd, dir), { recursive: true });
  copyFileSync(dispatcher, resolve(cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh'));
  writeFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), '{}');
  writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Scratch policy');
  const hook = (name, body) => writeFileSync(resolve(cwd, '.pi/hooks', name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  const event = (phase, native_event, family = 'file_read') => ({ schema_version: 1, harness: 'pi', cwd, session_id: 'scratch', phase, native_event, action: { family, tool_name: family === 'shell' ? 'bash' : 'read', input: { path: 'file' }, targets: [] }, result: phase === 'post_action' ? { status: 'succeeded', is_error: false, output: [] } : null });
  const run = (event, env = {}) => {
    const result = spawnSync('bash', [dispatcher.pathname, '--base64', Buffer.from(JSON.stringify(event)).toString('base64')], { cwd, env: { ...process.env, ...env }, encoding: 'utf8' });
    return { ...result, decision: JSON.parse(result.stdout) };
  };
  const handlers = new Map();
  const messages = [];
  const notifications = [];
  const pi = {
    on: (name, handler) => handlers.set(name, handler),
    getAllTools: () => [],
    sendMessage: (...args) => messages.push(args),
    exec: async (_script, args) => {
      const result = run(JSON.parse(Buffer.from(args[1], 'base64').toString()));
      return { stdout: result.stdout, stderr: result.stderr, code: result.status, killed: false };
    },
  };
  extension(pi);
  const ctx = { cwd, ui: { notify: (...args) => notifications.push(args) }, sessionManager: { getSessionId: () => 'scratch', getSessionFile: () => undefined } };
  return { cwd, hook, event, run, pi, handlers, messages, notifications, ctx };
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
  const patch = await f.handlers.get('tool_result')({ toolCallId: 'read-1', toolName: 'read', input: { path: 'file' }, content: original, details: { retained: true }, isError: true }, f.ctx);
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
  assert.equal(f.run(f.event('post_action', 'tool_result')).decision.decision, 'allow');
  const patch = await f.handlers.get('tool_result')({ toolCallId: 'x', toolName: 'read', input: {}, content: [], isError: false }, f.ctx);
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
    f.pi.exec = async () => response;
    const compact = await f.handlers.get('session_before_compact')({ reason: 'manual' }, f.ctx);
    assert.equal(compact, undefined);
    const patch = await f.handlers.get('tool_result')({ toolCallId: 'x', toolName: 'read', input: {}, content: [], isError: false }, f.ctx);
    assert.match(patch.content[0].text, /capability: unknown/);
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
  f.hook('block-destructive.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"pre sentinel"}}'`);
  f.hook('pr-gate-shiftleft.sh', 'exit 0');
  f.hook('truncation-check.sh', 'exit 0');
  const call = { toolCallId: 'shell', toolName: 'bash', input: { command: 'pwd' } };
  assert.equal(await f.handlers.get('tool_call')(call, f.ctx), undefined);
  const result = await f.handlers.get('tool_result')({ ...call, content: [], isError: false }, f.ctx);
  assert.match(result.content[0].text, /pre sentinel/);
  await f.handlers.get('user_bash')({ command: 'pwd', cwd: f.cwd, excludeFromContext: false }, f.ctx);
  assert.match(f.messages[0][0].content, /pre sentinel/);
  assert.equal(f.messages[0][1].deliverAs, 'nextTurn');
  f.hook('block-destructive.sh', `printf '%s\\n' '{"decision":"block","reason":"deny sentinel"}'`);
  assert.equal((await f.handlers.get('tool_call')(call, f.ctx)).block, true);
  assert.equal((await f.handlers.get('user_bash')({ command: 'pwd', cwd: f.cwd, excludeFromContext: false }, f.ctx)).result.exitCode, 1);
});

test('unsupported reads stay model visible without UI fatigue; genuine errors stay visible', async t => {
  const f = fixture(t);
  f.hook('truncation-check.sh', 'exit 0');
  f.hook('track-read.sh', 'exit 0');
  const call = { toolCallId: 'r', toolName: 'read', input: { path: 'file' } };
  await f.handlers.get('tool_call')(call, f.ctx);
  assert.equal(f.notifications.length, 0);
  const result = await f.handlers.get('tool_result')({ ...call, content: [], isError: false }, f.ctx);
  assert.match(result.content[0].text, /unsupported.*no pre-action handler/);
  for (const response of [
    { capability_status: 'unknown', decision: 'warn', reason: 'unknown sentinel' },
    { capability_status: 'unsupported', decision: 'deny', reason: 'deny sentinel' },
    { capability_status: 'unsupported', decision: 'warn', reason: 'unsupported observation' },
  ]) {
    f.pi.exec = async () => ({ stdout: JSON.stringify({ schema_version: 1, ...response }), stderr: 'stderr sentinel', code: 0 });
    await f.handlers.get('tool_call')(call, f.ctx);
  }
  assert.equal(f.notifications.length, 3);
});

for (const reason of ['startup', 'resume']) {
  test(`${reason} retains labelled previous-session history but repeated compact never rereads it`, async t => {
    const f = fixture(t);
    writeFileSync(resolve(f.cwd, 'context-log.md'), 'stale context sentinel');
    f.hook('session-context.sh', `jq --rawfile history "$CODEX_PROJECT_DIR/context-log.md" '{hookSpecificOutput:{additionalContext:("context-log.md (previous session) — " + .source + "\\n" + $history)}}'`);
    f.hook('post-compact-context.sh', `jq -n --rawfile history "$CODEX_PROJECT_DIR/context-log.md" '{hookSpecificOutput:{additionalContext:("WRONG portable recovery: " + $history)}}'`);
    f.hook('inject-primer-index.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"applicable primer sentinel"}}'`);
    await f.handlers.get('session_start')({ reason }, f.ctx);
    const start = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
    assert.match(start.message.content, new RegExp('context-log.md \\(previous session\\) — ' + reason));
    assert.match(start.message.content, /stale context sentinel/);
    assert.doesNotMatch(start.message.content, /WRONG portable recovery/);
    for (let i = 0; i < 2; i++) {
      const observed = f.run(f.event('lifecycle', 'session_compact'));
      assert.equal(observed.status, 0);
      assert.match(observed.decision.reason, /unsupported.*portable.*recovery.*not wired/);
      await f.handlers.get('session_compact')({ reason: 'manual' }, f.ctx);
      const next = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
      assert.doesNotMatch(next.message.content, /stale context sentinel|previous session|WRONG portable recovery/);
      assert.match(next.message.content, /applicable primer sentinel/);
      // Machine observations persist; routine model notices dedupe per session.
      if (i === 0) assert.match(next.message.content, /unsupported.*portable.*recovery.*not wired/);
      else assert.doesNotMatch(next.message.content, /unsupported.*portable.*recovery.*not wired/);
    }
  });
}

test('session compact preserves both reason and context for the next agent start', async t => {
  const f = fixture(t);
  f.pi.exec = async () => ({ stdout: JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision: 'warn', context: 'compact context', reason: 'compact reason' }), stderr: '', code: 0 });
  await f.handlers.get('session_compact')({ reason: 'manual' }, f.ctx);
  const next = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx);
  assert.match(next.message.content, /compact context/);
  assert.match(next.message.content, /compact reason/);
});
