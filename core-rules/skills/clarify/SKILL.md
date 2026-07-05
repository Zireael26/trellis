---
name: clarify
description: Front-load the spec-kit pipeline with a structured question pass. Use BEFORE invoking `spec` whenever the operator's initial request is vague, contradictory, or leaves any of the five canonical intent dimensions unresolved (intent, users affected, success metric, edge cases, rollback plan). Output is `specs/<NNN>-<slug>/clarify.md` — a Q&A document that the `spec` skill then converts into a structured spec. The skill refuses to declare itself done until every canonical question has a non-handwave answer.
---

# clarify

Front step of the opt-in spec → plan → tasks pipeline. The pipeline only works as well as the spec; the spec only works as well as the question pass that fed it. `clarify` is the question pass.

The skill produces `clarify.md` sitting beside `spec.md`. It does NOT write the spec — that's still the `spec` skill's job downstream. Clarify's deliverable is the answers, captured verbatim, with the operator's voice preserved.

## When to use

- The operator's initial request is one sentence and references something the agent doesn't fully understand.
- Two valid interpretations of the request exist and you can't pick silently (CLAUDE.md: "Don't hide confusion").
- Acceptance criteria are vague ("make it faster", "improve UX") — not testable yet.
- A previously written spec is being revised because reviewers flagged drift between what the requester wanted and what the spec assumed.
- The operator explicitly says "interview me before you spec this".

## When NOT to use

- The operator hands you a fully-written spec or detailed write-up. Read it, run `spec` to formalise, skip clarify.
- The work is a clear bug fix with a reproduction. Surgical default; no pipeline needed.
- The operator wants implementation NOW and explicitly waives the question pass. Note the waiver in `gotchas.md` if the resulting spec turns out wrong — that's data for the next pipeline run.

## Input contract

The `specs/<NNN>-<slug>/` directory must already exist. Two ways it gets there:

1. **Fresh feature, just scaffolded.** Operator (or you) ran `core-rules/skills/spec/scripts/new-feature.sh <slug>` to scaffold the directory + branch `feature/<slug>` + a *template* `spec.md`. The template is filled with placeholders, not real content. Clarify writes `clarify.md` alongside the template spec.md; the `spec` skill comes next and replaces the template's placeholders with real content informed by `clarify.md`.
2. **Existing in-flight feature.** `specs/<NNN>-<slug>/` already exists with a meaningfully-filled `spec.md`. The operator wants to re-clarify (typically because reviewers flagged drift between request and spec). Clarify writes `clarify.md`; the operator then re-runs the `spec` skill to revise `spec.md` against the new clarify findings.

If the directory does not exist yet, run `new-feature.sh <slug>` (or `<slug> --no-branch` if you want to stay on the current branch) FIRST. That script creates the directory, opens the branch, and lays down a template spec.md — clarify fits into the workflow right after.

## Output contract

One new file: `specs/<NNN>-<slug>/clarify.md`. Five sections, one per canonical question. Each section ends with the operator's answer (or, if the operator deferred, an explicit `Deferred: <reason>` block — not silent silence).

## The canonical five questions

Hardcoded for now. The schema lives at [`references/question-schema.md`](references/question-schema.md); update both in the same commit if either changes.

1. **Intent.** *What problem are we solving and why now?* Reject "build feature X" — that's a solution, not intent. Push back until the operator names the pain.
2. **Users affected.** *Who triggers this, who depends on it, who notices when it breaks?* If "everyone", you haven't decomposed; push for at least one concrete persona-in-scenario.
3. **Success metric.** *How will we know this worked — testable, observable, falsifiable.* Reject vibes ("better", "faster") without a number, a fixture, or a passing test.
4. **Edge cases.** *What inputs / states / timings make this hard?* Empty inputs, race conditions, rate limits, partial failures, retries.
5. **Rollback plan.** *If we ship this and it's wrong, how do we undo it cleanly?* Migrations need reverse migrations. Feature flags need a flip path. Schema changes need a stay-shape window.

Every question gets an answer or a `Deferred: <reason>` block. No silent skipping.

## How to use

1. **Read the operator's initial request.** Quote it verbatim at the top of `clarify.md`.
2. **Walk the five questions, one at a time.** For each: (a) ask the question in the operator's vocabulary; (b) listen to the answer; (c) write it down verbatim; (d) push back if the answer is a handwave.
3. **Surface contradictions.** If question 3's success metric doesn't match question 1's intent, flag the contradiction in `clarify.md` and resolve before declaring done.
4. **Don't silently improve answers.** If the operator's voice says "I don't know yet — figure it out", write that down with `Deferred: operator delegated this to the implementer`. Don't paper over with your guess.
5. **Declare done only when every question has an answer or an explicit deferral.** Then the operator (or the next agent invocation) runs the `spec` skill, which uses `clarify.md` as its input.

## Authoring rules

- **Operator voice wins.** Quote, don't paraphrase. The spec skill needs the original framing to avoid drift.
- **One answer per question.** If the operator gives two contradictory answers, surface the contradiction — don't pick one.
- **Deferrals are explicit and labelled.** `Deferred: <reason>` — never just an empty section.
- **Questions are sequential, not batched.** Asking all five up-front floods the operator; sequential lets answer N inform question N+1.
- **Attach a hypothesis + confidence to each question.** Before asking, state your own best guess at the answer and a confidence 0–1 — "my hypothesis: rollback = revert the deploy and restore the last snapshot (0.7)." Confirming or correcting a concrete guess is faster for the operator than answering a blank prompt, and it surfaces exactly where your mental model is wrong. The guess **primes** the question; it never **replaces** the answer — the operator's word still wins (see "Don't silently improve answers"). (Folded from the `interview-me` pattern.)
- **Predict-to-stop.** When you can predict the operator's next three answers with high confidence, the interview has converged — offer to stop early and move to `spec`, rather than walking the remaining questions ritually. A predicted answer is still a hypothesis: state it and let the operator veto.
- **No solutions in clarify.md.** This is the question pass. Solutions belong in `plan.md`. If the operator's answer to question 1 is a solution, ask "and the problem behind that?".

## Boundaries

- **One file written.** `specs/<NNN>-<slug>/clarify.md`. No edits to spec.md (which may not exist yet), no plan.md, no tasks.md, no code.
- **Read-only against the rest of the tree.** Read whatever you need to ask better questions — recent ADRs, `gotchas.md`, prior specs — modify nothing.
- **Refuse to overwrite an existing clarify.md.** Operator must explicitly remove it. Clarifications get revised in a follow-up, not silently overwritten.

## Sensible failure modes

- `specs/` directory missing → either the operator hasn't run `new-feature.sh` yet OR the slug is wrong. Stop and ask.
- Operator answers question 1 with a solution → don't write it down; ask the underlying-problem question and try again.
- Operator refuses to answer N questions → write each as `Deferred: operator declined`. The spec skill will surface these as "spec contains unanswered questions — proceed at risk".
- Operator's answers contradict each other → quote both; ask which is correct; record the resolution.

## Relationship to the rest of the pipeline

- **Before `spec`.** The spec skill reads `clarify.md` if it exists. If clarify wasn't run, the spec skill suggests running it for non-trivial features but does not hard-block (the pipeline stays opt-in).
- **Before `analyze`.** Not a direct dependency, but `analyze` uses `clarify.md` (when present) as one of the inputs for drift detection — if the spec drifted away from the operator's original intent captured in clarify, that's a major drift finding.
