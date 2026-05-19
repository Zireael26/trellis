# ADR: Tier 2 scheduled task promotion criteria

## Status
Accepted (retroactive — `lint-debt-trend` and `large-file-watch` parked 2026-04-27 in `scheduled-tasks/README.md`; recorded 2026-05-08 per plan task P3.10)

## Context

`scheduled-tasks/README.md` distinguishes **Tier 1** (registered, running
on a schedule) from **Tier 2** (designed, prompt drafted, not yet
registered). As of 2026-04-27, two tasks live in Tier 2:

| Task | Why parked |
|---|---|
| `lint-debt-trend` | Wait to see if the PostToolUse hook is enough to cap warnings |
| `large-file-watch` | Wait for evidence that big-file pain is real |

The audit (2026-05-08 §1.3 second bullet) flagged that the criteria for
*when* Tier 2 promotes to Tier 1 are not written down. A future maintainer
looking at the parked list cannot tell what evidence would tip the
balance.

## Decision

Tier 2 → Tier 1 promotion fires when **any** of:

1. **Real-world signal threshold** — a Tier 1 audit
   (`cross-project-process-audit`, `parent-hook-drift`,
   `audit-report-rollup`) reports the parked check's concern as a finding
   in 3+ consecutive runs. (Rule of Three applies here too.)
2. **PR-review volume threshold** — code review comments / human review
   time on the parked concern start consuming a not-trivial fraction of
   total review effort.
3. **Time threshold** — 6 months elapsed without Tier 1 audits surfacing
   the concern. Promote anyway as a low-cost trend-line; no harm done.

## Demotion criteria (Tier 1 → Tier 2 or retirement)

Less ceremony, more pragmatic:

- Tier 1 task fires zero criticals + zero warnings for 6+ consecutive
  weekly runs → demote to Tier 2 with a note "no longer pulling its
  weight; revisit if [trigger]".
- Tier 1 task fires false positives more than half the time for 4+ weeks
  → either fix the prompt or demote.

## Consequences

- The parking discipline stops being implicit. New Tier 2 tasks must
  state the trigger that would promote them — `targets.md` should carry
  a "Promotion trigger:" line.
- The README's Tier 2 table should grow a Trigger column on the next
  edit. P3.10 leaves the existing table as-is to keep the ADR scope to
  the criteria themselves; the table extension is logged as a
  follow-up.

## References

- `scheduled-tasks/README.md` Tier 2 table
- Audit §1.3 second bullet
