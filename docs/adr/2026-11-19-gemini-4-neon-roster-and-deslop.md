# ADR: Gemini 4 Neon roster cutover and `/de-slop` multi-harness workflow

- Date: 2026-11-19
- Status: Accepted
- Related: [Machine-local roster](2026-11-18-machine-local-roster.md), [GPT-6 roster](2026-09-27-gpt6-roster.md)

## Context

The Google Gemini family in the portable model catalog previously routed through `gemini-4-argon`. With Gemini 4 Neon available across four effort levels (`low`, `medium`, `high`, `xhigh`), the fleet needed an updated Google family route that preserves cross-family verdict independence while retiring `gemini-4-argon`. At the same time, operators running Google AI Pro subscriptions without Hydrogen access still rely on `gemini-3.8-flash`, so retiring Argon must not remove that subscription-compatible entry.

Separately, mature repositories accumulate redundant tests and low-signal boilerplate across harnesses (`claude-code`, `codex`, `pi`, `antigravity`, and `opencode`). Existing cleanup guidance lived only in single-harness surfaces, lacked structured `test_diet` telemetry in `trellis lean-audit`, and `roster.py` / `resolve-roles.py` could miss user-installed harness CLIs when invoked outside an interactive login shell.

## Decision

1. **Promote Gemini 4 Neon and retire Argon:** Add Gemini 4 Neon (`low`, `medium`, `high`, `xhigh`) to the canonical portable model catalog and role routing, and retire `gemini-4-argon`. Retain `gemini-3.8-flash` in the portable catalog so Google AI Pro accounts without Hydrogen access keep a supported Google-family seat.
2. **Ship `/de-slop` and multi-harness workflow parity:** Add `/de-slop` (`.claude/commands/de-slop.md` for `claude-code`) and wire `.agents/workflows/de-slop.md` and `.agents/workflows/test-cleanup.md` for `antigravity`, `codex`, and `pi`, paired with `test_diet` telemetry in `trellis lean-audit` so cleanup passes are measurable and repeatable.
3. **Broaden user CLI `PATH` discovery in roster resolution:** Update `roster.py` and `resolve-roles.py` to discover user-installed harness CLIs across standard user `PATH` locations without requiring interactive shell initialization.
4. **Accept stock macOS `$HOME/Library` deletion-guard ACL:** Extend `trellis launchd` (`scripts/install-disk-janitor-launchd.sh`) to accept Apple's stock single-ACE `0: group:everyone deny delete` on `$HOME/Library` (matching `$HOME`) while continuing to reject any other ACL entry on `$HOME/Library` and any ACL on `LaunchAgents`, `Logs`, or plist files.

## Consequences

- Google-family routing upgrades cleanly to Gemini 4 Neon with explicit effort granularity while keeping Google AI Pro fallback coverage via `gemini-3.8-flash`.
- Cleanup workflows (`/de-slop`, `/test-cleanup`) and `lean-audit` `test_diet` metrics are available uniformly across all supported harnesses.
- Non-interactive invocations of `trellis roster` and role resolution reliably locate user-installed harness binaries.
- Fresh macOS hosts with default `$HOME/Library` ACLs no longer require manual `chmod -N` before running `trellis launchd`, without weakening ACL enforcement on `LaunchAgents`, `Logs`, or plist targets.
