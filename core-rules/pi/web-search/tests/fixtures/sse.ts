// Synthetic SSE / fetch fixtures for transport tests. No network, no timers unless asked.
// Payloads are content-free placeholders; grounding semantics are T20's concern.

export const FAKE_TOKEN = "ya29.FAKE-TRANSPORT-TOKEN";
export const FAKE_PROJECT = "fake-project-1111";
export const REQUEST_ID = "agent-11111111-2222-4333-8444-555555555555";

/** One Cloud Code Assist style frame wrapping a Gemini response object. */
export function frame(payload: unknown, sep = "\n\n"): string {
  return `data: ${JSON.stringify({ response: payload })}${sep}`;
}

export const TEXT_EVENT = { candidates: [{ content: { role: "model", parts: [{ text: "placeholder text" }] } }] };
export const FINAL_EVENT = { candidates: [{ content: { role: "model", parts: [{ text: " done" }] }, finishReason: "STOP" }], usageMetadata: { promptTokenCount: 5, candidatesTokenCount: 3, totalTokenCount: 8 }, modelVersion: "gemini-3.8-flash-low" };

export type Recorded = { url: string; init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal; redirect: string } };

export type FakeFetchOptions = {
  status?: number;
  /** Byte chunks to emit; strings are UTF-8 encoded. */
  chunks?: (string | Uint8Array)[];
  /** If true the stream never ends after the chunks (stalled reader). */
  stall?: boolean;
  /** Throw instead of returning a response (network failure). */
  networkError?: boolean;
  /** Reject once the request signal aborts (like undici does). */
  honorSignal?: boolean;
  /** Error body for non-2xx (must never surface). */
  errorBody?: string;
  /** Delay before responding, ms. */
  delayMs?: number;
  /** fetch never settles; `release()` resolves it later with the configured response. */
  neverSettle?: boolean;
  /** The stream's underlying cancel() never resolves. */
  cancelNeverResolves?: boolean;
};

export type FakeFetch = {
  fetch: (url: string, init: Recorded["init"]) => Promise<Response>;
  calls: Recorded[];
  cancelled: () => boolean;
  bodyReads: () => number;
  /** For neverSettle: settle the pending fetch now. */
  release: () => void;
};

export function fakeFetch(options: FakeFetchOptions = {}): FakeFetch {
  const calls: Recorded[] = [];
  let cancelled = false;
  let bodyReads = 0;
  let release: () => void = () => {};
  const encoder = new TextEncoder();
  const onCancel = () => {
    cancelled = true;
    if (options.cancelNeverResolves) return new Promise<void>(() => {});
    return undefined;
  };
  const fetch = async (url: string, init: Recorded["init"]): Promise<Response> => {
    calls.push({ url, init });
    if (options.neverSettle) await new Promise<void>((resolve) => { release = resolve; });
    if (options.delayMs) await new Promise((resolve) => setTimeout(resolve, options.delayMs));
    if (options.networkError) throw new TypeError("fetch failed");
    if (options.honorSignal && init.signal.aborted) throw new DOMException("aborted", "AbortError");
    const status = options.status ?? 200;
    if (status < 200 || status >= 300) {
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encoder.encode(options.errorBody ?? `{"error":{"message":"SECRET-ERROR-BODY ${FAKE_TOKEN}"}}`));
          controller.close();
        },
        cancel: onCancel,
      });
      return new Response(stream, { status, headers: { "content-type": "application/json" } });
    }
    const chunks = options.chunks ?? [];
    let index = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (index < chunks.length) {
          bodyReads += 1;
          const c = chunks[index++];
          controller.enqueue(typeof c === "string" ? encoder.encode(c) : c);
          return;
        }
        if (options.stall) return new Promise<void>(() => {}); // never resolves
        controller.close();
      },
      cancel: onCancel,
    });
    return new Response(stream, { status, headers: { "content-type": "text/event-stream" } });
  };
  return { fetch, calls, cancelled: () => cancelled, bodyReads: () => bodyReads, release: () => release() };
}

/** Split a string into byte chunks at arbitrary offsets (including mid-multibyte). */
export function byteChunks(text: string, sizes: number[]): Uint8Array[] {
  const bytes = new TextEncoder().encode(text);
  const out: Uint8Array[] = [];
  let offset = 0;
  for (const size of sizes) {
    out.push(bytes.subarray(offset, offset + size));
    offset += size;
    if (offset >= bytes.length) break;
  }
  if (offset < bytes.length) out.push(bytes.subarray(offset));
  return out;
}
