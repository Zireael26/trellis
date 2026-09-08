// T18 deterministic tests: config, arguments, admission, owner boundary, cancellation.
// Run: node --experimental-strip-types --test core-rules/pi/web-search/tests/search.test.ts
// No network, no Pi runtime, no real credentials. Every dependency is injected.
import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import {
  CONFIG_ENV,
  CONFIG_MAX_BYTES,
  DAILY_ENDPOINT,
  RECEIPT_KEYS,
  costReceipt,
  createTrellisWebSearch,
  normalizeOrigin,
  parseConfig,
  parseCredential,
  raceOwner,
  readConfigFile,
  validateArgs,
  type Deps,
  type FileInfo,
  type TransportOutcome,
} from "../index.ts";

const unhandled: unknown[] = [];
process.on("unhandledRejection", (reason) => unhandled.push(reason));

const FAKE_TOKEN = "ya29.FAKE-TOKEN-DO-NOT-USE";
const FAKE_PROJECT = "fake-project-0000";
const GOOD_CONFIG = JSON.stringify({ provider: "antigravity", model: "gemini-3.8-flash", runtime_model: "gemini-3.8-flash-low", endpoint: "daily", max_calls: 3 });
const MODEL = { provider: "antigravity", id: "gemini-3.8-flash", api: "antigravity-api", baseUrl: DAILY_ENDPOINT };

type Harness = {
  deps: Deps;
  log: { envReads: string[]; fileReads: string[]; authProviders: string[]; transportCalls: number; isUsingOAuthCalls: number };
  files: Map<string, { info: FileInfo; text: string | null }>;
  env: Map<string, string>;
  setOwner(fn: () => Promise<{ auth: { apiKey?: string } } | undefined>): void;
  setTransport(fn: (req: Parameters<Deps["transport"]>[0]) => Promise<TransportOutcome>): void;
};

function harness(overrides: Partial<{ config: string | null; oauth: boolean; model: typeof MODEL | undefined; deadlineMs: number }> = {}): Harness {
  const log = { envReads: [] as string[], fileReads: [] as string[], authProviders: [] as string[], transportCalls: 0, isUsingOAuthCalls: 0 };
  const files = new Map<string, { info: FileInfo; text: string | null }>();
  const env = new Map<string, string>();
  const configText = overrides.config === undefined ? GOOD_CONFIG : overrides.config;
  if (configText !== null) {
    env.set(CONFIG_ENV, "/fake/search.json");
    files.set("/fake/search.json", { info: { isRegular: true, isSymlink: false, size: configText.length }, text: configText });
  }
  let owner: () => Promise<{ auth: { apiKey?: string } } | undefined> = async () => ({ auth: { apiKey: JSON.stringify({ token: FAKE_TOKEN, projectId: FAKE_PROJECT }) } });
  let transport: Harness["setTransport"] extends (fn: infer F) => void ? F : never = async () => ({ status: "unavailable", reason: "transport_unavailable" });
  let clock = 1_000_000;
  const deps: Deps = {
    registry: {
      find: (provider, id) => (provider === "antigravity" && id === "gemini-3.8-flash" ? (overrides.model === undefined ? MODEL : overrides.model) : undefined),
      isUsingOAuth: () => {
        log.isUsingOAuthCalls += 1;
        return overrides.oauth ?? true;
      },
      getProviderAuth: (provider) => {
        log.authProviders.push(provider);
        return owner();
      },
    },
    env: (name) => {
      log.envReads.push(name);
      return env.get(name);
    },
    readFile: (path) => {
      log.fileReads.push(path);
      return files.get(path) ?? { info: { isRegular: false, isSymlink: false, size: 0 }, text: null };
    },
    transport: (req) => {
      log.transportCalls += 1;
      return transport(req);
    },
    now: () => (clock += 7),
    deadlineMs: overrides.deadlineMs ?? 90_000,
    requestId: () => "agent-00000000-0000-4000-8000-000000000000",
  };
  return {
    deps,
    log,
    files,
    env,
    setOwner: (fn) => {
      owner = fn;
    },
    setTransport: (fn) => {
      transport = fn;
    },
  };
}

const OK = { query: "what is the current Node.js LTS", max_results: 3 };

function assertNoSecret(result: { content: { text: string }[]; details: unknown }) {
  const blob = JSON.stringify(result);
  assert.ok(!blob.includes(FAKE_TOKEN), "token leaked");
  assert.ok(!blob.includes(FAKE_PROJECT), "project id leaked");
}

// ---------- configuration ----------

test("config missing: unavailable/config_invalid, max_calls null, no owner or transport", async () => {
  const h = harness({ config: null });
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.status, "unavailable");
  assert.equal(r.details.reason, "config_invalid");
  assert.equal(r.details.max_calls, null);
  assert.equal(r.details.calls_used, null);
  assert.deepEqual(h.log.authProviders, []);
  assert.equal(h.log.transportCalls, 0);
  assert.equal(h.log.isUsingOAuthCalls, 0);
});

for (const [name, mutate] of [
  ["symlink", (f: { info: FileInfo }) => { f.info.isSymlink = true; }],
  ["not regular", (f: { info: FileInfo }) => { f.info.isRegular = false; }],
  ["oversize", (f: { info: FileInfo }) => { f.info.size = 8 * 1024 + 1; }],
] as const) {
  test(`config ${name}: config_invalid before parse`, async () => {
    const h = harness();
    mutate(h.files.get("/fake/search.json")!);
    const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
    assert.equal(r.details.reason, "config_invalid");
    assert.deepEqual(h.log.authProviders, []);
  });
}

for (const [name, text] of [
  ["unknown field", JSON.stringify({ ...JSON.parse(GOOD_CONFIG), base_url: "https://evil.example" })],
  ["missing field", JSON.stringify({ provider: "antigravity", model: "m", runtime_model: "r", endpoint: "daily" })],
  ["max_calls 0", GOOD_CONFIG.replace('"max_calls":3', '"max_calls":0')],
  ["max_calls 10", GOOD_CONFIG.replace('"max_calls":3', '"max_calls":10')],
  ["max_calls 2.5", GOOD_CONFIG.replace('"max_calls":3', '"max_calls":2.5')],
  ["wrong provider", GOOD_CONFIG.replace("antigravity", "google")],
  ["wrong endpoint", GOOD_CONFIG.replace('"daily"', '"sandbox"')],
  ["not json", "{"],
  ["array", "[]"],
] as const) {
  test(`config ${name}: rejected`, () => {
    assert.equal(parseConfig(text).ok, false);
  });
}

test("config is frozen after first read, even when later corrected", async () => {
  const h = harness({ config: null });
  const inst = createTrellisWebSearch(h.deps);
  await inst.execute(OK, undefined);
  h.env.set(CONFIG_ENV, "/fake/search.json");
  h.files.set("/fake/search.json", { info: { isRegular: true, isSymlink: false, size: GOOD_CONFIG.length }, text: GOOD_CONFIG });
  const r = await inst.execute(OK, undefined);
  assert.equal(r.details.reason, "config_invalid");
  assert.equal(h.log.fileReads.length, 0, "no file read after freeze");
});

// ---------- runtime arguments (schema bounds are advisory) ----------

for (const [name, params] of [
  ["empty query", { query: "" }],
  ["4001 code points", { query: "\u{1F600}".repeat(4001) }],
  ["query not string", { query: 5 }],
  ["max_results 0", { query: "q", max_results: 0 }],
  ["max_results 11", { query: "q", max_results: 11 }],
  ["max_results 1.5", { query: "q", max_results: 1.5 }],
  ["max_results string", { query: "q", max_results: "3" }],
  ["extra property", { query: "q", provider: "x" }],
  ["missing object", null],
] as const) {
  test(`args ${name}: error/invalid_arguments, no slot, no owner`, async () => {
    const h = harness();
    const inst = createTrellisWebSearch(h.deps);
    const r = await inst.execute(params, undefined);
    assert.equal(r.details.status, "error");
    assert.equal(r.details.reason, "invalid_arguments");
    assert.equal(inst.state().calls_used, 0);
    assert.deepEqual(h.log.authProviders, []);
  });
}

test("args: 4000 code points of astral characters is accepted", () => {
  assert.equal(validateArgs({ query: "\u{1F600}".repeat(4000) }).ok, true);
});

// ---------- admission: counter and guard ----------

test("admitted attempts consume a slot even when auth fails; budget then exhausts without owner I/O", async () => {
  const h = harness();
  h.setOwner(async () => undefined);
  const inst = createTrellisWebSearch(h.deps);
  for (let i = 1; i <= 3; i++) {
    const r = await inst.execute(OK, undefined);
    assert.equal(r.details.reason, "auth_unavailable");
    assert.equal(r.details.calls_used, i);
    assert.equal(r.details.max_calls, 3);
  }
  const r4 = await inst.execute(OK, undefined);
  assert.equal(r4.details.status, "error");
  assert.equal(r4.details.reason, "call_budget_exhausted");
  assert.equal(r4.details.calls_used, 3);
  assert.equal(h.log.authProviders.length, 3, "exhausted call made no owner request");
});

test("concurrent invocation returns error/busy without dispatch and without a slot", async () => {
  const h = harness();
  let release!: () => void;
  h.setOwner(() => new Promise((resolve) => { release = () => resolve(undefined); }));
  const inst = createTrellisWebSearch(h.deps);
  const first = inst.execute(OK, undefined);
  await Promise.resolve();
  const second = await inst.execute({ query: "second" }, undefined);
  assert.equal(second.details.reason, "busy");
  assert.equal(second.details.calls_used, 1, "busy reports the current counter, unchanged");
  release();
  const r1 = await first;
  assert.equal(r1.details.reason, "auth_unavailable");
  assert.equal(inst.state().calls_used, 1);
  assert.equal(h.log.authProviders.length, 1);
});

// ---------- registry and owner boundary ----------

test("owner lookup is exactly getProviderAuth('antigravity'); no credential env or file read", async () => {
  const h = harness();
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.deepEqual(h.log.authProviders, ["antigravity"]);
  assert.deepEqual(h.log.fileReads, ["/fake/search.json"]);
  const credentialEnv = h.log.envReads.filter((n) => /API_KEY|TOKEN|AUTH|CREDENTIAL|PROJECT_ID/i.test(n));
  assert.deepEqual(credentialEnv, []);
  assert.equal(r.details.reason, "transport_unavailable", "T18 build reaches the placeholder transport and no further");
  assert.equal(r.details.project_id_present, true);
  assertNoSecret(r);
});

test("unregistered model: unavailable/model_unregistered, no owner", async () => {
  const h = harness({ model: undefined });
  h.deps.registry.find = () => undefined;
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.reason, "model_unregistered");
  assert.deepEqual(h.log.authProviders, []);
});

test("registered baseUrl differing from daily: endpoint_mismatch, no owner", async () => {
  const h = harness({ model: { ...MODEL, baseUrl: "https://cloudcode-pa.googleapis.com" } });
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.reason, "endpoint_mismatch");
  assert.deepEqual(h.log.authProviders, []);
});

test("env override precedence ANTIGRAVITY_BASE_URL || NOAGY_BASE_URL; differing origin blocks, matching (with trailing slash) passes", async () => {
  const h = harness();
  h.env.set("NOAGY_BASE_URL", "https://daily-cloudcode-pa.sandbox.googleapis.com");
  let r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.reason, "endpoint_mismatch");
  assert.deepEqual(h.log.authProviders, []);
  h.env.set("ANTIGRAVITY_BASE_URL", `${DAILY_ENDPOINT}/`);
  r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.reason, "transport_unavailable", "ANTIGRAVITY_ wins over NOAGY_ and a matching origin passes");
});

test("non-OAuth auth mode: unsupported_auth_mode before owner", async () => {
  const h = harness({ oauth: false });
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.reason, "unsupported_auth_mode");
  assert.deepEqual(h.log.authProviders, []);
});

test("owner throws: unavailable/auth_error with no message text", async () => {
  const h = harness();
  h.setOwner(async () => { throw new Error(`OAuth refresh failed for antigravity: ${FAKE_TOKEN}`); });
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.reason, "auth_error");
  assert.ok(!JSON.stringify(r).includes("refresh failed"));
  assertNoSecret(r);
  assert.equal(h.log.transportCalls, 0);
});

for (const [name, apiKey] of [
  ["missing apiKey", undefined],
  ["not json", "not-json"],
  ["missing token", JSON.stringify({ projectId: FAKE_PROJECT })],
  ["empty projectId", JSON.stringify({ token: FAKE_TOKEN, projectId: "" })],
] as const) {
  test(`malformed credential (${name}): auth_error, no transport, no leak`, async () => {
    const h = harness();
    h.setOwner(async () => ({ auth: { apiKey } }));
    const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
    assert.equal(r.details.reason, "auth_error");
    assert.equal(h.log.transportCalls, 0);
    assertNoSecret(r);
  });
}

test("parseCredential never synthesizes a project id", () => {
  assert.equal(parseCredential(JSON.stringify({ token: "t" })), null);
});

// ---------- cancellation and deadline ----------

test("cancel while owner pending: cancelled/cancelled, late owner resolution discarded, no transport", async () => {
  const h = harness();
  let release!: () => void;
  h.setOwner(() => new Promise((resolve) => { release = () => resolve({ auth: { apiKey: JSON.stringify({ token: FAKE_TOKEN, projectId: FAKE_PROJECT }) } }); }));
  const ac = new AbortController();
  const inst = createTrellisWebSearch(h.deps);
  const pending = inst.execute(OK, ac.signal);
  await Promise.resolve();
  ac.abort();
  const r = await pending;
  assert.equal(r.details.status, "cancelled");
  assert.equal(r.details.reason, "cancelled");
  release();
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(h.log.transportCalls, 0, "late credential never dispatched");
  assert.equal(inst.state().in_flight, false);
  assert.equal(inst.state().calls_used, 1, "cancelled admitted attempt consumed its slot");
});

test("deadline while owner pending: cancelled/deadline, no transport", async () => {
  const h = harness({ deadlineMs: 20 });
  h.setOwner(() => new Promise(() => {}));
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.status, "cancelled");
  assert.equal(r.details.reason, "deadline");
  assert.equal(h.log.transportCalls, 0);
});

test("already-aborted signal: no owner request at all", async () => {
  const h = harness();
  const ac = new AbortController();
  ac.abort();
  const r = await createTrellisWebSearch(h.deps).execute(OK, ac.signal);
  assert.equal(r.details.reason, "cancelled");
  assert.deepEqual(h.log.authProviders, []);
});

test("transport receives the combined signal and a cancel mid-transport yields cancelled/cancelled", async () => {
  const h = harness();
  const ac = new AbortController();
  h.setTransport((req) => new Promise((_, reject) => {
    req.signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
  }));
  const inst = createTrellisWebSearch(h.deps);
  const pending = inst.execute(OK, ac.signal);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(h.log.transportCalls, 1);
  ac.abort();
  const r = await pending;
  assert.equal(r.details.status, "cancelled");
  assert.equal(r.details.reason, "cancelled");
});

test("raceOwner: abort wins and later resolution is ignored", async () => {
  const ac = new AbortController();
  let resolve!: (v: number) => void;
  const p = new Promise<number>((r) => { resolve = r; });
  const race = raceOwner(p, ac.signal);
  ac.abort();
  assert.deepEqual(await race, { kind: "aborted" });
  resolve(1);
  assert.deepEqual(await race, { kind: "aborted" });
});

// ---------- transport contract (injected; T19 replaces the placeholder) ----------

test("one transport call per admitted attempt with the frozen runtime model and agent-<uuid> request id", async () => {
  const h = harness();
  const seen: string[] = [];
  h.setTransport(async (req) => {
    seen.push(`${req.config.runtime_model}|${req.requestId}|${req.credential.projectId}`);
    return { status: "success", answer: "grounded answer", sources: [{ url: "https://example.org/a", title: "A", redirect_unresolved: false }], citations: [], observed_model: "gemini-3.8-flash-low", search_executed: true, components: {}, truncated: false };
  });
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(h.log.transportCalls, 1);
  assert.deepEqual(seen, [`gemini-3.8-flash-low|agent-00000000-0000-4000-8000-000000000000|${FAKE_PROJECT}`]);
  assert.equal(r.details.status, "success");
  assert.equal(r.details.request_id, "agent-00000000-0000-4000-8000-000000000000");
  assert.equal(r.content[0].text.startsWith("grounded answer"), true);
});

test("success trims sources to max_results and keeps unknown components unknown", async () => {
  const h = harness();
  h.setTransport(async () => ({
    status: "success", answer: "a", observed_model: null, search_executed: true, truncated: false, citations: [],
    sources: Array.from({ length: 7 }, (_, i) => ({ url: `https://example.org/${i}`, title: null, redirect_unresolved: false })),
    components: { output: { value: 12, presence: "observed", semantics: "candidatesTokenCount" } },
  }));
  const r = await createTrellisWebSearch(h.deps).execute({ query: "q", max_results: 2 }, undefined);
  assert.equal(r.details.sources.length, 2);
  assert.equal(r.details.components.output.value, 12);
  assert.equal(r.details.components.input.presence, "unknown");
  assert.equal(r.details.components.input.value, null);
});

// ---------- owner boundary: sync throw and late rejection ----------

test("owner throws synchronously: auth_error, guard released, no transport, no unhandled rejection", async () => {
  const h = harness();
  h.deps.registry.getProviderAuth = () => { throw new Error(`sync boom ${FAKE_TOKEN}`); };
  const inst = createTrellisWebSearch(h.deps);
  const r = await inst.execute(OK, undefined);
  assert.equal(r.details.reason, "auth_error");
  assert.equal(inst.state().in_flight, false);
  assert.equal(h.log.transportCalls, 0);
  assertNoSecret(r);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(unhandled, []);
});

test("owner rejects after abort: result stays cancelled and the late rejection is discarded, not unhandled", async () => {
  const h = harness();
  let reject!: (e: Error) => void;
  h.setOwner(() => new Promise((_, rej) => { reject = rej; }));
  const ac = new AbortController();
  const inst = createTrellisWebSearch(h.deps);
  const pending = inst.execute(OK, ac.signal);
  await Promise.resolve();
  ac.abort();
  const r = await pending;
  assert.equal(r.details.reason, "cancelled");
  reject(new Error("late failure"));
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(unhandled, []);
  assert.equal(h.log.transportCalls, 0);
});

test("raceOwner with an already-aborted signal still observes a later rejection", async () => {
  const ac = new AbortController();
  ac.abort();
  const race = raceOwner(Promise.reject(new Error("late")), ac.signal);
  assert.deepEqual(await race, { kind: "aborted" });
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(unhandled, []);
});

// ---------- endpoint normalization ----------

for (const [name, raw, expected] of [
  ["exact", DAILY_ENDPOINT, DAILY_ENDPOINT],
  ["trailing slash", `${DAILY_ENDPOINT}/`, DAILY_ENDPOINT],
  ["credentials", `https://user:pw@daily-cloudcode-pa.googleapis.com`, null],
  ["username only", `https://user@daily-cloudcode-pa.googleapis.com`, null],
  ["query", `${DAILY_ENDPOINT}/?x=1`, null],
  ["fragment", `${DAILY_ENDPOINT}#frag`, null],
  ["http", "http://daily-cloudcode-pa.googleapis.com", null],
  ["path differs", `${DAILY_ENDPOINT}/v1`, `${DAILY_ENDPOINT}/v1`],
  ["garbage", "not a url", null],
] as const) {
  test(`normalizeOrigin ${name}`, () => {
    assert.equal(normalizeOrigin(raw), expected);
  });
}

test("env override with credentials or query is endpoint_mismatch even when the host matches", async () => {
  for (const raw of [`https://u:p@daily-cloudcode-pa.googleapis.com`, `${DAILY_ENDPOINT}/?x=1`]) {
    const h = harness();
    h.env.set("ANTIGRAVITY_BASE_URL", raw);
    const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
    assert.equal(r.details.reason, "endpoint_mismatch", raw);
    assert.deepEqual(h.log.authProviders, []);
  }
});

// ---------- production config reader (real filesystem, fenced temp dir) ----------

function tmpDir(t: { after(fn: () => void): void }): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "spec047-cfg-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test("readConfigFile: regular file within bound is read; exactly 8 KiB is accepted", (t) => {
  const dir = tmpDir(t);
  const p = path.join(dir, "search.json");
  fs.writeFileSync(p, GOOD_CONFIG);
  const r = readConfigFile(fs, p);
  assert.equal(r.text, GOOD_CONFIG);
  assert.equal(r.info.isRegular, true);
  const exact = path.join(dir, "exact.json");
  fs.writeFileSync(exact, "x".repeat(CONFIG_MAX_BYTES));
  assert.equal(readConfigFile(fs, exact).text?.length, CONFIG_MAX_BYTES);
});

test("readConfigFile: 8 KiB + 1 is rejected without reading further", (t) => {
  const dir = tmpDir(t);
  const p = path.join(dir, "big.json");
  fs.writeFileSync(p, "x".repeat(CONFIG_MAX_BYTES + 1));
  const r = readConfigFile(fs, p);
  assert.equal(r.text, null);
  assert.equal(r.info.isRegular, true);
});

test("readConfigFile: symlink to a valid file is rejected (O_NOFOLLOW)", (t) => {
  const dir = tmpDir(t);
  const target = path.join(dir, "real.json");
  fs.writeFileSync(target, GOOD_CONFIG);
  const link = path.join(dir, "link.json");
  fs.symlinkSync(target, link);
  const r = readConfigFile(fs, link);
  assert.equal(r.text, null);
  assert.equal(r.info.isRegular, false);
});

test("readConfigFile: character device is rejected as not regular", () => {
  const r = readConfigFile(fs, "/dev/null");
  assert.equal(r.text, null);
  assert.equal(r.info.isRegular, false);
});

test("readConfigFile: FIFO with no writer does not block and is rejected", (t) => {
  const dir = tmpDir(t);
  const fifo = path.join(dir, "cfg.fifo");
  execFileSync("mkfifo", [fifo]);
  const started = Date.now();
  const r = readConfigFile(fs, fifo);
  assert.equal(r.text, null);
  assert.equal(r.info.isRegular, false);
  assert.ok(Date.now() - started < 1000, "must not block on the FIFO");
});

test("readConfigFile: missing path and directory are rejected", (t) => {
  const dir = tmpDir(t);
  assert.equal(readConfigFile(fs, path.join(dir, "absent.json")).text, null);
  assert.equal(readConfigFile(fs, dir).text, null);
});

test("readConfigFile: growth past the bound between fstat and read is detected by the bounded read", (t) => {
  // Deterministic stand-in for the race: fstat reports a small size, the descriptor
  // then yields more bytes than the bound. Injected fs shim; production fs semantics
  // are characterized by the cases above.
  const dir = tmpDir(t);
  const p = path.join(dir, "grow.json");
  fs.writeFileSync(p, "x".repeat(CONFIG_MAX_BYTES + 1));
  const shim = { ...fs, fstatSync: (fd: number) => ({ ...fs.fstatSync(fd), size: 10, isFile: () => true }) } as unknown as typeof fs;
  const r = readConfigFile(shim, p);
  assert.equal(r.text, null);
  assert.equal(r.info.size, CONFIG_MAX_BYTES + 1);
});

test("readConfigFile: descriptor is closed on every path", (t) => {
  const dir = tmpDir(t);
  const p = path.join(dir, "search.json");
  fs.writeFileSync(p, GOOD_CONFIG);
  const opened: number[] = [];
  const closed: number[] = [];
  const shim = {
    ...fs,
    openSync: (...args: Parameters<typeof fs.openSync>) => { const fd = fs.openSync(...args); opened.push(fd); return fd; },
    closeSync: (fd: number) => { closed.push(fd); fs.closeSync(fd); },
  } as unknown as typeof fs;
  readConfigFile(shim, p);
  const big = path.join(dir, "big.json");
  fs.writeFileSync(big, "x".repeat(CONFIG_MAX_BYTES + 1));
  readConfigFile(shim, big);
  assert.deepEqual(closed, opened);
  assert.equal(opened.length, 2);
});

// ---------- receipt projection ----------

test("cost receipt uses an explicit key allowlist and carries no query/answer/source text", async () => {
  const h = harness();
  h.setTransport(async () => ({ status: "success", answer: "SECRET-ANSWER", sources: [{ url: "https://example.org/SECRET-URL", title: "SECRET-TITLE", redirect_unresolved: false }], citations: [], observed_model: null, search_executed: true, components: {}, truncated: false }));
  const r = await createTrellisWebSearch(h.deps).execute({ query: "SECRET-QUERY" }, undefined);
  const receipt = costReceipt(r.details);
  assert.deepEqual(Object.keys(receipt).sort(), [...RECEIPT_KEYS].sort());
  const blob = JSON.stringify(receipt);
  for (const s of ["SECRET-QUERY", "SECRET-ANSWER", "SECRET-URL", "SECRET-TITLE", FAKE_TOKEN, FAKE_PROJECT]) assert.ok(!blob.includes(s), `${s} leaked into receipt`);
  assert.equal(receipt.account_binding, null);
  assert.equal(receipt.account_binding_state, "unknown");
  assert.equal(receipt.credential_owner, "pi:antigravity");
  assert.equal(receipt.capacity_protection, "advisory");
  assert.equal(receipt.dispatch_ref, null);
});

// ---------- absolute clock deadline (t20-deadline-final) ----------

test("late owner by the clock: owner resolves after the absolute deadline with the signal unaborted → cancelled/deadline, no transport", async () => {
  const h = harness();
  let reads = 0;
  h.deps.now = () => (++reads <= 2 ? 0 : 1_000_000); // reads 1-2 (started, admission) at 0; every later read is past 0 + 90 s
  const r = await createTrellisWebSearch(h.deps).execute(OK, undefined);
  assert.equal(r.details.status, "cancelled");
  assert.equal(r.details.reason, "deadline");
  assert.equal(h.log.transportCalls, 0);
  assert.equal(h.log.authProviders.length, 1, "the owner was consulted; its late answer was discarded");
});

test("clock deadline keeps the caller-cancellation reason distinct: an aborted tool signal reports cancelled, not deadline", async () => {
  const h = harness();
  let reads = 0;
  h.deps.now = () => (++reads <= 2 ? 0 : 1_000_000);
  const ac = new AbortController();
  ac.abort();
  const r = await createTrellisWebSearch(h.deps).execute(OK, ac.signal);
  assert.equal(r.details.reason, "cancelled");
});
