// Native session_compact envelopes through the actual dispatcher plus the existing
// stub ExtensionAPI transport. Not native pi execution, not a task-state audit:
// the primitive is stubbed so the protocol under test is chosen, and the shared
// library is exercised from its physical installed sibling location.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import extension from '../extensions/trellis.ts';

const dispatcher = new URL('../hooks/dispatch.sh', import.meta.url);
const library = new URL('../../hooks/lib/task-context.sh', import.meta.url);
const NOTE = 'Canonical task documents are authoritative';
const HEADER = 'task-context v1:';

// A chosen-protocol stand-in for the installed primitive. It never captures,
// never discovers documents and never reads a transcript; it records the cwd it
// was handed so the caller's "actual cwd" claim is observable.
const STUB = `import json, pathlib, sys
argv = sys.argv[1:]
here = pathlib.Path(__file__).resolve().parent
if argv[:2] != ["read", "--cwd"] or len(argv) != 3:
    sys.stdout.write('{"status":"unavailable","reason":"invalid_invocation","documents":[],"foreign_records":0}')
    raise SystemExit(1)
(here / "invoked-cwd").write_text(argv[2], encoding="utf-8")
spec = json.loads((here / "protocol.json").read_text(encoding="utf-8"))
sys.stdout.buffer.write(spec["raw"].encode("utf-8"))
sys.stdout.buffer.flush()
raise SystemExit(spec["exit"])
`;

function fixture(t, { lib = true, primitive = true } = {}) {
  const cwd = mkdtempSync(resolve(tmpdir(), 'trellis-task-compact-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const runtime = resolve(cwd, '.trellis/runtime');
  for (const dir of ['core-rules/pi/hooks', 'core-rules/hooks/lib']) mkdirSync(resolve(runtime, dir), { recursive: true });
  for (const dir of ['.agents/rules', '.pi/hooks', 'core-rules/hooks/lib']) mkdirSync(resolve(cwd, dir), { recursive: true });
  // The dispatcher under test is executed from its installed runtime location,
  // so the library it resolves is the physical sibling of that copy.
  const script = resolve(runtime, 'core-rules/pi/hooks/dispatch.sh');
  copyFileSync(dispatcher, script);
  writeFileSync(resolve(runtime, 'trellis.config.json'), '{}');
  writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Scratch policy');
  const installed = resolve(runtime, 'core-rules/hooks/lib');
  assert.ok(existsSync(library), 'the shared task-context library must be installed to run these cases');
  if (lib) copyFileSync(library, resolve(installed, 'task-context.sh'));
  // A decoy under the working directory proves resolution is physical, not $PWD.
  writeFileSync(resolve(cwd, 'core-rules/hooks/lib/task-context.sh'),
    'trellis_task_context() { printf "DECOY CWD LIBRARY\\n"; }\n');
  const protocol = (raw, exit = 0) => {
    if (!primitive) return;
    writeFileSync(resolve(installed, 'task-state.py'), STUB);
    writeFileSync(resolve(installed, 'protocol.json'), JSON.stringify({ raw, exit }));
  };
  const hook = (name, body) => writeFileSync(resolve(cwd, '.pi/hooks', name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  hook('inject-primer-index.sh', 'exit 0');
  const event = (native_event, extra = {}) => ({
    schema_version: 1, harness: 'pi', cwd, session_id: 'scratch', phase: 'lifecycle', native_event, ...extra,
  });
  const run = (payload) => {
    const result = spawnSync('bash', [script, '--base64', Buffer.from(JSON.stringify(payload)).toString('base64')],
      { cwd, env: process.env, encoding: 'utf8' });
    return { ...result, decision: JSON.parse(result.stdout) };
  };
  const handlers = new Map(), messages = [], notifications = [];
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
  const ctx = { cwd, ui: { notify: (...args) => notifications.push(args) },
    sessionManager: { getSessionId: () => 'scratch', getSessionFile: () => undefined } };
  return { cwd, installed, protocol, hook, event, run, pi, handlers, messages, notifications, ctx };
}

const document = (path, status, tasks) => ({ status, source: { path }, ...(tasks ? { tasks } : {}) });
const available = (documents, foreign = 0) => JSON.stringify({ status: 'available', documents, foreign_records: foreign });
const count = (text, needle) => text.split(needle).length - 1;

// Every advisory the dispatcher forwards must stay inside the library's byte bound.
function bounded(context) {
  assert.ok(context.includes(HEADER), `advisory header missing: ${context}`);
  assert.ok(context.includes(NOTE), `authority note missing: ${context}`);
  assert.equal(count(context, HEADER), 1, `advisory propagated ${count(context, HEADER)} times`);
  assert.ok(Buffer.byteLength(context, 'utf8') <= 512, 'advisory exceeded the 512-byte bound');
  assert.doesNotMatch(context, /DECOY CWD LIBRARY/);
}

function compact(f) {
  const observed = f.run(f.event('session_compact', { reason: 'manual' }));
  assert.equal(observed.status, 0, `dispatcher exited ${observed.status}: ${observed.stderr}`);
  assert.equal(observed.decision.decision, 'allow');
  assert.equal(observed.decision.capability_status, 'advisory');
  bounded(observed.decision.context ?? '');
  // The existing unsupported claims for portable recovery are preserved.
  assert.match(observed.decision.reason, /save-context-log\.sh: unsupported/);
  assert.doesNotMatch(observed.decision.reason, new RegExp(HEADER));
  return observed.decision.context;
}

test('a current capture reports only bounded counts on native compaction, with the actual cwd', t => {
  const f = fixture(t);
  f.protocol(available([document('tasks.md', 'current', [{ checked: true }, { checked: false }, { checked: false }])]));
  const context = compact(f);
  assert.match(context, /status=available documents=1 foreign_records=0 checked=1 pending=2/);
  assert.match(context, /- "tasks\.md": current checked=1 pending=2/);
  assert.equal(readFileSync(resolve(f.installed, 'invoked-cwd'), 'utf8'), f.cwd);
});

test('stale and missing sources are named and contribute no counts', t => {
  const f = fixture(t);
  f.protocol(available([document('plan.md', 'stale'), document('tasks.md', 'missing')]));
  const context = compact(f);
  assert.match(context, /status=available documents=2 foreign_records=0 checked=0 pending=0/);
  assert.match(context, /- "plan\.md": stale/);
  assert.match(context, /- "tasks\.md": missing/);
});

test('foreign records are counted but never replayed as this worktree', t => {
  const f = fixture(t);
  f.protocol(available([document('tasks.md', 'current', [{ checked: true }])], 3));
  const context = compact(f);
  assert.match(context, /status=available documents=1 foreign_records=3 checked=1 pending=0/);
  assert.match(context, /- "tasks\.md": current checked=1 pending=0/);
  assert.doesNotMatch(context, /other|foreign one/);
});

test('an uncaptured worktree yields the bounded no_records advisory without invented detail', t => {
  const f = fixture(t);
  f.protocol(JSON.stringify({ status: 'no_records', documents: [], foreign_records: 0 }));
  const context = compact(f);
  assert.match(context, /status=no_records documents=0 foreign_records=0 checked=0 pending=0/);
  assert.equal(context.trimEnd().split('\n').length, 2);
});

test('foreign-only records yield healthy no_records without replaying another worktree', t => {
  const f = fixture(t);
  f.protocol(JSON.stringify({ status: 'no_records', documents: [], foreign_records: 2 }));
  const context = compact(f);
  assert.match(context, /status=no_records documents=0 foreign_records=2 checked=0 pending=0/);
  assert.equal(context.trimEnd().split('\n').length, 2);
});

for (const [name, setup, reason] of [
  ['the primitive reports unavailable', f => f.protocol(JSON.stringify({ status: 'unavailable', reason: 'state_directory_drift', documents: [], foreign_records: 0 }), 1), 'state_directory_drift'],
  ['the protocol is truncated', f => f.protocol('{"status":"available","documents":[{"stat'), 'malformed_protocol'],
  ['the protocol is empty', f => f.protocol(''), 'empty_protocol_output'],
]) {
  test(`compaction still emits one bounded unavailable advisory when ${name}`, t => {
    const f = fixture(t);
    setup(f);
    const context = compact(f);
    assert.match(context, new RegExp(`status=unavailable reason=${reason} documents=0 foreign_records=0 checked=0 pending=0`));
  });
}

for (const [name, options] of [
  ['the sibling primitive is absent', { primitive: false }],
  ['the shared library is absent', { lib: false, primitive: false }],
]) {
  test(`compaction still emits one bounded unavailable advisory when ${name}`, t => {
    const f = fixture(t, options);
    const context = compact(f);
    assert.match(context, /status=unavailable reason=helper_unavailable documents=0 foreign_records=0 checked=0 pending=0/);
  });
}

test('a non-ASCII document path survives intact inside the UTF-8 byte bound', t => {
  const f = fixture(t);
  f.protocol(available([document('tâches/plan-é.md', 'current', [{ checked: true }, { checked: false }])]));
  const context = compact(f);
  assert.match(context, /- "tâches\/plan-é\.md": current checked=1 pending=1/);
  assert.ok(Buffer.byteLength(context, 'utf8') > context.length, 'the case must actually carry multi-byte characters');
});

test('compaction never runs post-compact-context.sh and never replays a context log or transcript', t => {
  const f = fixture(t);
  f.protocol(available([document('tasks.md', 'current', [{ checked: false }])]));
  writeFileSync(resolve(f.cwd, 'context-log.md'), 'stale context sentinel');
  const marker = resolve(f.cwd, 'post-compact-ran');
  f.hook('post-compact-context.sh', `touch ${JSON.stringify(marker)}\njq -n --rawfile history "$CODEX_PROJECT_DIR/context-log.md" '{hookSpecificOutput:{additionalContext:("WRONG portable recovery: " + $history)}}'`);
  f.hook('save-context-log.sh', `touch ${JSON.stringify(resolve(f.cwd, 'save-context-log-ran'))}`);
  f.hook('session-context.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"WRONG previous-session replay"}}'`);
  const context = compact(f);
  assert.doesNotMatch(context, /stale context sentinel|WRONG portable recovery|WRONG previous-session replay|previous session/);
  assert.equal(existsSync(marker), false, 'post-compact-context.sh must never be dispatched on pi compaction');
  assert.equal(existsSync(resolve(f.cwd, 'save-context-log-ran')), false);
});

test('the compact advisory reaches the next agent start exactly once and session start keeps its own flow', async t => {
  const f = fixture(t);
  f.protocol(available([document('tasks.md', 'current', [{ checked: true }, { checked: false }])]));
  f.hook('session-context.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"startup summary sentinel"}}'`);
  await f.handlers.get('session_start')({ reason: 'startup' }, f.ctx);
  const started = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx).message.content;
  assert.match(started, /startup summary sentinel/);
  // The task summary is a compaction branch, not a duplicate of the startup flow.
  assert.doesNotMatch(started, new RegExp(HEADER));

  await f.handlers.get('session_compact')({ reason: 'manual' }, f.ctx);
  const delivered = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx).message.content;
  bounded(delivered);
  assert.match(delivered, /- "tasks\.md": current checked=1 pending=1/);
  assert.doesNotMatch(delivered, /startup summary sentinel/);
  assert.equal(f.messages.length, 0);
  // A second start with no further compaction never re-delivers the advisory.
  assert.equal(f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx).message, undefined);
  assert.equal(f.notifications.length, 0);
});

test('repeated compaction re-reads task state without accumulating duplicate advisories', async t => {
  const f = fixture(t);
  for (const [checked, pending] of [[0, 1], [1, 0]]) {
    f.protocol(available([document('tasks.md', 'current', [{ checked: checked === 1 }])]));
    await f.handlers.get('session_compact')({ reason: 'manual' }, f.ctx);
    const delivered = f.handlers.get('before_agent_start')({ systemPrompt: 'parent' }, f.ctx).message.content;
    bounded(delivered);
    assert.match(delivered, new RegExp(`- "tasks\\.md": current checked=${checked} pending=${pending}`));
  }
});
