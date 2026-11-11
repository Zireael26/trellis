#!/usr/bin/env node
// node --experimental-strip-types --test core-rules/pi/tests/completion-gate.test.mjs
// T64b/T33: the Pi agent_before_settle gate over T64a's exact native member set.
import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { deliveredFixture } from './delivered-fixture.mjs';

export const MEMBERS = ['spec-gate', 'decision-receipt', 'stop-verify', 'code-review-subagent', 'ui-verify', 'required-post-action', 'stamp-turn'];
export const MANDATORY = ['decision-receipt', 'stop-verify', 'required-post-action'];
const TARGETS = { 'darwin:arm64': 'aarch64-apple-darwin', 'linux:x64': 'x86_64-unknown-linux-musl', 'linux:arm64': 'aarch64-unknown-linux-musl' };
const noop = { status: 'no_op', exit_code: 0, context: '', reason: '', error_class: null };

// Digest-pinned fake native companion, installed where dispatch.sh verifies it.
export async function gateFixture(t) {
  const target = TARGETS[`${process.platform}:${process.arch}`];
  if (!target) { t.skip('no native target for this host'); return; }
  const f = await deliveredFixture(t);
  const log = resolve(f.base, 'native-log');
  mkdirSync(log, { recursive: true });
  const body = `#!/bin/bash\nprintf '%s\\n' "$*" >> '${log}/argv'\ncat > '${log}/stdin'\ncat '${log}/response'\nexit "$(cat '${log}/rc')"\n`;
  const digest = createHash('sha256').update(body).digest('hex');
  mkdirSync(resolve(f.runtime, 'core-rules/native'), { recursive: true });
  writeFileSync(resolve(f.runtime, 'core-rules/native/artifacts.json'), JSON.stringify({ version: '9.9.9', assets: { [target]: { sha256: digest } } }));
  const home = resolve(f.cwd, 'trellis');
  const chain = ['bin', 'bin/native', 'bin/native/9.9.9', `bin/native/9.9.9/${target}`, `bin/native/9.9.9/${target}/${digest}`];
  for (const dir of chain) { mkdirSync(resolve(home, dir), { recursive: true }); chmodSync(resolve(home, dir), 0o700); }
  const companion = resolve(home, chain.at(-1), 'trellis-hooks');
  writeFileSync(companion, body, { mode: 0o500 });
  chmodSync(companion, 0o500);
  const appended = [];
  f.pi.appendEntry = (customType, data) => appended.push({ customType, data: structuredClone(data) });
  const respond = (rows, { rc = 0, decision, boundary = { entries: [{ type: 'custom_message', customType: 'x', content: 'x', display: true }] } } = {}) => {
    const members = MEMBERS.map(member => ({ member, result: rows[member] ?? noop })).filter(row => row.result !== 'missing');
    const blocking = MANDATORY.some(m => rows[m] && rows[m] !== 'missing' && rows[m].status !== 'no_op');
    writeFileSync(resolve(log, 'response'), JSON.stringify({ schema_version: 1, harness: 'pi', phase: 'agent_before_settle',
      batch: { decision: decision ?? (blocking ? 'deny' : 'allow'), members }, boundary }));
    writeFileSync(resolve(log, 'rc'), String(rc));
  };
  respond({});
  const settle = (canContinue = true, ctx = f.ctx) => f.fire('agent_before_settle',
    { type: 'agent_before_settle', entries: [], continue: false, outcome: 'completed',
      context: { canContinue, contextMessages: [{ role: 'assistant', content: [{ type: 'text', text: 'done' }] }], contextEntries: [], llmMessages: [], pendingMessages: [] } }, ctx);
  const allCalls = () => existsSync(resolve(log, 'argv')) ? readFileSync(resolve(log, 'argv'), 'utf8').trim().split('\n').filter(Boolean) : [];
  // T34: settle, shutdown and reload also reach the companion for their own
  // lifecycle phases (agent_settled, session_shutdown, session_start); only
  // agent_before_settle is the completion check these tests count.
  const calls = () => allCalls().filter(call => call.startsWith('event pi agent_before_settle '));
  const state = () => appended.filter(e => e.customType === 'trellis-completion').at(-1)?.data;
  const entryState = result => result?.entries?.find(e => e.type === 'custom' && e.customType === 'trellis-completion')?.data;
  return { ...f, log, respond, settle, calls, allCalls, appended, state, entryState, companion };
}

const deny = reason => ({ status: 'deny', exit_code: 2, context: '', reason, error_class: null });

test('T64b: the settle request is one native call over the exact frozen completion envelope', async t => {
  const f = await gateFixture(t); if (!f) return;
  assert.equal(await f.settle(), undefined, 'an accepted completion returns no boundary change');
  assert.deepEqual(f.calls(), [`event pi agent_before_settle ${f.cwd}`]);
  const request = JSON.parse(readFileSync(resolve(f.log, 'stdin'), 'utf8'));
  assert.deepEqual(Object.keys(request).sort(), ['can_continue', 'cwd', 'generation', 'harness', 'last_assistant_message', 'phase', 'schema_version', 'session_id', 'stop_hook_active', 'turn_id']);
  assert.equal(request.last_assistant_message, 'done');
  assert.equal(request.can_continue, true);
  assert.equal(f.state().status, 'accepted');
});

for (const member of MANDATORY) {
  test(`T64b: a failed ${member} blocks completion with published state and one continuation`, async t => {
    const f = await gateFixture(t); if (!f) return;
    f.respond({ [member]: deny(`${member} sentinel`) });
    const result = await f.settle();
    assert.equal(result.continue, true);
    assert.equal(f.entryState(result).status, 'blocked');
    assert.equal(f.entryState(result).unknown, false, result.entries.at(-1).content);
    assert.match(result.entries.find(e => e.type === 'custom_message').content, new RegExp(`${member} sentinel`));
    // A known project-check failure still permits ordinary guarded repairs.
    assert.equal(await f.fire('tool_call', f.call('bash', { command: 'ls' })), undefined);
  });
}

for (const [label, rows] of [['missing', { 'stop-verify': 'missing' }], ['malformed stage row', { 'ui-verify': { status: 'bogus', exit_code: 0, context: '', reason: '', error_class: null } }]]) {
  test(`T64b: a ${label} completion stage is unknown enforcement and denies covered actions`, async t => {
    const f = await gateFixture(t); if (!f) return;
    f.respond(rows);
    const result = await f.settle();
    assert.equal(f.entryState(result).unknown, true);
    assert.equal((await f.fire('tool_call', f.call('bash', { command: 'ls' }))).block, true);
    assert.equal((await f.fire('user_bash', { command: 'ls', cwd: f.cwd, excludeFromContext: true })).result.exitCode, 1);
    assert.equal(await f.fire('tool_call', f.call('read', { path: 'README.md' })), undefined, 'reads are not covered actions');
  });
}

test('T64b: advisory-open review/spec errors warn but accept', async t => {
  const f = await gateFixture(t); if (!f) return;
  f.respond({ 'code-review-subagent': { status: 'error', exit_code: 5, context: '', reason: 'review infra', error_class: 'review_infrastructure' } }, { decision: 'warn', boundary: {} });
  assert.equal(await f.settle(), undefined);
  assert.equal(f.state().status, 'accepted');
});

test('T33: needs_check is persisted before the fallible native call, and acceptance after it', async t => {
  const f = await gateFixture(t); if (!f) return;
  await f.settle();
  const statuses = f.appended.map(e => e.data.status);
  assert.deepEqual(statuses.slice(-2), ['needs_check', 'accepted']);
});

test('T33: continuation is bounded by canContinue, attempts and no-progress', async t => {
  const f = await gateFixture(t); if (!f) return;
  f.respond({ 'stop-verify': deny('same failure') });
  assert.equal((await f.settle(false)).continue, undefined, 'canContinue false never requests a continuation');
  const fresh = await gateFixture(t);
  fresh.respond({ 'stop-verify': deny('same failure') });
  assert.equal((await fresh.settle()).continue, true);
  assert.equal((await fresh.settle()).continue, true);
  assert.equal((await fresh.settle()).continue, undefined, 'a repeated identical failure stops after two no-progress attempts');
  const varied = await gateFixture(t);
  for (let i = 0; i < 3; i++) {
    varied.respond({ 'stop-verify': deny(`failure ${i}`) });
    assert.equal((await varied.settle()).continue, true);
  }
  varied.respond({ 'stop-verify': deny('failure 4') });
  const last = await varied.settle();
  assert.equal(last.continue, undefined, 'at most three continuations');
  assert.equal(varied.entryState(last).status, 'blocked', 'exhaustion leaves completion blocked');
});

test('T33: a throwing settle handler is an explicit unknown block, not a pass', async t => {
  const f = await gateFixture(t); if (!f) return;
  const broken = { ...f.ctx, sessionManager: { getSessionId: () => { throw new Error('session sentinel'); }, getSessionFile: () => undefined } };
  const result = await f.settle(true, broken);
  assert.equal(f.entryState(result).unknown, true);
  assert.match(result.entries.at(-1).content, /session sentinel/);
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'ls' }))).block, true);
});

test('T33: resets, settling and new prompts never clear a block; only a fresh passing check does', async t => {
  const f = await gateFixture(t); if (!f) return;
  f.respond({ 'stop-verify': 'missing' });
  await f.settle();
  f.fire('before_agent_start', { systemPrompt: '' });
  await f.fire('session_shutdown', { reason: 'quit' });
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'ls' }))).block, true, 'block survived resets');
  assert.equal(f.state().status, 'blocked', 'the next prompt persisted the standing block');
  f.respond({});
  assert.equal(await f.settle(), undefined);
  assert.equal(f.state().status, 'accepted');
  assert.equal(await f.fire('tool_call', f.call('bash', { command: 'ls' })), undefined);
});

test('T33: reload restores a blocked state; missing or malformed state is needs_check', async t => {
  const f = await gateFixture(t); if (!f) return;
  f.respond({ 'stop-verify': 'missing' });
  const saved = f.entryState(await f.settle());
  assert.equal(saved.unknown, true);
  const reloaded = { ...f.ctx, sessionManager: { ...f.ctx.sessionManager, getBranch: () => [{ type: 'custom', customType: 'trellis-completion', data: saved }] } };
  await f.fire('session_start', { reason: 'reload' }, reloaded);
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'ls' }))).block, true, 'reload kept the unknown block');
  for (const data of [undefined, { status: 'accepted' }, { ...saved, binding: 'elsewhere' }]) {
    const ctx = { ...f.ctx, sessionManager: { ...f.ctx.sessionManager, getBranch: () => data === undefined ? [] : [{ type: 'custom', customType: 'trellis-completion', data }] } };
    await f.fire('session_start', { reason: 'reload' }, ctx);
    assert.equal(await f.fire('tool_call', f.call('bash', { command: 'ls' })), undefined);
    f.respond({ 'decision-receipt': deny('still checked') });
    const result = await f.settle();
    assert.equal(f.entryState(result).status, 'blocked', 'needs_check after reload still runs the full check');
  }
});

test('T33: a mandatory local post-edit failure latches completion until that target passes again', async t => {
  const f = await gateFixture(t); if (!f) return;
  writeFileSync(resolve(f.cwd, 'eslint.config.js'), 'export default [];\n');
  mkdirSync(resolve(f.cwd, 'node_modules/.bin'), { recursive: true });
  const eslint = resolve(f.cwd, 'node_modules/.bin/eslint');
  const lint = code => { writeFileSync(eslint, `#!/bin/sh\n[ "$1" = --version ] && exit 0\necho lint-sentinel\nexit ${code}\n`); chmodSync(eslint, 0o755); };
  lint(1);
  writeFileSync(resolve(f.cwd, 'a.ts'), 'export const a = 1;\n');
  const edit = async () => { const call = f.call('write', { path: 'a.ts', content: 'export const a = 1;\n' }); await f.fire('tool_call', call); return f.result(call); };
  await edit();
  assert.equal(f.state().status, 'blocked');
  assert.match(Object.values(f.state().postFailures)[0], /lint-sentinel/);
  const before = f.calls().length;
  const blocked = await f.settle();
  assert.equal(f.entryState(blocked).status, 'blocked');
  assert.match(blocked.entries.at(-1).content, /a\.ts/);
  assert.equal(f.calls().length, before, 'a standing local failure blocks without claiming a native pass');
  assert.equal(await f.fire('tool_call', f.call('write', { path: 'a.ts', content: 'x' })), undefined, 'repair edits stay allowed');
  lint(0);
  await edit();
  assert.deepEqual(f.state().postFailures, {});
  assert.equal(await f.settle(), undefined, 'a fresh passing check accepts');
  assert.equal(f.state().status, 'accepted');
});

// --- T65: blocked state survives every reset/finalization callback ---------
// Host-like persistence: appended entries plus returned custom boundary entries.
function host(f) {
  const entries = [];
  const append = f.pi.appendEntry;
  f.pi.appendEntry = (customType, data) => { append(customType, data); entries.push({ type: 'custom', customType, data: structuredClone(data) }); };
  const settle = async (...args) => {
    const result = await f.settle(...args);
    for (const entry of result?.entries ?? []) if (entry.type === 'custom') entries.push(structuredClone(entry));
    return result;
  };
  const ctx = { ...f.ctx, sessionManager: { ...f.ctx.sessionManager, getBranch: () => entries } };
  const persisted = () => entries.filter(e => e.customType === 'trellis-completion').at(-1)?.data;
  return { entries, settle, ctx, persisted };
}

async function sequence(f, h) {
  await f.fire('agent_settled', { type: 'agent_settled', aborted: false }, h.ctx);
  f.fire('before_agent_start', { systemPrompt: '' }, h.ctx);
  await f.fire('session_shutdown', { reason: 'reload' }, h.ctx);
  await f.fire('session_start', { reason: 'reload' }, h.ctx);
  f.fire('before_agent_start', { systemPrompt: '' }, h.ctx);
}

for (const member of MANDATORY) {
  for (const exhaust of ['canContinue false', 'attempts exhausted']) {
    test(`T65: a failed ${member} (${exhaust}) stays blocked through settle, prompt, shutdown, reload and prompt`, async t => {
      const f = await gateFixture(t); if (!f) return;
      const h = host(f);
      f.respond({ [member]: deny(`${member} sentinel`) });
      if (exhaust === 'canContinue false') assert.equal((await h.settle(false)).continue, undefined);
      else { for (let i = 0; i < 3; i++) await h.settle(); assert.equal((await h.settle()).continue, undefined); }
      const calls = f.calls().length;
      await sequence(f, h);
      assert.equal(f.calls().length, calls, 'no callback ran the native completion or stamp-turn');
      for (const tree of ['.pi', '.codex']) {
        const dir = resolve(f.cwd, tree, '.reread-state');
        assert.ok(!existsSync(dir) || !readdirSync(dir).some(name => name.endsWith('.epoch')), `no turn stamp under ${tree}`);
      }
      assert.equal(h.persisted().status, 'blocked', 'no reset or settle claimed acceptance');
      assert.equal(h.persisted().unknown, false);
      // A known failed project check permits only normally guarded repair.
      assert.equal(await f.fire('tool_call', f.call('bash', { command: 'ls' }), h.ctx), undefined);
      assert.equal((await f.fire('tool_call', f.call('bash', { command: 'rm -rf /' }), h.ctx)).block, true, 'per-call guards still run');
      // Completion stays blocked until a fresh bound check passes.
      assert.equal(h.entries.filter(e => e.data?.status === 'accepted').length, 0);
      f.respond({});
      assert.equal(await h.settle(), undefined);
      assert.equal(h.persisted().status, 'accepted');
    });
  }
}

test('T65: unknown enforcement keeps denying covered actions across every callback and reload', async t => {
  const f = await gateFixture(t); if (!f) return;
  const h = host(f);
  f.respond({ 'required-post-action': 'missing' });
  await h.settle(false);
  await sequence(f, h);
  assert.equal((await f.fire('tool_call', f.call('write', { path: 'x.ts', content: 'x' }), h.ctx)).block, true);
  assert.equal((await f.fire('user_bash', { command: 'ls', cwd: f.cwd, excludeFromContext: true }, h.ctx)).result.exitCode, 1);
  assert.equal(await f.fire('tool_call', f.call('read', { path: 'x.ts' }), h.ctx), undefined);
});

test('T65: a crash before blocked-entry publication leaves needs_check, which never becomes accepted without a check', async t => {
  const f = await gateFixture(t); if (!f) return;
  const h = host(f);
  const exec = f.pi.exec;
  f.pi.exec = async () => { throw new Error('host died mid-check'); };
  const result = await f.settle(); // returned entries are never published: the "crash"
  assert.ok(result.entries.length);
  assert.equal(h.persisted().status, 'needs_check', 'only needs_check reached persistence');
  await f.fire('session_start', { reason: 'reload' }, h.ctx);
  f.fire('before_agent_start', { systemPrompt: '' }, h.ctx);
  assert.notEqual(h.persisted().status, 'accepted');
  // With a working transport again, the next settle must run the full native check.
  f.pi.exec = exec;
  const before = f.calls().length;
  f.respond({ 'stop-verify': deny('checked after reload') });
  const checked = await f.settle(true, h.ctx);
  assert.equal(f.calls().length, before + 1);
  assert.equal(f.entryState(checked).status, 'blocked');
});

test('T65: an operator abort, a shutdown request or an initialization error is never acceptance', async t => {
  const f = await gateFixture(t); if (!f) return;
  const h = host(f);
  f.fire('before_agent_start', { systemPrompt: '' }, h.ctx);
  // Aborted runs skip agent_before_settle and go straight to agent_settled.
  await f.fire('agent_settled', { type: 'agent_settled', aborted: true }, h.ctx);
  await f.fire('session_shutdown', { reason: 'quit' }, h.ctx);
  assert.equal(h.entries.filter(e => e.data?.status === 'accepted').length, 0);
  assert.equal(f.calls().length, 0, 'abort and shutdown never ran the completion check');
  // An initialization error (no attached runtime) is unknown enforcement.
  const broken = await gateFixture(t);
  const b = host(broken);
  const outside = { ...b.ctx, cwd: broken.base };
  const blocked = await broken.settle(true, outside);
  assert.equal(broken.entryState(blocked).unknown, true);
  assert.equal((await broken.fire('tool_call', broken.call('bash', { command: 'ls' }))).block, true);
});

// --- QP review fixes (H2, H3) -----------------------------------------------
test('QP H2: a gate-requested retry runs a fresh check, never a reentrant Stop', async t => {
  const f = await gateFixture(t); if (!f) return;
  f.respond({ 'stop-verify': deny('missing receipt') });
  for (let i = 0; i < 2; i++) {
    const result = await f.settle();
    assert.equal(result.continue, true, 'two unchanged retries stay within the no-progress bound');
    assert.equal(JSON.parse(readFileSync(resolve(f.log, 'stdin'), 'utf8')).stop_hook_active, false, `settle ${i + 1}`);
    assert.equal(f.entryState(result).status, 'blocked');
  }
  f.respond({});
  assert.equal(await f.settle(), undefined);
  assert.equal(JSON.parse(readFileSync(resolve(f.log, 'stdin'), 'utf8')).stop_hook_active, false);
  assert.equal(f.state().status, 'accepted');
});

const error = (reason, error_class) => ({ status: 'error', exit_code: 5, context: '', reason, error_class });
for (const [member, row] of [...[...MANDATORY, 'spec-gate'].map(m => [m, error(`${m} crashed`, 'required')]),
  ['code-review-subagent', error('review crashed', 'required')], ['ui-verify', error('ui crashed', null)]]) {
  test(`QP H3: a ${member} ${row.error_class ?? 'unclassed'} error that denies completion is unknown enforcement`, async t => {
    const f = await gateFixture(t); if (!f) return;
    f.respond({ [member]: row }, { decision: 'deny' });
    const result = await f.settle();
    assert.equal(f.entryState(result).status, 'blocked');
    assert.equal(f.entryState(result).unknown, true, result.entries.at(-1).content);
    assert.equal((await f.fire('tool_call', f.call('bash', { command: 'ls' }))).block, true);
    assert.equal((await f.fire('user_bash', { command: 'ls', cwd: f.cwd, excludeFromContext: true })).result.exitCode, 1);
    f.respond({});
    assert.equal(await f.settle(), undefined, 'a fresh passing check clears it');
    assert.equal(await f.fire('tool_call', f.call('bash', { command: 'ls' })), undefined);
  });
}

test('QP H3: a local verifier launch failure is unknown enforcement, rechecked at settle', async t => {
  const f = await gateFixture(t); if (!f) return;
  writeFileSync(resolve(f.cwd, 'eslint.config.js'), 'export default [];\n');
  mkdirSync(resolve(f.cwd, 'node_modules/.bin'), { recursive: true });
  const eslint = resolve(f.cwd, 'node_modules/.bin/eslint');
  writeFileSync(eslint, '#!/bin/sh\n[ "$1" = --version ] && exit 0\nexit 0\n');
  chmodSync(eslint, 0o755);
  writeFileSync(resolve(f.cwd, 'a.ts'), 'export const a = 1;\n');
  const original = f.pi.exec;
  f.pi.exec = async (cmd, args, opts) => {
    if (cmd === eslint) throw new Error('verifier launch failed sentinel');
    return original(cmd, args, opts);
  };
  const call = f.call('write', { path: 'a.ts', content: 'x' });
  await f.fire('tool_call', call);
  await f.result(call);
  assert.equal(f.state().status, 'blocked');
  assert.equal(f.state().unknown, true);
  assert.match(Object.values(f.state().postFailures)[0], /launch failed sentinel/);
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'ls' }))).block, true);
  assert.equal((await f.fire('tool_call', f.call('write', { path: 'a.ts', content: 'y' }))).block, true);
  // Still broken: settle rechecks, stays unknown, never claims a native pass.
  const before = f.calls().length;
  const blocked = await f.settle();
  assert.equal(f.entryState(blocked).unknown, true);
  assert.equal(f.calls().length, before);
  // The verifier works again (repaired out of band): the settle recheck
  // clears the latch and the native check accepts.
  f.pi.exec = original;
  assert.equal(await f.settle(), undefined);
  assert.equal(f.state().status, 'accepted');
  assert.equal(await f.fire('tool_call', f.call('bash', { command: 'ls' })), undefined);
});
