# ADR: bypass-tripwire runs weekdays only

## Status
Accepted (retroactive — 2026-04-28 was the first weekday run; recorded 2026-05-08 per plan task P3.10)

## Context

The `bypass-tripwire` scheduled task scans the fleet for `--no-verify`,
force-push, and direct-to-main markers. It fires on weekdays at 08:00 local
(`0 8 * * 1-5`).

The audit (2026-05-08 Trellis meta-audit §2.3 sixth bullet) flagged the
weekday-only cadence as undocumented: a reader looking at
`scheduled-tasks/README.md` sees the cron and has to infer why weekends are
skipped.

## Decision

Codify the weekday-only cadence and its rationale here.

## Rationale

- **Tripwires are silent unless tripped.** A weekend run produces output
  only if a bypass happened over the weekend. If one did, the operator
  doesn't see the alert until Monday morning anyway — by which time the
  Monday 08:00 run will have caught it.
- **Bypass events on weekends are rare and often deliberate.** Solo-dev
  evening hacking commonly involves `--no-verify` for quick spikes. Firing
  the audit weekend-mornings would generate noise that doesn't change the
  Monday triage.
- **Cost.** Each tripwire run touches every registered project. Halving
  the run count halves the API + scheduler cost for a check whose
  signal-to-noise on weekends is low.

## Consequences

- A bypass on Friday night surfaces in Monday's 08:00 run.
- An emergency-shaped weekend bypass (incident-driven, justified) does not
  trigger a notification until Monday — acceptable because the operator
  knows they did it; the tripwire's job is to surface *unintentional*
  bypass habits.
- Adding a Saturday/Sunday run later is one cron edit; this ADR is not a
  permanent commitment.

## References

- `scheduled-tasks/bypass-tripwire/prompt.md`
- `scheduled-tasks/README.md` cron table
- Audit §2.3 sixth bullet
