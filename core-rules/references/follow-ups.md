# follow-ups — the completion-boundary block

The *requirement* lives in `core-rules/AGENTS.md` § Definition of done: at a
completion boundary, end the message with a `Follow-ups` block when items
surfaced during the session (or state `Follow-ups: none`). Verification
evidence itself is recorded structurally by `stop-verify` into
`<git-dir>/trellis-local/last-verified.json` rather than scraped from HTML
comments in chat. This file carries the mechanism — block format, where items
are captured durably, and how a follow-up is disposed of later.

## When it fires

A completion boundary is a spec status flip (DECIDED / SHIPPED), a PR open, or
completion of a substantive implementation unit. Trivial turns emit nothing.

## Block format

Numbered, decreasing priority, one line each, each tagged with a suggested
disposition:

- Priority order: **blocking-risk > correctness > cost/quota > hygiene**.
- Dispositions: `fold` (do it inside the current unit), `new-spec` (it is its own
  piece of work), `surgical` (small, standalone, do it now-ish).
- Items derive **only** from context already read this session — never launch new
  exploration to find them.

## Verification evidence (structural, not HTML comments)

`stop-verify` writes `<git-dir>/trellis-local/last-verified.json` (`0600` in a
`0700` directory) when checks pass, binding `HEAD`, tree fingerprint, and the
commands that actually executed (`pre-push` never trusts `last-verified.json`
and always runs its own gate). Manual `<!-- dod-receipt -->` and
`<!-- follow-ups: ... -->` HTML comments are retired from `stop-verify`
enforcement; state the verification command, exit status, and diff summary
plainly for the human reader.

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
