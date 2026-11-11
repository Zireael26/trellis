// Synthetic callback/dispatcher overhead only; no model or native tool execution.
// node core-rules/pi/tests/bench-dispatch.mjs [source-root] [N] [--functional]
// --functional exercises one iteration per variant without timing output.
import { writeFileSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
import { loadavg } from 'node:os';
import { performance } from 'node:perf_hooks';
import { deliveredFixture } from './delivered-fixture.mjs';
import { localPostAction } from '../extensions/trellis.ts';
const source = process.argv[2] ? resolve(process.argv[2]) : undefined;
const functional = process.argv.includes('--functional');
const n = functional ? 1 : Number(process.argv[3] ?? 30);
const f = await deliveredFixture(undefined, source);
try {
  writeFileSync(resolve(f.cwd, 'file.txt'), 'fixture');
  const warm = f.call('read', { path: 'file.txt' });
  await f.fire('tool_call', warm); await f.result(warm);
  console.log(JSON.stringify({ evidence: 'synthetic delivered callbacks, no native host/model/tool runtime', source, n, node: process.version, loadavg: loadavg() }));
  // Handler-only edit/write variants; compatibility dispatch timing is a
  // different boundary. Qualification owns measured claims (T42–T44).
  for (const variant of [
    { tool: 'read', failed: false, details: undefined },
    ...['edit', 'write'].flatMap(tool => [
      { tool, failed: false, details: undefined },
      { tool, failed: true, details: undefined },
      { tool, failed: false, details: { isError: false } },
      { tool, failed: false, details: { isError: true } },
    ]),
  ]) {
    const { tool, failed, details } = variant;
    const durations = [], pres = [], posts = [];
    const before = f.calls.length;
    for (let i = 0; i < n; i++) {
      const event = f.call(tool, { path: 'file.txt', content: 'fixture' });
      const start = performance.now();
      const result = await f.fire('tool_call', event);
      if (result?.block) throw new Error(result.reason);
      const mid = performance.now();
      await f.fire('tool_result', { ...event, content: [{ type: 'text', text: 'fixture result' }], isError: failed, ...(details ? { details } : {}) });
      const end = performance.now();
      durations.push(end - start); pres.push(mid - start); posts.push(end - mid);
    }
    const stats = values => { values.sort((a, b) => a - b); return { p50_ms: (values[Math.floor((n - 1) / 2)] + values[Math.floor(n / 2)]) / 2, p95_ms: values[Math.ceil(n * .95) - 1] }; };
    console.log(JSON.stringify({ boundary: 'handler', variant, in_process_read_tracking: true,
      ...(functional ? { readiness: true, timing: 'UNMEASURED' } : { total: stats(durations), pre: stats(pres), post: stats(posts) }),
      processes_per_call: (f.calls.length - before) / n }));
  }
  // Keep prompt/lifecycle handler boundaries separate from the compatibility
  // dispatcher. Functional mode exercises both without publishing timings.
  for (const native_event of ['session_start', 'before_agent_start', 'session_before_compact', 'session_compact', 'session_shutdown']) {
    const durations = [];
    for (let i = 0; i < n; i++) {
      if (native_event === 'session_shutdown') await f.fire('session_start', { reason: 'resume' });
      const start = performance.now();
      await f.fire(native_event, { reason: 'startup', messageType: 'user', systemPrompt: 'parent', willRetry: false });
      durations.push(performance.now() - start);
    }
    console.log(JSON.stringify({ boundary: 'handler', native_event, readiness: true,
      ...(functional ? { timing: 'UNMEASURED' } : { wall_ms: durations }) }));
    if (native_event === 'before_agent_start') continue; // Local prompt assembly, no dispatcher event.
    const envelope = { schema_version: 1, harness: 'pi', phase: 'lifecycle', native_event, cwd: f.cwd, session_id: 'fixture-session', reason: 'startup' };
    const samples = [];
    for (let i = 0; i < n; i++) {
      const start = performance.now();
      const result = await f.pi.exec(resolve(f.runtime, 'core-rules/pi/hooks/dispatch.sh'), ['--base64', Buffer.from(JSON.stringify(envelope)).toString('base64')], { cwd: f.cwd, signal: f.ctx.signal });
      if (result.code !== 0 || !JSON.parse(result.stdout).schema_version) throw new Error(result.stderr || result.stdout);
      samples.push(performance.now() - start);
    }
    console.log(JSON.stringify({ boundary: 'dispatch-only', native_event, transport: 'legacy-base64', readiness: true,
      ...(functional ? { timing: 'UNMEASURED' } : { wall_ms: samples }) }));
  }
  for (const tool of ['edit', 'write']) for (const tracking of [false, true]) for (const status of ['succeeded', 'failed']) {
    const samples = [];
    let credits = 0;
    for (let i = 0; i < n; i++) {
      const event = { schema_version: 1, harness: 'pi', phase: 'post_action', native_event: 'tool_result', cwd: f.cwd, session_id: 'fixture-session',
        action: { id: `batch-${i}`, tool_name: tool, family: 'file_mutation', target_coverage: 'complete', targets: [{ operation: 'update', path: 'file.txt' }], input: { path: 'file.txt' } },
        result: { status, is_error: status === 'failed', output: [] }, in_process_read_tracking: tracking };
      const start = performance.now();
      const result = await localPostAction(f.pi, event, { cwd: f.cwd, signal: f.ctx.signal }, () => credits++);
      samples.push(performance.now() - start);
      if (result.decision !== 'allow') throw new Error(result.reason);
    }
    if (credits !== (tracking || status === 'failed' ? 0 : n)) throw new Error('duplicate or missing batch read credit');
    console.log(JSON.stringify({ boundary: 'handler-local-batch', tool, in_process_read_tracking: tracking, status, readiness: true,
      ...(functional ? { timing: 'UNMEASURED' } : { post_ms: samples }) }));
  }
} finally { rmSync(f.base, { recursive: true, force: true }); }
