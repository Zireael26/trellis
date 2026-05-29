# Targets — autonomy-drift

Runs weekly (Mon 11:30 — before preset-drift at 12:00, so any preset/autonomy interaction surfaces first).

Reads:
- `__TRELLIS_PATH__/trellis.config.json` (fleet default).
- `__TRELLIS_PATH__/registry.md` (active projects).
- `__TRELLIS_PATH__/blacklist.md` (temporary opt-outs).
- Each active project's `.trellis.config.json` or `trellis.config.json`.
- Each project's `<project>/.claude/session-autonomy` (if present).
- Each project's `<project>/decisions-log.md` (if present).

Writes:
- `__TRELLIS_PATH__/audits/YYYY-MM-DD-autonomy-drift.md`.

Read-only. No remediation; surfaces findings for human review.
