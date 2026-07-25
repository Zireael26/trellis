# Reference — X threads: algorithm + posting mechanics

Captured: 2026-07-08 (X ranker open-sourced 2026; posting mechanics observed
live same day). Algorithm section re-confirmed 2026-07-25. **Posting mechanics
partially superseded 2026-07-25 — see "Composer instability" below before
attempting the browser leg.** Re-ground on any X algorithm-repo change or
composer redesign.

Two sections: *why* the thread is shaped this way (the ranker), and *how* it
gets posted (the browser leg). Draft doctrine and the invocation contract live
in `SKILL.md`; the anti-tell catalog is `ai-tells.md`; the shape rules below
are enforced mechanically by `scripts/check-writing.sh --thread` — this doc
explains them, the script blocks on them.

## Algorithm — why the thread is shaped this way

- **Write for replies.** Engagement weighting is replies > reposts > likes
  (likes ≈ 0.5× weight). A thread that provokes replies beats one that merely
  reads clean.
- **Link-in-reply, always.** An external link in a tweet BODY costs roughly
  30–50% reach. Never put the link in the thread. Post it as a REPLY to the
  last tweet — the thread ranks unpenalized, the link rides underneath.
- **The hook lives in tweet one or nowhere.** Each tweet is scored
  independently, and the FIRST tweet gates the whole thread's distribution.
  Spend your best material there; a slow build buries the thread.
- **4–8 tweets, ≤280 chars each.** 4–8 is the working band; 280 per tweet is
  a hard ceiling. Both checked by `check-writing.sh --thread` — violations
  block dispatch, they do not warn.
- **Close with a genuine question.** A reply-bait closer earns the
  highest-weight engagement type. Genuine — a question you actually want
  answered, not engagement theater.
- **No hashtags.** Largely inert-to-negative for this content class.

## Posting mechanics — Claude-in-Chrome leg (capability-gated)

This leg requires a logged-in Chrome session + the browser tools. Absent
either, degrade to a paste-ready handoff per `SKILL.md` — never a hard fail,
never an unauthenticated retry.

- **Refs go stale after every re-render.** The composer redraws on each
  added tweet; element refs and coordinates from before the redraw are dead.
  Screenshot immediately before every click — especially the "+" add-tweet
  button, whose coordinates shift as boxes grow.
- **Selection is scoped per tweet box.** cmd+A selects within the *focused*
  box only. Click into the exact box before any select/retype. Typed text
  with no focused box executes as keyboard shortcuts (observed live:
  navigation jumped to the Likes page).
- **Recover drafts, don't retype.** X auto-saves composer state. On composer
  loss, recover via the "Your draft was saved. View" toast rather than
  reconstructing the thread from scratch.
- **Verify box order before posting.** Edited boxes can land out of order.
  Fix in place: click into the offending box, cmd+A, retype.
- **Sequence: thread → verify → link reply.** Post the thread first. VERIFY
  it live on the profile — count the tweets, read the order. Only then post
  the link reply on the LAST tweet (link-in-reply, above).
- **Composer instability (observed 2026-07-25, three consecutive failures).**
  The multi-box thread composer no longer survives automation on this surface.
  Three distinct corruptions, none of which posted anything:
  1. Clicking a tweet box by element ref while that box is below the modal
     fold does not focus it, and the subsequent typed text executes as
     keyboard shortcuts — the page navigated to Explore and a post attempt
     fired against an empty first box ("The content of your post is invalid").
     Box 1's text was silently cleared in the process.
  2. After injecting text with `document.execCommand('insertText')` into a
     focused box, the **rendered** composer held the text twice while an
     `innerText` read taken immediately afterward returned the single-length
     string. The cause is not established — the same call with a short string
     produced exactly one copy, so this is not a reliable double-apply; a race
     against the composer's own draft auto-restore fits the evidence equally
     well. What is established is the divergence: **a DOM read is a claim the
     editor has not finished making. Verify composer content by screenshot.**
  3. A `Runtime.evaluate` script holding `await` across several box additions
     froze the renderer past the 45-second CDP timeout, after which the
     composer reset to a single empty box and lost everything typed.
  Practical rule until this is re-grounded: keep any injected script under a
  few seconds, verify every box by screenshot rather than by DOM read, and if
  two attempts corrupt the draft, **discard and degrade to the paste-ready
  handoff**. A thread posted garbled is far worse than a thread handed over.
- **Anomaly posture: abort and surface.** On any unexpected state, stop and
  report the exact state — screenshot id plus what differed from expectation.
  Never blind-retry a click that may have already posted; a duplicate post is
  worse than a half-posted thread, and a half-posted thread surfaced with its
  exact state is recoverable.

Cross-references: `SKILL.md` (invocation contract, capability/degrade table),
`ai-tells.md` (prose-level tells — apply to tweet copy too),
`scripts/check-writing.sh` (the blocking check for the shape rules above).
