// Bounded single-attempt Antigravity grounding transport (Spec 047 T19).
//
// One HTTPS POST to the pinned daily endpoint with the frozen six headers and the
// frozen body; no endpoint, model or retry fallback; redirects rejected. The SSE
// stream is framed here with fixed byte/event bounds and handed to an injected
// result consumer. Grounding/result semantics (T20) live in result.ts; until a
// qualified consumer is installed the transport reports the stream as
// `unavailable/result_parser_unavailable` rather than claiming success.
//
// No Pi runtime imports. Frozen values: web-search/canary-plan.md §(c),(d).
// Attribution: ./NOTICE.

import type { Reason, Source, Citation, Components, TransportOutcome, TransportRequest, Transport } from "./index.ts";

export const DAILY_ORIGIN = "https://daily-cloudcode-pa.googleapis.com";
export const ENDPOINT_URL = `${DAILY_ORIGIN}/v1internal:streamGenerateContent?alt=sse`;
export const MAX_OUTPUT_TOKENS = 2048;
export const MAX_STREAM_BYTES = 1024 * 1024;
export const MAX_EVENT_BYTES = 128 * 1024;

export type Profile = { version: string; cl: string; os: string; arch: string; platform: "MACOS" };

/** Only the frozen canary profile is supported; any other host tuple is unsupported, never coerced. */
export const DARWIN_ARM64: Profile = { version: "2.8.0", cl: "963137146", os: "darwin", arch: "arm64", platform: "MACOS" };

export function selectProfile(platform: string, arch: string): Profile | null {
  return platform === "darwin" && arch === "arm64" ? DARWIN_ARM64 : null;
}

/** Pure header builder: no ambient env, no host reads. Key order matches the pinned plugin. */
export function buildHeaders(profile: Profile, token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    Accept: "text/event-stream",
    "User-Agent": `antigravity/hub/${profile.version} (aidev_client; os_type=${profile.os}; arch=${profile.arch}; cl=${profile.cl})`,
    "X-Goog-Api-Client": "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "Client-Metadata": JSON.stringify({ ideType: "ANTIGRAVITY", platform: profile.platform, pluginType: "GEMINI" }),
  };
}

export type BodyInput = { projectId: string; runtimeModel: string; query: string; requestId: string };

/** Frozen grounding body. Field order is fixed so the serialized bytes are reproducible. */
export function buildBody(input: BodyInput): Record<string, unknown> {
  return {
    project: input.projectId,
    model: input.runtimeModel,
    request: {
      contents: [{ role: "user", parts: [{ text: input.query }] }],
      tools: [{ googleSearch: {} }],
      generationConfig: { maxOutputTokens: MAX_OUTPUT_TOKENS },
    },
    requestType: "agent",
    userAgent: "antigravity",
    requestId: input.requestId,
  };
}

export const REQUEST_ID_PATTERN = /^agent-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** Incremental SSE framer with fixed bounds. Feed decoded text; collect `data:` payloads per event. */
export class SseFramer {
  private buffer = "";
  private decodedBytes = 0;
  readonly events: string[] = [];
  private bound: Reason | null = null;

  /**
   * Bounds are per complete frame and per remaining partial frame, never per
   * transport chunk, so identical bytes behave the same however they are split.
   * The 1 MiB bound is on total decoded bytes.
   */
  feed(chunk: string): Reason | null {
    if (this.bound) return this.bound;
    this.decodedBytes += Buffer.byteLength(chunk, "utf8");
    if (this.decodedBytes > MAX_STREAM_BYTES) return (this.bound = "stream_bound");
    this.buffer += chunk;
    let idx: number;
    while ((idx = this.buffer.search(/\r?\n\r?\n/)) !== -1) {
      const sep = this.buffer.slice(idx).match(/^\r?\n\r?\n/)![0];
      const raw = this.buffer.slice(0, idx);
      if (Buffer.byteLength(raw, "utf8") > MAX_EVENT_BYTES) return (this.bound = "stream_bound");
      this.buffer = this.buffer.slice(idx + sep.length);
      this.pushEvent(raw);
    }
    // The partial frame may end in a prefix of the delimiter (\r, \n, \r\n, \n\r, \r\n\r)
    // whose meaning is unresolved until more bytes or EOF arrive; those bytes are not
    // event bytes, so the bound is measured on the frame body only.
    if (Buffer.byteLength(SseFramer.stripDelimiterPrefix(this.buffer), "utf8") > MAX_EVENT_BYTES) return (this.bound = "stream_bound");
    return null;
  }

  private static stripDelimiterPrefix(partial: string): string {
    return partial.replace(/(\r\n\r|\n\r|\r\n|\n|\r)$/, "");
  }

  /** End of stream: a trailing frame without a blank-line terminator is still an event, and still bounded. */
  finish(): { events: string[]; trailingPartial: boolean; bound: Reason | null } {
    if (this.bound) return { events: this.events, trailingPartial: false, bound: this.bound };
    const body = SseFramer.stripDelimiterPrefix(this.buffer);
    if (Buffer.byteLength(body, "utf8") > MAX_EVENT_BYTES) {
      this.buffer = "";
      return { events: this.events, trailingPartial: true, bound: (this.bound = "stream_bound") };
    }
    const trailingPartial = body.trim().length > 0;
    if (trailingPartial) this.pushEvent(body);
    this.buffer = "";
    return { events: this.events, trailingPartial, bound: null };
  }

  private pushEvent(raw: string): void {
    const data: string[] = [];
    for (const line of raw.split(/\r?\n/)) {
      if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
    }
    if (data.length > 0) this.events.push(data.join("\n"));
  }
}

/** What the transport hands to the result consumer. Raw event payload strings; never headers or tokens. */
export type StreamHandoff = {
  events: string[];
  complete: boolean;
  trailingPartial: boolean;
  http_status: number;
  requestedRuntimeModel: string;
  maxResults: number;
  /** The combined tool/deadline signal; consumers check it at phase boundaries. */
  signal?: AbortSignal;
  /** Absolute deadline and clock; consumers poll these during synchronous work. */
  deadlineAt?: number;
  now?: () => number;
};

export type SuccessOutcome = Extract<TransportOutcome, { status: "success" }>;
export type ResultConsumer = (handoff: StreamHandoff) => TransportOutcome;

/** Placeholder consumer until T20: a completed stream is never claimed as a grounded answer. */
export const unqualifiedConsumer: ResultConsumer = () => ({ status: "unavailable", reason: "result_parser_unavailable" });

export type FetchLike = (input: string, init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal; redirect: "error" }) => Promise<Response>;

export type TransportOptions = {
  fetch: FetchLike;
  platform: string;
  arch: string;
  consumer?: ResultConsumer;
};

export function httpReason(status: number): Reason {
  if (status === 400) return "http_bad_request";
  if (status === 401 || status === 403) return "http_auth";
  if (status === 429) return "http_rate_limited";
  if (status >= 500 && status <= 599) return "http_server_error";
  return "http_other";
}

/** Fire-and-forget release: never awaited, never allowed to reject unobserved. */
function releaseBody(response: Response | undefined): void {
  if (!response?.body) return;
  try {
    void response.body.cancel().catch(() => {});
  } catch {
    // body already locked or closed
  }
}

function releaseReader(reader: ReadableStreamDefaultReader<Uint8Array>): void {
  try {
    void reader.cancel().catch(() => {});
  } catch {
    // already cancelled
  }
  try {
    reader.releaseLock();
  } catch {
    // lock already released or a read is still pending on a stalled stream
  }
}

export type Raced<T> = { kind: "value"; value: T } | { kind: "rejected" } | { kind: "aborted" };

/**
 * Race any pending transport operation against the combined signal. Handlers are
 * always attached; a value that arrives after abort is handed to `onLate` for
 * disposal (no second request, no await) and a late rejection is discarded.
 */
export function raceAbort<T>(promise: Promise<T>, signal: AbortSignal, onLate?: (value: T) => void): Promise<Raced<T>> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (outcome: Raced<T>) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", onAbort);
      resolve(outcome);
    };
    const onAbort = () => finish({ kind: "aborted" });
    promise.then(
      (value) => {
        if (settled) {
          try {
            onLate?.(value);
          } catch {
            // disposal must never throw
          }
          return;
        }
        finish({ kind: "value", value });
      },
      () => finish({ kind: "rejected" }),
    );
    if (signal.aborted) {
      finish({ kind: "aborted" });
      return;
    }
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

export function createAntigravityTransport(options: TransportOptions): Transport {
  const consumer = options.consumer ?? unqualifiedConsumer;
  return async (request: TransportRequest): Promise<TransportOutcome> => {
    const { signal } = request;
    const cancelled = (): TransportOutcome => ({ status: "cancelled", reason: "cancelled" });
    const expired = () => signal.aborted || request.now() > request.deadlineAt;
    const profile = selectProfile(options.platform, options.arch);
    if (!profile) return { status: "unavailable", reason: "unsupported_profile" };
    if (!REQUEST_ID_PATTERN.test(request.requestId)) return { status: "error", reason: "transport_error" };
    if (expired()) return cancelled();

    const body = JSON.stringify(buildBody({ projectId: request.credential.projectId, runtimeModel: request.config.runtime_model, query: request.query, requestId: request.requestId }));
    let fetchPromise: Promise<Response>;
    try {
      fetchPromise = Promise.resolve(options.fetch(ENDPOINT_URL, { method: "POST", headers: buildHeaders(profile, request.credential.token), body, signal, redirect: "error" }));
    } catch {
      return { status: "error", reason: "transport_error" };
    }
    // A fetch that never settles must not hold the result: race it; a late response is disposed.
    const fetched = await raceAbort(fetchPromise, signal, releaseBody);
    if (fetched.kind === "aborted") return cancelled();
    if (fetched.kind === "rejected") return signal.aborted ? cancelled() : { status: "error", reason: "transport_error" };
    const response = fetched.value;
    if (expired()) {
      releaseBody(response);
      return cancelled();
    }
    if (!response.ok) {
      releaseBody(response);
      return { status: "error", reason: httpReason(response.status), http_status: response.status };
    }
    if (!response.body) return { status: "error", reason: "transport_error", http_status: response.status };

    const reader = response.body.getReader();
    const onAbort = () => releaseReader(reader);
    signal.addEventListener("abort", onAbort, { once: true });
    const decoder = new TextDecoder("utf-8");
    const framer = new SseFramer();
    let complete = false;
    try {
      for (;;) {
        // Race every read against the signal so a stalled reader whose cancel never resolves cannot hold the result.
        const step = await raceAbort(reader.read(), signal);
        if (step.kind === "aborted") return cancelled();
        if (step.kind === "rejected") return signal.aborted ? cancelled() : { status: "error", reason: "transport_error", http_status: response.status };
        if (step.value.done) {
          const tail = decoder.decode();
          if (tail && framer.feed(tail)) return { status: "error", reason: "stream_bound", http_status: response.status };
          complete = true;
          break;
        }
        const bound = framer.feed(decoder.decode(step.value.value, { stream: true }));
        if (bound) return { status: "error", reason: bound, http_status: response.status };
      }
    } finally {
      signal.removeEventListener("abort", onAbort);
      releaseReader(reader);
    }
    const { events, trailingPartial, bound } = framer.finish();
    if (bound) return { status: "error", reason: bound, http_status: response.status };
    if (expired()) return cancelled();
    return consumer({ events, complete, trailingPartial, http_status: response.status, requestedRuntimeModel: request.config.runtime_model, maxResults: request.maxResults, signal, deadlineAt: request.deadlineAt, now: request.now });
  };
}

export type { Source, Citation, Components };
