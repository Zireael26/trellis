import assert from 'node:assert/strict';
import { test } from 'node:test';
import { linkSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { localPostAction, slopPolicy, scanSlop } from '../extensions/trellis.ts';
import { resolve } from 'node:path';
import { deliveredFixture } from './delivered-fixture.mjs';
import { mockDispatchExec } from './dispatch-test-transport.mjs';

for (const tool of ['read', 'bash']) {
  test(`ordinary ${tool} result stays local and preserves native content`, async t => {
    const f = await deliveredFixture(t);
    const event = f.call(tool, tool === 'read' ? { path: 'file' } : { command: 'printf ok' });
    assert.equal(await f.fire('tool_call', event), undefined);
    f.pi.exec = async () => { throw new Error('ordinary post must not dispatch'); };
    const content = [{ type: 'text', text: 'exact\r\n\0é' }, { type: 'image', data: 'AA==', mimeType: 'image/png' }];
    const patch = await f.fire('tool_result', { ...event, content, isError: false, details: {} });
    assert.equal(patch, undefined);
    assert.equal(f.calls.length, 0);
    assert.equal(content.length, 2);
    assert.equal(f.notifications.length, 0);
  });
}

test('read credit is branch-bound and a late prior-branch result earns no new credit', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.cwd, '.git'));
  const head = resolve(f.cwd, '.git/HEAD');
  writeFileSync(head, 'ref: refs/heads/first\n');
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const event = f.call('read', { path: 'file' });
  await f.fire('tool_call', event);
  writeFileSync(head, 'ref: refs/heads/second\n');
  await f.result(event);
  for (let i = 0; i < 2; i++) assert.equal(await f.fire('tool_call', f.call('edit', { path: 'file' })), undefined);
  assert.equal((await f.fire('tool_call', f.call('edit', { path: 'file' }))).block, true);
});

for (const tool of ['edit', 'write']) {
  test(`${tool} prose batch stays local without duplicate read credit`, async t => {
    const f = await deliveredFixture(t);
    writeFileSync(resolve(f.cwd, 'file.md'), 'text');
    const event = f.call(tool, { path: 'file.md', content: 'new text' });
    assert.equal(await f.fire('tool_call', event), undefined);
    f.pi.exec = async () => { throw new Error('prose post must not dispatch'); };
    await f.result(event);
    for (let i = 0; i < 3; i++) assert.equal(await f.fire('tool_call', f.call(tool, { path: 'file.md' })), undefined);
    assert.equal(f.notifications.length, 1, 'only the original reread warning; no hidden failed dispatcher');
    assert.equal(f.calls.length, 0);
  });
}

const batchEvent = (f, path, extra = {}) => ({ schema_version: 1, harness: 'pi', phase: 'post_action', native_event: 'tool_result', cwd: f.cwd, session_id: 'fixture-session', action: { id: 'batch', family: 'file_mutation', tool_name: 'edit', input: { path }, targets: [{ operation: 'update', path }], target_coverage: 'complete' }, result: { status: 'succeeded', is_error: false, output: [] }, ...extra });
const batchContext = f => ({ cwd: f.cwd, signal: f.ctx.signal });
const ok = { stdout: '', stderr: '', code: 0, killed: false };

for (const language of ['ts', 'py', 'go', 'rs', 'java']) {
  test(`local slop parser and scanner match shared ${language} literal rows and red/green samples`, () => {
    const path = new URL('../../hooks/lib/slop-patterns.sh', import.meta.url).pathname;
    const run = command => {
      const result = spawnSync('bash', ['-c', '. "$1"; ' + command, 'slop-parity', path, language], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout;
    };
    const policy = slopPolicy(readFileSync(path, 'utf8'), language);
    assert.deepEqual(policy.rows, run('slop_patterns_for_lang "$2"').trimEnd().split('\n').map(line => { const [id, match, suppress] = line.split('\t'); return { id, match, suppress }; }));
    assert.deepEqual(policy.globs, run('slop_carve_out_globs').trimEnd().split('\n'));
    for (const color of ['red', 'green']) {
      const sample = run(`slop__${color}_sample "$2"`);
      const expected = run(`slop__${color}_sample "$2" | slop_scan_text "$2" || true`).trimEnd();
      const findings = scanSlop(policy.rows, sample.trimEnd().split('\n').map((text, index) => ({ number: index + 1, text })));
      assert.deepEqual(findings, expected ? expected.split('\n').map(line => { const [number, id] = line.split('\t'); return { id, line: Number(number) }; }) : []);
    }
  });
}

test('ordered edit batch joins delayed lint, continues after failure, then tracks and suggests wiki', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.cwd, 'node_modules/.bin'), { recursive: true });
  writeFileSync(resolve(f.cwd, 'node_modules/.bin/eslint'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  writeFileSync(resolve(f.cwd, 'eslint.config.js'), 'export default []');
  writeFileSync(resolve(f.cwd, 'file.ts'), 'const bad = value as any;\n');
  writeFileSync(resolve(f.cwd, 'gotchas.md'), 'gotcha');
  const calls = [];
  let release, completed = false, credits = 0;
  f.pi.exec = async (command, args) => {
    if (command.endsWith('/eslint')) {
      calls.push('lint');
      if (args[0] === '--version') return ok;
      return new Promise(done => { release = () => done({ ...ok, code: 1, stdout: 'lint sentinel' }); });
    }
    calls.push(args.includes('--is-inside-work-tree') ? 'wiki' : 'slop');
    if (args.includes('--show-prefix')) return { ...ok, stdout: '' };
    if (args.includes('--verify')) return { ...ok, code: 1 };
    return ok;
  };
  const event = batchEvent(f, './file.ts');
  event.action.targets.push({ operation: 'update', path: 'gotchas.md' });
  const pending = localPostAction(f.pi, event, batchContext(f), () => { calls.push('track'); credits++; }).then(value => { completed = true; return value; });
  assert.equal(completed, false);
  assert.deepEqual(calls, ['lint']);
  release();
  const decision = await pending;
  assert.equal(decision.decision, 'warn');
  assert.match(decision.reason, /lint sentinel/);
  assert.match(decision.context, /ts-as-any[\s\S]*wiki-skill-suggest/);
  assert.ok(calls.indexOf('slop') > calls.indexOf('lint'));
  assert.ok(calls.indexOf('track') > calls.lastIndexOf('slop'));
  assert.ok(calls.indexOf('wiki') > calls.indexOf('track'));
  assert.equal(credits, 1);
  assert.equal(completed, true);
});

test('crashed member does not skip later tracking/wiki; skip flag and failed edit never duplicate credit', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'gotchas.md'), 'gotcha');
  let credits = 0;
  f.pi.exec = async () => { throw new Error('wiki crash sentinel'); };
  const event = batchEvent(f, './gotchas.md');
  const result = await localPostAction(f.pi, event, batchContext(f), () => { credits++; throw new Error('track crash sentinel'); });
  assert.equal(result.capability_status, 'unknown');
  assert.equal(result.decision, 'warn');
  assert.match(result.reason, /track-read.sh: unknown — track crash sentinel[\s\S]*wiki-skill-suggest.sh: unknown — wiki crash sentinel/);
  assert.equal(credits, 1);
  await localPostAction(f.pi, { ...event, in_process_read_tracking: true }, batchContext(f), () => credits++);
  await localPostAction(f.pi, { ...event, result: { status: 'failed' } }, batchContext(f), () => credits++);
  assert.equal(credits, 1);
});

test('slop uses added-line numbers, caps context, and ignores repo-relative test carve-outs', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file.ts'), 'preexisting as any\n');
  f.pi.exec = async (_command, args) => ({ ...ok, stdout: args.includes('--show-prefix') ? '' : args.includes('diff') ? '@@ -1 +37,7 @@\n' + Array(7).fill('+added as any').join('\n') : 'HEAD' });
  const decision = await localPostAction(f.pi, batchEvent(f, 'file.ts', { in_process_read_tracking: true }), batchContext(f));
  assert.equal(decision.decision, 'allow');
  assert.match(decision.context, /file.ts:37/);
  assert.match(decision.context, /\(\+2 more\)/);
  assert.equal((decision.context.match(/slop-tripwire:/g) ?? []).length, 5);
  f.pi.exec = async () => ({ ...ok, stdout: 'tests/' });
  assert.equal((await localPostAction(f.pi, batchEvent(f, 'file.ts', { in_process_read_tracking: true }), batchContext(f))).context, undefined);
});

for (const path of ['file.md', 'file.ts', 'gotchas.md', './gotchas.md']) {
  test(`local batch preserves compatibility verdict and context for ${path}`, async t => {
    const f = await deliveredFixture(t);
    const init = spawnSync('git', ['-c', 'init.defaultBranch=main', 'init', '-q', f.cwd], { encoding: 'utf8' });
    assert.equal(init.status, 0, init.stderr);
    writeFileSync(resolve(f.cwd, path), path.endsWith('.ts') ? 'const value = data as any;\n' : 'text\n');
    const event = batchEvent(f, path, { in_process_read_tracking: true });
    const local = await localPostAction(f.pi, event, batchContext(f));
    const legacy = spawnSync('bash', [resolve(f.runtime, 'core-rules/pi/hooks/dispatch.sh'), '--base64', Buffer.from(JSON.stringify(event)).toString('base64')], { cwd: f.cwd, encoding: 'utf8', timeout: 30_000, env: { PATH: process.env.PATH, HOME: f.cwd, TRELLIS_HOME: resolve(f.cwd, 'trellis'), TMPDIR: process.env.TMPDIR } });
    assert.equal(legacy.status, 0, legacy.stderr);
    assert.deepEqual(local, JSON.parse(legacy.stdout));
    assert.ok(f.calls.every(call => !call.script.endsWith('dispatch.sh')));
  });
}

test('real lint retains the shared 300 second dispatcher budget and late findings', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.cwd, 'node_modules/.bin'), { recursive: true });
  writeFileSync(resolve(f.cwd, 'node_modules/.bin/eslint'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  writeFileSync(resolve(f.cwd, 'eslint.config.js'), 'export default []');
  writeFileSync(resolve(f.cwd, 'file.ts'), 'const value = 1;');
  let now = 1000;
  t.mock.method(Date, 'now', () => now);
  const budgets = [];
  f.pi.exec = async (command, args, options) => {
    budgets.push(options.timeout);
    if (command.endsWith('/eslint') && args[0] === '--quiet') {
      if (options.timeout <= 20_000) return { ...ok, killed: true, code: 1 };
      now += 25_000; // Virtual elapsed time, not a timing measurement/sleep.
      return { ...ok, code: 1, stdout: 'slow-linter finding sentinel', stderr: 'linter stderr sentinel' };
    }
    return { ...ok, code: command.endsWith('/eslint') ? 0 : 1 };
  };
  const result = await localPostAction(f.pi, batchEvent(f, 'file.ts', { in_process_read_tracking: true }), batchContext(f));
  assert.equal(result.capability_status, 'advisory');
  assert.equal(result.decision, 'warn');
  assert.match(result.reason, /slow-linter finding sentinel/);
  assert.match(result.reason, /linter stderr sentinel/);
  assert.equal(budgets[0], 300_000);
  assert.ok(budgets.slice(1).every(timeout => timeout === 275_000), 'all later external work shares the remaining batch deadline');
});

test('eslint keeps non-installing canonical resolution instead of a different global executable', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'eslint.config.js'), 'export default []');
  writeFileSync(resolve(f.cwd, 'file.ts'), 'text');
  mkdirSync(resolve(f.cwd, 'tools'));
  for (const name of ['npx', 'eslint']) writeFileSync(resolve(f.cwd, 'tools', name), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const previous = process.env.PATH;
  process.env.PATH = resolve(f.cwd, 'tools');
  t.after(() => { process.env.PATH = previous; });
  const calls = [];
  f.pi.exec = async (command, args) => { calls.push({ command, args }); return args.includes('--quiet') ? { ...ok, code: 1, stdout: 'resolved-eslint sentinel' } : ok; };
  const result = await localPostAction(f.pi, batchEvent(f, 'file.ts', { in_process_read_tracking: true }), batchContext(f));
  assert.match(result.reason, /resolved-eslint sentinel/);
  assert.deepEqual(calls.filter(call => call.command.endsWith('/npx')).map(call => call.args.slice(0, 3)), [['--no-install', 'eslint', '--version'], ['--no-install', 'eslint', '--quiet']]);
  assert.ok(calls.every(call => !call.command.endsWith('/eslint')));
});

test('one crashed target cannot discard earlier findings or skip later targets', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.cwd, 'node_modules/.bin'), { recursive: true });
  writeFileSync(resolve(f.cwd, 'node_modules/.bin/eslint'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  writeFileSync(resolve(f.cwd, 'eslint.config.js'), 'export default []');
  for (const name of ['first', 'second', 'third']) writeFileSync(resolve(f.cwd, `${name}.ts`), 'data as any\n');
  f.pi.exec = async (command, args) => {
    if (command.endsWith('/eslint')) {
      if (args[0] === '--version') return ok;
      if (args[1].endsWith('second.ts')) throw new Error('second-target crash');
      return { ...ok, code: 1, stdout: `lint-${args[1]}` };
    }
    if (args.includes('--show-prefix') && args.at(-1) === '--show-prefix') return ok;
    return { ...ok, code: 1 };
  };
  const event = batchEvent(f, 'first.ts', { in_process_read_tracking: true });
  event.action.targets.push(...['second', 'third'].map(name => ({ operation: 'update', path: `${name}.ts` })));
  const result = await localPostAction(f.pi, event, batchContext(f));
  assert.equal(result.capability_status, 'unknown');
  assert.match(result.reason, /second-target crash/);
  assert.match(result.reason, /lint-.*first.ts/);
  assert.match(result.reason, /lint-.*third.ts/);
  assert.match(result.context, /first.ts[\s\S]*third.ts/);
});

test('tracking promises are joined and failures remain visible before wiki returns', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file.md'), 'text');
  let release, finished = false;
  const pending = localPostAction(f.pi, batchEvent(f, 'file.md'), batchContext(f), () => new Promise((_, reject) => { release = () => reject(new Error('async tracking sentinel')); })).then(result => { finished = true; return result; });
  await new Promise(done => setImmediate(done));
  assert.equal(finished, false);
  release();
  const result = await pending;
  assert.equal(result.capability_status, 'unknown');
  assert.match(result.reason, /async tracking sentinel/);
  const absent = await localPostAction(f.pi, batchEvent(f, 'file.md'), batchContext(f));
  assert.match(absent.reason, /tracking callback unavailable/);
});

test('wiki identity includes aliases rather than only the gotchas basename', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'gotchas.md'), 'gotcha');
  linkSync(resolve(f.cwd, 'gotchas.md'), resolve(f.cwd, 'alias.md'));
  f.pi.exec = async () => ok;
  const result = await localPostAction(f.pi, batchEvent(f, './alias.md', { in_process_read_tracking: true }), batchContext(f));
  assert.match(result.context, /wiki-skill-suggest/);
});

test('hunk trailing function text cannot replace the added-line coordinate', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file.ts'), 'text');
  f.pi.exec = async (_command, args) => ({ ...ok, stdout: args.includes('--show-prefix') ? '' : args.includes('diff') ? '@@ -1 +37,1 @@ function f(x = +123) {\n+value as any\n' : 'HEAD' });
  const result = await localPostAction(f.pi, batchEvent(f, 'file.ts', { in_process_read_tracking: true }), batchContext(f));
  assert.match(result.context, /file.ts:37/);
});

test('unsupported advisory policy syntax is visible and never evaluated', () => {
  const path = new URL('../../hooks/lib/slop-patterns.sh', import.meta.url);
  const source = readFileSync(path, 'utf8').replace("'ts-as-any'", '"$(touch /untrusted)"');
  assert.throws(() => slopPolicy(source, 'ts'), /nonliteral/);
});

test('a read completed on another branch cannot credit the original branch on return', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.cwd, '.git'));
  const head = resolve(f.cwd, '.git/HEAD');
  writeFileSync(head, 'ref: refs/heads/A\n');
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const event = f.call('read', { path: 'file' });
  await f.fire('tool_call', event);
  writeFileSync(head, 'ref: refs/heads/B\n');
  await f.result(event);
  writeFileSync(head, 'ref: refs/heads/A\n');
  for (let i = 0; i < 2; i++) assert.equal(await f.fire('tool_call', f.call('edit', { path: 'file' })), undefined);
  assert.equal((await f.fire('tool_call', f.call('edit', { path: 'file' }))).block, true);
});

test('detached HEAD movement deliberately invalidates prior read credit', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.cwd, '.git'));
  const head = resolve(f.cwd, '.git/HEAD');
  writeFileSync(head, 'a'.repeat(40) + '\n');
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const event = f.call('read', { path: 'file' });
  await f.fire('tool_call', event);
  await f.result(event);
  writeFileSync(head, 'b'.repeat(40) + '\n');
  for (let i = 0; i < 2; i++) assert.equal(await f.fire('tool_call', f.call('edit', { path: 'file' })), undefined);
  assert.equal((await f.fire('tool_call', f.call('edit', { path: 'file' }))).block, true);
});

test('post metadata failure preserves pre advisory and visibly degrades instead of throwing', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = mockDispatchExec(async () => ({ ...ok, stdout: JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision: 'allow', context: 'captured pre sentinel' }) }));
  const event = f.call('bash', { command: 'gh pr create' });
  await f.fire('tool_call', event);
  writeFileSync(resolve(f.cwd, '.git'), 'gitdir: missing-worktree\n');
  const post = await f.result(event);
  assert.match(post.content.at(-1).text, /captured pre sentinel/);
  assert.match(post.content.at(-1).text, /capability: unknown[\s\S]*post-action evaluation failed/);
  assert.equal(f.notifications.at(-1)[1], 'warning');
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'echo ok' }))).block, true);
});

test('orphan post with unavailable rules produces a visible unknown result', async t => {
  const f = await deliveredFixture(t);
  // First resource use is the result, not a successful pre-action gate.
  const path = resolve(f.runtime, 'core-rules/hooks/rules/destructive.json');
  writeFileSync(path, '{');
  const post = await f.result(f.call('read', { path: 'file' }));
  assert.match(post.content.at(-1).text, /guard rules are unavailable/);
  assert.match(post.content.at(-1).text, /capability: unknown/);
});

test('post snapshot errors remain model-visible even when notification also throws', async t => {
  const f = await deliveredFixture(t);
  const ctx = { ...f.ctx, sessionManager: { getSessionId() { throw new Error('post snapshot sentinel'); } }, ui: { notify() { throw new Error('notify crash'); } } };
  const original = [{ type: 'text', text: 'original result' }];
  const post = await f.fire('tool_result', { ...f.call('read', { path: 'file' }), content: original, isError: false }, ctx);
  assert.deepEqual(post.content.slice(0, 1), original);
  assert.match(post.content.at(-1).text, /capability: unknown[\s\S]*post snapshot sentinel/);
});

test('Go without an owning module retains its degradation diagnostic', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file.go'), 'package main\n');
  f.pi.exec = async () => ({ ...ok, code: 1 });
  const result = await localPostAction(f.pi, batchEvent(f, 'file.go', { in_process_read_tracking: true }), batchContext(f));
  assert.equal(result.decision, 'warn');
  assert.match(result.reason, /post-edit-verify.sh stderr: .*skipping Go lint.*no owning go.mod found/);
});

test('missing git retains the wiki advisory degradation diagnostic', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file.md'), 'text');
  const previous = process.env.PATH;
  process.env.PATH = '';
  t.after(() => { process.env.PATH = previous; });
  const result = await localPostAction(f.pi, batchEvent(f, 'file.md', { in_process_read_tracking: true }), batchContext(f));
  assert.equal(result.decision, 'warn');
  assert.match(result.reason, /wiki-skill-suggest.sh stderr: wiki-skill-suggest: git not found; degrading to no-op/);
});

test('a result without its matching pending input cannot grant read credit', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const event = f.call('read', { path: 'file' });
  await f.fire('tool_call', event);
  await f.result({ ...event, input: { ...event.input } });
  for (let i = 0; i < 2; i++) assert.equal(await f.fire('tool_call', f.call('edit', { path: 'file' })), undefined);
  assert.equal((await f.fire('tool_call', f.call('edit', { path: 'file' }))).block, true);
});
