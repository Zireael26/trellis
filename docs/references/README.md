# docs/references/ — opt-in domain checklists

Domain-knowledge checklists a project can **opt into**, distinct from the
always-on process spine. This directory is the RC.5 resolution of the
`addyosmani/agent-skills` evaluation: its **process** primitives were folded into
the core spine (`core-rules/references/` — doubt-driven-development,
source-driven-development, versioning, deprecation-and-migration), but its
**domain-knowledge** modules (observability, frontend, performance, API design,
TDD, shipping, browser-testing, security-hardening) are *not* made core-rules
skills — that would turn Trellis's lean process-spine into a domain library and
bloat every project's always-loaded surface.

Instead they live here as reference checklists a project consults when the work
touches that domain. Nothing here auto-loads; an agent reads the relevant file
on demand (or a project pins it in its own `CLAUDE.md`).

## Convention

- One file per domain, a **checklist**, not a tutorial. Keep it to what a
  competent engineer would forget under time pressure — the Definition-of-Done
  bar for that domain.
- Seeded **on demand**: a domain file is added the first time a project needs it,
  mined from the addyosmani `references/` (DoD, security-for-LLMs, observability,
  orchestration-anti-patterns) plus project experience — not pre-authored
  speculatively (no code for imaginary scenarios; the same rule applies to docs).
- Cite the process primitive it pairs with. Example: a `security-hardening.md`
  design-time threat-model checklist enriches `security-gate`'s prose; a
  `deprecation` domain note pairs with `core-rules/references/deprecation-and-migration.md`.

## Candidate domains (seed when first needed)

`observability-and-instrumentation`, `frontend-ui-engineering`,
`performance-optimization`, `api-and-interface-design`, `test-driven-development`,
`shipping-and-launch`, `browser-testing-with-devtools`,
`security-and-hardening` (design-time). These are the addyosmani domain modules
judged valuable-but-domain-specific — reference-only here, never core skills.
