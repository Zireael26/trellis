/**
 * opencode-go-2 — second OpenCode Go account as an independent provider.
 *
 * Why a provider rather than key rotation: pi's auth.json is keyed by provider
 * name, one credential each, and a rotating `!command` would be invisible to
 * the quota resolver — it would report headroom for an account it is not using,
 * which is a fallback indistinguishable from success. Two providers means the
 * resolver sees two lanes with separate quotas and routes on real headroom.
 *
 * The model list is cloned from the on-disk opencode-go catalogue rather than
 * hardcoded, so it cannot drift from account 1. modelRegistry is not available
 * on ExtensionAPI at factory time — it lives on ExtensionContext — so the
 * catalogue is read from models-store.json directly.
 *
 * Muse Spark 1.3 keeps its Responses wire (the catalogue may carry an older
 * Muse entry). The 2026-10-16 owner probes also authorize Argon on Google's
 * generateContent wire and GLM Flash on Chat Completions, both under the Go
 * inference endpoint. Their per-request OpenCode session header is derived
 * from the live session, never baked into catalogue metadata.
 */
const MODEL_ID = "muse-spark-1.3-contributor";
const MODEL_NAME = "Muse Spark 1.3 Contributor";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { streamSimple } from "@earendil-works/pi-ai/compat";

function opencodeGoModels(): any[] {
  const store = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "models-store.json");
  const walk = (o: any): any => {
    if (o && typeof o === "object") {
      if (o["opencode-go"]?.models) return o["opencode-go"].models;
      for (const v of Object.values(o)) {
        const r = walk(v);
        if (r) return r;
      }
    }
    return null;
  };
  try {
    return walk(JSON.parse(readFileSync(store, "utf8"))) ?? [];
  } catch {
    return [];
  }
}

export default async function (pi: ExtensionAPI) {
  if (!process.env.OPENCODE_GO_2_API_KEY) return; // account 2 not configured here

  const catalogue = opencodeGoModels();
  const base =
    catalogue.find((m) => m?.id === MODEL_ID) ??
    catalogue.find((m) => typeof m?.id === "string" && /^muse-spark-1\.\d+-contributor$/.test(m.id));
  if (!base) {
    console.error("[opencode-go-2] no muse-spark contributor entry in opencode-go catalogue; not registering");
    return;
  }
  const models = [{ ...base, id: MODEL_ID, name: MODEL_NAME, provider: "opencode-go-2", api: "openai-responses", baseUrl: "https://opencode.ai/zen/go/v1" }];
  for (const [id, api] of [
    ["gemini-4-argon-contributor", "google-generative-ai"],
    ["glm-5.3-flash", "openai-completions"],
  ]) {
    const entry = catalogue.find((model) => model?.id === id);
    if (!entry) {
      console.error(`[opencode-go-2] ${id} missing from opencode-go catalogue; skipping`);
      continue;
    }
    models.push({ ...entry, provider: "opencode-go-2", api, baseUrl: "https://opencode.ai/inference/go/v1" });
  }

  pi.registerProvider("opencode-go-2", {
    baseUrl: "https://opencode.ai/zen/go/v1",
    apiKey: "$OPENCODE_GO_2_API_KEY",
    api: "openai-responses",
    models,
    streamSimple(model, context, options) {
      if (model.id === "gemini-4-argon-contributor" || model.id === "glm-5.3-flash") {
        if (!options?.sessionId) throw new Error("OpenCode Go 2 needs a live session ID for x-opencode-session");
        return streamSimple(model, context, {
          ...options,
          headers: { ...options.headers, "x-opencode-session": options.sessionId },
        });
      }
      return streamSimple(model, context, options);
    },
  });
}
