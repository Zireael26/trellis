// Transport adapters for existing ExtensionAPI fixtures. Real dispatchers receive
// the actual nonce environment; decision-only mocks explicitly synthesize a
// completed response. Protocol/refusal tests in dispatch-signal use neither.
import assert from 'node:assert/strict';

export function completedDispatch(result, nonce) {
  return { ...result, stdout: `${result.stdout.trimEnd()}\n${JSON.stringify({ schema_version: 1, type: 'trellis_dispatch_complete', nonce, complete: true })}\n` };
}

export function realDispatchExec(exec) {
  return async (command, args, options) => {
    assert.equal(command, '/usr/bin/env');
    assert.match(args[0], /^TRELLIS_PI_DISPATCH_NONCE=[a-f0-9]{64}$/);
    const nonce = args[0].split('=')[1];
    assert.equal(args[1], '/bin/bash');
    return exec(args[2], args.slice(3), { ...options, env: { TRELLIS_PI_DISPATCH_NONCE: nonce } }, nonce);
  };
}

export function mockDispatchExec(exec) {
  return realDispatchExec(async (command, args, options, nonce) => completedDispatch(await exec(command, args, options), nonce));
}
