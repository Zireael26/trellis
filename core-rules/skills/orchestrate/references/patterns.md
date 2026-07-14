# Reference — Orchestration pattern catalog

Authoritative source for the always-on discipline: `CLAUDE.md` (Planning, Context
management, Definition of done). This file does not restate those rules — it points
at them and adds the two shapes they don't already cover.

The value here is **two new patterns**, not a ceremonial list of six. Four of the
useful shapes are already mandated in `CLAUDE.md` and practiced on every task;
those get a one-liner and a pointer. The remaining two — **tournament** and
**generate-and-filter** — are genuinely new to the Trellis vocabulary and get
worked guidance.

## Four shapes Trellis already does

These are already doctrine. Read the cited rule for the authoritative wording;
don't re-derive it.

- **fan-out-and-synthesize** — decompose into independent units, dispatch them in
  parallel, merge the results. See the parallel-dispatch bullet under *Context
  management* in `CLAUDE.md` (the `≥2 independent searches / >5 files / edit-heavy`
  triggers). This is the spine of every recipe in the library.
- **adversarial-verification** — a separate reviewer checks the work product the
  builder cannot mark its own. See the code-review-subagent rule under *Definition
  of done* in `CLAUDE.md` ("you do not self-mark your own homework"). Generalizes
  beyond code: any generate-then-independently-check loop. For above-solo-reliability
  builds, sharpen this reviewer into the gated **skeptical evaluator** (defaults to
  "not done", judges a pre-agreed sprint contract) — `references/skeptical-evaluator.md`.
- **generate-goal / loop-until-done** — frame the task as a verifiable goal first
  (failing test, green-before-and-after, explicit acceptance check), then iterate
  until that goal is met. See the verifiable-goal bullet under *Planning* in
  `CLAUDE.md`. The goal is what lets a loop run unattended; without it, "make it
  work" forces back-and-forth.
- **phase-decomposition** — split a large change into ordered phases, each
  independently verifiable, never one monolithic pass. See the max-7-files phasing
  bullet under *Planning* in `CLAUDE.md`. This is sequencing with a barrier between
  phases, the complement to fan-out's parallelism.

When a task maps onto one of these four, you already know the shape — the catalog
adds nothing. The rest of this file is the two it doesn't.

## tournament

**When.** You have N candidates and need a ranking or a single best, but N is too
large — or each candidate too heavy — to hold and compare in one context. Absolute
scoring is unreliable (the scale drifts across a long list; "8/10" means different
things 30 items apart), yet *relative* judgement between two items is stable. Use
when the decision is "which of these is better", repeated.

**Shape.** Treat it as a bracket, not a single pass.

1. Generate or collect the N candidates (often the output of a prior fan-out).
2. Compare in **pairs**: each match is one cheap, isolated judgement — "A vs B,
   which better satisfies the metric, and why". A pair fits one small context, so
   the comparison stays calibrated.
3. Advance winners; run rounds until one candidate (or a ranked top-k) remains.
   For a full ranking, keep the pairwise results and order by wins, or run a
   round-robin when N is small enough to afford it.
4. The judging metric is fixed up front and identical across every match — that is
   what makes the bracket coherent. Record *why* each match resolved as it did, so
   the final pick carries its justification.

Pair comparisons within a round are independent, so each round is itself a
fan-out-and-synthesize: dispatch the round's matches in parallel, barrier, then
seed the next round from the winners.

**Example sketch.** Ranking a backlog of candidate refactors by leverage when there
are forty of them and no single context can weigh all forty fairly: seed a bracket,
let each match decide "does refactor A or B remove more duplication per line
touched", advance winners round by round, surface the top three with the
match-by-match reasoning attached. Other fits: choosing among competing design
options, ordering findings by severity, picking the strongest of many drafts.

## generate-and-filter

**When.** The cheapest path to a good answer is to produce **many** rough
candidates and then keep only the ones that clear an explicit bar — rather than
trying to author one correct answer directly. Use when candidates are cheap to
generate, the quality metric is concrete and machine-checkable (or quick to
judge), and coverage matters more than first-try precision: ideation, test-case
generation, exploring several fix candidates for a stubborn bug.

**Shape.** Two stages, deliberately asymmetric.

1. **Generate wide and cheap.** Dispatch generation to produce far more candidates
   than you need — breadth over polish. Independent generators fan out in parallel;
   each need only be plausible, not final.
2. **Filter by an explicit metric.** Apply a *named, written-down* quality bar and
   drop everything below it. The metric must be stated before you look at the
   candidates — "passes the existing suite and raises branch coverage", "reproduces
   the bug then fixes it", "distinct from the others and on-brief" — not invented
   to fit whatever came back. Survivors are the deliverable; optionally rank them
   with a tournament.

The discipline is keeping the two stages separate: a generator that self-censors
toward "safe" answers defeats the breadth the pattern buys, and a filter that
softens its bar to admit near-misses defeats the quality the pattern guarantees.
Generate without judging, then judge without generating.

**Example sketch.** Hardening a thin function: generate twenty candidate test cases
aimed at its edges and error paths, then keep only those that both pass against
correct behavior and fail when the requirement is inverted (the load-bearing-test
check from *Definition of done* in `CLAUDE.md`) — discard the rest. Another fit:
when a bug resists a single fix, generate several distinct fix candidates, then
filter to the ones whose reproducing test goes green without breaking the suite.

## Composing the shapes

These combine. A tournament's rounds are each a fan-out-and-synthesize.
generate-and-filter feeds a tournament when the surviving set is still too large to
pick from directly. The recipe library wires fan-out-and-synthesize together with
adversarial-verification into the reusable fan-out-per-target → verify → verdict
skeleton; see `recipes/MANIFEST.md`.
