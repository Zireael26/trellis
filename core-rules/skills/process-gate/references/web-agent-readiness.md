# Reference — Web agent & LLM readiness

Sources:
- https://developers.google.com/search/docs/fundamentals/ai-optimization-guide
- https://developer.chrome.com/docs/lighthouse/agentic-browsing
- https://isitagentready.com/

Captured: 2026-05-16. **Re-verify quarterly** (not semi-annually) — this is
the axis where authoritative guidance is shifting fastest and sources
actively disagree.

## Trellis stance (load-bearing)

**Adopt:**

- `llms.txt` at project root, pointing to canonical docs.
- Valid `robots.txt` with explicit AI-crawler directives (allow or deny per
  policy) and a `Sitemap:` reference.
- XML `sitemap.xml`.
- Semantic HTML + a clean accessibility tree (defers to `web-a11y.md`).
- OpenGraph metadata (already covered by `web-seo.md`).

**Skip until n=2 registered projects need it:**

- WebMCP integration / MCP server card.
- x402, UCP (Universal Commerce Protocol), ACP (Agentic Commerce Protocol),
  Business Agent.
- Markdown content negotiation for agent consumption.
- AI-specific markdown mirrors of HTML pages.

**Never do (Google's negatives, preserved):**

- AI-rewriting content for LLM-specific phrasing.
- Chunking content into tiny pages to seed AI snippets.
- Fake brand mentions / inauthentic citation farms.

## Why this stance — the three-way disagreement

Three authoritative sources disagree on `llms.txt`:

| Source | `llms.txt` stance | AI-specific markup stance |
|---|---|---|
| Google AI Optimization Guide | "**Unnecessary.**" Explicitly debunked. | Not required. Don't AI-rewrite. |
| Lighthouse Agentic Browsing (Chrome team) | **Rewards presence** under Stability and Discoverability. | Rewards WebMCP and agent-centric accessibility. |
| Cloudflare `isitagentready.com` | **Rewards presence** implicitly via markdown content negotiation + protocol-discovery signals. | Rewards WebMCP, OAuth discovery, x402/UCP/ACP. |

Two of three reward `llms.txt`. Google calls it "unnecessary," not
"harmful." Cost is one static file pointing to canonical docs. Trellis takes
the hedge: ship it, document the dissent, revisit quarterly.

The speculative protocol layer (WebMCP, MCP server card, x402, UCP, ACP) is
not adopted because no registered project today ships an agent-served API
or ecommerce surface that would benefit. Revisit when a project requests it.

## `llms.txt` — minimal shape

A `/llms.txt` at the site root. Single file. Markdown. Points to canonical
human-readable docs already on the site; does **not** duplicate them.

```
# <project name>

> One-sentence project description.

## Docs

- [Getting started](https://example.com/docs/getting-started): one-line description.
- [API reference](https://example.com/docs/api): one-line description.

## Optional

- [Changelog](https://example.com/changelog): release history.
```

No `llms-full.txt`. No AI-only markdown mirrors. The point is signage, not
a new content surface.

## `robots.txt` — AI bot directives

Universal recommendation across Cloudflare quick-wins and Lighthouse SEO.
Shape:

```
User-agent: *
Allow: /
Disallow: /api/private/

# AI training crawlers — set per project policy
User-agent: GPTBot
Allow: /

User-agent: ClaudeBot
Allow: /

User-agent: Google-Extended
Allow: /

Sitemap: https://example.com/sitemap.xml
```

Default policy per registered project: `Allow` for indexing crawlers
(GPTBot, ClaudeBot, Google-Extended, PerplexityBot). Flip to `Disallow`
only if the project has an explicit reason — paid-content gate,
private-data exposure risk, or product-side decision.

## Semantic HTML + accessibility tree

Emerging agentic browsers (the category Google's guide flags) parse DOM,
accessibility tree, and screenshots. The best preparation is already in
`web-a11y.md`: WCAG 2.2 AA baseline, semantic landmarks, accessible names
on every interactive control, proper heading hierarchy. No new surface
needed; reuse the a11y work.

## What is explicitly NOT adopted, with reasoning

- **WebMCP / MCP server cards.** Speculative protocol. Zero registered
  projects expose agent-served APIs. Revisit when n=2 ships such an API.
- **x402, UCP, ACP, Business Agent.** Ecommerce / agentic-commerce protocol
  layer. Zero registered ecommerce projects. Revisit when one ships.
- **Markdown content negotiation** (Cloudflare quick-win). Niche; the
  canonical HTML surface is sufficient for current registered projects.
- **JSON-LD / schema.org markup** for AI consumption specifically. See
  `web-seo.md` — ship it only when it earns a rich result you want, not
  speculatively for AI parsing.

Cross-references: `web-seo.md` (human-search SEO, the foundation),
`web-a11y.md` (semantic HTML + a11y tree shared with agentic browsers).
