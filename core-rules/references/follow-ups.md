# follow-ups — the completion-boundary block

The *requirement* lives in `core-rules/CLAUDE.md` § Definition of done: at a
completion boundary, end the message with a `Follow-ups` block and emit the
machine marker alongside the DoD receipt. This file carries the mechanism —
block format, where items are captured durably, and how a follow-up is disposed
of later. Read it when you are writing a block or taking an item.

## When it fires

A completion boundary is a spec status flip (DECIDED / SHIPPED), a PR open, or a
DoD-receipt emission on a substantive unit. Trivial turns emit nothing.

## Block format

Numbered, decreasing priority, one line each, each tagged with a suggested
disposition:

- Priority order: **blocking-risk > correctness > cost/quota > hygiene**.
- Dispositions: `fold` (do it inside the current unit), `new-spec` (it is its own
  piece of work), `surgical` (small, standalone, do it now-ish).
- Items derive **only** from context already read this session — never launch new
  exploration to find them.

## Markers

Alongside the DoD receipt, emit `<!-- follow-ups: <count> -->`, or
`<!-- follow-ups: none -->` when there are none. Stop hooks **warn** —
non-blocking, by design — on a receipt without the marker.

## Durable capture

- **Spec-boundary items** go in that spec's `## Follow-ups` table:
  `# | priority | item | disposition | status`.
- **Non-spec units** append to `follow-ups.md` at the project root:
  `date | source | priority | item | status`, created lazily on first use.

## Disposition

Disposition is **operator-triggered** ("take #N") and never auto-taken. Routing
follows the 006 size floor: sub-floor → surgical now; above the floor → new spec;
already in scope → fold. On taking or dropping an item, update its ledger or spec
row with the disposition and a pointer (PR, spec id, or commit).
