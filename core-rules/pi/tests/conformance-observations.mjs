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
for (const dir of ['.trellis/runtime/core-rules/pi/hooks', '.agents/rules', '.pi/hooks']) {
  mkdirSync(resolve(cwd, dir), { recursive: true });
}
const dispatcher = resolve(cwd, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh');
copyFileSync(new URL('../hooks/dispatch.sh', import.meta.url), dispatcher);
writeFileSync(resolve(cwd, '.trellis/runtime/trellis.config.json'), '{}');
writeFileSync(resolve(cwd, '.agents/rules/trellis.md'), 'Fixture inherited parent policy');
const hook = (name, body) => {
  // Only denial/advisory transport bodies are stubs. Never replace policy consumers.
  const text = `#!/bin/bash\n# Explicit conformance transport stub, not policy implementation.\n${body}\n`;
  writeFileSync(resolve(cwd, '.pi/hooks', name), text, { mode: 0o755 });
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
  envelopes.push(JSON.parse(Buffer.from(args[1], 'base64').toString()));
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
      hook('block-destructive.sh', `printf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"fixture deny sentinel"}}'`);
      observations.response = await fire('tool_call', { toolCallId: 'shell', toolName: 'bash', input: { command: 'pwd' } });
      assert.equal(observations.response.block, true);
      assert.equal(observations.response.reason, decisions[0].reason);
      assert.equal(decisions[0].reason, 'block-destructive.sh: fixture deny sentinel');
      assert.equal(decisions[0].decision, 'deny');
      assert.equal(commands[0].exit_code, 1);
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
      observations.response = await fire('tool_result', { toolCallId: 'write', toolName: 'write', input: { path: 'file' }, content: [], isError: true });
      assert.equal(envelopes[0].result.status, 'failed');
      assert.equal(envelopes[0].action.family, 'file_mutation');
      assert.equal(decisions[0].capability_status, 'unsupported');
      assert.match(decisions[0].reason, /checks skipped due to failed result/);
      assert.doesNotMatch(decisions[0].reason, /hook unavailable/);
      assert.equal(commands[0].exit_code, 0);
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
      assert.equal(observations.responses.agent, null);
      assert.equal(observations.responses.custom, null);
      assert.deepEqual(envelopes.map(e => e.action.tool_name), ['agent', 'custom']);
      for (const e of envelopes) {
        assert.equal(e.action.family, 'unknown');
        assert.equal(e.action.target_coverage, 'none');
        assert.deepEqual(e.action.targets, []);
      }
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
