# Release 1.3.13 lands as one PR above the size cap

## Status

Accepted by the owner's standing instruction of 2026-10-11/12 to ship and roll out 1.3.13 in full. Covers PR #579 only.

## Context

1.3.13 delivers spec 069 (disk and worktree hygiene) on top of 1.3.12:
- the central worktree root and `trellis worktree migrate`;
- the Claude Code worktree hooks;
- the pi bash guard and `_pi` root;
- pnpm and uv sharing;
- the janitor dehydrate, host and watchdog scopes;
- tool and skill hygiene.

It also carries the gate fallout from the full-suite runs, plus three fixes picked after 1.3.12:
- organisation-admin approval for gate-config ranges;
- CPU-sized gate shards with measured stage weights;
- the runner's vanished-process race.

The range is 16,265 changed lines across 106 files: tests 8,066, spec 069 documents 1,156, other docs 214, code 6,829. That is above the process gate's 800-line hard cap. Each extra PR costs a full serial merge gate of more than an hour. Spec 069's lanes were each reviewed by another model family before integration, and the integrated range passed the full test and security rows on its exact head.

## Decision

Land #579 as one PR, gated in merge mode on its exact head. The PR description records the size acknowledgement and the test/spec/code split above.

## Consequences

- The oversized range stays visible in the gate's PR-hygiene row as a warning. The PR description records the size acknowledgement; this ADR does not grant it.
- The exception covers PR #579 only. It does not raise the default size caps.
