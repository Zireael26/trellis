// Extension dispatch boundary with real signal deaths and stubbed exec statuses;
// not a native Pi SDK/session proof.
// Run: node --test core-rules/pi/tests/dispatch-signal.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import extension from '../extensions/trellis.ts';

// Optional qualification against a read-only copy of Pi's actual exec module.
const realExec = process.env.PI_EXEC_MODULE ? (await import(process.env.PI_EXEC_MODULE)).execCommand : undefined;

const document = decision => JSON.stringify({ schema_version: 1, capability_status: 'advisory', decision, reason: 'partial output sentinel' });
const nonceFrom = args => args[0]?.startsWith('TRELLIS_PI_DISPATCH_NONCE=') ? args[0].split('=')[1] : undefined;
const terminal = nonce => JSON.stringify({ schema_version: 1, type: 'trellis_dispatch_complete', nonce, complete: true });
const completed = (decision, args) => `${document(decision)}\n${terminal(nonceFrom(args))}\n`;

function fixture(t, prefix = 'trellis-dispatch-signal-') {
  const cwd = mkdtempSync(resolve(tmpdir(), prefix));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const script = resolve(cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh');
  mkdirSync(resolve(script, '..'), { recursive: true });
  mkdirSync(resolve(cwd, '.agents/rules'), { recursive: true });
  writeFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), '{}');
  writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Fixture parent policy');
  writeFileSync(script, '#!/bin/bash\nexit 0\n', { mode: 0o755 });
  const handlers = new Map(), notifications = [];
  const pi = {
    on: (name, handler) => handlers.set(name, handler),
    // Pi 0.85 builtin metadata: the extension refuses read/edit/write/bash
    // whose provenance is not a single builtin (ccbe6a0c7).
    getAllTools: () => ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'].map(name => ({
      name, sourceInfo: { path: `<builtin:${name}>`, source: 'builtin', scope: 'temporary', origin: 'top-level', baseDir: undefined },
    })),
    sendMessage: () => {},
    exec: async () => { throw new Error('exec response not configured'); },
  };
  extension(pi);
  const ctx = { cwd, signal: new AbortController().signal,
    ui: { notify: (...args) => notifications.push(args) },
    sessionManager: { getSessionId: () => 'signal-session', getSessionFile: () => undefined } };
  const tool = () => handlers.get('tool_call')({ toolCallId: 'shell', toolName: 'bash', input: { command: 'gh pr create' } }, ctx);
  const user = () => handlers.get('user_bash')({ command: 'gh pr create', cwd, excludeFromContext: false }, ctx);
  return { cwd, script, pi, notifications, tool, user };
}

async function assertBlocked(f, status) {
  const tool = await f.tool();
  assert.equal(tool?.block, true, 'tool action must not run');
  assert.match(tool.reason, /dispatcher/i);
  assert.ok(tool.reason.includes(String(status)), `reason must name status ${String(status)}: ${tool.reason}`);
  assert.doesNotMatch(tool.reason, /partial output sentinel/);
  const user = await f.user();
  assert.equal(user?.result.exitCode, 1, 'user bash must not run');
  assert.ok(user.result.output.includes(String(status)));
}

for (const decision of ['warn', 'allow', 'deny', 'malformed']) {
  test(`real child prints ${decision} then SIGTERM: tool and user bash block`, async t => {
    const f = fixture(t);
    const stdout = decision === 'malformed' ? '{"decision":' : document(decision);
    writeFileSync(f.script, `#!/bin/bash\nprintf '%s\\n' '${stdout}'\nkill -TERM $$\n`);
    f.pi.exec = async (script, args, options) => {
      if (realExec) {
        const result = await realExec(script, args, options.cwd, options);
        assert.equal(result.stdout.trim(), stdout);
        assert.equal(result.code, 0);
        assert.equal(result.killed, false);
        assert.equal(result.truncated, false);
        return result;
      }
      const child = spawnSync(script, args, { cwd: options.cwd, encoding: 'utf8', timeout: 10_000 });
      assert.equal(child.error, undefined);
      assert.equal(child.signal, 'SIGTERM');
      assert.equal(child.status, null);
      assert.equal(child.stdout.trim(), stdout);
      // Exact external-signal mapping in @earendil-works/pi-coding-agent 1.5.0:
      // dist/utils/child-process.js:86 drops the signal; dist/core/exec.js:109
      // uses code ?? 0, and :38 sets killed only when Pi sends the kill itself.
      return { stdout: child.stdout, stderr: child.stderr, code: child.status ?? 0, killed: false, truncated: false };
    };
    await assertBlocked(f, 0);
  });
}

for (const decision of ['warn', 'allow', 'deny']) {
  test(`killed true with code 0 overrides valid ${decision}`, async t => {
    const f = fixture(t);
    f.pi.exec = async (_command, args) => ({ stdout: completed(decision, args), stderr: '', code: 0, killed: true });
    await assertBlocked(f, 0);
    assert.match(f.notifications[0][0], /killed|signal/i);
  });
  for (const code of [null, undefined, -1, 0.5, 128, 143, 255, NaN, Infinity, '0', false]) {
    test(`status ${String(code)} with valid ${decision} fails closed even without killed`, async t => {
      const f = fixture(t);
      f.pi.exec = async (_command, args) => ({ stdout: completed(decision, args), stderr: 'unrelated diagnostic', code, killed: false });
      await assertBlocked(f, code);
    });
  }
}

for (const response of [{ code: 0, killed: true }, { code: null, killed: false }]) {
  test(`abnormal exec ${String(response.code)}/${response.killed} is rejected before reading stdout`, async t => {
    const f = fixture(t);
    f.pi.exec = async () => ({ ...response, stderr: '', get stdout() { throw new Error('stdout must not be read'); } });
    await assertBlocked(f, response.code);
  });
}

for (const code of [0, 1, 127]) {
  test(`normal status ${code} with warn still warns without blocking`, async t => {
    const f = fixture(t);
    f.pi.exec = async (_command, args) => ({ stdout: completed('warn', args), stderr: '', code, killed: false });
    assert.equal(await f.tool(), undefined);
    assert.deepEqual(f.notifications[0], ['partial output sentinel', 'warning']);
    assert.equal(await f.user(), undefined);
  });
}

for (const [code, decision] of [[0, 'deny'], [1, 'deny'], [1, 'allow'], [127, 'allow']]) {
  test(`existing denial for ${decision} at status ${code} remains blocking`, async t => {
    const f = fixture(t);
    f.pi.exec = async (_command, args) => ({ stdout: completed(decision, args), stderr: '', code, killed: false });
    assert.equal((await f.tool()).block, true);
    assert.equal((await f.user()).result.exitCode, 1);
  });
}

for (const [name, output] of [
  ['missing terminal record', () => `${document('warn')}\n`],
  ['wrong nonce', () => `${document('allow')}\n${terminal('0'.repeat(64))}\n`],
  ['empty output', () => ''],
  ['partial JSON', () => '{"decision":'],
  ['extra output after terminal', args => `${completed('allow', args)}extra\n`],
  ['blank output after terminal', args => `${completed('allow', args)}\n`],
  ['extra output before decision', args => `extra\n${completed('allow', args)}`],
  ['two decisions', args => `${document('warn')}\n${completed('allow', args)}`],
  ['two terminal records', args => `${completed('allow', args)}${terminal(nonceFrom(args))}\n`],
  ['incomplete terminal', args => `${document('allow')}\n${JSON.stringify({ schema_version: 1, type: 'trellis_dispatch_complete', nonce: nonceFrom(args), complete: false })}\n`],
  ['malformed terminal', () => `${document('allow')}\n{\n`],
  ['terminal with unexpected field', args => `${document('allow')}\n${JSON.stringify({ schema_version: 1, type: 'trellis_dispatch_complete', nonce: nonceFrom(args), complete: true, extra: true })}\n`],
]) {
  test(`completion protocol denies ${name} even with status 0/killed false`, async t => {
    const f = fixture(t);
    f.pi.exec = async (_command, args) => ({ stdout: output(args), stderr: '', code: 0, killed: false });
    await assertBlocked(f, 0);
  });
}

test('truncated result denies even when the complete record survived', async t => {
  const f = fixture(t);
  f.pi.exec = async (_command, args) => ({ stdout: completed('allow', args), stderr: '', code: 0, killed: false, truncated: true });
  await assertBlocked(f, 0);
  assert.match(f.notifications[0][0], /truncated/i);
});

test('matching completion permits allow and supplies a fresh nonce only through env argv', async t => {
  const f = fixture(t), nonces = new Set();
  f.pi.exec = async (command, args) => {
    assert.equal(command, '/usr/bin/env');
    const nonce = nonceFrom(args);
    assert.match(nonce, /^[a-f0-9]{64}$/);
    assert.ok(!nonces.has(nonce));
    nonces.add(nonce);
    assert.equal(args[1], '/bin/bash');
    assert.equal(args[2], f.script);
    assert.equal(args[3], '--event-file');
    assert.equal(args.length, 5);
    return { stdout: completed('allow', args), stderr: '', code: 0, killed: false, truncated: false };
  };
  assert.equal(await f.tool(), undefined);
  assert.equal(await f.user(), undefined);
  assert.equal(nonces.size, 2);
});

test('a project root containing = dispatches a completed warning through real argv', async t => {
  const f = fixture(t, 'trellis-dispatch=');
  writeFileSync(f.script, `#!/bin/bash\nexec python3 -I - <<'PY'\nimport json, os\nprint('${document('warn')}')\nprint(json.dumps(dict(schema_version=1, type='trellis_dispatch_complete', nonce=os.environ['TRELLIS_PI_DISPATCH_NONCE'], complete=True)))\nPY\n`);
  f.pi.exec = async (command, args, options) => {
    const result = realExec ? await realExec(command, args, options.cwd, options)
      : (() => {
        const child = spawnSync(command, args, { cwd: options.cwd, encoding: 'utf8', timeout: 10_000 });
        assert.equal(child.error, undefined);
        assert.equal(child.signal, null);
        return { stdout: child.stdout, stderr: child.stderr, code: child.status ?? 0, killed: false };
      })();
    assert.equal(result.code, 0, result.stderr);
    return result;
  };
  assert.equal(await f.tool(), undefined);
  assert.deepEqual(f.notifications[0], ['partial output sentinel', 'warning']);
  assert.equal(await f.user(), undefined);
});

test('a terminal record replayed from an earlier call denies', async t => {
  const f = fixture(t);
  let previous;
  f.pi.exec = async (_command, args) => {
    const stdout = previous ?? completed('allow', args);
    previous = stdout;
    return { stdout, stderr: '', code: 0, killed: false };
  };
  assert.equal(await f.tool(), undefined);
  assert.equal((await f.tool()).block, true);
  assert.equal((await f.user()).result.exitCode, 1);
});
