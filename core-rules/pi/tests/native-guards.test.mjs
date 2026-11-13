// Native callback boundary regressions (not a model run). Explicit blocking
// returns backstop pi >=1.4's throw-to-block contract on older hosts too.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { linkSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { deliveredFixture } from './delivered-fixture.mjs';
import { mockDispatchExec } from './dispatch-test-transport.mjs';

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
  f.pi.exec = mockDispatchExec(async () => allow);
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
  f.pi.exec = mockDispatchExec(async () => allow);
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
  f.pi.exec = mockDispatchExec(async () => ({ ...allow, stdout: JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision: 'allow', context: 'startup sentinel' }) }));
  await f.fire('session_start', { reason: 'resume' });
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const event = f.call('read', { path: 'file' });
  await f.fire('tool_call', event);
  assert.equal(f.fire('before_agent_start', { messageType: 'custom', message: { customType: 'completion' }, systemPrompt: 'parent' }), undefined);
  f.pi.exec = mockDispatchExec(async () => allow);
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
  f.pi.exec = mockDispatchExec(async () => { dispatches++; return allow; });
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
  f.pi.exec = mockDispatchExec(() => new Promise(done => { release = done; }));
  const started = f.fire('tool_call', f.call('bash', { command: 'gh pr create' }));
  f.pi.exec = mockDispatchExec(async () => allow);
  await f.fire('agent_settled', {});
  release(allow);
  assert.match((await started).reason, /turn changed/);
});

test('async handlers snapshot cwd and context before awaiting a dispatcher', async t => {
  const f = await deliveredFixture(t);
  let reads = 0, stale = false;
  const ctx = { ...f.ctx, get cwd() { assert.equal(stale, false, 'stale ctx.cwd accessed'); reads++; return f.cwd; } };
  f.pi.exec = mockDispatchExec(async () => { stale = true; return allow; });
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

test('native mutation joins lint failure and slop context without dispatching pure members', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.cwd, 'node_modules/.bin'), { recursive: true });
  writeFileSync(resolve(f.cwd, 'node_modules/.bin/eslint'), '#!/bin/sh\n[ "$1" = --version ] && exit 0\necho lint-sentinel\nexit 1\n', { mode: 0o755 });
  writeFileSync(resolve(f.cwd, 'eslint.config.js'), 'export default []');
  const event = f.call('write', { path: 'new.ts' });
  assert.equal(await f.fire('tool_call', event), undefined);
  writeFileSync(resolve(f.cwd, 'new.ts'), 'const value = data as any;\n');
  const post = await f.result(event);
  assert.match(post.content.at(-1).text, /lint-sentinel/);
  assert.match(post.content.at(-1).text, /slop-tripwire: ts-as-any/);
  assert.equal(f.notifications.at(-1)[1], 'warning');
  assert.ok(f.calls.some(call => call.script.endsWith('/eslint')));
  assert.ok(f.calls.every(call => !call.script.endsWith('dispatch.sh')));
});

for (const command of ['g\\h p\\r cr\\eate', 'g"h" p\'r\' cr"eate"', 'g\\\nh pr create']) {
  test(`PR advisory prefilter retains escaped/quoted command ${JSON.stringify(command)}`, async t => {
    const f = await deliveredFixture(t);
    let calls = 0;
    f.pi.exec = mockDispatchExec(async () => { calls++; return allow; });
    assert.equal(await f.fire('tool_call', f.call('bash', { command })), undefined);
    assert.equal(calls, 1);
    await f.fire('user_bash', { command, cwd: f.cwd });
    assert.equal(calls, 2, 'actual scanner must get the chance to inspect both command paths');
  });
}

// QP H1: override records are the reread guard's escape authority; only the
// CLI writes them. The Pi mutation guard refuses them before its create and
// already-read exemptions, and the shared shell rule catches numbered redirects.
test('override records are refused to builtin mutations and numbered shell redirects', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = mockDispatchExec(async () => allow);
  const dir = resolve(f.cwd, 'trellis/state/reread-overrides');
  mkdirSync(dir, { recursive: true });
  const existing = resolve(dir, 'fedcba9876543210');
  writeFileSync(existing, '9999999999\t1\tx\n');
  // Grant read credit first, so the already-read exemption would otherwise apply.
  const read = f.call('read', { path: existing });
  await f.fire('tool_call', read);
  await f.result(read);
  for (const [tool, input] of [
        ['write', { path: resolve(dir, '0123456789abcdef'), content: 'record\n' }],
    ['write', { path: 'trellis/state/reread-overrides/../reread-overrides/new', content: 'record\n' }],
    ['write', { path: existing, content: 'record\n' }],
    ['edit', { path: existing, edits: [{ oldText: 'x', newText: 'y' }] }],
    ['write', { path: dir, content: 'record\n' }],
  ]) {
    const call = await f.fire('tool_call', f.call(tool, input));
    assert.equal(call?.block, true, `${tool} ${input.path}`);
    assert.match(call.reason, /written only by trellis reread override/);
  }
  for (const command of [`printf x 1> ${dir}/k`, `printf x 2> ${dir}/k`, `printf x 1>>${dir}/k`]) {
    assert.equal((await f.fire('tool_call', f.call('bash', { command })))?.block, true, command);
  }
  assert.equal(await f.fire('tool_call', f.call('bash', { command: `ls ${dir} 2>/dev/null` })), undefined);
  assert.equal(await f.fire('tool_call', f.call('write', { path: resolve(f.cwd, 'trellis/state/other'), content: 'x' })), undefined);
});

// r151-sol H1: process-gate verdicts live in the guarded state area; no agent
// mutation or shell write reaches them, through any spelling.
test('the gate verdict store is refused to builtin mutations and shell writes', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = mockDispatchExec(async () => allow);
  const dir = resolve(f.cwd, 'trellis/state/gate-verdicts');
  mkdirSync(resolve(dir, 'verdicts'), { recursive: true });
  symlinkSync(resolve(f.cwd, 'trellis/state'), resolve(f.cwd, 'gv-alias'));
  for (const [tool, input] of [
    ['write', { path: resolve(dir, 'verdicts/k.json'), content: '{}' }],
    ['write', { path: resolve(dir, 'reuse-disabled'), content: '' }],
    ['write', { path: 'trellis/State/Gate-Verdicts/logs/x.log', content: 'x' }],
    ['write', { path: 'gv-alias/gate-verdicts/verdicts/k.json', content: '{}' }],
  ]) {
    const call = await f.fire('tool_call', f.call(tool, input));
    assert.equal(call?.block, true, `${tool} ${input.path}`);
    assert.match(call.reason, /written only by the process gate/);
  }
  for (const command of [`printf '{}' > ${dir}/verdicts/k.json`, `echo x | tee ${dir}/logs/x.log`, `rm -f ${dir}/reuse-disabled`]) {
    assert.equal((await f.fire('tool_call', f.call('bash', { command })))?.block, true, command);
  }
  assert.equal(await f.fire('tool_call', f.call('bash', { command: `ls ${dir} 2>/dev/null` })), undefined);
});

// r151-reuse2 Sol N1: a hard link made through the symlinked state parent is the
// stored file, for builtin Write and Edit; dot-path and parent-rename shell
// spellings of the store are refused too.
test('hard links to stored files and spelled-out store paths are refused', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = mockDispatchExec(async () => allow);
  const saved = process.env.TRELLIS_HOME;
  process.env.TRELLIS_HOME = resolve(f.cwd, 'trellis');
  t.after(() => { if (saved === undefined) delete process.env.TRELLIS_HOME; else process.env.TRELLIS_HOME = saved; });
  const home = process.env.TRELLIS_HOME, dir = resolve(home, 'state/gate-verdicts');
  mkdirSync(resolve(dir, 'verdicts'), { recursive: true });
  mkdirSync(resolve(home, 'state/reread-overrides'), { recursive: true });
  writeFileSync(resolve(dir, 'verdicts/k.json'), '{"x":1}');
  writeFileSync(resolve(home, 'state/reread-overrides/0123456789abcdef'), 'r\n');
  symlinkSync(resolve(home, 'state'), resolve(f.cwd, 'gv-alias'));
  linkSync(resolve(f.cwd, 'gv-alias/gate-verdicts/verdicts/k.json'), resolve(f.cwd, 'k.json'));
  linkSync(resolve(home, 'state/reread-overrides/0123456789abcdef'), resolve(f.cwd, 'record'));
  writeFileSync(resolve(f.cwd, 'plain'), 'x');
  linkSync(resolve(f.cwd, 'plain'), resolve(f.cwd, 'plain-twin'));
  const wrong = [];
  for (const [path, reason] of [['k.json', /written only by the process gate/], ['record', /written only by trellis reread override/]]) {
    const read = f.call('read', { path });
    await f.fire('tool_call', read);
    await f.result(read);
    for (const [tool, input] of [['write', { path, content: '{}' }], ['edit', { path, edits: [{ oldText: '1', newText: '2' }] }]]) {
      const call = await f.fire('tool_call', f.call(tool, input));
      if (call?.block !== true || !reason.test(call.reason)) wrong.push(`${tool} ${path}`);
    }
  }
  const read = f.call('read', { path: 'plain-twin' });
  await f.fire('tool_call', read);
  await f.result(read);
  if (await f.fire('tool_call', f.call('write', { path: 'plain-twin', content: 'y' })) !== undefined) wrong.push('write plain-twin');
  for (const command of [`unlink ${home}/state/./gate-verdicts/reuse-disabled`, `ln gv-alias/gate-verdicts/verdicts/k.json k2.json`,
    'mv ~/.trellis/state ~/.trellis/state-backup', 'mv ${TRELLIS_HOME}/state/ /tmp/s', 'cd ~/.trellis && mv ./state /tmp/s']) {
    if ((await f.fire('tool_call', f.call('bash', { command })))?.block !== true) wrong.push(command);
  }
  assert.deepEqual(wrong, []);
});

test('override records are refused through case-folded and symlinked spellings', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = mockDispatchExec(async () => allow);
  const dir = resolve(f.cwd, 'trellis/state/reread-overrides');
  mkdirSync(dir, { recursive: true });
  symlinkSync(resolve(f.cwd, 'trellis/state'), resolve(f.cwd, 'alias'));
  symlinkSync(dir, resolve(f.cwd, 'records'));
  for (const path of ['trellis/State/Reread-Overrides/0123456789abcdef', 'alias/reread-overrides/0123456789abcdef', 'records/0123456789abcdef', 'records']) {
    const call = await f.fire('tool_call', f.call('write', { path, content: 'record\n' }));
    assert.equal(call?.block, true, path);
    assert.match(call.reason, /written only by trellis reread override/);
  }
  assert.equal(await f.fire('tool_call', f.call('write', { path: 'alias/other', content: 'x' })), undefined);
});
