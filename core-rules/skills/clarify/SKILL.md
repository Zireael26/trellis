---
name: clarify
description: Front-load the spec-kit pipeline with a structured question pass. Use BEFORE invoking `spec` whenever the operator's initial request is vague, contradictory, or leaves any of the five canonical intent dimensions unresolved (intent, users affected, success metric, edge cases, rollback plan). Output is `specs/<NNN>-<slug>/clarify.md` — a Q&A document that the `spec` skill then converts into a structured spec. The skill refuses to declare itself done until every canonical question has a non-handwave answer.
---

# clarify

Front step of the spec → plan → tasks pipeline (opt-in by default; **required** for above-floor changes when `mandatory_pipeline` is enabled — `engineering-process.md` §14.7). The pipeline only works as well as the spec; the spec only works as well as the question pass that fed it. `clarify` is the question pass.

The skill produces `clarify.md` sitting beside `spec.md`. It does NOT write the spec — that's still the `spec` skill's job downstream. Clarify's deliverable is the answers to the five dimensions, each one attributed to whoever actually settled it: the operator's own words where they gave them, and a labelled agent decision where existing authorization let one be taken. Both are legitimate; conflating them is not.

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

One new file: `specs/<NNN>-<slug>/clarify.md`. Five sections, one per canonical question, plus a conditional sixth `## Blind spots` section. Each section ends with a resolved answer and its attribution — the operator's answer quoted, or `Decided (agent): <answer> — <the authorization it rests on>` — or, where it was deferred, an explicit `Deferred: <reason>` block. Never silent silence, and never an agent decision dressed as an operator quotation. A blind-spot pass that was not warranted is recorded as `Not run: <domain is familiar>`, not omitted.

## The canonical five questions

Hardcoded for now. The schema lives at [`references/question-schema.md`](references/question-schema.md); update both in the same commit if either changes. The five are the fixed set; the blind-spot pass below is a conditional sixth section, not a sixth canonical question.

1. **Intent.** *What problem are we solving and why now?* Reject "build feature X" — that's a solution, not intent. Push back until the operator names the pain.
2. **Users affected.** *Who triggers this, who depends on it, who notices when it breaks?* If "everyone", you haven't decomposed; push for at least one concrete persona-in-scenario.
3. **Success metric.** *How will we know this worked — testable, observable, falsifiable.* Reject vibes ("better", "faster") without a number, a fixture, or a passing test.
4. **Edge cases.** *What inputs / states / timings make this hard?* Empty inputs, race conditions, rate limits, partial failures, retries.
5. **Rollback plan.** *If we ship this and it's wrong, how do we undo it cleanly?* Migrations need reverse migrations. Feature flags need a flip path. Schema changes need a stay-shape window.

**6. Blind spot pass (conditional).** Run this when the feature sits in a domain neither of you has depth in — a new protocol, an unfamiliar compliance surface, a platform you have not shipped on. Ask the operator to state their expertise level in the domain, then produce a short list of the unknowns *they did not ask about*: constraints, failure modes, and conventions a practitioner would take for granted. Record it under `## Blind spots` with each item marked `confirmed` / `not applicable` / `open`. Skip the section entirely when the domain is familiar — say so in one line rather than manufacturing unknowns.

Every question gets an answer or a `Deferred: <reason>` block. No silent skipping.

## How to use

1. **Read the operator's initial request.** Quote it verbatim at the top of `clarify.md`.
2. **Harvest before you ask.** Walk the five dimensions against what you already have — the request itself, prior turns, the spec being revised, `gotchas.md`, existing authorization. Record each dimension the available material already settles, attributed: quoted where the operator supplied it, `Decided (agent):` where you resolved it under existing authorization. A dimension you can answer honestly from what is in front of you is not a question.
3. **Ask what genuinely remains, and only that.** For each still-open dimension: (a) ask in the operator's vocabulary; (b) listen; (c) write the answer down verbatim; (d) push back if it is a handwave. Ask about consequential unknowns — a dimension whose either-way answer produces the same spec does not warrant an interview turn. Who answers the rest is the autonomy slider's call, not this skill's: at higher levels resolve them yourself and log the decision; at lower levels put them to the operator. When the operator asked to be interviewed, asked for the questions only, or asked you to wait, that request binds and you ask regardless.
4. **Surface contradictions.** If question 3's success metric doesn't match question 1's intent, flag the contradiction in `clarify.md` and resolve before declaring done.
5. **Don't silently improve answers, and don't invent them.** If the operator's voice says "I don't know yet — figure it out", write that down with `Deferred: operator delegated this to the implementer`. Never attribute words to the operator they did not say — an answer you reasoned to is an agent decision and is labelled as one.
6. **Declare done only when every dimension has an answer — operator's or attributed agent's — or an explicit deferral.** Then continue to the `spec` skill under whatever authorization is already in force; a caller already authorized for the pipeline does not need a fresh permission cycle to proceed, and one who asked to stop here stops here.

## Authoring rules

- **Operator voice wins where there is one.** Quote, don't paraphrase — the spec skill needs the original framing to avoid drift. Where no operator answer exists, an attributed agent decision is the honest record; a fabricated quotation is not, and it corrupts the drift detection `analyze` runs against this file.
- **One answer per question.** If the operator gives two contradictory answers, surface the contradiction — don't pick one.
- **Deferrals are explicit and labelled.** `Deferred: <reason>` — never just an empty section.
- **Ask sequentially when you are asking a person.** Firing all five at once floods the operator, and answer N informs question N+1. Batching is the right shape when the autonomy level has you answering them yourself, or when the operator has asked for the whole set at once.
- **Order by architectural consequence.** Between two questions, ask first the one whose answer would change the architecture — the data model, an interface shape, a UX flow, a rollback mechanism. A question whose either-way answer produces the same plan is a question for the PR description, not for clarify.
- **Attach a hypothesis + confidence to each question.** Before asking, state your own best guess at the answer and a confidence 0–1 — "my hypothesis: rollback = revert the deploy and restore the last snapshot (0.7)." Confirming or correcting a concrete guess is faster for the operator than answering a blank prompt, and it surfaces exactly where your mental model is wrong. The guess **primes** the question; it never **replaces** the answer — the operator's word still wins (see "Don't silently improve answers"). (Folded from the `interview-me` pattern.)
- **Predict-to-stop.** When you can predict the operator's next three answers with high confidence, the interview has converged — offer to stop early and move to `spec`, rather than walking the remaining questions ritually. A predicted answer is still a hypothesis: state it and let the operator veto.
- **No solutions in clarify.md.** This is the question pass. Solutions belong in `plan.md`. If the operator's answer to question 1 is a solution, ask "and the problem behind that?".

## Boundaries

- **One file written.** `specs/<NNN>-<slug>/clarify.md`. No edits to spec.md (which may not exist yet), no plan.md, no tasks.md, no code.
- **Read-only against the rest of the tree.** Read whatever you need to ask better questions — recent ADRs, `gotchas.md`, prior specs — modify nothing.
- **Never silently overwrite an existing clarify.md.** Blind overwrite is the thing being refused, not revision itself. Unasked, leave the file alone and say it exists. When a revision *is* asked for, edit it in place and surgically: change the sections the new findings actually touch, preserve every other section's text and attribution, and note what changed. Do not require the operator to delete the file first, and do not destroy-and-recreate it — the prior answers are the drift baseline `analyze` compares against.

## Sensible failure modes

- `specs/` directory missing → either the operator hasn't run `new-feature.sh` yet OR the slug is wrong. Stop and ask.
- Operator answers question 1 with a solution → don't write it down; ask the underlying-problem question and try again.
- Operator refuses to answer N questions → write each as `Deferred: operator declined`. The spec skill will surface these as "spec contains unanswered questions — proceed at risk".
- Operator's answers contradict each other → quote both; ask which is correct; record the resolution.

## Relationship to the rest of the pipeline

- **Before `spec`.** The spec skill reads `clarify.md` if it exists, and suggests running clarify for non-trivial features without hard-blocking. Under an enabled `mandatory_pipeline`, `clarify.md` (or a `.claude/spec-waiver`) is the artifact that satisfies the intake half of the pre-push gate; autonomy changes only *who answers* it. Canonical: `engineering-process.md` §14.7 and §14.9.
- **Before `analyze`.** Not a direct dependency, but `analyze` uses `clarify.md` (when present) as one of the inputs for drift detection — if the spec drifted away from the operator's original intent captured in clarify, that's a major drift finding.
