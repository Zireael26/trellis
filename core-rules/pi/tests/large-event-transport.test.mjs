// Real child-process regressions for large Pi bridge events; not native Pi host proof.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chmodSync, closeSync, copyFileSync, existsSync, ftruncateSync, linkSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import extension from '../extensions/trellis.ts';

const dispatcher = new URL('../hooks/dispatch.sh', import.meta.url);
const supervisor = new URL('../../hooks/lib/guard-supervise.pl', import.meta.url);

function fixture(t) {
  const cwd = mkdtempSync(resolve(tmpdir(), 'trellis-large-transport-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  for (const dir of ['.trellis/runtime/core-rules/pi/hooks', '.trellis/runtime/core-rules/hooks/lib', '.agents/rules', '.trellis/runtime/core-rules/codex/hooks']) {
    mkdirSync(resolve(cwd, dir), { recursive: true });
  }
  const script = resolve(cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh');
  copyFileSync(dispatcher, script);
  chmodSync(script, 0o755);
  copyFileSync(supervisor, resolve(cwd, '.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl'));
  writeFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), '{}');
  writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Scratch policy');
  for (const name of ['block-destructive.sh', 'pr-gate-shiftleft.sh', 'truncation-check.sh']) {
    writeFileSync(resolve(cwd, '.trellis/runtime/core-rules/codex/hooks', name), '#!/bin/bash\nexit 0\n', { mode: 0o755 });
  }
  const calls = [], handlers = new Map();
  const pi = {
    on: (name, handler) => handlers.set(name, handler),
    getAllTools: () => [],
    sendMessage: () => {},
    exec: async (command, args, options) => {
      let summary, fileMode, directoryMode;
      if (args[0] === '--event-file') {
        const event = JSON.parse(readFileSync(args[1], 'utf8'));
        fileMode = statSync(args[1]).mode & 0o7777;
        directoryMode = statSync(dirname(args[1])).mode & 0o7777;
        summary = {
          phase: event.phase,
          inputCommandLength: event.action?.input?.command?.length,
          imageDataLength: event.result?.output?.find(block => block.type === 'image')?.data?.length,
        };
      }
      const result = spawnSync('bash', [command, ...args], {
        cwd: options.cwd, env: process.env, encoding: 'utf8', timeout: 30_000,
      });
      calls.push({ command, argCount: args.length, mode: args[0], file: args[0] === '--event-file' ? args[1] : undefined,
        options, error: result.error?.code, status: result.status, fileMode, directoryMode, summary });
      if (result.error) throw result.error;
      return { stdout: result.stdout, stderr: result.stderr, code: result.status, killed: false };
    },
  };
  extension(pi);
  const ctx = {
    cwd,
    signal: new AbortController().signal,
    ui: { notify: () => {} },
    sessionManager: { getSessionId: () => 'large-event', getSessionFile: () => undefined },
  };
  return { cwd, script, calls, handlers, pi, ctx };
}

test('large pre-action input and image-sized shell result cross the process boundary without argv payload', async t => {
  const f = fixture(t);
  const largeInput = 'gh pr create --title ' + 'x'.repeat(2 * 1024 * 1024);
  const pre = await f.handlers.get('tool_call')({
    toolCallId: 'large-input', toolName: 'bash', input: { command: largeInput },
  }, f.ctx);
  const post = await f.handlers.get('tool_result')({
    toolCallId: 'large-result', toolName: 'bash', input: { command: 'printf image' },
    content: [{ type: 'image', data: 'A'.repeat(2 * 1024 * 1024), mimeType: 'image/png' }], isError: false,
  }, f.ctx);
  // Exercise both real spawns before asserting: historical red must prove
  // E2BIG for the image result too, not stop after the pre-action failure.
  assert.deepEqual(f.calls.map(call => call.error), [undefined, undefined]);
  assert.equal(pre, undefined);
  assert.equal(post, undefined);
  assert.equal(f.calls.length, 2);
  for (const call of f.calls) {
    assert.equal(call.mode, '--event-file');
    assert.equal(call.argCount, 2);
    assert.equal(call.fileMode, 0o600);
    assert.equal(call.directoryMode, 0o700);
    assert.equal(call.options.cwd, f.cwd);
    assert.equal(call.options.timeout, 300_000);
    assert.equal(call.options.signal, f.ctx.signal);
    assert.equal(existsSync(call.file), false, 'event leaf should be removed after dispatch');
    assert.equal(existsSync(dirname(call.file)), false, 'owned private directory should be removed after dispatch');
  }
  assert.equal(f.calls[0].summary.inputCommandLength, largeInput.length);
  assert.equal(f.calls[1].summary.imageDataLength, 2 * 1024 * 1024);
});

test('dispatcher rejects non-private, linked, and oversized event files without echoing data', t => {
  const f = fixture(t);
  const directory = mkdtempSync(resolve(f.cwd, 'event-validation-'));
  chmodSync(directory, 0o700);
  const sentinel = 'DO_NOT_ECHO_EVENT_SENTINEL';
  const event = JSON.stringify({ schema_version: 1, harness: 'pi', cwd: f.cwd, phase: 'lifecycle', native_event: 'session_before_compact', session_id: sentinel });
  const good = resolve(directory, 'good.json');
  writeFileSync(good, event, { flag: 'wx', mode: 0o600 });
  chmodSync(good, 0o600);
  const run = path => {
    const result = spawnSync('bash', [f.script, '--event-file', path], { cwd: f.cwd, env: process.env, encoding: 'utf8' });
    assert.equal(result.error, undefined);
    assert.doesNotMatch(result.stdout, new RegExp(sentinel));
    return { status: result.status, decision: JSON.parse(result.stdout) };
  };
  const valid = run(good);
  assert.equal(valid.status, 0);
  assert.equal(valid.decision.decision, 'allow');
  const legacy = spawnSync('bash', [f.script, '--base64', Buffer.from(event).toString('base64')], {
    cwd: f.cwd, env: process.env, encoding: 'utf8',
  });
  assert.equal(legacy.status, 0);
  assert.equal(JSON.parse(legacy.stdout).decision, 'allow');
  assert.doesNotMatch(legacy.stdout, new RegExp(sentinel));

  const badMode = resolve(directory, 'bad-mode.json');
  writeFileSync(badMode, event, { mode: 0o644 });
  chmodSync(badMode, 0o644);
  const unsafeMode = run(badMode);
  assert.equal(unsafeMode.status, 2);
  assert.equal(unsafeMode.decision.decision, 'deny');

  const linked = resolve(directory, 'hardlink.json');
  linkSync(good, linked);
  const unsafeLink = run(linked);
  assert.equal(unsafeLink.status, 2);
  assert.equal(unsafeLink.decision.decision, 'deny');
  const symlink = resolve(directory, 'symlink.json');
  symlinkSync(good, symlink);
  const unsafeSymlink = run(symlink);
  assert.equal(unsafeSymlink.status, 2);
  assert.equal(unsafeSymlink.decision.decision, 'deny');

  const wrongParent = resolve(directory, 'public-parent');
  mkdirSync(wrongParent, { mode: 0o755 });
  chmodSync(wrongParent, 0o755);
  const parentFile = resolve(wrongParent, 'event.json');
  writeFileSync(parentFile, event, { mode: 0o600 });
  chmodSync(parentFile, 0o600);
  const unsafeParent = run(parentFile);
  assert.equal(unsafeParent.status, 2);
  assert.equal(unsafeParent.decision.decision, 'deny');

  const oversized = resolve(directory, 'oversized.json');
  const fd = openSync(oversized, 'wx', 0o600);
  ftruncateSync(fd, 64 * 1024 * 1024 + 1);
  closeSync(fd);
  chmodSync(oversized, 0o600);
  const tooLarge = run(oversized);
  assert.equal(tooLarge.status, 2);
  assert.equal(tooLarge.decision.decision, 'deny');
});

test('temporary event transport cleans up after spawn failure/cancellation and reports cleanup refusal', async t => {
  for (const failure of [new Error('spawn failure sentinel'), Object.assign(new Error('cancel sentinel'), { name: 'AbortError' })]) {
    const f = fixture(t);
    let eventFile;
    f.pi.exec = async (_command, args, options) => {
      assert.equal(args[0], '--event-file');
      assert.equal(options.signal, f.ctx.signal);
      eventFile = args[1];
      throw failure;
    };
    const blocked = await f.handlers.get('tool_call')({
      toolCallId: failure.name, toolName: 'bash', input: { command: 'gh pr create' },
    }, f.ctx);
    assert.equal(blocked.block, true);
    assert.match(blocked.reason, /spawn failure sentinel|cancel sentinel/);
    assert.equal(existsSync(eventFile), false);
    assert.equal(existsSync(dirname(eventFile)), false);
  }

  const f = fixture(t);
  let eventFile, leftover;
  f.pi.exec = async (_command, args) => {
    eventFile = args[1];
    leftover = resolve(dirname(eventFile), 'unowned-sentinel');
    writeFileSync(leftover, 'preserve');
    return { stdout: JSON.stringify({ schema_version: 1, capability_status: 'enforced', decision: 'allow' }), stderr: '', code: 0, killed: false };
  };
  const directory = () => dirname(eventFile);
  t.after(() => { if (eventFile) rmSync(directory(), { recursive: true, force: true }); });
  const blocked = await f.handlers.get('tool_call')({
    toolCallId: 'cleanup-refusal', toolName: 'bash', input: { command: 'gh pr create' },
  }, f.ctx);
  assert.equal(blocked.block, true);
  assert.match(blocked.reason, /event transport cleanup failed/);
  assert.equal(existsSync(eventFile), false);
  assert.equal(existsSync(leftover), true, 'cleanup must not recursively remove an unowned leaf');
});
