# Tasks: <one-line headline, mirroring the spec + plan>

**Slug:** `<slug>`
**Date:** YYYY-MM-DD
**Spec:** `specs/<NNN>-<slug>/spec.md`
**Plan:** `specs/<NNN>-<slug>/plan.md`
**Status:** in-progress <!-- in-progress | done | abandoned -->

---

## Working contract

- This file is the source of truth for the feature's work breakdown.
- `TodoWrite` mirrors the next 3–5 active tasks; it does not duplicate the whole list.
- Tick the checkbox here when a task is committed. Don't tick it on local-only changes.
- Each task ≤4 hours. If you discover one is bigger mid-flight, split it and update this file.

---

## Tasks

| ID | Task | Est. | Depends | Covers (spec §3 criterion) | Status |
|----|------|------|---------|------|--------|
| T1 | <one-line imperative task naming the file> | ~Xh | — | <criterion> | [ ] |
| T2 | <...> | ~Xh | T1 | <criterion> | [ ] |
| T3 | <...> | ~Xh | T1 | <criterion> | [ ] |

## Coverage map

*Every spec success criterion should appear under at least one task.* If any criterion is uncovered, surface it before starting work.

| Spec criterion | Covering tasks |
|---|---|
| <criterion> | T1, T3 |
| <criterion> | T2 |

## Follow-ups (discovered during implementation)

*Items that didn't fit the original plan but need attention.* If a follow-up grows into substantive work, spawn a separate spec rather than appending tasks here.

- <item>

## Done criteria

*The feature is done when:*

- [ ] Every task above is checked.
- [ ] Every spec success criterion has a passing test in CI.
- [ ] PR is reviewed and merged (process-gate verdict MERGEABLE).
- [ ] Rollout step from plan §7 is complete (flag enabled, migration run, etc.).
- [ ] Status field above is updated to `done`.

---

## Status updates (optional changelog)

*Brief notes when the feature's status changes meaningfully — useful for handoffs.*

- YYYY-MM-DD: created from `plan.md`, 0/N tasks complete.
- YYYY-MM-DD: <update>
