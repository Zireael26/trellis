# Plan: <one-line headline, mirroring the spec>

**Slug:** `<slug>`
**Date:** YYYY-MM-DD
**Spec:** `specs/<NNN>-<slug>/spec.md`
**Status:** draft <!-- draft | reviewed | accepted -->

---

## 1. Technical approach

*Two or three paragraphs describing the shape of the solution.* What components are added/changed, the dataflow, the failure model. No code yet.

## 2. Data model + schema changes

*Columns, indexes, migrations.* If none, write "No schema changes." Otherwise list each table change with column types and migration ordering.

| Table | Change | Type | Default | Migration ID (assigned at impl time) |
|---|---|---|---|---|
| <table> | add column `<name>` | <type> | <default> | <YYYYMMDDhhmm>_<slug> |

## 3. API surface

*New endpoints, modified endpoints, deprecated endpoints.* If none, write "No API changes."

| Method | Path | Request body | Response | Status codes |
|---|---|---|---|---|
| POST | `/api/<resource>` | `{...}` | `{...}` | 201, 400, 409 |

For non-HTTP surfaces (CLI flag, library export, hook signature), describe with the same precision.

## 4. File-by-file change list

*Every file that gets created or modified.* Order = implementation order (each step leaves the tree buildable). Put new files first, modified files after.

| # | File | Action | Purpose |
|---|---|---|---|
| 1 | `src/foo/new-thing.ts` | new | Encapsulates the new behaviour. |
| 2 | `src/foo/index.ts` | modify | Export new-thing. |
| 3 | `src/foo/__tests__/new-thing.test.ts` | new | Unit coverage for new-thing. |

## 5. Sequencing + dependencies

*If the change list can't be done in strict order without breaking the build, describe the broken-window step and the rollback if abandoned.* Otherwise: "Order above is the implementation order; each step is independently buildable."

## 6. Test strategy

*What gets tested, at what level (unit / integration / e2e), with what fixtures.* Cite the coverage that proves each success criterion from the spec.

| Spec success criterion | Test name | Level | Fixture |
|---|---|---|---|
| <criterion> | <test-name> | unit / integration / e2e | <fixture> |

## 7. Rollout plan

*How does this ship safely?* Feature flag? Phased ramp? Migration window? Backfill? If none of those apply, write "Ship directly on merge; no flagging needed."

## 8. Risks + mitigations

*What goes wrong, and what catches it?* User-facing risks, data risks, perf risks, security risks.

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| <risk> | low / med / high | low / med / high | <mitigation> |

## 9. Decisions log

*Trade-offs you made + why.* Three sentences each. Include rejected alternatives by name.

- **Decision:** Picked X over Y.
  - **Why:** Writes are 10x reads, X is faster on writes.
  - **Rejected:** Y (would have required two migrations + a coordinator).

## 10. Out of scope (deferred)

*Things you noticed while planning that are real, but not this PR.* File one issue per item or note in `gotchas.md` if it's a lesson rather than a TODO.

- <item>

---

## Review checklist (author + reviewer fill out together)

- [ ] Every file in the change list has a one-line purpose
- [ ] Sequencing leaves the tree buildable at every step (or the broken-window step is named)
- [ ] Each spec success criterion has a corresponding test in the strategy section
- [ ] Schema changes (if any) list types + migration ordering
- [ ] API changes (if any) list status codes + payload shapes
- [ ] At least one explicit trade-off appears in the decisions log
- [ ] Rollout plan is concrete (flag, phased ramp, or "direct ship — no flagging")
- [ ] Out-of-scope items are listed, not silently dropped
- [ ] No ADRs are contradicted (or the contradiction is explicit + acknowledged)
