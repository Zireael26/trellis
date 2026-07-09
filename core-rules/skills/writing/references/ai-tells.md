# Reference — anti-AI-tell catalog

Raw source: 30-day research sweep (Reddit / GitHub / web supplemental,
2026-06-08 → 2026-07-08), archived in the operator's research capture store.

Captured: 2026-07-08. Re-verify if older than 6 months **or** on a
detector-landscape / model-generation shift — slop-vocab lists and folk tells
move with each model wave (the em-dash panic is a 2025–26 artifact; the next
generation will have different tics).

## Doctrine: clustering is the signal

Single tells are noise. Models trained on human prose produce human patterns;
one em-dash is style, and banning any one habit outright punishes real writers.
What fingerprints a piece is **co-occurrence**: em-dashes + antithesis +
rule-of-three + bold-lead-in bullets in the same post is a signature no human
accumulates by accident. Self-review hunts clusters, not instances.

Second doctrine, from the 61k-story analysis in the sweep: the deepest tells
are **structural, not lexical** — uniform shape survives word-level editing.
The strongest human signal is firsthand specificity: what broke, what it cost,
the receipt. You cannot de-slop your way into that; you write it in.

Fixes preserve the voice file's voice (`voice.md`, sibling doc). Never flatten
a piece into beige prose to dodge a detector — that trades one tell (AI) for a
worse one (nothing to say).

## The catalog

- **Em/en-dash overuse.** Chains of `—` splicing clauses in a punched-up
  register. Models reach for the dash to fake momentum. Fix: two sentences, a
  colon, or a parenthetical — whichever the voice file's rhythm actually uses.
  Gated drafts carry zero (blunt, but deterministic and easy to write around).
- **"Not just X, it's Y" antithesis.** Negative parallelism — "It's not X.
  It's Y.", "no X, no Y" — manufactures emphasis without content. One instance
  can be earned; a cluster is the single most-cited fingerprint in the sweep.
  Fix: state the claim directly; if the contrast is real, let the facts carry it.
- **Rule-of-three runs.** Balanced triads everywhere ("fast, cheap, and
  reliable"). Models overproduce the cadence; humans list the actual number of
  things. Fix: cut to the item that matters, or the true count.
- **Bold-lead-in bullet lists.** Runs of `- **Term.** explanation` signaling
  thoroughness. House convention for reference docs (this file included) — a
  tell in *blog prose*, where it reads as a model formatting its answer. Fix:
  plain prose or plain bullets; save the pattern for genuine reference material.
- **Slop vocabulary.** delve, leverage, robust, seamless, tapestry, testament,
  pivotal, crucial, foster, landscape / navigate-the, elevate, unlock, harness,
  journey, realm, vibrant, comprehensive, holistic. RLHF-era assistant register;
  models pick the prestige synonym, humans pick the plain word. Fix: the voice
  file's vocabulary lists win — "use" not "leverage", "dig into" not "delve".
- **"In conclusion" / restatement closers.** "Overall," "In conclusion," or a
  final paragraph re-summarizing the piece. Essay-corpus training plus
  summarization tuning. Fix: end on the last real point; a closer may add a
  consequence or a next step, never a recap.
- **Uniform paragraph rhythm.** Same-length paragraphs, one-idea-one-paragraph
  monotony, no burstiness. Models regress to mean sentence and paragraph
  length. Fix: vary on purpose — a one-sentence paragraph beside a dense one;
  merge ideas that belong together. Judgment-only; no script catches this.
- **Hedging pairs.** "While X, it's important to note Y", "it's worth noting",
  symmetrical both-sides caveats. Harmlessness tuning leaking into prose. Fix:
  commit to the side you hold; delete the "important to note" scaffold.

## Relationship to `scripts/check-writing.sh`

The script mechanically enforces the **scriptable subset**, blocking (SC1/SC2):
em/en-dash count (zero outside code fences), slop-vocab hits (zero), bold-lead-in
bullets (zero), antithesis instances (more than three blocks — three can be an
author's rationed voice move; four is cluster territory) — plus thread mechanics
(4–8 tweets, ≤280 chars, no links in bodies; see `x-thread.md`). Red means fix
and rerun; never publish around a red.

Everything else in this catalog — closers, paragraph rhythm, hedging, the
clustering judgment, structural sameness — is **not scriptable** and is applied
at the self-review stage (SKILL.md, stage 3), reading the draft against
`voice.md` and this file side by side.

## What NOT to do

- Don't strip all structure. Headings and lists are how technical readers scan;
  the tell is reflexive formatting, not formatting.
- Don't ban lists globally. A real enumeration wants a list; a narrative
  argument doesn't. The failure mode is every section becoming bullets.
- Don't write worse to seem human. Injected typos, forced slang, deliberately
  broken rhythm — detectors and readers both see through it, and it violates
  the voice file. The target is the author's actual published voice, which
  already reads human because it is.
