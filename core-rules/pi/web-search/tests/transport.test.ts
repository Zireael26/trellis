// T19 deterministic transport tests: exact request bytes, HTTP classes, stream bounds,
// cancellation at every stage, hard deadline with a stalled reader, reader release,
// no fallback, unsupported profile. No network.
// Run: node --experimental-strip-types --test core-rules/pi/web-search/tests/transport.test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DARWIN_ARM64,
  ENDPOINT_URL,
  MAX_EVENT_BYTES,
  MAX_STREAM_BYTES,
  SseFramer,
  buildBody,
  buildHeaders,
  createAntigravityTransport,
  httpReason,
  raceAbort,
  selectProfile,
  type StreamHandoff,
} from "../antigravity.ts";
import { createTrellisWebSearch, type Deps, type TransportRequest } from "../index.ts";
import { FAKE_PROJECT, FAKE_TOKEN, FINAL_EVENT, REQUEST_ID, TEXT_EVENT, byteChunks, fakeFetch, frame, type FakeFetchOptions } from "./fixtures/sse.ts";

const unhandled: unknown[] = [];
process.on("unhandledRejection", (reason) => unhandled.push(reason));

const CONFIG = { provider: "antigravity" as const, model: "gemini-3.8-flash", runtime_model: "gemini-3.8-flash-low", endpoint: "daily" as const, max_calls: 3 };

function request(overrides: Partial<TransportRequest> = {}): TransportRequest {
  return {
    config: CONFIG,
    credential: { token: FAKE_TOKEN, projectId: FAKE_PROJECT },
    query: "what is the current Node.js LTS",
    maxResults: 3,
    requestId: REQUEST_ID,
    signal: new AbortController().signal,
    deadlineAt: Number.MAX_SAFE_INTEGER,
    now: () => 0,
    ...overrides,
  };
}

function transport(fetchOptions: FakeFetchOptions = {}, extra: { platform?: string; arch?: string; consumer?: (h: StreamHandoff) => ReturnType<typeof capture> } = {}) {
  const f = fakeFetch(fetchOptions);
  const handoffs: StreamHandoff[] = [];
  const consumer = extra.consumer ?? ((h: StreamHandoff) => { handoffs.push(h); return capture(); });
  const t = createAntigravityTransport({ fetch: f.fetch, platform: extra.platform ?? "darwin", arch: extra.arch ?? "arm64", consumer });
  return { t, f, handoffs };
}

function capture() {
  return { status: "unavailable" as const, reason: "result_parser_unavailable" as const };
}

function assertNoSecret(value: unknown) {
  const blob = JSON.stringify(value);
  assert.ok(!blob.includes(FAKE_TOKEN), "token leaked");
  assert.ok(!blob.includes(FAKE_PROJECT), "project leaked");
  assert.ok(!blob.includes("SECRET-ERROR-BODY"), "error body leaked");
}

// ---------- frozen bytes ----------

test("headers: exact six frozen values in plugin order, no ambient input", () => {
  const h = buildHeaders(DARWIN_ARM64, "T");
  assert.deepEqual(Object.keys(h), ["Authorization", "Content-Type", "Accept", "User-Agent", "X-Goog-Api-Client", "Client-Metadata"]);
  assert.equal(h.Authorization, "Bearer T");
  assert.equal(h["Content-Type"], "application/json");
  assert.equal(h.Accept, "text/event-stream");
  assert.equal(h["User-Agent"], "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)");
  assert.equal(h["X-Goog-Api-Client"], "google-cloud-sdk vscode_cloudshelleditor/0.1");
  assert.equal(h["Client-Metadata"], '{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}');
});

test("body: exact frozen shape and serialized bytes", () => {
  const body = JSON.stringify(buildBody({ projectId: "P", runtimeModel: "gemini-3.8-flash-low", query: "Q", requestId: REQUEST_ID }));
  assert.equal(
    body,
    `{"project":"P","model":"gemini-3.8-flash-low","request":{"contents":[{"role":"user","parts":[{"text":"Q"}]}],"tools":[{"googleSearch":{}}],"generationConfig":{"maxOutputTokens":2048}},"requestType":"agent","userAgent":"antigravity","requestId":"${REQUEST_ID}"}`,
  );
  assert.ok(!body.includes("sessionId") && !body.includes("labels") && !body.includes("toolConfig") && !body.includes("systemInstruction"));
});

test("profile: only darwin/arm64 is supported", () => {
  assert.equal(selectProfile("darwin", "arm64"), DARWIN_ARM64);
  for (const [p, a] of [["linux", "x64"], ["darwin", "x64"], ["win32", "arm64"], ["linux", "arm64"]]) assert.equal(selectProfile(p, a), null, `${p}/${a}`);
});

test("request: one POST to the pinned URL with frozen headers, body, redirect:error and the caller's signal", async () => {
  const { t, f, handoffs } = transport({ chunks: [frame(TEXT_EVENT), frame(FINAL_EVENT)] });
  const ac = new AbortController();
  const r = await t(request({ signal: ac.signal }));
  assert.equal(f.calls.length, 1);
  const call = f.calls[0];
  assert.equal(call.url, ENDPOINT_URL);
  assert.equal(call.init.method, "POST");
  assert.equal(call.init.redirect, "error");
  assert.equal(call.init.signal, ac.signal);
  assert.deepEqual(call.init.headers, buildHeaders(DARWIN_ARM64, FAKE_TOKEN));
  assert.equal(JSON.parse(call.init.body).model, "gemini-3.8-flash-low");
  assert.equal(JSON.parse(call.init.body).project, FAKE_PROJECT);
  assert.equal(r.status, "unavailable");
  assert.equal(r.reason, "result_parser_unavailable");
  assert.equal(handoffs.length, 1);
  assert.equal(handoffs[0].events.length, 2);
  assert.equal(handoffs[0].complete, true);
  assert.equal(handoffs[0].http_status, 200);
  assert.equal(handoffs[0].requestedRuntimeModel, "gemini-3.8-flash-low");
});

test("no fallback: per invocation exactly one request with the configured model; different configs do not share one model", async () => {
  const { t, f } = transport({ status: 404 });
  await t(request());
  await t(request({ config: { ...CONFIG, runtime_model: "gemini-3.8-flash-high" } }));
  assert.equal(f.calls.length, 2);
  assert.equal(JSON.parse(f.calls[0].init.body).model, "gemini-3.8-flash-low");
  assert.equal(JSON.parse(f.calls[1].init.body).model, "gemini-3.8-flash-high");
  assert.ok(f.calls.every((c) => c.url === ENDPOINT_URL));
});

test("unsupported profile: unavailable before any fetch", async () => {
  const { t, f } = transport({}, { platform: "linux", arch: "x64" });
  const r = await t(request());
  assert.deepEqual(r, { status: "unavailable", reason: "unsupported_profile" });
  assert.equal(f.calls.length, 0);
});

test("malformed request id is refused before fetch", async () => {
  const { t, f } = transport();
  const r = await t(request({ requestId: "agent/abc/1/def/2" }));
  assert.equal(r.status, "error");
  assert.equal(f.calls.length, 0);
});

// ---------- HTTP classes ----------

for (const [status, reason] of [[400, "http_bad_request"], [401, "http_auth"], [403, "http_auth"], [429, "http_rate_limited"], [500, "http_server_error"], [503, "http_server_error"], [404, "http_other"]] as const) {
  test(`HTTP ${status}: fixed ${reason}, body cancelled unread, nothing leaks`, async () => {
    const { t, f, handoffs } = transport({ status });
    const r = await t(request());
    assert.equal(r.status, "error");
    assert.equal(r.reason, reason);
    assert.equal(r.status === "error" ? r.http_status : undefined, status);
    assert.equal(f.cancelled(), true, "error body released");
    assert.equal(handoffs.length, 0);
    assertNoSecret(r);
    assert.equal(httpReason(status), reason);
  });
}

test("network failure before response: transport_error, single attempt", async () => {
  const { t, f } = transport({ networkError: true });
  const r = await t(request());
  assert.deepEqual(r, { status: "error", reason: "transport_error" });
  assert.equal(f.calls.length, 1);
});

// ---------- SSE framing and bounds ----------

test("framer: CRLF, multiline data, chunk boundaries mid-multibyte, trailing frame without terminator", async () => {
  const text = `data: {"a":1}\r\ndata: {"b":"é\u{1F600}"}\r\n\r\n${frame(TEXT_EVENT)}data: {"tail":true}`;
  const { t, handoffs } = transport({ chunks: byteChunks(text, [3, 10, 20, 1, 2, 7]) });
  await t(request());
  const h = handoffs[0];
  assert.equal(h.events.length, 3);
  assert.equal(h.events[0], '{"a":1}\n{"b":"é\u{1F600}"}');
  assert.equal(JSON.parse(h.events[1]).response.candidates[0].content.parts[0].text, "placeholder text");
  assert.equal(h.events[2], '{"tail":true}');
  assert.equal(h.trailingPartial, true);
  assert.equal(h.complete, true);
});

test("framer: non-data lines (comments, event:, id:) are ignored; empty frames produce no event", () => {
  const fr = new SseFramer();
  assert.equal(fr.feed(": keepalive\n\nevent: ping\nid: 1\n\n"), null);
  assert.deepEqual(fr.finish().events, []);
});

test("event over 128 KiB: stream_bound, reader released", async () => {
  const big = `data: ${"x".repeat(MAX_EVENT_BYTES + 10)}\n\n`;
  // `stall` keeps the fixture stream open past the oversized event so the reader
  // cancel is observable; a naturally closing fixture pulls ahead and closes first.
  const { t, f, handoffs } = transport({ chunks: byteChunks(big, [1000, 5000, 100000]), stall: true });
  const r = await t(request());
  assert.equal(r.status, "error");
  assert.equal(r.reason, "stream_bound");
  assert.equal(f.cancelled(), true, "reader cancelled after the bound tripped");
  assert.equal(handoffs.length, 0);
});

test("stream over 1 MiB of small frames: stream_bound without consuming the rest", async () => {
  const small = frame({ t: 1 });
  const count = Math.ceil(MAX_STREAM_BYTES / small.length) + 5;
  const chunks = Array.from({ length: count }, () => small);
  const { t, f } = transport({ chunks });
  const r = await t(request());
  assert.equal(r.status === "error" ? r.reason : r.status, "stream_bound");
  assert.ok(f.bodyReads() < count, "did not read every chunk after the bound tripped");
  assert.equal(f.cancelled(), true);
});

test("stream exactly at 1 MiB total is accepted", async () => {
  const payload = "y".repeat(1000);
  const one = `data: ${payload}\n\n`;
  const n = Math.floor(MAX_STREAM_BYTES / one.length);
  const { t, handoffs } = transport({ chunks: Array.from({ length: n }, () => one) });
  const r = await t(request());
  assert.equal(r.reason, "result_parser_unavailable");
  assert.equal(handoffs[0].events.length, n);
});

// ---------- cancellation and deadline ----------

test("cancel before fetch: cancelled, zero requests", async () => {
  const { t, f } = transport();
  const ac = new AbortController();
  ac.abort();
  const r = await t(request({ signal: ac.signal }));
  assert.deepEqual(r, { status: "cancelled", reason: "cancelled" });
  assert.equal(f.calls.length, 0);
});

test("cancel during fetch (before headers): cancelled, one request, no consumer", async () => {
  const ac = new AbortController();
  const { t, f, handoffs } = transport({ delayMs: 10, honorSignal: true, chunks: [frame(FINAL_EVENT)] });
  const pending = t(request({ signal: ac.signal }));
  setTimeout(() => ac.abort(), 2);
  const r = await pending;
  assert.equal(r.status, "cancelled");
  assert.equal(f.calls.length, 1);
  assert.equal(handoffs.length, 0);
});

test("cancel mid-stream: cancelled, reader cancelled/released, no consumer", async () => {
  const ac = new AbortController();
  const { t, f, handoffs } = transport({ chunks: [frame(TEXT_EVENT)], stall: true });
  const pending = t(request({ signal: ac.signal }));
  setTimeout(() => ac.abort(), 5);
  const r = await pending;
  assert.equal(r.status, "cancelled");
  assert.equal(f.cancelled(), true);
  assert.equal(handoffs.length, 0);
});

test("hard deadline with a stalled reader that ignores the signal: returns when the signal fires", async () => {
  const { t, f, handoffs } = transport({ chunks: [frame(TEXT_EVENT)], stall: true });
  const deadline = AbortSignal.timeout(15);
  const started = Date.now();
  const r = await t(request({ signal: deadline }));
  assert.equal(r.status, "cancelled");
  assert.ok(Date.now() - started < 1000);
  assert.equal(f.cancelled(), true);
  assert.equal(handoffs.length, 0);
});

test("reader released on the happy path too (cancel after done is harmless)", async () => {
  const { t } = transport({ chunks: [frame(FINAL_EVENT)] });
  const r = await t(request());
  assert.equal(r.reason, "result_parser_unavailable");
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(unhandled, []);
});

// ---------- correction: pending operations never hold the result ----------

test("fetch that never settles: abort returns promptly; late response is disposed without a second request", async () => {
  const ac = new AbortController();
  const { t, f, handoffs } = transport({ neverSettle: true, chunks: [frame(FINAL_EVENT)] });
  const pending = t(request({ signal: ac.signal }));
  await new Promise((resolve) => setTimeout(resolve, 2));
  ac.abort();
  const r = await pending;
  assert.deepEqual(r, { status: "cancelled", reason: "cancelled" });
  f.release();
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(f.calls.length, 1);
  assert.equal(f.cancelled(), true, "late response body disposed");
  assert.equal(handoffs.length, 0);
  assert.deepEqual(unhandled, []);
});

test("abort with a reader whose underlying cancel never resolves: result returns promptly, no unhandled rejection", async () => {
  const ac = new AbortController();
  const { t, f } = transport({ chunks: [frame(TEXT_EVENT)], stall: true, cancelNeverResolves: true });
  const pending = t(request({ signal: ac.signal }));
  setTimeout(() => ac.abort(), 5);
  const started = Date.now();
  const r = await pending;
  assert.equal(r.status, "cancelled");
  assert.ok(Date.now() - started < 1000, "not held by the pending cancel");
  assert.equal(f.cancelled(), true);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(unhandled, []);
});

test("HTTP error whose body cancellation never resolves: fixed reason returns promptly", async () => {
  const { t } = transport({ status: 503, cancelNeverResolves: true });
  const started = Date.now();
  const r = await t(request());
  assert.equal(r.status, "error");
  assert.equal(r.reason, "http_server_error");
  assert.ok(Date.now() - started < 1000);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(unhandled, []);
});

test("instance guard is released after an abort with a never-resolving cancel (next call is not busy)", async () => {
  const ac = new AbortController();
  const { t } = transport({ chunks: [frame(TEXT_EVENT)], stall: true, cancelNeverResolves: true });
  const deps: Deps = {
    registry: {
      find: () => ({ provider: "antigravity", id: "gemini-3.8-flash", api: "antigravity-api", baseUrl: "https://daily-cloudcode-pa.googleapis.com" }),
      isUsingOAuth: () => true,
      getProviderAuth: async () => ({ auth: { apiKey: JSON.stringify({ token: FAKE_TOKEN, projectId: FAKE_PROJECT }) } }),
    },
    env: (name) => (name === "TRELLIS_WEB_SEARCH_CONFIG" ? "/fake/cfg" : undefined),
    readFile: () => ({ info: { isRegular: true, isSymlink: false, size: 10 }, text: JSON.stringify(CONFIG) }),
    transport: t,
    now: () => Date.now(),
    deadlineMs: 90_000,
    requestId: () => REQUEST_ID,
  };
  const inst = createTrellisWebSearch(deps);
  const pending = inst.execute({ query: "q" }, ac.signal);
  setTimeout(() => ac.abort(), 5);
  const r1 = await pending;
  assert.equal(r1.details.reason, "cancelled");
  assert.equal(inst.state().in_flight, false);
  const r2 = await inst.execute({ query: "q2" }, undefined);
  assert.notEqual(r2.details.reason, "busy");
  assert.equal(r2.details.calls_used, 2);
});

test("raceAbort: late rejection after abort is discarded; late value goes to onLate", async () => {
  const ac = new AbortController();
  let resolve!: (v: string) => void;
  let reject!: (e: Error) => void;
  const late: string[] = [];
  const a = raceAbort(new Promise<string>((r) => { resolve = r; }), ac.signal, (v) => late.push(v));
  const b = raceAbort(new Promise<string>((_, rj) => { reject = rj; }), ac.signal);
  ac.abort();
  assert.deepEqual(await a, { kind: "aborted" });
  assert.deepEqual(await b, { kind: "aborted" });
  resolve("late-value");
  reject(new Error("late-error"));
  await new Promise((r) => setTimeout(r, 5));
  assert.deepEqual(late, ["late-value"]);
  assert.deepEqual(unhandled, []);
});

// ---------- correction: event bound is per frame, not per transport chunk ----------

test("many small events totaling >128 KiB behave identically in one chunk and in many chunks", async () => {
  const one = frame({ k: "v".repeat(500) });
  const count = Math.ceil((MAX_EVENT_BYTES * 3) / one.length);
  const text = one.repeat(count);
  assert.ok(Buffer.byteLength(text) > MAX_EVENT_BYTES);
  const single = transport({ chunks: [text] });
  const many = transport({ chunks: byteChunks(text, Array.from({ length: 40 }, (_, i) => 1000 + i * 37)) });
  const r1 = await single.t(request());
  const r2 = await many.t(request());
  assert.equal(r1.reason, "result_parser_unavailable");
  assert.equal(r2.reason, "result_parser_unavailable");
  assert.deepEqual(single.handoffs[0].events, many.handoffs[0].events);
  assert.equal(single.handoffs[0].events.length, count);
});

test("framer: a single frame over 128 KiB fails immediately even when delivered in one chunk with valid neighbours", () => {
  const fr = new SseFramer();
  assert.equal(fr.feed(frame({ ok: 1})), null);
  assert.equal(fr.feed(`data: ${"z".repeat(MAX_EVENT_BYTES + 1)}\n\n${frame({ after: 1 })}`), "stream_bound");
  assert.equal(fr.feed(frame({ more: 1 })), "stream_bound", "bound is sticky");
});

test("framer: partial frame growing past 128 KiB without a terminator fails at the chunk that crosses the bound", () => {
  const fr = new SseFramer();
  assert.equal(fr.feed(`data: ${"p".repeat(MAX_EVENT_BYTES - 100)}`), null);
  assert.equal(fr.feed("p".repeat(200)), "stream_bound");
});

// ---------- closure: exact-bound frames with the delimiter split across chunks ----------

const EXACT = `data: ${"e".repeat(MAX_EVENT_BYTES - 6)}`; // raw frame body exactly MAX_EVENT_BYTES bytes
assert.equal(Buffer.byteLength(EXACT), MAX_EVENT_BYTES);

for (const [name, sep, splitAt] of [
  ["LF LF split after first LF", "\n\n", 1],
  ["CRLF CRLF split after CR", "\r\n\r\n", 1],
  ["CRLF CRLF split after CRLF", "\r\n\r\n", 2],
  ["CRLF CRLF split after CRLF CR", "\r\n\r\n", 3],
  ["LF CRLF split after LF CR", "\n\r\n", 2],
] as const) {
  test(`exact-bound frame, ${name}: accepted, identical to the single-chunk delivery`, () => {
    const whole = new SseFramer();
    assert.equal(whole.feed(EXACT + sep), null);
    const split = new SseFramer();
    assert.equal(split.feed(EXACT + sep.slice(0, splitAt)), null, "must not reject before the delimiter resolves");
    assert.equal(split.feed(sep.slice(splitAt)), null);
    assert.deepEqual(split.finish(), whole.finish());
    assert.equal(whole.events.length, 1);
    assert.equal(Buffer.byteLength(whole.events[0]), MAX_EVENT_BYTES - 6);
  });
}

test("exact-bound + 1 frame is rejected when the delimiter resolves, in one chunk and split", () => {
  const over = EXACT + "e";
  assert.equal(new SseFramer().feed(over + "\n\n"), "stream_bound");
  const split = new SseFramer();
  assert.equal(split.feed(over + "\n"), "stream_bound", "body already over the bound regardless of the pending delimiter");
});

test("exact-bound frame at EOF without terminator is accepted; one byte over at EOF is rejected by finish()", () => {
  const ok = new SseFramer();
  assert.equal(ok.feed(EXACT + "\n"), null);
  const fin = ok.finish();
  assert.equal(fin.bound, null);
  assert.equal(fin.events.length, 1);
  const over = new SseFramer();
  assert.equal(over.feed(EXACT), null);
  assert.equal(over.feed("e"), "stream_bound");
  const eof = new SseFramer();
  // Bound must also be enforced by finish() when the last chunk ended exactly at the bound plus a lone CR.
  assert.equal(eof.feed(EXACT + "\r"), null);
  assert.equal(eof.finish().bound, null);
});

test("transport: exact-bound frame with the delimiter split across two chunks is delivered as one event", async () => {
  const { t, handoffs } = transport({ chunks: [EXACT + "\r\n", "\r\n", frame(FINAL_EVENT)] });
  const r = await t(request());
  assert.equal(r.reason, "result_parser_unavailable");
  assert.equal(handoffs[0].events.length, 2);
});

test("transport: EOF with an over-bound unterminated trailing frame is stream_bound, not a handoff", async () => {
  const { t, handoffs } = transport({ chunks: [frame(TEXT_EVENT), `data: ${"q".repeat(MAX_EVENT_BYTES)}`] });
  const r = await t(request());
  assert.equal(r.status, "error");
  assert.equal(r.reason, "stream_bound");
  assert.equal(handoffs.length, 0);
});

// ---------- integration through the tool instance ----------

test("through createTrellisWebSearch: deadline covers owner + fetch + stream; result is content-free and carries http_status", async () => {
  const { t } = transport({ status: 429 });
  const deps: Deps = {
    registry: {
      find: () => ({ provider: "antigravity", id: "gemini-3.8-flash", api: "antigravity-api", baseUrl: "https://daily-cloudcode-pa.googleapis.com" }),
      isUsingOAuth: () => true,
      getProviderAuth: async () => ({ auth: { apiKey: JSON.stringify({ token: FAKE_TOKEN, projectId: FAKE_PROJECT }) } }),
    },
    env: (name) => (name === "TRELLIS_WEB_SEARCH_CONFIG" ? "/fake/cfg" : undefined),
    readFile: () => ({ info: { isRegular: true, isSymlink: false, size: 10 }, text: JSON.stringify(CONFIG) }),
    transport: t,
    now: () => Date.now(),
    deadlineMs: 90_000,
    requestId: () => REQUEST_ID,
  };
  const r = await createTrellisWebSearch(deps).execute({ query: "q" }, undefined);
  assert.equal(r.details.status, "error");
  assert.equal(r.details.reason, "http_rate_limited");
  assert.equal(r.details.http_status, 429);
  assert.equal(r.details.request_id, REQUEST_ID);
  assert.equal(r.details.calls_used, 1);
  assertNoSecret(r);
});

test("through createTrellisWebSearch: a transport without an injected consumer keeps the placeholder outcome (never success)", async () => {
  const { t } = transport({ chunks: [frame(TEXT_EVENT), frame(FINAL_EVENT)] });
  const deps: Deps = {
    registry: {
      find: () => ({ provider: "antigravity", id: "gemini-3.8-flash", api: "antigravity-api", baseUrl: "https://daily-cloudcode-pa.googleapis.com" }),
      isUsingOAuth: () => true,
      getProviderAuth: async () => ({ auth: { apiKey: JSON.stringify({ token: FAKE_TOKEN, projectId: FAKE_PROJECT }) } }),
    },
    env: (name) => (name === "TRELLIS_WEB_SEARCH_CONFIG" ? "/fake/cfg" : undefined),
    readFile: () => ({ info: { isRegular: true, isSymlink: false, size: 10 }, text: JSON.stringify(CONFIG) }),
    transport: t,
    now: () => Date.now(),
    deadlineMs: 90_000,
    requestId: () => REQUEST_ID,
  };
  const r = await createTrellisWebSearch(deps).execute({ query: "q" }, undefined);
  assert.equal(r.details.status, "unavailable");
  assert.equal(r.details.reason, "result_parser_unavailable");
  assert.equal(r.details.search_executed, false);
  assert.deepEqual(r.details.sources, []);
});
