// Trellis opt-in Pi web search (Spec 047, SC6). Antigravity-backed Google Search
// grounding tool that any eligible Pi parent may call. Loaded explicitly with
// `pi -e <adopted>/core-rules/pi/web-search/index.ts`; never auto-discovered.
//
// This module owns registration, lazy bounded config, runtime argument bounds,
// the per-instance call counter and in-flight guard, the registry/owner boundary
// and the cancellation race. ./antigravity.ts owns the bounded single-attempt
// transport; ./result.ts (T20) owns grounding/result semantics. The transport is
// injected so every boundary is testable without Pi or the network.
//
// Design pins: specs/047-session-efficiency-cost-transparency/web-search/canary-plan.md.
// Attribution for adapted design: ./NOTICE.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createAntigravityTransport } from "./antigravity.ts";
import { groundingConsumer } from "./result.ts";

export const TOOL_NAME = "trellis_web_search";
export const SCHEMA_VERSION = "trellis-web-search/v1";
export const DAILY_ENDPOINT = "https://daily-cloudcode-pa.googleapis.com";
export const ANTIGRAVITY_API = "antigravity-api";
export const CONFIG_ENV = "TRELLIS_WEB_SEARCH_CONFIG";
export const CONFIG_MAX_BYTES = 8 * 1024;
export const QUERY_MAX_CODEPOINTS = 4000;
export const DEFAULT_DEADLINE_MS = 90_000;

export type Status = "success" | "unavailable" | "error" | "cancelled";
export type Reason =
  | "invalid_arguments"
  | "config_invalid"
  | "busy"
  | "call_budget_exhausted"
  | "model_unregistered"
  | "unsupported_auth_mode"
  | "endpoint_mismatch"
  | "auth_unavailable"
  | "auth_error"
  | "deadline"
  | "cancelled"
  | "unsupported_profile"
  | "transport_unavailable"
  | "transport_error"
  | "http_bad_request"
  | "http_auth"
  | "http_rate_limited"
  | "http_server_error"
  | "http_other"
  | "result_parser_unavailable"
  | "incomplete_stream"
  | "malformed_stream"
  | "provider_error"
  | "no_search_evidence"
  | "no_sources"
  | "no_answer"
  | "render_bound"
  | "stream_bound";

/** Why the rendered answer is shorter than the provider's: our 32 KiB bound, the provider's output limit, or both. */
export type TruncationCause = null | "render_bound" | "provider_limit" | "both";

export type SearchConfig = {
  provider: "antigravity";
  model: string;
  runtime_model: string;
  endpoint: "daily";
  max_calls: number;
};

export type Presence = "observed" | "unknown" | "unsupported";
export type Component = { value: number | null; presence: Presence; semantics: string };
export type Components = Record<"input" | "output" | "cache_read" | "cache_write" | "reasoning" | "provider_total", Component>;

export type Source = { url: string; title: string | null; redirect_unresolved: boolean };
export type Citation = { source_index: number; start: number; end: number };

export type Details = {
  schema: typeof SCHEMA_VERSION;
  status: Status;
  reason: Reason | null;
  request_id: string | null;
  provider: "antigravity";
  model: string | null;
  runtime_model: string | null;
  observed_model: string | null;
  search_executed: boolean;
  sources: Source[];
  citations: Citation[];
  observed_at: string;
  elapsed_ms: number;
  calls_used: number | null;
  max_calls: number | null;
  components: Components;
  credential_owner: "pi:antigravity";
  account_binding: null;
  account_binding_state: "unknown";
  capacity_protection: "advisory";
  dispatch_ref: null;
  project_id_present: boolean | null;
  http_status: number | null;
  truncated: boolean;
  truncation_cause: TruncationCause;
};

export type ToolResult = { content: { type: "text"; text: string }[]; details: Details };

/** Minimal registry surface used by this extension (Pi's ModelRegistry satisfies it). */
export type RegistryLike = {
  find(provider: string, modelId: string): { provider: string; id: string; api: string; baseUrl: string } | undefined;
  isUsingOAuth(model: { provider: string; id: string; api: string; baseUrl: string }): boolean;
  getProviderAuth(provider: string): Promise<{ auth: { apiKey?: string } } | undefined>;
};

export type Credential = { token: string; projectId: string };

export type TransportRequest = {
  config: SearchConfig;
  credential: Credential;
  query: string;
  maxResults: number;
  requestId: string;
  signal: AbortSignal;
  /** Absolute deadline on the injected clock, fixed at admission; polled alongside the signal. */
  deadlineAt: number;
  now: () => number;
};

export type TransportOutcome =
  | { status: "success"; answer: string; sources: Source[]; citations: Citation[]; observed_model: string | null; search_executed: boolean; components: Partial<Components>; truncated: boolean; truncation_cause?: TruncationCause }
  | { status: "unavailable" | "error" | "cancelled"; reason: Reason; http_status?: number };

export type Transport = (request: TransportRequest) => Promise<TransportOutcome>;

export type FileInfo = { isRegular: boolean; isSymlink: boolean; size: number };

export type Deps = {
  registry: RegistryLike;
  env: (name: string) => string | undefined;
  readFile: (path: string) => { info: FileInfo; text: string | null };
  transport: Transport;
  now: () => number;
  deadlineMs: number;
  requestId: () => string;
};

const REASON_TEXT: Record<Reason, string> = {
  invalid_arguments: "invalid arguments: query must be 1-4000 characters and max_results an integer 1-10",
  config_invalid: "search configuration missing or invalid (TRELLIS_WEB_SEARCH_CONFIG)",
  busy: "a search is already in flight for this extension instance",
  call_budget_exhausted: "this extension instance has used its configured search budget",
  model_unregistered: "configured Antigravity model is not registered in Pi",
  unsupported_auth_mode: "configured model is not using Pi's Antigravity OAuth owner",
  endpoint_mismatch: "an Antigravity endpoint override differs from the pinned daily endpoint",
  auth_unavailable: "Pi's Antigravity owner returned no credential",
  auth_error: "Pi's Antigravity owner failed to resolve a usable credential",
  deadline: "search deadline elapsed",
  cancelled: "search cancelled",
  unsupported_profile: "this host platform/architecture has no frozen request profile",
  transport_unavailable: "search transport is not available in this build",
  transport_error: "search request failed before a response was read",
  http_bad_request: "provider rejected the request (HTTP 400)",
  http_auth: "provider rejected the credential (HTTP 401/403)",
  http_rate_limited: "provider rate limit or quota reached (HTTP 429)",
  http_server_error: "provider server error (HTTP 5xx)",
  http_other: "provider returned an unexpected HTTP status",
  result_parser_unavailable: "provider stream received but no grounding result parser is installed",
  incomplete_stream: "provider stream ended without a terminal event",
  malformed_stream: "provider stream contained an unparseable event",
  provider_error: "provider reported an error or a non-completion stop",
  no_search_evidence: "provider returned an answer without search evidence",
  no_sources: "provider reported a search but no valid sources",
  no_answer: "provider reported a search and sources but an empty answer",
  render_bound: "grounded result could not be rendered within the 32 KiB bound without cutting a source",
  stream_bound: "provider stream exceeded a fixed bound",
};

const UNKNOWN = (semantics: string): Component => ({ value: null, presence: "unknown", semantics });

export function unknownComponents(): Components {
  return {
    input: UNKNOWN("promptTokenCount"),
    output: UNKNOWN("candidatesTokenCount"),
    cache_read: UNKNOWN("cachedContentTokenCount"),
    cache_write: UNKNOWN("not reported by provider"),
    reasoning: UNKNOWN("thoughtsTokenCount"),
    provider_total: UNKNOWN("totalTokenCount; may overlap components"),
  };
}

/** Keys allowed in a cost-only receipt. Anything else is content and must not leave the tool result. */
export const RECEIPT_KEYS = [
  "schema", "status", "reason", "request_id", "provider", "model", "runtime_model", "observed_model",
  "search_executed", "observed_at", "elapsed_ms", "calls_used", "max_calls", "components",
  "credential_owner", "account_binding", "account_binding_state", "capacity_protection", "dispatch_ref",
] as const;

export function costReceipt(details: Details): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const key of RECEIPT_KEYS) out[key] = details[key];
  return out;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isInt(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

/**
 * Strict endpoint normalization. Returns null (never a partial match) for any URL
 * that is not https, carries credentials, a query or a fragment, or fails to
 * parse. Matches the installed plugin's `assertSafeApiBaseUrl` shape
 * (origin + path, trailing slashes stripped) without its host allowlist: this
 * extension only ever compares against the single pinned daily endpoint.
 */
export function normalizeOrigin(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  if (url.username || url.password) return null;
  if (url.search || url.hash) return null;
  const path = url.pathname.replace(/\/+$/, "");
  return `${url.origin}${path === "/" ? "" : path}`;
}

export type ConfigOutcome = { ok: true; config: SearchConfig } | { ok: false };

/** Validate a config document. Unknown fields, wrong types and out-of-range budgets are all invalid. */
export function parseConfig(text: string | null): ConfigOutcome {
  if (text === null) return { ok: false };
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false };
  }
  if (!isRecord(parsed)) return { ok: false };
  const keys = Object.keys(parsed).sort();
  const expected = ["endpoint", "max_calls", "model", "provider", "runtime_model"];
  if (keys.length !== expected.length || keys.some((k, i) => k !== expected[i])) return { ok: false };
  if (parsed.provider !== "antigravity" || parsed.endpoint !== "daily") return { ok: false };
  if (typeof parsed.model !== "string" || parsed.model.length === 0 || parsed.model.length > 128) return { ok: false };
  if (typeof parsed.runtime_model !== "string" || parsed.runtime_model.length === 0 || parsed.runtime_model.length > 128) return { ok: false };
  if (!isInt(parsed.max_calls, 1, 9)) return { ok: false };
  return {
    ok: true,
    config: { provider: "antigravity", model: parsed.model, runtime_model: parsed.runtime_model, endpoint: "daily", max_calls: parsed.max_calls },
  };
}

export function loadConfig(deps: Pick<Deps, "env" | "readFile">): ConfigOutcome {
  const path = deps.env(CONFIG_ENV);
  if (!path || path.length === 0) return { ok: false };
  const file = deps.readFile(path);
  if (!file.info.isRegular || file.info.isSymlink || file.info.size > CONFIG_MAX_BYTES) return { ok: false };
  return parseConfig(file.text);
}

export type ArgsOutcome = { ok: true; query: string; maxResults: number } | { ok: false };

/** Runtime bounds; schema bounds are advisory because some provider bridges strip them. */
export function validateArgs(params: unknown): ArgsOutcome {
  if (!isRecord(params)) return { ok: false };
  const keys = Object.keys(params);
  if (keys.some((k) => k !== "query" && k !== "max_results")) return { ok: false };
  const query = params.query;
  if (typeof query !== "string") return { ok: false };
  const length = Array.from(query).length;
  if (length < 1 || length > QUERY_MAX_CODEPOINTS) return { ok: false };
  let maxResults = 5;
  if (params.max_results !== undefined) {
    if (!isInt(params.max_results, 1, 10)) return { ok: false };
    maxResults = params.max_results;
  }
  return { ok: true, query, maxResults };
}

/** Parse the owner's in-memory credential envelope. Never logs either value. */
export function parseCredential(apiKey: unknown): Credential | null {
  if (typeof apiKey !== "string" || apiKey.length === 0) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(apiKey);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  const token = parsed.token;
  const projectId = parsed.projectId;
  if (typeof token !== "string" || token.length === 0) return null;
  if (typeof projectId !== "string" || projectId.length === 0) return null;
  return { token, projectId };
}

/**
 * Race the owner's resolution against an abort signal. Pi's extension-facing
 * `getProviderAuth` accepts no signal, so a late resolution is discarded here and
 * never dispatched; the owner's own refresh is not cancelled.
 */
export function raceOwner<T>(promise: Promise<T>, signal: AbortSignal): Promise<{ kind: "resolved"; value: T } | { kind: "rejected" } | { kind: "aborted" }> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (outcome: { kind: "resolved"; value: T } | { kind: "rejected" } | { kind: "aborted" }) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", onAbort);
      resolve(outcome);
    };
    const onAbort = () => finish({ kind: "aborted" });
    // Always observe the promise so a late rejection after abort is discarded, never unhandled.
    promise.then((value) => finish({ kind: "resolved", value }), () => finish({ kind: "rejected" }));
    if (signal.aborted) {
      finish({ kind: "aborted" });
      return;
    }
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

/** Invoke the owner so that a synchronous throw becomes a rejection, never an escape. */
export function invokeOwner(registry: RegistryLike): Promise<{ auth: { apiKey?: string } } | undefined> {
  try {
    return Promise.resolve(registry.getProviderAuth("antigravity"));
  } catch {
    return Promise.reject(new Error("owner threw synchronously"));
  }
}

export type Instance = {
  execute(params: unknown, signal: AbortSignal | undefined): Promise<ToolResult>;
  /** Read-only view for tests and receipts. */
  state(): { calls_used: number; max_calls: number | null; config_state: "unread" | "valid" | "invalid"; in_flight: boolean };
};

export function createTrellisWebSearch(deps: Deps): Instance {
  let configState: "unread" | "valid" | "invalid" = "unread";
  let config: SearchConfig | null = null;
  let callsUsed = 0;
  let inFlight = false;

  function ensureConfig(): SearchConfig | null {
    if (configState === "unread") {
      const outcome = loadConfig(deps);
      configState = outcome.ok ? "valid" : "invalid";
      config = outcome.ok ? outcome.config : null;
    }
    return config;
  }

  function finish(started: number, status: Status, reason: Reason | null, extra: Partial<Details> = {}, text?: string): ToolResult {
    const details: Details = {
      schema: SCHEMA_VERSION,
      status,
      reason,
      request_id: null,
      provider: "antigravity",
      model: config?.model ?? null,
      runtime_model: config?.runtime_model ?? null,
      observed_model: null,
      search_executed: false,
      sources: [],
      citations: [],
      observed_at: new Date(deps.now()).toISOString(),
      elapsed_ms: Math.max(0, deps.now() - started),
      calls_used: configState === "valid" ? callsUsed : null,
      max_calls: config?.max_calls ?? null,
      components: unknownComponents(),
      credential_owner: "pi:antigravity",
      account_binding: null,
      account_binding_state: "unknown",
      capacity_protection: "advisory",
      dispatch_ref: null,
      project_id_present: null,
      http_status: null,
      truncated: false,
      truncation_cause: null,
      ...extra,
    };
    // A rendered success answer is emitted verbatim: result.ts already bounds it at
    // 32 KiB including source formatting; budget/protection live in details.
    if (text !== undefined) return { content: [{ type: "text", text }], details };
    const body = reason ? `${TOOL_NAME}: ${status}/${reason} — ${REASON_TEXT[reason]}` : `${TOOL_NAME}: ${status}`;
    const budget = details.max_calls === null ? "budget unknown" : `calls ${details.calls_used}/${details.max_calls}`;
    return { content: [{ type: "text", text: `${body} (${budget}; capacity protection: advisory)` }], details };
  }

  async function execute(params: unknown, toolSignal: AbortSignal | undefined): Promise<ToolResult> {
    const started = deps.now();
    const args = validateArgs(params);
    if (!args.ok) return finish(started, "error", "invalid_arguments");
    const cfg = ensureConfig();
    if (!cfg) return finish(started, "unavailable", "config_invalid");
    // Guard first: busy is not an admitted attempt and consumes no slot.
    if (inFlight) return finish(started, "error", "busy");
    if (callsUsed >= cfg.max_calls) return finish(started, "error", "call_budget_exhausted");
    // Admission: claim the guard and one slot atomically (synchronous section).
    inFlight = true;
    callsUsed += 1;
    // Two views of one 90 s deadline: the timer signal (observed by async I/O) and an
    // absolute clock deadline (polled during synchronous work where a timer callback
    // cannot run). Both are fixed here at admission.
    const deadlineAt = deps.now() + deps.deadlineMs;
    const deadline = AbortSignal.timeout(deps.deadlineMs);
    const combined = toolSignal ? AbortSignal.any([toolSignal, deadline]) : deadline;
    const expired = () => deps.now() > deadlineAt;
    const abortReason = (): Reason => (toolSignal?.aborted ? "cancelled" : "deadline");
    try {
      const model = deps.registry.find("antigravity", cfg.model);
      if (!model || model.api !== ANTIGRAVITY_API) return finish(started, "unavailable", "model_unregistered");
      if (normalizeOrigin(model.baseUrl) !== DAILY_ENDPOINT) return finish(started, "unavailable", "endpoint_mismatch");
      const override = deps.env("ANTIGRAVITY_BASE_URL") || deps.env("NOAGY_BASE_URL");
      if (override && override.trim().length > 0 && normalizeOrigin(override.trim()) !== DAILY_ENDPOINT) {
        return finish(started, "unavailable", "endpoint_mismatch");
      }
      if (!deps.registry.isUsingOAuth(model)) return finish(started, "unavailable", "unsupported_auth_mode");
      if (combined.aborted) return finish(started, "cancelled", abortReason());
      const owner = await raceOwner(invokeOwner(deps.registry), combined);
      if (owner.kind === "aborted") return finish(started, "cancelled", abortReason());
      if (owner.kind === "rejected") return finish(started, "unavailable", "auth_error");
      if (owner.value === undefined) return finish(started, "unavailable", "auth_unavailable");
      const credential = parseCredential(owner.value.auth?.apiKey);
      if (!credential) return finish(started, "unavailable", "auth_error");
      // Owner may have returned late by the clock even if the timer callback has not run yet.
      if (combined.aborted || expired()) return finish(started, "cancelled", abortReason(), { project_id_present: true });
      const requestId = deps.requestId();
      let outcome: TransportOutcome;
      try {
        outcome = await deps.transport({ config: cfg, credential, query: args.query, maxResults: args.maxResults, requestId, signal: combined, deadlineAt, now: deps.now });
      } catch {
        outcome = combined.aborted ? { status: "cancelled", reason: abortReason() } : { status: "error", reason: "transport_error" };
      }
      if (outcome.status !== "success") {
        const reason = outcome.status === "cancelled" ? abortReason() : outcome.reason;
        return finish(started, outcome.status, reason, { request_id: requestId, project_id_present: true, http_status: outcome.http_status ?? null });
      }
      // Fail closed: a success that arrives after the absolute deadline is not a success.
      if (combined.aborted || expired()) return finish(started, "cancelled", abortReason(), { request_id: requestId, project_id_present: true });
      const sources = outcome.sources.slice(0, args.maxResults);
      return finish(
        started,
        "success",
        null,
        {
          request_id: requestId,
          project_id_present: true,
          observed_model: outcome.observed_model,
          search_executed: outcome.search_executed,
          sources,
          citations: outcome.citations,
          components: { ...unknownComponents(), ...outcome.components },
          truncated: outcome.truncated,
          truncation_cause: outcome.truncation_cause ?? (outcome.truncated ? "render_bound" : null),
        },
        outcome.answer,
      );
    } finally {
      inFlight = false;
    }
  }

  return {
    execute,
    state: () => ({ calls_used: callsUsed, max_calls: config?.max_calls ?? null, config_state: configState, in_flight: inFlight }),
  };
}

/** Literal JSON schema. Bounds here are advisory; `validateArgs` is authoritative. */
export const TOOL_SCHEMA = {
  type: "object",
  properties: {
    query: { type: "string", minLength: 1, maxLength: QUERY_MAX_CODEPOINTS, description: "Search query text. Sent to Google Search grounding as task data; URLs are treated as text, never fetched by this tool." },
    max_results: { type: "integer", minimum: 1, maximum: 10, description: "Maximum sources to return (default 5)." },
  },
  required: ["query"],
  additionalProperties: false,
} as const;

/**
 * Bounded, descriptor-based config read: open with O_NOFOLLOW (symlink → ELOOP →
 * invalid) and O_NONBLOCK (a FIFO or device never blocks), fstat the OPEN
 * descriptor (no path re-resolution, so replacement after open is irrelevant),
 * require a regular file within bound, then read at most CONFIG_MAX_BYTES + 1
 * bytes so growth after fstat is detected instead of read unbounded. The
 * descriptor is always closed. This reader is used for the config path only.
 */
export function readConfigFile(fs: typeof import("node:fs"), path: string): { info: FileInfo; text: string | null } {
  const invalid = { info: { isRegular: false, isSymlink: false, size: 0 } as FileInfo, text: null };
  let fd: number | undefined;
  try {
    fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const st = fs.fstatSync(fd);
    const info: FileInfo = { isRegular: st.isFile(), isSymlink: false, size: st.size };
    if (!info.isRegular || info.size > CONFIG_MAX_BYTES) return { info, text: null };
    const buffer = Buffer.alloc(CONFIG_MAX_BYTES + 1);
    let total = 0;
    while (total < buffer.length) {
      const n = fs.readSync(fd, buffer, total, buffer.length - total, total);
      if (n === 0) break;
      total += n;
    }
    if (total > CONFIG_MAX_BYTES) return { info: { ...info, size: total }, text: null };
    return { info, text: buffer.subarray(0, total).toString("utf8") };
  } catch {
    return invalid;
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
        // already closed or invalid descriptor; nothing to release
      }
    }
  }
}

/** Production dependencies. File I/O is limited to the operator-selected config path. */
export async function productionDeps(ctx: ExtensionContext): Promise<Deps> {
  const fs = await import("node:fs");
  const crypto = await import("node:crypto");
  return {
    registry: ctx.modelRegistry as unknown as RegistryLike,
    env: (name) => process.env[name],
    readFile: (path) => readConfigFile(fs, path),
    transport: createAntigravityTransport({ fetch: (url, init) => globalThis.fetch(url, init), platform: process.platform, arch: process.arch, consumer: groundingConsumer }),
    now: () => Date.now(),
    deadlineMs: DEFAULT_DEADLINE_MS,
    requestId: () => `agent-${crypto.randomUUID()}`,
  };
}

export default function trellisWebSearchExtension(pi: ExtensionAPI): void {
  let instance: Promise<Instance> | undefined;
  pi.registerTool({
    name: TOOL_NAME,
    label: "Trellis web search (Antigravity)",
    description:
      "Opt-in Google Search grounding through Pi's existing Antigravity credential owner. Returns a grounded answer with source URLs and citations. Does not fetch URLs, run code or browse; inspect sources separately when required. Per-instance call budget applies.",
    parameters: TOOL_SCHEMA as never,
    // "parallel" so Pi does not queue overlapping calls; the instance's own
    // in-flight guard is then the single admission point and returns error/busy.
    // No concurrency is introduced beyond that guard.
    executionMode: "parallel",
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      instance ??= productionDeps(ctx).then(createTrellisWebSearch);
      const result = await (await instance).execute(params, signal);
      return { content: result.content, details: result.details };
    },
  });
}
