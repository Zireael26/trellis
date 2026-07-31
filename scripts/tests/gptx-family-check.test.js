#!/usr/bin/env node
'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const {
  checkAgentOutcome,
  outcomeFromHookInput,
  runHook,
  outcomesFromTranscript,
  scan,
} = require('../gptx/family-check');
const { AGENT_TYPE_PROVIDERS } = require('../gptx/session-policy');

const ROOT = path.resolve(__dirname, '..', '..');
const CHECK = path.join(ROOT, 'scripts', 'gptx', 'family-check.js');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'gptx-family-check-'));

// --- the predicate -----------------------------------------------------------------

// The regression this file exists for: 2026-07-31, opus-advisor resolving to Sol.
assert.equal(
  checkAgentOutcome({ agentType: 'opus-advisor', resolvedModel: 'gpt-5.6-sol' }).status,
  'mismatch',
);
assert.equal(
  checkAgentOutcome({ agentType: 'opus-advisor', resolvedModel: 'claude-opus-5[1m]' }).status,
  'ok',
);

// Every declared Claude type must trip on a GPT model, and vice versa. Asserted over the
// real table rather than a sample, so a type added later is covered without a test edit.
for (const [type, expected] of Object.entries(AGENT_TYPE_PROVIDERS)) {
  const claudeResult = checkAgentOutcome({ agentType: type, resolvedModel: 'claude-opus-5' });
  const gptResult = checkAgentOutcome({ agentType: type, resolvedModel: 'gpt-5.6-sol' });
  assert.equal(claudeResult.status, expected === 'claude' ? 'ok' : 'mismatch', type);
  assert.equal(gptResult.status, expected === 'gpt' ? 'ok' : 'mismatch', type);
}

// The agent this change adds is registered; without the entry the guard would classify it
// 'unknown' and --delegates claude would reject the top-rung Claude reviewer.
assert.equal(AGENT_TYPE_PROVIDERS['fable-advisor'], 'claude');
assert.equal(
  checkAgentOutcome({ agentType: 'fable-advisor', resolvedModel: 'claude-fable-5' }).status,
  'ok',
);
assert.equal(
  checkAgentOutcome({ agentType: 'fable-advisor', resolvedModel: 'gpt-5.6-sol' }).status,
  'mismatch',
);

// Effort-suffixed aliases are what actually appear in transcripts; they must classify.
for (const model of ['gpt-5.6-sol-high', 'gpt-5.6-sol-xhigh', 'gpt-5.6-terra-xhigh']) {
  assert.equal(checkAgentOutcome({ agentType: 'claude', resolvedModel: model }).status, 'mismatch');
}

// Case and unicode folding: 'Explore' is how the harness writes it, 'explore' is the key.
assert.equal(
  checkAgentOutcome({ agentType: 'Explore', resolvedModel: 'gpt-5.6-sol' }).status,
  'mismatch',
);

// Non-answers stay non-answers. An unregistered type has no declared family to contradict.
assert.equal(checkAgentOutcome({}).status, 'skip');
assert.equal(checkAgentOutcome({ agentType: 'claude' }).status, 'skip');
assert.equal(
  checkAgentOutcome({ agentType: 'not-a-real-agent', resolvedModel: 'gpt-5.6-sol' }).status,
  'unknown-type',
);
assert.equal(
  checkAgentOutcome({ agentType: 'claude', resolvedModel: 'something-else' }).status,
  'unknown-model',
);

// A deliberate override is a legitimate call, not a leak. This is the false positive that
// would make the hook noise, so it is asserted rather than assumed.
assert.equal(
  checkAgentOutcome({
    agentType: 'general-purpose', resolvedModel: 'gpt-5.6-terra-xhigh', explicitModel: 'terra',
  }).status,
  'explicit-override',
);
assert.equal(
  checkAgentOutcome({
    agentType: 'opus-advisor', resolvedModel: 'gpt-5.6-sol', explicitModel: 'inherit',
  }).status,
  'mismatch',
);

// --- the hook ----------------------------------------------------------------------

assert.equal(runHook('not json'), null);
assert.equal(runHook(JSON.stringify({ tool_name: 'Bash' })), null);
assert.equal(runHook(JSON.stringify({ tool_name: 'Agent', tool_response: {} })), null);
assert.equal(
  runHook(JSON.stringify({
    tool_name: 'Agent',
    tool_response: { agentType: 'gpt-sol', resolvedModel: 'gpt-5.6-sol' },
  })),
  null,
);

const fired = runHook(JSON.stringify({
  tool_name: 'Agent',
  tool_input: { subagent_type: 'opus-advisor' },
  tool_response: { agentType: 'opus-advisor', resolvedModel: 'gpt-5.6-sol' },
}));
assert.ok(fired, 'a mismatched Agent result must produce hook output');
assert.match(fired.systemMessage, /opus-advisor/);
assert.match(fired.systemMessage, /same-family and does not count/);
assert.equal(fired.hookSpecificOutput.hookEventName, 'PostToolUse');

// Overrides reach the predicate through the hook's own extraction, not just directly.
assert.equal(
  outcomeFromHookInput({ tool_input: { model: 'terra' }, tool_response: { agentType: 'claude', resolvedModel: 'gpt-5.6-terra' } }).explicitModel,
  'terra',
);
assert.equal(
  runHook(JSON.stringify({
    tool_name: 'Agent',
    tool_input: { subagent_type: 'general-purpose', model: 'terra' },
    tool_response: { agentType: 'general-purpose', resolvedModel: 'gpt-5.6-terra-xhigh' },
  })),
  null,
);

// The hook runs after every Agent call in every installed session. It must never exit
// non-zero and never write anything on the clean path — a crash here is worse than the
// bug it reports.
for (const stdin of ['', 'garbage', '{"tool_name":"Agent"}', '{"tool_name":"Agent","tool_response":null}']) {
  const out = execFileSync('node', [CHECK], { input: stdin, encoding: 'utf8' });
  assert.equal(out, '', `hook must stay silent on: ${stdin}`);
}

// --- scan --------------------------------------------------------------------------

const transcript = path.join(temporary, 'session.jsonl');
const entry = (toolUseResult) => JSON.stringify({ type: 'user', toolUseResult });
fs.writeFileSync(transcript, [
  entry({ agentType: 'gpt-sol', resolvedModel: 'gpt-5.6-sol', agentId: 'a1' }),
  entry({ agentType: 'opus-advisor', resolvedModel: 'claude-opus-5[1m]', agentId: 'a2' }),
  entry({ agentType: 'opus-advisor', resolvedModel: 'gpt-5.6-sol', agentId: 'a3' }),
  // Same agent replayed across a resume — counted once, not three times.
  entry({ agentType: 'opus-advisor', resolvedModel: 'gpt-5.6-sol', agentId: 'a3' }),
  entry({ agentType: 'opus-advisor', resolvedModel: 'gpt-5.6-sol', agentId: 'a3' }),
  '{"type":"user"}',
  '{ truncated line still being written',
  '',
].join('\n'));

assert.equal(outcomesFromTranscript(transcript).length, 5);
assert.deepEqual(outcomesFromTranscript(path.join(temporary, 'missing.jsonl')), []);

const result = scan(temporary);
assert.equal(result.checked, 5);
assert.equal(result.mismatches.length, 1, 'replayed records must dedupe by agentId');
assert.equal(result.mismatches[0].agentId, 'a3');

// A clean tree exits 0; a dirty one exits 1 so a scheduled scan is loud, not informative.
const clean = fs.mkdtempSync(path.join(os.tmpdir(), 'gptx-family-check-clean-'));
fs.writeFileSync(path.join(clean, 's.jsonl'), entry({ agentType: 'gpt-sol', resolvedModel: 'gpt-5.6-sol', agentId: 'b1' }));
execFileSync('node', [CHECK, '--scan', clean], { encoding: 'utf8' });
assert.throws(
  () => execFileSync('node', [CHECK, '--scan', temporary], { encoding: 'utf8', stdio: 'pipe' }),
  (error) => error.status === 1,
  '--scan must exit 1 when a mismatch is present',
);

fs.rmSync(temporary, { recursive: true, force: true });
fs.rmSync(clean, { recursive: true, force: true });

console.log(
  `gptx-family-check: ok (agent types=${Object.keys(AGENT_TYPE_PROVIDERS).length}, `
  + 'hook cases=9, scan cases=6)',
);
