// Delivered callback boundaries against the real bash budget, never a live home.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { test } from 'node:test';
import { deliveredFixture } from './delivered-fixture.mjs';

function shell(f, command, ...args) {
  const result = spawnSync('bash', ['--noprofile', '--norc', '-c', `source "$1" && ${command}`, 'skill-budget-parity',
    resolve(f.runtime, 'core-rules/hooks/lib/skill-size.sh'), ...args], {
    cwd: f.cwd, encoding: 'utf8', timeout: 10_000,
    env: { PATH: process.env.PATH, HOME: f.cwd, TRELLIS_HOME: resolve(f.cwd, 'trellis'), TMPDIR: resolve(f.cwd, 'tmp') },
  });
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  return result;
}

test('M1 shell skill budget matches native read and slash boundaries', async t => {
  const f = await deliveredFixture(t);
  const sourced = shell(f, 'printf \'%s\\n\' "$SKILL_SIZE_BUDGET_BYTES"');
  assert.equal(sourced.status, 0, sourced.stderr);
  assert.match(sourced.stdout.trim(), /^[1-9][0-9]*$/);
  const budget = Number(sourced.stdout.trim());
  assert.ok(Number.isSafeInteger(budget) && budget > 0, 'shell budget must be a positive integer');
  for (const bytes of [budget, budget + 1]) {
    const name = `boundary-${bytes}`, path = f.skill(name, bytes);
    const checked = shell(f, 'skill_size_check_root "$2"', resolve(path, '..'));
    assert.equal(checked.status, bytes > budget ? 1 : 0, checked.stderr);
    const read = await f.fire('tool_call', f.call('read', { path }));
    assert.equal(read?.block, checked.status === 1 ? true : undefined, `native read at ${bytes} bytes`);
    const slash = await f.fire('input', { text: `/skill:${name}`, source: 'rpc' });
    assert.equal(slash?.action, checked.status === 1 ? 'handled' : undefined, `slash preload at ${bytes} bytes`);
  }
  assert.equal(f.calls.length, 0, 'native preload checks must not dispatch');
});

test('L1 native edit success prefix containing not found grants read credit', async t => {
  const f = await deliveredFixture(t);
  f.pi.exec = async () => ({ stdout: '{"schema_version":1,"capability_status":"enforced","decision":"allow"}', stderr: '', code: 0 });
  writeFileSync(resolve(f.cwd, 'file'), 'not found');
  const edit = f.call('edit', { path: 'file' });
  assert.equal(await f.fire('tool_call', edit), undefined);
  assert.match(f.notifications.at(-1)[0], /reread-guard:.*warn/);
  await f.fire('tool_result', { ...edit, isError: false,
    content: [{ type: 'text', text: 'Success. Updated the following files:\nM file\n- not found\n+ found' }] });
  const warnings = f.notifications.length;
  for (let i = 0; i < 3; i++) {
    assert.equal(await f.fire('tool_call', f.call('edit', { path: 'file' })), undefined, 'successful edit grants read credit');
  }
  assert.equal(f.notifications.length, warnings, 'later edits neither warn nor exhaust the reread budget');
});
