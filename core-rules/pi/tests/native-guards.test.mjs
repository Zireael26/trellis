// Native callback boundary regressions (not a model run). Explicit blocking
// returns backstop pi >=1.4's throw-to-block contract on older hosts too.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { deliveredFixture } from './delivered-fixture.mjs';

const allow = { stdout: '{"schema_version":1,"capability_status":"enforced","decision":"allow"}', stderr: '', code: 0 };
const turn = f => f.fire('before_agent_start', { messageType: 'user', systemPrompt: 'parent' });
const write = f => f.fire('tool_call', f.call('write', { path: 'file' }));

for (const [file, contents] of [['destructive.json', undefined], ['destructive.json', '{'], ['destructive.json', '{"schema_version":1,"guard":"block-destructive","rules":[]}'], ['reread.json', '{}']]) {
  test(`unavailable guard data ${file}/${contents ?? 'missing'} blocks at both execution gates`, async t => {
    const f = await deliveredFixture(t, undefined, runtime => {
      const path = resolve(runtime, 'core-rules/hooks/rules', file);
      if (contents === undefined) rmSync(path); else writeFileSync(path, contents);
    });
    assert.ok(f.handlers.has('tool_call'), 'a load failure must leave the blocking handler installed');
    const call = await f.fire('tool_call', f.call('bash', { command: 'printf harmless' }));
    assert.equal(call.block, true);
    assert.match(call.reason, /guard rules are unavailable/);
    const bash = await f.fire('user_bash', { command: 'printf harmless', cwd: f.cwd });
    assert.equal(bash.result.exitCode, 1);
    assert.match(bash.result.output, /guard rules are unavailable/);
    assert.equal(f.calls.length, 0);
  });
}

test('unexpected tool_call failure explicitly blocks even when the host would swallow a throw', async t => {
  const f = await deliveredFixture(t);
  f.pi.getCommands = () => { throw new Error('guard crash sentinel'); };
  const decision = await f.fire('tool_call', f.call('read', { path: 'SKILL.md' }));
  assert.equal(decision.block, true);
  assert.match(decision.reason, /guard crash sentinel/);
  assert.equal(f.calls.length, 0);
});

test('guard patterns, failure markers and warn budgets come from runtime JSON at load', async t => {
  const f = await deliveredFixture(t, undefined, runtime => {
    const path = name => resolve(runtime, 'core-rules/hooks/rules', name);
    const destructive = JSON.parse(readFileSync(path('destructive.json'), 'utf8'));
    destructive.rules[0].match = ['^forbidden-by-data$'];
    writeFileSync(path('destructive.json'), JSON.stringify(destructive));
    const reread = JSON.parse(readFileSync(path('reread.json'), 'utf8'));
    reread.warn_budget.default = 1;
    reread.edit_failure_markers.pattern = 'DATA_FAILURE';
    writeFileSync(path('reread.json'), JSON.stringify(reread));
  });
  f.pi.exec = async () => allow;
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'forbidden-by-data' }))).block, true);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const edit = f.call('edit', { path: 'file' });
  await f.fire('tool_call', edit);
  await f.fire('tool_result', { ...edit, content: [{ type: 'text', text: 'data_failure' }], isError: false });
  assert.equal((await write(f)).block, true, 'custom failure marker prevents read credit; custom budget is exhausted');
  // Rules are loaded once, not read from a mutable project path per tool call.
  rmSync(resolve(f.runtime, 'core-rules/hooks/rules'), { recursive: true });
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'forbidden-by-data' }))).block, true);
});

test('native lowercase failure prefixes never grant mutation read credit', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = async () => allow;
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  for (const text of ['error without a colon', 'no files were modified.']) {
    turn(f);
    const event = f.call('edit', { path: 'file' });
    await f.fire('tool_call', event);
    await f.fire('tool_result', { ...event, content: [{ type: 'text', text }], isError: false });
    assert.equal(await write(f), undefined);
    assert.equal((await write(f)).block, true, text);
  }
});

test('rule matching keeps C-locale ASCII folding and exact line anchors', async t => {
  const f = await deliveredFixture(t, undefined, runtime => {
    const path = resolve(runtime, 'core-rules/hooks/rules/destructive.json');
    const data = JSON.parse(readFileSync(path, 'utf8'));
    data.rules[0].match = ['^k$'];
    data.rules[0].ignore_case = true;
    writeFileSync(path, JSON.stringify(data));
  });
  for (const [command, deny] of [['K', true], ['x\nK', true], ['k\r', false], ['k\u2028', false], ['K', false]]) {
    const result = await f.fire('tool_call', f.call('bash', { command }));
    assert.equal(result?.block ?? false, deny, JSON.stringify(command));
  }
});

test('custom agent runs preserve read credit, pending calls and undelivered context', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = async () => ({ ...allow, stdout: JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision: 'allow', context: 'startup sentinel' }) });
  await f.fire('session_start', { reason: 'resume' });
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const event = f.call('read', { path: 'file' });
  await f.fire('tool_call', event);
  assert.equal(f.fire('before_agent_start', { messageType: 'custom', message: { customType: 'completion' }, systemPrompt: 'parent' }), undefined);
  f.pi.exec = async () => allow;
  await f.result(event);
  for (let i = 0; i < 3; i++) assert.equal(await write(f), undefined);
  assert.match(turn(f).message.content, /startup sentinel/);
  assert.equal(await write(f), undefined);
  assert.equal(await write(f), undefined);
  assert.equal((await write(f)).block, true, 'a real user prompt resets read credit');
});

test('settlement clears pending generation; a late reused-id result cannot credit or consume a new call', async t => {
  const f = await deliveredFixture(t);
  let dispatches = 0;
  f.pi.exec = async () => { dispatches++; return allow; };
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const old = { ...f.call('read', { path: 'file' }), toolCallId: 'reused' };
  await f.fire('tool_call', old);
  await f.fire('agent_settled', {});
  const current = { ...f.call('read', { path: 'file' }), toolCallId: 'reused' };
  await f.fire('tool_call', current);
  const before = dispatches;
  assert.equal(await f.result(old), undefined);
  assert.equal(dispatches, before, 'stale results do not dispatch against the new generation');
  assert.equal(await write(f), undefined);
  assert.equal(await write(f), undefined);
  assert.equal((await write(f)).block, true, 'old read did not enter this generation');
  await f.result(current);
  assert.equal(await write(f), undefined, 'late result did not delete the new pending call');
});

test('pre-action resuming after settlement blocks instead of publishing stale pending state', async t => {
  const f = await deliveredFixture(t);
  let release;
  f.pi.exec = () => new Promise(done => { release = done; });
  const started = f.fire('tool_call', f.call('bash', { command: 'gh pr create' }));
  f.pi.exec = async () => allow;
  await f.fire('agent_settled', {});
  release(allow);
  assert.match((await started).reason, /turn changed/);
});

test('async handlers snapshot cwd and context before awaiting a dispatcher', async t => {
  const f = await deliveredFixture(t);
  let reads = 0, stale = false;
  const ctx = { ...f.ctx, get cwd() { assert.equal(stale, false, 'stale ctx.cwd accessed'); reads++; return f.cwd; } };
  f.pi.exec = async () => { stale = true; return allow; };
  assert.equal(await f.fire('tool_call', f.call('bash', { command: 'gh pr create' }), ctx), undefined);
  assert.equal(reads, 1);
});

test('unhandled search pre/post callbacks do not dispatch or grant read credit', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  for (const tool of ['grep', 'find', 'ls']) {
    const event = f.call(tool, { path: 'file', pattern: 'x' });
    assert.equal(await f.fire('tool_call', event), undefined);
    await f.result(event);
  }
  assert.equal(f.calls.length, 0);
  assert.equal(await write(f), undefined);
  assert.equal(await write(f), undefined);
  assert.equal((await write(f)).block, true);
});

test('successful mutation still runs every post-action advisory hook', async t => {
  const f = await deliveredFixture(t);
  const names = ['post-edit-verify', 'slop-tripwire', 'wiki-skill-suggest'];
  for (const name of names) writeFileSync(resolve(f.runtime, `core-rules/codex/hooks/${name}.sh`),
    `#!/bin/bash\nprintf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"${name} sentinel"}}'\n`);
  const event = f.call('write', { path: 'new' });
  assert.equal(await f.fire('tool_call', event), undefined);
  const post = await f.result(event);
  for (const name of names) assert.match(post.content.at(-1).text, new RegExp(`${name} sentinel`));
  assert.equal(f.calls.length, 1, 'post advisories remain one dispatcher call');
});

for (const command of ['g\\h p\\r cr\\eate', 'g"h" p\'r\' cr"eate"', 'g\\\nh pr create']) {
  test(`PR advisory prefilter retains escaped/quoted command ${JSON.stringify(command)}`, async t => {
    const f = await deliveredFixture(t);
    let calls = 0;
    f.pi.exec = async () => { calls++; return allow; };
    assert.equal(await f.fire('tool_call', f.call('bash', { command })), undefined);
    assert.equal(calls, 1);
    await f.fire('user_bash', { command, cwd: f.cwd });
    assert.equal(calls, 2, 'actual scanner must get the chance to inspect both command paths');
  });
}
