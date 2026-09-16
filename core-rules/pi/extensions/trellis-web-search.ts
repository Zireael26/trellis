// @ts-nocheck
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const TOOL_NAME = "trellis_web_search";
export const DAILY_ORIGIN = "https://daily-cloudcode-pa.googleapis.com";
export const ENDPOINT_URL = `${DAILY_ORIGIN}/v1internal:streamGenerateContent?alt=sse`;

export type WebSearchResult = {
  provider: string;
  answer: string;
  sources: Array<{ url: string; title: string }>;
  queries?: string[];
};

async function searchAntigravity(query: string, maxResults: number, signal?: AbortSignal): Promise<WebSearchResult | null> {
  const authFile = path.join(os.homedir(), ".pi/agent/auth.json");
  if (!fs.existsSync(authFile)) return null;

  let authData: any;
  try {
    authData = JSON.parse(fs.readFileSync(authFile, "utf8"));
  } catch {
    return null;
  }

  const agy = authData.antigravity;
  if (!agy || !agy.access) return null;

  const token = agy.access;
  const projectId = agy.projectId || "cloudcode-pa-prod";

  const headers = {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    Accept: "text/event-stream",
    "User-Agent": "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)",
    "X-Goog-Api-Client": "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "Client-Metadata": JSON.stringify({ ideType: "ANTIGRAVITY", platform: "MACOS", pluginType: "GEMINI" }),
  };

  const reqBody = {
    project: projectId,
    model: "gemini-3.5-flash-lite",
    request: {
      contents: [{ role: "user", parts: [{ text: query }] }],
      tools: [{ googleSearch: {} }],
      generationConfig: { maxOutputTokens: 2048 },
    },
    requestType: "agent",
    userAgent: "antigravity",
    requestId: `agent-${Math.random().toString(36).slice(2)}-${Date.now()}`,
  };

  const timeoutSignal = AbortSignal.timeout(30000);
  const combinedSignal = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal;

  const resp = await fetch(ENDPOINT_URL, {
    method: "POST",
    headers,
    body: JSON.stringify(reqBody),
    signal: combinedSignal,
  });

  if (!resp.ok) {
    throw new Error(`Antigravity HTTP error: ${resp.status} ${resp.statusText}`);
  }

  const body = await resp.text();
  let answer = "";
  const sources: Array<{ url: string; title: string }> = [];
  const queries: string[] = [];

  for (const line of body.split("\n")) {
    if (line.startsWith("data: ")) {
      try {
        const data = JSON.parse(line.slice(6));
        const cands = data.response?.candidates || [];
        for (const c of cands) {
          for (const p of c.content?.parts || []) {
            if (p.text && !p.thought) answer += p.text;
          }
          if (c.groundingMetadata) {
            const gm = c.groundingMetadata;
            if (Array.isArray(gm.webSearchQueries)) {
              for (const q of gm.webSearchQueries) {
                if (q && !queries.includes(q)) queries.push(q);
              }
            }
            if (Array.isArray(gm.groundingChunks)) {
              for (const chunk of gm.groundingChunks) {
                if (chunk.web?.uri) {
                  sources.push({ url: chunk.web.uri, title: chunk.web.title || "" });
                }
              }
            }
          }
        }
      } catch {
        // ignore unparseable partial chunk
      }
    }
  }

  if (!answer.trim()) return null;

  return {
    provider: "Google Antigravity (Gemini 3.5 Flash-Lite)",
    answer: answer.trim(),
    sources: sources.slice(0, maxResults),
    queries,
  };
}

async function searchOpenAICodex(query: string, _maxResults: number, signal?: AbortSignal): Promise<WebSearchResult> {
  return new Promise((resolve, reject) => {
    const proc = spawn("codex", ["--search", "exec", "--sandbox", "read-only", query], {
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 45000,
    });

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (d) => (stdout += d.toString()));
    proc.stderr.on("data", (d) => (stderr += d.toString()));

    if (signal) {
      signal.addEventListener(
        "abort",
        () => {
          try {
            proc.kill("SIGTERM");
          } catch {}
          reject(new Error("Search request cancelled"));
        },
        { once: true },
      );
    }

    proc.on("close", (code) => {
      if (code !== 0) {
        return reject(new Error(`Codex search failed with exit code ${code}: ${stderr}`));
      }
      const lines = stdout.trim().split("\n").filter((l) => l.trim().length > 0);
      const answer = lines[lines.length - 1] || stdout;
      resolve({
        provider: "OpenAI Codex (ChatGPT Subscription Fallback)",
        answer: answer.trim(),
        sources: [],
      });
    });

    proc.on("error", (err) => reject(err));
  });
}

export async function executeWebSearch(query: string, maxResults = 5, signal?: AbortSignal): Promise<string> {
  let result: WebSearchResult | null = null;
  let antigravityError: string | null = null;

  try {
    result = await searchAntigravity(query, maxResults, signal);
  } catch (err: any) {
    antigravityError = err?.message || String(err);
  }

  if (!result) {
    try {
      result = await searchOpenAICodex(query, maxResults, signal);
    } catch (fallbackErr: any) {
      const msg = [
        "Web search failed across all providers:",
        `• Antigravity (primary): ${antigravityError || "No results returned"}`,
        `• OpenAI Codex (fallback): ${fallbackErr?.message || String(fallbackErr)}`,
      ].join("\n");
      throw new Error(msg);
    }
  }

  let output = `${result.answer}\n\n---\n*Source Provider: ${result.provider}*`;
  if (result.queries && result.queries.length > 0) {
    output += `\n*Search Queries:* ${result.queries.map((q) => `\`${q}\``).join(", ")}`;
  }
  if (result.sources && result.sources.length > 0) {
    output += "\n\n**Sources:**\n";
    result.sources.forEach((s, i) => {
      const title = s.title ? `[${s.title}](${s.url})` : s.url;
      output += `${i + 1}. ${title}\n`;
    });
  }

  return output;
}

export default function registerTrellisWebSearchExtension(pi: ExtensionAPI): void {
  const toolDefinition = {
    name: TOOL_NAME,
    label: "Trellis Web Search",
    description:
      "Search the live web for current facts, technical documentation, news, or release versions. Primary: Google Search grounding via Antigravity; Fallback: OpenAI Codex search.",
    parameters: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "The search query text.",
        },
        max_results: {
          type: "integer",
          minimum: 1,
          maximum: 10,
          description: "Maximum number of source references to return (default: 5).",
        },
      },
      required: ["query"],
      additionalProperties: false,
    },
    async execute(_toolCallId: string, params: any, signal?: AbortSignal) {
      const query = typeof params === "string" ? params : params?.query;
      if (!query || typeof query !== "string" || query.trim().length === 0) {
        return {
          content: [{ type: "text", text: "Error: query parameter is required." }],
          isError: true,
        };
      }
      const maxResults = typeof params?.max_results === "number" ? params.max_results : 5;
      try {
        const text = await executeWebSearch(query.trim(), maxResults, signal);
        return {
          content: [{ type: "text", text }],
        };
      } catch (err: any) {
        return {
          content: [{ type: "text", text: `Web search error: ${err?.message || String(err)}` }],
          isError: true,
        };
      }
    },
  };

  pi.registerTool(toolDefinition as any);

  // Register friendly alias web_search
  pi.registerTool({
    ...toolDefinition,
    name: "web_search",
    label: "Web Search",
  } as any);
}
