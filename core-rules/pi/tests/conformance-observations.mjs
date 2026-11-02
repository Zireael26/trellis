// Real extension callbacks + dispatcher with a fixture ExtensionAPI, never native-host proof.
// Invoked by scripts/harness-conformance.py under Node >=24; scratch is retained.
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, copyFileSync, unlinkSync, readFileSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { spawnSync } from 'node:child_process';
import extension from '../extensions/trellis.ts';

const [id, scratch] = process.argv.slice(2);
const cwd = resolve(scratch, id);
const observations = {}, commands = [], handlers = new Map(), messages = [], notifications = [];
for (const dir of ['.trellis/runtime/core-rules/pi/hooks', '.trellis/runtime/core-rules/hooks/lib', '.agents/rules', '.trellis/runtime/core-rules/codex/hooks']) {
  mkdirSync(resolve(cwd, dir), { recursive: true });
}
const dispatcher = resolve(cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh');
copyFileSync(new URL('../hooks/dispatch.sh', import.meta.url), dispatcher);
// Required guards run through the runtime's supervisor, beside the dispatcher.
copyFileSync(new URL('../../hooks/lib/guard-supervise.pl', import.meta.url),
  resolve(cwd, '.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl'));
writeFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), '{}');
writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Fixture inherited parent policy');
const hook = (name, body) => {
  // Only denial/advisory transport bodies are stubs. Never replace policy consumers.
  const text = `#!/bin/bash\n# Explicit conformance transport stub, not policy implementation.\n${body}\n`;
  writeFileSync(resolve(cwd, '.trellis/runtime/core-rules/codex/hooks', name), text, { mode: 0o755 });
  observations.stub_hooks = { ...observations.stub_hooks, [name]: text };
};
const envelopes = [], decisions = [];
function run(script, args, options) {
  const n = commands.length;
  const stdoutPath = relative(scratch, resolve(cwd, `dispatch-${n}.stdout`));
  const stderrPath = relative(scratch, resolve(cwd, `dispatch-${n}.stderr`));
  const result = spawnSync(process.env.CONFORMANCE_BASH, [script, ...args], {
    cwd: options.cwd, env: process.env, encoding: 'utf8', timeout: 30000,
  });
  writeFileSync(resolve(scratch, stdoutPath), result.stdout ?? '');
  writeFileSync(resolve(scratch, stderrPath), (result.stderr ?? '') + (result.error ? `\n${result.error.message}` : ''));
  commands.push({ argv: [process.env.CONFORMANCE_BASH, script, ...args], cwd: options.cwd,
    exit_code: result.status, status: result.error?.code === 'ETIMEDOUT' ? 'timeout' : result.error ? 'not_run' : 'exited',
    stdout_path: stdoutPath, stderr_path: stderrPath });
  envelopes.push(args[0] === '--event-file' ? JSON.parse(readFileSync(args[1], 'utf8')) : JSON.parse(Buffer.from(args[1], 'base64').toString()));
  if (result.error) throw result.error;
  decisions.push(JSON.parse(result.stdout));
  return { stdout: result.stdout, stderr: result.stderr, code: result.status, killed: false };
}
const pi = {
  on: (name, handler) => handlers.set(name, handler),
  getAllTools: () => [
    ...['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'].map(name => ({ name,
      sourceInfo: { path: `<builtin:${name}>`, source: 'builtin', scope: 'temporary', origin: 'top-level', baseDir: undefined } })),
    ...['Agent', 'SubagentWorkflow'].map(name => ({ name,
      sourceInfo: { path: '/fixture/pi-subagents/dist/index.js', source: 'local', scope: 'temporary', origin: 'top-level', baseDir: '/fixture/pi-subagents/dist' } })),
  ],
  sendMessage: (...args) => messages.push(args),
  exec: async (script, args, options) => run(script, args, options),
};
extension(pi);
const ctx = { cwd, signal: new AbortController().signal, ui: { notify: (...args) => notifications.push(args) },
  sessionManager: { getSessionId: () => id, getSessionFile: () => undefined } };
const fire = (name, event) => handlers.get(name)(event, ctx);
let assertion = 'pass', reason = 'Real callback/dispatcher fixture assertions passed';
try {
  switch (id) {
    case 'pi.pre-denial': {
      // Spec 072 T10: the shared destructive rules run in process; a shell call
      // reaches no dispatcher before or after it is decided.
      const rule = JSON.parse(readFileSync(new URL('../../hooks/rules/destructive.json', import.meta.url), 'utf8'))
        .rules.find(entry => entry.id === 'git-force-push');
      observations.allowed = (await fire('tool_call', { toolCallId: 'benign', toolName: 'bash', input: { command: 'pwd' } })) ?? null;
      observations.response = await fire('tool_call', { toolCallId: 'shell', toolName: 'bash', input: { command: 'git push --force origin main' } });
      assert.equal(observations.allowed, null);
      assert.equal(observations.response?.block, true);
      assert.equal(observations.response?.reason, rule.reason);
      assert.deepEqual(notifications, [[rule.reason, 'error']]);
      assert.deepEqual(envelopes, []);
      break;
    }
    case 'pi.post-advisory': {
      hook('truncation-check.sh', `printf '%s\\n' '{"hookSpecificOutput":{"additionalContext":"context sentinel"},"reason":"reason sentinel"}'\nprintf '%s\\n' 'stderr sentinel' >&2`);
      const original = [{ type: 'text', text: 'original result' }, { type: 'image', data: 'AA==', mimeType: 'image/png' }];
      observations.original = structuredClone(original);
      observations.response = await fire('tool_result', { toolCallId: 'read', toolName: 'read', input: { path: 'file' }, content: original, details: { retained: true }, isError: true });
      assert.deepEqual(observations.response.content.slice(0, 2), observations.original);
      assert.deepEqual(Object.keys(observations.response), ['content']);
      assert.equal(observations.response.content.length, 3);
      for (const sentinel of ['context sentinel', 'reason sentinel', 'stderr sentinel']) assert.ok(observations.response.content[2].text.includes(sentinel));
      assert.deepEqual(original, observations.original);
      assert.equal(decisions[0].capability_status, 'advisory');
      assert.equal(commands[0].exit_code, 0);
      break;
    }
    case 'pi.compact-missing': {
      unlinkSync(dispatcher);
      observations.dispatcher_present = false;
      observations.compact_response = (await fire('session_before_compact', { reason: 'manual', willRetry: false })) ?? null;
      observations.write_response = await fire('tool_call', { toolCallId: 'write', toolName: 'write', input: { path: 'file' } });
      assert.equal(observations.compact_response, null);
      assert.match(messages[0][0].content, /dispatcher is missing/);
      assert.equal(messages[0][1].deliverAs, 'nextTurn');
      assert.equal(observations.write_response.block, true);
      assert.match(observations.write_response.reason, /dispatcher is missing/);
      assert.equal(commands.length, 0);
      break;
    }
    case 'pi.failed-mutation': {
      // Spec 072 T10: a failed mutation is labelled unchecked in process and
      // never dispatched; only a successful one reaches the post-action hooks.
      observations.response = await fire('tool_result', { toolCallId: 'write', toolName: 'write', input: { path: 'file' }, content: [], isError: true });
      assert.deepEqual(envelopes, []);
      assert.equal(observations.response.content.length, 1);
      assert.match(observations.response.content[0].text, /^\[Trellis post-action advisory; capability: unsupported\]\n/);
      assert.match(observations.response.content[0].text, /post_action\/file_mutation: unsupported — checks skipped due to failed result/);
      assert.doesNotMatch(observations.response.content[0].text, /hook unavailable/);
      break;
    }
    case 'pi.spawner-boundary': {
      unlinkSync(resolve(cwd, '.agents/rules/trellis.md'));
      observations.tools = pi.getAllTools();
      observations.responses = {};
      for (const toolName of ['Agent', 'SubagentWorkflow', 'agent', 'custom']) {
        observations.responses[toolName] = (await fire('tool_call', { toolCallId: toolName, toolName, input: { path: 'file' } })) ?? null;
      }
      for (const name of ['Agent', 'SubagentWorkflow']) {
        assert.equal(observations.responses[name].block, true);
        assert.match(observations.responses[name].reason, /parent policy is missing/);
      }
      for (const name of ['agent', 'custom']) {
        assert.equal(observations.responses[name].block, true);
        assert.match(observations.responses[name].reason, /unmediated/);
      }
      assert.deepEqual(envelopes, []); // Unknown tools never reach a fail-open dispatcher.
      break;
    }
    case 'pi.command-discovery': {
      mkdirSync(resolve(cwd, 'nested'));
      observations.runtime_config = readFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), 'utf8');
      observations.response = await fire('resources_discover', { cwd: resolve(cwd, 'nested') });
      assert.deepEqual(observations.response, { skillPaths: [resolve(cwd, '.agents/skills')], promptPaths: [resolve(cwd, '.agents/commands')] });
      break;
    }
    default: throw new Error(`Unknown case: ${id}`);
  }
} catch (error) {
  assertion = error.code === 'ERR_ASSERTION' ? 'fail' : 'unknown';
  reason = error.message;
}
Object.assign(observations, { envelopes, decisions, messages, notifications });
console.log(JSON.stringify({ assertion, reason, observations, commands }));
process.exitCode = assertion === 'pass' ? 0 : 1;
