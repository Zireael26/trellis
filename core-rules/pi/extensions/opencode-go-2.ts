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
 * 2026-09-02 operator ruling: Muse Spark Contributor is the only model in use
 * on both OpenCode Go subs (GLM removed everywhere). 2026-09-03: the model is
 * Muse Spark 1.3 Contributor. The on-disk catalogue may still carry only the
 * 1.2 entry (pi's bundled catalogue lags OpenCode's), so the 1.3 entry is
 * derived from whichever muse-spark contributor entry exists, id and name
 * rewritten. Wire is openai-responses: the Go chat/completions wire returned
 * 500 for Muse on 2026-09-03 while /responses answered.
 */
const MODEL_ID = "muse-spark-1.3-contributor";
const MODEL_NAME = "Muse Spark 1.3 Contributor";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

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

  pi.registerProvider("opencode-go-2", {
    baseUrl: "https://opencode.ai/zen/go/v1",
    apiKey: "$OPENCODE_GO_2_API_KEY",
    api: "openai-responses",
    models,
  });
}
