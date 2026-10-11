// Synthetic callback/dispatcher overhead only; no model or native tool execution.
// node core-rules/pi/tests/bench-dispatch.mjs [source-root] [N]
import { writeFileSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
import { loadavg } from 'node:os';
import { performance } from 'node:perf_hooks';
import { deliveredFixture } from './delivered-fixture.mjs';
const source = process.argv[2] ? resolve(process.argv[2]) : undefined;
const n = Number(process.argv[3] ?? 30);
const f = await deliveredFixture(undefined, source);
try {
  writeFileSync(resolve(f.cwd, 'file.txt'), 'fixture');
  const warm = f.call('read', { path: 'file.txt' });
  await f.fire('tool_call', warm); await f.result(warm);
  console.log(JSON.stringify({ evidence: 'synthetic delivered callbacks, no native host/model/tool runtime', source, n, node: process.version, loadavg: loadavg() }));
  for (const tool of ['read', 'write']) {
    const durations = [], pres = [], posts = [];
    const before = f.calls.length;
    for (let i = 0; i < n; i++) {
      const event = f.call(tool, { path: 'file.txt', content: 'fixture' });
      const start = performance.now();
      const result = await f.fire('tool_call', event);
      if (result?.block) throw new Error(result.reason);
      const mid = performance.now();
      await f.result(event);
      const end = performance.now();
      durations.push(end - start); pres.push(mid - start); posts.push(end - mid);
    }
    const stats = values => { values.sort((a, b) => a - b); return { p50_ms: (values[Math.floor((n - 1) / 2)] + values[Math.floor(n / 2)]) / 2, p95_ms: values[Math.ceil(n * .95) - 1] }; };
    console.log(JSON.stringify({ tool, total: stats(durations), pre: stats(pres), post: stats(posts), processes_per_call: (f.calls.length - before) / n }));
  }
} finally { rmSync(f.base, { recursive: true, force: true }); }
