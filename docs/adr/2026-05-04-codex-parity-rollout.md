# ADR: Keep Codex Parity Rollout Together

## Status
Accepted

## Context
Trellis originally treated Claude Code as the only first-class harness. Codex support now requires coordinated changes across parent rules, Codex hook assets, process-gate behavior, onboarding scripts, template sync, and audit prompts.

Splitting those changes across several parent-layer PRs would create intermediate states where one part of the system advertises Codex support while another part cannot install, sync, or audit it.

## Decision
Ship the parent-layer Codex parity work as one Trellis PR:

- canonical `.codex/` hook assets,
- `AGENTS.md` and `.agents/` inheritance guidance,
- onboarding and sync scripts,
- process-gate updates,
- audit prompt updates,
- template sync support.

Active project rollout PRs remain separate per repository because those changes are mechanical deployments of the new parent contract.

## Consequences
The Trellis PR is larger than the default process-gate hard cap, but review is clearer because all parent-layer contract changes can be checked together. Rollback is also straightforward: revert the one parent-layer PR, then skip or revert the dependent project rollout PRs.
