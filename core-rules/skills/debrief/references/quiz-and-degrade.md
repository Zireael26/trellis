# Reference — quiz mechanic + capability gate

The discipline the quiz exists to enforce lives in `SKILL.md` § Quiz mechanic: mix
open-ended and multiple-choice, **shuffle** the correct answer's position, **never
reveal** until the human has committed a response, and gate on tool presence — not
harness identity. This file is the mechanics behind that summary; it does not restate
the teaching loop.

## What a quiz item is for

A quiz item is a **mastery check**, not a gotcha. It probes whether the human can
reconstruct the understanding, not whether they can recall a phrasing. Use it where a
restatement is ambiguous — a passed item is one of the two ways a checklist box flips
to checked (the other is a clean restatement in the human's own words). Mix shapes:

- **Open-ended** — "Why did the rejected branch fail here?" Forces reconstruction;
  best for the *why* tier where a multiple-choice would leak the answer.
- **Multiple-choice** — three or four options, exactly one correct, the distractors
  drawn from plausible-but-wrong mental models (not nonsense). Best for edge-case and
  blast-radius checks where the wrong answers are themselves diagnostic.

## The three disciplines (non-negotiable, every harness)

1. **Shuffle the correct answer's position.** Across a run of multiple-choice items
   the correct option must not sit in a fixed slot — no positional tell. Randomize per
   item.
2. **No early reveal.** Do not state, hint at, or visibly lean toward the correct
   answer until the human has committed their choice. The point is to surface a wrong
   mental model, which only happens if they commit first.
3. **Diagnose, then fill.** A wrong answer is not a failure to move past — it is the
   gap. Explain *why* the chosen option is wrong and *why* the correct one holds, then
   re-probe (a fresh item or a restatement) before flipping the box. A guessed-correct
   answer is not mastery either; if the reasoning is absent, treat it as unchecked.

## Capability gate

The gate keys on **whether the harness exposes a structured single-question tool**,
checked against the actual tool list — not on harness identity.

- **Has a structured single-question tool** (`AskUserQuestion` on Claude Code today).
  Use it for clean multiple-choice submission: one question, labelled options, the
  human picks one, and the tool returns the choice atomically. Shuffle the correct
  option's position before presenting; do not reveal until the choice is returned.
- **No such tool — degrade to numbered inline Q&A.** Present the question and number
  the options inline in the transcript; ask the human to reply with the number. The
  three disciplines are **identical** — shuffle the correct position, withhold the
  answer until they reply, then diagnose. The only thing lost is the structured
  submission surface; the rigor is unchanged.

The quiz is **never** a hard dependency on `AskUserQuestion` or any Claude-only tool.
Where the structured tool is absent, the numbered-inline form carries the same
discipline — that is the degrade, not a downgrade of the check.

## Open-dialogue note

The quiz is one instrument inside a two-way conversation, not an interrogation. The
human may interrupt to ask the agent a question at any point, and may ask for a
re-explanation at a chosen depth (the ELI ladder in `SKILL.md`). Quiz when a
restatement is ambiguous; do not gate every box behind a quiz when a clear restatement
already demonstrates mastery.
