# Reference — Web accessibility

Sources:
- https://www.w3.org/WAI/WCAG22/quickref/
- https://www.w3.org/WAI/WCAG21/quickref/ (back-compat reference)
- https://web.dev/learn/accessibility
- https://github.com/dequelabs/axe-core
- https://pa11y.org/

Captured: 2026-05-16. Re-verify if older than 6 months — WCAG 2.2 is now
published (October 2023); axe-core supports it; pa11y still caps at WCAG 2.1.

## TL;DR

Baseline: **WCAG 2.2 Level AA** (supersedes 2.1; axe-core supports it).
Canonical tool: **axe-core**. Automated gate deferred per
`core-rules/deferred.md:57` until Rule of Three; manual checklist below is
the floor in the meantime.

## WCAG 2.2 AA — numeric thresholds that come up in review

So agents don't re-research these every time. 2.2 is fully back-compatible
with 2.1 — every 2.1 AA criterion remains an AA criterion in 2.2; 2.2 adds
new ones (most relevant below: 2.5.8 target-size at AA).

| Criterion | Level | Rule |
|---|---|---|
| 1.1.1 Non-text Content | A | Every meaningful image has `alt`; decorative images have `alt=""`. |
| 1.3.1 Info and Relationships | A | Use semantic elements (`<nav>`, `<main>`, `<button>`, `<h1>`–`<h6>`). |
| 1.4.3 Contrast (Minimum) | AA | Normal text ≥ **4.5:1**. Large text (≥18 pt or ≥14 pt bold) ≥ **3:1**. |
| 1.4.11 Non-text Contrast | AA | UI components + graphical objects ≥ **3:1** against adjacent colors. |
| 2.1.1 Keyboard | A | All functionality reachable via keyboard. No mouse-only interactions. |
| 2.4.3 Focus Order | A | Tab order matches visual/DOM order. |
| 2.4.7 Focus Visible | AA | Visible focus indicator on every keyboard-focusable element. |
| 2.4.11 Focus Not Obscured (Minimum) | AA *(new in 2.2)* | Sticky headers / footers / overlays do not fully hide the focused element. |
| 2.5.5 Target Size (Enhanced) | AAA | Touch targets ≥ **44×44 CSS px** — recommended floor for new work. |
| 2.5.8 Target Size (Minimum) | AA *(new in 2.2)* | Touch targets ≥ **24×24 CSS px** unless inline or user-agent-controlled. |
| 3.1.1 Language of Page | A | `<html lang="…">` set correctly. |
| 3.3.1 Error Identification | A | Form errors identified in text. |
| 3.3.2 Labels or Instructions | A | Every form control has a label or instruction. |
| 3.3.8 Accessible Authentication (Minimum) | AA *(new in 2.2)* | No cognitive function test (e.g. memorize, transcribe) required for auth without an alternative. |

## Tool stance — axe-core canonical

`@axe-core/cli` and `@axe-core/react` are the Trellis-canonical
accessibility tools. Reasoning:

- Supports WCAG 2.2 today (pa11y caps at 2.1).
- Deque-maintained with fast rule updates.
- Ships in Chrome DevTools' Issues panel — manual + automated runs share
  the same rule engine.
- First-class React/Next.js integration via `@axe-core/react`.
- Lighthouse's Accessibility category uses axe-core internally — a passing
  axe-core run aligns with Lighthouse a11y scoring.
- Matches TGSC's existing project-local `check-a11y.sh`
  (`stack-profiles.md:14`).

**pa11y** is documented as the alternative for projects where axe-core is a
poor fit:

- Pure static-HTML projects with no JS framework.
- Portfolio sites or marketing pages where a lean CLI fits better than a
  framework-coupled library.

One tool per project. No blending. If unsure, pick axe-core.

## Manual checks Lighthouse cannot automate

Run before any non-trivial public-page PR:

1. Tab through the page from a cold reload — every interactive element
   reachable, focus visible, order logical.
2. Visual order matches DOM order (no `order:` / negative margins that
   reorder content visually but not for screen readers).
3. Custom controls have an accessible name (`aria-label`, `aria-labelledby`,
   or visible text).
4. Live regions (`aria-live`) used for dynamic content updates.
5. Off-screen content hidden from AT (`aria-hidden="true"` or
   `display: none`).
6. Brief screen-reader smoke test on the route — macOS VoiceOver
   (`Cmd+F5`) or NVDA on Windows.

## Automated CI integration — deferred

Project-local `check-a11y.sh` running axe-core against the preview is the
established pattern. **Promotion to a canonical Trellis check is deferred
per `core-rules/deferred.md:57`** until a second project independently
adopts it. TGSC is currently the sole witness.

When promoting, the validator should target the `web-next` stack profile in
`stack-profiles.md` and fail on new violations relative to `main`.

## Deep-dive curriculum

`https://web.dev/learn/accessibility` — 20 modules covering semantic HTML,
ARIA, keyboard, color/contrast, animation, typography, forms, video/audio,
patterns, automated + manual + AT testing. Not duplicated here. Read on
demand when working on an unfamiliar a11y area.

Cross-references: `web-perf.md` (target-size 44×44 px also affects mobile
tap accuracy), `web-agent-readiness.md` (semantic HTML + accessibility tree
quality are how emerging agentic browsers parse pages).
