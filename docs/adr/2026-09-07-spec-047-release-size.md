# Ship Spec 047 as one reviewed release change

Status: proposed for the 1.2.0 release preparation.

Spec 047 delivers three things in one version: the opt-in Pi web-search adapter
under `core-rules/pi/web-search/`, the session reporting and guidance disclosure
changes, and the separately registered evaluation. The intended commit range is
roughly 47,800 countable lines across two commits (the release commit and a gate-repair commit) against an 800-line hard cap, so it needs this
exception under `references/pr-hygiene.md`.

## What is actually in the range

The executable surface is small. It is the adapter's four product files plus its
fixtures and tests, the fenced runner `scripts/pi-web-search-tests.sh` and its
Bats coverage, the reporting and guidance edits, and the digest and orchestration
recipe changes. Everything else — the large majority of the line count — is the
per-task evidence that this spec's own completion rule requires: fenced test
receipts with actual exits, canary ledgers, independent review rounds, and the
frozen review inputs those rounds were taken against.

Splitting is possible only along lines that destroy what is being reviewed.
Separating the evidence from the code it certifies leaves an intermediate commit
whose receipts name files that do not exist in it. Separating the adapter from
the reporting changes splits one version allocation across two releases and
requires the SC6 canary — which exercises the adapter through the shipped
runtime — to be run twice against two different payloads. Neither split reduces
the surface a reviewer must read; both reduce what one commit and one rollback
can show.

## What is deliberately not in the range

This exception is for evidence that is worth reviewing, not for everything the
work produced. About 26,700 lines across 111 files stay local and are not
committed:

- Raw third-party HTTP response bodies under `web-search/repair-evidence/` and the
  reviewer citation captures under `implementation/citation-capture/raw/` — fetched kernel.org, nodejs.org, lore and
  GitHub pages, more than a third of them byte-identical duplicates between the
  two collectors. Their manifests (`index.json`, `grok/INDEX.tsv`, the `.headers`
  and `.meta` files) record each URL, HTTP status, byte count and SHA-256, and
  `grok/EXCERPTS.md` records the passages actually relied on. Those manifests
  and excerpts ship; the bodies are reproducible from them and remain locally
  retained.
- 3,108 lines of `*.patch` deltas that restate code already present in the range.
- 430 lines of third-party CLI `--help` dumps captured while probing tooling.
- Harness-managed agent leaves under `.agents/agents/`, which are delivered by
  attachment and are not this spec's material.
- Per-task captures, native envelopes, pane records and raw stub stdout, which
  `implementation/publication-inventory-review.md` already classifies local-only.

Nothing failing is removed. Failed cells, inconclusive outcomes and unavailable
advisories stay in the committed evidence with their dispositions.

## Search owner boundary

The adapter is additive and opt-in, and the boundary is the reason it can ship
inside a MINOR release rather than as its own change. It obtains an in-memory
token and project envelope only through Pi's registered Antigravity OAuth owner;
it does not open or mutate credential stores, and its production file I/O is
confined to one explicitly selected, bounded, non-symlink regular config file.
It issues a single POST with no retry, no fallback endpoint, model, auth owner or
header variant, and fails closed on unsupported platform tuples. Received URLs
are never fetched. Its cost receipt allowlist excludes the query, the answer,
source URLs and titles, citations, raw stream and token or project values.
`implementation/t22-source-review.md` is an independent source-only review of
exactly these properties at the four pinned product hashes.

That review is source-only. It does not establish provider compatibility, live
behaviour or rollback, and this ADR does not claim otherwise: SC6 closes on the
live canary and rollback receipts, and the release scope must name exactly which
parent, build and runtime routes were verified.

## Consequences

The PR keeps its size warning and requires explicit independent reviewer
acknowledgement of the size in its description. This exception covers Spec 047's
release commit only. The staging inventory that decides what is committed is
`specs/047-session-efficiency-cost-transparency/implementation/opus-release-preparation.md`;
the commit is made against that inventory, never with a blanket `git add -A`.
Before the public mirror is published, the projected diff is checked for local
`~/.trellis`, fleet and credential metadata, which the private evidence contains
by design and the public mirror must not.
