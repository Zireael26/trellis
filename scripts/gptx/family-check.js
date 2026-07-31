#!/usr/bin/env node
'use strict';

// family-check.js — does the model an Agent actually got match the family its name promises?
//
// The delegation guard (PreToolUse) can only check the REQUEST. When an Agent is chosen by
// `subagent_type` with no explicit model, `classifyAgentRequest` returns
// `resolved_model: null` — the harness has not resolved the profile's model yet. So the
// guard authorizes a provider it never sees confirmed.
//
// The 2026-07-31 audit found that gap is load-bearing in one direction only. Every one of
// 35 `gpt-*` resolutions ran a GPT model — the gpt names are honest. But 13 CLAUDE-named
// agents resolved to `gpt-5.6-sol`, in every case under a GPT caller: `claude` x7,
// `opus-advisor` x2, `general-purpose` x2, `Explore` x1, `feature-dev:code-reviewer` x1.
// `opus-advisor` was right 109 of 111 times, so this is intermittent, not structural —
// which is exactly why it survived: nothing ever said the word "mismatch" out loud.
//
// That failure is silent and it defeats a doctrine gate. A GPT worker consulting
// `opus-advisor` believes it is getting a cross-family reviewer; when the resolution
// degrades it gets Sol reviewing Sol, and the transcript still reads "opus-advisor".
//
// Two surfaces, ONE predicate, so they cannot disagree:
//   - PostToolUse hook: fires the moment a mismatched Agent returns.
//   - `--scan`: sweeps existing transcripts, which is the only surface that can see
//     sessions already running (a live session's hooks are fixed in its launch settings).
//
// Post-hoc by construction. The work is already done by the time the model is known, so
// this reports; it cannot prevent. Naming the miss is the whole point.

const fs = require('fs');
const path = require('path');
const { AGENT_TYPE_PROVIDERS, classifyModel } = require('./session-policy');

const normalizeLower = (value) => String(value ?? '').normalize('NFKC').trim().toLowerCase();

/**
 * `explicitModel` is the caller's `Agent(model: ...)` override, when there was one. A
 * Claude-typed agent deliberately run on Terra is a legitimate call — the delegation
 * guard already classifies it `explicit-model` and authorizes the provider up front —
 * so it is not a mismatch and must not be reported as one. Only the hook can know this;
 * see the note on `scan`.
 *
 * @param {{agentType: unknown, resolvedModel: unknown, explicitModel?: unknown}} outcome
 * @returns {{status:'ok'|'mismatch'|'unknown-type'|'unknown-model'|'explicit-override'|'skip',
 *            agentType:string|null, expected:string|null, actual:string|null,
 *            resolvedModel:string|null}}
 */
const checkAgentOutcome = ({ agentType, resolvedModel, explicitModel } = {}) => {
  const type = normalizeLower(agentType);
  const model = String(resolvedModel ?? '').normalize('NFKC').trim();
  const override = normalizeLower(explicitModel);
  const base = { agentType: type || null, resolvedModel: model || null };

  if (!type || !model) return { ...base, status: 'skip', expected: null, actual: null };

  if (override && override !== 'inherit') {
    return { ...base, status: 'explicit-override', expected: null, actual: null };
  }

  if (!Object.hasOwn(AGENT_TYPE_PROVIDERS, type)) {
    // An unregistered type has no declared family, so there is nothing to contradict.
    // Reported rather than swallowed: a gpt-named type missing from the table is how a
    // real mismatch would hide, and adding the entry is the fix.
    return { ...base, status: 'unknown-type', expected: null, actual: null };
  }

  const expected = AGENT_TYPE_PROVIDERS[type];
  const actual = classifyModel(model).provider;
  if (actual === 'unknown') return { ...base, status: 'unknown-model', expected, actual: null };
  if (actual === expected) return { ...base, status: 'ok', expected, actual };
  return { ...base, status: 'mismatch', expected, actual };
};

const mismatchMessage = (result) => [
  `Agent family mismatch: '${result.agentType}' is declared ${result.expected}`,
  `but resolved to '${result.resolvedModel}' (${result.actual}).`,
  result.expected === 'claude' && result.actual === 'gpt'
    ? 'A Claude-named agent ran on GPT. If this agent was consulted as an independent or '
      + 'cross-family reviewer for GPT work, that review was same-family and does not count '
      + '— re-run it on a Claude model before relying on the verdict.'
    : 'Re-run the unit on the declared family before relying on its output.',
].join(' ');

// --- PostToolUse -------------------------------------------------------------------
// Never throws, never blocks, exits 0 on every path. This runs after every Agent call in
// every session that installs it; a crash here would be a worse bug than the one it finds.

const outcomeFromHookInput = (hookInput) => {
  const response = hookInput?.tool_response ?? hookInput?.tool_result ?? {};
  const payload = typeof response === 'object' && response !== null ? response : {};
  const input = typeof hookInput?.tool_input === 'object' && hookInput.tool_input !== null
    ? hookInput.tool_input
    : {};
  return {
    agentType: payload.agentType,
    resolvedModel: payload.resolvedModel,
    explicitModel: input.model,
  };
};

const hookPayload = (result) => ({
  systemMessage: mismatchMessage(result),
  hookSpecificOutput: {
    hookEventName: 'PostToolUse',
    additionalContext: mismatchMessage(result),
  },
});

const runHook = (raw) => {
  let hookInput;
  try {
    hookInput = JSON.parse(raw);
  } catch {
    return null; // Unparseable input is the harness's problem, not a family mismatch.
  }
  if (hookInput?.tool_name !== 'Agent') return null;
  const result = checkAgentOutcome(outcomeFromHookInput(hookInput));
  return result.status === 'mismatch' ? hookPayload(result) : null;
};

// --- scan --------------------------------------------------------------------------

const outcomesFromTranscript = (file) => {
  const outcomes = [];
  let contents;
  try {
    contents = fs.readFileSync(file, 'utf8');
  } catch {
    return outcomes;
  }
  for (const line of contents.split('\n')) {
    if (!line || !line.includes('"agentType"')) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue; // A truncated tail line in a transcript still being written.
    }
    const payload = entry?.toolUseResult;
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) continue;
    if (payload.agentType == null) continue;
    outcomes.push({
      agentType: payload.agentType,
      resolvedModel: payload.resolvedModel,
      agentId: payload.agentId ?? null,
      file,
    });
  }
  return outcomes;
};

const transcriptFiles = (root) => {
  const found = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) found.push(full);
    }
  };
  walk(root);
  return found;
};

// `toolUseResult` records what the agent RESOLVED to, never whether the caller asked for
// it, so scan cannot suppress a deliberate `Agent(model: ...)` override the way the hook
// can. It over-reports rather than under-reports, and says so in its summary. Checked
// against this fleet on 2026-07-31: every flagged call had `model: NONE`, so nothing in
// the current corpus is an override. Confirm a hit against the caller before acting on it.
const scan = (root) => {
  const seen = new Set();
  const mismatches = [];
  let checked = 0;
  for (const file of transcriptFiles(root)) {
    for (const outcome of outcomesFromTranscript(file)) {
      const result = checkAgentOutcome(outcome);
      if (result.status === 'skip') continue;
      checked += 1;
      if (result.status !== 'mismatch') continue;
      // Transcripts replay the same toolUseResult across resumes; count agents, not lines.
      const key = outcome.agentId ?? `${result.agentType}:${result.resolvedModel}:${outcome.file}`;
      if (seen.has(key)) continue;
      seen.add(key);
      mismatches.push({ ...result, agentId: outcome.agentId, file: outcome.file });
    }
  }
  return { checked, mismatches };
};

const main = (argv) => {
  const scanIndex = argv.indexOf('--scan');
  if (scanIndex === -1) {
    const payload = runHook(fs.readFileSync(0, 'utf8'));
    if (payload) process.stdout.write(`${JSON.stringify(payload)}\n`);
    return;
  }

  const root = argv[scanIndex + 1] || path.join(process.env.HOME || '', '.claude/projects');
  const { checked, mismatches } = scan(root);
  for (const item of mismatches) {
    process.stdout.write(`${mismatchMessage(item)} [${item.agentId ?? 'unknown'}] ${item.file}\n`);
  }
  process.stdout.write(
    `family-check: ${checked} agent results, ${mismatches.length} mismatched`
    + ' (a deliberate Agent(model:) override is indistinguishable here and would also'
    + ' appear as a mismatch — confirm against the caller)\n',
  );
  // Exit 1 on any mismatch so a scheduled scan is loud instead of merely informative.
  if (mismatches.length > 0) process.exitCode = 1;
};

if (require.main === module) main(process.argv.slice(2));

module.exports = {
  checkAgentOutcome,
  mismatchMessage,
  outcomeFromHookInput,
  runHook,
  outcomesFromTranscript,
  scan,
};
