# Block oversized Skills before body injection

Date: 2026-07-28
Status: Accepted
Spec: `specs/026-oversized-skill-safety/`

## Context

A dynamically loaded Skill injected about 847,790 characters into a GPT-backed
Claude Code session. Auto-compaction did not recover; manual `/compact` did.
PostToolUse probes showed only `{commandName, success}` because `SKILL.md` arrives
later as separate user context. Post-load output replacement cannot protect this
boundary.

Normal canonical Skills are far below the incident size. Lowering the 272,000-token
GPT context window would reduce useful capacity while leaving dynamic Skill
injection possible.

## Decision

1. Set a hard inline `SKILL.md` budget of 65,536 valid UTF-8 bytes.
2. Enforce model-invoked Skills at PreToolUse and direct slash Skills at
   UserPromptExpansion, before expansion.
3. Resolve supported roots by project > user > installed plugin cache > marketplace,
   matching declared name or basename and failing closed on same-tier ambiguity.
4. Reject control-character paths/names and use option-safe canonicalization.
5. Warn, but do not block session startup, for discoverable oversized/ambiguous roots.
6. Keep the 272K context and normal auto-compaction unchanged.
7. Treat unknown external loader roots as residual risk instead of claiming full
   loader coverage.
8. Keep Claude and Codex hook copies behaviorally identical and verify settings
   distribution through existing sync/inventory gates.

## Alternatives considered

**PostToolUse truncation.** Rejected because the event lacks the body and fires
before the later user-context injection can be replaced.

**Lower global context.** Rejected because it penalizes normal work and does not
bound one injected Skill body.

**Automatically truncate oversized Skills.** Rejected because partial instructions
are unsafe and loader rewriting is not available at the proven hook boundary.

**Scan every directory named `skills`.** Rejected because it creates false
ambiguity across Cursor, Windsurf, source trees, and unrelated nested directories.

## Consequences

- Discoverable oversized Skills fail before model context damage.
- Canonical Skills gain a deterministic CI/local size gate.
- Plugin cache copies win over marketplace source copies without false ambiguity.
- Missing future loader roots remain an explicit limitation requiring upstream
  product support or a new proven hook field.
- Existing sessions and services are unaffected until a separate maintenance-window
  rollout installs merged hooks.
