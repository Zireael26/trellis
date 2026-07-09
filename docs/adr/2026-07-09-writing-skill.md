# ADR: `writing` — canonical publishing skill for blogs + X threads (spec 010)

**Date:** 2026-07-09
**Status:** Accepted

## Context

The fleet's SEO surface is enforced at the plumbing level — process-gate Gate 6 pulls `web-seo.md`, `web-agent-readiness.md`, and `web-perf.md` on every web-profile project — but nothing covered the content itself. The 2026-07-08 loop-era release proved the missing capability live: a blog post authored against an anti-AI-tell catalog and the author's published voice, plus a 6-tweet X thread shaped by the open-sourced ranker's actual weights (replies > reposts > likes; external links in tweet bodies cost 30–50% reach, so the link rides a reply), posted end-to-end via browser automation. All of it — tell catalog, algorithm mechanics, composer gotchas, voice-matching — evaporated with the session. AI-looking content is not a cosmetic problem: the ranker penalizes its correlates and readers bounce, so the gap is reach and reputation.

## Decision

- Ship `writing` as the twelfth canonical skill (`core-rules/skills/writing/`): six-stage pipeline — voice load → draft → self-review → scriptable validation → publish → receipts.
- **Full auto-post on explicit invocation** (operator-decided over a per-run approval stop): `disable-model-invocation: true` means every run is operator-triggered, so the invocation is the per-action authorization and its named targets bound the scope; `check-writing.sh` red blocks publish; anomalies abort-and-surface, never blind-retry; the blog leg still rides the target repo's own PR gates. Any model-initiated posting would be a bright-line change requiring its own ADR. The skill never deletes or edits already-published content.
- **Scriptable subset is enforced, not advised:** `scripts/check-writing.sh` (blog mode: em/en-dashes outside code fences, slop vocabulary, bold-lead-in bullets, antithesis clustering; thread mode: 4–8 tweets, ≤280 chars, no links in bodies) exits non-zero and blocks. The judgment subset (rhythm, clustering, voice fidelity) lives in `references/ai-tells.md` for the self-review stage. Clustering is the signal; single tells are noise; fixes must preserve the voice file's voice.
- **Voice files live in the target content repo** (`docs/voice.md`), never under `core-rules/` — the public mirror syncs `core-rules/skills/` wholesale, so keeping voice outside it makes leakage structurally impossible rather than policy-prevented. Per-project because a personal site and a product do not share a voice. akaushik.org's file is seeded from its three published Trellis posts.
- **Posting leg is capability-gated, not identity-gated** (orchestrate precedent): no logged-in Chrome + Claude-in-Chrome → paste-ready handoff; Codex harness → authoring + validation only. Missing validator script is the one hard stop.
- Volatile references (`ai-tells.md`, `x-thread.md`) carry captured dates and re-verify triggers — the `web-seo.md` / codex-routing dating pattern; no hand-edits on trend news.
- v1 scope is blogs + X threads only; LinkedIn/newsletter/landing copy deferred until each gets its own grounding pass.

## Consequences

- Fleet rollout via `scripts/rollout-writing-skill.sh` (debrief-pattern symlink install, both harness dirs); public template receives the skill through the existing wholesale skills sync — users bring their own voice files.
- The gitignore fragments gain one more untracked symlink per project until the next per-project onboard re-run regenerates the managed block (known, batched drift).
- Re-ground obligations: X ranker weights on algorithm-repo changes; tell catalog on detector-landscape shifts or ≥6 months.
- The `check-writing.sh` build was delegated to Codex under the 009 advisory-first pilot (ledger row 2), continuing the pilot's evidence accumulation.
