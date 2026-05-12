# Spec: <one-line headline>

**Slug:** `<slug>`
**Date:** YYYY-MM-DD
**Author:** <name>
**Status:** draft <!-- draft | reviewed | accepted | superseded -->

---

## 1. Problem statement

*What hurts today? Who notices? Why now?* One paragraph. No solutions.

## 2. Users + scenario

*Who triggers this and in what moment?* If multiple personas, list each with their own moment. Concrete, not generic.

- **<persona>** — <scenario>

## 3. Success criteria

*Testable, observable outcomes. Not aspirations.* Each criterion must be something an engineer can write a test for or measure on a dashboard.

- [ ] <criterion>
- [ ] <criterion>
- [ ] <criterion>

## 4. Non-goals

*What this feature is NOT solving.* Most scope creep is prevented here. Be explicit.

- <non-goal>
- <non-goal>

## 5. Constraints

*Hard limits the feature must respect.* Compliance, performance budgets, backwards compatibility, platform requirements, deadlines.

- <constraint>

## 6. Open questions

*Things the operator and author haven't decided yet.* If empty, write "None as of <date>". Open questions block the `plan` skill from making silent picks downstream.

- <question>

## 7. Risks

*What goes wrong if we ship this?* User-facing failure modes, data integrity risks, rollout hazards.

- <risk>

## 8. Out of scope (intentional)

*Adjacent things people might assume are part of this work but aren't.* This is non-goals' sibling — non-goals = "we considered and chose no"; out-of-scope = "this would be a different feature entirely".

- <out-of-scope item>

---

## Review checklist (author + reviewer fill out together)

- [ ] Problem statement names a real pain, not a solution
- [ ] Every success criterion is testable
- [ ] At least one non-goal is listed
- [ ] Constraints cite their source (compliance doc, perf budget, deadline rationale)
- [ ] Open questions are real questions, not placeholder TODOs
- [ ] No implementation detail crept in (file names, function names, API shapes — those belong in `plan.md`)
- [ ] Spec is readable in under 5 minutes
