---
name: debrief
description: Teach the human the change just made — incrementally, restate-first, verifying understanding tier by tier before advancing. Explicit invocation only.
argument-hint: "[PR# | path | blank = this session's change] [--keep]"
disable-model-invocation: true
---

# debrief

The teach-it-back discipline. The agent did the work; now it makes the human **deeply
understand it** — incrementally, verifying mastery of each tier before advancing,
drilling the *whys*, and keeping a running checklist of what the human must understand.
It is the autonomy counterweight: the more the agent did on the human's behalf, the more
valuable the debrief. This SKILL.md is the harness-neutral specification of that
discipline. Authoritative rules live in `engineering-process.md` and `CLAUDE.md` — when
in doubt, those win.

Loaded identically whether surfaced from `.claude/skills/debrief/` or
`.agents/skills/debrief/`. Same SKILL.md, same `references/`.

This skill is **explicit-invoke-only** — it never auto-fires. On harnesses that support
it, `disable-model-invocation: true` is the hard switch (it also drops the description
from ambient context). Elsewhere, the narrow description plus the "when NOT to use" prose
below are the soft guard, and the skill is invoked by name.

## When to use

- After a change or session, when the human wants to genuinely understand what was built
  and *why* — especially after autonomous (L4/L5) work, where they were deliberately less
  in the loop while it happened.
- To onboard a teammate onto a specific change or pull request.

## When NOT to use

- As ambient narration during work. The skill is explicit-only (`/debrief`); it does not
  narrate as you go.
- For a quick one-line "what did you change." Just answer.
- For mapping a **stable** subsystem the human is not about to need deeply — that is the
  primer / `/explore` lane. `debrief` is for *changes* and *recent work*, not standing
  architecture.

## Arguments

`[PR# | path | blank = this session's change] [--keep]` — the skill parses its own
arguments.

1. **Pull `--keep` out first.** Scan the argument string for `--keep` and remove it; it
   controls only the checklist doc's fate (see *The running checklist doc*), not the
   subject.
2. **The trimmed remainder is the subject.** An empty remainder means **this session's
   change** — the working diff / the work just completed.
3. **Resolve the subject:**
   - blank → the current session's change (working diff).
   - `PR#` (`#123` or a bare number) → that pull request's diff and description.
   - a path → the named file or subsystem (for a *stable existing* subsystem a primer is
     usually the better tool; `debrief` is for changes).

Resolve the subject, then run the teaching loop on it.

## The teaching loop (restate-first)

Diagnose before teaching. Never lecture from zero.

1. **Restate-first.** Ask the human to restate their current understanding of the subject
   *first*. Their restatement is the diagnosis.
2. **Fill the gaps** the restatement reveals — at **both altitudes**: motivation (the
   high level) and concrete logic / edge cases (the low level). Every tier needs both.
3. **Verify mastery** of the current tier — a restatement in their own words, or a passed
   quiz item.
4. **Advance** only after the current tier is mastered. One tier at a time; never dump all
   three at the end.

## The three understanding tiers (and the checklist structure)

The running checklist doc is organized as **exactly these three tiers**; each tier is a
set of checkbox items, flipped from unchecked to checked only when the human demonstrates
it:

1. **The problem** — what problem the change solves, *why the problem existed*, and the
   alternative branches considered and rejected.
2. **The solution** — what was done, *why this way*, the design decisions, and the edge
   cases.
3. **The broader context** — why this matters, and what the change impacts: blast radius,
   downstream consumers, follow-ons.

Understanding the problem well is imperative — do **not** let the human skip tier 1 to get
to the code.

## Drill the whys

Recurse on "why," not just "what" and "how." When the human gives a surface answer, ask
the next "why" until the causal chain is explicit. "What" and "how" are necessary but not
sufficient — a tier is mastered when the *why* is reconstructed, not recited.

## Open dialogue + the ELI ladder

The debrief is a **two-way conversation**: the human may interrupt to ask the agent
questions at any point, not only restate and answer quizzes. On request, the agent
re-explains at a chosen depth — **eli5** (absolute basics), **eli14** (some background
assumed), **eli-intern** (a capable engineer new to *this* codebase). The human drives
which rung; the agent honours it.

## Quiz mechanic (capability-gated)

Probe understanding with a mix of open-ended and multiple-choice questions. Three
disciplines hold on **every** harness:

- **Shuffle** the correct answer's position across questions — no positional tell.
- **Never reveal** the answer until the human has committed a response.
- A wrong answer is the gap, not a stop — diagnose it, then re-probe before flipping a box.

**Capability gate.** If the harness exposes a structured single-question tool
(`AskUserQuestion` on Claude Code today, checked against the actual tool list), use it for
clean multiple-choice submission. Otherwise **degrade** to numbered inline Q&A, preserving
the shuffle and the no-early-reveal. The quiz is **never** a hard dependency on
`AskUserQuestion` or any Claude-only tool. Mechanics:
[`references/quiz-and-degrade.md`](references/quiz-and-degrade.md).

## Show-code / debugger (capability-gated)

Show the actual code, or step a debugger where the harness exposes one (checked against
the tool list). Otherwise **degrade** to reading the relevant code together. Never a hard
dependency — the debugger is a nicety, the discipline of looking at the real code is not.

## Stop condition (a verifiable goal)

The stop condition rests on the **verifiable-goal rule in `CLAUDE.md`** — the same rule
the loop-until-done pattern rests on — not on any CLI command:

> **Done** = every checklist item across all three tiers has either a demonstrated
> restatement in the human's own words or a passed quiz item.

Open (unchecked) items mean **not done** — keep teaching. The one bounded escape hatch
mirrors `CLAUDE.md`'s open-todos rule: the human may explicitly **defer or abandon a
specific item with a reason**. The default stays "keep teaching until mastered"; the
escape hatch is owned, never silent. This is harness-neutral and depends on no CLI loop.

## The running checklist doc

The checklist is the durable output of a debrief — a persisted artifact the human keeps.

- **Default — transient, uncommitted.** Lands at
  `<canonical-root>/.claude/debrief/<topic>-<sha>.md`, where `<canonical-root>` is the
  **parent of `git rev-parse --git-common-dir`** (the same canonical-root convention as
  `context-log.md`, primers, and `_explore/`, so worktree sessions and the main checkout
  share one location). The agent creates the directory on first use, exactly as `/explore`
  creates its notes dir. It is personal learning scratch, not project history: kept out of
  commits by being **transient** — created on use, deleted by the human or promoted via
  `--keep` — **not** by a `.gitignore` entry (none exists for `_explore/` or primers
  today; `debrief` adds none).
- **`--keep` — promote to a committed doc.** When the human passes `--keep`, the finished
  checklist is written to `docs/debriefs/<topic>.md` and committed as a durable
  onboarding / learning record. Promotion is an explicit opt-in; the default stays
  transient.
- **Format.** Three tiered sections (above); each item a checkbox; items flip to checked
  only on demonstrated understanding. Update the doc **incrementally** during the session,
  not in one shot at the end.

## Capability gate + graceful degrade

The skill is **universal** — no hard capability requirement; it ships to the public
mirror. Each gate keys on **tool presence, not harness identity**: the question is whether
the harness exposes the tool, checked against the actual tool list. Two niceties degrade;
the discipline never does.

| Capability | Have it | Degrade |
|---|---|---|
| No-auto-fire switch (`disable-model-invocation`) | hard suppression — can't auto-trigger | narrow description + explicit "when NOT to use" prose |
| Structured single-question tool | clean MCQ submission, shuffled, no reveal | numbered inline Q&A, same shuffle / no-reveal |
| Debugger | step through live | read the code together |

Restate-first, gated tiers, drill-the-whys, the checklist doc, the verifiable stop
condition — identical on every harness. Only the quiz / debugger surface changes.
