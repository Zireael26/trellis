// Grounding result semantics (Spec 047 T20). A pure consumer for the framed SSE
// events produced by ./antigravity.ts. Decides success only on explicit provider
// search evidence plus valid sources plus a nonempty answer; everything else is a
// fixed, content-free reason. Never echoes provider error fields or raw events.
//
// Offsets: provider groundingSupports segments are interpreted as UTF-8 byte
// offsets into the accumulated answer (Gemini API semantics). They are validated
// against code-point boundaries and, when `segment.text` is present, against the
// sliced text; every valid citation is then exposed in JS string (UTF-16 code
// unit) indices into the rendered text, whose prefix is the answer. Invalid
// offsets leave the source uncoupled; no citation is ever fabricated.
//
// Work is linear in stream size and checks the combined deadline signal at phase
// boundaries so a large but valid stream cannot outlive the 90 s deadline.
// No Pi runtime imports. Attribution for the adapted shape: ./NOTICE.

import type { Citation, Component, Components, Source, TransportOutcome, TruncationCause } from "./index.ts";
import type { ResultConsumer, StreamHandoff } from "./antigravity.ts";

export const MAX_INTERNAL_SOURCES = 20;
export const MAX_RENDERED_BYTES = 32 * 1024;
export const MIN_ANSWER_BYTES = 256;
export const RENDER_TRUNCATION_LABEL = "\n\n[answer truncated: 32 KiB rendered bound]";
export const PROVIDER_LIMIT_LABEL = "\n\n[answer ended at the provider output limit]";
/** Same bytes as RENDER_TRUNCATION_LABEL; name retained for earlier receipts. */
export const TRUNCATION_LABEL = RENDER_TRUNCATION_LABEL;
export const MODEL_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const GROUNDING_REDIRECT_HOST = /(^|\.)vertexaisearch\.cloud\.google\.com$/i;
const CONTROL_CHARS = /[\x00-\x1F\x7F]/;
const CHECKPOINT_EVERY = 256;

type Rec = Record<string, unknown>;
const isRec = (v: unknown): v is Rec => typeof v === "object" && v !== null && !Array.isArray(v);
const isStr = (v: unknown): v is string => typeof v === "string";

export type ParsedEvent = {
  /** Any present, non-null `error` member on the outer or inner envelope, whatever its shape. */
  error: boolean;
  text: string;
  hasContent: boolean;
  finishReason: string | null;
  chunks: string[] | null;
  chunkTitles: (string | null)[];
  supports: { start: number | null; end: number | null; text: string | null; indices: number[] }[];
  queries: string[];
  usage: Rec | null;
  modelVersion: string | null;
};

/** Parse one framed event payload. Returns null for JSON that is not an object. */
export function parseEvent(payload: string): ParsedEvent | null {
  let raw: unknown;
  try {
    raw = JSON.parse(payload);
  } catch {
    return null;
  }
  if (!isRec(raw)) return null;
  const data = isRec(raw.response) ? raw.response : raw;
  const present = (o: Rec) => Object.prototype.hasOwnProperty.call(o, "error") && o.error !== null && o.error !== undefined;
  const out: ParsedEvent = { error: present(raw) || present(data), text: "", hasContent: false, finishReason: null, chunks: null, chunkTitles: [], supports: [], queries: [], usage: null, modelVersion: null };
  const candidate = Array.isArray(data.candidates) && isRec(data.candidates[0]) ? data.candidates[0] : null;
  if (candidate) {
    const parts = isRec(candidate.content) && Array.isArray(candidate.content.parts) ? candidate.content.parts : [];
    for (const part of parts) {
      if (isRec(part) && isStr(part.text) && part.thought !== true) {
        out.text += part.text;
        out.hasContent = true;
      }
    }
    if (isStr(candidate.finishReason) && candidate.finishReason.length > 0) out.finishReason = candidate.finishReason;
    const gm = isRec(candidate.groundingMetadata) ? candidate.groundingMetadata : null;
    if (gm) {
      out.hasContent = true;
      if (Array.isArray(gm.groundingChunks)) {
        out.chunks = gm.groundingChunks.map((c) => (isRec(c) && isRec(c.web) && isStr(c.web.uri) ? c.web.uri : ""));
        out.chunkTitles = gm.groundingChunks.map((c) => (isRec(c) && isRec(c.web) && isStr(c.web.title) ? c.web.title : null));
      }
      if (Array.isArray(gm.groundingSupports)) {
        for (const s of gm.groundingSupports) {
          if (!isRec(s)) continue;
          const seg = isRec(s.segment) ? s.segment : {};
          const indices = Array.isArray(s.groundingChunkIndices) ? s.groundingChunkIndices.filter((i): i is number => Number.isInteger(i) && (i as number) >= 0) : [];
          out.supports.push({
            start: Number.isInteger(seg.startIndex) ? (seg.startIndex as number) : seg.startIndex === undefined ? 0 : null,
            end: Number.isInteger(seg.endIndex) ? (seg.endIndex as number) : null,
            text: isStr(seg.text) ? seg.text : null,
            indices,
          });
        }
      }
      if (Array.isArray(gm.webSearchQueries)) out.queries = gm.webSearchQueries.filter((q): q is string => isStr(q) && q.trim().length > 0);
    }
  }
  if (isRec(data.usageMetadata)) out.usage = data.usageMetadata;
  // Typed identity guard: only a bounded identifier shape is accepted; prose or
  // secret-bearing values stay null so nothing arbitrary reaches cost receipts.
  if (isStr(data.modelVersion) && MODEL_ID_PATTERN.test(data.modelVersion)) out.modelVersion = data.modelVersion;
  return out;
}

/**
 * Accept only http(s) URLs with no userinfo syntax in the raw authority (an empty
 * `@` is rejected too), no surrounding whitespace and no control characters. The
 * received string is kept verbatim; nothing is normalized or fetched.
 */
export function validateSourceUrl(raw: string): { url: string; redirect_unresolved: boolean } | null {
  if (!raw || raw.length > 2048 || raw !== raw.trim() || CONTROL_CHARS.test(raw)) return null;
  const scheme = raw.match(/^(https?):\/\//i);
  if (!scheme) return null;
  const authority = raw.slice(scheme[0].length).split(/[/?#]/, 1)[0];
  if (authority.length === 0 || authority.includes("@")) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  if (u.username || u.password) return null;
  return { url: raw, redirect_unresolved: GROUNDING_REDIRECT_HOST.test(u.hostname) };
}

function counter(value: unknown, semantics: string): Component {
  if (typeof value === "number" && Number.isInteger(value) && value >= 0 && Number.isFinite(value)) return { value, presence: "observed", semantics };
  return { value: null, presence: "unknown", semantics };
}

/** Presence-aware usage mapping from the LAST usageMetadata seen (cumulative per event; never summed). */
export function mapUsage(usage: Rec | null): Partial<Components> {
  if (!usage) return {};
  return {
    input: counter(usage.promptTokenCount, "promptTokenCount"),
    output: counter(usage.candidatesTokenCount, "candidatesTokenCount"),
    cache_read: counter(usage.cachedContentTokenCount, "cachedContentTokenCount"),
    reasoning: counter(usage.thoughtsTokenCount, "thoughtsTokenCount"),
    provider_total: counter(usage.totalTokenCount, "totalTokenCount; may overlap components"),
    cache_write: { value: null, presence: "unsupported", semantics: "not reported by provider" },
  };
}

/** One linear pass: UTF-8 byte offset → JS index for every code-point boundary. */
export function byteBoundaryMap(text: string): Map<number, number> {
  const map = new Map<number, number>();
  let bytes = 0;
  let i = 0;
  while (i < text.length) {
    map.set(bytes, i);
    const cp = text.codePointAt(i)!;
    bytes += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    i += cp >= 0x10000 ? 2 : 1;
  }
  map.set(bytes, i);
  return map;
}

/** Single-offset lookup built on the boundary map (tests and readers). */
export function byteOffsetToIndex(text: string, byteOffset: number): number | null {
  return byteOffset < 0 ? null : byteBoundaryMap(text).get(byteOffset) ?? null;
}

/** Longest prefix of `text` that fits `budget` bytes, cut on a code-point boundary. */
function prefixWithinBytes(text: string, budget: number): string {
  let keep = 0;
  let bytes = 0;
  while (keep < text.length) {
    const cp = text.codePointAt(keep)!;
    const size = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    if (bytes + size > budget) break;
    bytes += size;
    keep += cp >= 0x10000 ? 2 : 1;
  }
  return text.slice(0, keep);
}

function sourceLine(s: Source, n: number): string {
  return `${n}. ${s.title ? `${s.title} — ` : ""}${s.url}${s.redirect_unresolved ? " (grounding redirect, unresolved)" : ""}`;
}

export type Rendered = { text: string; sources: Source[]; citations: Citation[]; truncation: TruncationCause };

/**
 * Render answer + sources within MAX_RENDERED_BYTES, counting every byte this
 * extension emits (answer, both labels, source block). Source lines are never cut:
 * whole trailing sources are dropped until a nonempty answer fits, and the exposed
 * source list and citations are reconciled to what is actually rendered.
 * Returns null only if not even one source line fits beside a minimal answer.
 */
export function render(answer: string, sources: Source[], citations: Citation[], providerLimited: boolean): Rendered | null {
  const bytes = (s: string) => Buffer.byteLength(s, "utf8");
  const answerBytes = bytes(answer);
  const limitLabel = providerLimited ? PROVIDER_LIMIT_LABEL : "";
  const fixed = bytes(limitLabel);
  const minAnswer = Math.min(answerBytes, MIN_ANSWER_BYTES);
  const lines = sources.map((s, i) => sourceLine(s, i + 1));
  const blockFor = (n: number) => (n === 0 ? "" : `\n\nSources:\n${lines.slice(0, n).join("\n")}`);
  let keep = sources.length;
  // Drop whole trailing sources until either everything fits, or a truncated
  // answer of at least MIN_ANSWER_BYTES fits beside the remaining sources.
  while (keep > 0) {
    const blockBytes = bytes(blockFor(keep));
    if (answerBytes + fixed + blockBytes <= MAX_RENDERED_BYTES) break;
    if (minAnswer + bytes(RENDER_TRUNCATION_LABEL) + fixed + blockBytes <= MAX_RENDERED_BYTES) break;
    keep -= 1;
  }
  if (keep === 0 && sources.length > 0) return null;
  const block = blockFor(keep);
  let body = answer;
  let cits = citations.filter((c) => c.source_index < keep);
  let truncation: TruncationCause = providerLimited ? "provider_limit" : null;
  if (answerBytes + fixed + bytes(block) > MAX_RENDERED_BYTES) {
    const budget = MAX_RENDERED_BYTES - bytes(RENDER_TRUNCATION_LABEL) - fixed - bytes(block);
    if (budget < minAnswer) return null;
    body = prefixWithinBytes(answer, budget);
    cits = cits.filter((c) => c.end <= body.length);
    truncation = providerLimited ? "both" : "render_bound";
    body += RENDER_TRUNCATION_LABEL;
  }
  return { text: body + limitLabel + block, sources: sources.slice(0, keep), citations: cits, truncation };
}

export function consumeStream(handoff: StreamHandoff): TransportOutcome {
  const signal = handoff.signal;
  // Deadline is polled on the injected clock as well as the signal: a timer callback
  // cannot fire while this synchronous parse holds the event loop.
  const expired = () => Boolean(signal?.aborted) || (handoff.now !== undefined && handoff.deadlineAt !== undefined && handoff.now() > handoff.deadlineAt);
  const err = (reason: Extract<TransportOutcome, { status: "error" }>["reason"]): TransportOutcome => ({ status: "error", reason, http_status: handoff.http_status });
  const cancelled = (): TransportOutcome => ({ status: "cancelled", reason: "cancelled" });
  if (expired()) return cancelled();
  if (!handoff.complete) return err("incomplete_stream");

  // Phase 1: parse events; enforce error envelopes and terminal ordering.
  let answer = "";
  const sources: Source[] = [];
  const indexByUrl = new Map<string, number>();
  let currentMap: (number | null)[] = [];
  const supports: { start: number | null; end: number | null; text: string | null; globals: number[] }[] = [];
  let searchExecuted = false;
  let usage: Rec | null = null;
  let observedModel: string | null = null;
  let terminal: string | null = null;
  let eventCount = 0;
  for (const payload of handoff.events) {
    if (++eventCount % CHECKPOINT_EVERY === 0 && expired()) return cancelled();
    const e = parseEvent(payload);
    if (!e) return err("malformed_stream");
    if (e.error) return err("provider_error");
    // After the terminal event only usage/model metadata may follow; any further
    // content, grounding or a second finishReason is a terminal conflict.
    if (terminal !== null && (e.hasContent || e.finishReason !== null)) return err("provider_error");
    if (e.finishReason !== null) terminal = e.finishReason;
    answer += e.text;
    if (e.chunks) {
      currentMap = e.chunks.map((uri, i) => {
        const valid = validateSourceUrl(uri);
        if (!valid) return null;
        const existing = indexByUrl.get(valid.url);
        if (existing !== undefined) return existing;
        if (sources.length >= MAX_INTERNAL_SOURCES) return null;
        const title = e.chunkTitles[i] ?? null;
        sources.push({ url: valid.url, title: title && !CONTROL_CHARS.test(title) ? title.slice(0, 256) : null, redirect_unresolved: valid.redirect_unresolved });
        indexByUrl.set(valid.url, sources.length - 1);
        return sources.length - 1;
      });
    }
    for (const s of e.supports) {
      const globals = s.indices.map((i) => currentMap[i] ?? null).filter((g): g is number => g !== null);
      supports.push({ start: s.start, end: s.end, text: s.text, globals });
    }
    if (e.queries.length > 0) searchExecuted = true;
    if (e.usage) usage = e.usage;
    if (e.modelVersion) observedModel = e.modelVersion;
  }
  if (eventCount === 0 || terminal === null) return err("incomplete_stream");
  if (terminal !== "STOP" && terminal !== "MAX_TOKENS") return err("provider_error");
  if (!searchExecuted) return err("no_search_evidence");
  if (sources.length === 0) return err("no_sources");
  if (answer.trim().length === 0) return err("no_answer");
  if (expired()) return cancelled();

  // Phase 2: citations, linear in answer + supports.
  const exposed = sources.slice(0, handoff.maxResults);
  const boundaries = byteBoundaryMap(answer);
  const answerBytes = Buffer.byteLength(answer, "utf8");
  const seen = new Set<string>();
  const citations: Citation[] = [];
  let n = 0;
  for (const s of supports) {
    if (++n % CHECKPOINT_EVERY === 0 && expired()) return cancelled();
    if (s.start === null || s.end === null || s.start >= s.end || s.end > answerBytes) continue;
    const start = boundaries.get(s.start);
    const end = boundaries.get(s.end);
    if (start === undefined || end === undefined) continue;
    if (s.text !== null && answer.slice(start, end) !== s.text) continue;
    for (const g of s.globals) {
      if (g >= exposed.length) continue;
      const key = `${g}:${start}:${end}`;
      if (seen.has(key)) continue;
      seen.add(key);
      citations.push({ source_index: g, start, end });
    }
  }
  if (expired()) return cancelled();

  // Phase 3: bounded rendering, reconciled sources/citations.
  const rendered = render(answer, exposed, citations, terminal === "MAX_TOKENS");
  if (!rendered) return err("render_bound");
  // Immediately before success: rendering was the last expensive phase.
  if (expired()) return cancelled();
  return {
    status: "success",
    answer: rendered.text,
    sources: rendered.sources,
    citations: rendered.citations,
    observed_model: observedModel,
    search_executed: true,
    components: mapUsage(usage),
    truncated: rendered.truncation !== null,
    truncation_cause: rendered.truncation,
  };
}

export const groundingConsumer: ResultConsumer = consumeStream;
