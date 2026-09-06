// Real Bash dispatcher boundary tests; no native SDK/session or hook-body proof.
// Run: node --test core-rules/pi/tests/dispatcher-denials.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const dispatcher = new URL('../hooks/dispatch.sh', import.meta.url);
const top = { decision: 'block', reason: 'top reason' };
const nested = { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: 'nested reason' } };
function fixture(t) {
  const cwd = mkdtempSync(resolve(tmpdir(), 'trellis-denials-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  for (const dir of ['.trellis/runtime/core-rules/pi/hooks', '.pi/hooks', 'tmp']) mkdirSync(resolve(cwd, dir), { recursive: true });
  const script = resolve(cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh');
  copyFileSync(dispatcher, script);
  writeFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), '{}');
  const hook = (name, output, rc, stderr = '') => {
    const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
    writeFileSync(resolve(cwd, '.pi/hooks', name), `#!/bin/bash\nprintf '%s' ${quote(output)}\nprintf '%s' ${quote(stderr)} >&2\nexit ${rc}\n`, { mode: 0o755 });
  };
  const run = (optional = false) => {
    const event = { schema_version: 1, harness: 'pi', cwd, session_id: 'scratch', phase: optional ? 'post_action' : 'pre_action', native_event: optional ? 'tool_result' : 'tool_call', action: { family: 'shell', tool_name: 'bash', input: { command: 'printf harmless' }, targets: [] }, result: optional ? { status: 'succeeded', is_error: false, output: [] } : null };
    const result = spawnSync('bash', [script, '--base64', Buffer.from(JSON.stringify(event)).toString('base64')], { cwd, env: { PATH: process.env.PATH, HOME: cwd, TMPDIR: resolve(cwd, 'tmp') }, encoding: 'utf8', timeout: 10_000 });
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    return { status: result.status, decision: JSON.parse(result.stdout) };
  };
  hook('pr-gate-shiftleft.sh', '', 0);
  return { hook, run };
}

for (const [name, payload, reason] of [['top', top, 'top reason'], ['nested', nested, 'nested reason']]) {
  for (const rc of [0, 2]) {
    test(`${name} denial exit ${rc} is enforced with parsed reason`, t => {
      const f = fixture(t);
      f.hook('block-destructive.sh', JSON.stringify(payload), rc);
      const result = f.run();
      assert.equal(result.status, 1);
      assert.equal(result.decision.decision, 'deny');
      assert.equal(result.decision.capability_status, 'enforced');
      assert.equal(result.decision.reason, `block-destructive.sh: ${reason}`);
    });
    test(`optional ${name} denial exit ${rc} warns without hard denial`, t => {
      const f = fixture(t);
      f.hook('truncation-check.sh', JSON.stringify(payload), rc);
      const result = f.run(true);
      assert.equal(result.status, 0);
      assert.equal(result.decision.decision, 'warn');
      assert.equal(result.decision.capability_status, 'advisory');
      assert.equal(result.decision.reason, `truncation-check.sh: ${reason}`);
    });
  }
}

for (const [name, output, rc] of [
  ['malformed', '{"decision":"block"', 2],
  ['nonJSON', 'hook failed', 2],
  ['empty', '', 2],
  ['no denial', '{}', 2],
  ['array is not a denial object', JSON.stringify([top]), 2],
  ['wrong nested event', JSON.stringify({ hookSpecificOutput: { ...nested.hookSpecificOutput, hookEventName: 'PostToolUse' } }), 2],
  ['crash', '', 5],
  ['crash with valid block', JSON.stringify(top), 5],
  ['timeout status with valid block', JSON.stringify(top), 124],
]) {
  test(`${name} exit ${rc} stays unknown and fails closed`, t => {
    const f = fixture(t);
    f.hook('block-destructive.sh', output, rc);
    const result = f.run();
    assert.equal(result.status, 1);
    assert.equal(result.decision.decision, 'deny');
    assert.equal(result.decision.capability_status, 'unknown');
    assert.match(result.decision.reason, new RegExp(`unknown — exited ${rc}`));
  });
}

test('both reasons, context and stderr survive without weakening denial', t => {
  const f = fixture(t);
  f.hook('block-destructive.sh', JSON.stringify({ ...top, hookSpecificOutput: { ...nested.hookSpecificOutput, additionalContext: 'context sentinel' } }), 2, 'stderr sentinel');
  const result = f.run();
  assert.equal(result.status, 1);
  assert.equal(result.decision.decision, 'deny');
  assert.equal(result.decision.capability_status, 'unknown');
  assert.equal(result.decision.context, 'context sentinel');
  assert.equal(result.decision.reason, 'block-destructive.sh: top reason\nnested reason\nblock-destructive.sh stderr: stderr sentinel');
});

for (const output of ['', JSON.stringify({ hookSpecificOutput: { permissionDecision: 'allow', hookEventName: 'PreToolUse' } })]) {
  test(`required stderr with exit-zero ${output ? 'self-permit' : 'empty output'} warns with unknown capability`, t => {
    const f = fixture(t);
    f.hook('block-destructive.sh', output, 0, 'required diagnostic');
    const result = f.run();
    assert.equal(result.status, 0);
    assert.equal(result.decision.decision, 'warn');
    assert.equal(result.decision.capability_status, 'unknown');
    assert.match(result.decision.reason, /required diagnostic/);
  });
}

for (const payload of [top, nested]) {
  for (const rc of [0, 2]) {
    test(`required ${payload === top ? 'top' : 'nested'} deny with stderr exit ${rc} remains deny and unknown`, t => {
      const f = fixture(t);
      f.hook('block-destructive.sh', JSON.stringify(payload), rc, 'required diagnostic');
      const result = f.run();
      assert.equal(result.status, 1);
      assert.equal(result.decision.decision, 'deny');
      assert.equal(result.decision.capability_status, 'unknown');
      assert.match(result.decision.reason, /required diagnostic/);
    });
  }
}

test('optional stderr remains advisory and warns without denying', t => {
  const f = fixture(t);
  f.hook('truncation-check.sh', '', 0, 'optional diagnostic');
  const result = f.run(true);
  assert.equal(result.status, 0);
  assert.equal(result.decision.decision, 'warn');
  assert.equal(result.decision.capability_status, 'advisory');
  assert.match(result.decision.reason, /optional diagnostic/);
});

test('later optional context cannot clear an earlier optional denial warning', t => {
  const f = fixture(t);
  f.hook('block-destructive.sh', JSON.stringify({ hookSpecificOutput: { additionalContext: 'pre context' } }), 0, 'first warning');
  f.hook('pr-gate-shiftleft.sh', JSON.stringify(nested), 0);
  const result = f.run();
  assert.equal(result.status, 0);
  assert.equal(result.decision.decision, 'warn');
  assert.equal(result.decision.context, 'pre context');
  assert.match(result.decision.reason, /first warning/);
  assert.match(result.decision.reason, /nested reason/);
});
