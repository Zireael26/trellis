# Reference — Web SEO and discoverability

Sources:
- https://developers.google.com/search/docs/fundamentals/ai-optimization-guide
- https://developer.chrome.com/docs/lighthouse/seo
- https://developers.google.com/search/docs/fundamentals/seo-starter-guide

Captured: 2026-05-16. Re-verify if older than 6 months — Google's SEO
guidance and AI-search framing have shifted multiple times in the last
two years.

## TL;DR

AI-search visibility is downstream of standard SEO done well. Google's
generative AI features draw on the same ranking signals as core Search. Do
not invent AI-specific surfaces here — that lives in `web-agent-readiness.md`.

## Lighthouse SEO baseline

A passing Lighthouse SEO score (≥ 90) on every public route requires:

- `<title>` element present, descriptive, unique per route.
- `<meta name="description">` present and ≤ ~160 chars.
- `<html lang="…">` set.
- Descriptive link text (no "click here").
- Valid `robots.txt`; page not blocked from indexing if it should be public.
- `<meta name="viewport" content="width=device-width, initial-scale=1">`.
- Legible font sizes (≥ 12 px on mobile for body text).
- Tap targets sized appropriately (cross-ref `web-a11y.md` — 44×44 px).
- Valid `hreflang` if the site is multilingual.
- `<link rel="canonical">` per page when duplicate-URL risk exists.

## Google AI optimization guide — positives

What to ship (the boring part — vanilla SEO done well):

- **Indexable.** Page must be eligible to show with a snippet in Google
  Search. No accidental `noindex` on production routes; auth-gating only
  what should be private.
- **JavaScript renders content for Googlebot.** If shipping CSR, verify the
  rendered DOM via Search Console's URL Inspection tool or
  `mobile-friendly-test`. Prefer SSR or prerender for routes whose content
  matters for ranking.
- **Semantic HTML.** Headings, landmarks, descriptive anchor text. Same
  baseline as `web-a11y.md`.
- **`robots.txt` + XML sitemap.** Standard discovery surface. `robots.txt`
  references the sitemap location.
- **Canonical URLs.** `<link rel="canonical">` on each public page.
- **OpenGraph + Twitter card meta** for share-surface rendering. One
  canonical content body; meta cards mirror it, not replace it.
- **Page experience.** Core Web Vitals in the Good band — see `web-perf.md`.
- **Unique, first-hand content.** Recycled or generic content ranks poorly
  under Google's EEAT framing.
- **No duplicate content across paths.** One URL per piece. Use canonical
  + 301s where consolidation is needed.

## Anti-patterns — explicit don'ts

Google's AI optimization guide debunks these. Worth calling out because
agents reach for them:

- **No content chunking** for AI consumption. Write at the natural
  granularity; models handle synonyms and variation.
- **No "AI rewrites"** of content for LLM-specific phrasing.
- **No fake brand mentions** or inauthentic citation farms.
- **No `schema.org` JSON-LD markup unless it earns a rich result you
  actually want.** Not required for generative AI search; ship it only for
  Article, Product, FAQ, Recipe, etc., where the rich result is worth the
  maintenance.
- **No long-tail keyword variations** churned out as separate pages.

## What about `llms.txt`, MCP server cards, WebMCP?

Out of scope for this doc. See `web-agent-readiness.md` for the Trellis
stance on agent-targeted surfaces — those are a separate axis from
human-search SEO.

Cross-references: `web-perf.md` (Core Web Vitals as ranking signal),
`web-a11y.md` (semantic HTML shared baseline), `web-agent-readiness.md`
(agent/LLM-targeted surfaces).
