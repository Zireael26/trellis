# Context log

Evidence captured from project sessions. Entries are concise and retain the observed inputs, result, and verification.

## session-2026-08-20

- 2026-08-20 — Attachment follow-up: Husky preparation had rewritten `core.hooksPath` after Trellis attachment.
- Input: project root and the recorded managed dispatcher path.
- Result: doctor reported the managed dispatcher as current after the path was restored.
- Verification: a second doctor run reported no hook-authority drift.

## session-2026-08-26

- 2026-08-26 — The same hook-authority drift was reproduced after another installation.
- Input: project root and managed dispatcher path.
- Result: the dispatcher was restored and doctor reported it as current.
- Verification: a separate doctor run reported no drift.
