# Reference — Web performance

Sources:
- https://developer.chrome.com/docs/lighthouse/overview
- https://developer.chrome.com/docs/lighthouse/performance/performance-scoring
- https://web.dev/articles/vitals

Captured: 2026-05-16. Re-verify if older than 6 months — Lighthouse scoring
weights and CWV thresholds have shifted between major versions before.

## TL;DR

Public-facing pages on registered projects target Lighthouse Performance
score **≥ 90** and Core Web Vitals in the "Good" band on field data. Run
Lighthouse locally before any non-trivial public-page PR; attach the score
to the PR as a receipt.

## Core Web Vitals targets

| Metric | Good | Needs improvement | Poor |
|---|---|---|---|
| LCP (Largest Contentful Paint) | ≤ 2.5 s | ≤ 4.0 s | > 4.0 s |
| INP (Interaction to Next Paint) | ≤ 200 ms | ≤ 500 ms | > 500 ms |
| CLS (Cumulative Layout Shift) | ≤ 0.1 | ≤ 0.25 | > 0.25 |

INP replaced FID as a Core Web Vital in March 2024. Measure INP in the
field (CrUX, Search Console, RUM); the lab-side equivalent in Lighthouse is
**TBT (Total Blocking Time)** — target ≤ 200 ms on mid-tier hardware.

## Lighthouse Performance scoring

Current weights (re-verify against the source URL above when refreshing
this doc — Lighthouse rebalances between major versions):

| Metric | Weight |
|---|---|
| First Contentful Paint (FCP) | 10% |
| Speed Index | 10% |
| Largest Contentful Paint (LCP) | 25% |
| Total Blocking Time (TBT) | 30% |
| Cumulative Layout Shift (CLS) | 25% |

Score bands: 0–49 poor (red) · 50–89 needs improvement (orange) · 90–100
good (green). Target ≥ 90 on a representative public route.

Note: Lighthouse uses log-normal curves derived from HTTP Archive data, so
individual metric → score mappings are continuous, not stepwise.

## What to run today

No Trellis-managed automation. Per-PR developer workflow:

1. Build the production artifact (`pnpm build && pnpm start`, `next build &&
   next start`, or equivalent).
2. Run Lighthouse on the route(s) the PR changes — Chrome DevTools →
   Lighthouse panel, mobile profile, Performance category. CLI alternative:
   `npx lighthouse <url> --only-categories=performance --form-factor=mobile`.
3. Attach the score (and any regression delta against `main`) to the PR
   description's Receipts section.

If the change is JS-bundle-shaped (new dependency, route-level code split,
image-handling change), include a build-size delta in receipts.

## Lighthouse CI — deferred

`@lhci/cli` (Lighthouse CI) is the project-local automation path. Not yet a
canonical Trellis check because automated frontend gates are deferred per
`core-rules/deferred.md:57` until Rule of Three. First adopting project
should install it project-local and document its budget file (e.g.,
`.lighthouserc.json`) in the project README, not promote it parent-side
until n=2 lands.

## Common regressions to watch

- New `<img>` without `width`/`height` or `aspect-ratio` style → CLS.
- New blocking `<script>` in `<head>` → TBT and FCP.
- Web font without `font-display: swap` → FCP and CLS.
- Client-side data fetch on the LCP element's path → LCP.
- Hydration-heavy components above the fold → TBT and INP.

Cross-references: `web-a11y.md` (target-size 44×44 px and motion-reduction
overlap with perf decisions), `web-seo.md` (page experience is part of SEO
ranking signals).
