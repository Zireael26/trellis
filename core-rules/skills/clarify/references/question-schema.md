# clarify question schema

The five canonical questions every `clarify.md` must answer (or explicitly defer). These are hardcoded in the skill body; this file is the deep-dive reference that explains the *why* behind each question, what counts as a real answer, and what to push back on.

If you edit the question set, also edit `SKILL.md`'s "The canonical five questions" section in the same commit. Drift between the two creates ambiguity about which is authoritative.

---

## Q1 — Intent

> What problem are we solving and why now?

**Real answer looks like:** "Stock counts diverge from warehouse by end of day; manual reconciliation eats 90 minutes per store per week. We have 12 new stores rolling out in Q3 and the reconciliation load doesn't scale."

**Handwave answer to push back on:**
- "Build a sync feature." → that's a solution; ask for the underlying pain.
- "Improve inventory." → ask "improve which dimension of inventory, for whom?"
- "Customers asked for it." → ask "which customers, asking for what specifically?"

**Why this question.** Without naming the pain, every other question is unanchored. Solutions multiply; problems anchor.

---

## Q2 — Users affected

> Who triggers this, who depends on it, who notices when it breaks?

**Real answer looks like:** "Triggered by POS sale completion. Depended on by warehouse fulfilment team (they treat the reconciled count as authoritative). Breaks visible to store managers within the same shift."

**Handwave answer to push back on:**
- "Everyone." → ask for one concrete persona-in-scenario.
- "Internal teams." → ask which team's workflow changes specifically.
- "Users." → users of what, in what role, at what moment?

**Why this question.** Distinguishes the trigger surface from the consumer surface from the failure-visibility surface. Each of those is a separate design constraint downstream.

---

## Q3 — Success metric

> How will we know this worked — testable, observable, falsifiable.

**Real answer looks like:** "Stock counts in POS and warehouse agree within 60 seconds of any sale event, measured by a query joining both systems' audit logs over a 7-day window. Reconciliation manual hours drop to under 30/store/week."

**Handwave answer to push back on:**
- "It works." → ask what observable behaviour proves it works.
- "Better UX." → ask which metric improves and how it's measured.
- "Faster." → faster than what baseline, measured how, on what fixture?

**Why this question.** A success metric you can't write a test against is an aspiration, not a criterion. Acceptance criteria in spec.md §3 inherit from here directly.

---

## Q4 — Edge cases

> What inputs / states / timings make this hard?

**Real answer looks like:** "POS goes offline mid-shift and queues sales locally; warehouse API rate-limits at 30 req/min; partial fulfilment (item picked, then returned to shelf); multi-station POS where two terminals sell the last unit within the same second."

**Handwave answer to push back on:**
- "We'll figure that out at implementation." → no; surface enough now that the plan knows what to design for.
- "Standard edge cases." → name three.
- *(silence)* → ask for the failure mode the operator is most worried about; iterate.

**Why this question.** Most production bugs come from edge cases the spec didn't name. Surfacing them in clarify means the plan and tasks both account for them; missing them here means re-spec mid-implementation.

---

## Q5 — Rollback plan

> If we ship this and it's wrong, how do we undo it cleanly?

**Real answer looks like:** "Behind feature flag `inventory_sync_v2`. Flag off → POS reverts to the existing daily-batch reconciliation path. Schema change is additive (new `sync_events` table); no destructive migration. Rollback = flip the flag + monitor for 24h."

**Handwave answer to push back on:**
- "We won't need to roll back." → almost always wrong; force the answer.
- "Revert the commit." → not a plan when there's a schema migration or a flag.
- "Disable it." → ask how, specifically.

**Why this question.** Rollback is the most under-specified part of every spec. Forcing it into clarify catches the schema-migration-with-no-reverse and the no-feature-flag-but-1%-customers-already-using-it scenarios before implementation begins.

---

## Editing this schema

If the five questions ever need to change:

1. Update `SKILL.md`'s "The canonical five questions" section in the same commit.
2. Add a deprecation note here for the removed question, with the rationale.
3. Run `scripts/conformance-check.sh` to confirm no other doc references the dropped name.
4. Note the change in `CHANGELOG.md`.
