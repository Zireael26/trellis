import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chmodSync, existsSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { deliveredFixture } from './delivered-fixture.mjs';

const blocked = async (f, tool, input) => f.fire('tool_call', f.call(tool, input));
const read = async (f, path, failed = false) => {
  const event = f.call('read', { path });
  assert.equal(await f.fire('tool_call', event), undefined);
  await f.result(event, failed);
};

test('delivered read pre-action does not spawn; missing runtime still blocks', async t => {
  const f = await deliveredFixture(t);
  assert.equal(await blocked(f, 'read', { path: 'file' }), undefined);
  assert.equal(f.calls.length, 0);
  rmSync(resolve(f.cwd, '.trellis/runtime'));
  assert.equal((await blocked(f, 'read', { path: 'file' })).block, true);
  assert.equal(f.calls.length, 0);
});

for (const missing of ['dispatcher', 'policy']) {
  test(`missing ${missing} cannot be hidden by mutation fast path`, async t => {
    const f = await deliveredFixture(t);
    rmSync(missing === 'dispatcher' ? resolve(f.runtime, 'core-rules/pi/hooks/dispatch.sh') : resolve(f.cwd, '.agents/rules/trellis.md'));
    assert.equal((await blocked(f, 'write', { path: 'new', content: 'x' })).block, true);
    assert.equal(f.calls.length, 0);
  });
}

for (const tool of ['edit', 'write']) {
  test(`${tool} existing file warns twice then blocks before action without spawning`, async t => {
    const f = await deliveredFixture(t);
    writeFileSync(resolve(f.cwd, 'file'), 'unchanged');
    for (let i = 0; i < 2; i++) assert.equal(await blocked(f, tool, { path: 'file', content: 'x' }), undefined);
    assert.equal((await blocked(f, tool, { path: 'file', content: 'x' })).block, true);
    assert.equal(f.calls.length, 0);
  });
}

test('L5 reread budget is one; immutable preset ceiling restores L3 budget', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  writeFileSync(resolve(f.cwd, '.trellis.json'), '{"autonomy":5}');
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
  mkdirSync(resolve(f.runtime, 'core-rules/presets'), { recursive: true });
  writeFileSync(resolve(f.runtime, 'core-rules/presets/safe.md'), '---\nautonomy_ceiling: 3\n---\n');
  writeFileSync(resolve(f.cwd, '.trellis.json'), '{"autonomy":5,"presets":["safe"]}');
  f.fire('before_agent_start', { systemPrompt: 'parent' });
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
});

test('successful normalized read permits overwrite; failed reads never earn credit', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  await read(f, './nested/../file');
  for (let i = 0; i < 4; i++) assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  f.fire('before_agent_start', { systemPrompt: 'parent' });
  await read(f, 'file', true);
  for (let i = 0; i < 2; i++) assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
});

test('successful mutation earns read credit, failed mutation does not', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const first = f.call('write', { path: 'file' });
  await f.fire('tool_call', first);
  await f.result(first, true);
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
  f.fire('before_agent_start', { systemPrompt: 'parent' });
  const success = f.call('write', { path: 'file' });
  await f.fire('tool_call', success);
  await f.result(success);
  for (let i = 0; i < 3; i++) assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
});

test('create is exempt; read credit does not survive session start or change roots', async t => {
  const f = await deliveredFixture(t);
  assert.equal(await blocked(f, 'write', { path: 'new' }), undefined);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  await read(f, 'file');
  await f.fire('session_start', { reason: 'resume' });
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
});

for (const path of [undefined, '', 42, 'bad\nfile', 'bad\tfile', 'bad\0file']) {
  test(`unknown mutation target ${JSON.stringify(path)} denies before execution`, async t => {
    const f = await deliveredFixture(t);
    assert.equal((await blocked(f, 'write', { path })).block, true);
    assert.equal(f.calls.length, 0);
  });
}

test('dangling symlink and unreadable autonomy state deny, not create exemption', async t => {
  const f = await deliveredFixture(t);
  symlinkSync(resolve(f.cwd, 'absent'), resolve(f.cwd, 'link'));
  assert.equal((await blocked(f, 'write', { path: 'link' })).block, true);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  writeFileSync(resolve(f.cwd, '.trellis.json'), '{');
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
});

for (const native of ['tool_call', 'user_bash']) {
  test(`JSON destructive guard blocks ${native} before execution without a shell guard`, async t => {
    const f = await deliveredFixture(t);
    const fire = command => native === 'tool_call' ? blocked(f, 'bash', { command }) : f.fire('user_bash', { command, cwd: f.cwd, excludeFromContext: true });
    const denial = await fire('rm -rf /fixture-never-executed');
    assert.equal(native === 'tool_call' ? denial.block : denial.result.exitCode, native === 'tool_call' ? true : 1);
    assert.match(native === 'tool_call' ? denial.reason : denial.result.output, /Blocked destructive rm/);
    assert.equal(await fire('printf harmless'), undefined);
    rmSync(resolve(f.runtime, 'core-rules/codex/hooks/block-destructive.sh'));
    assert.equal(await fire('printf harmless'), undefined);
    const cached = await fire('rm -rf /fixture-never-executed');
    assert.equal(native === 'tool_call' ? cached.block : cached.result.exitCode, native === 'tool_call' ? true : 1);
    assert.equal(f.calls.length, 0);
  });
}

for (const bytes of [65536, 65537]) {
  test(`native skill read ${bytes} bytes checks budget before preload without spawn`, async t => {
    const f = await deliveredFixture(t);
    const path = f.skill('budget', bytes);
    const r = await blocked(f, 'read', { path });
    assert.equal(r?.block, bytes > 65536 ? true : undefined);
    assert.equal(f.calls.length, 0);
  });
}

for (const invalid of ['oversized', 'unreadable', 'utf8', 'ambiguous', 'missing-path']) {
  test(`slash skill ${invalid} refuses before body expansion`, async t => {
    const f = await deliveredFixture(t);
    const path = f.skill('preload', invalid === 'oversized' ? 65537 : 30);
    if (invalid === 'unreadable') rmSync(path);
    if (invalid === 'utf8') writeFileSync(path, Buffer.from([255]));
    if (invalid === 'ambiguous') {
      const other = f.skill('other');
      f.commands.push({ name: 'skill:preload', source: 'skill', sourceInfo: { path: other } });
    }
    if (invalid === 'missing-path') delete f.commands[0].sourceInfo.path;
    assert.ok(f.handlers.has('input'));
    const r = await f.fire('input', { text: '/skill:preload arguments', source: 'rpc' });
    assert.equal(r.action, 'handled');
    assert.match(f.notifications.at(-1)[0], /skill|Skill/);
    assert.equal(f.calls.length, 0);
  });
}

for (const spelling of ['at-prefix', 'tilde', 'file-url', 'unicode-space']) {
  test(`native ${spelling} path cannot disguise existing overwrite`, async t => {
    const f = await deliveredFixture(t);
    const path = resolve(f.cwd, 'some file');
    writeFileSync(path, 'x');
    const input = spelling === 'at-prefix' ? '@some file' : spelling === 'tilde' ? `~/${relative(homedir(), path)}` : spelling === 'file-url' ? pathToFileURL(path).href : 'some\u00a0file';
    assert.equal(await blocked(f, 'write', { path: input }), undefined);
    assert.equal(await blocked(f, 'write', { path: input }), undefined);
    assert.equal((await blocked(f, 'write', { path: input })).block, true);
  });
}

test('directory dispatcher is unavailable even without a spawn', async t => {
  const f = await deliveredFixture(t);
  const path = resolve(f.runtime, 'core-rules/pi/hooks/dispatch.sh');
  rmSync(path); mkdirSync(path);
  assert.equal((await blocked(f, 'read', { path: 'file' })).block, true);
});

test('nonexecutable dispatcher refuses the read fast path', async t => {
  const f = await deliveredFixture(t);
  chmodSync(resolve(f.runtime, 'core-rules/pi/hooks/dispatch.sh'), 0o644);
  assert.equal((await blocked(f, 'read', { path: 'file' })).block, true);
});

test('skill alias is checked by physical target before native read', async t => {
  const f = await deliveredFixture(t);
  const path = f.skill('oversized-alias', 65537);
  symlinkSync(path, resolve(f.cwd, 'alias.md'));
  assert.equal((await blocked(f, 'read', { path: 'alias.md' })).block, true);
});

for (const key of ['path', 'file_path', 'filePath']) {
  test(`M1 ${key} shape cannot bypass reread`, async t => {
    const f = await deliveredFixture(t);
    writeFileSync(resolve(f.cwd, 'file'), 'x');
    assert.equal(await blocked(f, 'write', { [key]: 'file' }), undefined);
    assert.equal(await blocked(f, 'write', { [key]: 'file' }), undefined);
    assert.equal((await blocked(f, 'write', { [key]: 'file' })).block, true);
  });
}

for (const toolName of ['custom', 'mcp_mutate', 'MultiEdit', 'NotebookEdit', 'apply_patch', 'rename', 'delete']) {
  test(`M2/M3 unmediated ${toolName} refuses pre-action`, async t => {
    const f = await deliveredFixture(t);
    f.pi.getAllTools = () => [{ name: toolName, annotations: { readOnlyHint: true }, sourceInfo: { source: toolName.startsWith('mcp') ? 'mcp' : 'local' } }];
    assert.equal((await blocked(f, toolName, { path: 'file' })).block, true);
    assert.equal(f.calls.length, 0);
  });
}

for (const toolName of ['grep', 'find', 'ls']) {
  test(`M2 pure builtin ${toolName} allows, local name collision refuses`, async t => {
    const f = await deliveredFixture(t);
    assert.equal(await blocked(f, toolName, { path: '.' }), undefined);
    f.pi.getAllTools = () => [{ name: toolName, sourceInfo: { source: 'local' } }];
    assert.equal((await blocked(f, toolName, { path: '.' })).block, true);
  });
}

function subagentControlSource(f) {
  const root = resolve(f.base, 'node_modules/@tintinweb/pi-subagents');
  const path = resolve(root, 'src/index.ts');
  mkdirSync(resolve(root, 'src'), { recursive: true });
  writeFileSync(resolve(root, 'package.json'), JSON.stringify({ name: '@tintinweb/pi-subagents', version: '0.22.0' }));
  writeFileSync(path, 'fixture extension');
  return { path, source: 'npm:@tintinweb/pi-subagents@0.22.0', origin: 'package', scope: 'user' };
}

for (const toolName of ['get_subagent_result', 'steer_subagent']) {
  for (const source of ['npm:@tintinweb/pi-subagents', 'npm:@tintinweb/pi-subagents@0.22.0']) {
    test(`subagent control ${toolName} permits verified package source ${source}`, async t => {
      const f = await deliveredFixture(t), sourceInfo = { ...subagentControlSource(f), source };
      f.pi.getAllTools = () => [{ name: toolName, sourceInfo }];
      assert.equal(await blocked(f, toolName, { agent_id: 'fixture', message: 'guidance' }), undefined);
      await f.result(f.call(toolName, { agent_id: 'fixture' }));
      assert.equal(f.calls.length, 0, 'unhandled control pre/post never dispatch');
    });
  }
  for (const invalid of ['foreign-source', 'prefix-collision', 'alias-spec', 'npm-alias', 'top-level', 'wrong-package', 'missing-path', 'symlink-escape', 'nested-package']) {
    test(`subagent control ${toolName} refuses ${invalid} provenance`, async t => {
      const f = await deliveredFixture(t), sourceInfo = subagentControlSource(f);
      const root = resolve(sourceInfo.path, '../..');
      if (invalid === 'foreign-source') sourceInfo.source = 'npm:other-extension';
      if (invalid === 'prefix-collision') sourceInfo.source = 'npm:@tintinweb/pi-subagents-impostor';
      if (invalid === 'alias-spec') sourceInfo.source = 'npm:@tintinweb/pi-subagents@file:evil.tgz';
      if (invalid === 'npm-alias') sourceInfo.source = 'npm:@tintinweb/pi-subagents@npm:evil-pkg@1.0.0';
      if (invalid === 'top-level') sourceInfo.origin = 'top-level';
      if (invalid === 'wrong-package') writeFileSync(resolve(root, 'package.json'), '{"name":"other-extension"}');
      if (invalid === 'missing-path') sourceInfo.path += '.missing';
      if (invalid === 'symlink-escape' || invalid === 'nested-package') {
        const foreign = resolve(invalid === 'nested-package' ? root : f.base, 'foreign');
        mkdirSync(foreign, { recursive: true });
        writeFileSync(resolve(foreign, 'package.json'), '{"name":"other-extension"}');
        writeFileSync(resolve(foreign, 'index.ts'), 'foreign extension');
        if (invalid === 'nested-package') sourceInfo.path = resolve(foreign, 'index.ts');
        else { rmSync(sourceInfo.path); symlinkSync(resolve(foreign, 'index.ts'), sourceInfo.path); }
      }
      f.pi.getAllTools = () => [{ name: toolName, sourceInfo, annotations: { readOnlyHint: true } }];
      assert.equal((await blocked(f, toolName, {})).block, true);
      assert.equal(f.calls.length, 0);
    });
  }
  test(`subagent control ${toolName} resolves a legitimate linked entry`, async t => {
    const f = await deliveredFixture(t), sourceInfo = subagentControlSource(f);
    const alias = resolve(f.base, 'linked-extension.ts');
    symlinkSync(sourceInfo.path, alias);
    f.pi.getAllTools = () => [{ name: toolName, sourceInfo: { ...sourceInfo, path: alias } }];
    assert.equal(await blocked(f, toolName, {}), undefined);
  });
}

for (const toolName of ['shell_mutator', 'delete', 'list_agents']) {
  test(`subagent package provenance does not authorize unclassified ${toolName}`, async t => {
    const f = await deliveredFixture(t), sourceInfo = subagentControlSource(f);
    f.pi.getAllTools = () => [{ name: toolName, sourceInfo }];
    assert.equal((await blocked(f, toolName, { command: 'rm -rf fixture' })).block, true);
    assert.equal(f.calls.length, 0);
  });
}
for (const toolName of ['Agent', 'SubagentWorkflow']) {
  test(`subagent control fix preserves existing ${toolName} delegation behavior`, async t => {
    const f = await deliveredFixture(t);
    f.pi.getAllTools = () => [{ name: toolName, sourceInfo: { source: 'local' } }];
    assert.equal(await blocked(f, toolName, {}), undefined);
  });
}

for (const toolName of ['Agent', 'SubagentWorkflow', 'steer_subagent']) {
  test(`subagent policy gate blocks ${toolName} without parent policy`, async t => {
    const f = await deliveredFixture(t), sourceInfo = subagentControlSource(f);
    f.pi.getAllTools = () => [{ name: toolName, sourceInfo }];
    rmSync(resolve(f.cwd, '.agents/rules/trellis.md'));
    assert.equal((await blocked(f, toolName, {})).block, true);
    assert.equal(f.calls.length, 0);
    const start = f.fire('before_agent_start', { systemPrompt: 'parent' });
    assert.match(start.message.content, /Agent, SubagentWorkflow, and steer_subagent tools are blocked/);
  });
}
test('subagent policy gate preserves result retrieval without parent policy', async t => {
  const f = await deliveredFixture(t), sourceInfo = subagentControlSource(f);
  f.pi.getAllTools = () => [{ name: 'get_subagent_result', sourceInfo }];
  rmSync(resolve(f.cwd, '.agents/rules/trellis.md'));
  assert.equal(await blocked(f, 'get_subagent_result', {}), undefined);
  assert.equal(f.calls.length, 0);
});

for (const input of [
  { path: 'file', filePath: 'other' },
  { path: 'file', targets: [{ path: 'file' }, { path: 'other' }] },
  { path: 'file', edits: [{ path: 'other', oldText: 'x', newText: 'y' }] },
  { path: 'file', destination: 'other' },
]) {
  test(`M3 incomplete mutation ${JSON.stringify(input)} refuses`, async t => {
    const f = await deliveredFixture(t);
    assert.equal((await blocked(f, 'edit', input)).block, true);
    assert.equal(f.calls.length, 0);
  });
}

test('M3 native edits within one declared target remain supported', async t => {
  const f = await deliveredFixture(t);
  assert.equal(await blocked(f, 'edit', { path: 'new', edits: [{ oldText: 'x', newText: 'y' }, { oldText: 'a', newText: 'b' }] }), undefined);
});

test('M4 PowerShell verbs refuse instead of passing a POSIX guard', async t => {
  const f = await deliveredFixture(t);
  assert.equal((await blocked(f, 'powershell', { command: 'Remove-Item -Recurse -Force C:\\fixture' })).block, true);
  assert.equal(f.calls.length, 0);
});

for (const details of [{ error: 'failed' }, { is_error: true }, { isError: true }, { tool_use_error: 'failed' }]) {
  test(`M6 explicit result error ${JSON.stringify(details)} earns no read credit`, async t => {
    const f = await deliveredFixture(t);
    writeFileSync(resolve(f.cwd, 'file'), 'x');
    const event = f.call('edit', { path: 'file' });
    await f.fire('tool_call', event);
    await f.fire('tool_result', { ...event, isError: false, details, content: [] });
    assert.equal(await blocked(f, 'edit', { path: 'file' }), undefined);
    assert.equal((await blocked(f, 'edit', { path: 'file' })).block, true);
  });
}

test('M6 string failure gives no credit; object code containing error text is successful', async t => {
  const f = await deliveredFixture(t);
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  const event = f.call('edit', { path: 'file' });
  await f.fire('tool_call', event);
  await f.fire('tool_result', { ...event, isError: false, content: [{ type: 'text', text: 'Error: String to replace not found' }] });
  assert.equal(await blocked(f, 'edit', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'edit', { path: 'file' })).block, true);
  f.fire('before_agent_start', { systemPrompt: 'parent' });
  const success = f.call('edit', { path: 'file' });
  await f.fire('tool_call', success);
  await f.fire('tool_result', { ...success, isError: false, details: { originalFile: 'Error: ENOENT not found' }, content: [] });
  for (let i = 0; i < 3; i++) assert.equal(await blocked(f, 'edit', { path: 'file' }), undefined);
});

test('M6 ambient reread override cannot bypass in-process block', async t => {
  const f = await deliveredFixture(t);
  const previous = process.env.TRELLIS_REREAD_OVERRIDE;
  process.env.TRELLIS_REREAD_OVERRIDE = '1';
  t.after(() => { if (previous === undefined) delete process.env.TRELLIS_REREAD_OVERRIDE; else process.env.TRELLIS_REREAD_OVERRIDE = previous; });
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
});

for (const [name, runtime, canonical, legacy, session, budget] of [
  ['runtime default', { autonomy_default: 4 }, {}, {}, undefined, 1],
  ['canonical beats legacy', {}, { autonomy: 5 }, { autonomy: 1 }, undefined, 1],
  ['legacy absent-field fallback', {}, {}, { autonomy: 4 }, undefined, 1],
  ['invalid canonical suppresses legacy', { autonomy_default: 2 }, { autonomy: 'invalid' }, { autonomy: 5 }, undefined, 2],
  ['session override', {}, { autonomy: 5 }, {}, '1', 2],
  ['quoted numeric parity', {}, { autonomy: '5' }, {}, undefined, 1],
  ['invalid session does not lower L5', {}, { autonomy: 5 }, {}, '01', 1],
]) {
  test(`M6 autonomy precedence ${name}`, async t => {
    const f = await deliveredFixture(t);
    writeFileSync(resolve(f.runtime, 'trellis.config.json'), JSON.stringify(runtime));
    writeFileSync(resolve(f.cwd, '.trellis.json'), JSON.stringify(canonical));
    writeFileSync(resolve(f.cwd, '.trellis.config.json'), JSON.stringify(legacy));
    if (session) { mkdirSync(resolve(f.cwd, '.claude')); writeFileSync(resolve(f.cwd, '.claude/session-autonomy'), session); }
    writeFileSync(resolve(f.cwd, 'file'), 'x');
    for (let i = 0; i < budget; i++) assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
    assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
  });
}

test('M6 malformed preset ceiling cannot silently lower the L5 warn budget', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.runtime, 'core-rules/presets'), { recursive: true });
  writeFileSync(resolve(f.runtime, 'core-rules/presets/invalid.md'), '---\nautonomy_ceiling: 01\n---\n');
  writeFileSync(resolve(f.cwd, '.trellis.json'), '{"autonomy":5,"presets":["invalid"]}');
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
});

for (const [name, raw, runtime, budget] of [
  ['decimal token is invalid', '{"autonomy":3.0}', '{"autonomy_default":5}', 1],
  ['trailing string newline matches shell', '{"autonomy":"5\\n"}', '{}', 1],
]) {
  test(`R2 F2 ${name}`, async t => {
    const f = await deliveredFixture(t);
    writeFileSync(resolve(f.runtime, 'trellis.config.json'), runtime);
    writeFileSync(resolve(f.cwd, '.trellis.json'), raw);
    writeFileSync(resolve(f.cwd, 'file'), 'x');
    for (let i = 0; i < budget; i++) assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
    assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
  });
}

test('R2 F2 CRLF preset fields and POSIX session whitespace preserve shell parity', async t => {
  const f = await deliveredFixture(t);
  mkdirSync(resolve(f.runtime, 'core-rules/presets'), { recursive: true });
  writeFileSync(resolve(f.runtime, 'core-rules/presets/strict.md'), '---\r\nautonomy_default: 5\r\n---\r\n');
  writeFileSync(resolve(f.cwd, '.trellis.json'), '{"presets":["strict"]}');
  mkdirSync(resolve(f.cwd, '.claude'));
  writeFileSync(resolve(f.cwd, '.claude/session-autonomy'), '\u00a01');
  writeFileSync(resolve(f.cwd, 'file'), 'x');
  assert.equal(await blocked(f, 'write', { path: 'file' }), undefined);
  assert.equal((await blocked(f, 'write', { path: 'file' })).block, true);
});

for (const kind of ['session', 'project']) {
  test(`R2 F1 linked worktree uses canonical ${kind} autonomy`, async t => {
    const f = await deliveredFixture(t);
    const main = resolve(f.base, 'main'), work = resolve(f.base, 'work');
    mkdirSync(main);
    const git = (args, input) => {
      const r = spawnSync('git', args, { cwd: main, input, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: f.cwd,
        GIT_AUTHOR_NAME: 'fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_NAME: 'fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' } });
      assert.equal(r.status, 0, r.stderr); return r.stdout.trim();
    };
    git(['init', '-q']);
    const blob = git(['hash-object', '-w', '--stdin'], 'fixture');
    const tree = git(['mktree'], `100644 blob ${blob}\tfile\n`);
    const head = git(['commit-tree', tree], 'fixture root');
    git(['worktree', 'add', '--detach', '--no-checkout', work, head]);
    mkdirSync(resolve(work, '.trellis'));
    symlinkSync(f.runtime, resolve(work, '.trellis/runtime'));
    mkdirSync(resolve(work, '.agents/rules'), { recursive: true });
    writeFileSync(resolve(work, '.agents/rules/trellis.md'), 'fixture worktree policy');
    writeFileSync(resolve(work, '.trellis.json'), '{"autonomy":1}');
    if (kind === 'project') writeFileSync(resolve(main, '.trellis.json'), '{"autonomy":5}');
    else { mkdirSync(resolve(main, '.claude')); writeFileSync(resolve(main, '.claude/session-autonomy'), '5'); }
    writeFileSync(resolve(work, 'file'), 'x');
    const ctx = { ...f.ctx, cwd: work };
    assert.equal(await f.fire('tool_call', f.call('write', { path: 'file' }), ctx), undefined);
    assert.equal((await f.fire('tool_call', f.call('write', { path: 'file' }), ctx)).block, true);
  });
}

test('R2 F3 case-variant manifest cannot hide preload budget on case-insensitive volumes', async t => {
  const f = await deliveredFixture(t);
  const path = f.skill('case-alias', 65537);
  const lower = path.replace(/SKILL\.md$/, 'skill.md');
  if (!existsSync(lower)) { t.skip('case-sensitive volume; native casing alias does not resolve'); return; }
  assert.equal((await blocked(f, 'read', { path: lower })).block, true);
});

test('M7 shell writes remain explicitly outside structured reread scope', async t => {
  const f = await deliveredFixture(t);
  // This is only a guard query; the shell command is NEVER executed.
  assert.equal(await blocked(f, 'bash', { command: 'printf x > file' }), undefined);
  assert.equal(f.calls.length, 0);
});

test('safe slash skill and duplicate physical aliases allow; runtime rechecks changed manifest', async t => {
  const f = await deliveredFixture(t);
  const path = f.skill('safe', 65536);
  assert.ok(f.handlers.has('input'));
  assert.equal(await f.fire('input', { text: '/skill:safe', source: 'interactive' }), undefined);
  const alias = resolve(f.cwd, 'alias.md');
  symlinkSync(path, alias);
  f.commands.push({ name: 'skill:safe', source: 'skill', sourceInfo: { path: alias } });
  assert.equal(await f.fire('input', { text: '/skill:safe', source: 'rpc' }), undefined);
  writeFileSync(path, 'x'.repeat(65537));
  assert.equal((await f.fire('input', { text: '/skill:safe', source: 'rpc' })).action, 'handled');
});

test('session start runs the payload hook set and nothing exists under the reserved .pi/hooks', async t => {
  const f = await deliveredFixture(t);
  const startup = () => {
    const event = { schema_version: 1, harness: 'pi', cwd: f.cwd, session_id: 'fixture-session', phase: 'lifecycle', native_event: 'session_start', reason: 'startup' };
    const r = spawnSync('bash', [resolve(f.cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh'), '--base64', Buffer.from(JSON.stringify(event)).toString('base64')],
      { cwd: f.cwd, encoding: 'utf8', timeout: 30_000, env: { PATH: process.env.PATH, HOME: f.cwd, TMPDIR: resolve(f.cwd, 'tmp') } });
    assert.equal(r.error, undefined);
    return JSON.parse(r.stdout).reason ?? '';
  };
  assert.equal(existsSync(resolve(f.cwd, '.pi/hooks')), false);
  const ran = startup();
  assert.doesNotMatch(ran, /session-context\.sh: unknown/);
  assert.doesNotMatch(ran, /inject-primer-index\.sh: unknown/);
  // The hook resolves from the runtime payload: without it there, it is unavailable.
  rmSync(resolve(f.runtime, 'core-rules/codex/hooks/session-context.sh'));
  assert.match(startup(), /session-context\.sh: unknown — hook unavailable/);
});
