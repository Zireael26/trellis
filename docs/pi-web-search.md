# Web Search in Pi (Trellis Standard Integration)

Trellis provides built-in live web search capability for Pi sessions through the `trellis_web_search` tool (also aliased as `web_search`).

## Overview

The web search tool enables Pi agents to query real-time external data, verify documentation, inspect package release versions, and cross-check breaking news without leaving the session.

- **Primary Provider:** Google Search Grounding through **Google Antigravity** (`gemini-3.7-flash-low` on the daily Cloud Code endpoint).
  - Uses the existing Antigravity OAuth session already configured in Pi (`/login antigravity`).
  - Returns grounded model synthesis along with source URLs, page titles, and grounding search queries.
- **Automatic Fallback:** **OpenAI Codex** Search through the user's active ChatGPT Plus/Pro subscription.
  - If Antigravity encounters any issue (e.g. rate limits, network timeouts, authentication expiration), the tool automatically falls back to `codex --search` without failing the agent's turn.
- **Default Availability:**
  - Auto-loaded globally from `~/.pi/agent/extensions/trellis-web-search.ts`.
  - Available to all Trellis-attached projects via `.pi/extensions/trellis-web-search.ts`.

## Tool Usage

Agents call `trellis_web_search` or `web_search`:

```json
{
  "query": "latest Next.js release version and breaking changes",
  "max_results": 5
}
```

### Parameters

- `query` (string, required): The search query text.
- `max_results` (integer, optional, default: 5, min: 1, max: 10): Maximum number of web sources to return.

## Fallback & Error Handling

1. When a query is initiated, the tool first dispatches to Google Antigravity with a 30-second timeout.
2. If Antigravity returns valid text and sources, the grounded result is returned immediately with provider metadata.
3. If Antigravity fails or returns empty content, the tool invokes the local Codex search engine in read-only sandbox mode.
4. The output clearly cites whether the primary Antigravity provider or the OpenAI Codex fallback was used.

## Configuration & Overrides

For headless environments or bounded batch tasks, an optional task configuration may still be supplied via `TRELLIS_WEB_SEARCH_CONFIG` pointing to a JSON file:

```json
{
  "provider": "antigravity",
  "model": "gemini-3.7-flash",
  "runtime_model": "gemini-3.7-flash-low",
  "endpoint": "daily",
  "max_calls": 50
}
```

When `TRELLIS_WEB_SEARCH_CONFIG` is omitted, the tool automatically uses default Antigravity grounding with OpenAI Codex fallback and a generous per-session quota.
