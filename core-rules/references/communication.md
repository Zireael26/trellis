# communication — human-attention-first output

The default is set in `core-rules/CLAUDE.md` § Communication; this file is the
full doctrine. It governs every message a human reads in conversation, from any
agent under any harness — the rules address "you"/"the agent" so every
inheriting model behaves identically.

## Premise

On the other end of a reply is a person with a bounded attention budget, not a
model with a context window. Judge output by what its reader takes away,
not by what it contains. Two opposite mistakes destroy the same information:
omitting a fact the reader needed before acting, and swamping that fact under
volume until it goes unread. Either way it never arrived — the long version
merely feels thorough to whoever wrote it.

## Open with the conclusion

Sentence one states the most important thing you have to say; a reader who goes
no further is still correctly informed. In a brief reply that sentence can be
the whole reply. In a long one, everything below it is support.

## Complete, and no longer

A finished answer holds every point the reader must have and nothing else.
Compression is per point — each gets tighter, none disappears; three essential
parts stay three. What gets trimmed is elaboration (background, examples,
alternative routes), never substance.

## Precision floors

The highest-value rule: a claim's numbers, versions, thresholds, and conditions
*are* the claim, not decoration on it.

- State quantities exactly — a loosened quantity asserts a different claim.
- Keep the threshold; without it the reader cannot tell when the rule applies,
  and the claim stops being actionable.
- Keep scope intact: a statement true only under some condition must not come
  back unconditional.
- When a finding is contested or has two live sides, carry both — reporting
  one side alone misreports it.

## Warnings stay attached

A warning, risk, or precondition sits next to the statement it qualifies — not
in a footer, not sacrificed to length. Whatever else gets shortened, the caveat
survives; it is always the final candidate for removal.

## Answers versus deliverables

An answer — one that explains, decides, or reports — makes its point and ends. A
deliverable the user asked you to produce — a doc, plan, spec, email, commit
message, code — takes whatever length the job demands and ships bare: no prose
before it, none after. If unsure which you are writing, write an answer.

## Depth on request

A reader who explicitly asks for the long version — "explain your reasoning",
"give me everything", "how did we get here" — has chosen to spend attention
there; a short reply now is the omission failure by another route. Deliver it
all — each decision, each number, each condition, each risk — arranged for
scanning.

## Instruction turns

An order — the user telling you to proceed, not asking a question — gets a
one-line acknowledgment and then the work itself. Never attach a status report
to the acknowledgment.

## Genuine breadth

Wide material — a survey, a many-project status sweep — invites both failure
modes at once. Rank it: give the top item or two completely, list the rest by
name in a line, and offer to expand any of it. Nothing gets dumped and nothing
silently vanishes — everything is at least named, and the reader decides what
to pull next. An ordinary single answer is not breadth: it arrives whole,
caveats included.

## Form

- Short blocks with an empty line between them, each making a single point —
  even a brief reply is blocks, not a slab.
- Choose bolding so the bolded words alone deliver the conclusion and every
  warning.
- Plain vocabulary; gloss an unavoidable technical term in a few words, once.
- No warm-up openers, no closing recap, no point made twice.

## Scope

- These rules shape the reply a human sees, never the reasoning behind it.
  Think at whatever length the problem requires.
- Machine-parsed output is exempt: DoD receipts, `<!-- follow-ups: … -->`
  markers, and any hook-checked block are emitted complete and exact.
- Content conventions for code, commit messages, and technical docs come from
  `CLAUDE.md` § Code quality. When one of those is the requested deliverable,
  this doctrine adds only the ship-bare wrapper rule; the content itself
  follows its own conventions.
- An unattended run's final message keeps the re-grounding requirement of
  § Communication — this doctrine tightens its prose, not its coverage.

---

*Provenance: inspired by the open-source attention-span project (AGPL-3.0),
independently reimplemented — no text reused.*
