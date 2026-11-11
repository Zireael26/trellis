import assert from 'node:assert/strict';
import { test } from 'node:test';
import { resolve } from 'node:path';
import { rmSync, writeFileSync } from 'node:fs';
import { deliveredFixture } from './delivered-fixture.mjs';

for (const corrupt of [false, true]) {
  test(`rules initialize inside registered gates (${corrupt ? 'corrupt' : 'missing'})`, async t => {
    const f = await deliveredFixture(t);
    // Registration must not have read resources yet. A failure at first use
    // remains a deny, not an extension that disappears from Pi's registry.
    const path = resolve(f.runtime, 'core-rules/hooks/rules/destructive.json');
    if (corrupt) writeFileSync(path, '{'); else rmSync(path);
    for (const name of ['tool_call', 'user_bash']) assert.ok(f.handlers.has(name));
    const call = await f.fire('tool_call', f.call('bash', { command: 'printf harmless' }));
    assert.equal(call.block, true);
    assert.match(call.reason, /guard rules are unavailable/);
    const bash = await f.fire('user_bash', { command: 'printf harmless', cwd: f.cwd });
    assert.equal(bash.result.exitCode, 1);
    assert.match(bash.result.output, /guard rules are unavailable/);
    assert.equal(f.calls.length, 0);
  });
}

test('unexpected context initialization exceptions deny through both installed gates', async t => {
  const f = await deliveredFixture(t);
  const ctx = { ...f.ctx, sessionManager: { getSessionId() { throw new Error('initialization sentinel'); } } };
  const call = await f.fire('tool_call', f.call('bash', { command: 'echo ok' }), ctx);
  assert.equal(call.block, true);
  assert.match(call.reason, /initialization sentinel/);
  const bash = await f.fire('user_bash', { command: 'echo ok', cwd: f.cwd }, ctx);
  assert.equal(bash.result.exitCode, 1);
  assert.match(bash.result.output, /initialization sentinel/);
  assert.equal(f.calls.length, 0);
});
