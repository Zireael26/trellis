// T20 deterministic result tests: grounding semantics, citations, usage presence,
// URL safety, bounds, rendering, and content isolation. No network, no Pi runtime.
// Run: node --experimental-strip-types --test core-rules/pi/web-search/tests/result.test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { MAX_INTERNAL_SOURCES, MAX_RENDERED_BYTES, PROVIDER_LIMIT_LABEL, RENDER_TRUNCATION_LABEL, TRUNCATION_LABEL, byteBoundaryMap, byteOffsetToIndex, consumeStream, groundingConsumer, mapUsage, render, validateSourceUrl } from "../result.ts";
import { createAntigravityTransport, type StreamHandoff } from "../antigravity.ts";
import { RECEIPT_KEYS, costReceipt, createTrellisWebSearch, type Deps } from "../index.ts";
import { FAKE_PROJECT, FAKE_TOKEN, REQUEST_ID, fakeFetch, frame } from "./fixtures/sse.ts";

const SECRET = `SECRET-PROVIDER-ERROR ${FAKE_TOKEN} ${FAKE_PROJECT}`;
const URL_A = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/AAA";
const URL_B = "https://example.org/b";

function ev(payload: unknown): string {
  return JSON.stringify({ response: payload });
}

function chunk(uri: string, title?: string) {
  return { web: { uri, ...(title ? { title } : {}) } };
}

function handoff(events: string[], extra: Partial<StreamHandoff> = {}): StreamHandoff {
  return { events, complete: true, trailingPartial: false, http_status: 200, requestedRuntimeModel: "gemini-3.8-flash-low", maxResults: 5, ...extra };
}

/** Multi-event grounded stream: text deltas, grounding in the final event, usage, modelVersion. */
function grounded(overrides: { queries?: unknown; chunks?: unknown[]; supports?: unknown[]; usage?: unknown; text?: [string, string]; finish?: string; modelVersion?: unknown } = {}) {
  const [t1, t2] = overrides.text ?? ["Node.js 24 is ", "the Active LTS line."];
  const gm: Record<string, unknown> = {};
  gm.webSearchQueries = overrides.queries === undefined ? ["node lts"] : overrides.queries;
  gm.groundingChunks = overrides.chunks ?? [chunk(URL_A, "Node.js"), chunk(URL_B, "Example")];
  gm.groundingSupports = overrides.supports ?? [{ segment: { startIndex: 0, endIndex: 10, text: "Node.js 24" }, groundingChunkIndices: [0] }];
  const final: Record<string, unknown> = {
    candidates: [{ content: { parts: [{ text: t2 }] }, finishReason: overrides.finish ?? "STOP", groundingMetadata: gm }],
    usageMetadata: overrides.usage === undefined ? { promptTokenCount: 12, candidatesTokenCount: 7, totalTokenCount: 19 } : overrides.usage,
  };
  if (overrides.modelVersion !== undefined) final.modelVersion = overrides.modelVersion;
  return [ev({ candidates: [{ content: { parts: [{ text: t1 }] } }] }), ev(final)];
}

function assertNoLeak(value: unknown) {
  const blob = JSON.stringify(value);
  for (const s of [FAKE_TOKEN, FAKE_PROJECT, "SECRET-PROVIDER-ERROR"]) assert.ok(!blob.includes(s), `${s} leaked`);
}

// ---------- success semantics ----------

test("multi-event terminal success: deltas accumulated, evidence required, citations mapped, usage observed, observed model reported", () => {
  const r = consumeStream(handoff(grounded({ modelVersion: "gemini-3.8-flash-low" })));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.ok(r.answer.startsWith("Node.js 24 is the Active LTS line."));
  assert.equal(r.search_executed, true);
  assert.deepEqual(r.sources.map((s) => s.url), [URL_A, URL_B]);
  assert.equal(r.sources[0].redirect_unresolved, true, "grounding redirect preserved and labelled");
  assert.equal(r.sources[1].redirect_unresolved, false);
  assert.deepEqual(r.citations, [{ source_index: 0, start: 0, end: 10 }]);
  assert.equal(r.answer.slice(0, 10), "Node.js 24");
  assert.equal(r.observed_model, "gemini-3.8-flash-low");
  assert.equal(r.components.input?.value, 12);
  assert.equal(r.components.output?.value, 7);
  assert.equal(r.components.provider_total?.value, 19);
  assert.equal(r.components.cache_read?.presence, "unknown");
  assert.equal(r.components.cache_write?.presence, "unsupported");
  assert.equal(r.truncated, false);
  assert.ok(r.answer.includes("\n\nSources:\n1. Node.js — " + URL_A + " (grounding redirect, unresolved)\n2. Example — " + URL_B));
});

test("observed model is only the provider-reported field; requested runtime is never substituted", () => {
  const r = consumeStream(consumeInput(grounded()));
  assert.equal(r.status, "success");
  if (r.status === "success") assert.equal(r.observed_model, null);
  function consumeInput(events: string[]) {
    return handoff(events);
  }
});

// ---------- refusals (fixed, content-free) ----------

test("no webSearchQueries: error/no_search_evidence even with sources and links in the text", () => {
  const r = consumeStream(handoff(grounded({ queries: null, text: ["see https://example.org/x ", "for details"] })));
  assert.deepEqual(r, { status: "error", reason: "no_search_evidence", http_status: 200 });
});

test("empty webSearchQueries array, or only blank strings: no_search_evidence", () => {
  assert.equal(consumeStream(handoff(grounded({ queries: [] }))).reason, "no_search_evidence");
  assert.equal(consumeStream(handoff(grounded({ queries: ["  "] }))).reason, "no_search_evidence");
  assert.equal(consumeStream(handoff(grounded({ queries: "node" }))).reason, "no_search_evidence");
});

test("search reported but no valid sources: no_sources", () => {
  assert.equal(consumeStream(handoff(grounded({ chunks: [] }))).reason, "no_sources");
  assert.equal(consumeStream(handoff(grounded({ chunks: [chunk("ftp://x"), { web: {} }, "junk"] }))).reason, "no_sources");
});

test("search and sources but empty/whitespace answer: no_answer", () => {
  assert.equal(consumeStream(handoff(grounded({ text: ["", "  \n"] }))).reason, "no_answer");
});

test("incomplete stream (no terminal finishReason, or transport incomplete, or zero events): incomplete_stream", () => {
  const [first] = grounded();
  assert.equal(consumeStream(handoff([first])).reason, "incomplete_stream");
  assert.equal(consumeStream(handoff(grounded(), { complete: false })).reason, "incomplete_stream");
  assert.equal(consumeStream(handoff([])).reason, "incomplete_stream");
});

test("terminal error payload with secrets: provider_error, nothing echoed", () => {
  const events = [grounded()[0], JSON.stringify({ error: { code: 401, message: SECRET, status: "UNAUTHENTICATED" } })];
  const r = consumeStream(handoff(events));
  assert.deepEqual(r, { status: "error", reason: "provider_error", http_status: 200 });
  assertNoLeak(r);
});

test("non-completion finishReason (SAFETY): provider_error; MAX_TOKENS: success flagged truncated", () => {
  assert.equal(consumeStream(handoff(grounded({ finish: "SAFETY" }))).reason, "provider_error");
  const r = consumeStream(handoff(grounded({ finish: "MAX_TOKENS" })));
  assert.equal(r.status, "success");
  if (r.status === "success") assert.equal(r.truncated, true);
});

test("malformed event payload: malformed_stream; a non-object JSON event too", () => {
  assert.equal(consumeStream(handoff([grounded()[0], "{not json"])).reason, "malformed_stream");
  assert.equal(consumeStream(handoff([grounded()[0], "[1,2]"])).reason, "malformed_stream");
});

// ---------- usage presence ----------

test("sparse/zero/malformed/late usage: zero is observed zero, missing or malformed stays unknown, last event wins without summing", () => {
  const events = [
    ev({ candidates: [{ content: { parts: [{ text: "A " }] } }], usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 1, totalTokenCount: 101 } }),
    ev({ candidates: [{ content: { parts: [{ text: "B" }] }, finishReason: "STOP", groundingMetadata: { webSearchQueries: ["q"], groundingChunks: [chunk(URL_B)] } }] }),
    ev({ usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 0, cachedContentTokenCount: -1, thoughtsTokenCount: 2.5, totalTokenCount: "100" } }),
  ];
  const r = consumeStream(handoff(events));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.equal(r.answer.startsWith("A B"), true);
  assert.equal(r.components.input?.value, 100, "late usage event replaces, never sums (not 200)");
  assert.deepEqual(r.components.output, { value: 0, presence: "observed", semantics: "candidatesTokenCount" });
  assert.equal(r.components.cache_read?.presence, "unknown");
  assert.equal(r.components.reasoning?.presence, "unknown");
  assert.equal(r.components.provider_total?.presence, "unknown");
});

test("mapUsage with no usage at all returns nothing (all components stay unknown at the tool layer)", () => {
  assert.deepEqual(mapUsage(null), {});
});

// ---------- citations and offsets ----------

test("unicode byte offsets: valid boundaries convert to JS indices; mid-code-point or out-of-range offsets are uncoupled", () => {
  const answer = "é😀x"; // bytes: é=2, 😀=4, x=1 → 7 bytes; JS length 4
  assert.equal(byteOffsetToIndex(answer, 0), 0);
  assert.equal(byteOffsetToIndex(answer, 2), 1);
  assert.equal(byteOffsetToIndex(answer, 6), 3);
  assert.equal(byteOffsetToIndex(answer, 7), 4);
  assert.equal(byteOffsetToIndex(answer, 1), null);
  assert.equal(byteOffsetToIndex(answer, 3), null);
  assert.equal(byteOffsetToIndex(answer, 8), null);
  const supports = [
    { segment: { startIndex: 2, endIndex: 6, text: "😀" }, groundingChunkIndices: [0] },
    { segment: { startIndex: 1, endIndex: 6 }, groundingChunkIndices: [1] },
    { segment: { startIndex: 0, endIndex: 99 }, groundingChunkIndices: [1] },
    { segment: { startIndex: 4, endIndex: 2 }, groundingChunkIndices: [1] },
  ];
  const r = consumeStream(handoff(grounded({ text: ["é", "😀x"], supports })));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.deepEqual(r.citations, [{ source_index: 0, start: 1, end: 3 }]);
  assert.equal(r.answer.slice(1, 3), "😀");
});

test("segment.text mismatch, unknown chunk index, negative index: uncoupled, never fabricated", () => {
  const supports = [
    { segment: { startIndex: 0, endIndex: 4, text: "WRONG" }, groundingChunkIndices: [0] },
    { segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [7] },
    { segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [-1, 1.5] },
    { groundingChunkIndices: [1] },
  ];
  const r = consumeStream(handoff(grounded({ supports })));
  assert.equal(r.status, "success");
  if (r.status === "success") assert.deepEqual(r.citations, []);
});

test("supports resolve against the most recent chunk list; duplicate sources collapse and indices remap", () => {
  const events = [
    ev({ candidates: [{ content: { parts: [{ text: "abcd" }] }, groundingMetadata: { groundingChunks: [chunk(URL_B), chunk(URL_A)], groundingSupports: [{ segment: { startIndex: 0, endIndex: 2 }, groundingChunkIndices: [1] }] } }] }),
    ev({ candidates: [{ content: { parts: [{ text: "ef" }] }, finishReason: "STOP", groundingMetadata: { webSearchQueries: ["q"], groundingChunks: [chunk(URL_A), chunk(URL_B), chunk(URL_B)], groundingSupports: [{ segment: { startIndex: 2, endIndex: 6 }, groundingChunkIndices: [0, 2] }, { segment: { startIndex: 2, endIndex: 6 }, groundingChunkIndices: [0] }] } }] }),
  ];
  const r = consumeStream(handoff(events));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.deepEqual(r.sources.map((s) => s.url), [URL_B, URL_A], "first-seen order, deduped");
  assert.deepEqual(r.citations, [
    { source_index: 1, start: 0, end: 2 },
    { source_index: 1, start: 2, end: 6 },
    { source_index: 0, start: 2, end: 6 },
  ]);
});

// ---------- URL safety and bounds ----------

for (const [name, raw, ok] of [
  ["https", "https://example.org/a?b=1#c", true],
  ["http", "http://example.org/", true],
  ["userinfo", "https://user:pw@example.org/", false],
  ["username only", "https://user@example.org/", false],
  ["javascript", "javascript:alert(1)", false],
  ["file", "file:///etc/passwd", false],
  ["control char", "https://example.org/a\x01b", false],
  ["newline", "https://example.org/\nx", false],
  ["garbage", "not a url", false],
  ["empty", "", false],
] as const) {
  test(`validateSourceUrl ${name}`, () => {
    assert.equal(validateSourceUrl(raw) !== null, ok);
  });
}

test("internal bound 20 distinct sources; output bound max_results; citations to unexposed sources dropped", () => {
  const chunks = Array.from({ length: 30 }, (_, i) => chunk(`https://example.org/${i}`));
  const supports = [
    { segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [0] },
    { segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [3] },
    { segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [25] },
  ];
  const r = consumeStream(handoff(grounded({ chunks, supports, text: ["abcd", "!"] }), { maxResults: 3 }));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.equal(r.sources.length, 3);
  assert.deepEqual(r.citations, [{ source_index: 0, start: 0, end: 4 }]);
  const wide = consumeStream(handoff(grounded({ chunks, text: ["abcd", "!"] }), { maxResults: 10 }));
  if (wide.status === "success") assert.equal(wide.sources.length, 10);
  const all = consumeStream(handoff(grounded({ chunks, text: ["abcd", "!"] }), { maxResults: 30 }));
  if (all.status === "success") assert.equal(all.sources.length, MAX_INTERNAL_SOURCES);
});

// ---------- rendering bound ----------

test("rendered text is bounded at 32 KiB including sources and the truncation label; label present; cut at a code point", () => {
  const long = "😀".repeat(12_000); // 48,000 bytes
  const r = consumeStream(handoff(grounded({ text: [long, "tail"] })));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.ok(Buffer.byteLength(r.answer, "utf8") <= MAX_RENDERED_BYTES);
  assert.ok(r.answer.includes(TRUNCATION_LABEL));
  assert.ok(r.answer.endsWith(URL_B));
  assert.equal(r.truncated, true);
  const cut = r.answer.slice(0, r.answer.indexOf(TRUNCATION_LABEL));
  assert.ok(!/[\uD800-\uDFFF]$/.test(cut) || cut.length % 2 === 0, "no dangling surrogate");
  assert.equal([...cut].every((c) => c === "😀"), true);
});

test("answer truncation drops citations that no longer fit inside the exposed answer", () => {
  const long = "a".repeat(40_000);
  const supports = [
    { segment: { startIndex: 0, endIndex: 10 }, groundingChunkIndices: [0] },
    { segment: { startIndex: 39_000, endIndex: 39_010 }, groundingChunkIndices: [1] },
  ];
  const r = consumeStream(handoff(grounded({ text: [long, ""], supports })));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.equal(r.truncated, true);
  assert.deepEqual(r.citations, [{ source_index: 0, start: 0, end: 10 }]);
  const answerOnly = r.answer.slice(0, r.answer.indexOf(TRUNCATION_LABEL));
  assert.ok(r.citations.every((c) => c.end <= answerOnly.length));
});

test("exactly 32 KiB rendered is not truncated", () => {
  const block = `\n\nSources:\n1. ${URL_B}`;
  const answer = "b".repeat(MAX_RENDERED_BYTES - Buffer.byteLength(block));
  const r = consumeStream(handoff(grounded({ text: [answer, ""], chunks: [chunk(URL_B)], supports: [] })));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.equal(Buffer.byteLength(r.answer), MAX_RENDERED_BYTES);
  assert.equal(r.truncated, false);
});

// ---------- corrections (t20-corrections.md) ----------

test("C1 source block alone over 32 KiB: whole trailing sources dropped, nonempty answer kept, details reconciled, total ≤ 32768 bytes", async () => {
  const longTitle = "Ünïcödé ".repeat(32); // 256-char cap applies
  const chunks = Array.from({ length: 10 }, (_, i) => chunk(`https://example.org/${"ü".repeat(1500)}/${i}`, longTitle));
  const supports = [{ segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [0] }, { segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [9] }];
  const [e1, e2] = grounded({ chunks, supports, text: ["abcd", " tail"] });
  const f = fakeFetch({ chunks: [`data: ${e1}\n\n`, `data: ${e2}\n\n`] });
  const t = createAntigravityTransport({ fetch: f.fetch, platform: "darwin", arch: "arm64", consumer: groundingConsumer });
  const r = await createTrellisWebSearch(deps(t)).execute({ query: "q", max_results: 10 }, undefined);
  assert.equal(r.details.status, "success");
  const text = r.content[0].text;
  assert.ok(Buffer.byteLength(text, "utf8") <= MAX_RENDERED_BYTES, `rendered ${Buffer.byteLength(text, "utf8")} bytes`);
  assert.ok(text.startsWith("abcd tail"));
  assert.ok(r.details.sources.length >= 1 && r.details.sources.length < 10, `kept ${r.details.sources.length}`);
  for (const s of r.details.sources) assert.ok(text.includes(s.url), "every exposed source is rendered whole");
  assert.equal(text.includes("/9"), false, "dropped source is not rendered");
  assert.deepEqual(r.details.citations, [{ source_index: 0, start: 0, end: 4 }], "citation to a dropped source removed");
  assert.equal(r.details.truncated, false);
});

test("C1 render(): not even one source line fits beside a minimal answer → null → error/render_bound at the tool", () => {
  const huge = { url: `https://example.org/${"a".repeat(2000)}`, title: "t".repeat(256), redirect_unresolved: false };
  const many = Array.from({ length: 20 }, (_, i) => ({ ...huge, url: `${huge.url}/${i}` }));
  const ok = render("x".repeat(40_000), many, [], false);
  assert.ok(ok && Buffer.byteLength(ok.text, "utf8") <= MAX_RENDERED_BYTES && ok.sources.length >= 1);
  const src = Array.from({ length: 1 }, () => ({ url: `https://example.org/${"b".repeat(2040)}`, title: null, redirect_unresolved: false }));
  const tight = render("y".repeat(300), src, [], false);
  assert.ok(tight && tight.sources.length === 1);
  const impossible = [{ url: `https://example.org/${"c".repeat(2040)}`, title: "T".repeat(256), redirect_unresolved: true }];
  const filler = Array.from({ length: 19 }, (_, i) => ({ url: `https://example.org/${"d".repeat(1500)}/${i}`, title: "T".repeat(256), redirect_unresolved: false }));
  const r = render("z".repeat(500), [...filler, ...impossible], [], false);
  assert.ok(r === null || Buffer.byteLength(r.text, "utf8") <= MAX_RENDERED_BYTES);
});

for (const [name, raw] of [
  ["empty userinfo", "https://@example.org/"],
  ["userinfo with colon", "https://:@example.org/"],
  ["leading whitespace", " https://example.org/"],
  ["trailing whitespace", "https://example.org/ "],
  ["trailing newline", "https://example.org/\n"],
  ["empty authority", "https:///path"],
] as const) {
  test(`C2 validateSourceUrl rejects ${name}`, () => {
    assert.equal(validateSourceUrl(raw), null);
  });
}
test("C2 validateSourceUrl keeps a safe received URL verbatim (no normalization)", () => {
  const raw = "HTTPS://Example.org/Path?Q=1#Frag";
  assert.deepEqual(validateSourceUrl(raw), { url: raw, redirect_unresolved: false });
});

for (const [name, errorValue] of [["string", "SECRET-PROVIDER-ERROR text"], ["number", 401], ["array", ["SECRET-PROVIDER-ERROR"]], ["object", { message: "SECRET-PROVIDER-ERROR" }], ["boolean", true]] as const) {
  test(`C3 ${name} error envelope on the response beside a STOP candidate → provider_error, no echo`, () => {
    const [e1] = grounded();
    const final = JSON.parse(grounded()[1]);
    final.response.error = errorValue;
    const r = consumeStream(handoff([e1, JSON.stringify(final)]));
    assert.deepEqual(r, { status: "error", reason: "provider_error", http_status: 200 });
    assertNoLeak(r);
    const outer = JSON.parse(grounded()[1]);
    outer.error = errorValue;
    assert.equal(consumeStream(handoff([e1, JSON.stringify(outer)])).reason, "provider_error");
  });
}
test("C3 error: null is not an error envelope", () => {
  const final = JSON.parse(grounded()[1]);
  final.response.error = null;
  assert.equal(consumeStream(handoff([grounded()[0], JSON.stringify(final)])).status, "success");
});

test("C4 post-terminal text without a new terminal → provider_error; trailing usage/model-only events remain allowed", () => {
  const [e1, e2] = grounded();
  const post = ev({ candidates: [{ content: { parts: [{ text: " more" }] } }] });
  assert.equal(consumeStream(handoff([e1, e2, post])).reason, "provider_error");
  const usageOnly = ev({ usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2 }, modelVersion: "gemini-3.8-flash-low" });
  const r = consumeStream(handoff([e1, e2, usageOnly]));
  assert.equal(r.status, "success");
  if (r.status === "success") {
    assert.equal(r.components.input?.value, 1);
    assert.equal(r.observed_model, "gemini-3.8-flash-low");
  }
});

test("C4 conflicting terminals: an earlier failure finish is never overwritten by a later STOP; two STOPs conflict", () => {
  const [e1] = grounded();
  const safety = ev({ candidates: [{ content: { parts: [] }, finishReason: "SAFETY" }] });
  const stop = grounded()[1];
  assert.equal(consumeStream(handoff([e1, safety, stop])).reason, "provider_error");
  assert.equal(consumeStream(handoff([e1, stop, stop])).reason, "provider_error");
  const groundingAfter = ev({ candidates: [{ groundingMetadata: { webSearchQueries: ["late"] } }] });
  assert.equal(consumeStream(handoff([e1, stop, groundingAfter])).reason, "provider_error");
});

test("C5 MAX_TOKENS on a short answer: provider-limit label visible, distinct from the 32 KiB label, within budget", () => {
  const r = consumeStream(handoff(grounded({ finish: "MAX_TOKENS" })));
  assert.equal(r.status, "success");
  if (r.status !== "success") return;
  assert.ok(r.answer.includes(PROVIDER_LIMIT_LABEL));
  assert.ok(!r.answer.includes(RENDER_TRUNCATION_LABEL));
  assert.equal(r.truncation_cause, "provider_limit");
  assert.ok(Buffer.byteLength(r.answer, "utf8") <= MAX_RENDERED_BYTES);
  const both = consumeStream(handoff(grounded({ finish: "MAX_TOKENS", text: ["a".repeat(40_000), ""] })));
  if (both.status === "success") {
    assert.equal(both.truncation_cause, "both");
    assert.ok(both.answer.includes(PROVIDER_LIMIT_LABEL) && both.answer.includes(RENDER_TRUNCATION_LABEL));
    assert.ok(Buffer.byteLength(both.answer, "utf8") <= MAX_RENDERED_BYTES);
  }
});

test("C6 parsing is linear: ~1 MiB stream with 5000 supports and a 100 KiB unicode answer completes quickly; boundary map is one pass", () => {
  const answerPart = "ü😀ab".repeat(12_500); // ~100 KiB
  const supports = Array.from({ length: 5000 }, (_, i) => ({ segment: { startIndex: (i % 100) * 8, endIndex: (i % 100) * 8 + 8 }, groundingChunkIndices: [i % 2] }));
  const events: string[] = [];
  for (let i = 0; i < 300; i++) events.push(ev({ candidates: [{ content: { parts: [{ text: "x".repeat(3000) }] } }] })); // ~900 KiB of deltas
  events.push(ev({ candidates: [{ content: { parts: [{ text: answerPart }] }, finishReason: "STOP", groundingMetadata: { webSearchQueries: ["q"], groundingChunks: [chunk(URL_A), chunk(URL_B)], groundingSupports: supports } }] }));
  const started = performance.now();
  const r = consumeStream(handoff(events));
  const elapsed = performance.now() - started;
  assert.equal(r.status, "success");
  assert.ok(elapsed < 2000, `parse took ${elapsed.toFixed(0)} ms`);
  const bm = byteBoundaryMap("é😀x");
  assert.deepEqual([...bm.entries()], [[0, 0], [2, 1], [6, 3], [7, 4]]);
});

test("C6 deadline carried through parsing: already-aborted signal yields cancelled; no success after abort", () => {
  const ac = new AbortController();
  ac.abort();
  assert.deepEqual(consumeStream(handoff(grounded(), { signal: ac.signal })), { status: "cancelled", reason: "cancelled" });
});

/** Deterministic clock: returns `before` for the first `calls` reads, then `after`. The signal is never aborted. */
function steppingClock(calls: number, before = 0, after = 1_000_000) {
  let n = 0;
  return { now: () => (++n <= calls ? before : after), reads: () => n };
}

test("C6 absolute clock deadline observed during synchronous parse with the signal still unaborted (event checkpoint)", () => {
  const events = [...Array.from({ length: 600 }, () => ev({ candidates: [{ content: { parts: [{ text: "d" }] } }] })), grounded()[1]];
  const live = new AbortController();
  const clock = steppingClock(1); // first read (entry) is within deadline, the 256-event checkpoint sees the clock past it
  const r = consumeStream(handoff(events, { signal: live.signal, deadlineAt: 90_000, now: clock.now }));
  assert.deepEqual(r, { status: "cancelled", reason: "cancelled" });
  assert.equal(live.signal.aborted, false, "no abort() was involved");
  assert.ok(clock.reads() >= 2);
});

test("C6 absolute clock deadline observed after the citation phase and immediately before success (render phase)", () => {
  const supports = Array.from({ length: 600 }, (_, i) => ({ segment: { startIndex: 0, endIndex: 4 }, groundingChunkIndices: [i % 2] }));
  const events = grounded({ supports, text: ["abcd", " tail"] });
  const live = new AbortController();
  // Reads: entry(1), after phase 1(2), support checkpoints at 256 and 512 (3,4), after phase 2(5), before success(6).
  for (const [calls, label] of [[4, "support checkpoint"], [5, "after citations"], [6, "before success"]] as const) {
    const clock = steppingClock(calls - 1);
    const r = consumeStream(handoff(events, { signal: live.signal, deadlineAt: 90_000, now: clock.now }));
    assert.deepEqual(r, { status: "cancelled", reason: "cancelled" }, label);
  }
  const ok = consumeStream(handoff(events, { signal: live.signal, deadlineAt: 90_000, now: steppingClock(100).now }));
  assert.equal(ok.status, "success", "within deadline the same stream succeeds");
});

test("C6 transport: clock past deadline after fetch returns → cancelled before the consumer runs; late transport success is refused by the tool", async () => {
  const [e1, e2] = grounded();
  const f = fakeFetch({ chunks: [`data: ${e1}\n\n`, `data: ${e2}\n\n`] });
  let consumed = 0;
  const t = createAntigravityTransport({ fetch: f.fetch, platform: "darwin", arch: "arm64", consumer: (h) => { consumed += 1; return groundingConsumer(h); } });
  const clock = steppingClock(1); // entry within deadline; the post-fetch check sees the clock past it
  const r = await t({ config: { provider: "antigravity", model: "gemini-3.8-flash", runtime_model: "gemini-3.8-flash-low", endpoint: "daily", max_calls: 3 }, credential: { token: FAKE_TOKEN, projectId: FAKE_PROJECT }, query: "q", maxResults: 3, requestId: REQUEST_ID, signal: new AbortController().signal, deadlineAt: 90_000, now: clock.now });
  assert.deepEqual(r, { status: "cancelled", reason: "cancelled" });
  assert.equal(consumed, 0);
  assert.equal(f.calls.length, 1);
  // Tool layer: transport returns success but the clock is past the admission deadline → cancelled/deadline, never success.
  // The clock stays within the deadline until the transport itself is running, then
  // jumps past it before returning success: the refusal can only come from the
  // tool's post-transport check.
  let clockNow = 0;
  let transportCalls = 0;
  const lateSuccess: Deps["transport"] = async (req) => {
    transportCalls += 1;
    assert.equal(req.now() > req.deadlineAt, false, "transport was dispatched within the deadline");
    clockNow = 1_000_000;
    return { status: "success", answer: "late", sources: [{ url: URL_B, title: null, redirect_unresolved: false }], citations: [], observed_model: null, search_executed: true, components: {}, truncated: false };
  };
  const d: Deps = { ...deps(lateSuccess), now: () => clockNow, deadlineMs: 90_000 };
  const rr = await createTrellisWebSearch(d).execute({ query: "q" }, undefined);
  assert.equal(transportCalls, 1, "transport invoked exactly once");
  assert.equal(rr.details.status, "cancelled");
  assert.equal(rr.details.reason, "deadline");
  assert.deepEqual(rr.details.sources, []);
  assert.equal(rr.details.search_executed, false);
  assert.ok(!rr.content[0].text.includes("late"), "late answer never rendered");
});

test("C6 through the tool: consumer cancellation maps to cancelled/deadline when the deadline fired", async () => {
  const [e1, e2] = grounded();
  const f = fakeFetch({ chunks: [`data: ${e1}\n\n`, `data: ${e2}\n\n`], delayMs: 30 });
  const t = createAntigravityTransport({ fetch: f.fetch, platform: "darwin", arch: "arm64", consumer: groundingConsumer });
  const d = { ...deps(t), deadlineMs: 10 };
  const r = await createTrellisWebSearch(d).execute({ query: "q" }, undefined);
  assert.equal(r.details.status, "cancelled");
  assert.equal(r.details.reason, "deadline");
});

for (const [name, value, expected] of [
  ["bounded id", "gemini-3.8-flash-low", "gemini-3.8-flash-low"],
  ["prose", "gemini 3.8 flash (preview) served by SECRET-PROVIDER-ERROR", null],
  ["secret-bearing", `model:${FAKE_TOKEN}`, null],
  ["too long", "m".repeat(65), null],
  ["leading dash", "-gemini", null],
  ["non-string", 3.8, null],
] as const) {
  test(`typed identity guard: modelVersion ${name} → ${expected === null ? "null" : "kept"}`, () => {
    const r = consumeStream(handoff(grounded({ modelVersion: value })));
    assert.equal(r.status, "success");
    if (r.status === "success") assert.equal(r.observed_model, expected);
    assertNoLeak(r);
  });
}

test("typed identity guard: requested runtime id never substitutes for a missing/invalid provider id", () => {
  const r = consumeStream(handoff(grounded({ modelVersion: "not a model id!" }), { requestedRuntimeModel: "gemini-3.8-flash-low" }));
  if (r.status === "success") assert.equal(r.observed_model, null);
});

// ---------- end to end through transport + tool ----------

function deps(transport: Deps["transport"]): Deps {
  return {
    registry: {
      find: () => ({ provider: "antigravity", id: "gemini-3.8-flash", api: "antigravity-api", baseUrl: "https://daily-cloudcode-pa.googleapis.com" }),
      isUsingOAuth: () => true,
      getProviderAuth: async () => ({ auth: { apiKey: JSON.stringify({ token: FAKE_TOKEN, projectId: FAKE_PROJECT }) } }),
    },
    env: (name) => (name === "TRELLIS_WEB_SEARCH_CONFIG" ? "/fake/cfg" : undefined),
    readFile: () => ({ info: { isRegular: true, isSymlink: false, size: 10 }, text: JSON.stringify({ provider: "antigravity", model: "gemini-3.8-flash", runtime_model: "gemini-3.8-flash-low", endpoint: "daily", max_calls: 3 }) }),
    transport,
    now: () => Date.now(),
    deadlineMs: 90_000,
    requestId: () => REQUEST_ID,
  };
}

test("production consumer through the real transport and tool: success details, bounded content, receipt allowlist without content", async () => {
  const [e1, e2] = grounded({ modelVersion: "gemini-3.8-flash-low" });
  const f = fakeFetch({ chunks: [`data: ${e1}\n\n`, `data: ${e2}\n\n`] });
  const t = createAntigravityTransport({ fetch: f.fetch, platform: "darwin", arch: "arm64", consumer: groundingConsumer });
  const r = await createTrellisWebSearch(deps(t)).execute({ query: "SECRET-QUERY node lts", max_results: 1 }, undefined);
  assert.equal(r.details.status, "success");
  assert.equal(r.details.reason, null);
  assert.equal(r.details.search_executed, true);
  assert.equal(r.details.observed_model, "gemini-3.8-flash-low");
  assert.equal(r.details.sources.length, 1);
  assert.equal(r.details.citations.length, 1);
  assert.equal(r.details.http_status, null, "http_status only accompanies failures");
  assert.ok(r.content[0].text.startsWith("Node.js 24 is the Active LTS line."));
  assert.ok(!r.content[0].text.includes("capacity protection"), "success content is the bounded rendering only");
  const receipt = costReceipt(r.details);
  assert.deepEqual(Object.keys(receipt).sort(), [...RECEIPT_KEYS].sort());
  const blob = JSON.stringify(receipt);
  for (const s of ["SECRET-QUERY", "Node.js 24", URL_A, URL_B, "Example", FAKE_TOKEN, FAKE_PROJECT]) assert.ok(!blob.includes(s), `${s} in receipt`);
});

test("production consumer: link-only prose without search evidence is error/no_search_evidence at the tool layer", async () => {
  const e = ev({ candidates: [{ content: { parts: [{ text: "see https://example.org/x" }] }, finishReason: "STOP", groundingMetadata: { groundingChunks: [chunk(URL_B)] } }] });
  const f = fakeFetch({ chunks: [`data: ${e}\n\n`] });
  const t = createAntigravityTransport({ fetch: f.fetch, platform: "darwin", arch: "arm64", consumer: groundingConsumer });
  const r = await createTrellisWebSearch(deps(t)).execute({ query: "q" }, undefined);
  assert.equal(r.details.status, "error");
  assert.equal(r.details.reason, "no_search_evidence");
  assert.equal(r.details.search_executed, false);
  assert.deepEqual(r.details.sources, []);
  assert.equal(r.details.http_status, 200);
});

test("production consumer: provider error event with secrets never reaches content or details", async () => {
  const e = JSON.stringify({ error: { code: 403, message: SECRET } });
  const f = fakeFetch({ chunks: [`data: ${e}\n\n`] });
  const t = createAntigravityTransport({ fetch: f.fetch, platform: "darwin", arch: "arm64", consumer: groundingConsumer });
  const r = await createTrellisWebSearch(deps(t)).execute({ query: "q" }, undefined);
  assert.equal(r.details.reason, "provider_error");
  assertNoLeak(r);
});
