#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const mode = process.env.FAKE_MODE ?? 'background-then-complete';
const stateFile = process.env.FAKE_STATE_FILE;
const supportedModes = new Set([
  'background-then-complete',
  'stall-once',
  'stall-twice',
  'no-session-id',
]);

if (!stateFile) {
  console.error('FAKE_STATE_FILE is required');
  process.exit(2);
}
if (!supportedModes.has(mode)) {
  console.error(`unsupported FAKE_MODE: ${mode}`);
  process.exit(2);
}

function initialState() {
  return {
    mode,
    launchCount: 0,
    cancelCalls: 0,
    annotations: [],
    requestedEfforts: [],
    jobs: {},
  };
}

function readState() {
  if (!fs.existsSync(stateFile)) return initialState();
  return JSON.parse(fs.readFileSync(stateFile, 'utf8'));
}

function writeState(state) {
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, `${JSON.stringify(state, null, 2)}\n`);
}

function optionValue(args, name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

function jobIdFrom(args) {
  return args.find((arg) => /^job-\d+$/.test(arg));
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

const [command, ...args] = process.argv.slice(2);
const state = readState();

if (state.mode !== mode) {
  console.error(`state mode ${state.mode} does not match FAKE_MODE ${mode}`);
  process.exit(2);
}

if (command === 'task') {
  state.launchCount += 1;
  const id = `job-${state.launchCount}`;
  const effort = optionValue(args, '--effort') ?? null;
  const prompt = args.at(-1) ?? '';
  const annotation = 'prior attempt stalled; working tree may hold partial edits — review git diff first';
  const logFile = `${stateFile}.${id}.log`;
  fs.writeFileSync(logFile, `launch ${state.launchCount}\n`);

  state.requestedEfforts.push(effort);
  if (prompt.includes(annotation)) state.annotations.push(annotation);
  state.jobs[id] = {
    id,
    attempt: state.launchCount,
    effort,
    logFile,
    cancelled: false,
  };
  writeState(state);
  emit({ jobId: id });
  process.exit(0);
}

const id = jobIdFrom(args);
const job = id ? state.jobs[id] : undefined;
if (!job) {
  emit({ error: { code: 'JOB_NOT_FOUND', jobId: id ?? null } });
  process.exit(1);
}

if (command === 'status') {
  let status = 'completed';
  let threadId = `thread-${job.attempt}`;

  if (mode === 'stall-twice' || (mode === 'stall-once' && job.attempt === 1)) {
    status = 'running';
  } else if (mode === 'no-session-id' && job.attempt === 1) {
    status = 'starting';
    threadId = null;
  }

  emit({
    job: {
      id,
      // Match the real cancellation caveat: the companion can record a cancel
      // request while the underlying turn remains active.
      status,
      threadId,
      logFile: job.logFile,
      cancelRequested: job.cancelled,
    },
  });
  process.exit(0);
}

if (command === 'cancel') {
  state.cancelCalls += 1;
  job.cancelled = true;
  writeState(state);
  emit({ job: { id, status: 'cancelled', cancelled: true } });
  process.exit(0);
}

if (command === 'result') {
  emit({ job: { id, status: job.cancelled ? 'cancelled' : 'completed' }, result: `completed ${id}` });
  process.exit(0);
}

emit({ error: { code: 'UNSUPPORTED_COMMAND', command: command ?? null } });
process.exit(2);
